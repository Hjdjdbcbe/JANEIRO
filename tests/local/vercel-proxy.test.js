/* ============================================================
   وسيط /warranty على Vercel.

     node tests/local/vercel-proxy.test.js [dbname]

   Supabase تستبدل Content-Type بـ text/plain وتضيف sandbox،
   فتخرج وثيقة الزبون كوداً خاماً. الوسيط يعيد بعث الصفحة
   بترويسة صحيحة. هنا تُشغَّل الدالة الحقيقية خلفه، ويُنادى
   الوسيط كما تناديه Vercel — بـreq/res لا بخادم.

   وتُحاكى ترويسات Supabase على الردّ الصاعد: بلا محاكاتها يمرّ
   الاختبار على شيء لا يشبه الواقع الذي كُتب له.
   ============================================================ */
const http = require("http");
const { execFileSync, spawn } = require("child_process");
const path = require("path");

const DB   = process.argv[2] || process.env.JANEIRO_TEST_DB || "janeiro_test";
const ROOT = path.resolve(__dirname, "../..");
const STUB = 8991;   // يلعب دور PostgREST
const BOT  = 8000;   // الدالة الحقيقية
const SB   = 8992;   // يلعب دور بوّابة Supabase: يفسد الترويسة عمداً

let passed = 0;
const green = (s) => `\x1b[32m${s}\x1b[0m`;
const red   = (s) => `\x1b[31m${s}\x1b[0m`;
function assert(cond, msg) {
  if (cond) { passed++; console.log(green(`PASS  ${msg}`)); }
  else { console.log(red(`FAIL: ${msg}`)); process.exitCode = 1; throw new Error(msg); }
}

try { execFileSync("deno", ["--version"], { stdio: "ignore" }); }
catch { console.log("SKIP  vercel-proxy: deno غير مثبّت."); process.exit(0); }

const sql = (t) => execFileSync("psql",
  ["-d", DB, "-X", "-A", "-t", "-q", "-v", "ON_ERROR_STOP=1", "-c", t],
  { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();

function lit(v) {
  if (v === null || v === undefined) return "null";
  if (typeof v === "number") return String(v);
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "object") return `$j$${JSON.stringify(v)}$j$::jsonb`;
  return `$q$${String(v)}$q$`;
}

// ---- PostgREST وهمي ----
const stub = http.createServer(async (req, res) => {
  let b = ""; req.on("data", (c) => (b += c));
  await new Promise((r) => req.on("end", r));
  const fn = new URL(req.url, "http://x").pathname.replace("/rest/v1/rpc/", "");
  const named = Object.entries(JSON.parse(b || "{}"))
    .map(([k, v]) => `${k} => ${lit(v)}`).join(", ");
  try {
    let ro = false;
    try { ro = ["s", "i"].includes(sql(`select provolatile from pg_proc where proname = ${lit(fn)} limit 1`)); } catch {}
    const out = sql(`${ro ? "begin read only; " : ""}select ${fn}(${named}) as r;${ro ? " commit;" : ""}`);
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(out === "" ? "null" : out);
  } catch (e) {
    const m = String(e.stderr || e.message || "").match(/ERROR:\s+(.*)/);
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ message: (m ? m[1] : "err").trim(), code: "P0001" }));
  }
});

/* ---- بوّابة Supabase الوهمية ----
   تنقل الطلب إلى الدالة، ثم تفسد ترويسة الردّ كما تفعل
   Supabase فعلاً. هذا هو الواقع الذي يُختبَر ضدّه. */
const gate = http.createServer(async (req, res) => {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const up = await fetch(`http://127.0.0.1:${BOT}${req.url.replace(/^\/functions\/v1\/telegram-bot/, "")}`, {
    method: req.method,
    redirect: "manual",
    headers: { "content-type": req.headers["content-type"] || "text/plain" },
    body: chunks.length ? Buffer.concat(chunks) : undefined,
  });
  const loc = up.headers.get("location");
  res.writeHead(up.status, {
    "Content-Type": "text/plain",
    "Content-Security-Policy": "default-src 'none'; sandbox",
    "X-Content-Type-Options": "nosniff",
    ...(loc ? { Location: loc } : {}),
  });
  res.end(Buffer.from(await up.arrayBuffer()));
});

