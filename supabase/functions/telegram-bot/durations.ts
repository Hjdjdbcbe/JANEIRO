/* ============================================================
   المدد — مصدر واحد
   ============================================================
   الأزرار المعروضة في أي مكان يُسأل فيه عن مدة، وحدودُ الإدخال
   اليدوي. القاعدة تتحقّق من المجالات نفسها (bot_set_variant_duration
   وقيود bot_certificates)، ولا تعيد القائمة: لو أعادتها لصار
   تبديلُ زرٍّ هجرةً.
   ============================================================ */

/** أزرار الأشهر. الشهران مثنّى في العربية — انظر i18n. */
export const MONTH_CHOICES = [1, 2, 3, 6, 12];

/** أيام الهدية المعروضة. «لا» هو الأغلب، فهو أوّلها. */
export const BONUS_CHOICES = [0, 7, 14];

/** المدة المخصّصة: أعداد صحيحة، بلا كسور. */
export const CUSTOM = {
  months: { min: 1, max: 60 },
  days:   { min: 1, max: 999 },
  bonus:  { min: 0, max: 90 },
} as const;

/** يقبل الأرقام العربية الشرقية كما يقبل اللاتينية. */
export function parseCount(raw: string): number | null {
  const s = raw.trim().replace(/[٠-٩]/g, (c) => String("٠١٢٣٤٥٦٧٨٩".indexOf(c)));
  if (!/^\d+$/.test(s)) return null;
  const n = Number(s);
  return Number.isSafeInteger(n) ? n : null;
}

/** داخل المجال أم لا — وبالرسالة التي تُقال للمستخدم. */
export function checkRange(
  n: number | null, range: { min: number; max: number },
): string | null {
  if (n === null) return "عدد صحيح فقط، بلا كسور.";
  if (n < range.min || n > range.max) return `من ${range.min} إلى ${range.max}.`;
  return null;
}
