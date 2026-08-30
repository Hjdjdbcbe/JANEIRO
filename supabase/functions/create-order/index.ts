// ============================================================
// POST /functions/v1/create-order
// Creates an awaiting_receipt order. Prices are recomputed
// server-side; anything price-like in the payload is ignored.
// ============================================================
import { cors, json, serviceClient, clientIp, mapError, ipRateLimit } from "../_shared/util.ts";

interface ItemIn {
  product_id: string;
  plan_id: string;
  quantity?: number;
  bundle_id?: string | null;
  activation?: { label: string; value: string }[];
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  const db = serviceClient();
  const ip = clientIp(req);

  try {
    if (!(await ipRateLimit(db, ip, "create_order", 15, 10))) {
      return json({ ok: false, code: "RATE_LIMITED",
        message: "عدد المحاولات كبير. انتظر قليلاً ثم أعد المحاولة." }, 429);
    }

    const body = await req.json();
    const {
      name, phone, wilaya, payment_method_id,
      items, idempotency_key,
    } = body as {
      name: string; phone: string; wilaya?: string;
      payment_method_id: string; items: ItemIn[]; idempotency_key: string;
    };

    if (!idempotency_key || String(idempotency_key).length < 8) {
      return json({ ok: false, code: "INVALID_REQUEST",
        message: "طلب غير صالح." }, 400);
    }
    if (!Array.isArray(items) || items.length === 0) {
      return json({ ok: false, code: "EMPTY_CART", message: "سلتك فارغة." }, 400);
    }

    // Strip everything except the fields the server is willing to accept.
    // Notably: no price, no total, no order_number, no status.
    const safeItems = items.slice(0, 20).map((i) => ({
      product_id: String(i.product_id),
      plan_id: String(i.plan_id),
      quantity: Math.max(1, Math.min(10, Number(i.quantity) || 1)),
      // The bundle this line claims to belong to. Only the id crosses:
      // the RPC reads the bundle's price, contents and availability
      // itself and refuses a group that is not whole. Anything
      // price-like about it is absent for the same reason نوع التفعيل
      // is -- the server would ignore it.
      bundle_id: i.bundle_id ? String(i.bundle_id).slice(0, 40) : null,
      activation: Array.isArray(i.activation)
        ? i.activation.slice(0, 10).map((a) => ({
            label: String(a.label ?? "").slice(0, 120),
            value: String(a.value ?? "").slice(0, 300),
          }))
        : [],
    }));

    const { data, error } = await db.rpc("create_order", {
      p_name: String(name ?? "").slice(0, 80),
      p_phone: String(phone ?? "").slice(0, 20),
      p_wilaya: wilaya ? String(wilaya).slice(0, 60) : null,
      p_payment_method: payment_method_id,
      p_items: safeItems,
      p_idempotency_key: String(idempotency_key).slice(0, 100),
      p_client_ip: ip || null,
    });

    if (error) {
      const m = mapError(error);
      const status = m.code === "ACTIVE_ORDER_LIMIT" ? 409
                   : m.code === "RATE_LIMITED" ? 429
                   : m.code === "UNKNOWN" ? 500 : 400;
      return json({ ok: false, ...m }, status);
    }

    return json({ ok: true, order: data });
  } catch (err) {
    const m = mapError(err);
    return json({ ok: false, ...m }, m.code === "UNKNOWN" ? 500 : 400);
  }
});
