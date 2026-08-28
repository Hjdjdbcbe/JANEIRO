#!/usr/bin/env bash
# ============================================================
# تشغيل Janeiro محلياً بأمر واحد.
#
#     bash run-locally.sh
#
# يبني قاعدة بيانات محلية، يطبّق الهجرات، يزرع بيانات تجريبية،
# ثم يشغّل خادماً يخدم الموقع واللوحة معاً على المنفذ 8808.
#
# ⚠️  هذه بيئة تجربة، ليست نشراً. البيانات محلية على جهازك،
#     والصور المرفوعة تُحفظ في مجلد assets/product-media لا في
#     تخزين Supabase. للنشر الحقيقي راجع README §النشر.
#
# يحتاج: PostgreSQL و Node.js مثبّتين ويعملان.
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

DB="${JANEIRO_TEST_DB:-janeiro_test}"
PORT="${PORT:-8808}"
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
red()  { printf '\033[31m%s\033[0m\n' "$*"; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }

# ---------- 1. المتطلبات ----------
command -v psql >/dev/null || { red "PostgreSQL غير مثبّت (الأمر psql غير موجود)."; exit 1; }
command -v node >/dev/null || { red "Node.js غير مثبّت (الأمر node غير موجود)."; exit 1; }
pg_isready -q || { red "خادم PostgreSQL لا يعمل. شغّله أولاً ثم أعد المحاولة."; exit 1; }

# ---------- 2. مكتبة pg ----------
if ! node -e "require('pg')" 2>/dev/null; then
  bold "==> تثبيت مكتبة pg"
  npm install --no-save --no-audit --no-fund pg >/dev/null
fi

# ---------- 3. قاعدة البيانات ----------
bold "==> بناء قاعدة البيانات $DB وتطبيق الهجرات"
bash tests/local/run-tests.sh >/dev/null 2>&1 || {
  red "فشل بناء قاعدة البيانات. شغّل هذا الأمر لرؤية السبب:"
  echo "    bash tests/local/run-tests.sh"
  exit 1
}

bold "==> زرع بيانات المتجر التجريبية (حساب أدمن، طرق دفع، عروض)"
psql -q -d "$DB" -f tests/frontend/fixtures.sql

# ---------- 4. المفاتيح ----------
# الموقع واللوحة يقرآن كلاهما config.js. محلياً يشيران إلى هذا الخادم.
for d in dashboard frontend; do
  if [ ! -f "$d/config.js" ]; then
    bold "==> كتابة $d/config.js (محلي)"
    printf 'window.JANEIRO_CONFIG = {\n  SUPABASE_URL: "http://127.0.0.1:%s",\n  SUPABASE_ANON_KEY: "local-mock",\n};\n' "$PORT" > "$d/config.js"
  fi
done

# ---------- 5. الخادم ----------
if lsof -ti :"$PORT" >/dev/null 2>&1; then
  bold "==> إيقاف خادم قديم على المنفذ $PORT"
  lsof -ti :"$PORT" | xargs -r kill 2>/dev/null || true
  sleep 1
fi

echo
green "════════════════════════════════════════════════════"
green "  المتجر    →  http://127.0.0.1:$PORT/frontend/index.html"
green "  اللوحة    →  http://127.0.0.1:$PORT/dashboard/index.html"
green ""
green "  دخول اللوحة:"
green "     البريد     admin@janeiro.test"
green "     كلمة المرور admin-pass-123"
green "════════════════════════════════════════════════════"
echo "  (بيانات تجريبية محلية فقط — ليست حساباً حقيقياً)"
echo "  أوقف الخادم بـ Ctrl+C"
echo

PGUSER="${PGUSER:-$(whoami)}" exec node tests/frontend/mock-supabase.js
