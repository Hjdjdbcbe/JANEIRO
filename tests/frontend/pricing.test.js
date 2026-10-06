/* السعر حسب طريقة الدفع (039): Flexy بزيادة نسبة، وخطة لها سعر فليكسي خاص.
   يحتاج mock-supabase.js شغّالاً وقاعدة janeiro_test. */
const { chromium } = require("playwright");
const { Client } = require("pg");

const BASE = "http://127.0.0.1:8808";
let failures = 0;
const ok  = m => console.log(`\x1b[32mPASS\x1b[0m  ${m}`);
const bad = m => { console.log(`\x1b[31mFAIL\x1b[0m  ${m}`); failures++; };
const check = (c, m) => c ? ok(m) : bad(m);

(async () => {
  const db = new Client({ database: process.env.MOCK_DB || "janeiro_test", host: "/var/run/postgresql" });
  await db.connect();
  const q = async (sql, args) => (await db.query(sql, args)).rows;

  const [flexy] = await q("select id, surcharge_pct from payment_methods where type='flexy'");
  const [bmob]  = await q("select id, surcharge_pct from payment_methods where type='baridimob'");
  const [a] = await q(`select p.id, pl.id plan, pl.price, pl.flexy_price from products p join product_plans pl on pl.product_id=p.id
                        where p.slug='snapchat-plus' and pl.is_active order by pl.sort_order limit 1`);
  const [b] = await q(`select p.id, pl.id plan, pl.price, pl.flexy_price from products p join product_plans pl on pl.product_id=p.id
                        where p.slug='chatgpt-plus' and pl.is_active order by pl.sort_order limit 1`);
  await q("update payment_methods set is_active=true, surcharge_pct=20 where id=$1", [flexy.id]);
  await q("update payment_methods set is_active=true, surcharge_pct=0 where id=$1", [bmob.id]);
  const offer = Number(b.price) + 50;                       // below +20%, above the list price
  await q("update product_plans set flexy_price=$2 where id=$1", [b.plan, offer]);

  const browser = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  try {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
    const errors = [];
    page.on("pageerror", e => errors.push(e.message));
    await page.addInitScript(u => { window.JANEIRO_CONFIG = { SUPABASE_URL: u, SUPABASE_ANON_KEY: "mock-anon-key" }; }, BASE);
    await page.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });

    const amountFor = async label => {
      await page.locator("#o2 .pay2 .paybtn", { hasText: label }).click();
      return page.evaluate(() => ({
        amount: document.querySelector("#payBox .amount b").textContent.replace(/[^\d]/g, ""),
        note: (document.querySelector("#payBox .pay-diff") || {}).textContent || "",
      }));
    };
    const toPay = async ids => {
      await page.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });   // an empty cart each time
      await page.evaluate(ids => { ids.forEach(id => addToCart(id, 0)); closePanels(); go("order"); step(2); }, ids);
      await page.waitForSelector("#o2 .pay2 .paybtn");
    };

    const listA = Number(a.price);
    const flexA = Math.ceil(listA * 1.2 / 10) * 10;
    await toPay([a.id]);
    let r = await amountFor("BaridiMob");
    check(+r.amount === listA && !r.note, `BaridiMob shows the list price, no note (${r.amount})`);
    r = await amountFor("Flexy");
    check(+r.amount === flexA, `Flexy shows +20%, rounded up to 10 دج (${r.amount} = ${flexA})`);
    check(/20%/.test(r.note), `and says why: "${r.note.trim()}"`);

    await toPay([b.id]);
    r = await amountFor("Flexy");
    check(+r.amount === offer, `a plan's own Flexy price is charged as written (${r.amount} = ${offer})`);
    check(/سعر خاص/.test(r.note), `and is named a special price: "${r.note.trim()}"`);

    /* no percentage at all: the plan's Flexy price still applies */
    await q("update payment_methods set surcharge_pct=0 where id=$1", [flexy.id]);
    await toPay([b.id]);
    r = await amountFor("Flexy");
    check(+r.amount === offer, `without a percentage the Flexy price still applies (${r.amount})`);
    await q("update payment_methods set surcharge_pct=20 where id=$1", [flexy.id]);

    await toPay([a.id, b.id]);
    r = await amountFor("Flexy");
    check(+r.amount === flexA + offer, `mixed cart adds both (${r.amount} = ${flexA + offer})`);

    const lines = await page.locator("#payBox .paylines .r").count();
    check(lines === 2, `the pay step lists what is paid for (${lines} lines)`);

    /* «اطلب الآن» twice on the same plan is still one item */
    await page.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });
    await page.evaluate(id => { openDetail(id); addCurrent(true); openDetail(id); addCurrent(true); }, a.id);
    const qty = await page.evaluate(() => document.querySelector("#cartBadge").textContent.trim());
    check(qty === "1", `buying the same plan now twice does not double it (cart: ${qty})`);

    /* a product page opens on its cheapest plan, the price its card quoted:
       list ChatGPT's dearer plan first for this check */
    const plans = await q(`select pl.id, pl.price, pl.sort_order from product_plans pl join products p on p.id=pl.product_id
                            where p.slug='chatgpt-plus' and pl.is_active order by pl.sort_order`);
    const dear = plans.reduce((x, y) => Number(y.price) > Number(x.price) ? y : x);
    await q("update product_plans set sort_order=-1 where id=$1", [dear.id]);
    try {
      await page.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });
      await page.evaluate(id => openDetail(id), b.id);
      const sel = await page.evaluate(() => document.querySelector("#dTotal").textContent.replace(/[^\d]/g, ""));
      const lo = Math.min(...plans.map(x => Number(x.price)));
      check(+sel === lo, `the cheapest plan is selected first, even listed second (${sel} = ${lo})`);
    } finally {
      await q("update product_plans set sort_order=$2 where id=$1", [dear.id, dear.sort_order]);
    }

    /* Flexy: the receipt step asks for a screenshot and the exact time */
    await toPay([a.id]);
    await page.locator("#o2 .pay2 .paybtn", { hasText: "Flexy" }).click();
    await page.evaluate(() => step(3));
    let rs = await page.evaluate(() => ({ h: document.querySelector("#receiptH").textContent,
      lbl: document.querySelector("#refLabel").textContent, type: document.querySelector("#fRef").type,
      drop: document.querySelector("#dropText").textContent }));
    check(/الفليكسي/.test(rs.h) && /الفليكسي/.test(rs.drop), `Flexy asks for the Flexy screenshot: "${rs.h}"`);
    check(/وقت الدفع/.test(rs.lbl) && rs.type === "time", `and the exact time of payment, as a time field: "${rs.lbl}" (${rs.type})`);
    await page.setInputFiles("#receiptFile", { name: "flexy.png", mimeType: "image/png",
      buffer: Buffer.from("89504e470d0a1a0a0000000d4948445200000001000000010806000000", "hex") });
    await page.evaluate(() => nextFromReceipt());
    const stuck = await page.evaluate(() => !document.querySelector("#o3").classList.contains("hidden"));
    check(stuck, "without the time it does not move on");
    await page.fill("#fRef", "14:35");
    await page.evaluate(() => nextFromReceipt());
    const moved = await page.evaluate(() => !document.querySelector("#o4").classList.contains("hidden"));
    check(moved, "with the screenshot and the time it moves on");
    const review = await page.locator("#orderSummary").innerText();
    check(/وقت الدفع/.test(review) && /14:35/.test(review), "the review shows the payment time");

    /* back to BaridiMob: receipt and transaction number again */
    await page.evaluate(() => step(2));
    await page.locator("#o2 .pay2 .paybtn", { hasText: "BaridiMob" }).click();
    await page.evaluate(() => step(3));
    rs = await page.evaluate(() => ({ h: document.querySelector("#receiptH").textContent,
      lbl: document.querySelector("#refLabel").textContent, type: document.querySelector("#fRef").type }));
    check(/وصل/.test(rs.h) && /رقم العملية/.test(rs.lbl) && rs.type === "text",
          `BaridiMob asks for the receipt and the number: "${rs.h}" / "${rs.lbl}"`);

    /* the same cart, priced by the server */
    const server = await page.evaluate(async ([b, items, pm]) => {
      const res = await (await fetch(`${b}/functions/v1/create-order`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "عميل", phone: "0560" + Math.floor(100000 + Math.random() * 899999),
          payment_method_id: pm, idempotency_key: "pricing-" + Date.now(), items }) })).json();
      return res.order?.total ?? JSON.stringify(res);
    }, [BASE, await Promise.all([a, b].map(async x => ({ product_id: x.id, plan_id: x.plan, quantity: 1,
          activation: (await q("select label, field_type from product_requirements where product_id=$1", [x.id]))
            .map(f => ({ label: f.label, value: f.field_type === "email" ? "buyer@example.com" : "0550123456" })) }))), flexy.id]);
    check(Number(server) === flexA + offer, `the server charges what the page showed (${server})`);

    check(!errors.length, `no JS errors${errors.length ? ": " + errors.join(" | ") : ""}`);
  } finally {
    await browser.close();
    await q("update payment_methods set surcharge_pct=$2 where id=$1", [flexy.id, flexy.surcharge_pct]);
    await q("update payment_methods set surcharge_pct=$2 where id=$1", [bmob.id, bmob.surcharge_pct]);
    await q("update product_plans set flexy_price=$2 where id=$1", [b.plan, b.flexy_price]);
    await db.end();
  }
  console.log(failures ? `\n\x1b[31m${failures} FAILED\x1b[0m` : "\n\x1b[32mall pricing checks passed\x1b[0m");
  process.exit(failures ? 1 : 0);
})();
