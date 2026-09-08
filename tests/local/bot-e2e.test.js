/* ============================================================
   اختبار البوت كاملاً: الدالة الحقيقية تعمل على Deno، وتتكلم مع
   قاعدة البيانات المحلية، ونقرأ ما أرسله إلى تليجرام فعلاً.

     node tests/local/bot-e2e.test.js [dbname]

   ما يقف بين الاثنين خادم وهمي واحد يلعب دورين:

     /rest/v1/rpc/<اسم>  — كما يفعل PostgREST، بما في ذلك تشغيل
        الدوال المعلَّنة stable داخل معاملة READ ONLY. هذا بالضبط
        ما يكشف دالة قالت عن نفسها stable ثم كتبت (نفس الخطأ الذي
        أوقع get_certificate على Supabase).
     /bot<token>/<method> — تليجرام: يسجّل كل نداء بدل إرساله،
        فنقرأ نص الرسائل والأزرار التي بناها البوت.

   يحتاج: psql، وdeno. بلا deno يتخطّى نفسه برسالة واضحة.
   ============================================================ */
const http = require("http");
const { execFileSync, spawn } = require("child_process");
const path = require("path");

const DB    = process.argv[2] || process.env.JANEIRO_TEST_DB || "janeiro_test";
const ROOT  = path.resolve(__dirname, "../..");
const STUB  = 8977;
/* Deno.serve() بلا خيارات يستمع على 8000، ولا متغيّر بيئة ولا
   راية سطر أوامر تغيّر ذلك — ودالة Supabase الحقيقية لا تمرّر
   منفذاً. فهذا هو المنفذ، ويُتحقَّق من خلوّه قبل التشغيل. */
const BOT   = 8000;
const TOKEN = "1111:TEST";
const SECRET = "test-webhook-secret";

const OWNER  = 970000001;
const SELLER = 970000002;
const OUTSIDER = 970000009;

let passed = 0;
const green = (s) => `\x1b[32m${s}\x1b[0m`;
const red   = (s) => `\x1b[31m${s}\x1b[0m`;
function ok(msg)  { passed++; console.log(green(`PASS  ${msg}`)); }
function fail(msg) { console.log(red(`FAIL: ${msg}`)); process.exitCode = 1; throw new Error(msg); }
function assert(cond, msg) { cond ? ok(msg) : fail(msg); }

// ---------- psql ----------
function sql(text) {
  return execFileSync("psql", ["-d", DB, "-X", "-A", "-t", "-q", "-v", "ON_ERROR_STOP=1", "-c", text],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

/* قيم JSON -> نصّ SQL. dollar-quoting لأن الأكواد والأسماء
   العربية قد تحمل علامات اقتباس. */
function lit(v) {
  if (v === null || v === undefined) return "null";
  if (typeof v === "number")  return String(v);
  if (typeof v === "boolean") return v ? "true" : "false";
  if (Array.isArray(v)) return `array[${v.map(lit).join(",")}]::text[]`;
  const s = String(v);
  let tag = "q";
  while (s.includes(`$${tag}$`)) tag += "q";
  return `$${tag}$${s}$${tag}$`;
}

// ---------- الخادم الوهمي ----------
const telegramCalls = [];

function readBody(req) {
  return new Promise((res) => {
    let b = "";
    req.on("data", (c) => (b += c));
    req.on("end", () => res(b));
  });
}

const stub = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const body = await readBody(req);

  // ---- تليجرام ----
  if (url.pathname.startsWith(`/bot${TOKEN}/`)) {
    const method = url.pathname.split("/").pop();
    const payload = JSON.parse(body || "{}");
    telegramCalls.push({ method, payload });
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ ok: true, result: { message_id: telegramCalls.length + 100 } }));
  }

  // ---- PostgREST ----
  if (url.pathname.startsWith("/rest/v1/rpc/")) {
    const fn = url.pathname.replace("/rest/v1/rpc/", "");
    const args = JSON.parse(body || "{}");
    const named = Object.entries(args).map(([k, v]) => `${k} => ${lit(v)}`).join(", ");
    let readOnly = false;
    try {
      readOnly = ["s", "i"].includes(
        sql(`select provolatile from pg_proc where proname = ${lit(fn)} limit 1`));
    } catch { /* دالة غير موجودة: يكشفها النداء نفسه بعد سطر */ }
    try {
      const out = sql(`${readOnly ? "begin read only; " : ""}` +
                      `select ${fn}(${named}) as r;${readOnly ? " commit;" : ""}`);
      res.writeHead(200, { "Content-Type": "application/json" });
      return res.end(out === "" ? "null" : out);
    } catch (e) {
      const raw = String(e.stderr || e.message || "");
      const m = raw.match(/ERROR:\s+(.*)/);
      res.writeHead(400, { "Content-Type": "application/json" });
      return res.end(JSON.stringify({ message: (m ? m[1] : raw).trim(), code: "P0001" }));
    }
  }

  res.writeHead(404).end("no");
});

