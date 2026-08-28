/* Mock Supabase for local frontend verification.
   Serves the five PostgREST queries js/janeiro-api.js actually issues,
   plus the four Edge Function routes, backed by the real local Postgres.
   Not a PostgREST implementation -- just enough to prove the wiring. */
const http = require("http");
const fs = require("fs");
const path = require("path");
const { Pool } = require("pg");

const DB = process.env.MOCK_DB || "janeiro_test";
const ROOT = process.env.SITE_ROOT || "/home/user/JANEIRO";
const pool = new Pool({ database: DB, host: "/var/run/postgresql" });

const send = (res, code, body, type = "application/json; charset=utf-8") => {
  res.writeHead(code, { "Content-Type": type, "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" });
  res.end(typeof body === "string" || Buffer.isBuffer(body) ? body : JSON.stringify(body));
};

// Run a query as the anon role so RLS applies, exactly like PostgREST.
async function asAnon(sql, params = []) {
  const c = await pool.connect();
  try {
    await c.query("begin");
    await c.query("set local role anon");
    const r = await c.query(sql, params);
    await c.query("commit");
    return r.rows;
  } catch (e) { await c.query("rollback"); throw e; }
  finally { c.release(); }
}
const asService = (sql, params = []) => pool.query(sql, params).then(r => r.rows);

/* Runs as the `authenticated` role with request.jwt.claims set from the
   bearer token, which is what makes auth.uid() and therefore is_admin()
   work exactly as they do in production. Falls back to anon. */
async function asUser(sql, params = [], uid = null) {
  const c = await pool.connect();
  try {
    await c.query("begin");
    if (uid) {
      await c.query("select set_config('request.jwt.claims', $1, true)",
        [JSON.stringify({ sub: uid, role: "authenticated" })]);
      await c.query("set local role authenticated");
    } else {
      await c.query("set local role anon");
    }
    const r = await c.query(sql, params);
    await c.query("commit");
    return r.rows;
  } catch (e) { await c.query("rollback"); throw e; }
  finally { c.release(); }
}

/* The mock's token is just the user id. Real GoTrue issues a signed JWT;
   nothing here verifies signatures, so this stays a test harness. */
const uidFrom = (req) => {
  const h = req.headers.authorization || "";
  const t = h.replace(/^Bearer\s+/i, "").trim();
  return /^[0-9a-f-]{36}$/i.test(t) ? t : null;
};

const PRODUCT_EMBED = `
  select p.*,
    (select jsonb_build_object('slug',c.slug,'name',c.name)
       from categories c where c.id = p.category_id) as categories,
    coalesce((select jsonb_agg(jsonb_build_object(
        'id',pl.id,'name',pl.name,'price',pl.price,'old_price',pl.old_price,
        'is_active',pl.is_active,'sort_order',pl.sort_order) order by pl.sort_order)
      from product_plans pl where pl.product_id = p.id and pl.is_active), '[]'::jsonb) as product_plans,
    coalesce((select jsonb_agg(jsonb_build_object('label',f.label,'sort_order',f.sort_order) order by f.sort_order)
      from product_features f where f.product_id = p.id), '[]'::jsonb) as product_features,
    coalesce((select jsonb_agg(jsonb_build_object(
        'id',r.id,'label',r.label,'field_type',r.field_type,'placeholder',r.placeholder,
        'is_required',r.is_required,'sort_order',r.sort_order) order by r.sort_order)
      from product_requirements r where r.product_id = p.id), '[]'::jsonb) as product_requirements
  from products p`;

