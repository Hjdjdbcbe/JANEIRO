// ============================================================
// submit-order — نسخة قائمة بذاتها، وُلِّدت آلياً من supabase/functions/.
// لا تُعدّلها هنا؛ عدّل المصدر ثم أعد التوليد.
// ============================================================

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

// ── submit-order/index.ts ──────────────────────────────────────────
// ============================================================
// POST /functions/v1/submit-order
// awaiting_receipt -> pending_payment_review, then notify Telegram.
//
// Telegram is best-effort: a failed notification never fails the
// order. The database is the source of truth.
// ============================================================

/* The order alerts can come from their own bot, separate from the
   stock/sales bot (telegram-bot), which also reads TELEGRAM_BOT_TOKEN.
   ORDERS_BOT_TOKEN / ORDERS_CHAT_ID win when set; otherwise the shared
   names are used, as before. */
const TG_TOKEN = Deno.env.get("ORDERS_BOT_TOKEN") || Deno.env.get("TELEGRAM_BOT_TOKEN") || "";
const TG_CHAT  = Deno.env.get("ORDERS_CHAT_ID")   || Deno.env.get("TELEGRAM_CHAT_ID")   || "";

const STATUS_AR: Record<string, string> = {
  pending_payment_review: "مراجعة الدفع",
  payment_confirmed: "تم تأكيد الدفع",
  activating: "جاري التفعيل",
  needs_info: "نحتاج معلومات إضافية",
  completed: "مكتمل",
  cancelled: "ملغي",
  refunded: "تم الاسترجاع",
};

async function buildMessage(db: SupabaseClient, orderId: string): Promise<string> {
  const { data: o } = await db
    .from("orders")
    .select(`order_number, customer_name, customer_phone, customer_wilaya,
             total, currency, payment_reference, status, submitted_at, customer_note,
             payment_methods ( label )`)
    .eq("id", orderId).single();

  const { data: items } = await db
    .from("order_items")
    .select(`product_name_snapshot, plan_name_snapshot, quantity, total_price, activation_type,
             order_activation_data ( field_label, field_value )`)
    .eq("order_id", orderId);

  const lines: string[] = [];
  lines.push("🛒 طلب جديد — Janeiro Store", "");
  lines.push(`رقم الطلب: ${o?.order_number}`);
  lines.push(`العميل: ${o?.customer_name}`);
  lines.push(`الهاتف: ${o?.customer_phone}`);
  if (o?.customer_wilaya) lines.push(`الولاية: ${o.customer_wilaya}`);
  lines.push("", "المنتجات:");

  for (const it of items ?? []) {
    lines.push(`• ${it.product_name_snapshot}`);
    lines.push(`  الخطة: ${it.plan_name_snapshot}`);
    if (it.activation_type) lines.push(`  نوع التفعيل: ${it.activation_type}`);
    lines.push(`  الكمية: ${it.quantity}`);
    lines.push(`  السعر: ${it.total_price} ${o?.currency ?? "دج"}`);
    const act = (it as { order_activation_data?: { field_label: string; field_value: string }[] })
      .order_activation_data ?? [];
    for (const a of act) lines.push(`  ${a.field_label}: ${a.field_value}`);
    lines.push("");
  }

  lines.push(`الإجمالي: ${o?.total} ${o?.currency ?? "دج"}`);
  const pm = (o as { payment_methods?: { label?: string } } | null)?.payment_methods;
  lines.push(`الدفع: ${pm?.label ?? "—"}`);
  if (o?.payment_reference) lines.push(`رقم العملية: ${o.payment_reference}`);
  if (o?.customer_note) lines.push("", `رسالة العميل: ${o.customer_note}`);
  lines.push(`وقت الطلب: ${o?.submitted_at}`);
  lines.push(`الحالة: ${STATUS_AR[o?.status as string] ?? o?.status}`);

  return lines.join("\n");
}

async function notifyTelegram(db: SupabaseClient, orderId: string, orderNumber: string) {
  if (!TG_TOKEN || !TG_CHAT) {
    await db.from("order_notifications").insert({
      order_id: orderId, channel: "telegram", status: "failed",
      error_message: "TELEGRAM_NOT_CONFIGURED",
    });
    return;
  }

  try {
    const text = await buildMessage(db, orderId);
    const r = await fetch(`https://api.telegram.org/bot${TG_TOKEN}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: TG_CHAT, text }),
    });
    if (!r.ok) throw new Error(`sendMessage ${r.status}: ${await r.text()}`);

    // send the actual receipt image, not just its name
    const { data: order } = await db.from("orders")
      .select("receipt_path").eq("id", orderId).single();

    if (order?.receipt_path) {
      const { data: file } = await db.storage.from("receipts").download(order.receipt_path);
      if (file) {
        const fd = new FormData();
        fd.append("chat_id", TG_CHAT);
        fd.append("caption", `وصل الدفع — ${orderNumber}`);
        fd.append("photo", file, `${orderNumber}.jpg`);
        const p = await fetch(`https://api.telegram.org/bot${TG_TOKEN}/sendPhoto`, {
          method: "POST", body: fd,
        });
        if (!p.ok) throw new Error(`sendPhoto ${p.status}: ${await p.text()}`);
      }
    }

    await db.from("order_notifications").insert({
      order_id: orderId, channel: "telegram", status: "sent",
    });
  } catch (err) {
    console.error("telegram failed", err);
    await db.from("order_notifications").insert({
      order_id: orderId, channel: "telegram", status: "failed",
      error_message: String((err as Error).message ?? err).slice(0, 1000),
    });
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  const db = serviceClient();
  const ip = clientIp(req);

  try {
    if (!(await ipRateLimit(db, ip, "submit_order", 15, 10))) {
      return json({ ok: false, code: "RATE_LIMITED",
        message: "عدد المحاولات كبير. انتظر قليلاً ثم أعد المحاولة." }, 429);
    }

    const { order_id, payment_reference } = await req.json();
    if (!order_id) {
      return json({ ok: false, code: "INVALID_REQUEST", message: "طلب غير صالح." }, 400);
    }

    const { data, error } = await db.rpc("submit_order", {
      p_order_id: order_id,
      p_payment_reference: payment_reference ? String(payment_reference).slice(0, 60) : null,
    });

    if (error) {
      const m = mapError(error);
      const status = m.code === "ACTIVE_ORDER_LIMIT" ? 409
                   : m.code === "UNKNOWN" ? 500 : 400;
      return json({ ok: false, ...m }, status);
    }

    // Order is safely persisted at this point. Notify without blocking
    // the customer's response.
    if (!data.already_submitted) {
      const bg = notifyTelegram(db, data.order_id, data.order_number);
      // deno-lint-ignore no-explicit-any
      (globalThis as any).EdgeRuntime?.waitUntil?.(bg) ?? await bg;
    }

    // WhatsApp number comes from the database, not from the frontend
    const { data: setting } = await db
      .from("store_settings").select("value").eq("key", "whatsapp_number").single();

    return json({ ok: true, order: data, whatsapp_number: setting?.value ?? "" });
  } catch (err) {
    const m = mapError(err);
    return json({ ok: false, ...m }, m.code === "UNKNOWN" ? 500 : 400);
  }
});
