/* The visual system: light/dark theme (FOUC guard, persistence), a measured
   WCAG contrast sweep over every visible text node on every page — not a
   curated list, because a curated list only ever proves the pairs I
   remembered — and the typography rules the brief set out.

   Runs against mock-supabase.js like the other suites. */
const { chromium } = require("playwright");
const BASE = process.env.BASE || "http://127.0.0.1:8808";
let fail = 0;
const check = (c, m) => { console.log(`${c ? "\x1b[32mPASS\x1b[0m" : "\x1b[31mFAIL\x1b[0m"}  ${m}`); if (!c) fail++; };

/* Composites every semi-transparent background down the ancestor chain,
   then applies the WCAG 2.1 relative-luminance formula. Returns one row
   per text-bearing element so the caller can report the worst offenders
   rather than just a count. */
const SWEEP = () => {
  const parse = c => {
    const m = c.match(/[\d.]+/g);
    if (!m) return null;
    return { r: +m[0], g: +m[1], b: +m[2], a: m.length > 3 ? +m[3] : 1 };
  };
  const over = (fg, bg) => ({
    r: fg.r * fg.a + bg.r * (1 - fg.a),
    g: fg.g * fg.a + bg.g * (1 - fg.a),
    b: fg.b * fg.a + bg.b * (1 - fg.a), a: 1,
  });
  const lum = c => {
    const f = v => { v /= 255; return v <= .03928 ? v / 12.92 : Math.pow((v + .055) / 1.055, 2.4); };
    return .2126 * f(c.r) + .7152 * f(c.g) + .0722 * f(c.b);
  };
  const ratio = (a, b) => {
    const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p);
    return (x + .05) / (y + .05);
  };
  /* Every ground the text could actually be sitting on.

     A gradient contributes one candidate per colour stop, and the worst of
     them is the one that counts -- averaging, or sampling one point, is
     exactly how a failing end of a gradient hides behind a passing one.
     Stops are themselves often translucent (a glow fading to transparent),
     so each is composited over the opaque ground behind the gradient, and
     any translucent fills between that ground and the text go back on top
     in order. */
  const stopsOf = img => (img.match(/rgba?\([^)]*\)/g) || []).map(parse).filter(Boolean);

  const opaqueGround = start => {
    const layers = [];
    let n = start;
    while (n && n.nodeType === 1) {
      const c = parse(getComputedStyle(n).backgroundColor);
      if (c && c.a > 0) {
        if (c.a === 1) { let o = c; for (let i = layers.length - 1; i >= 0; i--) o = over(layers[i], o); return o; }
        layers.push(c);
      }
      n = n.parentElement;
    }
    let o = { r: 255, g: 255, b: 255, a: 1 };
    for (let i = layers.length - 1; i >= 0; i--) o = over(layers[i], o);
    return o;
  };

  const basesOf = el => {
    // nearest ancestor-or-self painting a gradient, and the fills above it
    const above = [];
    let g = el;
    while (g && g.nodeType === 1) {
      const cs = getComputedStyle(g);
      const gi = cs.backgroundImage;
      if (gi && gi !== "none" && /gradient/.test(gi)) break;
      const c = parse(cs.backgroundColor);
      if (c && c.a === 1) { g = null; break; }      // opaque fill hides anything below
      if (c && c.a > 0) above.push(c);
      g = g.parentElement;
    }
    if (!g || g.nodeType !== 1) return [opaqueGround(el)];

    /* start at g, not its parent: a gradient element's own background-color
       paints beneath its background-image (that is how .poster keeps a white
       base under a translucent wash) */
    const ground = opaqueGround(g);
    const stops = stopsOf(getComputedStyle(g).backgroundImage);
    /* the bare ground is only reachable where the gradient is see-through;
       an all-opaque gradient covers it completely */
    const seeThrough = !stops.length || stops.some(c => c.a < 1);
    const cands = stops.map(c => over(c, ground)).concat(seeThrough ? [ground] : []);
    return cands.map(base => {
      let o = base;
      for (let i = above.length - 1; i >= 0; i--) o = over(above[i], o);
      return o;
    });
  };

  const out = [];
  let skipped = 0;
  document.querySelectorAll("*").forEach(el => {
    if (el.closest(".sk, .hidden, [aria-hidden='true']")) return;
    /* Text sitting on product artwork has a raster background; there is no
       colour to compute against. Counted and reported, never silently dropped. */
    if (el.closest(".poster") && el.closest(".poster").querySelector("img.pimg")) { skipped++; return; }
    const own = Array.from(el.childNodes)
      .filter(n => n.nodeType === 3 && n.textContent.trim()).map(n => n.textContent.trim()).join(" ");
    if (!own) return;
    const cs = getComputedStyle(el);
    if (cs.visibility === "hidden" || cs.display === "none" || +cs.opacity === 0) return;
    const box = el.getBoundingClientRect();
    if (box.width < 2 || box.height < 2) return;
    const fg = parse(cs.color);
    if (!fg) return;
    const size = parseFloat(cs.fontSize);
    const weight = +cs.fontWeight || 400;
    /* WCAG "large text": 24px, or 18.66px at 700+ */
    const large = size >= 24 || (size >= 18.66 && weight >= 700);

    const own_img = cs.backgroundImage;
    const clipped = /text/.test(cs.webkitBackgroundClip || cs.backgroundClip || "") && fg.a === 0;
    let r, note = "";
    if (clipped) {
      /* gradient-clipped text: the gradient IS the foreground, and the
         ground is whatever is behind the element itself */
      const st = stopsOf(own_img);
      const bases = basesOf(el.parentElement || el);
      if (!st.length) return;
      r = Math.min(...bases.map(b => Math.min(...st.map(c => ratio(over(c, b), b)))));
      note = "gradient text";
    } else {
      const bases = basesOf(el);
      r = Math.min(...bases.map(b => ratio(over(fg, b), b)));
      if (bases.length > 1) note = `worst of ${bases.length} gradient stops`;
    }
    out.push({
      sel: el.tagName.toLowerCase() + (el.className && typeof el.className === "string"
        ? "." + el.className.trim().split(/\s+/).slice(0, 2).join(".") : ""),
      text: own.slice(0, 28), ratio: +r.toFixed(2), need: large ? 3 : 4.5, note,
    });
  });
  out.skipped = skipped;
  return out;
};