// ---------- إرسال تحديث إلى البوت ----------
let msgId = 500;
async function update(obj, { secret = SECRET } = {}) {
  const r = await fetch(`http://127.0.0.1:${BOT}/`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-telegram-bot-api-secret-token": secret },
    body: JSON.stringify(obj),
  });
  await r.text();
  return r.status;
}

const from = (id) => ({ id, first_name: `مستخدم${id}`, username: `u${id}` });

const message = (id, text, reply_to) => ({
  message: { chat: { id }, from: from(id), text, message_id: ++msgId,
             ...(reply_to ? { reply_to_message: { text: reply_to } } : {}) },
});

const tap = (id, data, message_id = 100) => ({
  callback_query: { id: `cb${++msgId}`, data, from: from(id),
                    message: { chat: { id }, message_id } },
});

// آخر ما أُرسل، وكل الأزرار فيه مسطّحة
function last(method) {
  for (let i = telegramCalls.length - 1; i >= 0; i--)
    if (!method || telegramCalls[i].method === method) return telegramCalls[i];
  return null;
}
const lastText = (m) => last(m)?.payload?.text ?? "";
const buttons = (m) =>
  (last(m)?.payload?.reply_markup?.inline_keyboard ?? []).flat();
const buttonFor = (m, needle) =>
  buttons(m).find((b) => b.text.includes(needle));
function drain() { telegramCalls.length = 0; }

// ---------- التهيئة ----------
function seed() {
  sql(`delete from bot_issues where admin_id in (select id from bot_admins where telegram_id >= 970000000)`);
  sql(`delete from bot_cards where variant_id in (select v.id from bot_variants v join bot_products p on p.id=v.product_id where p.code='e2e')`);
  sql(`delete from bot_variants where product_id in (select id from bot_products where code='e2e')`);
  sql(`delete from bot_products where code='e2e'`);
  sql(`delete from bot_admins where telegram_id >= 970000000`);
}

