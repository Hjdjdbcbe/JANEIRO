#!/usr/bin/env bash
# ============================================================
# ينتج ملف SQL واحداً صغيراً يكفي لتشغيل بوت المخزون وحده،
# دون بقية المتجر — ليُلصق دفعة واحدة في Supabase SQL Editor.
#
#     bash tools/build-bot-sql.sh
#
# الناتج: docs/bot-setup.sql
#
# لماذا يوجد هذا بجانب docs/full-setup.sql: ذاك ينشر المتجر كاملاً
# (‏228 كيلوبايت)، وهذا ~800 سطر. من يريد البوت فقط — أو من يركّب
# من هاتفه ولصق ملف ضخم عنده عذاب — يلصق هذا.
#
# ما فيه: ما يعتمد عليه 021 من الهجرة 001 (pgcrypto، دالة
# set_updated_at، جدول store_settings)، ثم 021 كاملة. مأخوذ من
# الملفين نفسيهما لا منسوخاً بيدٍ، فلا يمكن أن يتخلّف عنهما.
#
# ملاحظة: لصق هذا على مشروع فيه المتجر أصلاً آمن — كل شيء فيه
# `if not exists` أو `or replace`، ولا يمسّ جدولاً قائماً.
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

CORE=supabase/migrations/001_core_schema.sql
OUT=docs/bot-setup.sql

# كل هجرات البوت بالترتيب، لا 021 وحدها. أول ما أُضيفت 022 بقي
# هذا الملف على 021 بصمت، فكان من ينشر من الصفر يأخذ نصف البوت.
BOT_MIGRATIONS=(supabase/migrations/*bot*.sql)
[ -e "${BOT_MIGRATIONS[0]}" ] || { echo "لا توجد هجرات بوت" >&2; exit 1; }

{
  echo "-- ============================================================"
  echo "-- Janeiro — بوت المخزون وحده. وُلِّد آلياً، لا تُعدّله يدوياً."
  echo "-- المصدر: $CORE + ${BOT_MIGRATIONS[*]}"
  echo "--"
  echo "-- الصقه كاملاً في Supabase → SQL Editor واضغط Run، مرة واحدة."
  echo "-- آمن على مشروع فيه المتجر أصلاً: لا ينشئ ما هو موجود."
  echo "-- ============================================================"
  echo
  echo "-- ── ما يحتاجه البوت من 001_core_schema.sql ────────────────"
  grep -m1 '^create extension if not exists "pgcrypto";' "$CORE"
  echo
  sed -n '/^-- ---------- shared updated_at trigger ----------$/,/^-- ---------- profiles/p' "$CORE" \
    | sed '$d'
  sed -n '/^-- ---------- store settings (key\/value) ----------$/,/^  for each row execute function set_updated_at();$/p' "$CORE"
  echo
  for m in "${BOT_MIGRATIONS[@]}"; do
    echo "-- ── $(basename "$m") ─────────────────────────────────────"
    cat "$m"
    echo
  done
} > "$OUT"

echo "wrote $OUT ($(wc -l < "$OUT") lines, $(du -h "$OUT" | cut -f1))"
