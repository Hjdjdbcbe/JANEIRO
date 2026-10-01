/* Drives the dashboard's bot and store sections (035) in Chromium against
   mock-supabase.js. Needs fixtures.sql, then bot-fixtures.sql, applied.
   Every check that changes something reads the result back from the
   database, not only from the screen. Re-runnable: it makes its own
   product, sale and seller each run. */
const { chromium } = require("playwright");
const { execFileSync } = require("child_process");
const BASE = process.env.BASE || "http://127.0.0.1:8808";
const DB = process.env.DB || "janeiro_test";
let fail = 0;
const check = (c, m) => { console.log(`${c ? "\x1b[32mPASS\x1b[0m" : "\x1b[31mFAIL\x1b[0m"}  ${m}`); if (!c) fail++; };
const sql = q => execFileSync("psql", ["-d", DB, "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", q]).toString().trim();
const RUN = Date.now().toString(36);

(async () => {
  const browser = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  const errs = [];
  const p = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  p.on("pageerror", e => errs.push(e.message));
  p.on("console", m => { if (m.type() === "error" && !/Failed to load|ERR_/.test(m.text())) errs.push(m.text()); });
  p.on("dialog", d => d.accept());
  await p.addInitScript(b => { window.JANEIRO_CONFIG = { SUPABASE_URL: b, SUPABASE_ANON_KEY: "mock-anon" }; }, BASE);

  const toast = async () => (await p.locator("#toast").textContent()) || "";
  const go = async v => {
    await p.evaluate(() => { document.querySelector("#toast").textContent = ""; });
    await p.evaluate(v => showView(v), v);
    await p.waitForFunction(v => { const s = document.getElementById(v);
      return s && !s.classList.contains("hidden") && s.children.length > 0
        && ![...s.querySelectorAll(".empty")].some(e => e.textContent.trim() === "…"); }, v, { timeout: 10000 });
    await p.waitForTimeout(500);
  };

  // ---------- a signed-in non-admin is refused by every new function ----------
  await p.goto(`${BASE}/dashboard/index.html`, { waitUntil: "networkidle" });
  const refused = await p.evaluate(async b => {
    const s = await (await fetch(`${b}/auth/v1/token?grant_type=password`, { method: "POST",
      headers: { "Content-Type": "application/json", apikey: "mock-anon" },
      body: JSON.stringify({ email: "nobody@janeiro.test", password: "nobody-pass-123" }) })).json();
    const out = [];
    for (const [fn, body] of [["admin_bot", { p_action: "catalog", p_args: {} }], ["admin_bot_summary", {}],
                              ["admin_customers", {}], ["admin_store_config", {}],
                              ["admin_save_settings", { p_values: { store_name: "x" } }]]) {
      const r = await fetch(`${b}/rest/v1/rpc/${fn}`, { method: "POST", body: JSON.stringify(body),
        headers: { "Content-Type": "application/json", apikey: "mock-anon", Authorization: `Bearer ${s.access_token}` } });
      out.push(r.status);
    }
    return out;
  }, BASE);
  check(refused.every(s => s >= 400), `a non-admin is refused by every console function (${refused})`);

  await p.fill("#email", "admin@janeiro.test"); await p.fill("#pass", "admin-pass-123");
  await p.click("#loginBtn");
  await p.waitForSelector("#app:not(.hidden)", { timeout: 10000 });

  // ---------- the sidebar reaches every section ----------
  const tabs = await p.$$eval("#tabs .tab[data-v]", t => t.map(x => x.dataset.v));
  for (const v of ["overview", "queue", "products", "deals", "bundles", "categories", "customers",
                   "warranty", "stock", "sales", "sellers", "settings"])
    check(tabs.includes(v), `the sidebar has «${v}»`);

  // ---------- overview: the bot sits next to the store ----------
  await p.waitForFunction(() => /بوت التليغرام/.test(document.querySelector("#overview")?.textContent || ""), null, { timeout: 10000 });
  const ovText = await p.locator("#overview").textContent();
  const avail = sql(`select count(*) from bot_cards where status = 'available'`);
  check(new RegExp(`أكواد متاحة\\s*${avail}`).test(ovText.replace(/\s+/g, " ")),
        `the overview shows the bot's available codes from the database (${avail})`);

  // ---------- stock: a product made from the dashboard ----------
  await p.click('#tabs .tab[data-v="stock"]');
  await p.waitForSelector("#newBotProd");
  const code = "t" + RUN;
  await p.click("#newBotProd");
  await p.fill("#npCode", code); await p.fill("#npName", "منتج اختبار " + RUN);
  await p.click("#npSave");
  const card = p.locator(`[data-pcode="${code}"]`);
  await card.waitFor({ timeout: 10000 });
  check(sql(`select count(*) from bot_products where code = '${code}'`) === "1", "a bot product is created from the dashboard");

  await card.locator('[data-nv="code"]').fill("m1");
  await card.locator('[data-nv="name"]').fill("شهر");
  await card.locator("[data-addvar]").click();
  await p.locator(`[data-pcode="${code}"] [data-var]`).waitFor({ timeout: 10000 });
  const vid = await p.locator(`[data-pcode="${code}"] [data-var]`).getAttribute("data-var");
  check(!!vid, "and a duration (variant) under it");

  // ship codes, one of them twice
  await p.locator(`[data-var="${vid}"] [data-vpanel="add"]`).click();
  await p.fill(`[data-var="${vid}"] [data-codes]`, `A-${RUN}-1\nA-${RUN}-2\nA-${RUN}-3\nA-${RUN}-1`);
  await p.evaluate(() => { document.querySelector("#toast").textContent = ""; });
  await p.click(`[data-var="${vid}"] [data-ship]`);
  await p.waitForFunction(() => /تزاد \d/.test(document.querySelector("#toast").textContent), null, { timeout: 10000 });
  const shipped = await toast();
  check(/تزاد 3/.test(shipped) && /1 مكرّر/.test(shipped), `shipping codes reports added and duplicates (${shipped})`);
  check(sql(`select count(*) from bot_cards where variant_id = '${vid}' and status = 'available'`) === "3",
        "three codes are in stock, the duplicate is not");
  await p.locator(`[data-var="${vid}"] .cnt-av`).waitFor();
  check(/3 متاح/.test(await p.locator(`[data-var="${vid}"] .cnt-av`).textContent()), "the row shows 3 متاح");

  // price for the first market
  const mkt = sql(`select code from bot_markets where is_active order by sort_order limit 1`);
  const priceIn = p.locator(`[data-var="${vid}"] [data-price="${mkt}"]`);
  await priceIn.fill("1450"); await priceIn.dispatchEvent("change");
  await p.waitForFunction(() => /السعر/.test(document.querySelector("#toast").textContent), null, { timeout: 10000 });
  check(sql(`select price from bot_prices where variant_id = '${vid}' and market = '${mkt}'`).startsWith("1450"),
        "a price typed in the dashboard is the bot's price");

  // duration
  await p.locator(`[data-var="${vid}"] [data-vpanel="dur"]`).click();
  await p.fill(`[data-var="${vid}"] [data-dv]`, "2");
  await p.click(`[data-var="${vid}"] [data-dsave]`);
  await p.waitForFunction(() => /المدة/.test(document.querySelector("#toast").textContent), null, { timeout: 10000 });
  check(sql(`select duration_value || ' ' || duration_unit from bot_variants where id = '${vid}'`) === "2 month",
        "the duration is saved (2 month)");

  // disable one code from the codes list
  await p.locator(`[data-var="${vid}"] [data-vpanel="codes"]`).waitFor();
  await p.locator(`[data-var="${vid}"] [data-vpanel="codes"]`).click();
  await p.locator(`[data-var="${vid}"] [data-dis]`).first().waitFor({ timeout: 10000 });
  check(await p.locator(`[data-var="${vid}"] .code`).count() === 3, "the codes list shows the variant's codes");
  await p.locator(`[data-var="${vid}"] [data-dis]`).first().click();
  await p.locator(`[data-var="${vid}"] [data-en]`).first().waitFor({ timeout: 10000 });
  check(sql(`select count(*) from bot_cards where variant_id = '${vid}' and status = 'disabled'`) === "1",
        "a code can be taken out of stock");

  // ---------- sales: a sale a seller made in the bot shows up and is confirmed here ----------
  const nfx = sql(`select v.id from bot_variants v join bot_products p on p.id = v.product_id
                    where p.code = 'netflix' and v.code = 'm1'`);
  const cust = "زبون-" + RUN;
  sql(`insert into bot_cards (variant_id, code) values ('${nfx}', 'S-${RUN}')`);
  const issue = JSON.parse(sql(`select bot_request_card(900000002, '${nfx}', '${cust}', null, null)`)).issue_id;
  await p.click('#tabs .tab[data-v="sales"]');
  await p.waitForSelector("#sq");
  await p.fill("#sq", cust);
  await p.locator(`[data-issue="${issue}"]`).waitFor({ timeout: 10000 });
  await p.waitForFunction(() => document.querySelectorAll("#srows [data-issue]").length === 1, null, { timeout: 5000 }).catch(() => {});
  check(await p.locator("#srows [data-issue]").count() === 1, "searching sales by customer finds exactly that sale");
  check(/ياسين/.test(await p.locator(`[data-issue="${issue}"]`).textContent()), "the sale carries its seller's name");
  await p.locator(`[data-issue="${issue}"] [data-confirm]`).click();
  await p.locator(`[data-issue="${issue}"] [data-cert]`).waitFor({ timeout: 10000 });
  check(sql(`select status from bot_issues where id = '${issue}'`) === "confirmed", "confirming in the dashboard confirms in the bot");

  // a warranty link for that sale
  await p.locator(`[data-issue="${issue}"] [data-cert]`).click();
  await p.locator("[data-certform] [data-plat]").waitFor();
  await p.selectOption("[data-certform] [data-plat]", "Netflix");
  await p.click("[data-certform] [data-make]");
  await p.locator("[data-certform] .linkbox").waitFor({ timeout: 10000 }).catch(async () => console.log("toast:", await toast()));
  const link = await p.locator("[data-certform] .linkbox .mono").textContent();
  check(/\/warranty\/claim\/[A-Za-z0-9_-]{16,}$/.test(link), `the customer gets a one-time warranty link (${link})`);
  const certCode = sql(`select c.code from bot_certificates c where c.issue_id = '${issue}'`);
  check(/^[A-Z0-9-]{6,}$/.test(certCode), `the warranty exists in the bot (${certCode})`);

  // ---------- warranty: the bot's certificate is found and revoked here ----------
  await p.click('#tabs .tab[data-v="warranty"]');
  await p.click('[data-wt="bot"]');
  await p.waitForSelector("#wq");
  await p.fill("#wq", certCode);
  await p.locator(`[data-revoke="${certCode}"]`).waitFor({ timeout: 10000 });
  await p.waitForFunction(() => document.querySelectorAll("#wrows .row").length === 1, null, { timeout: 5000 }).catch(() => {});
  check(await p.locator("#wrows .row").count() === 1, "searching warranties by code finds it");
  await p.locator(`[data-revoke="${certCode}"]`).click();
  await p.waitForFunction(() => /أُلغيت/.test(document.querySelector("#toast").textContent), null, { timeout: 10000 });
  check(sql(`select revoked_at is not null from bot_certificates where code = '${certCode}'`) === "t", "revoking from the dashboard revokes it");

  await p.click('[data-wt="site"]');
  const siteCerts = Number(sql(`select count(*) from warranty_certificates`));
  await p.waitForFunction(n => document.querySelectorAll("#wrows .row").length === n, Math.min(siteCerts, 50), { timeout: 10000 }).catch(() => {});
  check((await p.locator("#wrows .row").count()) === Math.min(siteCerts, 50), `the site's certificates are listed (${siteCerts})`);

  // ---------- sellers ----------
  const tid = String(910000000 + Math.floor(Math.random() * 8999999));
  await p.click('#tabs .tab[data-v="sellers"]');
  await p.waitForSelector("#nsId");
  await p.fill("#nsId", tid); await p.fill("#nsName", "بائع " + RUN);
  await p.click("#nsAdd");
  await p.waitForFunction(t => document.querySelector("#sellers").textContent.includes(t), tid, { timeout: 10000 });
  check(sql(`select count(*) from bot_admins where telegram_id = ${tid} and is_active`) === "1", "a seller is added from the dashboard");
  await p.locator(`[data-rm="${tid}"]`).click();
  await p.waitForFunction(() => /تنحّى/.test(document.querySelector("#toast").textContent), null, { timeout: 10000 });
  check(sql(`select count(*) from bot_admins where telegram_id = ${tid} and is_active`) === "0", "and removed");

  // ---------- customers ----------
  await p.click('#tabs .tab[data-v="customers"]');
  await p.waitForSelector("#cq");
  await p.fill("#cq", "0561000002");
  await p.waitForFunction(() => document.querySelectorAll("#crows .row").length === 1, null, { timeout: 10000 });
  check(/سارة/.test(await p.locator("#crows").textContent()), "a customer is found by phone");

  // ---------- settings: what is saved is what the storefront reads ----------
  await p.click('#tabs .tab[data-v="settings"]');
  await p.waitForSelector("#s_support_message");
  const before = await p.inputValue("#s_support_message");
  await p.fill("#s_support_message", "رسالة " + RUN);
  await p.click("#setSave");
  await p.waitForFunction(() => /تحفظت/.test(document.querySelector("#toast").textContent), null, { timeout: 10000 });
  const pub = await p.evaluate(async b => (await (await fetch(`${b}/rest/v1/store_settings?select=key,value`,
    { headers: { apikey: "mock-anon" } })).json()).find(x => x.key === "support_message")?.value, BASE);
  check(pub === "رسالة " + RUN, `a saved setting is what the storefront reads (${pub})`);
  await p.fill("#s_whatsapp_number", "12");
  await p.click("#setSave");
  await p.waitForTimeout(800);
  check(sql(`select value from store_settings where key = 'support_message'`) === "رسالة " + RUN &&
        !/تحفظت/.test(await toast()), `a bad WhatsApp number is refused (${await toast()})`);
  await p.click('#tabs .tab[data-v="settings"]');
  await p.waitForSelector("#s_support_message");
  await p.fill("#s_support_message", before);
  await p.click("#setSave");
  await p.waitForFunction(() => /تحفظت/.test(document.querySelector("#toast").textContent), null, { timeout: 10000 });

  // ---------- site texts: edited here, shown on the storefront ----------
  sql(`delete from site_texts where key in ('nav_home', 'n_products')`);
  await p.click('#tabs .tab[data-v="texts"]');
  await p.waitForSelector("#tq");
  const parsed = await p.evaluate(async () => parseI18N(await (await fetch("/")).text()).length);
  const inSource = Number(require("child_process").execSync(
    "awk '/const I18N = \\{/,/^};/' frontend/index.html | grep -cE '^\\s*[a-z][a-z0-9_]*:\\s*\\{'").toString());
  check(parsed === inSource && parsed > 200, `every storefront text is offered for editing (${parsed} of ${inSource})`);
  await p.fill("#tq", "nav_home");
  await p.waitForTimeout(450); // the search re-renders after a short pause
  await p.waitForSelector('[data-tkey="nav_home"]');
  const newHome = "البداية " + RUN, newHomeFr = "Début " + RUN;
  await p.fill('[data-tkey="nav_home"] [data-tlang="ar"]', newHome);
  await p.fill('[data-tkey="nav_home"] [data-tlang="fr"]', newHomeFr);
  check(await p.locator("#tbar").isVisible(), "unsaved edits raise the save bar");
  await p.click("#tSave");
  await p.waitForFunction(() => /تحفظ/.test(document.querySelector("#toast").textContent), null, { timeout: 10000 });
  check(sql(`select value from site_texts where key = 'nav_home' and lang = 'ar'`) === newHome, "the edit is stored");
  check(sql(`select count(*) from site_texts where key = 'nav_home' and lang = 'en'`) === "0",
        "untouched languages store nothing (they keep the built-in text)");

  // a placeholder the site fills in cannot be dropped
  await p.fill("#tq", "n_products");
  await p.waitForTimeout(450); // the search re-renders after a short pause
  await p.waitForSelector('[data-tkey="n_products"]');
  await p.fill('[data-tkey="n_products"] [data-tlang="ar"]', "منتجات بزاف");
  await p.click("#tSave");
  await p.waitForTimeout(500);
  check(/\{n\}/.test(await toast()) && sql(`select count(*) from site_texts where key = 'n_products'`) === "0",
        `dropping {n} is refused before it reaches the site (${await toast()})`);
  await p.click("#tUndo");

  const shop = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  await shop.addInitScript(b => { window.JANEIRO_CONFIG = { SUPABASE_URL: b, SUPABASE_ANON_KEY: "mock-anon" }; }, BASE);
  await shop.goto(`${BASE}/`, { waitUntil: "networkidle" });
  await shop.waitForFunction(t => document.querySelector('#mainNav [data-i18n="nav_home"]')?.textContent === t, newHome, { timeout: 10000 }).catch(() => {});
  check(await shop.locator('#mainNav [data-i18n="nav_home"]').textContent() === newHome, "the storefront shows the edited Arabic text");
  await shop.evaluate(() => document.querySelector('[data-lang="fr"]')?.click());
  await shop.waitForTimeout(400);
  check(await shop.locator('#mainNav [data-i18n="nav_home"]').textContent() === newHomeFr, "and the edited French text");
  await shop.evaluate(() => document.querySelector('[data-lang="en"]')?.click());
  await shop.waitForTimeout(400);
  check(await shop.locator('#mainNav [data-i18n="nav_home"]').textContent() === "Home", "an unedited language keeps the built-in text");
  await shop.evaluate(() => document.querySelector('[data-lang="ar"]')?.click());

  // back to the original
  await p.fill("#tq", "nav_home");
  await p.waitForTimeout(450); // the search re-renders after a short pause
  await p.waitForSelector('[data-tkey="nav_home"] [data-treset]');
  await p.click('[data-tkey="nav_home"] [data-treset]');
  await p.click("#tSave");
  await p.waitForFunction(() => /للأصل/.test(document.querySelector("#toast").textContent), null, { timeout: 10000 });
  check(sql(`select count(*) from site_texts where key = 'nav_home'`) === "0", "«رجّع الأصل» removes the edit");
  await shop.reload({ waitUntil: "networkidle" });
  await shop.waitForTimeout(600);
  check(await shop.locator('#mainNav [data-i18n="nav_home"]').textContent() === "الرئيسية", "and the storefront is back to its own text");
  await shop.close();

  // ---------- every section loads cleanly, on a desktop and on a phone ----------
  for (const [w, h] of [[1280, 900], [390, 844]]) {
    await p.setViewportSize({ width: w, height: h });
    for (const v of tabs) {
      await go(v);
      const t = await toast();
      const r = await p.evaluate(() => ({ doc: document.documentElement.scrollWidth, win: window.innerWidth }));
      check(!t && r.doc <= r.win + 1, `${w}px «${v}» loads with no error and no sideways scroll${t ? " -> " + t : ""}${r.doc > r.win + 1 ? ` (doc ${r.doc})` : ""}`);
    }
  }

  check(errs.length === 0, `no JS errors${errs.length ? " -> " + errs.slice(0, 3).join(" | ") : ""}`);
  await browser.close();
  console.log(fail ? `\n\x1b[31m${fail} CONSOLE CHECK(S) FAILED\x1b[0m` : "\n\x1b[32mALL CONSOLE CHECKS PASSED\x1b[0m");
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
