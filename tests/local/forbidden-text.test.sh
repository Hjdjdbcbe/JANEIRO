#!/usr/bin/env bash
# ============================================================
# عناوين ممنوعة: نصوص شائعة في نماذج شهادات الضمان في السوق.
# وثيقة Janeiro Store نصوصها أصلية، ولا تقتبس من أي نموذج.
#
#   bash tests/local/forbidden-text.test.sh
#
# يفشل إن ظهرت أي منها في أي ملف مصدر — فلا تعود بالغفلة في
# تعديل لاحق. هذا الملف نفسه مستثنى، وفيه القائمة.
# ============================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

FORBIDDEN=(
  "CERTIFICAT DE GARANTIE"
  "Conditions de garantie"
  "Numéro de commande"
  "Nom d'utilisateur"
  "Plateforme d'activation"
  "Code de garantie"
)

# النطاق: ملفات وثيقة الالتزام. الفرونت القديم (frontend/index.html)
# فيه عبارتان منها في ترجمة شهادة ضمان المتجر الفرنسية — سابقتان
# لهذه الفيتشر، ولا تُمسّان بلا قرار صاحب المتجر. فهو مستثنى هنا
# بوعي لا بغفلة: إن قُرّر تغييرهما يُحذف الاستثناء ويُصبح محروساً.
SCOPE=(
  supabase/migrations/025_service_engagement.sql
  supabase/functions/telegram-bot
  tests/engagement.test.sql
  docs
)
[ -e supabase/functions/telegram-bot/i18n.ts ] || true

bad=0
for phrase in "${FORBIDDEN[@]}"; do
  hits=$(grep -rIl --fixed-strings "$phrase" "${SCOPE[@]}" \
           --exclude-dir=.git --exclude-dir=.deno-cache \
           --exclude-dir=node_modules --exclude-dir=dist-functions \
           --exclude="forbidden-text.test.sh" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    red "FAIL: «$phrase» موجود في:"
    printf '  %s\n' $hits
    bad=1
  fi
done

if [ "$bad" = 0 ]; then
  green "PASS  لا عنوان من نماذج السوق في ملفات وثيقة الالتزام (${#FORBIDDEN[@]} عبارة)"
else
  red "استبدلها بنصوص Janeiro Store الأصلية."
  exit 1
fi