async function rest(url, res) {
  const table = url.pathname.replace("/rest/v1/", "");
  const q = url.searchParams;
  try {
    if (table === "store_settings")
      return send(res, 200, await asAnon("select key, value from store_settings"));
    if (table === "categories")
      return send(res, 200, await asAnon(
        "select id,name,slug,icon,icon_path,accent_color from categories where is_active order by sort_order"));
    if (table === "public_daily_deals")
      return send(res, 200, await asAnon(
        `select id, product_id, plan_id, deal_price, original_price, plan_name,
                product_slug, product_name, starts_at, ends_at, sort_order, server_now
           from public_daily_deals order by sort_order`));
    if (table === "payment_methods")
      return send(res, 200, await asAnon(
        `select id,type,label,account_holder,account_number,extra_info,instructions
           from payment_methods where is_active order by sort_order`));
    if (table === "products") {
      const slug = (q.get("slug") || "").replace("eq.", "");
      if (slug) return send(res, 200, await asAnon(`${PRODUCT_EMBED} where p.slug = $1 limit 1`, [slug]));
      return send(res, 200, await asAnon(
        `${PRODUCT_EMBED} where p.status in ('published','temporarily_unavailable','coming_soon')
           and p.archived_at is null order by p.sort_order`));
    }
    /* ---------- admin console reads ---------- */
    if (table === "orders") {
      const uid = q.get("__uid") || null;
      const id = (q.get("id") || "").replace("eq.", "");
      if (id) {
        const rows = await asUser(`
          select o.*,
            (select jsonb_build_object('label', pm.label, 'type', pm.type)
               from payment_methods pm where pm.id = o.payment_method_id) as payment_methods,
            coalesce((select jsonb_agg(jsonb_build_object(
                'product_name_snapshot', i.product_name_snapshot,
                'plan_name_snapshot', i.plan_name_snapshot,
                'quantity', i.quantity, 'unit_price', i.unit_price,
                'total_price', i.total_price,
                'warranty_label_snapshot', i.warranty_label_snapshot,
                'order_activation_data', coalesce((
                   select jsonb_agg(jsonb_build_object(
                     'field_label', a.field_label, 'field_value', a.field_value))
                     from order_activation_data a where a.order_item_id = i.id), '[]'::jsonb)))
              from order_items i where i.order_id = o.id), '[]'::jsonb) as order_items,
            coalesce((select jsonb_agg(jsonb_build_object(
                'old_status', h.old_status, 'new_status', h.new_status,
                'note', h.note, 'created_at', h.created_at))
              from order_status_history h where h.order_id = o.id), '[]'::jsonb) as order_status_history
          from orders o where o.id = $1`, [id], uid);
        return send(res, 200, rows);
      }
      const st = (q.get("status") || "").replace("eq.", "");
      const rows = await asUser(
        `select id, order_number, customer_name, customer_phone, status, total, currency, created_at
           from orders ${st ? "where status = $1::order_status" : ""}
          order by created_at desc limit 100`, st ? [st] : [], uid);
      return send(res, 200, rows);
    }
    if (table === "order_status_transitions") {
      const from = (q.get("from_status") || "").replace("eq.", "");
      return send(res, 200, await asUser(
        "select to_status from order_status_transitions where from_status = $1::order_status order by to_status",
        [from], q.get("__uid") || null));
    }
    return send(res, 404, { message: `no mock for ${table}` });
  } catch (e) { return send(res, 500, { message: String(e.message) }); }
}

/* PostgREST exposes RPCs under /rest/v1/rpc/<name>; these run as the
   caller so the functions' own is_admin() guards are what decide. */
async function adminRpc(name, req, res) {
  const uid = uidFrom(req);
  const body = JSON.parse((await readBody(req)).toString() || "{}");
  try {
    if (name === "admin_order_counts") {
      const rows = await asUser("select admin_order_counts() as r", [], uid);
      return send(res, 200, rows[0].r);
    }
    if (name === "admin_dashboard_stats") {
      const rows = await asUser("select admin_dashboard_stats() as r", [], uid);
      return send(res, 200, rows[0].r);
    }
    if (name === "admin_list_products") {
      const rows = await asUser("select admin_list_products() as r", [], uid);
      return send(res, 200, rows[0].r);
    }
    if (name === "admin_upsert_product") {
      const rows = await asUser("select admin_upsert_product($1::jsonb) as r",
                                [JSON.stringify(body.p_payload)], uid);
      return send(res, 200, rows[0].r);
    }
    if (name === "admin_archive_product") {
      const rows = await asUser("select admin_archive_product($1) as r", [body.p_slug], uid);
      return send(res, 200, rows[0].r);
    }
    if (name === "admin_update_order_status") {
      const rows = await asUser(
        "select admin_update_order_status($1::uuid, $2::order_status, $3) as r",
        [body.p_order_id, body.p_new_status, body.p_note ?? null], uid);
      return send(res, 200, rows[0].r);
    }
    return send(res, 404, { message: `no rpc ${name}` });
  } catch (e) {
    const raw = String(e.message || "");
    const code = raw.split(":")[0].trim();
    /* PostgREST answers 401/403 for a permission failure; the console
       relies on that to send the person back to the login screen. */
    if (code === "NOT_AUTHORIZED") return send(res, 403, { message: "غير مصرّح لك." });
    if (code === "ORDER_NOT_FOUND") return send(res, 404, { message: "لم نعثر على الطلب." });
    if (code.startsWith("INVALID_STATUS_TRANSITION"))
      return send(res, 400, { message: "هذه النقلة غير مسموحة من الحالة الحالية." });
    return send(res, 400, { message: raw });
  }
}

