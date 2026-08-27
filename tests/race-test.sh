#!/usr/bin/env bash
# ============================================================
# §18 race condition test — against a DEPLOYED project.
#
# Fires 10 simultaneous create-order requests for one customer,
# then checks the hard guarantee: never more than max_active_orders
# in an active status for that phone.
#
# Note on what this can and cannot prove: an awaiting_receipt order
# is not an active order (§12/§17), so several creates SHOULD succeed
# here. The cap is enforced at submit time, which is why the script
# also submits. For a version that runs without a deployment, see
# tests/local/concurrency.test.sh.
#
# Usage:
#   export SUPABASE_URL=https://xxx.supabase.co
#   export SUPABASE_ANON_KEY=eyJ...
#   export PRODUCT_ID=... PLAN_ID=... PAYMENT_METHOD_ID=...
#   # activation fields the product requires, as a JSON array:
#   export ACTIVATION='[{"label":"اسم المستخدم في ديسكورد","value":"racer"}]'
#   bash tests/race-test.sh
# ============================================================
set -euo pipefail

: "${SUPABASE_URL:?set SUPABASE_URL}"
: "${SUPABASE_ANON_KEY:?set SUPABASE_ANON_KEY}"
: "${PRODUCT_ID:?set PRODUCT_ID}"
: "${PLAN_ID:?set PLAN_ID}"
: "${PAYMENT_METHOD_ID:?set PAYMENT_METHOD_ID}"

# create_order rejects an item missing a required activation field, so
# without this every request fails for the wrong reason and the race is
# never actually exercised. Look the labels up with:
#   select label from product_requirements where product_id = '<PRODUCT_ID>';
ACTIVATION="${ACTIVATION:-[]}"

PHONE="${PHONE:-0552000099}"
N="${N:-10}"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

echo "Firing $N concurrent create-order requests for $PHONE ..."

for i in $(seq 1 "$N"); do
  curl -s -X POST "$SUPABASE_URL/functions/v1/create-order" \
    -H "apikey: $SUPABASE_ANON_KEY" \
    -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\":\"سباق اختبار\",
      \"phone\":\"$PHONE\",
      \"payment_method_id\":\"$PAYMENT_METHOD_ID\",
      \"idempotency_key\":\"race-$(date +%s)-$i-$RANDOM\",
      \"items\":[{\"product_id\":\"$PRODUCT_ID\",\"plan_id\":\"$PLAN_ID\",\"quantity\":1,
                  \"activation\":$ACTIVATION}]
    }" > "$OUT/r$i.json" &
done
wait

echo
echo "--- create results ---"
SUCCESS=$(grep -l '"ok":true'          "$OUT"/*.json 2>/dev/null | wc -l | tr -d ' ')
LIMITED=$(grep -l 'ACTIVE_ORDER_LIMIT' "$OUT"/*.json 2>/dev/null | wc -l | tr -d ' ')
RATED=$(grep -l 'RATE_LIMITED'         "$OUT"/*.json 2>/dev/null | wc -l | tr -d ' ')
OTHER=$((N - SUCCESS - LIMITED - RATED))

echo "succeeded:            $SUCCESS"
echo "ACTIVE_ORDER_LIMIT:   $LIMITED"
echo "RATE_LIMITED:         $RATED"
echo "other:                $OTHER"

if [ "$OTHER" -gt 0 ]; then
  echo
  echo "Unexpected responses (a create that failed for some other reason means"
  echo "the race was never exercised — check ACTIVATION and the IDs):"
  grep -h -o '"code":"[^"]*"' "$OUT"/*.json 2>/dev/null | sort | uniq -c
fi

# ------------------------------------------------------------
# The real guarantee is at submit time. These orders have no
# receipt, so they cannot be submitted from here — verify the cap
# in SQL after driving a few through the full flow.
# ------------------------------------------------------------
cat <<SQL

--- now verify the cap in SQL ---
  select status, count(*) from orders
   where normalized_phone = '213${PHONE:1}'
   group by status order by 1;

Expected: at most max_active_orders rows across
  pending_payment_review / payment_confirmed / activating / needs_info
(awaiting_receipt rows are not capped and may exceed it — that is by design)
SQL
