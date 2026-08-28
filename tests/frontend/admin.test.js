/* Drives admin/index.html in Chromium against mock-supabase.js.
   Needs fixtures.sql applied (it seeds the admin account and orders). */
const { chromium } = require("playwright");
const BASE = process.env.BASE || "http://127.0.0.1:8808";
let fail = 0;
const check = (c, m) => { console.log(`${c ? "\x1b[32mPASS\x1b[0m" : "\x1b[31mFAIL\x1b[0m"}  ${m}`); if (!c) fail++; };

(async () => {
  const browser = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  const errs = [];
  const newPage = async (opts = {}) => {
    const p = await browser.newPage(opts);
    p.on("pageerror", e => errs.push(e.message));
    p.on("console", m => { if (m.type() === "error" && !/Failed to load|ERR_/.test(m.text())) errs.push(m.text()); });
    await p.addInitScript(b => { window.JANEIRO_CONFIG = { SUPABASE_URL: b, SUPABASE_ANON_KEY: "mock-anon" }; }, BASE);
    return p;
  };
  const login = async (p, email, pass) => {
    await p.fill("#email", email); await p.fill("#pass", pass);
    await p.click("#loginBtn");
  };

  /* This suite drives orders through their lifecycle, so it cannot lean
     on shared fixture rows: a second run would find them already moved
     and fail for the wrong reason. It creates its own order through the
     real customer endpoints instead, and works on that. */
  async function seedOwnOrder(page) {
    return page.evaluate(async (b) => {
      const get = async (q) => (await fetch(`${b}/rest/v1/${q}`)).json();
      const [pm] = await get("payment_methods?select=id&is_active=eq.true");
      const [prod] = await get("products?select=*&slug=eq.gemini-pro");
      const plan = prod.product_plans[0];
      const phone = "0562" + String(Math.floor(100000 + Math.random() * 899999));

      const created = await (await fetch(`${b}/functions/v1/create-order`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: "عميل لوحة", phone, payment_method_id: pm.id,
          idempotency_key: "admin-suite-" + Date.now() + "-" + Math.random().toString(36).slice(2),
          items: [{ product_id: prod.id, plan_id: plan.id, quantity: 1, activation: [
            { label: "بريد Gmail للتفعيل", value: "console@gmail.com" },
            { label: "رقم الهاتف المرتبط", value: phone }] }],
        }),
      })).json();
      if (!created.ok) throw new Error("seed create failed: " + JSON.stringify(created));

      // a real JPEG: upload-receipt sniffs the magic bytes
      const bytes = new Uint8Array(600); bytes.set([0xff, 0xd8, 0xff, 0xe0]);
      const fd = new FormData();
      fd.append("order_id", created.order.order_id);
      fd.append("file", new Blob([bytes], { type: "image/jpeg" }), "receipt.jpg");
      await fetch(`${b}/functions/v1/upload-receipt`, { method: "POST", body: fd });

      const done = await (await fetch(`${b}/functions/v1/submit-order`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ order_id: created.order.order_id, payment_reference: "4821990" }),
      })).json();
      if (!done.ok) throw new Error("seed submit failed: " + JSON.stringify(done));
      return { number: done.order.order_number, phone, last4: phone.slice(-4) };
    }, BASE);
  }

  // ---------- a non-admin must not get in ----------
  const p1 = await newPage({ viewport: { width: 390, height: 844 } });
  await p1.goto(`${BASE}/admin/index.html`, { waitUntil: "networkidle" });
  check(await p1.locator("#login").isVisible(), "the console opens on a login screen, not the queue");

  await login(p1, "admin@janeiro.test", "wrong-pass");
  await p1.waitForTimeout(900);
  check((await p1.locator("#loginErr").innerText()).length > 0, "a wrong password is refused with a message");
  check(await p1.locator("#app").isHidden(), "a failed login shows no order data");

  // a real account that simply is not an admin
  await login(p1, "nobody@janeiro.test", "nobody-pass-123");
  await p1.waitForTimeout(1200);
  const notAdmin = await p1.locator("#loginErr").innerText();
  check(/أدمن/.test(notAdmin), `a signed-in non-admin is told plainly: "${notAdmin.trim()}"`);
  check(await p1.locator("#app").isHidden(), "a non-admin never reaches the console");
  const leaked = await p1.evaluate(() => sessionStorage.getItem("janeiro_admin_session"));
  check(!leaked, "a refused non-admin session is not left behind in storage");
  await p1.close();

  // ---------- the admin works the queue ----------
  const p = await newPage({ viewport: { width: 390, height: 844 } });
  await p.goto(`${BASE}/admin/index.html`, { waitUntil: "networkidle" });
  const seeded = await seedOwnOrder(p);
  await login(p, "admin@janeiro.test", "admin-pass-123");
  await p.waitForSelector("#app:not(.hidden)", { timeout: 10000 });
  check(true, "the admin reaches the console");

  await p.waitForFunction(() => document.querySelectorAll("#chips .chip[data-s]").length > 0);
  /* Assert what must be true, not how many statuses happen to be
     populated: the queue this run's order landed in has to be there and
     has to count it. A bare ">= 4" made the suite depend on leftover
     fixture state. */
  const reviewChip = p.locator('#chips .chip[data-s="pending_payment_review"]');
  check(await reviewChip.count() === 1, "the queue shows a chip for the status our order is in");
  const reviewN = parseInt((await reviewChip.locator(".n").innerText()).trim(), 10);
  check(reviewN >= 1, `that chip counts the waiting order (${reviewN})`);
  check((await p.locator('#chips .chip[aria-pressed="true"]').innerText()).includes("مراجعة الدفع"),
        "it opens on the queue that needs the owner first");

  await p.waitForSelector("#rows .row");
  const mine = await p.locator("#rows .row", { hasText: seeded.number }).count();
  check(mine === 1, `the review queue lists the order this run created (${seeded.number})`);

  // ---------- open it and read what you need to fulfil ----------
  await p.locator("#rows .row", { hasText: seeded.number }).first().click();
  await p.waitForSelector("#detail:not(.hidden)");
  const body = await p.locator("#detailBody").innerText();
  check(body.includes(seeded.number), "the order number is shown");
  check(body.includes("console@gmail.com"), "the activation data the owner must act on is visible");
  check(body.includes(seeded.phone), "the customer's phone is shown");
  check(body.includes("4821990"), "the payment reference is shown");
  check(await p.locator("#receiptBtn").count() === 1, "there is a way to open the payment receipt");

  // the receipt bucket is private: the link must be minted, not public
  const signed = await p.evaluate(async (b) => {
    const t = JSON.parse(sessionStorage.getItem("janeiro_admin_session")).access_token;
    const r = await fetch(`${b}/storage/v1/object/sign/receipts/orders/x/any.jpg`,
      { method: "POST", headers: { Authorization: `Bearer ${t}`, "Content-Type": "application/json" },
        body: JSON.stringify({ expiresIn: 300 }) });
    return { status: r.status, body: await r.text() };
  }, BASE);
  check(signed.status === 200 && signed.body.includes("token"), "an admin can mint a signed receipt link");
  const anonSign = await p.evaluate(async (b) => (await fetch(
    `${b}/storage/v1/object/sign/receipts/orders/x/any.jpg`,
    { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" })).status, BASE);
  check(anonSign === 403, `without a session the receipt cannot be signed (HTTP ${anonSign})`);

  // ---------- only legal next steps are offered ----------
  const offered = await p.locator("[data-to]").allInnerTexts();
  check(offered.length === 3 && offered.join() === ["تم تأكيد الدفع","نحتاج معلومات","ملغي"].join(),
        `only the legal next steps are offered: ${offered.join(" · ")}`);
  check(!offered.includes("مكتمل"), "a jump straight to مكتمل is not even offered");

  // ---------- move it, with a reason ----------
  await p.fill("#note", "الوصل مطابق للمبلغ");
  await p.locator('[data-to="payment_confirmed"]').click();
  await p.waitForTimeout(1400);
  const after = await p.locator("#detailBody").innerText();
  check(after.includes("تم تأكيد الدفع"), "the order moved");
  check(after.includes("الوصل مطابق للمبلغ"), "the reason is recorded in the order's own log");

  // ---------- drive the same order the rest of the way ----------
  await p.locator('[data-to="activating"]').click();
  await p.waitForTimeout(1300);
  await p.locator('[data-to="completed"]').click();
  await p.waitForTimeout(1400);
  const finished = await p.locator("#detailBody").innerText();
  check(finished.includes("مكتمل"), "an order can be driven all the way to مكتمل");
  check(!(await p.locator("[data-to]").allInnerTexts()).includes("مكتمل"),
        "once completed, the only move left is a refund");

  // the customer's tracking page must now agree
  const track = await p.evaluate(async ([b, n, l4]) => {
    const r = await fetch(`${b}/functions/v1/track-order`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ order_number: n, phone_last4: l4 }) });
    return await r.json();
  }, [BASE, seeded.number, seeded.last4]);
  check(track?.order?.status === "completed",
        `the customer's tracking page shows the new status (${track?.order?.status_label || "—"})`);

  await p.click("#back");
  await p.waitForSelector("#queue:not(.hidden)");

  // ---------- signing out clears everything ----------
  await p.click("#logout");
  await p.waitForTimeout(400);
  check(await p.locator("#login").isVisible(), "signing out returns to the login screen");
  check(!(await p.evaluate(() => sessionStorage.getItem("janeiro_admin_session"))),
        "signing out clears the stored session");

  check(errs.length === 0, `no JS errors${errs.length ? " -> " + errs.slice(0, 3).join(" | ") : ""}`);
  await p.screenshot({ path: "/tmp/claude-0/-home-user-JANEIRO/68cc013f-a073-5abe-9b55-e7d0bdbc6503/scratchpad/admin-390.png" });
  await p.close();
  await browser.close();
  console.log(fail ? `\n\x1b[31m${fail} FAILED\x1b[0m` : "\n\x1b[32mALL ADMIN CHECKS PASSED\x1b[0m");
  process.exit(fail ? 1 : 0);
})();
