#!/usr/bin/env bash
# ============================================================
# §18 concurrency test, run against real parallel connections.
#
# This is the local counterpart of tests/race-test.sh: same
# guarantee, but exercised at the database level so it can run
# without a deployed project. race-test.sh checks the same thing
# through the Edge Functions once you have one.
#
#   bash tests/local/concurrency.test.sh [dbname]
# ============================================================
set -euo pipefail
DB="${1:-janeiro_test}"
PHONE_A=0552000099   # concurrent create+submit
PHONE_B=0552000088   # concurrent submit of pre-created orders
PHONE_C=0552000077   # concurrent creates sharing one idempotency key

fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*"; exit 1; }
pass() { printf '\033[32mPASS  %s\033[0m\n' "$*"; }

q() { psql -d "$DB" -X -A -t -q -c "$1"; }

PM=$(q "select id from payment_methods where is_active order by sort_order limit 1;")
PROD=$(q "select id from products where slug='discord-nitro';")
PLAN=$(q "select id from product_plans where product_id='$PROD' order by sort_order limit 1;")
ITEMS="jsonb_build_array(jsonb_build_object('product_id','$PROD'::uuid,'plan_id','$PLAN'::uuid,'quantity',1,'activation',jsonb_build_array(jsonb_build_object('label','اسم المستخدم في ديسكورد','value','racer'))))"

cleanup() {
  q "delete from orders where normalized_phone in ('213${PHONE_A:1}','213${PHONE_B:1}','213${PHONE_C:1}');" >/dev/null
  # Also drop the phone's rate-limit buckets. Without this a second run of
  # this script creates nothing and every assertion below passes on an
  # empty set — a test that cannot fail is worse than no test.
  q "delete from rate_limits where bucket_key in ('213${PHONE_A:1}','213${PHONE_B:1}','213${PHONE_C:1}');" >/dev/null
}
cleanup

# ---------- case 1: create + submit concurrently in one transaction ----------
for i in $(seq 1 10); do
  psql -d "$DB" -X -q -A -t -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQL &
begin;
select set_config('janeiro.oid',
  (create_order('عميل سباق','$PHONE_A',null,'$PM'::uuid,$ITEMS,'conc-a-$i-'||md5(random()::text))->>'order_id'), false);
update orders set receipt_path='orders/x/$i.jpg', receipt_uploaded_at=now()
  where id = current_setting('janeiro.oid')::uuid;
select submit_order(current_setting('janeiro.oid')::uuid, null);
commit;
SQL
done
wait

ACTIVE_A=$(q "select count(*) from orders where normalized_phone='213${PHONE_A:1}' and status in ('pending_payment_review','payment_confirmed','activating','needs_info');")
MAXA=$(q "select coalesce(value::int,2) from store_settings where key='max_active_orders';")
[ "$ACTIVE_A" -le "$MAXA" ] || fail "10 concurrent create+submit produced $ACTIVE_A active orders (cap is $MAXA)"
[ "$ACTIVE_A" -ge 1 ] || fail "none of the 10 succeeded; the cap was not what stopped them"
pass "10 concurrent create+submit -> $ACTIVE_A active orders (cap $MAXA)"

# ---------- case 2: create separately, then submit all concurrently ----------
# This is the real-world shape: create, upload, submit are three
# separate requests, so the cap can only be enforced at submit time.
psql -d "$DB" -X -q -A -t >/dev/null <<SQL
do \$\$
declare v_id uuid; i int;
begin
  for i in 1..6 loop
    begin
      v_id := (create_order('عميل سباق','$PHONE_B',null,'$PM'::uuid,$ITEMS,'conc-b-'||i||'-'||md5(random()::text))->>'order_id')::uuid;
      update orders set receipt_path='orders/y/'||i||'.jpg', receipt_uploaded_at=now() where id=v_id;
    exception when others then null;  -- rate limiter may cut this short; that is fine
    end;
  end loop;
end \$\$;
SQL

PREPARED=$(q "select count(*) from orders where normalized_phone='213${PHONE_B:1}' and status='awaiting_receipt';")
[ "$PREPARED" -ge 3 ] || fail "only $PREPARED orders were prepared; nothing to race, so this case proves nothing"

for id in $(q "select id from orders where normalized_phone='213${PHONE_B:1}' and status='awaiting_receipt';"); do
  psql -d "$DB" -X -q -A -t -c "select submit_order('$id'::uuid,null);" >/dev/null 2>&1 &
done
wait

