/* Creates a product through the dashboard UI, publishes it, then buys it
   as a customer — the loop that proves the editor actually works. */
const { chromium } = require("playwright");
const zlib = require("zlib");

/* A real PNG, built here rather than committed as a fixture, so a test can
   ask for any size it needs -- square, oblong, tiny, huge -- and the bytes
   are genuinely PNG bytes with a genuine signature. */
function png(w, h) {
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body) >>> 0);
    return Buffer.concat([len, body, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;   // 8-bit RGBA
  const raw = Buffer.alloc(h * (1 + w * 4));
  for (let y = 0; y < h; y++) {
    const row = y * (1 + w * 4);
    raw[row] = 0;
    for (let x = 0; x < w; x++) {
      const o = row + 1 + x * 4;
      raw[o] = 108; raw[o + 1] = 53; raw[o + 2] = 255; raw[o + 3] = 255;
    }
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(raw)), chunk("IEND", Buffer.alloc(0)),
  ]);
}
let CRC;
function crc32(buf) {
  if (!CRC) {
    CRC = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
      CRC[n] = c;
    }
  }
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = CRC[(c ^ buf[i]) & 0xFF] ^ (c >>> 8);
  return c ^ -1;
}
const asFile = (name, mimeType, buffer) => ({ name, mimeType, buffer });
const BASE = process.env.BASE || "http://127.0.0.1:8808";
let fail = 0;
const check = (c, m) => { console.log(`${c ? "\x1b[32mPASS\x1b[0m" : "\x1b[31mFAIL\x1b[0m"}  ${m}`); if (!c) fail++; };

