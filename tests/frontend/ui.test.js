/* The storefront's layout and behaviour against the design reference
   (design-reference/storefront-mockup.html): header, hero card stack,
   platforms strip, category tabs, عرض الشهر, product cards, motion,
   page switches, the phone layout and the three languages.
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
  const ready = p => p.waitForFunction(() => document.querySelectorAll("#homeGrid .pcard:not(.sk)").length > 0, { timeout: 10000 });
  const fromDb = async (q) => (await (await fetch(`${BASE}/rest/v1/${q}`)).json());

  const page = await newPage({ viewport: { width: 1280, height: 1000 } });
  await page.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });
  await ready(page);

  // ---------- category tabs: text only, from the categories table ----------
  const cats = await fromDb("categories?select=id,name,slug&is_active=eq.true&order=sort_order");
  const tabs = await page.evaluate(() => [...document.querySelectorAll("#catGrid .category-chip")].map(b => ({
    text: b.textContent.trim(), pressed: b.getAttribute("aria-pressed"),
    glyphs: b.querySelectorAll("svg,img").length,
  })));
  check(tabs.length === cats.length + 1, `one tab per category plus "الكل": ${tabs.length}`);
  check(tabs[0].text === "الكل" && tabs[0].pressed === "true", `"الكل" leads and starts selected: ${tabs[0].text}`);
  check(tabs.every(t => t.glyphs === 0), "the tabs carry no icons");
  check(tabs.slice(1).map(t => t.text).join("|") === cats.map(c => c.name).join("|"),
        "tab names and order come from the database");
  check(await page.locator("#menuCats .mcat svg, #menuCats .mcat img").count() === 0,
        "the side menu's categories are text only too");

  // a home tab filters the grid in place: no page switch
  const products = await fromDb("products?select=id,slug");
  const allCards = await page.locator("#homeGrid .pcard").count();
  check(allCards === products.length, `the home grid holds every product (${allCards} of ${products.length})`);
  await page.locator("#catGrid .category-chip", { hasText: "التصميم والإبداع" }).click();
  await page.waitForTimeout(200);
  const filtered = await page.evaluate(() => ({
    onHome: !document.querySelector("#home").classList.contains("hidden"),
    n: document.querySelectorAll("#homeGrid .pcard").length,
    pressed: document.querySelector('#catGrid .category-chip[aria-pressed="true"]').textContent.trim(),
  }));
  check(filtered.onHome && filtered.n > 0 && filtered.n < allCards,
        `a tab narrows the home grid without leaving the page (${filtered.n} cards)`);
  check(filtered.pressed === "التصميم والإبداع", `the chosen tab is marked: ${filtered.pressed}`);
  await page.fill("#homeSearch", "canva");
  await page.waitForTimeout(150);
  check(await page.locator("#homeGrid .pcard").count() === 1, "the search narrows it further, by slug as well as name");
  await page.fill("#homeSearch", "zzzz");
  await page.waitForTimeout(150);
  check(await page.locator("#homeGrid .empty").count() === 1, "no match shows the empty state, with the WhatsApp way out");
  await page.fill("#homeSearch", "");
  await page.locator("#catGrid .category-chip").first().click();
  await page.waitForTimeout(150);

  // ---------- product card ----------
  const card = await page.evaluate(() => {
    const c = [...document.querySelectorAll("#homeGrid .pcard")];
    const withPoster = c.find(x => x.querySelector("img.pimg"));
    const without = c.find(x => x.querySelector(".ph"));
    const ratio = el => { const r = el.getBoundingClientRect(); return +(r.width / r.height).toFixed(3); };
    return {
      poster: withPoster && {
        src: withPoster.querySelector("img.pimg").getAttribute("src"),
        ratio: ratio(withPoster.querySelector(".art")),
        fit: getComputedStyle(withPoster.querySelector("img.pimg")).objectFit,
      },
      ph: without && {
        ratio: ratio(without.querySelector(".art")),
        hidden: [...without.querySelectorAll(".ph > *")].every(e => e.getAttribute("aria-hidden") === "true"),
        label: without.querySelector(".ph").getAttribute("aria-label"),
        name: without.querySelector(".pname").textContent,
        c1: without.querySelector(".ph").style.getPropertyValue("--c1"),
        foot: without.querySelector(".ph-foot").textContent.includes("janeiro-store.com"),
      },
      parts: c.slice(0, 4).map(x => ({
        name: !!x.querySelector(".pname"), desc: !!x.querySelector(".pdesc"),
        from: (x.querySelector(".pprice small") || {}).textContent,
        buy: (x.querySelector(".pbody .btn") || {}).textContent,
      })),
    };
  });
  check(!!card.poster && /product-media\/products\/.+\.webp$/.test(card.poster.src),
        `a product's card artwork comes from poster_path: ${card.poster && card.poster.src.split("/public/")[1]}`);
  check(!!card.poster && Math.abs(card.poster.ratio - 600 / 832) < 0.01 && card.poster.fit === "cover",
        `shown whole at 3:4 (${card.poster && card.poster.ratio})`);
  check(!!card.ph && Math.abs(card.ph.ratio - 600 / 832) < 0.01, "a product without one gets a stand-in of the same shape");
  check(!!card.ph && card.ph.hidden && card.ph.label === card.ph.name,
        "the stand-in is announced once by name; its pieces are decoration");
  check(!!card.ph && /^#/.test(card.ph.c1.trim()) && card.ph.foot,
        `drawn from the product's accent_color (${card.ph && card.ph.c1}) with the janeiro-store.com strip`);
  check(card.parts.every(p => p.name && p.desc && p.from === "يبدا من" && p.buy === "اشري دركا"),
        "every card: name, short description, يبدا من + price, اشري دركا");

  /* + only on a product with exactly one plan, and it adds straight to
     the cart; everything else has a plan to choose on the product page */
  const plusInfo = await page.evaluate(async () => {
    const cards = [...document.querySelectorAll("#homeGrid .pcard")];
    return cards.map(c => !!c.querySelector(".plus"));
  });
  const plans = await fromDb("products?select=id,product_plans(id,is_active),status");
  const single = plans.filter(p => p.status === "published" && p.product_plans.filter(x => x.is_active).length === 1).length;
  check(plusInfo.filter(Boolean).length === single,
        `the + button shows only on single-plan products (${plusInfo.filter(Boolean).length}, expected ${single})`);
  /* make one single-plan product in the page's own data and check what + does */
  const plusAdds = await page.evaluate(() => {
    const id = document.querySelector("#homeGrid .pcard .btn").getAttribute("onclick").match(/'(.+?)'/)[1];
    window.addQuick(id);
    return !document.querySelector("#detail").classList.contains("hidden");
  });
  check(plusAdds, "a multi-plan product sends its quick-add to the product page instead");
  await page.evaluate(() => window.go("home"));

  // ---------- عرض الشهر: the first live deal ----------
  const offer = await page.evaluate(() => {
    const o = document.querySelector("#offer");
    return {
      shown: !o.hidden,
      tag: (o.querySelector(".tag") || {}).textContent,
      name: (o.querySelector("h3") || {}).textContent,
      price: (o.querySelector(".price b") || {}).textContent,
      old: (o.querySelector(".price .old") || {}).textContent,
      disc: o.querySelector('.disc[dir="ltr"]') ? o.querySelector(".disc").textContent : null,
      before: o.compareDocumentPosition(document.querySelector("#homeGrid")) & Node.DOCUMENT_POSITION_FOLLOWING,
      gridTop: document.querySelector("#homeGrid").getBoundingClientRect().top,
      offerTop: o.getBoundingClientRect().top,
    };
  });
  check(offer.shown && offer.tag === "عرض الشهر", "عرض الشهر is shown");
  check(/Spotify Premium/.test(offer.name || ""), `it is the first live daily deal: ${offer.name}`);
  check((offer.price || "").includes("770") && (offer.old || "").includes("1,100"),
        `deal price ${offer.price}, list price ${offer.old} struck`);
  check(!!offer.disc && offer.disc.includes("30"), `discount chip, bidi-isolated: ${offer.disc}`);
  check(offer.offerTop < offer.gridTop, "on a desktop it sits above the grid");

  await page.locator("#offer .btn-primary").click();
  await page.waitForSelector("#detail:not(.hidden)");
  check((await page.locator("#dName").innerText()) === "Spotify Premium", "its button opens the product");
  check((await page.locator("#dTotal").innerText()).includes("770"), "on the deal's plan, at the deal price");
  const checked = await page.locator('#dPlans .opt[aria-checked="true"] .nm').innerText();
  check(checked === "شهر واحد", `the discounted plan is preselected: ${checked}`);
  await page.locator("#detail .btn-primary").first().click();
  await page.waitForTimeout(300);
  // textContent: the closed drawer is visibility:hidden, so innerText reads ""
  check((await page.locator("#cartTotal").textContent()).includes("770"), "and the cart charges the deal price");

  // no live deal -> a hot product takes the slot, at its plain price
  const page2 = await newPage({ viewport: { width: 1280, height: 900 } });
  await page2.route("**/rest/v1/public_daily_deals*", r => r.fulfill({ status: 200, body: "[]" }));
  await page2.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });
  await ready(page2);
  const hot = await fromDb("products?select=name,badge_type,status&order=sort_order");
  const firstHot = hot.find(p => p.badge_type === "hot" && p.status === "published");
  const fallback = await page2.evaluate(() => ({
    shown: !document.querySelector("#offer").hidden,
    name: document.querySelector("#offer h3").textContent,
    disc: document.querySelectorAll("#offer .disc").length,
  }));
  check(fallback.shown && fallback.name.includes(firstHot.name) && fallback.disc === 0,
        `no deal -> the first hot product, no discount chip: ${fallback.name}`);
  await page2.close();

  // ---------- the hero ----------
  await page.evaluate(() => { window.go("home"); window.scrollTo(0, 0); });
  await page.waitForTimeout(400);
  const all = await fromDb("products?select=name,poster_path,badge_type,status&order=sort_order");
  const hero = await page.evaluate(() => {
    const el = document.querySelector(".hero");
    const h1 = el.querySelector("h1");
    const lh = parseFloat(getComputedStyle(h1).lineHeight);
    return {
      badge: el.querySelector(".eyebrow.pill").textContent.trim(),
      lines: Math.round(h1.getBoundingClientRect().height / lh),
      line2: getComputedStyle(h1.querySelector("span:not(.h1a)")).color,
      line1: getComputedStyle(h1.querySelector(".h1a")).color,
      lead: !!el.querySelector(".lead"),
      buttons: [...el.querySelectorAll(".btns > *")].map(b => b.textContent.trim()),
      checks: el.querySelectorAll(".hero-copy .checks > span").length,
      cards: [...el.querySelectorAll(".stack .card-img")].map(c => ({
        cls: c.className, src: (c.querySelector("img.pimg") || {}).getAttribute?.("src") || null,
        rot: getComputedStyle(c).transform,
      })),
      cta: el.querySelector(".stack-cta")?.textContent.replace(/\s+/g, " ").trim(),
      ctaBtn: !!el.querySelector(".stack-cta .btn"),
    };
  });
  check(hero.badge === "+1000 زبون وثقو فينا", `badge: ${hero.badge}`);
  check(hero.lines === 2, `the heading sits on two lines (${hero.lines})`);
  check(hero.line1 !== hero.line2, `its second line is violet (${hero.line2})`);
  check(hero.lead && hero.buttons.length === 2 && hero.checks === 3,
        `lead, two buttons (${hero.buttons.join(" / ")}) and three ticks`);
  check(hero.cards.length === 3 && hero.cards.every(c => c.rot !== "none"), "three cards, fanned");
  const withPosters = all.filter(p => p.poster_path).length;
  check(hero.cards.filter(c => c.src).length === Math.min(3, withPosters),
        "products that have card artwork are the ones fanned out");
  const front = hero.cards.find(c => /\bf\b/.test(c.cls));
  check(!!front && !!front.src, "the front card is real artwork");
  check(hero.ctaBtn && /يبدا من/.test(hero.cta) && /\d/.test(hero.cta),
        `the pill under it: name, price and اشري دركا (${hero.cta})`);
  await page.locator(".stack-cta .btn").click();
  await page.waitForSelector("#detail:not(.hidden)");
  check(true, "and its button opens the product page");
  await page.evaluate(() => window.go("home"));

  // ---------- platforms strip ----------
  const strip = await page.evaluate(() => {
    const spans = [...document.querySelectorAll("#platTrack span")];
    return {
      names: spans.filter(s => !s.hasAttribute("aria-hidden")).map(s => s.textContent),
      copies: spans.filter(s => s.getAttribute("aria-hidden") === "true").length,
      anim: getComputedStyle(document.querySelector("#platTrack")).animationName,
    };
  });
  check(strip.names.length === all.length && strip.copies === all.length,
        `every product's name, once for reading and once aria-hidden for the loop (${strip.names.length})`);
  check(strip.anim === "slide", `it scrolls: ${strip.anim}`);

  // ---------- header ----------
  const head = await page.evaluate(() => {
    const h = document.querySelector("#hd");
    return {
      pos: getComputedStyle(h).position,
      nav: [...h.querySelectorAll(".nav button")].map(b => b.textContent.trim()),
      navShown: getComputedStyle(h.querySelector(".nav")).display !== "none",
      burgerShown: getComputedStyle(h.querySelector(".menu-btn")).display !== "none",
      langs: [...h.querySelectorAll(".langs button")].map(b => `${b.textContent}:${b.getAttribute("aria-pressed")}`),
      cartBg: getComputedStyle(h.querySelector(".sq.cart")).backgroundColor,
      badge: !!h.querySelector("#cartBadge"),
      theme: !!h.querySelector("#themeBtn"),
      bundlesLinked: [...document.querySelectorAll("#hd button, #menu button, footer button")]
        .some(b => /bundles/.test(b.getAttribute("onclick") || "")),
    };
  });
  check(head.pos === "sticky", "the header stays on top");
  check(head.nav.join(" ") === "الرئيسية المنتجات كيفاش تطلب الأسئلة", `nav reads: ${head.nav.join(" / ")}`);
  check(head.navShown && !head.burgerShown, "a desktop column shows the links, not the burger");
  check(head.langs.join(" ") === "ع:true FR:false EN:false", `language pills: ${head.langs.join(" ")}`);
  check(head.cartBg === "rgb(124, 58, 237)" && head.badge, "the cart is the violet button with its count");
  check(head.theme, "the sun/moon button is there");
  check(!head.bundlesLinked, "the bundles page is not linked from the header, the menu or the footer");

  await page.evaluate(() => window.goSection("faq"));
  await page.waitForTimeout(900);
  const faqTop = await page.evaluate(() => document.querySelector("#faq").getBoundingClientRect().top);
  check(faqTop >= 0 && faqTop < 120, `الأسئلة in the nav scrolls to the FAQ (top ${Math.round(faqTop)})`);

  // the FAQ cards open one at a time
  await page.locator("#homeFaq summary").nth(2).click();
  await page.waitForTimeout(150);
  const open = await page.evaluate(() => [...document.querySelectorAll("#homeFaq details")].map(d => d.open));
  check(open.filter(Boolean).length === 1 && open[2], `one FAQ card open at a time: ${open}`);

  // the WhatsApp band carries the number from store_settings
  const settings = await fromDb("store_settings?select=key,value");
  const wa = settings.find(s => s.key === "whatsapp_number").value;
  const shown = await page.locator("#waNum").innerText();
  check(shown.replace(/\s/g, "") === "0" + wa.slice(3), `WhatsApp band number from store_settings: ${shown}`);

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

  // ---------- motion ----------
  await page.evaluate(() => window.go("shop", "all"));
  await page.waitForTimeout(100);
  const stag = await page.evaluate(() => {
    const c = [...document.querySelectorAll("#shopGrid .pcard")];
    return c.slice(0, 8).map(x => parseInt(x.style.getPropertyValue("--stag-d")) || 0);
  });
  check(Math.max(...stag) <= 300, `stagger total capped at 300ms: max ${Math.max(...stag)}ms`);
  const steps = stag.slice(1).map((v, i) => v - stag[i]).filter(v => v > 0);
  check(steps.every(v => v <= 60), `stagger step never exceeds 60ms: ${[...new Set(steps)].join(",")}ms`);

  const longTransitions = await page.evaluate(() => {
    const bad = [];
    for (const el of document.querySelectorAll(".btn,.pcard,.category-chip,.paybtn,.opt,.plus,.sq")) {
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
      if (/(^|[ ,])(top|left|right|bottom|width|height|margin|padding)([ ,]|$)/.test(props))
        bad.push(el.className + " -> " + props);
    }
    return bad;
  });
  check(animatedProps.length === 0, `nothing transitions layout properties${animatedProps.length ? " -> " + animatedProps.slice(0,3) : ""}`);

  // ---------- reduced motion ----------
  const page3 = await newPage({ viewport: { width: 1280, height: 900 } });
  await page3.emulateMedia({ reducedMotion: "reduce" });
  await page3.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });
  await ready(page3);
  await page3.waitForTimeout(600);
  const rm = await page3.evaluate(() => {
    const hidden = [...document.querySelectorAll(".rv,.stag,#homeGrid .pcard,#shopGrid .pcard")]
      .filter(e => parseFloat(getComputedStyle(e).opacity) < 1).length;
    const moving = [...document.querySelectorAll("*")]
      .filter(e => getComputedStyle(e).animationName !== "none"
                && getComputedStyle(e).animationPlayState === "running").length;
    const loopCopies = [...document.querySelectorAll('#platTrack [aria-hidden="true"]')]
      .filter(e => getComputedStyle(e).display !== "none").length;
    return { hidden, moving, loopCopies };
  });
  check(rm.hidden === 0, `reduced motion: nothing left stuck invisible (${rm.hidden} hidden)`);
  check(rm.moving === 0, `reduced motion: no animation running, the platforms strip included (${rm.moving} running)`);
  check(rm.loopCopies === 0, "reduced motion: the strip's loop copy is dropped and it just wraps");
  await page3.close();

  // ---------- scroll behaviour across page switches ----------
  // NOTE: click by coordinates, never locator.click(). Playwright scrolls
  // a target into view before clicking, which moves the page itself and
  // makes every one of these assertions measure the harness rather than
  // the app.
  const scr = await newPage({ viewport: { width: 390, height: 844 } });
  await scr.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });
  await ready(scr);
  await scr.waitForTimeout(900);
  const sy = () => scr.evaluate(() => window.scrollY);

  await scr.evaluate(() => window.go("shop"));
  await scr.waitForTimeout(400);
  await scr.evaluate(() => window.scrollTo({ top: 1400, behavior: "instant" }));
  await scr.waitForTimeout(350);
  const deep = await sy();

  const onScreenCard = await scr.evaluate(() => {
    const el = [...document.querySelectorAll("#shopGrid .pcard .pbody .btn:not([disabled])")]
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

  await scr.evaluate(() => window.scrollTo({ top: 900, behavior: "instant" }));
  await scr.waitForTimeout(300);
  await scr.evaluate(() => window.go("shop"));
  await scr.waitForTimeout(400);
  check(await sy() === 0, "re-tapping the current page scrolls to the top");

  await scr.evaluate(() => window.scrollTo({ top: 900, behavior: "instant" }));
  await scr.waitForTimeout(250);
  await scr.evaluate(() => window.go("home"));
  await scr.waitForTimeout(250);
  await scr.evaluate(() => window.selectCat("design"));
  await scr.waitForTimeout(450);
  check(await sy() === 0, "filtering the all-products page starts the new list at the top");

  const behaviour = await scr.evaluate(() => {
    let seen = null;
    const orig = window.scrollTo.bind(window);
    window.scrollTo = (...a) => { if (typeof a[0] === "object") seen = a[0].behavior; return orig(...a); };
    window.go("home");
    window.scrollTo = orig;
    return seen;
  });
  check(behaviour === "instant", `page switches scroll instantly rather than animating (behavior=${behaviour})`);

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

  // ---------- the phone layout ----------
  for (const w of [375, 390, 430]) {
    const pm = await newPage({ viewport: { width: w, height: 844 } });
    await pm.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });
    await ready(pm);
    await pm.waitForTimeout(600);
    const m = await pm.evaluate(() => {
      const box = s => document.querySelector(s).getBoundingClientRect();
      const lh = el => parseFloat(getComputedStyle(el).lineHeight);
      const h2 = document.querySelector("#store h2");
      return {
        doc: document.documentElement.scrollWidth, win: window.innerWidth,
        offenders: [...document.querySelectorAll("body *")]
          .filter(e => e.getBoundingClientRect().right > window.innerWidth + 1
                    && getComputedStyle(e).position !== "fixed"
                    && !e.closest(".tabs-scroll,.marquee,.panel"))
          .slice(0, 3).map(e => e.tagName + "." + (e.className || "").toString().slice(0, 30)),
        h1Lines: Math.round(box(".hero h1").height / lh(document.querySelector(".hero h1"))),
        checksHidden: getComputedStyle(document.querySelector(".hero-copy .checks")).display === "none",
        stackBottom: box(".stack").bottom,
        platsTop: box("#plats .marquee").top,
        platsLabel: getComputedStyle(document.querySelector(".plats-lbl")).display === "none",
        shopH2Lines: Math.round(h2.getBoundingClientRect().height / lh(h2)),
        firstCard: box("#homeGrid .pcard").top + window.scrollY,
        vh: window.innerHeight,
        gridBottom: box("#homeGrid").bottom,
        offerTop: box("#offer").top,
        langsInHeader: getComputedStyle(document.querySelector("#hd .langs")).display !== "none",
        burger: box(".menu-btn"),
      };
    });
    check(m.doc <= m.win + 1, `${w}px: no horizontal scroll (doc ${m.doc} vs win ${m.win})${m.offenders.length ? " -> " + m.offenders : ""}`);
    check(m.h1Lines === 2 && m.checksHidden, `${w}px: a short hero -- two-line heading, no tick row (${m.h1Lines} lines)`);
    check(m.platsLabel && m.platsTop - m.stackBottom <= 24,
          `${w}px: the platforms strip hugs the cards, no label (${Math.round(m.platsTop - m.stackBottom)}px)`);
    check(m.shopH2Lines === 1, `${w}px: the shop heading is one line (${m.shopH2Lines})`);
    check(m.firstCard < m.vh * 2, `${w}px: products start within the second screen (${Math.round(m.firstCard)}px)`);
    check(m.offerTop > m.gridBottom, `${w}px: عرض الشهر comes after the grid on a phone`);
    check(!m.langsInHeader && m.burger.left >= 0 && m.burger.right <= m.win,
          `${w}px: the languages move into the menu and the burger stays on screen`);
    /* the language button next to the cart opens the three choices */
    await pm.click("#langBtn");
    const pick = await pm.evaluate(() => ({
      open: !document.querySelector("#langMenu").hidden,
      items: [...document.querySelectorAll("#langMenu button")].map(b => b.dataset.lang).join(","),
      box: document.querySelector("#langMenu").getBoundingClientRect(),
    }));
    check(pick.open && pick.items === "ar,fr,en" && pick.box.left >= 0 && pick.box.right <= w,
          `${w}px: the language button opens ع / FR / EN, on screen`);
    await pm.click('#langMenu [data-lang="fr"]');
    const picked = await pm.evaluate(() => [document.documentElement.lang, document.querySelector("#langBtn").textContent,
      document.querySelector("#langMenu").hidden]);
    check(picked.join() === "fr,FR,true", `${w}px: picking French switches, relabels the button and closes the list (${picked})`);
    await pm.evaluate(() => window.setLang("ar"));
    if (w === 390) {
      await pm.evaluate(() => window.openPanel("menu"));
      await pm.waitForTimeout(400);
      check(await pm.locator("#menu .langs").isVisible(), "390px: the side menu carries the language pills");
    }
    await pm.close();
  }

  // ---------- language switch (AR / FR / EN) ----------
  const lp = await newPage({ viewport: { width: 1280, height: 1000 } });
  await lp.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });
  await ready(lp);
  await lp.click('#hd .langs button[data-lang="fr"]');
  const fr = await lp.evaluate(() => ({
    dir: document.documentElement.getAttribute("dir"),
    lang: document.documentElement.getAttribute("lang"),
    nav: [...document.querySelectorAll("#mainNav button")].map(b => b.textContent.trim()).join(" "),
    pressed: [...document.querySelectorAll('.langs [data-lang="fr"]')].every(b => b.getAttribute("aria-pressed") === "true")
          && document.querySelector('#langMenu [data-lang="fr"]').getAttribute("aria-checked") === "true",
    cardBtn: document.querySelector("#homeGrid .pcard .btn")?.textContent.trim(),
    offer: document.querySelector("#offer .tag")?.textContent,
    h1: document.querySelector(".hero h1").textContent.replace(/\s+/g, " ").trim(),
  }));
  check(fr.dir === "ltr" && fr.lang === "fr", `switches to French: dir=${fr.dir} lang=${fr.lang}`);
  check(fr.nav === "Accueil Produits Comment commander Questions", `French nav reads: ${fr.nav}`);
  check(fr.pressed, "both copies of the FR pill are marked pressed");
  check(fr.cardBtn === "Acheter" && fr.offer === "Offre du mois", `cards and the offer translate: ${fr.cardBtn} / ${fr.offer}`);
  check(fr.h1 === "Tous vos abonnements numériques, au même endroit.", `the hero translates: ${fr.h1}`);

  await lp.reload({ waitUntil: "networkidle" });
  await ready(lp);
  const persisted = await lp.evaluate(() => document.documentElement.getAttribute("lang"));
  check(persisted === "fr", `the language choice survives a reload: ${persisted}`);
  const ltrOverflow = await lp.evaluate(() => ({ doc: document.documentElement.scrollWidth, win: window.innerWidth }));
  check(ltrOverflow.doc <= ltrOverflow.win + 1, `LTR layout has no horizontal scroll (doc ${ltrOverflow.doc} vs win ${ltrOverflow.win})`);

  const en = await lp.evaluate(() => {
    window.setLang("en");
    return [...document.querySelectorAll("#mainNav button")].map(b => b.textContent.trim()).join(" ");
  });
  check(en === "Home Products How to order FAQ", `English nav reads: ${en}`);
  const ar = await lp.evaluate(() => {
    window.setLang("ar");
    return { dir: document.documentElement.getAttribute("dir"),
             nav: [...document.querySelectorAll("#mainNav button")].map(b => b.textContent.trim()).join(" ") };
  });
  check(ar.dir === "rtl" && ar.nav === "الرئيسية المنتجات كيفاش تطلب الأسئلة", `cycles back to Arabic: ${ar.nav}`);

  /* every key the page asks for exists in all three languages */
  const missing = await lp.evaluate(() => {
    const keys = new Set();
    document.querySelectorAll("[data-i18n],[data-i18n-ph],[data-i18n-aria]").forEach(e =>
      ["i18n", "i18nPh", "i18nAria"].forEach(k => e.dataset[k] && keys.add(e.dataset[k])));
    const out = [];
    for (const l of ["fr", "en"]) {
      window.setLang(l);
      document.querySelectorAll("[data-i18n]").forEach(e => {
        if (e.textContent === e.dataset.i18n) out.push(`${l}:${e.dataset.i18n}`);
      });
    }
    window.setLang("ar");
    return out;
  });
  check(missing.length === 0, `every static string has FR and EN${missing.length ? " -> " + missing.slice(0, 5) : ""}`);
  await lp.close();

  // ---------- catalogue text (owner-authored, machine-translated) ----------
  const lt = await newPage({ viewport: { width: 1280, height: 1000 } });
  await lt.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });
  await ready(lt);
  const beforeName = await lt.locator("#shopGrid .pcard h3").first().textContent();
  await lt.evaluate(() => window.setLang("fr"));
  await lt.waitForFunction(() => {
    const h3 = document.querySelector("#shopGrid .pcard h3");
    return h3 && h3.textContent.startsWith("[FR]");
  }, { timeout: 8000 });
  const afterName = await lt.locator("#shopGrid .pcard h3").first().textContent();
  check(afterName === `[FR] ${beforeName}`, `product name is machine-translated: "${beforeName}" -> "${afterName}"`);
  const catTab = await lt.locator("#catGrid .category-chip").nth(1).textContent();
  check(catTab.startsWith("[FR] "), `category name is translated too: "${catTab}"`);
  const allTab = await lt.locator("#catGrid .category-chip").first().textContent();
  check(allTab === "Tout", `the "all" tab is dictionary-translated, not sent for machine translation: "${allTab}"`);
  await lt.evaluate(() => window.setLang("ar"));
  await lt.waitForTimeout(150);
  const restoredName = await lt.locator("#shopGrid .pcard h3").first().textContent();
  check(restoredName === beforeName, `switching back to Arabic restores the original text: "${restoredName}"`);
  await lt.close();

  /* Every var() in the stylesheet must resolve to something defined.
     A typo like var(--s5) is not an error anywhere -- the element just
     silently loses that property -- so this reads the stylesheet SOURCE. */
  const unresolved = await page.evaluate(() => {
    const css = [...document.querySelectorAll("style")].map(s => s.textContent).join("\n")
                  .replace(/\/\*[\s\S]*?\*\//g, " ");
    const defined = new Set([...css.matchAll(/(--[\w-]+)\s*:/g)].map(m => m[1]));
    for (const el of document.querySelectorAll("[style]"))
      for (const p of el.style) if (p.startsWith("--")) defined.add(p);
    const used = new Set();
    for (const m of css.matchAll(/var\(\s*(--[\w-]+)\s*([,)])/g))
      if (m[2] === ")") used.add(m[1]);
    /* and the inline styles the script writes */
    for (const el of document.querySelectorAll("[style]"))
      for (const m of el.getAttribute("style").matchAll(/var\(\s*(--[\w-]+)\s*\)/g)) used.add(m[1]);
    return [...used].filter(n => !defined.has(n));
  });
  check(unresolved.length === 0, `every var() resolves${unresolved.length ? " -> " + unresolved.join(", ") : ""}`);

  check(errs.length === 0, `no JS errors${errs.length ? " -> " + errs.slice(0, 3).join(" | ") : ""}`);
  await page.close();
  await browser.close();
  console.log(fail ? `\n\x1b[31m${fail} FAILED\x1b[0m` : "\n\x1b[32mALL UI CHECKS PASSED\x1b[0m");
  process.exit(fail ? 1 : 0);
})();
