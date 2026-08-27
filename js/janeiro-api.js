/* ============================================================
   Janeiro Store — API layer
   Replaces the hardcoded CATEGORIES / PRODUCTS arrays.

   Only the ANON key lives here. It is safe in a browser: every
   table is protected by RLS, and order creation goes through
   Edge Functions that hold the service role key server-side.
   ============================================================ */

/*
   Two ways to configure, in this order:

   1. Set window.JANEIRO_CONFIG before this module loads -- lets a
      deploy step inject the keys without editing a tracked file:

        <script>window.JANEIRO_CONFIG = { SUPABASE_URL:"...", SUPABASE_ANON_KEY:"..." }</script>

   2. Or fill the placeholders below.
*/
const PLACEHOLDER = {
  SUPABASE_URL: "__SUPABASE_URL__",       // e.g. https://xxxx.supabase.co
  SUPABASE_ANON_KEY: "__SUPABASE_ANON_KEY__",
};

const JANEIRO_CONFIG = {
  ...PLACEHOLDER,
  ...(typeof window !== "undefined" ? (window.JANEIRO_CONFIG || {}) : {}),
};

/** True once real keys are in place. The UI shows a setup message
    instead of firing doomed requests at "__SUPABASE_URL__". */
export function isConfigured() {
  const { SUPABASE_URL: u, SUPABASE_ANON_KEY: k } = JANEIRO_CONFIG;
  return Boolean(u && k && !u.startsWith("__") && !k.startsWith("__"));
}

const REST = () => `${JANEIRO_CONFIG.SUPABASE_URL}/rest/v1`;
const FN   = () => `${JANEIRO_CONFIG.SUPABASE_URL}/functions/v1`;
const HEAD = () => ({
  apikey: JANEIRO_CONFIG.SUPABASE_ANON_KEY,
  Authorization: `Bearer ${JANEIRO_CONFIG.SUPABASE_ANON_KEY}`,
  "Content-Type": "application/json",
});

async function rest(path) {
  const r = await fetch(`${REST()}/${path}`, { headers: HEAD() });
  if (!r.ok) {
    const err = new Error(`REST ${r.status}: ${await r.text()}`);
    err.code = `REST_${r.status}`;
    throw err;
  }
  return r.json();
}
async function callFn(name, body) {
  const r = await fetch(`${FN()}/${name}`, {
    method: "POST", headers: HEAD(), body: JSON.stringify(body),
  });
  const data = await r.json().catch(() => ({}));
  if (!r.ok || data.ok === false) {
    const err = new Error(data.message || "حدث خطأ غير متوقع.");
    err.code = data.code || "UNKNOWN";
    throw err;
  }
  return data;
}

/* ---------------- catalog ---------------- */

export async function loadStoreSettings() {
  const rows = await rest("store_settings?select=key,value");
  return Object.fromEntries(rows.map((r) => [r.key, r.value]));
}

export async function loadCategories() {
  return rest(
    "categories?select=id,name,slug,icon,icon_path,accent_color&is_active=eq.true&order=sort_order",
  );
}

/**
 * Live deals only. The view already filters by is_active and the
 * starts_at/ends_at window server-side, so an upcoming or expired deal
 * never reaches the browser.
 *
 * Every row carries server_now. The countdown uses it to measure the
 * browser's clock offset once, so a device with a wrong clock still
 * counts down to the real end time.
 */
export async function loadDailyDeals() {
  const rows = await rest(
    "public_daily_deals?select=id,product_id,plan_id,deal_price,original_price," +
    "plan_name,product_slug,product_name,starts_at,ends_at,sort_order,server_now" +
    "&order=sort_order",
  );
  return rows.map((r) => ({
    id: r.id,
    productId: r.product_id,
    planId: r.plan_id,
    price: Number(r.deal_price),
    originalPrice: Number(r.original_price),
    planName: r.plan_name,
    productSlug: r.product_slug,
    productName: r.product_name,
    endsAt: new Date(r.ends_at).getTime(),
    serverNow: new Date(r.server_now).getTime(),
    percentOff: Math.round((1 - Number(r.deal_price) / Number(r.original_price)) * 100),
  }));
}

/** Public URL for a file in the product-media bucket. */
export function mediaUrl(path) {
  return publicMedia(path);
}