// ============================================================
async function main() {
  try { execFileSync("deno", ["--version"], { stdio: "ignore" }); }
  catch {
    console.log("SKIP  bot-e2e: deno غير مثبّت (https://deno.com) — تخطّي");
    return;
  }

  // منفذ مشغول يظهر لاحقاً كـ«لم تبدأ الاستماع» — يُقال الآن بوضوح.
  const busy = await fetch(`http://127.0.0.1:${BOT}/`).then(() => true).catch(() => false);
  if (busy) fail(`المنفذ ${BOT} مشغول — أوقف ما يستعمله ثم أعد التشغيل`);

  seed();
  await new Promise((r) => stub.listen(STUB, "127.0.0.1", r));

  const proc = spawn("deno", [
    "run", "--quiet", "--allow-net", "--allow-env",
    `--import-map=${path.join(ROOT, "tests/local/bot-import-map.json")}`,
    path.join(ROOT, "supabase/functions/telegram-bot/index.ts"),
  ], {
    env: {
      ...process.env,
      SUPABASE_URL: `http://127.0.0.1:${STUB}`,
      SUPABASE_SERVICE_ROLE_KEY: "test-service-key",
      TELEGRAM_BOT_TOKEN: TOKEN,
      TELEGRAM_WEBHOOK_SECRET: SECRET,
      TELEGRAM_OWNER_ID: String(OWNER),
      TELEGRAM_API_BASE: `http://127.0.0.1:${STUB}`,
      DENO_DIR: process.env.DENO_DIR || path.join(ROOT, ".deno-cache"),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let denoErr = "";
  proc.stderr.on("data", (d) => { denoErr += d; });
  proc.stdout.on("data", () => {});

  // كل ما بعد spawn داخل try: أي فشل هنا يجب ألا يترك عملية deno
  // معلّقة على المنفذ تُفشل التشغيل التالي لسبب آخر تماماً.
  try {
    const deadline = Date.now() + 120_000;
    for (;;) {
      try { await fetch(`http://127.0.0.1:${BOT}/`, { method: "GET" }); break; } catch { /* ما زال يبني */ }
      if (proc.exitCode !== null) { console.log(denoErr); fail("توقّف deno قبل أن يستمع"); }
      if (Date.now() > deadline) { console.log(denoErr); fail("الدالة لم تبدأ الاستماع خلال دقيقتين"); }
      await new Promise((r) => setTimeout(r, 300));
    }
    await run();
    console.log(`\n${green(`BOT E2E PASSED (${passed} فحصاً)`)}`);
  } finally {
    proc.kill("SIGKILL");
    stub.close();
    seed();
  }
}

async function run() {
  // ========== الحماية ==========
  const bad = await update(message(OWNER, "/start"), { secret: "wrong" });
  assert(bad === 401, "الترويسة السرّية الخاطئة تُرفض بـ401");
  assert(telegramCalls.length === 0, "ولا يُرسَل أي شيء إلى تليجرام");

  // ========== المالك يُفتح من متغيّر البيئة ==========
  drain();
  await update(message(OWNER, "/start"));
  assert(lastText("sendMessage").includes("المالك"), "المالك الأول يُعرَف من TELEGRAM_OWNER_ID");
  assert(!!buttonFor("sendMessage", "شحن أكواد"), "وتظهر له أزرار المالك");
  assert(sql(`select role from bot_admins where telegram_id=${OWNER}`) === "owner",
         "وسُجِّل في قاعدة البيانات كمالك");

  // ========== الغريب ==========
  drain();
  await update(message(OUTSIDER, "/start"));
  assert(lastText("sendMessage").includes("لا تملك صلاحية"), "الغريب يُردّ بلا معلومات");
  assert(buttons("sendMessage").length === 0, "ولا يُعطى أي زر");

  drain();
  await update(tap(OUTSIDER, "m:stock"));
  assert(last("answerCallbackQuery")?.payload.text.includes("لا تملك صلاحية"),
         "والغريب لا يفتح المخزون بضغطة زر مباشرة");
  assert(!last("editMessageText"), "ولا تُعدَّل له أي رسالة");

  // ========== بائع ==========
  drain();
  await update(message(OWNER, `/addadmin ${SELLER} بائع الاختبار`));
  assert(lastText("sendMessage").includes("✅"), "المالك يضيف بائعاً");
  await update(message(SELLER, "/start"));
  assert(!buttonFor("sendMessage", "شحن أكواد"), "البائع لا يرى أزرار المالك");
  assert(!!buttonFor("sendMessage", "بيع بطاقة"), "لكنه يرى زر البيع");

  drain();
  await update(message(SELLER, `/addadmin 970000123 دخيل`));
  assert(lastText("sendMessage").includes("للمالك وحده"), "البائع لا يضيف أدمن");

  // ========== منتج ومدة وأكواد ==========
  drain();
  await update(message(OWNER, "/addproduct e2e منتج الاختبار"));
  assert(lastText("sendMessage").includes("✅"), "إضافة منتج جديد من البوت");
  await update(message(OWNER, "/addvariant e2e year سنة"));
  await update(message(OWNER, "/addvariant e2e 3months 3 أشهر"));
  assert(Number(sql(`select count(*) from bot_variants v join bot_products p on p.id=v.product_id where p.code='e2e'`)) === 2,
         "مدّتان: سنة و3 أشهر");

  drain();
  await update(message(OWNER, "/addcards e2e year\nE2E-A\nE2E-B\nE2E-C"));
  assert(lastText("sendMessage").includes("أُضيفت: <b>3</b>"), "شحن 3 أكواد برسالة واحدة");
  drain();
  await update(message(OWNER, "/addcards e2e year\nE2E-A\nE2E-D"));
  assert(lastText("sendMessage").includes("مكرّرة تُجوهلت: 1"), "المكرّر يُتجاهل ويُعلَن");

  // شحن بالأزرار (الردّ على السؤال)
  drain();
  await update(tap(OWNER, "m:load"));
  const prodBtn = buttonFor("editMessageText", "منتج الاختبار") ?? buttons("editMessageText")[0];
  assert(!!prodBtn, "زر شحن -> اختيار المنتج");
  drain();
  await update(tap(OWNER, prodBtn.callback_data));
  const varBtn = buttonFor("editMessageText", "3 أشهر");
  assert(!!varBtn && varBtn.callback_data.startsWith("lv:"), "ثم اختيار المدة");
  drain();
  await update(tap(OWNER, varBtn.callback_data));
  const prompt = lastText("sendMessage");
  assert(last("sendMessage").payload.reply_markup.force_reply === true,
         "يسأل بردّ إجباري بدل جدول حالة");
  drain();
  await update(message(OWNER, "T-1\nT-2", prompt.replace(/<[^>]+>/g, "")));
  assert(lastText("sendMessage").includes("أُضيفت: <b>2</b>"), "الردّ على السؤال يشحن المدة الصحيحة");
  assert(Number(sql(`select count(*) from bot_cards c join bot_variants v on v.id=c.variant_id where v.code='3months' and c.code like 'T-%'`)) === 2,
         "والأكواد وصلت مدة «3 أشهر» لا غيرها");

  // ========== البيع ==========
  drain();
  await update(tap(SELLER, "m:sell"));
  let pb = buttonFor("editMessageText", "منتج الاختبار");
  await update(tap(SELLER, pb.callback_data));
  const yearBtn = buttonFor("editMessageText", "سنة");
  assert(yearBtn.text.includes("4 متاحة"), "زر المدة يعرض المتاح، وجده: " + yearBtn.text);

  drain();
  await update(tap(SELLER, yearBtn.callback_data));
  const card = last("sendMessage");
  assert(card.payload.text.includes("E2E-A"), "أول بطاقة في الطابور هي أول ما أُضيف");
  assert(card.payload.text.includes("المتبقي في المخزون: <b>3</b>"), "المتبقي 3 بعد الحجز");
  const okBtn = card.payload.reply_markup.inline_keyboard[0][0];
  const noBtn = card.payload.reply_markup.inline_keyboard[0][1];
  assert(okBtn.text.includes("تأكيد") && noBtn.text.includes("إلغاء"), "زرّا التأكيد والإلغاء");
  assert(sql(`select status from bot_cards where code='E2E-A'`) === "reserved",
         "البطاقة محجوزة لا مباعة");

  // ---------- إلغاء ----------
  drain();
  await update(tap(SELLER, noBtn.callback_data));
  const cancelled = lastText("editMessageText");
  assert(cancelled.includes("ملغاة"), "الإلغاء يعدّل نفس الرسالة");
  assert(!cancelled.includes("E2E-A"), "والكود يُمحى من الرسالة لأن البطاقة عادت للتداول");
  assert(sql(`select status from bot_cards where code='E2E-A'`) === "available",
         "والبطاقة رجعت للمخزون");
  assert(Number(sql(`select count(*) from bot_issues i join bot_admins a on a.id=i.admin_id where a.telegram_id=${SELLER} and i.status='confirmed'`)) === 0,
         "ولا تُحسب عملية ناجحة");

  // ---------- تأكيد ----------
  drain();
  await update(tap(SELLER, yearBtn.callback_data));
  const card2 = last("sendMessage");
  assert(card2.payload.text.includes("E2E-A"), "نفس البطاقة تُطرح من جديد بعد الإلغاء");
  drain();
  await update(tap(SELLER, card2.payload.reply_markup.inline_keyboard[0][0].callback_data));
  const done = lastText("editMessageText");
  assert(done.includes("ناجحة"), "التأكيد يعلن نجاح العملية");
  assert(done.includes("مبيعاتك الآن: <b>1</b>"), "ويعرض عدّاد البائع");
  assert(sql(`select status from bot_cards where code='E2E-A'`) === "sold", "والبطاقة صارت مباعة");

  // تأكيد ثانٍ لنفس الرسالة
  drain();
  await update(tap(SELLER, card2.payload.reply_markup.inline_keyboard[0][0].callback_data));
  assert(last("answerCallbackQuery").payload.text.includes("مغلقة"),
         "ضغطة ثانية على تأكيد تُردّ برسالة واضحة");

  // ========== العدّاد ==========
  drain();
  await update(message(SELLER, "/stats"));
  assert(lastText("sendMessage").includes("عمليات ناجحة: <b>1</b>"), "/stats يعطي البائع رقمه");
  drain();
  await update(message(SELLER, "/allstats"));
  assert(lastText("sendMessage").includes("للمالك وحده"), "البائع لا يرى مبيعات غيره");
  drain();
  await update(message(OWNER, "/allstats"));
  const all = lastText("sendMessage");
  assert(all.includes("بائع الاختبار") && all.includes("🥇"), "المالك يرى ترتيب الجميع");

  // ========== نفاد المخزون ==========
  sql(`update bot_cards set status='sold' where variant_id in (select v.id from bot_variants v join bot_products p on p.id=v.product_id where p.code='e2e' and v.code='year')`);
  drain();
  await update(tap(SELLER, yearBtn.callback_data));
  assert(last("answerCallbackQuery").payload.text.includes("نفد المخزون"),
         "نفاد المخزون يُبلَّغ ولا يُخترع كود");
  assert(!last("sendMessage"), "ولا تُرسل رسالة بطاقة");

  // ========== تعطيل بائع ==========
  drain();
  await update(message(OWNER, `/deladmin ${SELLER}`));
  assert(lastText("sendMessage").includes("عُطِّل"), "المالك يعطّل بائعاً");
  drain();
  await update(message(SELLER, "/stock"));
  assert(lastText("sendMessage").includes("لا تملك صلاحية"), "والمعطَّل يُمنع فوراً");
}

main().catch((e) => {
  if (!process.exitCode) { console.error(e); process.exitCode = 1; }
  process.exit(process.exitCode);
});
