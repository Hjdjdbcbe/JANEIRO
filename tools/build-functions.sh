#!/usr/bin/env bash
# ============================================================
# ينتج نسخة قائمة بذاتها من كل دالة (Edge Function)، بلا استيراد
# من ملفات أخرى، لتُلصق مباشرة في Supabase Dashboard → Edge
# Functions → New Function — بلا تثبيت أي أداة على جهازك.
#
#     bash tools/build-functions.sh
#
# الناتج: dist-functions/<اسم الدالة>.ts — أربعة ملفات.
#
# لماذا ملف واحد لكل دالة: الدوال الأربع تستورد من
# supabase/functions/_shared/util.ts، ومحرّر اللوحة يقبل كودك
# كما تلصقه دون أن يفهم هذا الاستيراد النسبي. فيُدمَج util.ts
# داخل كل دالة، وتُحذف سطور الاستيراد التي أصبحت زائدة.
#
# المصدر الحقيقي يبقى supabase/functions/ — لا تُعدّل الناتج هنا.
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=dist-functions
rm -rf "$OUT"; mkdir -p "$OUT"

SHARED=supabase/functions/_shared/util.ts

for fn in create-order upload-receipt submit-order track-order translate-content get-certificate; do
  src="supabase/functions/$fn/index.ts"
  out="$OUT/$fn.ts"

  {
    echo "// ============================================================"
    echo "// $fn — نسخة قائمة بذاتها، وُلِّدت آلياً من supabase/functions/."
    echo "// لا تُعدّلها هنا؛ عدّل المصدر ثم أعد التوليد."
    echo "// ============================================================"
    echo
    cat "$SHARED"
    echo
    echo "// ── $fn/index.ts ──────────────────────────────────────────"
    # يحذف سطر استيراد util.ts، وسطر استيراد SupabaseClient المنفصل
    # في submit-order (util.ts يجلبه بالفعل، واستيراده مرتين من نفس
    # الوحدة تصادم أسماء يرفضه Deno).
    grep -vE '^import .* from "\.\./_shared/util\.ts";$' "$src" \
      | grep -vE '^import type \{ SupabaseClient \} from "https://esm\.sh/@supabase/supabase-js@2\.45\.0";$'
  } > "$out"

  echo "  $fn.ts  ($(wc -l < "$out") سطراً)"
done

echo
echo "تُلصق كل واحدة في: Supabase Dashboard → Edge Functions → Deploy a new function"
echo "اسم الدالة يجب أن يطابق اسم الملف بالضبط (بلا .ts): create-order, upload-receipt, submit-order, track-order, translate-content, get-certificate"