(async () => {
  const browser = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  const errs = [];
  const p = await browser.newPage({ viewport: { width: 390, height: 900 } });
  p.on("pageerror", e => errs.push(e.message));
  p.on("console", m => { if (m.type() === "error" && !/Failed to load|ERR_/.test(m.text())) errs.push(m.text()); });
  await p.addInitScript(b => { window.JANEIRO_CONFIG = { SUPABASE_URL: b, SUPABASE_ANON_KEY: "k" }; }, BASE);

  const slug = "test-editor-" + Date.now().toString(36);
  const PRICE = 3300;

  await p.goto(`${BASE}/dashboard/index.html`, { waitUntil: "networkidle" });
  await p.fill("#email", "admin@janeiro.test"); await p.fill("#pass", "admin-pass-123");
  await p.click("#loginBtn");
  await p.waitForSelector("#app:not(.hidden)", { timeout: 10000 });

  // ---------- the products tab lists the catalogue ----------
  await p.locator('#tabs .tab[data-v="products"]').click();
  await p.waitForSelector("#products .prow", { timeout: 10000 });
  const before = await p.locator("#products .prow").count();
  check(before > 0, `the products tab lists the catalogue (${before})`);
  const withPoster = await p.locator("#products .pthumb img").count();
  check(withPoster >= 3, `products with artwork show their poster (${withPoster})`);

  // ---------- a published product must be buyable ----------
  await p.click("#newProd");
  await p.waitForSelector("#editor:not(.hidden)");
  await p.fill('[data-f="name"]', "منتج من اللوحة");
  await p.fill('[data-f="slug"]', slug);
  await p.selectOption('[data-f="status"]', "published");
  await p.click("#saveProd");
  await p.waitForTimeout(900);
  check((await p.locator("#toast").innerText()).includes("خطة"),
        "publishing with no plan is refused, and says why");
  check(await p.locator("#editor").isVisible(), "the editor stays open so nothing typed is lost");

  // ---------- fill it in properly ----------
  await p.fill('[data-p="0"][data-k="name"]', "شهر واحد");
  await p.fill('[data-p="0"][data-k="price"]', String(PRICE));
  await p.fill('[data-f="short_description"]', "منتج أُنشئ من لوحة التحكم.");

  // an old price below the real price is a data error, caught before saving
  await p.fill('[data-p="0"][data-k="old_price"]', "1000");
  await p.click("#saveProd");
  await p.waitForTimeout(700);
  check((await p.locator("#toast").innerText()).includes("قبل الخصم"),
        "an old price below the price is refused");
  await p.fill('[data-p="0"][data-k="old_price"]', "");

  // features and an activation field
  await p.locator('[data-ft="0"]').fill("ميزة أولى");
  await p.locator('[data-add="requirements"]').click();
  await p.waitForTimeout(200);
  await p.fill('[data-r="0"][data-k="label"]', "البريد الإلكتروني للحساب");
  await p.selectOption('[data-r="0"][data-k="field_type"]', "email");

  await p.click("#saveProd");
  await p.waitForSelector("#products:not(.hidden)", { timeout: 10000 });
  await p.waitForTimeout(600);
  check(await p.locator("#products .prow").count() === before + 1,
        "the new product appears in the list");

  // ---------- reopening shows what was saved ----------
  await p.locator("#products .prow", { hasText: "منتج من اللوحة" }).first().click();
  await p.waitForSelector("#editor:not(.hidden)");
  check(await p.locator('[data-p="0"][data-k="price"]').inputValue() === String(PRICE),
        "the plan price round-trips");
  check(await p.locator('[data-r="0"][data-k="label"]').inputValue() === "البريد الإلكتروني للحساب",
        "the activation field round-trips");
  check(await p.locator('[data-f="slug"]').isDisabled(),
        "the slug is locked once saved — orders and links depend on it");

  // ---------- and a customer can actually buy it ----------
  const bought = await p.evaluate(async ([b, s, price]) => {
    const [prod] = await (await fetch(`${b}/rest/v1/products?select=*&slug=eq.${s}`)).json();
    if (!prod) return { err: "not visible to the public" };
    const [pm] = await (await fetch(`${b}/rest/v1/payment_methods?select=id&is_active=eq.true`)).json();
    const plan = prod.product_plans[0];
    const req = prod.product_requirements[0];
    const r = await (await fetch(`${b}/functions/v1/create-order`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name: "عميل", phone: "0563" + Math.floor(100000 + Math.random() * 899999),
        payment_method_id: pm.id, idempotency_key: "editor-buy-" + Date.now(),
        items: [{ product_id: prod.id, plan_id: plan.id, quantity: 1,
                  activation: [{ label: req.label, value: "buyer@example.com" }] }],
      }) })).json();
    return { ok: r.ok, total: r.order?.total, planPrice: plan.price,
             visible: true, fields: prod.product_requirements.length };
  }, [BASE, slug, PRICE]);

  check(bought.visible === true, "the published product is visible to customers");
  check(bought.ok === true, `a customer can order it${bought.err ? " -> " + bought.err : ""}`);
  check(Number(bought.total) === PRICE,
        `the price charged is the one typed in the editor (${bought.total} = ${PRICE})`);

  // ---------- archiving hides it without erasing the order ----------
  await p.goto(`${BASE}/dashboard/index.html`, { waitUntil: "networkidle" });
  await p.waitForSelector("#app:not(.hidden)", { timeout: 10000 });
  await p.locator('#tabs .tab[data-v="products"]').click();
  await p.waitForSelector("#products .prow");
  await p.locator("#products .prow", { hasText: "منتج من اللوحة" }).first().click();
  await p.waitForSelector("#editor:not(.hidden)");
  p.once("dialog", d => d.accept());
  await p.click("#archProd");
  await p.waitForTimeout(1200);
  const gone = await p.evaluate(async ([b, s]) =>
    (await (await fetch(`${b}/rest/v1/products?select=id&slug=eq.${s}`)).json()).length, [BASE, slug]);
  check(gone === 0, "an archived product leaves the shop");

  // ---------- brand icons ----------
  await p.locator('#tabs .tab[data-v="products"]').click();
  await p.waitForSelector("#products .prow", { timeout: 10000 });

  const notice = p.locator("#products .notice");
  check(await notice.count() === 1, "the products list names what still needs an icon");
  const noticeText = await notice.textContent().catch(() => "");
  const markers = await p.locator("#products .noicon").count();
  check(markers > 0, `each product without an icon is marked in the list (${markers})`);
  check(/بلا أيقونة/.test(noticeText) || /أيقونة/.test(noticeText),
        "the banner says what is missing and why it matters");

  // open a product that has no icon yet
  await p.locator("#products .prow", { has: p.locator(".noicon") }).first().click();
  await p.waitForSelector("#iconFile", { state: "attached", timeout: 8000 });

  const lastToast = () => p.locator("#toast").textContent();
  const tryIcon = async (file) => {
    await p.setInputFiles("#iconFile", file);
    await p.waitForTimeout(450);
    return (await lastToast()) || "";
  };

  /* Every rejection below has to actually reject. A validator that only
     ever passes is the failure mode worth testing for. */
  let t = await tryIcon(asFile("wide.png", "image/png", png(256, 128)));
  check(/مربّعة/.test(t), `non-square is refused: "${t.slice(0, 60)}"`);

  t = await tryIcon(asFile("tiny.png", "image/png", png(64, 64)));
  check(/صغيرة/.test(t), `below the minimum is refused: "${t.slice(0, 60)}"`);

  t = await tryIcon(asFile("huge.png", "image/png", png(1200, 1200)));
  check(/كبيرة/.test(t), `above the maximum is refused: "${t.slice(0, 60)}"`);

  // a text file renamed .png, announced as image/png -- the exact case
  // Content-Type sniffing waves through
  t = await tryIcon(asFile("fake.png", "image/png", Buffer.from("<script>alert(1)</script>", "utf8")));
  check(/ليس PNG/.test(t), `a renamed file is refused on its bytes, not its name: "${t.slice(0, 60)}"`);

  // an SVG, announced as PNG
  t = await tryIcon(asFile("mark.png", "image/png",
        Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"><script>1</script></svg>', "utf8")));
  check(/ليس PNG/.test(t), `an SVG in PNG clothing is refused: "${t.slice(0, 60)}"`);

  const stillEmpty = await p.locator("#iconTxt").textContent();
  check(/اختر/.test(stillEmpty), "after every rejection the field is still empty, nothing was stored");

  // ...and the valid one is accepted
  t = await tryIcon(asFile("icon.png", "image/png", png(256, 256)));
  check(/رُفعت/.test(t), `a square 256px PNG is accepted: "${t.slice(0, 60)}"`);
  const shown = await p.locator(".iconprev img").count();
  check(shown === 1, "the uploaded icon previews in the editor");

  const iconSlug = await p.inputValue("#f_slug");
  await p.click("#saveProd");
  await p.waitForSelector("#products:not(.hidden)", { timeout: 10000 });

  /* Reopening it is the real round trip: the path has to survive
     admin_upsert_product, the CHECK constraint, and admin_list_products
     before the editor can show it back. The module scope is not on
     window, so this reads what the UI actually renders. */
  await p.locator(`#products .prow[data-slug="${iconSlug}"]`).click();
  await p.waitForSelector("#iconFile", { state: "attached", timeout: 8000 });
  const savedPath = await p.locator(".card:has(#iconFile) .mono").textContent();
  check(savedPath.trim() === `products/icons/${iconSlug}.png`,
        `icon_path round-trips through the database: ${savedPath.trim()}`);
  await p.click("#edBack");
  await p.waitForSelector("#products:not(.hidden)", { timeout: 8000 });

  const markersAfter = await p.locator("#products .noicon").count();
  check(markersAfter === markers - 1,
        `the list stops flagging it once uploaded (${markers} -> ${markersAfter})`);

  check(errs.length === 0, `no JS errors${errs.length ? " -> " + errs.slice(0, 3).join(" | ") : ""}`);
  await p.close();
  await browser.close();
  console.log(fail ? `\n\x1b[31m${fail} FAILED\x1b[0m` : "\n\x1b[32mALL PRODUCT CHECKS PASSED\x1b[0m");
  process.exit(fail ? 1 : 0);
})();
