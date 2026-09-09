#!/usr/bin/env bash
# ============================================================
# يجهّز مشروع Supabase كاملاً بأمر واحد.
#
#     bash tools/setup-supabase.sh
#
# يقرأ إعداداتك من ملف .env.deploy بجانب هذا المستودع (مستثنى في
# .gitignore، لا يدخل git أبداً). انسخ .env.deploy.example وعبّئه.
#
# ما يفعله:
#   1. يربط المستودع بمشروعك
#   2. يدفع كل الهجرات
#   3. يضع الأسرار في Supabase Secrets — لا تُطبع ولا تُحفظ في ملف مرفوع
#   4. ينشر كل الدوال
#   5. يربط بوت المخزون بتليجرام (إن ملأت TELEGRAM_OWNER_ID)
#   6. يقول لك ما تبقّى عليك يدوياً
#
# لم يُشغَّل هذا الملف على مشروع حقيقي بعد: بيئة التطوير هنا لا تملك
# supabase CLI ولا مشروعاً ولا مفاتيحك. يوقف نفسه عند أول خطأ.
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

command -v supabase >/dev/null || {
  red "supabase CLI غير مثبّت."
  echo "  ثبّته من: https://supabase.com/docs/guides/local-development/cli/getting-started"
  exit 1; }

# يُفحص الآن لا عند استعماله: ربط الـwebhook آخر خطوة، وفشلها هناك
# يعني نشراً نصفه تمّ ونصفه لا.
command -v curl >/dev/null || {
  red "curl غير مثبّت — يحتاجه ربط بوت المخزون بتليجرام."
  exit 1; }

[ -f .env.deploy ] || {
  red "لا يوجد ملف .env.deploy"
  echo "  cp .env.deploy.example .env.deploy   ثم عبّئه"
  exit 1; }

# shellcheck disable=SC1091
set -a; . ./.env.deploy; set +a

: "${SUPABASE_PROJECT_REF:?ينقص SUPABASE_PROJECT_REF في .env.deploy}"
: "${SITE_URL:?ينقص SITE_URL في .env.deploy — عنوان متجرك، مثال https://janeiro.com}"

bold "==> 1/5 ربط المشروع ($SUPABASE_PROJECT_REF)"
supabase link --project-ref "$SUPABASE_PROJECT_REF"

bold "==> 2/5 دفع الهجرات"
supabase db push

bold "==> 3/5 الأسرار"
# ALLOWED_ORIGIN يقبل عنواناً واحداً وهو عنوان المتجر. اللوحة لا تستدعي
# الدوال أصلاً — تتكلم مع القاعدة مباشرة — فلا تحتاج إذناً هنا.
supabase secrets set "ALLOWED_ORIGIN=$SITE_URL" >/dev/null
green "    ALLOWED_ORIGIN = $SITE_URL"

# التوكن يُضبط وحده: يستعمله إشعارُ الطلبات وبوتُ المخزون معاً،
# وربطه بوجود CHAT_ID كان يترك البوت بلا توكن لمن أراد البوت دون
# إشعارات — فيردّ 503 على كل رسالة.
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  supabase secrets set "TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN" >/dev/null
  green "    توكن تيليغرام — مضبوط (لا يُطبع)"
else
  echo "    تيليغرام: بلا توكن. الطلبات ستُحفظ كاملة، لكن لن يصلك إشعار."
fi