export async function loadPaymentMethods() {
  return rest(
    "payment_methods?select=id,type,label,account_holder,account_number,extra_info,instructions" +
    "&is_active=eq.true&order=sort_order",
  );
}

/** Product list for the shop grid. */
export async function loadProducts() {
  const rows = await rest(
    "products?select=id,name,slug,short_description,accent_color,poster_path,thumbnail_path," +
    "badge_type,badge_label,status,sort_order,warranty_type,warranty_days,warranty_label," +
    "categories(slug,name),product_plans(id,name,price,old_price,is_active,sort_order)" +
    "&status=in.(published,temporarily_unavailable,coming_soon)" +
    "&archived_at=is.null&order=sort_order",
  );
  return rows.map(normalizeProduct);
}

/** Full detail for one product. */
export async function loadProduct(slug) {
  const rows = await rest(
    `products?select=*,categories(slug,name),` +
    `product_plans(id,name,price,old_price,is_active,sort_order),` +
    `product_features(label,sort_order),` +
    `product_requirements(id,label,field_type,placeholder,is_required,sort_order)` +
    `&slug=eq.${encodeURIComponent(slug)}&limit=1`,
  );
  if (!rows.length) throw new Error("PRODUCT_NOT_FOUND");
  return normalizeProduct(rows[0]);
}

/** Maps a database row onto the shape the existing UI already expects. */
function normalizeProduct(row) {
  const plans = (row.product_plans || [])
    .filter((p) => p.is_active)
    .sort((a, b) => a.sort_order - b.sort_order)
    .map((p) => ({ id: p.id, n: p.name, p: Number(p.price), old: p.old_price ? Number(p.old_price) : null }));

  return {
    id: row.id,
    slug: row.slug,
    name: row.name,
    cat: row.categories?.slug ?? null,
    catName: row.categories?.name ?? "",
    desc: row.short_description ?? "",
    description: row.description ?? "",
    accent: row.accent_color ?? "#7357FF",
    image: publicMedia(row.poster_path) || publicMedia(row.thumbnail_path) || null,
    poster: publicMedia(row.poster_path),
    thumbnail: publicMedia(row.thumbnail_path),
    badge: row.badge_type ?? null,
    badgeLabel: row.badge_label ?? null,
    available: row.status === "published",
    status: row.status,
    delivery: row.delivery_label ?? deliveryText(row),
    warranty: warrantyText(row),
    features: (row.product_features || [])
      .sort((a, b) => a.sort_order - b.sort_order).map((f) => f.label),
    fields: (row.product_requirements || [])
      .sort((a, b) => a.sort_order - b.sort_order)
      .map((r) => ({ id: r.id, l: r.label, ph: r.placeholder ?? "",
                     type: r.field_type, required: r.is_required })),
    plans,
    oldFrom: plans.find((p) => p.old)?.old ?? null,
  };
}

function publicMedia(path) {
  return path ? `${JANEIRO_CONFIG.SUPABASE_URL}/storage/v1/object/public/product-media/${path}` : null;
}

function deliveryText(row) {
  if (row.delivery_min == null && row.delivery_max == null) return "يُحدَّد عند الطلب";
  const unit = { minutes: "دقيقة", hours: "ساعة", days: "يوم" }[row.delivery_unit] ?? "";
  if (row.delivery_min != null && row.delivery_max != null)
    return `${row.delivery_min}–${row.delivery_max} ${unit}`;
  return `${row.delivery_min ?? row.delivery_max} ${unit}`;
}

/** Never invents a warranty that isn't in the data. */
function warrantyText(row) {
  switch (row.warranty_type) {
    case "subscription_duration": return "ضمان طوال مدة الاشتراك";
    case "days":       return `ضمان ${row.warranty_days} يوم`;
    case "activation": return "ضمان التفعيل";
    case "custom":     return row.warranty_label ?? "—";
    default:           return "—";
  }
}

/* ---------------- order flow ---------------- */

/** One key per checkout attempt — protects against double submits. */
export function newIdempotencyKey() {
  return (crypto.randomUUID?.() ?? `k-${Date.now()}-${Math.random().toString(36).slice(2)}`);
}

