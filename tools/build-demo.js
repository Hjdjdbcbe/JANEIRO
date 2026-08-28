#!/usr/bin/env node
/* Builds a single self-contained HTML file of the storefront: the real
   page, the real stylesheet, the real application code, with the
   catalogue and every asset baked in so it runs with no server at all.
   For sharing a build someone can click through before it is deployed.

   Everything that reads goes through one function in janeiro-api.js
   (`rest`) and everything that writes goes through another (`callFn`), so
   only those two are swapped. The rendering code is untouched -- what you
   click in the demo is the code that ships.

     node tools/build-demo.js            # against a running mock on :8808
     BASE=http://... node tools/build-demo.js

   Ordering is simulated and says so: the confirmation carries a JNR-DEMO
   number and the page shows a standing notice. Nothing is sent anywhere. */
const fs = require("fs");
const path = require("path");

const BASE = process.env.BASE || "http://127.0.0.1:8808";
const ROOT = path.join(__dirname, "..");
/* --artifact strips the document skeleton: some hosts supply their own
   <html>/<head>/<body> and nest whatever you give them inside it, which
   would bury the lang and dir attributes the whole layout depends on. */
const ARTIFACT = process.argv.includes("--artifact");
const OUT = path.join(ROOT, "demo", ARTIFACT ? "janeiro-demo.artifact.html" : "janeiro-demo.html");

/* the exact queries the page issues, captured from a real page load */
const QUERIES = [
  "store_settings?select=key,value",
  "categories?select=id,name,slug,icon,icon_path,accent_color&is_active=eq.true&order=sort_order",
  "products?select=id,name,slug,short_description,accent_color,poster_path,thumbnail_path,icon_path," +
    "badge_type,badge_label,status,sort_order,warranty_type,warranty_days,warranty_label," +
    "categories(slug,name),product_plans(id,name,price,old_price,is_active,sort_order)" +
    "&status=in.(published,temporarily_unavailable,coming_soon)&archived_at=is.null&order=sort_order",
  "payment_methods?select=id,type,label,account_holder,account_number,extra_info,instructions" +
    "&is_active=eq.true&order=sort_order",
  "public_daily_deals?select=id,product_id,plan_id,deal_price,original_price,plan_name,product_slug," +
    "product_name,starts_at,ends_at,sort_order,server_now&order=sort_order",
];

const MIME = { ".webp":"image/webp", ".png":"image/png", ".jpg":"image/jpeg",
               ".jpeg":"image/jpeg", ".svg":"image/svg+xml", ".woff2":"font/woff2" };
const dataUri = (file) => {
  const b = fs.readFileSync(file);
  return `data:${MIME[path.extname(file)] || "application/octet-stream"};base64,${b.toString("base64")}`;
};

