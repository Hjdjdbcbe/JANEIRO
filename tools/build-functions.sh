#!/usr/bin/env bash
# ============================================================
# ينتج نسخة قائمة بذاتها من كل دالة (Edge Function)، بلا استيراد
# من ملفات أخرى، لتُلصق مباشرة في Supabase Dashboard → Edge
# Functions → New Function — بلا تثبيت أي أداة على جهازك.
#
#     bash tools/build-functions.sh
#
# الناتج: dist-functions/<اسم الدالة>.ts — ملف لكل دالة.
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

# telegram-bot لا يستورد util.ts — بل i18n.ts وqr.ts. دمجُ util.ts
# فيه كان سيكرّر استيراد supabase-js من نفس الوحدة، وهو تصادم
# أسماء يرفضه Deno.
#
# والثلاثة تُدمج في ملف واحد: محرّر اللوحة يقبل ما تلصقه ولا يفهم
# استيراداً نسبياً، فملفان ناقصان = دالة لا تُقلع. ونسخة اللصق
# تُكتب كذلك في docs/ لأن dist-functions/ خارج git، والمالك ينسخ
# من GitHub لا من قرصه.
BOT_OUT="$OUT/telegram-bot.ts"
{
  echo "// ============================================================"
  echo "// telegram-bot — نسخة قائمة بذاتها، وُلِّدت آلياً من"
  echo "// supabase/functions/telegram-bot/ (index.ts + i18n.ts + qr.ts)."
  echo "// لا تُعدّلها هنا؛ عدّل المصدر ثم أعد التوليد بـ"
  echo "//     bash tools/build-functions.sh"
  echo "// ============================================================"
  echo
  echo 'import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";'
  echo
  echo "// ── i18n.ts ───────────────────────────────────────────────"
  # export يسقط: كل شيء صار في وحدة واحدة، وexport داخلها بلا معنى
  sed -E 's/^export (type|const|function|interface) /\1 /' \
    supabase/functions/telegram-bot/i18n.ts
  echo
  echo "// ── qr.ts ─────────────────────────────────────────────────"
  sed -E 's/^export (type|const|function|interface) /\1 /' \
    supabase/functions/telegram-bot/qr.ts
  echo
  echo "// ── index.ts ──────────────────────────────────────────────"
  grep -vE '^import .* from "\./(i18n|qr)\.ts";$' \
    supabase/functions/telegram-bot/index.ts \
    | grep -vE '^import type .* from "\./(i18n|qr)\.ts";$' \
    | grep -vE '^import \{ createClient, SupabaseClient \} from "https://esm\.sh/@supabase/supabase-js@2\.45\.0";$'
} > "$BOT_OUT"

cp "$BOT_OUT" docs/bot-function.ts
echo "  telegram-bot.ts  ($(wc -l < "$BOT_OUT") سطراً)  + docs/bot-function.ts"

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
echo "اسم الدالة يجب أن يطابق اسم الملف بالضبط (بلا .ts): create-order, upload-receipt, submit-order, track-order, translate-content, get-certificate, telegram-bot"
echo "و telegram-bot وحدها تُنشر بـ Verify JWT = مطفأ (تليجرام لا يرسل مفتاح Supabase)."
