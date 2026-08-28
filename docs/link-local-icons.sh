#!/usr/bin/env bash
# ============================================================
# ربط أيقونات العلامات المنسوخة يدوياً بقاعدة البيانات المحلية.
#
#     bash docs/link-local-icons.sh
#
# الرفع من اللوحة يفعل أمرين: يكتب الملف، ويضبط عمود icon_path عند
# الحفظ. إذا نسخت الملفات بنفسك فالأمر الأول تمّ والثاني لا — وبدون
# العمود لا يعرف الموقع أن الأيقونة موجودة.
#
# هذا السكربت يمشي على الملفات ويضبط العمود لكل منتج يطابق اسمه.
#
# الخطوات:
#   1. انسخ أيقوناتك إلى assets/product-media/products/icons/
#      باسم المنتج بالضبط:  canva-pro.png ، chatgpt-plus.png ...
#   2. شغّل هذا السكربت
#
# ⚠️  محلي فقط. الملفات هنا لا تصل إلى تخزين Supabase ولا إلى أي
#     موقع منشور.
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

DB="${JANEIRO_TEST_DB:-janeiro_test}"
DIR="assets/product-media/products/icons"
bold(){ printf '\033[1m%s\033[0m\n' "$*"; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

mkdir -p "$DIR"

shopt -s nullglob
files=("$DIR"/*.png "$DIR"/*.webp)
if [ ${#files[@]} -eq 0 ]; then
  yellow "لا ملفات في $DIR"
  echo
  bold "المعرّفات (slugs) التي يتوقّعها الموقع — سمِّ الملفات بها:"
  psql -d "$DB" -X -A -t -c \
    "select '   ' || slug || '.png   (' || name || ')' from products where archived_at is null order by sort_order"
  exit 0
fi

linked=0; skipped=0
for f in "${files[@]}"; do
  base="$(basename "$f")"
  slug="${base%.*}"
  ext="${base##*.}"
  # نفس القيد الموجود في الهجرة 013 — لو خالفه المسار رفضته قاعدة البيانات
  if ! [[ "$slug" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    yellow "  تجاوز $base — الاسم يجب أن يكون حروفاً صغيرة وأرقاماً وشرطات فقط"
    skipped=$((skipped+1)); continue
  fi
  n=$(psql -d "$DB" -X -A -t -c \
    "update products set icon_path='products/icons/${slug}.${ext}'
      where slug='${slug}' and archived_at is null returning 1" | wc -l)
  if [ "$n" -ge 1 ]; then
    green "  ✓ $base"; linked=$((linked+1))
  else
    yellow "  ✗ $base — لا يوجد منتج بالمعرّف '$slug'"
    skipped=$((skipped+1))
  fi
done

echo
bold "رُبطت $linked أيقونة."
[ "$skipped" -gt 0 ] && yellow "تُجوهلت $skipped."

missing=$(psql -d "$DB" -X -A -t -c \
  "select string_agg(slug, ', ' order by sort_order)
     from products where icon_path is null and archived_at is null")
if [ -n "$missing" ]; then
  echo
  yellow "ما زالت بلا أيقونة: $missing"
else
  echo; green "كل المنتجات لديها أيقونة."
fi
