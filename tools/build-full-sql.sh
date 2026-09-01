#!/usr/bin/env bash
# ============================================================
# يدمج كل الهجرات السبع عشرة في ملف SQL واحد، بالترتيب، ليُلصق
# دفعة واحدة في Supabase SQL Editor — بلا حاجة لتثبيت أي أداة.
#
#     bash tools/build-full-sql.sh
#
# الناتج: docs/full-setup.sql (لا تُعدّله يدوياً — أعد توليده بهذا
# السكربت، فالمصدر الحقيقي هو supabase/migrations/*.sql دائماً).
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=docs/full-setup.sql
{
  echo "-- ============================================================"
  echo "-- Janeiro Store — كل الهجرات مدمجة، وُلِّدت آلياً."
  echo "-- المصدر: supabase/migrations/*.sql — لا تُعدّل هذا الملف يدوياً."
  echo "-- الصقه كاملاً في Supabase SQL Editor واضغط Run، مرة واحدة."
  echo "-- ============================================================"
  echo
  for f in supabase/migrations/*.sql; do
    echo "-- ── $(basename "$f") ──────────────────────────────────────"
    cat "$f"
    echo
  done
} > "$OUT"

echo "wrote $OUT ($(wc -l < "$OUT") lines, $(du -h "$OUT" | cut -f1))"
