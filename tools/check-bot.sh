#!/usr/bin/env bash
# ============================================================
# يفحص بوت المخزون بعد نشره ويقول أين الخلل بالضبط.
#
#     bash tools/check-bot.sh
#
# يقرأ .env.deploy إن وُجد، أو المتغيّرات من البيئة:
#   TELEGRAM_BOT_TOKEN, SUPABASE_PROJECT_REF, TELEGRAM_OWNER_ID
#   TELEGRAM_WEBHOOK_SECRET (اختياري — يفعّل الفحص الأخير الحيّ)
#
# لماذا يوجد: أشيع أعطال هذا النشر لا تُنتج رسالة خطأ في أي مكان —
# البوت ببساطة لا يردّ. هذا الملف يميّز بينها: الدالة غير منشورة،
# أو Verify JWT ما زال مشتعلاً، أو السرّ غير مضبوط، أو الـwebhook
# غير مربوط، أو مربوط على رابط خطأ.
#
# لا يطبع التوكن ولا السرّ في أي حال.
# ============================================================
set -uo pipefail
cd "$(dirname "$0")/.."

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

ok=0; bad=0
pass() { green "  ✅ $*"; ok=$((ok+1)); }
fail() { red   "  ❌ $*"; bad=$((bad+1)); }
hint() { dim   "     $*"; }

command -v curl >/dev/null || { red "curl غير مثبّت."; exit 1; }

if [ -f .env.deploy ]; then
  # shellcheck disable=SC1091
  set -a; . ./.env.deploy; set +a
fi

TOKEN="${TELEGRAM_BOT_TOKEN:-}"
REF="${SUPABASE_PROJECT_REF:-}"
OWNER="${TELEGRAM_OWNER_ID:-}"
SECRET="${TELEGRAM_WEBHOOK_SECRET:-}"

# يسمح للاختبار المحلي بتوجيه الفحص إلى دالة تعمل على الجهاز.
FN_URL="${BOT_FUNCTION_URL:-https://$REF.supabase.co/functions/v1/telegram-bot}"
API="${TELEGRAM_API_BASE:-https://api.telegram.org}"

echo
bold "==> 1/4 الإعدادات"
[ -n "$TOKEN" ] && pass "TELEGRAM_BOT_TOKEN موجود" || {
  fail "TELEGRAM_BOT_TOKEN ناقص"; hint "املأه في .env.deploy (من @BotFather)"; }
[ -n "$REF" ] || [ -n "${BOT_FUNCTION_URL:-}" ] && pass "SUPABASE_PROJECT_REF موجود" || {
  fail "SUPABASE_PROJECT_REF ناقص"; hint "من رابط مشروعك: dashboard/project/XXXX"; }
[ -n "$OWNER" ] && pass "TELEGRAM_OWNER_ID موجود" || {
  fail "TELEGRAM_OWNER_ID ناقص"; hint "راسل @userinfobot في تليجرام"; }
[ "$bad" -gt 0 ] && { echo; red "أكمل ما سبق ثم أعد الفحص."; exit 1; }

echo
bold "==> 2/4 البوت في تليجرام"
ME=$(curl -sS -m 20 "$API/bot$TOKEN/getMe" 2>/dev/null)
case "$ME" in
  *'"ok":true'*)
    USERNAME=$(printf '%s' "$ME" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p')
    pass "التوكن صالح — البوت @${USERNAME:-?}" ;;
  *'"error_code":401'*)
    fail "التوكن مرفوض من تليجرام"
    hint "انسخه من جديد من @BotFather (/mybots ← API Token)" ;;
  *)
    fail "لم أصل إلى تليجرام"
    hint "تحقّق من اتصالك بالإنترنت" ;;
esac

echo
bold "==> 3/4 الدالة على Supabase"
# طلب بلا الترويسة السرّية. الردّ المتوقّع 401 من الدالة نفسها —
# وهو دليل على أنها منشورة وحارسها يعمل.
BODY=$(curl -sS -m 25 -o /tmp/.botchk -w '%{http_code}' \
       -X POST "$FN_URL" -H "Content-Type: application/json" -d '{}' 2>/dev/null)
