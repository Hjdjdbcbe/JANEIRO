// ============================================================
// POST /functions/v1/track-order
// body: { order_number, phone_last4 }
// Returns status + item names only. Never phone, receipt,
// activation data or payment account details.
// ============================================================
import { cors, json, serviceClient, clientIp, mapError, ipRateLimit } from "../_shared/util.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  const db = serviceClient();
  const ip = clientIp(req);

  try {
    // tighter limit here: this endpoint is the obvious brute-force target
    if (!(await ipRateLimit(db, ip, "track_order", 20, 10))) {
      return json({ ok: false, code: "RATE_LIMITED",
        message: "عدد المحاولات كبير. انتظر قليلاً ثم أعد المحاولة." }, 429);
    }

    const { order_number, phone_last4 } = await req.json();

    const { data, error } = await db.rpc("track_order", {
      p_order_number: String(order_number ?? "").slice(0, 30),
      p_phone_last4: String(phone_last4 ?? "").slice(0, 4),
    });

    if (error) {
      const m = mapError(error);
      // Deliberately identical response for "wrong number" and
      // "wrong phone" so the endpoint can't be used to enumerate orders.
      if (m.code === "ORDER_NOT_FOUND" || m.code === "INVALID_TRACKING_INPUT") {
        return json({ ok: false, code: "ORDER_NOT_FOUND",
          message: "لم نعثر على طلب بهذه البيانات. تحقق من رقم الطلب وآخر 4 أرقام من هاتفك." }, 404);
      }
      return json({ ok: false, ...m }, m.code === "RATE_LIMITED" ? 429 : 400);
    }

    return json({ ok: true, order: data });
  } catch (err) {
    const m = mapError(err);
    return json({ ok: false, ...m }, 500);
  }
});
