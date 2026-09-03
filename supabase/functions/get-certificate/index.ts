// ============================================================
// POST /functions/v1/get-certificate
// body: { code }
// Public, code-only lookup for a warranty certificate: the code
// itself is the credential (a 56-bit random token), so no phone or
// login is asked for -- the customer opens the link they were given
// and it just shows the document.
// ============================================================
import { cors, json, serviceClient, clientIp, mapError, ipRateLimit } from "../_shared/util.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  const db = serviceClient();
  const ip = clientIp(req);

  try {
    if (!(await ipRateLimit(db, ip, "get_certificate", 30, 10))) {
      return json({ ok: false, code: "RATE_LIMITED",
        message: "عدد المحاولات كبير. انتظر قليلاً ثم أعد المحاولة." }, 429);
    }

    const { code } = await req.json();

    const { data, error } = await db.rpc("get_certificate", {
      p_code: String(code ?? "").slice(0, 40),
    });

    if (error) {
      const m = mapError(error);
      return json({ ok: false, ...m }, m.code === "CERTIFICATE_NOT_FOUND" ? 404
        : m.code === "RATE_LIMITED" ? 429 : 400);
    }

    return json({ ok: true, certificate: data });
  } catch (err) {
    const m = mapError(err);
    return json({ ok: false, ...m }, 500);
  }
});