const MSG = {
  ACTIVE_ORDER_LIMIT: "لديك طلبان قيد المعالجة بالفعل.",
  INVALID_PHONE: "رقم الهاتف غير صحيح. أدخل رقماً جزائرياً صالحاً.",
  INVALID_NAME: "الاسم غير صالح.",
  RATE_LIMITED: "عدد المحاولات كبير. انتظر قليلاً ثم أعد المحاولة.",
  RECEIPT_REQUIRED: "يجب رفع وصل الدفع قبل تأكيد الطلب.",
  ORDER_NOT_FOUND: "لم نعثر على الطلب.",
  MISSING_ACTIVATION_FIELD: "يرجى إكمال بيانات التفعيل المطلوبة.",
  INVALID_EMAIL_FIELD: "البريد الإلكتروني المدخل غير صحيح.",
  INVALID_FILE_TYPE: "الملف يجب أن يكون صورة JPG أو PNG أو WebP.",
};
const mapErr = e => {
  const code = String(e.message || "").split(":")[0].trim().replace(/[^A-Z_]/g, "");
  return MSG[code] ? { code, message: MSG[code] } : { code: "UNKNOWN", message: "حدث خطأ غير متوقع." };
};

async function auth(url, req, res) {
  const body = JSON.parse((await readBody(req)).toString() || "{}");
  const rows = await asService(
    "select id, email from auth.users where email = $1 and password = $2",
    [body.email ?? "", body.password ?? ""]);
  if (!rows.length)
    return send(res, 400, { error: "invalid_grant", error_description: "بيانات الدخول غير صحيحة." });
  return send(res, 200, {
    access_token: rows[0].id, token_type: "bearer", expires_in: 3600,
    user: { id: rows[0].id, email: rows[0].email },
  });
}

function readBody(req) {
  return new Promise(r => { const c = []; req.on("data", d => c.push(d)); req.on("end", () => r(Buffer.concat(c))); });
}

async function fn(name, req, res) {
  const raw = await readBody(req);
  try {
    if (name === "create-order") {
      const b = JSON.parse(raw.toString());
      const items = (b.items || []).map(i => ({
        product_id: String(i.product_id), plan_id: String(i.plan_id),
        quantity: Math.max(1, Math.min(10, Number(i.quantity) || 1)),
        activation: Array.isArray(i.activation) ? i.activation : [],
      }));
      const rows = await asService(
        "select create_order($1,$2,$3,$4::uuid,$5::jsonb,$6,$7) as r",
        [b.name ?? "", b.phone ?? "", b.wilaya ?? null, b.payment_method_id,
         JSON.stringify(items), b.idempotency_key, "203.0.113.5"]);
      return send(res, 200, { ok: true, order: rows[0].r });
    }
    if (name === "upload-receipt") {
      // multipart: pull order_id and sniff the file bytes, like the real function
      const s = raw.toString("latin1");
      const oid = (s.match(/name="order_id"\r\n\r\n([^\r]+)/) || [])[1];
      const fileStart = s.indexOf("\r\n\r\n", s.indexOf('name="file"')) + 4;
      const bytes = Buffer.from(s.slice(fileStart, fileStart + 12), "latin1");
      const jpg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
      const png = bytes[0] === 0x89 && bytes[1] === 0x50;
      if (!jpg && !png) return send(res, 400, { ok: false, ...{ code: "INVALID_FILE_TYPE", message: MSG.INVALID_FILE_TYPE } });
      const r = await asService("select order_number, status from orders where id = $1", [oid]);
      if (!r.length) return send(res, 404, { ok: false, code: "ORDER_NOT_FOUND", message: MSG.ORDER_NOT_FOUND });
      await asService(
        "update orders set receipt_path = $2, receipt_uploaded_at = now() where id = $1",
        [oid, `orders/${r[0].order_number}/mock.${jpg ? "jpg" : "png"}`]);
      return send(res, 200, { ok: true, uploaded: true });
    }
    if (name === "submit-order") {
      const b = JSON.parse(raw.toString());
      const rows = await asService("select submit_order($1::uuid,$2) as r", [b.order_id, b.payment_reference ?? null]);
      const wa = await asService("select value from store_settings where key='whatsapp_number'");
      return send(res, 200, { ok: true, order: rows[0].r, whatsapp_number: wa[0]?.value ?? "" });
    }
    if (name === "track-order") {
      const b = JSON.parse(raw.toString());
      try {
        const rows = await asService("select track_order($1,$2) as r", [b.order_number ?? "", b.phone_last4 ?? ""]);
        return send(res, 200, { ok: true, order: rows[0].r });
      } catch (e) {
        const m = mapErr(e);
        if (m.code === "ORDER_NOT_FOUND" || m.code === "INVALID_TRACKING_INPUT")
          return send(res, 404, { ok: false, code: "ORDER_NOT_FOUND", message: "لم نعثر على طلب بهذه البيانات." });
        return send(res, 400, { ok: false, ...m });
      }
    }
    return send(res, 404, { ok: false, message: "no such function" });
  } catch (e) {
    const m = mapErr(e);
    return send(res, m.code === "ACTIVE_ORDER_LIMIT" ? 409 : m.code === "UNKNOWN" ? 500 : 400, { ok: false, ...m });
  }
}

