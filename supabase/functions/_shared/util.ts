// ============================================================
// Janeiro Store — shared Edge Function helpers
// ============================================================
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

// Set ALLOWED_ORIGIN to your real domain in production
// (e.g. https://janeiro-store.com). "*" is fine while developing.
const ALLOWED_ORIGIN = Deno.env.get("ALLOWED_ORIGIN") ?? "*";

export const cors = {
  "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};

/** Service-role client. NEVER expose this key to a browser. */
export function serviceClient(): SupabaseClient {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json; charset=utf-8" },
  });
}

export function clientIp(req: Request): string {
  const fwd = req.headers.get("x-forwarded-for");
  return (fwd ? fwd.split(",")[0] : "").trim();
}

/**
 * Maps internal error codes to Arabic customer-facing messages.
 * Anything unrecognised becomes a generic message — we never leak
 * SQL text or stack traces to the browser.
 */
const MESSAGES: Record<string, string> = {
  ACTIVE_ORDER_LIMIT:
    "لديك طلبان قيد المعالجة بالفعل. انتظر اكتمال أو إلغاء أحدهما قبل إنشاء طلب جديد.",
  INVALID_PHONE: "رقم الهاتف غير صحيح. أدخل رقماً جزائرياً صالحاً.",
  INVALID_NAME: "الاسم غير صالح.",
  EMPTY_CART: "سلتك فارغة.",
  CART_TOO_LARGE: "عدد المنتجات في السلة كبير جداً.",
  INVALID_PAYMENT_METHOD: "طريقة الدفع غير متاحة.",
  PRODUCT_NOT_FOUND: "أحد المنتجات لم يعد متوفراً.",
  PRODUCT_NOT_PURCHASABLE: "أحد المنتجات غير متاح للشراء حالياً.",
  PLAN_NOT_FOUND: "الخطة المختارة لم تعد متوفرة.",
  PLAN_PRODUCT_MISMATCH: "بيانات الطلب غير متطابقة.",
  PLAN_INACTIVE: "الخطة المختارة لم تعد متاحة.",
  INVALID_QUANTITY: "الكمية غير صالحة.",
  MISSING_ACTIVATION_FIELD: "يرجى إكمال بيانات التفعيل المطلوبة.",
  INVALID_EMAIL_FIELD: "البريد الإلكتروني المدخل غير صحيح.",
  ACTIVATION_VALUE_TOO_LONG: "أحد الحقول طويل جداً.",
  RATE_LIMITED: "عدد المحاولات كبير. انتظر قليلاً ثم أعد المحاولة.",
  RECEIPT_REQUIRED: "يجب رفع وصل الدفع قبل تأكيد الطلب.",
  ORDER_NOT_FOUND: "لم نعثر على الطلب.",
  EMPTY_ORDER: "الطلب فارغ.",
  INVALID_TOTAL: "قيمة الطلب غير صالحة.",
  INVALID_TRACKING_INPUT: "تحقق من رقم الطلب ورقم هاتفك.",
  INVALID_FILE_TYPE: "الملف يجب أن يكون صورة JPG أو PNG أو WebP.",
  FILE_TOO_LARGE: "حجم الصورة يتجاوز 5 ميغابايت.",
  ORDER_ALREADY_SUBMITTED: "تم إرسال هذا الطلب مسبقاً.",
  CERTIFICATE_NOT_FOUND: "لم نعثر على شهادة بهذا الرمز.",
};

export function mapError(err: unknown): { code: string; message: string } {
  const raw = String((err as Error)?.message ?? err ?? "");
  // Postgres raises come through as "CODE" or "CODE:detail"
  const code = raw.split(":")[0].trim().replace(/[^A-Z_]/g, "");
  if (MESSAGES[code]) return { code, message: MESSAGES[code] };
  console.error("Unmapped error:", raw);
  return { code: "UNKNOWN", message: "حدث خطأ غير متوقع. حاول مرة أخرى." };
}

/** IP-level rate limit backed by the rate_limits table. */
export async function ipRateLimit(
  db: SupabaseClient, ip: string, action: string, max: number, minutes: number,
): Promise<boolean> {
  if (!ip) return true; // no IP available -> rely on phone-level limiting
  const { data, error } = await db.rpc("check_rate_limit", {
    p_key: `ip:${ip}`, p_action: action, p_max: max, p_window: `${minutes} minutes`,
  });
  if (error) { console.error("rate limit error", error); return true; }
  return data === true;
}