RESP=$(cat /tmp/.botchk 2>/dev/null); rm -f /tmp/.botchk
case "$BODY:$RESP" in
  401:forbidden*)
    pass "الدالة منشورة، والترويسة السرّية تحرسها" ;;
  503:*)
    fail "الدالة منشورة لكن TELEGRAM_WEBHOOK_SECRET غير مضبوط"
    hint "Supabase ← Edge Functions ← Secrets، أضف السرّ ثم أعد النشر"
    hint "أو: supabase secrets set TELEGRAM_WEBHOOK_SECRET=..." ;;
  40*:*Missing*authorization*|40*:*Invalid*JWT*|40*:*missing*JWT*)
    fail "Verify JWT ما زال مشتعلاً — تليجرام لا يمرّ منه أبداً"
    hint "أعد النشر بـ: supabase functions deploy telegram-bot --no-verify-jwt"
    hint "أو أطفئ Verify JWT من إعدادات الدالة في اللوحة" ;;
  404:*)
    fail "لا توجد دالة بهذا الاسم على المشروع"
    hint "الاسم يجب أن يكون telegram-bot بالضبط"
    hint "$FN_URL" ;;
  000:*)
    fail "لم أصل إلى الدالة إطلاقاً"
    hint "تأكّد أن SUPABASE_PROJECT_REF صحيح: $REF" ;;
  *)
    fail "ردّ غير متوقّع من الدالة (HTTP $BODY)"
    hint "$(printf '%s' "$RESP" | head -c 200)" ;;
esac

echo
bold "==> 4/4 ربط الـwebhook"
INFO=$(curl -sS -m 20 "$API/bot$TOKEN/getWebhookInfo" 2>/dev/null)
HOOK=$(printf '%s' "$INFO" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
ERR=$(printf '%s'  "$INFO" | sed -n 's/.*"last_error_message":"\([^"]*\)".*/\1/p')
PEND=$(printf '%s' "$INFO" | sed -n 's/.*"pending_update_count":\([0-9]*\).*/\1/p')

# تعذّر الوصول إلى تليجرام يُنتج رداً فارغاً، ورابطاً فارغاً معه.
# بلا هذا الفرق كان الفحص يقول «لا webhook مربوط» لمن انقطع
# إنترنته — تشخيص خاطئ يرسله يعيد ضبط شيء سليم أصلاً.
if ! printf '%s' "$INFO" | grep -q '"ok":true'; then
  fail "لم أصل إلى تليجرام لأسأله عن الـwebhook"
  hint "تحقّق من اتصالك بالإنترنت ثم أعد الفحص"
elif [ -z "$HOOK" ]; then
  fail "لا يوجد webhook مربوط — البوت لن يستقبل شيئاً"
  hint "افتح هذا الرابط في المتصفّح بعد وضع السرّ مكان <السرّ>:"
  hint "$API/bot<TOKEN>/setWebhook?url=$FN_URL&secret_token=<السرّ>"
elif [ "$HOOK" != "$FN_URL" ]; then
  fail "الـwebhook مربوط على رابط آخر"
  hint "المربوط: $HOOK"
  hint "المتوقّع: $FN_URL"
else
  pass "الـwebhook مربوط على الدالة الصحيحة"
fi

if [ -n "$ERR" ]; then
  fail "آخر محاولة من تليجرام فشلت: $ERR"
  hint "غالباً السرّ في تليجرام يخالف الذي في Supabase — أعد setWebhook بالسرّ نفسه"
fi
[ "${PEND:-0}" -gt 5 ] 2>/dev/null && {
  fail "$PEND تحديثاً عالقاً بلا معالجة"
  hint "الدالة ترفض ما يصلها — راجع الخطوة 3 أعلاه"; }

# ---------- الفحص الحيّ ----------
# يمرّ تحديثاً حقيقياً في المسار كاملاً: الدالة ← القاعدة ← تليجرام.
if [ -n "$SECRET" ] && [ "$bad" -eq 0 ]; then
  echo
  bold "==> فحص حيّ: تمرير رسالة /id في المسار كاملاً"
  LIVE=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST "$FN_URL" \
    -H "Content-Type: application/json" \
    -H "x-telegram-bot-api-secret-token: $SECRET" \
    -d "{\"message\":{\"message_id\":1,
         \"chat\":{\"id\":$OWNER},
         \"from\":{\"id\":$OWNER,\"first_name\":\"owner\"},
         \"text\":\"/id\"}}" 2>/dev/null)
  if [ "$LIVE" = "200" ]; then
    pass "الدالة قبلت التحديث"
    green "  📱 افتح تليجرام: يجب أن تكون وصلتك رسالة فيها رقمك الآن."
    dim   "     لم تصل؟ اضغط Start في البوت أولاً (تليجرام يمنع"
    dim   "     البوت من مراسلة من لم يبدأ معه) ثم أعد هذا الفحص."
  else
    fail "الدالة ردّت HTTP $LIVE على تحديث يحمل السرّ الصحيح"
    hint "السرّ في .env.deploy يخالف الذي في Supabase Secrets"
  fi
fi

echo
if [ "$bad" -eq 0 ]; then
  green "════════════════════════════════════════"
  green "  كل الفحوص مرّت ($ok). البوت جاهز."
  green "════════════════════════════════════════"
  echo "  افتحه وأرسل /start، ثم اشحن أكوادك:"
  echo "      /addcards giftcard year"
  echo "      CODE-1"
else
  red "$bad مشكلة. أصلحها بالترتيب من الأعلى ثم أعد الفحص."
  exit 1
fi