if [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
  supabase secrets set "TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID" >/dev/null
  green "    chat_id الإشعارات — مضبوط"
fi

# بوت المخزون: يحتاج مالكاً وسرّ webhook. السرّ يُولَّد هنا إن لم
# تعطه، ويوضع في Supabase وفي تليجرام معاً — فلا حاجة لرؤيته أبداً.
BOT=no
if [ -n "${TELEGRAM_OWNER_ID:-}" ] && [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  BOT=yes
  # openssl ليس مضموناً على كل جهاز (ويندوز خصوصاً). البديل من
  # /dev/urandom يكفي تماماً هنا، وبلا الاثنين نطلب السرّ صراحةً
  # بدل الموت في منتصف نشرٍ بدأ فعلاً.
  if [ -n "${TELEGRAM_WEBHOOK_SECRET:-}" ]; then
    WEBHOOK_SECRET="$TELEGRAM_WEBHOOK_SECRET"
  elif command -v openssl >/dev/null; then
    WEBHOOK_SECRET=$(openssl rand -hex 32)
  elif [ -r /dev/urandom ]; then
    WEBHOOK_SECRET=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 64)
  else
    red "    لا openssl ولا /dev/urandom — ضع TELEGRAM_WEBHOOK_SECRET في .env.deploy بنفسك."
    exit 1
  fi
  supabase secrets set "TELEGRAM_OWNER_ID=$TELEGRAM_OWNER_ID" \
                       "TELEGRAM_WEBHOOK_SECRET=$WEBHOOK_SECRET" >/dev/null
  green "    بوت المخزون — المالك $TELEGRAM_OWNER_ID، والسرّ مضبوط (لا يُطبع)"
elif [ -n "${TELEGRAM_OWNER_ID:-}" ]; then
  red   "    بوت المخزون: TELEGRAM_OWNER_ID موجود لكن TELEGRAM_BOT_TOKEN فارغ — يُتخطّى."
else
  echo  "    بوت المخزون: متروك فارغاً (املأ TELEGRAM_OWNER_ID لتفعيله)."
fi

bold "==> 4/5 نشر الدوال"
for fn in create-order upload-receipt submit-order track-order \
          translate-content get-certificate; do
  printf '    %s\n' "$fn"
  supabase functions deploy "$fn"
done

bold "==> 5/5 بوت المخزون"
if [ "$BOT" = yes ]; then
  # --no-verify-jwt ضرورية: تليجرام لا يعرف مفاتيح Supabase ولن يرسل
  # Authorization. ما يحرس الدالة هو الترويسة السرّية أدناه.
  printf '    نشر telegram-bot\n'
  supabase functions deploy telegram-bot --no-verify-jwt

  printf '    ربط الـwebhook\n'
  HOOK_URL="https://$SUPABASE_PROJECT_REF.supabase.co/functions/v1/telegram-bot"
  RESP=$(curl -sS -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/setWebhook" \
    -H "Content-Type: application/json" \
    -d "{\"url\":\"$HOOK_URL\",
         \"secret_token\":\"$WEBHOOK_SECRET\",
         \"allowed_updates\":[\"message\",\"callback_query\"]}")
  case "$RESP" in
    *'"ok":true'*) green "    الـwebhook مربوط: $HOOK_URL" ;;
    # لا يُطبع RESP كما هو: ردّ تليجرام على الخطأ قد يعيد الرابط
    # وفيه التوكن.
    *) red "    فشل ربط الـwebhook. راجع docs/telegram-bot.md §5.5"
       echo "$RESP" | sed "s/$TELEGRAM_BOT_TOKEN/<TOKEN>/g" ;;
  esac
else
  echo "    متخطّى."
fi

echo
green "════════════════════════════════════════════════════"
green "  الخادم جاهز. بقي عليك ثلاثة أشياء في القاعدة:"
green "════════════════════════════════════════════════════"
cat <<'EOF'

  1) حساب الأدمن — سجّل بريدك في Supabase → Authentication → Add user،
     ثم في SQL Editor:

        insert into profiles (id, role)
        values ('UUID-المستخدم-هنا', 'admin')
        on conflict (id) do update set role = 'admin';

  2) رقم واتساب واسم المتجر:

        update store_settings set value = '213XXXXXXXXX' where key = 'whatsapp_number';
        update store_settings set value = 'Janeiro Store' where key = 'store_name';

  3) حسابات الدفع — بدونها يرى الزبون "لم تُضف بعد":

        update payment_methods set account_holder = 'الاسم واللقب',
                                   account_number = 'رقم الحساب',
                                   instructions   = 'تعليمات الدفع'
         where type = 'ccp';        -- ثم baridimob و flexy

  وإن نشرت بوت المخزون: افتحه في تليجرام وأرسل /start — تُفتح لك
  قائمة المالك تلقائياً. ثم اشحن الأكواد وأضف بائعيك:

        /addcards giftcard year
        CODE-1
        CODE-2

        /addadmin 987654321 محمد

     (الدليل كاملاً: docs/telegram-bot.md)

  ثم ابنِ الموقع وارفعه:

        SUPABASE_URL=https://xxxx.supabase.co \
        SUPABASE_ANON_KEY=eyJ... \
        bash tools/build-site.sh

EOF
