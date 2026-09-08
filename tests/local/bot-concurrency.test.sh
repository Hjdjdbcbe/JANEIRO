#!/usr/bin/env bash
# ============================================================
# بوت المخزون (021) تحت التزامن، باتصالات متوازية حقيقية.
#
#   bash tests/local/bot-concurrency.test.sh [dbname]
#
# ما يُختبر هنا لا يمكن اختباره داخل معاملة واحدة: بائعان
# يضغطان الزر في نفس اللحظة. الضمان المطلوب:
#   * لا يخرج كود بطاقة واحدة لبائعين
#   * لا يُباع أكثر مما في المخزون
#   * ضغطتان على «تأكيد» لا تنتجان بيعتين
# ============================================================
set -euo pipefail
DB="${1:-janeiro_test}"

OWNER=990000001
SELLERS=(990000101 990000102 990000103 990000104 990000105 990000106 990000107 990000108)
STOCK=5          # عدد البطاقات المتاحة
RACERS=8         # عدد الطالبين المتزامنين — أكثر من المخزون عمداً

fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*"; exit 1; }
pass() { printf '\033[32mPASS  %s\033[0m\n' "$*"; }
q() { psql -d "$DB" -X -A -t -q -c "$1"; }

cleanup() {
  q "delete from bot_issues where admin_id in (select id from bot_admins where telegram_id >= 990000000);" >/dev/null
  q "delete from bot_cards  where variant_id in (select id from bot_variants where code = 'race');" >/dev/null
  q "delete from bot_variants where code = 'race';" >/dev/null
  q "delete from bot_products where code = 'racetest';" >/dev/null
  q "delete from bot_admins where telegram_id >= 990000000;" >/dev/null
}
cleanup
trap cleanup EXIT

# ---------- setup ----------
q "select bot_bootstrap_owner($OWNER,'race_owner','مالك السباق');" >/dev/null
for s in "${SELLERS[@]}"; do q "select bot_add_admin($OWNER,$s,'بائع $s');" >/dev/null; done
q "select bot_add_product($OWNER,'racetest','منتج السباق');" >/dev/null
q "select bot_add_variant($OWNER,'racetest','race','مدة السباق');" >/dev/null
VAR=$(q "select id from bot_variants where code='race';")
CODES=$(python3 - "$STOCK" <<'PY'
import sys
print(",".join("'R-%03d'" % i for i in range(1, int(sys.argv[1]) + 1)))
PY
)
q "select bot_add_cards($OWNER,'$VAR'::uuid, array[$CODES]);" >/dev/null

# ---------- case 1: أكثر من طالب من مخزون محدود ----------
OUT=$(mktemp -d)
for s in "${SELLERS[@]}"; do
  ( psql -d "$DB" -X -A -t -q -c \
      "select bot_request_card($s,'$VAR'::uuid)->>'card_code';" 2>/dev/null \
      > "$OUT/$s.txt" || true ) &
done
wait