/**
 * Step 1 — create the awaiting_receipt order.
 * Note we send NO prices: the server computes them from the database.
 */
export async function createOrder({ name, phone, wilaya, paymentMethodId, items, idempotencyKey }) {
  const res = await callFn("create-order", {
    name, phone, wilaya,
    payment_method_id: paymentMethodId,
    items: items.map((i) => ({
      product_id: i.productId,
      plan_id: i.planId,
      quantity: i.qty,
      activation: i.activation ?? [],
    })),
    idempotency_key: idempotencyKey,
  });
  return res.order;
}

/** Step 2 — upload the receipt image. */
export async function uploadReceipt(orderId, file, onProgress) {
  if (file.size > 5 * 1024 * 1024) {
    const e = new Error("حجم الصورة يتجاوز 5 ميغابايت."); e.code = "FILE_TOO_LARGE"; throw e;
  }
  if (!["image/jpeg", "image/png", "image/webp"].includes(file.type)) {
    const e = new Error("الملف يجب أن يكون صورة JPG أو PNG أو WebP."); e.code = "INVALID_FILE_TYPE"; throw e;
  }

  const fd = new FormData();
  fd.append("order_id", orderId);
  fd.append("file", file);

  // XHR (not fetch) so we can report upload progress
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", `${FN()}/upload-receipt`);
    xhr.setRequestHeader("apikey", JANEIRO_CONFIG.SUPABASE_ANON_KEY);
    xhr.setRequestHeader("Authorization", `Bearer ${JANEIRO_CONFIG.SUPABASE_ANON_KEY}`);
    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable && onProgress) onProgress(Math.round((e.loaded / e.total) * 100));
    };
    xhr.onload = () => {
      let d = {}; try { d = JSON.parse(xhr.responseText); } catch { /* ignore */ }
      if (xhr.status >= 200 && xhr.status < 300 && d.ok) return resolve(d);
      const err = new Error(d.message || "تعذر رفع الوصل.");
      err.code = d.code || "UPLOAD_FAILED"; reject(err);
    };
    xhr.onerror = () => {
      const e = new Error("تعذر الاتصال بالخادم."); e.code = "NETWORK"; reject(e);
    };
    xhr.send(fd);
  });
}

/** Step 3 — final submission. Only after this is the order real. */
export async function submitOrder(orderId, paymentReference) {
  const res = await callFn("submit-order", {
    order_id: orderId, payment_reference: paymentReference || null,
  });
  return { order: res.order, whatsappNumber: res.whatsapp_number };
}

/** Built only AFTER the order is safely persisted. */
export function buildWhatsAppUrl(number, order, items, currency = "دج") {
  const lines = [
    "السلام عليكم، أكملت طلبي من Janeiro Store.", "",
    `رقم الطلب: ${order.order_number}`, "",
  ];
  items.forEach((i) => lines.push(`المنتج: ${i.name} — ${i.plan}`));
  lines.push("", `المبلغ: ${order.total} ${currency}`, "",
    "تم رفع وصل الدفع من الموقع.", "أريد متابعة طلبي.");
  return `https://wa.me/${number}?text=${encodeURIComponent(lines.join("\n"))}`;
}

/* ---------------- tracking ---------------- */

export async function trackOrder(orderNumber, phoneLast4) {
  const res = await callFn("track-order", {
    order_number: orderNumber, phone_last4: phoneLast4,
  });
  return res.order;
}

/* ---------------- cart price revalidation ---------------- */

/**
 * Compares cart prices against the live catalog before checkout so the
 * customer sees a price change instead of a confusing server rejection.
 */
export async function revalidateCart(cart, products) {
  const changes = [];
  for (const item of cart) {
    const p = products.find((x) => x.id === item.productId);
    if (!p) { changes.push({ item, reason: "removed" }); continue; }
    if (!p.available) { changes.push({ item, reason: "unavailable", product: p }); continue; }
    const plan = p.plans.find((pl) => pl.id === item.planId);
    if (!plan) { changes.push({ item, reason: "plan_removed", product: p }); continue; }
    if (Number(plan.p) !== Number(item.price)) {
      changes.push({ item, reason: "price_changed", product: p, oldPrice: item.price, newPrice: plan.p });
    }
  }
  return changes;
}
