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
#   2. يدفع الهجرات الـ17 كلها
#   3. يضع الأسرار في Supabase Secrets — لا تُطبع ولا تُحفظ في ملف مرفوع
#   4. ينشر الدوال الأربع
#   5. يقول لك ما تبقّى عليك يدوياً
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

[ -f .env.deploy ] || {
  red "لا يوجد ملف .env.deploy"
  echo "  cp .env.deploy.example .env.deploy   ثم عبّئه"
  exit 1; }

# shellcheck disable=SC1091
set -a; . ./.env.deploy; set +a

: "${SUPABASE_PROJECT_REF:?ينقص SUPABASE_PROJECT_REF في .env.deploy}"
: "${SITE_URL:?ينقص SITE_URL في .env.deploy — عنوان متجرك، مثال https://janeiro.com}"

bold "==> 1/4 ربط المشروع ($SUPABASE_PROJECT_REF)"
supabase link --project-ref "$SUPABASE_PROJECT_REF"

bold "==> 2/4 دفع الهجرات"
supabase db push

bold "==> 3/4 الأسرار"
# ALLOWED_ORIGIN يقبل عنواناً واحداً وهو عنوان المتجر. اللوحة لا تستدعي
# الدوال أصلاً — تتكلم مع القاعدة مباشرة — فلا تحتاج إذناً هنا.
supabase secrets set "ALLOWED_ORIGIN=$SITE_URL" >/dev/null
green "    ALLOWED_ORIGIN = $SITE_URL"

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
  supabase secrets set "TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN" \
                       "TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID" >/dev/null
  green "    توكن تيليغرام و chat_id — مضبوطان (لا يُطبعان)"
else
  echo "    تيليغرام: متروك فارغاً. الطلبات ستُحفظ كاملة، لكن لن يصلك إشعار."
fi

bold "==> 4/4 نشر الدوال"
for fn in create-order upload-receipt submit-order track-order; do
  printf '    %s\n' "$fn"
  supabase functions deploy "$fn"
done

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

  ثم ابنِ الموقع وارفعه:

        SUPABASE_URL=https://xxxx.supabase.co \
        SUPABASE_ANON_KEY=eyJ... \
        bash tools/build-site.sh

EOF
