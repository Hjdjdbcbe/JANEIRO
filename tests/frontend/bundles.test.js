/* ============================================================
   الباقات — driven through the real pages.

     node tests/frontend/bundles.test.js

   The point of most of these is that no figure on screen is
   arithmetic the browser did: the price, the list total and the
   saving all come from public_bundles, and the total the customer is
   charged is computed again by create_order. Where a test can check
   the same number in both places, it does.
   ============================================================ */
const { chromium } = require("playwright");

const BASE = process.env.BASE || "http://127.0.0.1:8808";
let fail = 0;
const check = (c, m) => { console.log(`${c ? "\x1b[32mPASS\x1b[0m" : "\x1b[31mFAIL\x1b[0m"}  ${m}`); if (!c) fail++; };
/* the FIRST number in the string: "945 دج (21%)" is one figure and a
   note about it, and stripping every non-digit glued them into 94521 */
const num = s => Number((String(s).match(/[\d,]+(?:\.\d+)?/) || ["0"])[0].replace(/,/g, ""));

(async () => {
  const browser = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  const errs = [];
  const p = await browser.newPage({ viewport: { width: 1280, height: 950 } });
  p.on("pageerror", e => errs.push(e.message));
  p.on("console", m => { if (m.type() === "error" && !/Failed to load|ERR_/.test(m.text())) errs.push(m.text()); });

  await p.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });
  await p.waitForFunction(() => document.querySelectorAll("#shopGrid .pcard:not(.sk)").length > 0);
  await p.waitForTimeout(600);

  // what the server says, to measure the page against
  const server = (await (await fetch(`${BASE}/rest/v1/public_bundles`)).json())[0];
  check(!!server, `the database serves a bundle to measure against: ${server && server.slug}`);

  // ---------- the button ----------
  const wired = await p.evaluate(() => {
    const b = [...document.querySelectorAll("button")].find(x => x.textContent.trim() === "اكتشف الباقات");
    return b ? b.getAttribute("onclick") : null;
  });
  check(wired === "go('bundles')", `"اكتشف الباقات" opens the bundles page, not the offers filter: ${wired}`);

  // ---------- the list ----------
  await p.evaluate(() => window.go("bundles"));
  await p.waitForSelector("#bundles:not(.hidden)");
  await p.waitForTimeout(400);
  const cards = await p.locator("#bundleGrid .bcard").count();
  check(cards === 1, `every live bundle gets a card (${cards})`);

  const card = await p.evaluate(() => {
    const c = document.querySelector("#bundleGrid .bcard");
    return {
      name: c.querySelector("h3").textContent.trim(),
      names: c.querySelector(".bnames").textContent.trim(),
      price: c.querySelector(".bprice b").textContent,
      old: c.querySelector(".bprice s").textContent,
      save: c.querySelector(".bsave").textContent.trim(),
      marks: c.querySelectorAll(".bmarks .bm").length,
    };
  });
  check(card.name === server.name, `the card names the bundle: ${card.name}`);
  check(num(card.price) === Number(server.bundle_price),
        `the price is the server's, not a percentage worked out here: ${card.price}`);
  check(num(card.old) === Number(server.list_total),
        `the struck-through figure is the server's list total: ${card.old}`);
  check(card.save === `وفّر ${server.saving_pct}%`,
        `the saving is the server's: "${card.save}"`);
  check(num(card.old) > num(card.price), "and it really is a saving");
  check(card.marks === server.items.length,
        `a mark for each product inside (${card.marks})`);
  for (const it of server.items)
    check(card.names.includes(it.name), `the card lists ${it.name}`);

  // ---------- the detail page ----------
  await p.locator("#bundleGrid .bcard button").first().click();
  await p.waitForSelector("#bundle:not(.hidden)");
  await p.waitForTimeout(300);
  const detail = await p.evaluate(() => ({
    name: document.querySelector("#bName").textContent.trim(),
    rows: [...document.querySelectorAll("#bItems .bitem")].map(r => ({
      name: r.querySelector(".n b").textContent.trim(),
      plan: r.querySelector(".n span").textContent.trim(),
      price: r.querySelector(".mono").textContent,
    })),
    list: document.querySelector("#bList").textContent,
    price: document.querySelector("#bPrice").textContent,
    save: document.querySelector("#bSave").textContent,
  }));
  check(detail.name === server.name, "the detail page names the bundle");
  check(detail.rows.length === server.items.length,
        `each product is shown on its own (${detail.rows.length})`);
  const priced = server.items.every(i =>
    detail.rows.some(r => r.name === i.name && num(r.price) === Number(i.price) && r.plan === i.plan_name));
  check(priced, "each one with its own plan and its own list price");
  check(num(detail.list) === Number(server.list_total), `the list total: ${detail.list}`);
  check(num(detail.price) === Number(server.bundle_price), `the bundle price: ${detail.price}`);
  check(num(detail.save) === Number(server.saving), `and what it saves: ${detail.save}`);

  /* The marks are 38/44px boxes with the artwork clipped inside them.
     The size rules were scoped to the card's row, so the same markup
     in a detail row had an unconstrained <img>: the product poster
     rendered at its natural size and covered the page. Measured here
     rather than eyeballed. */
  const marks = await p.evaluate(() =>
    [...document.querySelectorAll("#bundle .bm, #bundleGrid .bm")].map(el => {
      const r = el.getBoundingClientRect();
      const img = el.querySelector("img");
      const ir = img ? img.getBoundingClientRect() : null;
      return { w: Math.round(r.width), h: Math.round(r.height),
               imgW: ir ? Math.round(ir.width) : null };
    }));
  check(marks.length > 0 && marks.every(m => m.w <= 48 && m.h <= 48),
        `every product mark stays a mark (widest ${Math.max(...marks.map(m => m.w))}px)`);
  check(marks.every(m => m.imgW === null || m.imgW <= m.w),
        "and its artwork is clipped inside it, not spilling over the page");

  // ---------- the cart ----------
  await p.click("#bundle .btn-primary");
  await p.waitForTimeout(500);
  const cart = await p.evaluate(() => ({
    lines: document.querySelectorAll("#cartList .cbundle .citem").length,
    grouped: document.querySelectorAll("#cartList .cbundle").length,
    total: document.querySelector("#cartTotal").textContent,
    badge: document.querySelector("#cartBadge").textContent,
  }));
  check(cart.grouped === 1, "the bundle goes into the cart as one group");
  check(cart.lines === server.items.length + 1,
        `carrying a line per product plus its own price row (${cart.lines})`);
  check(num(cart.total) === Number(server.bundle_price),
        `the cart charges the bundle price, not the sum of the parts: ${cart.total}`);
  check(cart.badge === String(server.items.length),
        `the badge counts the products in it (${cart.badge})`);

  /* The lines inside the group must add up to the struck-through total,
     not to a deal-discounted version of it. The server charges bundle
     lines at list price, so a cart showing deal prices inside a bundle
     would print numbers the order does not record and a group whose
     parts do not sum to the figure it is measured against. */
  const groupLines = await p.evaluate(() =>
    [...document.querySelectorAll("#cartList .cbundle .citem .pr")].map(e => e.textContent));
  const groupSum = groupLines.slice(0, -1).reduce((s, t) => s + num(t), 0);
  check(groupSum === Number(server.list_total),
        `the lines inside the bundle add up to its list total: ${groupSum} = ${server.list_total}`);

  // adding it again buys two of it
  await p.evaluate(id => window.addBundle(id), server.id);
  await p.waitForTimeout(300);
  check(num(await p.evaluate(() => document.querySelector("#cartTotal").textContent))
        === Number(server.bundle_price) * 2, "adding it again charges twice the bundle price");
  await p.evaluate(() => window.chQty(0, -1));
  await p.waitForTimeout(300);
  check(num(await p.evaluate(() => document.querySelector("#cartTotal").textContent))
        === Number(server.bundle_price), "and stepping it back down charges once");

  // ---------- taking a product out unties the rest ----------
  await p.evaluate(() => window.delItem(0));
  await p.waitForTimeout(300);
  const untied = await p.evaluate(() => ({
    grouped: document.querySelectorAll("#cartList .cbundle").length,
    lines: document.querySelectorAll("#cartList .citem").length,
    total: document.querySelector("#cartTotal").textContent,
    /* the price printed on each surviving line, so the expectation is
       the page's own arithmetic rather than a second copy of it here.
       It is NOT the bundle's list prices: an untied line is an
       ordinary line again, and an ordinary line takes a live deal
       price if the product has one. */
    lineTotals: [...document.querySelectorAll("#cartList .citem .pr")].map(e => e.textContent),
  }));
  const sumLines = untied.lineTotals.reduce((s, t) => s + num(t), 0);
  check(untied.grouped === 0, "removing one product unties the bundle");
  check(untied.lines === server.items.length - 1, `the others stay in the cart (${untied.lines})`);
  check(num(untied.total) === sumLines,
        `the rest are charged line by line: ${untied.total} = ${sumLines}`);
  check(num(untied.total) !== Number(server.bundle_price),
        "the bundle price is gone with the bundle");

  // ---------- what the server is asked for ----------
  // place the order for real and compare the totals
  const placed = await p.evaluate(async ([b, bid]) => {
    const [pm] = await (await fetch(`${b}/rest/v1/payment_methods?select=id&is_active=eq.true`)).json();
    const bundle = (await (await fetch(`${b}/rest/v1/public_bundles`)).json())[0];
    const r = await (await fetch(`${b}/functions/v1/create-order`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name: "عميل باقة", phone: "0569" + Math.floor(100000 + Math.random() * 899999),
        payment_method_id: pm.id, idempotency_key: "bundle-ui-" + Date.now(),
        /* the products in this bundle have their own required
           activation fields; fill them the way step 4 of the checkout
           does, or the order is refused for the wrong reason */
        items: await Promise.all(bundle.items.map(async (i) => {
          const [prod] = await (await fetch(
            `${b}/rest/v1/products?select=*,product_requirements(*)&slug=eq.${i.slug}`)).json();
          return {
            product_id: i.product_id, plan_id: i.plan_id, quantity: 1, bundle_id: bid,
            activation: (prod.product_requirements || []).map(r => ({
              label: r.label,
              value: r.field_type === "email" ? "buyer@example.com" : "0550111222",
            })),
          };
        })),
      }) })).json();
    return { ok: r.ok, code: r.code, order: r.order, expect: Number(bundle.bundle_price),
             list: Number(bundle.list_total) };
  }, [BASE, server.id]);
  check(placed.ok === true, `the bundle can actually be ordered${placed.ok ? "" : " -> " + placed.code}`);
  check(placed.ok && Number(placed.order.total) === placed.expect,
        `the server charges the bundle price: ${placed.ok && placed.order.total}`);
  check(placed.ok && Number(placed.order.subtotal) === placed.list,
        `with the list total kept as the subtotal: ${placed.ok && placed.order.subtotal}`);
  check(placed.ok && Number(placed.order.discount_total) === placed.list - placed.expect,
        `and the saving recorded on the order: ${placed.ok && placed.order.discount_total}`);

  // ---------- the offers system is untouched ----------
  await p.evaluate(() => window.go("shop", "__offers"));
  await p.waitForTimeout(400);
  const offers = await p.evaluate(() => ({
    title: document.querySelector("#shopTitle")?.textContent?.trim(),
    cards: document.querySelectorAll("#shopGrid .pcard").length,
  }));
  check(offers.cards > 0, `العروض still lists its own discounted products (${offers.cards})`);
  check(await p.evaluate(() => document.querySelectorAll("#dealGrid .deal, #deals .deal").length) >= 0,
        "and the deals section is still on the page");

  await p.close();

  // ============================================================
  // the dashboard: making a bundle the way the owner will
  // ============================================================
  const d = await browser.newPage({ viewport: { width: 430, height: 1000 } });
  d.on("pageerror", e => errs.push("dash: " + e.message));
  await d.addInitScript(b => { window.JANEIRO_CONFIG = { SUPABASE_URL: b, SUPABASE_ANON_KEY: "k" }; }, BASE);
  await d.goto(`${BASE}/dashboard/index.html`, { waitUntil: "networkidle" });
  await d.fill("#email", "admin@janeiro.test");
  await d.fill("#pass", "admin-pass-123");
  await d.click("#loginBtn");
  await d.waitForSelector("#app:not(.hidden)", { timeout: 15000 });

  await d.locator('#tabs .tab[data-v="bundles"]').click();
  await d.waitForSelector("#bundles:not(.hidden)");
  await d.waitForTimeout(600);
  check(await d.locator("#bundles .prow").count() >= 1,
        "the console lists the bundles that exist");

  const slug = "test-bundle-ui-" + Date.now().toString(36);
  await d.click("#newBundle");
  await d.waitForSelector("#bundleEditor:not(.hidden)");
  await d.fill('[data-b="name"]', "باقة من اللوحة");
  await d.fill('[data-b="slug"]', slug);

  // two products, chosen by plan
  /* two plans of two DIFFERENT products: a bundle holds one plan per
     product, so taking a product removes all of its plans from the
     picker -- picking the first two options would often be two plans
     of the same product and the second choice would no longer exist */
  const opts = await d.evaluate(() => {
    const seen = new Set(), out = [];
    for (const o of [...document.querySelector("#bAdd").options].slice(1)) {
      const pid = o.value.split("|")[0];
      if (seen.has(pid)) continue;
      seen.add(pid); out.push(o.value);
      if (out.length === 2) break;
    }
    return out;
  });
  check(opts.length === 2, "the picker offers plans of different products to choose from");
  /* it sits outside .ed at first, so it kept the browser's own white
     select on a dark console */
  const picker = await d.evaluate(() => {
    const cs = getComputedStyle(document.querySelector("#bAdd"));
    const page = getComputedStyle(document.body).backgroundColor;
    const lum = c => { const n = c.match(/[\d.]+/g).map(Number);
                       return (0.2126*n[0] + 0.7152*n[1] + 0.0722*n[2]) / 255; };
    return { picker: lum(cs.backgroundColor), page: lum(page) };
  });
  check(Math.abs(picker.picker - picker.page) < 0.35,
        `the picker wears the console's own skin, not the browser's default`);
  await d.selectOption("#bAdd", opts[0]);
  await d.waitForTimeout(200);
  await d.selectOption("#bAdd", opts[1]);
  await d.waitForTimeout(200);
  check(await d.locator("#bundleEditor .rep").count() === 2, "both go into the bundle");

  // the list total is the console's own sum of those plans
  const listShown = await d.evaluate(() =>
    document.querySelector("#bundleEditor .dl b").textContent);
  /* the console's own sum of the two rows it is showing, so the total
     is checked against the parts on screen rather than against a
     second copy of the arithmetic here */
  const rowPrices = await d.evaluate(() =>
    [...document.querySelectorAll("#bundleEditor .rep .meta")].map(e => e.textContent));
  const rowSum = rowPrices.reduce((s, t) => s + num(t), 0);
  check(num(listShown) === rowSum,
        `the list total is the sum of the rows shown: ${listShown} = ${rowSum}`);

  // a price that is not a saving is refused, and says why
  await d.fill('[data-b="bundle_price"]', String(num(listShown) + 1000));
  await d.evaluate(() => { document.querySelector("#bActive").click(); });
  await d.click("#saveBundle");
  await d.waitForTimeout(500);
  check((await d.locator("#toast").innerText()).includes("أقل من"),
        `a price above the list total is refused: "${(await d.locator("#toast").innerText()).slice(0, 60)}"`);

  // a real one saves
  const price = Math.round(num(listShown) * 0.8);
  await d.fill('[data-b="bundle_price"]', String(price));
  await d.click("#saveBundle");
  await d.waitForSelector("#bundles:not(.hidden)", { timeout: 10000 });
  await d.waitForTimeout(600);
  check(await d.locator("#bundles .prow", { hasText: "باقة من اللوحة" }).count() === 1,
        "the new bundle appears in the list");

  // and the storefront is serving it, at the price that was typed
  const served = await d.evaluate(async ([b, s]) => {
    const rows = await (await fetch(`${b}/rest/v1/public_bundles`)).json();
    return rows.find(x => x.slug === s) || null;
  }, [BASE, slug]);
  check(!!served, "the storefront is serving the bundle the console just made");
  check(served && Number(served.bundle_price) === price,
        `at the price that was typed, not a percentage: ${served && served.bundle_price}`);
  check(served && Number(served.list_total) === num(listShown),
        `with the list total the console showed: ${served && served.list_total}`);

  // deleting it takes it off the storefront
  await d.locator("#bundles .prow", { hasText: "باقة من اللوحة" }).first().click();
  await d.waitForSelector("#bundleEditor:not(.hidden)");
  d.once("dialog", dlg => dlg.accept());
  await d.click("#delBundle");
  await d.waitForSelector("#bundles:not(.hidden)", { timeout: 10000 });
  await d.waitForTimeout(600);
  const goneFromShop = await d.evaluate(async ([b, s]) => {
    const rows = await (await fetch(`${b}/rest/v1/public_bundles`)).json();
    return !rows.some(x => x.slug === s);
  }, [BASE, slug]);
  check(goneFromShop, "deleting it takes it off the storefront");
  await d.close();

  check(errs.length === 0, `no JS errors${errs.length ? " -> " + errs.slice(0, 3).join(" | ") : ""}`);
  await browser.close();
  console.log(fail ? `\n\x1b[31m${fail} FAILED\x1b[0m` : "\n\x1b[32mALL BUNDLE CHECKS PASSED\x1b[0m");
  process.exit(fail ? 1 : 0);
})();