(async () => {
  // ---------- 1. the catalogue ----------
  const data = {};
  for (const q of QUERIES) {
    const r = await fetch(`${BASE}/rest/v1/${q}`, { headers: { apikey: "demo" } });
    if (!r.ok) throw new Error(`${q} -> ${r.status}`);
    data[q] = await r.json();
  }
  const products = data[QUERIES[2]];
  console.log(`  catalogue: ${products.length} products, ${data[QUERIES[1]].length} categories, ` +
              `${data[QUERIES[3]].length} payment methods, ${data[QUERIES[4]].length} deals`);

  // ---------- 2. every media path the catalogue references ----------
  const media = {};
  const want = new Set();
  for (const p of products) [p.poster_path, p.thumbnail_path, p.icon_path]
    .forEach(v => v && want.add(v));
  for (const c of data[QUERIES[1]]) c.icon_path && want.add(c.icon_path);
  for (const rel of want) {
    const f = path.join(ROOT, "assets/product-media", rel);
    if (fs.existsSync(f)) media[rel] = dataUri(f);
    else console.log(`  (no file for ${rel} -- the page falls back on its own)`);
  }
  console.log(`  media: ${Object.keys(media).length} files inlined`);

  // ---------- 3. the application code, with both transports swapped ----------
  let api = fs.readFileSync(path.join(ROOT, "js/janeiro-api.js"), "utf8");

  api = api.replace(/async function rest\(path\) \{[\s\S]*?\n\}/,
`async function rest(path) {
  if (!(path in DEMO_DATA)) throw new Error("demo: no snapshot for " + path);
  // structuredClone so a caller mutating a row cannot corrupt the snapshot
  return structuredClone(DEMO_DATA[path]);
}`);

  api = api.replace(/function publicMedia\(path\) \{[\s\S]*?\n\}/,
`function publicMedia(path) {
  return path ? (DEMO_MEDIA[path] ?? null) : null;
}`);

  // the write path: simulated, and unmistakably marked as such
  api = api.replace(/async function callFn\([\s\S]*?\n\}/,
`async function callFn(name, body) {
  await new Promise(r => setTimeout(r, 260));   // enough to see the pending state
  const S = (DEMO.orders ??= {});
  if (name === "create-order") {
    const prods = DEMO_DATA[DEMO_PRODUCTS_KEY];
    let total = 0;
    for (const it of body.items) {
      const p = prods.find(x => x.id === it.product_id);
      const pl = p && p.product_plans.find(x => x.id === it.plan_id);
      total += (pl ? Number(pl.price) : 0) * (it.quantity || 1);
    }
    const id = "demo-" + Math.random().toString(36).slice(2, 10);
    const num = "JNR-DEMO-" + Math.random().toString(36).slice(2, 6).toUpperCase();
    S[id] = { order_id: id, order_number: num, total, status: "awaiting_receipt",
              phone: body.phone, created_at: new Date().toISOString() };
    return { order: S[id] };
  }
  if (name === "submit-order") {
    const o = S[body.order_id];
    if (!o) { const e = new Error("لم نعثر على الطلب."); e.code = "ORDER_NOT_FOUND"; throw e; }
    o.status = "payment_review";
    return { order: o, whatsapp_number: DEMO_WHATSAPP };
  }
  if (name === "track-order") {
    const o = Object.values(S).find(x =>
      x.order_number === String(body.order_number || "").trim().toUpperCase() &&
      String(x.phone || "").slice(-4) === String(body.phone_last4 || ""));
    if (!o) { const e = new Error("لم نعثر على الطلب."); e.code = "ORDER_NOT_FOUND"; throw e; }
    return { order: { order_number: o.order_number, status: o.status,
                      created_at: o.created_at, total: o.total, items: [] } };
  }
  throw new Error("demo: unhandled function " + name);
}`);

  // the receipt upload is an XHR to a server that is not there
  api = api.replace(/export async function uploadReceipt\(orderId, file, onProgress\) \{/,
`export async function uploadReceipt(orderId, file, onProgress) {
  if (true) {   // demo: validate exactly as the real one does, then stop short of sending
    if (file.size > 5 * 1024 * 1024) {
      const e = new Error("حجم الصورة يتجاوز 5 ميغابايت."); e.code = "FILE_TOO_LARGE"; throw e;
    }
    if (!["image/jpeg", "image/png", "image/webp"].includes(file.type)) {
      const e = new Error("الملف يجب أن يكون صورة JPG أو PNG أو WebP."); e.code = "INVALID_FILE_TYPE"; throw e;
    }
    for (let i = 0; i <= 100; i += 20) { onProgress && onProgress(i); await new Promise(r => setTimeout(r, 60)); }
    return { ok: true, demo: true };
  }`);

  api = api.replace(/export function isConfigured\(\) \{[\s\S]*?\n\}/,
                    "export function isConfigured() { return true; }");
  api = api.replace(/^import .*$/gm, "");
  /* janeiro-api.js documents its own setup with a literal <script> tag in a
     comment. Pasted into the page, that tag CLOSES the module script early
     and the rest of the application becomes visible HTML text -- template
     literals and all. Neutralise every closer in anything being inlined. */
  api = api.replace(/<\/script/gi, "<\\/script");

  // ---------- 4. fold it into the page ----------
  let html = fs.readFileSync(path.join(ROOT, "frontend/index.html"), "utf8");

  const settings = Object.fromEntries(data[QUERIES[0]].map(r => [r.key, r.value]));
  const preamble =
    `const DEMO = {};\n` +
    `const DEMO_WHATSAPP = ${JSON.stringify(settings.whatsapp_number || "213000000000")};\n` +
    `const DEMO_PRODUCTS_KEY = ${JSON.stringify(QUERIES[2])};\n` +
    `const DEMO_DATA = ${JSON.stringify(data)};\n` +
    `const DEMO_MEDIA = ${JSON.stringify(media)};\n`;

  /* A FUNCTION replacement, never a string: $&, $\` and $' are special in a
     replacement string, and the code being injected is full of `${...}`. */
  const injected =
    `/* ---- demo build: the api module, inlined, with its transports swapped ---- */\n` +
    preamble + api + `\nconst API = { isConfigured, loadStoreSettings, loadCategories, loadProducts,\n` +
    `  loadProduct, loadPaymentMethods, loadDailyDeals, mediaUrl, newIdempotencyKey,\n` +
    `  createOrder, uploadReceipt, submitOrder, buildWhatsAppUrl, trackOrder, revalidateCart };\n`;
  html = html.replace('import * as API from "../js/janeiro-api.js";', () => injected);
  html = html.replace(/^\s*export (async function|function|const)/gm, "$1");

  // the config script cannot load from disk here
  html = html.replace(/<script src="config\.js"[^>]*><\/script>/,
    '<script>window.JANEIRO_CONFIG={SUPABASE_URL:"demo",SUPABASE_ANON_KEY:"demo"};</script>');

  // ---------- 5. inline every asset the page references ----------
  // href= too: the <link rel="preload"> tags point at the same files, and a
  // preload left pointing at a path that is not there throws CORS noise in
  // the console of a file:// build.
  const assetRe = /(?:src="|href="|url\()assets\/([^")]+)(?:"|\))/g;
  const seen = new Set();
  html = html.replace(assetRe, (m, rel) => {
    const f = path.join(ROOT, "frontend/assets", rel);
    if (!fs.existsSync(f)) { console.log(`  (missing asset ${rel})`); return m; }
    seen.add(rel);
    const uri = dataUri(f);
    if (m.startsWith("src="))  return `src="${uri}"`;
    if (m.startsWith("href=")) return `href="${uri}"`;
    return `url(${uri})`;
  });
  console.log(`  assets: ${seen.size} inlined (fonts, logo, hero artwork)`);

  // ---------- 6. say plainly that it is a demo ----------
  html = html.replace("</body>", `
<div id="demoTag" style="position:fixed;inset-block-end:calc(var(--s4) + env(safe-area-inset-bottom));
  inset-inline-start:var(--s4);z-index:95;background:var(--code-bg);color:#fff;
  font-family:var(--f-body);font-size:11.5px;font-weight:600;line-height:1.5;
  padding:8px 13px;border-radius:999px;box-shadow:var(--sh-3);max-width:min(78vw,320px)">
  معاينة — لا تُرسل طلبات فعلية
</div>
</body>`);

  if (ARTIFACT) {
    html = html
      .replace(/<!DOCTYPE html>\s*/i, "")
      .replace(/<html[^>]*>\s*/i, "")
      .replace(/<\/html>\s*$/i, "")
      .replace(/<\/?head>\s*/gi, "")
      .replace(/<body[^>]*>\s*/i, "")
      .replace(/<\/body>\s*/i, "");
    // RTL and the Arabic locale came off the <html> tag with it; put them back
    html = `<script>document.documentElement.lang="ar";document.documentElement.dir="rtl";</script>\n` + html;
  }

  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, html);
  console.log(`\n  wrote ${path.relative(ROOT, OUT)}  ${(fs.statSync(OUT).size / 1048576).toFixed(2)} MB`);
})();