ACTIVE_B=$(q "select count(*) from orders where normalized_phone='213${PHONE_B:1}' and status in ('pending_payment_review','payment_confirmed','activating','needs_info');")
[ "$ACTIVE_B" -le "$MAXA" ] || fail "concurrent submits produced $ACTIVE_B active orders (cap is $MAXA)"
[ "$ACTIVE_B" -ge 1 ] || fail "no order survived the concurrent submits; the cap was not what stopped them"
pass "$PREPARED concurrent submits -> $ACTIVE_B active orders (cap $MAXA)"

# ---------- case 3: same idempotency key, fired concurrently ----------
# A double-click puts two identical requests in flight at once. Both miss
# the up-front replay lookup, so the loser hits the unique index. It must
# still come back as the same order, not as an error.
# Uses its own phone: a phone already at the cap would fail these creates
# for an unrelated reason and the race would never be exercised.
KEY="conc-idem-$(date +%s)-$RANDOM"
OUT=$(mktemp -d)
for i in 1 2 3 4; do
  psql -d "$DB" -X -q -A -t -c \
    "select create_order('عميل','$PHONE_C',null,'$PM'::uuid,$ITEMS,'$KEY')->>'order_id';" \
    >"$OUT/$i" 2>&1 &
done
wait
N=$(q "select count(*) from orders where idempotency_key='$KEY';")
[ "$N" -eq 1 ] || fail "4 concurrent creates with one idempotency key produced $N orders"

OID=$(q "select id from orders where idempotency_key='$KEY';")
SAME=$( { grep -l "^$OID$" "$OUT"/* 2>/dev/null || true; } | wc -l | tr -d ' ')
ERRS=$( { grep -l 'ERROR' "$OUT"/* 2>/dev/null || true; } | wc -l | tr -d ' ')
rm -rf "$OUT"
[ "$ERRS" -eq 0 ] || fail "$ERRS of 4 concurrent same-key creates errored; a double-click must not 500"
[ "$SAME" -eq 4 ] || fail "only $SAME of 4 concurrent same-key creates returned the shared order id"
pass "4 concurrent creates with one idempotency key -> 1 order, all 4 got its id"

# ---------- case 4: same order submitted twice concurrently ----------
# Timing alone will not reproduce this: whichever call starts second
# usually finds the order already moved and takes the early return. The
# bug only shows when both calls read the order BEFORE either updates it.
#
# submit_order reads the row first and only then takes an advisory lock on
# the customer's phone. So: hold that same lock from a third session, fire
# both calls (both read, both block), then release. Both resume having seen
# awaiting_receipt — the exact interleaving that used to send two Telegram
# messages for one order.
cleanup
OID=$(q "select create_order('عميل','$PHONE_A',null,'$PM'::uuid,$ITEMS,'dbl-$(date +%s)-$RANDOM')->>'order_id';")
q "update orders set receipt_path='orders/z/a.jpg', receipt_uploaded_at=now() where id='$OID';" >/dev/null

LOCKKEY="janeiro_orders_213${PHONE_A:1}"
psql -d "$DB" -X -q -A -t -c \
  "select pg_advisory_lock(hashtext('$LOCKKEY')::bigint); select pg_sleep(4);" >/dev/null 2>&1 &
BARRIER=$!
sleep 1                      # let the barrier session take the lock

OUT=$(mktemp -d)
for i in 1 2; do
  psql -d "$DB" -X -q -A -t -c \
    "select submit_order('$OID'::uuid,'REF-$i')->>'already_submitted';" >"$OUT/$i" 2>&1 &
done
sleep 1                      # both are now parked on the advisory lock
wait $BARRIER                # barrier session ends, lock released, both resume
wait

FIRSTS=$( { grep -h -c '^false$' "$OUT"/* 2>/dev/null || true; } | paste -sd+ | bc)
BLOCKED=$( { grep -h -c '^true$' "$OUT"/* 2>/dev/null || true; } | paste -sd+ | bc)
rm -rf "$OUT"
[ "$FIRSTS" -eq 1 ] || fail "double-submit reported $FIRSTS first-submitters (expected 1); Telegram would fire $FIRSTS times"
[ "$BLOCKED" -eq 1 ] || fail "double-submit reported $BLOCKED already-submitted replies (expected 1)"
REFKEPT=$(q "select payment_reference from orders where id='$OID';")
pass "barrier-forced double-submit -> 1 first-submitter, 1 replay, reference kept ($REFKEPT)"

cleanup