// ---- req/res وهميان كما تبنيهما Vercel ----
function call(url, { method = "GET", body, headers = {} } = {}) {
  return new Promise((resolve) => {
    const out = { status: 200, headers: {}, body: "" };
    const req = { url, method, headers, body };
    const res = {
      setHeader: (k, v) => { out.headers[k.toLowerCase()] = v; return res; },
      status: (c) => { out.status = c; return res; },
      end: (b) => { out.body = b ? Buffer.from(b).toString("utf8") : ""; resolve(out); },
    };
    require(path.join(ROOT, "api/warranty/[...path].js"))(req, res);
  });
}

async function main() {
  await new Promise((r) => stub.listen(STUB, "127.0.0.1", r));
  await new Promise((r) => gate.listen(SB, "127.0.0.1", r));

  const proc = spawn("deno", ["run", "--quiet", "--allow-net", "--allow-env",
    `--import-map=${path.join(ROOT, "tests/local/bot-import-map.json")}`,
    path.join(ROOT, "supabase/functions/telegram-bot/index.ts")], {
    env: { ...process.env,
      SUPABASE_URL: `http://127.0.0.1:${STUB}`,
      SUPABASE_SERVICE_ROLE_KEY: "k",
      TELEGRAM_BOT_TOKEN: "1:T", TELEGRAM_WEBHOOK_SECRET: "s",
      TELEGRAM_API_BASE: `http://127.0.0.1:${STUB}`,
      PUBLIC_SITE_URL: "https://janeiro-theta.vercel.app",
      DENO_DIR: process.env.DENO_DIR || path.join(ROOT, ".deno-cache") },
    stdio: "ignore",
  });
  process.env.SUPABASE_URL = `http://127.0.0.1:${SB}`;

  for (let i = 0; i < 60; i++) {
    try { await fetch(`http://127.0.0.1:${BOT}/`); break; }
    catch { await new Promise((r) => setTimeout(r, 250)); }
  }

  try {
    // ---- ما تبعثه البوّابة: هو العطب نفسه ----
    const raw = await fetch(`http://127.0.0.1:${SB}/functions/v1/telegram-bot/warranty/verify/JW-0000000000`);
    assert(raw.headers.get("content-type") === "text/plain",
           "البوّابة تبعث text/plain — هذا هو العطب الذي نصلحه");
    assert((raw.headers.get("content-security-policy") || "").includes("sandbox"),
           "وsandbox معها");

    // ---- وما يبعثه الوسيط ----
    const r = await call("/warranty/verify/JW-0000000000", {
      headers: { "x-forwarded-for": "41.200.5.5" },
    });
    assert(r.status === 200, "الوسيط يمرّر 200");
    assert(r.headers["content-type"] === "text/html; charset=utf-8",
           "ويبعث text/html بترميز utf-8، وجد: " + r.headers["content-type"]);
    assert(!("content-security-policy" in r.headers),
           "ولا ينقل sandbox — وإلا بقيت الصفحة بلا تنسيق");
    assert(r.headers["x-robots-tag"] === "noindex, nofollow", "وممنوعة الفهرسة");
    assert(r.body.startsWith("<!doctype html>"), "والجسم هو الصفحة نفسها");
    assert(/[؀-ۿ]/.test(r.body), "والعربية سليمة لا مشوّهة");

    // ---- الشكل المكتوب في العنوان كما تعيد Vercel كتابته ----
    // رمز آخر: الحدّ على القراءة يُحتسب لكل رمز، وإعادة نفسه
    // تُصيبه فتُرَدّ رسالة حدٍّ لا رسالة «غير موجودة»
    const r2 = await call("/api/warranty/verify/JW-1111111111?lang=fr", {
      headers: { "x-forwarded-for": "41.200.7.7" },
    });
    assert(r2.headers["content-type"] === "text/html; charset=utf-8",
           "والشكل بعد إعادة الكتابة كذلك");
    assert(r2.body.includes("Aucun document"), "واللغة تُنقل في العنوان");

    // ---- التحويل يُنقل ولا يُبتلع ----
    // وثيقة معلّقة تُصنع هنا: الفحص الأهم لا يتخطّى نفسه لأن
    // القاعدة صادف أن كانت خالية منها.
    sql(`insert into bot_admins (telegram_id, display_name, role)
         values (995001, 'وسيط', 'owner')
         on conflict (telegram_id) do nothing`);
    const code = "JW-PROXY00001";
    sql(`delete from bot_certificates where code = '${code}'`);
    sql(`insert into bot_certificates
           (code, ref_code, platform, months, bonus_days, starts_at, ends_at,
            issued_by, filled_at)
         values ('${code}', 'JS-PROXY001', 'Netflix', 12, 0, now(),
                 bot_engagement_expiry(now(), 12, 0, null),
                 (select id from bot_admins where telegram_id = 995001),
                 -- معلّقة: filled_at افتراضيّه now()، ووثيقة الالتزام
                 -- تولد بلا تعبئة كما تفعل bot_engagement_from_issue
                 null)`);
    // 64 خانة hex بالضبط: المسار لا يقبل غيرها، وحرف واحد خارجها
    // يجعل الطلب يسقط إلى مسار الويبهوك فيُردّ 401
    const tok = require("crypto").randomBytes(32).toString("hex");
    sql(`insert into bot_fill_tokens (token, certificate_id, created_by, expires_at)
         values ('${tok}', (select id from bot_certificates where code = '${code}'),
                 (select id from bot_admins where telegram_id = 995001),
                 now() + interval '1 day')`);

    const r3 = await call(`/warranty/claim/${tok}?lang=ar`, {
      method: "POST",
      headers: { "x-forwarded-for": "41.200.9.9" },
      body: { full_name: "زبون الوسيط", whatsapp: "0661223344", instagram: "" },
    });
    assert(r3.status === 303, "الإرسال يردّ 303 لا 200، وجد: " + r3.status);
    assert((r3.headers["location"] || "").includes("janeiro-theta.vercel.app"),
           "والتحويل إلى الموقع لا إلى Supabase، وجد: " + r3.headers["location"]);
    assert(sql(`select (filled_at is not null)::text from bot_certificates
                 where code = '${code}'`) === "true",
           "والبيانات وصلت القاعدة عبر الوسيط");

    // ثم الوثيقة نفسها تُقرأ عبره
    const r5 = await call(`/warranty/${code}?lang=ar`, {
      headers: { "x-forwarded-for": "41.200.9.9" },
    });
    assert(r5.headers["content-type"] === "text/html; charset=utf-8",
           "والوثيقة تُقرأ عبر الوسيط بترويسة صحيحة");
    assert(r5.body.includes("زبون الوسيط"), "وتحمل اسم صاحبها");

    // ---- غياب الإعداد يُقال، ولا يُخرج صفحة بيضاء ----
    const keep = process.env.SUPABASE_URL;
    delete process.env.SUPABASE_URL;
    delete require.cache[require.resolve(path.join(ROOT, "api/warranty/[...path].js"))];
    const r4 = await call("/warranty/verify/JW-0000000000");
    assert(r4.status === 503 && r4.body.includes("SUPABASE_URL"),
           "وبلا SUPABASE_URL يقول ما ينقصه");
    process.env.SUPABASE_URL = keep;

    console.log(green(`\nVERCEL PROXY PASSED (${passed} فحصاً)`));
  } finally {
    try { process.kill(proc.pid); } catch {}
    stub.close(); gate.close();
  }
}

main().catch((e) => {
  if (!process.exitCode) { console.error(e); process.exitCode = 1; }
  process.exit(process.exitCode);
});
