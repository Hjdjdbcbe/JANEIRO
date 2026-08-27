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
        "select id,name,slug,icon,accent_color from categories where is_active order by sort_order"));
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
    return send(res, 404, { message: `no mock for ${table}` });
  } catch (e) { return send(res, 500, { message: String(e.message) }); }
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

const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8" };

http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  if (req.method === "OPTIONS") return send(res, 204, "");
  if (url.pathname.startsWith("/rest/v1/")) return rest(url, res);
  if (url.pathname.startsWith("/functions/v1/"))
    return fn(url.pathname.replace("/functions/v1/", ""), req, res);

  // static site
  let f = url.pathname === "/" ? "/frontend/index.html" : url.pathname;
  const abs = path.join(ROOT, f);
  if (!abs.startsWith(ROOT) || !fs.existsSync(abs)) return send(res, 404, "not found", "text/plain");
  send(res, 200, fs.readFileSync(abs), TYPES[path.extname(abs)] || "application/octet-stream");
}).listen(8808, () => console.log("mock supabase + site on http://127.0.0.1:8808"));