GOT=$(cat "$OUT"/*.txt | grep -v '^$' | sort)
N_GOT=$(printf '%s\n' "$GOT" | grep -c . || true)
N_UNIQ=$(printf '%s\n' "$GOT" | sort -u | grep -c . || true)
rm -rf "$OUT"

[ "$N_GOT" = "$STOCK" ]  || fail "$RACERS طالباً متزامناً من $STOCK بطاقات أنتجوا $N_GOT بطاقة"
[ "$N_UNIQ" = "$N_GOT" ] || fail "كود بطاقة خرج أكثر من مرة ($N_GOT خرجت، $N_UNIQ مختلفة)"
pass "$RACERS طلبات متزامنة على $STOCK بطاقات -> $N_GOT أكواد، كلها مختلفة"

LEFT=$(q "select count(*) from bot_cards where variant_id='$VAR'::uuid and status='available';")
RESV=$(q "select count(*) from bot_cards where variant_id='$VAR'::uuid and status='reserved';")
[ "$LEFT" = "0" ]      || fail "بقيت $LEFT بطاقة متاحة رغم نفاد المخزون"
[ "$RESV" = "$STOCK" ] || fail "$RESV محجوزة، والمتوقع $STOCK"
pass "المخزون بعد السباق: 0 متاحة، $RESV محجوزة"

# ولا بطاقة معلّقة في عمليتين
DUP=$(q "select count(*) from (select card_id from bot_issues where status='pending' group by card_id having count(*)>1) d;")
[ "$DUP" = "0" ] || fail "$DUP بطاقة معلّقة في أكثر من عملية"
pass "لا بطاقة معلّقة في عمليتين"

# ---------- case 2: ضغطتان على «تأكيد» لنفس العملية ----------
ISSUE=$(q "select id from bot_issues where status='pending' order by requested_at limit 1;")
SELLER=$(q "select a.telegram_id from bot_issues i join bot_admins a on a.id=i.admin_id where i.id='$ISSUE'::uuid;")
OUT=$(mktemp -d)
for i in 1 2 3 4 5; do
  ( psql -d "$DB" -X -A -t -q -c \
      "select bot_confirm_issue($SELLER,'$ISSUE'::uuid)->>'status';" 2>/dev/null \
      > "$OUT/$i.txt" || true ) &
done
wait
OKS=$(cat "$OUT"/*.txt | grep -c 'confirmed' || true)
rm -rf "$OUT"
[ "$OKS" = "1" ] || fail "5 تأكيدات متزامنة نجح منها $OKS (المتوقع 1)"

SALES=$(q "select count(*) from bot_issues where id='$ISSUE'::uuid and status='confirmed';")
SOLD=$(q "select count(*) from bot_cards c join bot_issues i on i.card_id=c.id where i.id='$ISSUE'::uuid and c.status='sold';")
[ "$SALES" = "1" ] || fail "العملية سُجّلت $SALES مرة"
[ "$SOLD"  = "1" ] || fail "البطاقة لم تُعلَّم مباعة"
pass "5 تأكيدات متزامنة -> بيعة واحدة، بطاقة واحدة مباعة"

# ---------- case 3: تأكيد وإلغاء في نفس اللحظة ----------
ISSUE=$(q "select id from bot_issues where status='pending' order by requested_at limit 1;")
SELLER=$(q "select a.telegram_id from bot_issues i join bot_admins a on a.id=i.admin_id where i.id='$ISSUE'::uuid;")
OUT=$(mktemp -d)
( psql -d "$DB" -X -A -t -q -c "select bot_confirm_issue($SELLER,'$ISSUE'::uuid)->>'status';" 2>/dev/null > "$OUT/c.txt" || true ) &
( psql -d "$DB" -X -A -t -q -c "select bot_cancel_issue($SELLER,'$ISSUE'::uuid)->>'status';"  2>/dev/null > "$OUT/x.txt" || true ) &
wait
WON=$(cat "$OUT"/*.txt | grep -v '^$' | grep -c . || true)
rm -rf "$OUT"
[ "$WON" = "1" ] || fail "تأكيد وإلغاء متزامنان نجح منهما $WON (المتوقع 1)"

STATE=$(q "select status from bot_issues where id='$ISSUE'::uuid;")
CARD=$(q "select c.status from bot_cards c join bot_issues i on i.card_id=c.id where i.id='$ISSUE'::uuid;")
case "$STATE:$CARD" in
  confirmed:sold|cancelled:available) : ;;
  *) fail "حالة غير متسقة بعد السباق: العملية=$STATE والبطاقة=$CARD" ;;
esac
pass "تأكيد وإلغاء متزامنان -> نتيجة واحدة متسقة ($STATE / $CARD)"

echo
printf '\033[32m%s\033[0m\n' "BOT CONCURRENCY TESTS PASSED"
