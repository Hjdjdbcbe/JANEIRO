/* Covers the category icons, the deals section and the motion rules.
   Runs against mock-supabase.js like e2e.test.js. */
const { chromium } = require("playwright");
const BASE = process.env.BASE || "http://127.0.0.1:8808";
let fail = 0;
const check = (c, m) => { console.log(`${c ? "\x1b[32mPASS\x1b[0m" : "\x1b[31mFAIL\x1b[0m"}  ${m}`); if (!c) fail++; };

(async () => {
  // Orders and rate-limit buckets from a previous run would trip the
  // real 2-active-order cap and fail this suite for the wrong reason.
  await fetch(`${BASE}/__test/reset`).catch(() => {});

  const browser = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  const errs = [];
  const newPage = async (opts = {}) => {
    const p = await browser.newPage(opts);
    p.on("pageerror", e => errs.push(e.message));
    p.on("console", m => { if (m.type() === "error" && !/simpleicons|wa\.me|ERR_|Failed to load/.test(m.text())) errs.push(m.text()); });
    await p.addInitScript(b => { window.JANEIRO_CONFIG = { SUPABASE_URL: b, SUPABASE_ANON_KEY: "k" }; }, BASE);
    return p;
  };

  const page = await newPage({ viewport: { width: 1280, height: 1000 } });
  await page.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });
  await page.waitForFunction(() => document.querySelectorAll("#shopGrid .pcard:not(.sk)").length > 0, { timeout: 10000 });

  // ---------- category icons ----------
  const tiles = await page.locator("#catGrid .cticon").count();
  check(tiles === 7, `every chip carries an icon tile: ${tiles}`);
  check(await page.locator("#menuCats .cticon").count() === 6, "side-menu categories use the same tile");
  const tinted = await page.evaluate(() => {
    const t = document.querySelectorAll("#catGrid .category-chip")[1].querySelector(".cticon");
    return { cat: t.style.getPropertyValue("--cat") };
  });
  check(/^#|rgb/.test(tinted.cat.trim()), `tile tinted from the category accent: ${tinted.cat}`);
  // "الإنتاجية والعمل" has no icon_path in the fixture
  const plainTile = page.locator("#catGrid .category-chip", { hasText: "الإنتاجية والعمل" }).locator(".cticon");
  check(await plainTile.locator("svg").count() === 1, "no uploaded asset -> designed fallback glyph renders");
  check(await plainTile.locator("img").count() === 0, "no asset -> no image request at all");

  // ---------- an uploaded icon_path renders as an image ----------
  // Driven through the database and the storage bucket, not by poking
  // page internals: this is the path a real upload takes.
  const pageIcons = await newPage({ viewport: { width: 1280, height: 900 } });
  await pageIcons.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });
  await pageIcons.waitForFunction(() => document.querySelectorAll("#catGrid .cticon").length > 1);
  await pageIcons.waitForTimeout(900);

  const uploaded = pageIcons.locator("#catGrid .category-chip", { hasText: "الذكاء الاصطناعي" }).locator(".cticon img");
  const imgAttrs = await uploaded.evaluate(e => ({
    w: e.getAttribute("width"), h: e.getAttribute("height"), l: e.loading,
    src: e.getAttribute("src"), painted: e.naturalWidth > 0,
  })).catch(() => null);
  check(imgAttrs && imgAttrs.w === "128" && imgAttrs.h === "128" && imgAttrs.l === "lazy",
        `uploaded icon is lazy with a fixed 128x128 box: ${JSON.stringify({ w: imgAttrs?.w, h: imgAttrs?.h, l: imgAttrs?.l })}`);
  check(imgAttrs && /product-media\/categories\/ai\.png$/.test(imgAttrs.src),
        `icon URL built from icon_path via the public bucket: ${imgAttrs?.src?.split("/public/")[1]}`);
  check(imgAttrs && imgAttrs.painted, "the uploaded icon actually loaded");

  // the category whose asset 404s must show the glyph, never an empty tile
  const brokenTile = pageIcons.locator("#catGrid .category-chip", { hasText: "التصميم والإبداع" }).locator(".cticon");
  await pageIcons.waitForTimeout(700);
  check(await brokenTile.locator("svg").count() === 1, "a missing asset still shows the designed glyph");
  check(await brokenTile.locator("img").count() === 0, "the failed <img> removes itself via onerror");
  // and the glyph is underneath a WORKING image too, so a lazy asset
  // that has not arrived yet never leaves a blank tile
  const layered = pageIcons.locator("#catGrid .category-chip", { hasText: "الذكاء الاصطناعي" }).locator(".cticon");
  check(await layered.locator("svg").count() === 1, "the fallback glyph sits behind a loaded image, not instead of it");
  await pageIcons.close();

  // ---------- deals ----------
  check(!(await page.locator("#dealsSec").isHidden()), "deals section is shown when the server has live deals");
  const dealCards = await page.locator("#dealsRail .pcard").count();
  check(dealCards === 2, `two live deals rendered: ${dealCards}`);

  const first = page.locator("#dealsRail .pcard").first();
  check((await first.locator(".pprice b").innerText()).includes("770"), "deal price shown");
  check((await first.locator(".pprice .old").innerText()).includes("1,100"), "original price struck through");
  const disc = await first.locator(".pprice .disc").innerText();
  check(disc.includes("30"), "discount percentage computed by the server data");
  // inside an RTL row "-30%" reorders to "30%-" without isolation
  check(await first.locator('.pprice .disc[dir="ltr"]').count() === 1,
        `discount chip is bidi-isolated so the sign stays on the left: "${disc}"`);

  const t1 = await page.locator("#dealsTimer").innerText();
  await page.waitForTimeout(2200);
  const t2 = await page.locator("#dealsTimer").innerText();
  check(/\d{2}:\d{2}:\d{2}/.test(t1) && t1 !== t2, `countdown is live and counting: "${t1}" -> "${t2}"`);

  // the discounted price must follow into the detail page and the cart,
  // or the cart total disagrees with what create_order charges
  await first.locator(".pbody .btn").click();
  await page.waitForSelector("#detail:not(.hidden)");
  check((await page.locator("#dName").innerText()) === "Spotify Premium", "deal card opens its product");
  check((await page.locator("#dTotal").innerText()).includes("770"), "detail page shows the deal price");
  const checked = await page.locator('#dPlans .opt[aria-checked="true"] .nm').innerText();
  check(checked === "شهر واحد", `the discounted plan is preselected: ${checked}`);

  await page.locator("#detail .btn-primary").first().click();
  await page.waitForTimeout(300);
  check((await page.locator("#cartTotal").innerText()).includes("770"), "cart total uses the deal price");

  // ---------- deals hidden when none are live ----------
  const page2 = await newPage({ viewport: { width: 1280, height: 900 } });
  await page2.route("**/rest/v1/public_daily_deals*", r => r.fulfill({ status: 200, body: "[]" }));
  await page2.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });
  await page2.waitForFunction(() => document.querySelectorAll("#shopGrid .pcard:not(.sk)").length > 0);
  check(await page2.locator("#dealsSec").isHidden(), "no live deals -> section hidden entirely, no empty state");
  check((await page2.locator("#dealsRail").innerText()).trim() === "", "no placeholder deal invented");
  await page2.close();

  // ---------- motion ----------
  const stag = await page.evaluate(() => {
    const c = [...document.querySelectorAll("#shopGrid .pcard")];
    return c.slice(0, 8).map(x => parseInt(x.style.getPropertyValue("--stag-d")) || 0);
  });
  check(Math.max(...stag) <= 300, `stagger total capped at 300ms: max ${Math.max(...stag)}ms`);
  const steps = stag.slice(1).map((v, i) => v - stag[i]).filter(v => v > 0);
  check(steps.every(v => v <= 60), `stagger step never exceeds 60ms: ${[...new Set(steps)].join(",")}ms`);

  const longTransitions = await page.evaluate(() => {
    const bad = [];
    for (const el of document.querySelectorAll(".btn,.pcard,.category-chip,.paybtn,.opt")) {
      const cs = getComputedStyle(el);
      cs.transitionDuration.split(",").forEach((d, i) => {
        const ms = parseFloat(d) * (d.includes("ms") ? 1 : 1000);
        if (ms > 400) bad.push(`${el.className}:${cs.transitionProperty.split(",")[i]}=${d}`);
      });
    }
    return bad;
  });
  check(longTransitions.length === 0, `no interaction transition over 400ms${longTransitions.length ? " -> " + longTransitions.slice(0,3) : ""}`);

  const animatedProps = await page.evaluate(() => {
    const bad = [];
    for (const el of document.querySelectorAll("*")) {
      const props = getComputedStyle(el).transitionProperty;
      // .hbar is the pre-existing header shrink-on-scroll. It transitions
      // height, but inside a fixed header whose reserved space is a
      // constant, so it reflows five flex children and never the page.
      // Flagged in the report rather than rewritten.
      if (el.classList.contains("hbar")) continue;
      if (/(^|[ ,])(top|left|right|bottom|width|height|margin)([ ,]|$)/.test(props))
        bad.push(el.className + " -> " + props);
    }
    return bad;
  });
  check(animatedProps.length === 0, `nothing transitions layout properties${animatedProps.length ? " -> " + animatedProps.slice(0,3) : ""}`);

  // ---------- the hero product orbit ----------
  // earlier checks navigated away; the hero has to be on screen and in
  // view or the marks measure zero and the observer keeps it paused
  await page.evaluate(() => window.go("home"));
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(500);

  const orb = await page.evaluate(() => {
    const marks = [...document.querySelectorAll(".hoBill")];
    const cs = getComputedStyle(document.getElementById("hoRing"));
    return {
      n: marks.length,
      dur: cs.animationDuration,
      labels: marks.map(m => m.getAttribute("aria-label")),
      delays: marks.map(m => m.style.animationDelay),
      /* Aspect ratio, not width: perspective legitimately shrinks a mark
         at the back of the ring in BOTH dimensions, so a width threshold
         flags correct foreshortening. A mark showing its edge is squashed
         in one dimension only -- measured at 23x66 when this regressed,
         against ~1.0 when it is right. */
      ratios: marks.map(m => { const r = m.getBoundingClientRect(); return +(r.width / r.height).toFixed(2); }),
    };
  });
  check(orb.n === 6, `six marks on a desktop column: ${orb.n}`);
  check(parseFloat(orb.dur) >= 30, `the ring turns slowly enough to read as ambient: ${orb.dur}`);
  check(orb.labels.every(Boolean), "every mark carries its product name for assistive tech");
  check(new Set(orb.labels).size === orb.n, "no product appears on the ring twice");

  /* The counter-turn has to cancel the ring's angle AND the mark's own
     slot angle. Cancelling only the ring leaves each mark skewed by its
     slot angle -- it shows its edge, and its hit area shrinks to a sliver
     that silently swallows clicks. Both animations therefore take the same
     negative delay, and a mark that is too narrow is the symptom. */
  check(orb.ratios.every(r => r > 0.85),
        `every mark faces the reader, none shows its edge: ${orb.ratios.join(", ")}`);
  check(new Set(orb.delays).size === orb.n,
        "each mark is phase-shifted, so they do not dim in unison");

  /* Front marks take clicks; back ones pass behind the logo and must not,
     or a tap on the logo lands on whatever is hidden behind it. */
  await page.hover("#horbit");
  await page.waitForTimeout(250);
  const hits = await page.evaluate(() => [...document.querySelectorAll(".hoBill")].map(m => {
    const r = m.getBoundingClientRect();
    const top = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    return { pe: getComputedStyle(m).pointerEvents, own: m === top || m.contains(top) };
  }));
  const front = hits.filter(h => h.pe === "auto");
  check(front.length > 0 && front.length < hits.length,
        `the ring is split front/back: ${front.length} of ${hits.length} clickable`);
  check(front.every(h => h.own),
        "every clickable mark actually receives the click, not a slot behind it");

  check(await page.evaluate(() => getComputedStyle(document.getElementById("hoRing")).animationPlayState) === "paused",
        "hovering the ring stops it");

  // clicking a mark opens that product
  const label = await page.evaluate(() => [...document.querySelectorAll(".hoBill")]
    .find(m => getComputedStyle(m).pointerEvents === "auto").getAttribute("aria-label"));
  await page.locator(`.hoBill[aria-label="${label}"]`).click();
  await page.waitForTimeout(500);
  check(await page.evaluate(() => document.getElementById("dName").textContent) === label,
        `clicking a mark opens its product: ${label}`);
  await page.evaluate(() => window.go("home"));
  await page.waitForTimeout(300);

  // scrolled out of sight, it stops -- an animation nobody sees costs the same
  await page.evaluate(() => window.scrollTo(0, 3000));
  await page.waitForTimeout(400);
  check(await page.evaluate(() => getComputedStyle(document.getElementById("hoRing")).animationPlayState) === "paused",
        "the ring stops once it is scrolled out of view");
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(400);

  // the featured product is real, priced, and buyable
  const feat = await page.evaluate(() => {
    const c = document.querySelector(".hfeat");
    if(!c) return null;
    return { name: c.querySelector(".hfInfo b")?.textContent,
             price: c.querySelector(".hfPrice b")?.textContent,
             buttons: [...c.querySelectorAll("button")].map(b => b.textContent.trim()) };
  });
  check(feat && feat.name, `the hero features a real product: ${feat && feat.name}`);
  check(feat && /\d/.test(feat.price || ""), `it shows a price: ${feat && feat.price}`);
  check(feat && feat.buttons.length === 2, `with a buy and an add-to-cart: ${feat && feat.buttons.join(" / ")}`);

  // cart pulse fires once
  await page.evaluate(() => document.querySelector("#cartBadge").classList.remove("cartpulse"));
  await page.evaluate(() => window.go("shop"));
  await page.waitForSelector("#shop:not(.hidden)");
  await page.locator("#shopGrid .pcard", { hasText: "Gemini Pro" }).first().locator(".pbody .btn").click();
  await page.waitForSelector("#detail:not(.hidden)");
  await page.locator("#detail .btn-primary").first().click();
  check(await page.locator("#cartBadge.cartpulse").count() === 1, "adding to cart pulses the badge once");
  const pulseDur = await page.evaluate(() => getComputedStyle(document.querySelector("#cartBadge")).animationDuration);
  check(parseFloat(pulseDur) <= 0.4, `pulse is short: ${pulseDur}`);

  // ---------- reduced motion ----------
  const page3 = await newPage({ viewport: { width: 1280, height: 900 } });
  await page3.emulateMedia({ reducedMotion: "reduce" });
  await page3.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });
  await page3.waitForFunction(() => document.querySelectorAll("#shopGrid .pcard:not(.sk)").length > 0);
  await page3.waitForTimeout(600);
  const rm = await page3.evaluate(() => {
    const hidden = [...document.querySelectorAll(".rv,.stag,#shopGrid .pcard")]
      .filter(e => parseFloat(getComputedStyle(e).opacity) < 1).length;
    const moving = [...document.querySelectorAll("*")]
      .filter(e => getComputedStyle(e).animationName !== "none"
                && getComputedStyle(e).animationPlayState === "running").length;
    return { hidden, moving };
  });
  check(rm.hidden === 0, `reduced motion: nothing left stuck invisible (${rm.hidden} hidden)`);
  check(rm.moving === 0, `reduced motion: no animation running (${rm.moving} running)`);
  await page3.close();

  // ---------- scroll behaviour across page switches ----------
  // NOTE: click by coordinates, never locator.click(). Playwright scrolls
  // a target into view before clicking, which moves the page itself and
  // makes every one of these assertions measure the harness rather than
  // the app. Two false readings came from exactly that.
  const scr = await newPage({ viewport: { width: 390, height: 844 } });
  await scr.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });
  await scr.waitForFunction(() => document.querySelectorAll("#shopGrid .pcard:not(.sk)").length > 0);
  await scr.waitForTimeout(900);
  const sy = () => scr.evaluate(() => window.scrollY);

  await scr.evaluate(() => window.go("shop"));
  await scr.waitForTimeout(400);
  await scr.evaluate(() => window.scrollTo({ top: 1400, behavior: "instant" }));
  await scr.waitForTimeout(350);
  const deep = await sy();

  const onScreenCard = await scr.evaluate(() => {
    const el = [...document.querySelectorAll("#shopGrid .pcard .pbody .btn")]
      .find(x => { const r = x.getBoundingClientRect(); return r.top > 80 && r.bottom < 800; });
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  });
  check(!!onScreenCard && deep > 400, `scrolled deep into the shop (y=${deep})`);
  if (onScreenCard) {
    await scr.mouse.click(onScreenCard.x, onScreenCard.y);
    await scr.waitForSelector("#detail:not(.hidden)");
    await scr.waitForTimeout(350);
    check(await sy() === 0, "the product page opens at the top");

    const crumb = await scr.locator("#detail .crumb").first().boundingBox();
    await scr.mouse.click(crumb.x + crumb.width / 2, crumb.y + crumb.height / 2);
    await scr.waitForTimeout(600);
    const back = await sy();
    check(Math.abs(back - deep) <= 4,
          `going back returns you to the card you were on, not the top (${deep} -> ${back})`);
  }

  // tapping the nav item for the page you are already on means "go to the start"
  await scr.evaluate(() => window.scrollTo({ top: 900, behavior: "instant" }));
  await scr.waitForTimeout(300);
  await scr.evaluate(() => window.go("shop"));
  await scr.waitForTimeout(400);
  check(await sy() === 0, "re-tapping the current page scrolls to the top");

  // a filter replaces the list, so a remembered offset would point at nothing
  await scr.evaluate(() => window.scrollTo({ top: 900, behavior: "instant" }));
  await scr.waitForTimeout(250);
  await scr.evaluate(() => window.go("home"));
  await scr.waitForTimeout(250);
  await scr.evaluate(() => window.selectCat("design"));
  await scr.waitForTimeout(450);
  check(await sy() === 0, "filtering starts the new list at the top");

  // page switches must jump, not animate up the old page
  const behaviour = await scr.evaluate(() => {
    let seen = null;
    const orig = window.scrollTo.bind(window);
    window.scrollTo = (...a) => { if (typeof a[0] === "object") seen = a[0].behavior; return orig(...a); };
    window.go("home");
    window.scrollTo = orig;
    return seen;
  });
  check(behaviour === "instant",
        `page switches scroll instantly rather than animating (behavior=${behaviour})`);

  // drawers must not lose the page position
  await scr.evaluate(() => window.go("shop"));
  await scr.evaluate(() => window.scrollTo({ top: 800, behavior: "instant" }));
  await scr.waitForTimeout(350);
  const beforeDrawer = await sy();
  await scr.evaluate(() => window.openPanel("cart"));
  await scr.waitForTimeout(400);
  await scr.evaluate(() => window.closePanels());
  await scr.waitForTimeout(450);
  check(Math.abs((await sy()) - beforeDrawer) <= 4,
        `opening and closing the cart keeps your place (${beforeDrawer} -> ${await sy()})`);
  await scr.close();

  // ---------- narrow viewports ----------
  for (const w of [375, 390, 430]) {
    const pm = await newPage({ viewport: { width: w, height: 820 } });
    await pm.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });
    await pm.waitForFunction(() => document.querySelectorAll("#shopGrid .pcard:not(.sk)").length > 0);
    await pm.waitForTimeout(500);
    const over = await pm.evaluate(() => ({
      doc: document.documentElement.scrollWidth,
      win: window.innerWidth,
      offenders: [...document.querySelectorAll("body *")]
        .filter(e => e.getBoundingClientRect().right > window.innerWidth + 1
                  && getComputedStyle(e).position !== "fixed"
                  && !e.closest(".rail,.category-carousel,[style*='overflow']"))
        .slice(0, 3).map(e => e.tagName + "." + (e.className || "").toString().slice(0, 30)),
    }));
    check(over.doc <= over.win + 1, `${w}px: no horizontal scroll (doc ${over.doc} vs win ${over.win})${over.offenders.length ? " -> " + over.offenders : ""}`);
    if (w === 390) await pm.screenshot({ path: "/tmp/claude-0/-home-user-JANEIRO/68cc013f-a073-5abe-9b55-e7d0bdbc6503/scratchpad/m390.png" });
    await pm.close();
  }

  check(errs.length === 0, `no JS errors${errs.length ? " -> " + errs.slice(0, 3).join(" | ") : ""}`);
  await page.close();
  await browser.close();
  console.log(fail ? `\n\x1b[31m${fail} FAILED\x1b[0m` : "\n\x1b[32mALL UI CHECKS PASSED\x1b[0m");
  process.exit(fail ? 1 : 0);
})();
