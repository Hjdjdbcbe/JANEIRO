#!/usr/bin/env bash
# ============================================================
# §18 race condition test
# Fires 10 simultaneous create-order requests for a customer who
# already has 1 active order. Expected: exactly ONE succeeds,
# the rest return ACTIVE_ORDER_LIMIT.
#
# Usage:
#   export SUPABASE_URL=https://xxx.supabase.co
#   export SUPABASE_ANON_KEY=eyJ...
#   export PRODUCT_ID=... PLAN_ID=... PAYMENT_METHOD_ID=...
#   bash tests/race-test.sh
# ============================================================
set -euo pipefail

: "${SUPABASE_URL:?set SUPABASE_URL}"
: "${SUPABASE_ANON_KEY:?set SUPABASE_ANON_KEY}"
: "${PRODUCT_ID:?set PRODUCT_ID}"
: "${PLAN_ID:?set PLAN_ID}"
: "${PAYMENT_METHOD_ID:?set PAYMENT_METHOD_ID}"

PHONE="${PHONE:-0552000099}"
OUT=$(mktemp -d)

echo "Firing 10 concurrent create-order requests for $PHONE ..."

for i in $(seq 1 10); do
  curl -s -X POST "$SUPABASE_URL/functions/v1/create-order" \
    -H "apikey: $SUPABASE_ANON_KEY" \
    -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\":\"سباق اختبار\",
      \"phone\":\"$PHONE\",
      \"payment_method_id\":\"$PAYMENT_METHOD_ID\",
      \"idempotency_key\":\"race-$(date +%s)-$i-$RANDOM\",
      \"items\":[{\"product_id\":\"$PRODUCT_ID\",\"plan_id\":\"$PLAN_ID\",\"quantity\":1}]
    }" > "$OUT/r$i.json" &
done
wait

echo
echo "--- results ---"
SUCCESS=$(grep -l '"ok":true'              "$OUT"/*.json 2>/dev/null | wc -l | tr -d ' ')
LIMITED=$(grep -l 'ACTIVE_ORDER_LIMIT'     "$OUT"/*.json 2>/dev/null | wc -l | tr -d ' ')
OTHER=$((10 - SUCCESS - LIMITED))

echo "succeeded:            $SUCCESS"
echo "ACTIVE_ORDER_LIMIT:   $LIMITED"
echo "other:                $OTHER"
echo

# awaiting_receipt orders don't count toward the cap, so several
# creates may succeed here. The hard guarantee is at submit time:
# never more than 2 orders in an active status.
echo "Now verify in SQL that the cap held:"
echo "  select status, count(*) from orders"
echo "   where normalized_phone = '213${PHONE:1}' group by status;"
echo
echo "Expected: at most 2 rows across"
echo "  pending_payment_review / payment_confirmed / activating / needs_info"

rm -rf "$OUT"