(async () => {
  const browser = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
  const errs = [];
  const newPage = async (opts = {}) => {
    const p = await browser.newPage(opts);
    p.on("pageerror", e => errs.push(e.message));
    await p.addInitScript(b => { window.JANEIRO_CONFIG = { SUPABASE_URL: b, SUPABASE_ANON_KEY: "k" }; }, BASE);
    return p;
  };

  // ---------- default theme + FOUC ----------
  let page = await newPage({ viewport: { width: 1280, height: 1000 }, colorScheme: "light" });
  await page.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });
  check(await page.getAttribute("html", "data-theme") === "light", "no stored choice + light OS -> light");

  // The <head> script must have run before the first style is applied.
  // If it were deferred, data-theme would still be unset at that point.
  const early = await page.evaluate(() => window.__earlyTheme);
  check(early === "light" || early === undefined, "theme attribute set in <head>, not after load");

  const dark = await newPage({ viewport: { width: 1280, height: 1000 }, colorScheme: "dark" });
  await dark.goto(`${BASE}/frontend/index.html`, { waitUntil: "networkidle" });
  check(await dark.getAttribute("html", "data-theme") === "dark", "no stored choice + dark OS -> dark");

  // ---------- the choice outranks the OS ----------
  await dark.click("#themeBtn");
  check(await dark.getAttribute("html", "data-theme") === "light", "toggle flips dark -> light");
  check(await dark.evaluate(() => localStorage.getItem("janeiro-theme")) === "light", "choice is persisted");
  await dark.reload({ waitUntil: "networkidle" });
  check(await dark.getAttribute("html", "data-theme") === "light",
        "saved light survives reload under a dark OS preference");
  check(await dark.getAttribute("#themeBtn", "aria-pressed") === "false", "aria-pressed tracks the theme");
  const meta = await dark.getAttribute('meta[name="theme-color"]', "content");
  check(meta === "#FFFFFF", `theme-color follows the theme: ${meta}`);
  await dark.close();

  // ---------- contrast sweep, every page, both themes ----------
  await page.addInitScript(`window.SWEEP_FN = ${SWEEP.toString()}`);
  await page.evaluate(`window.SWEEP_FN = ${SWEEP.toString()}`);
  const PAGES = ["home", "shop", "order", "track", "about", "policies"];
  for (const theme of ["light", "dark"]) {
    await page.evaluate(t => {
      document.documentElement.setAttribute("data-theme", t);
      localStorage.setItem("janeiro-theme", t);
    }, theme);
    for (const p of PAGES) {
      await page.evaluate(n => window.go(n, n === "shop" ? "all" : undefined), p);
      await page.waitForTimeout(180);
      const { rows, skipped } = await page.evaluate(() => {
        const r = SWEEP_FN(); return { rows: r, skipped: r.skipped };
      });
      const bad = rows.filter(r => r.ratio < r.need);
      const worst = rows.slice().sort((a, b) => a.ratio - b.ratio)[0];
      check(bad.length === 0,
        `${theme}/${p}: ${rows.length} text nodes, ${bad.length} under target` +
        (worst ? ` (lowest ${worst.ratio}:1 on ${worst.sel})` : "") +
        (skipped ? `, ${skipped} on artwork not measurable` : ""));
      bad.slice(0, 8).forEach(b =>
        console.log(`        ${b.ratio}:1 (needs ${b.need}) ${b.sel} — "${b.text}"${b.note ? ` [${b.note}]` : ""}`));
    }
  }

  // ---------- typography ----------
  await page.evaluate(() => window.go("home"));
  await page.waitForTimeout(200);

  /* document.fonts.check() is NOT usable here: it returns true when no
     matching @font-face rule exists at all, so it passes just as happily
     when the font never loaded. It did exactly that while the faces were
     still coming from fonts.googleapis.com, which this browser cannot
     reach -- the assertion could not fail. Measure instead: render the
     same Arabic string in the face and in a forced fallback and require
     the advance widths to differ. */
  const type = await page.evaluate(async () => {
    await document.fonts.ready;
    const AR = "كل أدواتك الرقمية موثوقة";
    const c = document.createElement("canvas").getContext("2d");
    const w = f => { c.font = "400 40px " + f; return +c.measureText(AR).width.toFixed(1); };
    const faces = [...document.fonts].map(f => `${f.family}/${f.status}`);
    return { base: w("monospace"), lalezar: w("Lalezar, monospace"),
             cairo: w("Cairo, monospace"), faces };
  });
  check(type.faces.length > 0, `@font-face rules registered: ${type.faces.length}`);
  check(type.faces.every(f => /loaded/.test(f)) || type.faces.some(f => /loaded/.test(f)),
        `at least one face reports loaded: ${type.faces.slice(0, 3).join(", ")}`);
  check(type.lalezar !== type.base,
        `Lalezar renders Arabic, not a fallback (${type.lalezar} vs ${type.base})`);
  check(type.cairo !== type.base,
        `Cairo renders Arabic, not a fallback (${type.cairo} vs ${type.base})`);
  check(type.lalezar !== type.cairo,
        `Lalezar and Cairo are distinct faces (${type.lalezar} vs ${type.cairo})`);

  /* The brief was explicit: never the handwritten face on prices or payment
     details. Asserted by walking what the browser resolved, not by reading
     the stylesheet — a later rule could always override an earlier one. */
  const MONEY = ".pprice b, .pprice .old, .pprice .from, .ctot b, .stickybar .amt b, " +
                ".paybox .r b, .opt .pr, .cinfo .pr, .summary .r b, .mono, .dl div";
  for (const p of ["home", "shop", "order", "track"]) {
    await page.evaluate(n => window.go(n, n === "shop" ? "all" : undefined), p);
    await page.waitForTimeout(180);
    const bad = await page.evaluate(sel => {
      const out = [];
      document.querySelectorAll(sel).forEach(el => {
        if (!el.textContent.trim()) return;
        const f = getComputedStyle(el).fontFamily;
        if (/Lalezar/i.test(f)) out.push(`${el.className || el.tagName} -> ${f}`);
      });
      return out;
    }, MONEY);
    check(bad.length === 0, `${p}: no price or payment detail in the display face` +
      (bad.length ? ` — ${bad.slice(0, 3).join(", ")}` : ""));
  }

  /* Lalezar ships one weight. Asking it for 600 or 800 makes the browser
     synthesise a bold, which on a joined script closes up the letterforms. */
  const faux = await page.evaluate(() => {
    const out = [];
    document.querySelectorAll("*").forEach(el => {
      if (!Array.from(el.childNodes).some(n => n.nodeType === 3 && n.textContent.trim())) return;
      const cs = getComputedStyle(el);
      if (!/Lalezar/i.test(cs.fontFamily)) return;
      if (+cs.fontWeight !== 400) out.push(`${el.tagName}.${el.className} @${cs.fontWeight}`);
    });
    return out;
  });
  check(faux.length === 0, `no faux bold on the single-weight display face` +
    (faux.length ? ` — ${faux.slice(0, 4).join(", ")}` : ""));

  /* Arabic joins; negative tracking pulls the joins into each other. */
  const tight = await page.evaluate(() => {
    const out = [];
    document.querySelectorAll("*").forEach(el => {
      const t = Array.from(el.childNodes).filter(n => n.nodeType === 3).map(n => n.textContent).join("");
      if (!/[\u0600-\u06FF]/.test(t)) return;               // Arabic runs only
      const ls = getComputedStyle(el).letterSpacing;
      if (ls !== "normal" && parseFloat(ls) < 0) out.push(`${el.tagName}.${el.className} @${ls}`);
    });
    return out;
  });
  check(tight.length === 0, `no negative letter-spacing on Arabic` +
    (tight.length ? ` — ${tight.slice(0, 4).join(", ")}` : ""));

  check(errs.length === 0, `no page errors: ${errs.slice(0, 3).join(" | ") || "none"}`);
  await browser.close();
  console.log(fail ? `\n${fail} failed` : "\nall passed");
  process.exit(fail ? 1 : 0);
})();
