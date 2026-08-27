// ============================================================
// POST /functions/v1/submit-order
// awaiting_receipt -> pending_payment_review, then notify Telegram.
//
// Telegram is best-effort: a failed notification never fails the
// order. The database is the source of truth.
// ============================================================
import { cors, json, serviceClient, clientIp, mapError, ipRateLimit } from "../_shared/util.ts";
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const TG_TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
const TG_CHAT  = Deno.env.get("TELEGRAM_CHAT_ID") ?? "";

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
             total, currency, payment_reference, status, submitted_at,
             payment_methods ( label )`)
    .eq("id", orderId).single();

  const { data: items } = await db
    .from("order_items")
    .select(`product_name_snapshot, plan_name_snapshot, quantity, total_price,
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