const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
  ".png": "image/png", ".jpg": "image/jpeg", ".webp": "image/webp", ".svg": "image/svg+xml" };

/* Stands in for the public product-media bucket. Serves a tiny valid PNG
   for any path, except one containing "missing" so the frontend's
   onerror fallback can be exercised. */
const PNG_1PX = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
  "base64");
function storage(url, res) {
  if (url.pathname.includes("missing")) return send(res, 404, "not found", "text/plain");
  /* Serve the real artwork from assets/product-media when it is there,
     so the preview shows what the bucket will actually hold. */
  const rel = url.pathname.replace("/storage/v1/object/public/product-media/", "");
  const abs = path.join(ROOT, "assets/product-media", rel);
  if (abs.startsWith(path.join(ROOT, "assets/product-media")) && fs.existsSync(abs))
    return send(res, 200, fs.readFileSync(abs), TYPES[path.extname(abs)] || "image/png");
  send(res, 200, PNG_1PX, "image/png");
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  if (req.method === "OPTIONS") return send(res, 204, "");
  if (url.pathname === "/auth/v1/token") return auth(url, req, res);
  if (url.pathname.startsWith("/rest/v1/rpc/"))
    return adminRpc(url.pathname.replace("/rest/v1/rpc/", ""), req, res);
  if (url.pathname.startsWith("/storage/v1/object/sign/")) {
    const uid = uidFrom(req);
    const rows = await asUser("select is_admin() as ok", [], uid).catch(() => [{ ok: false }]);
    if (!rows[0]?.ok) return send(res, 403, { message: "غير مصرّح لك." });
    const path = url.pathname.replace("/storage/v1/object/sign/", "");
    return send(res, 200, { signedURL: `/object/public/product-media/${path}?token=mock` });
  }
  if (url.pathname.startsWith("/rest/v1/")) {
    url.searchParams.set("__uid", uidFrom(req) || "");
    return rest(url, res);
  }
  if (url.pathname.startsWith("/functions/v1/"))
    return fn(url.pathname.replace("/functions/v1/", ""), req, res);
  if (url.pathname.startsWith("/storage/v1/object/public/")) return storage(url, res);
  if (req.method === "POST" && url.pathname.startsWith("/storage/v1/object/product-media/")) {
    const uid = uidFrom(req);
    const ok = await asUser("select is_admin() as ok", [], uid).catch(() => [{ ok: false }]);
    if (!ok[0]?.ok) return send(res, 403, { message: "غير مصرّح لك." });
    const rel = url.pathname.replace("/storage/v1/object/product-media/", "");
    const abs = path.join(ROOT, "assets/product-media", rel);
    if (!abs.startsWith(path.join(ROOT, "assets/product-media")))
      return send(res, 400, { message: "bad path" });
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, await readBody(req));
    return send(res, 200, { Key: `product-media/${rel}` });
  }

  /* Test-only reset. The browser suites place real orders, and the
     2-active-order cap is real, so without this a second run of the
     same suite fails with ACTIVE_ORDER_LIMIT -- a test artefact that
     looks exactly like a product bug. */
  if (url.pathname === "/__test/reset") {
    /* Scoped on purpose. A blanket "delete from orders" also wiped the
       lifecycle orders fixtures.sql seeds, so whichever suite ran second
       found an empty queue and failed for the wrong reason. Fixture rows
       carry a seed- idempotency key and are left alone. */
    return asService(
      "delete from orders where idempotency_key not like 'seed-%'; delete from rate_limits;")
      .then(() => send(res, 200, { ok: true }))
      .catch(e => send(res, 500, { ok: false, message: String(e.message) }));
  }

  // static site
  let f = url.pathname === "/" ? "/frontend/index.html" : url.pathname;
  const abs = path.join(ROOT, f);
  if (!abs.startsWith(ROOT) || !fs.existsSync(abs)) return send(res, 404, "not found", "text/plain");
  send(res, 200, fs.readFileSync(abs), TYPES[path.extname(abs)] || "application/octet-stream");
}).listen(8808, () => console.log("mock supabase + site on http://127.0.0.1:8808"));
