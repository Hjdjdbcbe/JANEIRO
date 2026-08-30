const { chromium } = require("playwright");

const BASE = "http://127.0.0.1:8808";
let failures = 0;
const ok  = m => console.log(`\x1b[32mPASS\x1b[0m  ${m}`);
const bad = m => { console.log(`\x1b[31mFAIL\x1b[0m  ${m}`); failures++; };
const check = (c, m) => c ? ok(m) : bad(m);

(async () => {
  // Orders and rate-limit buckets from a previous run would trip the
  // real 2-active-order cap and fail this suite for the wrong reason.
  await fetch(`${BASE}/__test/reset`).catch(() => {});

  const browser = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", e => errors.push(e.message));
  // cdn.simpleicons.org and wa.me are unreachable in this sandbox; their
  // load failures are not defects in the page.
  const EXTERNAL = /simpleicons|wa\.me|ERR_TUNNEL|ERR_CONNECTION_RESET|ERR_NAME_NOT_RESOLVED|Failed to load resource/;
  page.on("console", m => { if (m.type() === "error" && !EXTERNAL.test(m.text())) errors.push(m.text()); });

  // point the page at the mock before any module runs
  await page.addInitScript(b => {
    window.JANEIRO_CONFIG = { SUPABASE_URL: b, SUPABASE_ANON_KEY: "mock-anon-key" };
    // wa.me cannot be reached here, so record the URL rather than opening it
    window.__opened = [];
    window.open = (u) => { window.__opened.push(u); return null; };
  }, BASE);

  await page.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });

  // ---------- catalogue loaded from the database ----------
  await page.waitForFunction(() => document.querySelectorAll("#shopGrid .pcard:not(.sk)").length > 0, { timeout: 10000 });
  /* Compare against what the API actually returns, not a hardcoded count:
     adding a product to the catalogue should not fail the test suite. */
  const cards = await page.locator("#shopGrid .pcard").count();
  const visible = await page.evaluate(async (b) =>
    (await (await fetch(`${b}/rest/v1/products?select=id`)).json()).length, BASE);
  check(cards === visible && cards > 0,
        `the grid renders every visible product (${cards} cards, ${visible} from the database)`);

  const chips = await page.locator("#catGrid .category-chip").count();
  check(chips === 7, `category chips: ${chips} (الكل + 6 categories)`);

  const chipHasIcon = await page.locator("#catGrid .category-chip").nth(1).locator("svg path, svg circle, svg rect").count();
  await page.evaluate(() => window.go("shop"));
  await page.waitForSelector("#shop:not(.hidden)");
  check(chipHasIcon > 0, "category chips still carry their designed glyphs");

  const noStatics = await page.evaluate(() => typeof window.PRODUCTS === "undefined");
  check(noStatics, "no global PRODUCTS array leaks into the page");

  // prices come from the DB (Gemini Pro's cheapest plan is 1900)
  await page.locator("#shopGrid .pcard", { hasText: "Gemini Pro" }).first().waitFor();
  const geminiPrice = await page.locator("#shopGrid .pcard", { hasText: "Gemini Pro" }).first().locator(".pprice b").innerText();
  check(geminiPrice.includes("1,900"), `Gemini Pro price from DB: "${geminiPrice}"`);

  // coming_soon product must not be purchasable
  const appleBtn = page.locator("#shopGrid .pcard", { hasText: "Apple One" }).first().locator(".pbody .btn");
  check(await appleBtn.isDisabled(), "coming_soon product's button is disabled");

  // ---------- detail ----------
  await page.locator("#shopGrid .pcard", { hasText: "Gemini Pro" }).first().locator(".pbody .btn").click();
  await page.waitForSelector("#detail:not(.hidden)");
  check((await page.locator("#dName").innerText()) === "Gemini Pro", "detail shows the product from the DB");
  const plans = await page.locator("#dPlans .opt").count();
  check(plans === 3, `detail shows ${plans} plans from the DB (expected 3)`);
  /* نوع التفعيل: the store's answer, shown to the buyer -- not a control
     the buyer operates. It has to be the product's own stored value and
     there must be nothing on the page to change it with. */
  const act = await page.evaluate(() => ({
    text: document.querySelector("#dActType").textContent.trim(),
    rowShown: !document.querySelector("#dActRow").classList.contains("hidden"),
    controls: document.querySelectorAll("#detail select, #detail input, #detail textarea").length,
  }));
  check(act.rowShown && act.text === "تفعيل مباشر",
        `نوع التفعيل reads from the product: "${act.text}"`);
  check(act.controls === 0,
        `nothing on the product page lets the buyer change it (${act.controls} inputs)`);
  check((await page.locator("#detail").innerText()).indexOf("ما نطلبه للتفعيل") === -1,
        "the old read-only 'ما نطلبه للتفعيل' row is gone");

  /* and a product the owner has not set one for shows no row at all,
     rather than an empty label or a dash */
  await page.evaluate(() => window.go("shop"));
  await page.waitForSelector("#shop:not(.hidden)");
  await page.locator("#shopGrid .pcard", { hasText: "Spotify Premium" }).first()
            .locator(".pbody .btn").click();
  await page.waitForSelector("#detail:not(.hidden)");
  await page.waitForTimeout(200);
  check(await page.evaluate(() => document.querySelector("#dActRow").classList.contains("hidden")),
        "a product with no نوع التفعيل set shows no row for it");

  await page.evaluate(() => window.go("shop"));
  await page.waitForSelector("#shop:not(.hidden)");
  await page.locator("#shopGrid .pcard", { hasText: "Gemini Pro" }).first()
            .locator(".pbody .btn").click();
  await page.waitForSelector("#detail:not(.hidden)");
  const war = await page.locator("#dWar").innerText();
  check(war.includes("ضمان طوال مدة الاشتراك"), `warranty derived from warranty_type: "${war}"`);

  // ---------- order flow ----------
  await page.locator("#detail .btn-primary").first().click();          // add / buy now
  await page.waitForTimeout(300);
  await page.evaluate(() => window.go("order"));
  await page.waitForSelector("#order:not(.hidden)");

  /* ---------- required fields on step 1 ----------
     Everything empty: the step must not advance, and each rule must
     say so under its own field rather than in a toast that vanishes. */
  await page.click("#o1 .btn-primary");
  await page.waitForTimeout(250);
  const empty = await page.evaluate(() => ({
    stillHere: !document.querySelector("#o1").classList.contains("hidden"),
    chan:  document.querySelector("#chanBox").classList.contains("bad"),
    chanMsg: getComputedStyle(document.querySelector("#chanErr")).visibility,
    name:  document.querySelector("#fldName").classList.contains("bad"),
    nameMsg: document.querySelector("#errName").textContent.trim(),
    phone: document.querySelector("#fldPhone").classList.contains("bad"),
    phoneMsg: document.querySelector("#errPhone").textContent.trim(),
  }));
  check(empty.stillHere, "an empty step 1 does not advance");
  check(empty.chan && empty.chanMsg !== "hidden", "قناة المتابعة is flagged and its message shows");
  check(empty.name && empty.nameMsg === "الاسم مطلوب", `name message: ${empty.nameMsg}`);
  check(empty.phone && empty.phoneMsg === "رقم الهاتف يجب أن يتكون من 10 أرقام ويبدأ بـ 05 أو 06 أو 07",
        `phone message: ${empty.phoneMsg}`);

  /* the phone rule, measured on blur -- not only on submit */
  const phoneCases = [
    ["055012345",   false, "nine digits"],
    ["05501234567", false, "eleven digits"],
    ["0450123456",  false, "starts 04"],
    ["0850123456",  false, "starts 08"],
    ["05a0123456",  false, "letters in it"],
    ["0550123456",  true,  "05 + ten digits"],
    ["0660123456",  true,  "06 + ten digits"],
    ["0770123456",  true,  "07 + ten digits"],
    ["0550 12 34 56", false, "spaces between the groups"],
    ["+213550123456", false, "the +213 form"],
    ["0550-123456",   false, "a dash in it"],
  ];
  for (const [value, ok, what] of phoneCases) {
    await page.fill("#fPhone", value);
    await page.locator("#fPhone").blur();
    await page.waitForTimeout(60);
    const bad = await page.evaluate(() => document.querySelector("#fldPhone").classList.contains("bad"));
    check(bad !== ok, `${ok ? "accepts" : "rejects"} ${what}: ${value}`);
  }

  /* One press, not two. Revealing a message used to grow the field on
     blur, which moved the button between press and release and threw
     the tap away: typing a bad number and then reaching straight for
     "التالي" did nothing at all. So this types into the phone, leaves
     the caret there, and presses the button exactly once. */
  /* Showing a message must not move anything. It used to: the line was
     revealed with display:none -> block, which grew the field by 19px
     ON BLUR -- so a customer who typed a bad number and reached
     straight for "التالي" had the button slide out from under their
     finger between press and release, and the press did nothing at
     all. Measured here rather than described: the button's position is
     read with the errors off, then with all three on. */
  const shift = await page.evaluate(() => {
    const btn = () => document.querySelector("#o1 .btn-primary").getBoundingClientRect().top;
    document.querySelector("#chanBox").classList.remove("bad");
    ["fldName","fldPhone"].forEach(id => document.querySelector("#"+id).classList.remove("bad"));
    const clean = btn();
    document.querySelector("#chanBox").classList.add("bad");
    ["fldName","fldPhone"].forEach(id => document.querySelector("#"+id).classList.add("bad"));
    const shown = btn();
    return Math.round(shown - clean);
  });
  check(shift === 0, `three messages appearing move the button by ${shift}px`);

  await page.fill("#fName", "أمين بلقاسم");
  await page.locator("#fName").blur();
  await page.fill("#fPhone", "0550123456");
  await page.fill("#fWilaya", "الجزائر");

  // name and phone right, channel still unchosen -> still blocked
  await page.click("#o1 .btn-primary");
  await page.waitForTimeout(250);
  check(await page.evaluate(() => !document.querySelector("#o1").classList.contains("hidden")),
        "no channel means no order, even with the rest filled in");

  await page.locator("#chanBox .paybtn").first().click();
  check(await page.evaluate(() => !document.querySelector("#chanBox").classList.contains("bad")),
        "choosing a channel clears its error");
  await page.click("#o1 .btn-primary");

  await page.waitForSelector("#o2:not(.hidden)");
  const payBtns = await page.locator("#o2 .pay2 .paybtn").count();
  check(payBtns === 3, `payment buttons rendered from payment_methods: ${payBtns}`);
  const payBox = await page.locator("#payBox").innerText();
  check(payBox.includes("0012345678 12") && payBox.includes("محمد ب."),
        "CCP account details come from the database");
  check(!payBox.includes("يُملأ لاحقاً"), "no placeholder account details remain");

  await page.click("#o2 .btn-primary");
  await page.waitForSelector("#o3:not(.hidden)");

  // a real JPEG (magic bytes matter: the backend sniffs them)
  const jpeg = Buffer.concat([Buffer.from([0xff,0xd8,0xff,0xe0]), Buffer.alloc(600, 7), Buffer.from([0xff,0xd9])]);
  await page.setInputFiles("#receiptFile", { name: "receipt.jpg", mimeType: "image/jpeg", buffer: jpeg });
  check((await page.locator("#dropText").innerText()).includes("receipt.jpg"), "receipt selected");
  await page.fill("#fRef", "4821990");
  await page.click("#o3 .btn-primary");

  await page.waitForSelector("#o4:not(.hidden)");
  const actInputs = await page.locator("#actFields input").count();
  check(actInputs === 2, `activation inputs built from the DB: ${actInputs}`);

  // submit with a required field empty -> blocked client-side, no order created
  await page.click("#o4 .btn-primary");
  await page.waitForTimeout(400);
  check(await page.locator("#sent").isHidden(), "submit blocked while a required activation field is empty");

  await page.fill('[data-af="0_0"]', "amine@gmail.com");
  await page.fill('[data-af="0_1"]', "0550111222");

  await page.click("#o4 .btn-primary");
  await page.waitForSelector("#sent:not(.hidden)", { timeout: 20000 });

  const oid = await page.locator("#sentOid").innerText();
  check(/^JNR-\d{6}-[0-9A-Z]{4}$/.test(oid), `server-issued order number shown: ${oid}`);
  const total = await page.locator("#sentTotal").innerText();
  check(total.includes("1,900"), `total came from the server: "${total}"`);

  const opened = await page.evaluate(() => window.__opened);
  const waUrl = decodeURIComponent(opened[opened.length - 1] || "");
  check(waUrl.startsWith("https://wa.me/213555123456"), `WhatsApp opened with the number from store_settings: ${waUrl.slice(0,34)}`);
  check(waUrl.includes(oid), "WhatsApp message carries the server's order number");
  check(!waUrl.includes("undefined") && !waUrl.includes("null"), "WhatsApp message has no undefined/null placeholders");
  check(decodeURIComponent(waUrl).includes("تفعيل مباشر"),
        "the chosen نوع التفعيل travels with the order to WhatsApp");

  // ---------- tracking ----------
  await page.evaluate(() => window.go("track"));
  await page.fill("#tNum", oid);
  await page.fill("#tLast4", "3456");
  await page.click("#track .btn-primary");
  await page.waitForTimeout(1200);
  const tr = await page.locator("#tResult").innerText();
  check(tr.includes(oid) && tr.includes("مراجعة الدفع"), `tracking returned the order: ${tr.split("\n").join(" | ").slice(0,80)}`);

  await page.fill("#tLast4", "9999");
  await page.click("#track .btn-primary");
  await page.waitForTimeout(1200);
  const tr2 = await page.locator("#tResult").innerText();
  check(!tr2.includes(oid), "tracking with the wrong phone reveals nothing");

  check(errors.length === 0, `no JS errors on the page${errors.length ? " -> " + errors.slice(0,3).join(" | ") : ""}`);

  await page.screenshot({ path: "/tmp/claude-0/-home-user-JANEIRO/68cc013f-a073-5abe-9b55-e7d0bdbc6503/scratchpad/mock/shop.png", fullPage: false });
  await browser.close();
  console.log(failures ? `\n\x1b[31m${failures} FAILED\x1b[0m` : "\n\x1b[32mALL E2E CHECKS PASSED\x1b[0m");
  process.exit(failures ? 1 : 0);
})();
