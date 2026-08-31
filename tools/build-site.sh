#!/usr/bin/env bash
# ============================================================
# يبني مجلّد dist/ الجاهز للرفع.
#
#     SUPABASE_URL=https://xxxx.supabase.co \
#     SUPABASE_ANON_KEY=eyJhbGci... \
#     bash tools/build-site.sh
#
# الناتج:
#     dist/index.html        ← المتجر، على جذر الدومين
#     dist/dashboard/        ← اللوحة، على /dashboard
#
# ما يفعله بالضبط:
#   • ينسخ الملفات ويصحّح مسار واحد: المتجر يستورد ../js/janeiro-api.js
#     لأنه داخل frontend/ في المستودع، وعلى جذر الموقع لا يوجد "أعلى".
#   • يكتب config.js للاثنين من متغيّرات البيئة — لا يُنسخ أي config.js
#     من المستودع، فمفاتيحك المحلية لا تُرفع بالخطأ.
#   • يضيف robots.txt يمنع فهرسة اللوحة في محركات البحث.
#
# المفتاح anon عام بالتصميم وتحميه RLS. مفتاح service_role
# و توكن تيليغرام لا يقتربان من هنا — مكانهما Supabase Secrets.
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SUPABASE_URL:?اضبط SUPABASE_URL — رابط مشروعك على Supabase}"
: "${SUPABASE_ANON_KEY:?اضبط SUPABASE_ANON_KEY — المفتاح العام anon}"

case "$SUPABASE_URL" in
  https://*.supabase.co) ;;
  http://127.0.0.1:*)    ;;   # للتحقق من ناتج البناء على الخادم المحلي
  *) echo "SUPABASE_URL يجب أن يكون مثل https://xxxx.supabase.co" >&2; exit 1 ;;
esac

rm -rf dist
mkdir -p dist/js dist/dashboard

# ---------- المتجر ----------
cp frontend/index.html dist/index.html
# المسار الوحيد الذي يتغيّر: المتجر ينزل من frontend/ إلى الجذر.
# لاحظ "./" — بدونها يصير "js/janeiro-api.js" مُعرّفاً مجرّداً
# (bare specifier) يرفضه المتصفح، فتُحمَّل الصفحة بخطوطها وصورتها
# ولا يعمل فيها شيء. حدث ذلك فعلاً وأُمسك بتشغيل الناتج.
sed -i 's#"\.\./js/janeiro-api\.js"#"./js/janeiro-api.js"#' dist/index.html
grep -q '"\./js/janeiro-api\.js"' dist/index.html || {
  echo "فشل تصحيح مسار janeiro-api.js — توقّف قبل بناء نسخة معطّلة" >&2; exit 1; }

cp js/janeiro-api.js dist/js/

# الأصول: ما تشير إليه الصفحة فعلاً، لا المجلد كله. مجلد assets يحمل
# بانرات قديمة لم تعد مستعملة، ونسخ PNG احتياطية لصور webp — نسخه
# كاملاً كان يرفع حجم ما تُحمّله من 1 ميغا إلى 12.
mapfile -t refs < <(grep -ohE 'assets/[A-Za-z0-9._/-]+' dist/index.html | sort -u)
for rel in "${refs[@]}"; do
  [ -f "frontend/$rel" ] || { echo "مرجع مفقود: $rel" >&2; exit 1; }
  mkdir -p "dist/$(dirname "$rel")"
  cp "frontend/$rel" "dist/$rel"
done
echo "  الأصول المنسوخة: ${#refs[@]} ملفاً"

# ---------- اللوحة ----------
cp dashboard/index.html          dist/dashboard/index.html
cp dashboard/activation-types.js dist/dashboard/activation-types.js

# ---------- المفاتيح ----------
write_config() {
  cat > "$1" <<EOF
/* مكتوب آلياً من tools/build-site.sh — لا تعدّله هنا. */
window.JANEIRO_CONFIG = {
  SUPABASE_URL: "${SUPABASE_URL}",
  SUPABASE_ANON_KEY: "${SUPABASE_ANON_KEY}",
};
EOF
}
write_config dist/config.js
write_config dist/dashboard/config.js

# ---------- محركات البحث ----------
cat > dist/robots.txt <<EOF
User-agent: *
Disallow: /dashboard/
EOF

# ---------- تنبيه لو تسرّب سرّ ----------
# يبحث عن مفتاح حقيقي لا عن الكلمة: الملفات تذكر "service_role" في
# تعليقاتها لتحذّر منه، والبحث عن الكلمة كان يوقف البناء على تحذير.
# القاعدة هنا: أي رمز JWT في dist يجب أن يكون مفتاح anon نفسه.
leaked=$(grep -rhoE 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}' dist 2>/dev/null \
         | sort -u | grep -vxF "$SUPABASE_ANON_KEY" || true)
if [ -n "$leaked" ]; then
  echo "توقّف: في dist/ مفتاح ليس مفتاح anon. لا ترفع هذا المجلد." >&2
  echo "  يبدأ بـ: $(echo "$leaked" | head -1 | cut -c1-24)…" >&2
  exit 1
fi
# وتوكن بوت تيليغرام له شكل معروف: أرقام ثم نقطتان ثم 35 حرفاً
if grep -rqE '[0-9]{8,10}:[A-Za-z0-9_-]{35}' dist 2>/dev/null; then
  echo "توقّف: يبدو أن توكن تيليغرام في dist/. لا ترفع هذا المجلد." >&2
  exit 1
fi

echo "تم البناء في dist/ ($(du -sh dist | cut -f1))"
echo "  المتجر  →  /"
echo "  اللوحة  →  /dashboard/"
