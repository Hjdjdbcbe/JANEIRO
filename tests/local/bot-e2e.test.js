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

/* ملف الدخول: المصدر افتراضاً، أو نسخة اللصق المولَّدة حين
   يُمرَّر BOT_ENTRY. هي ما يُنشر فعلاً على Supabase، فتُشغَّل
   عليها نفس الاختبارات — دمجٌ يسقط منه ملف يُقلع مرة ثم يفشل
   عند أول نداء. */
const ENTRY = process.env.BOT_ENTRY
  ? path.resolve(ROOT, process.env.BOT_ENTRY)
  : path.join(ROOT, "supabase/functions/telegram-bot/index.ts");

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
  /* مصفوفة نصوص -> text[] (أكواد البطاقات). أي شيء آخر مركّب
     -> jsonb، لأن PostgREST يمرّر JSON كما هو إلى وسيط jsonb.
     بلا هذا الفرق كانت مصفوفة الكائنات تصير
     array['[object Object]']::text[] ويختفي الوسيط الصحيح. */
  const json = (x) => {
    const s = JSON.stringify(x);
    let tag = "j";
    while (s.includes(`$${tag}$`)) tag += "j";
    return `$${tag}$${s}$${tag}$::jsonb`;
  };
  if (Array.isArray(v)) {
    return v.every((e) => typeof e === "string")
      ? `array[${v.map(lit).join(",")}]::text[]`
      : json(v);
  }
  if (typeof v === "object") return json(v);
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
  // الوثائق أولاً: bot_certificates.issue_id مقيّد بـ restrict عمداً،
  // فلا تفقد وثيقةٌ بيعتَها. التنظيف يحترم الترتيب نفسه.
  sql(`delete from bot_certificates where issue_id in (
         select i.id from bot_issues i join bot_admins a on a.id = i.admin_id
          where a.telegram_id >= 970000000)`);
  sql(`delete from bot_fields where product_id in (select id from bot_products where code='e2e')`);
  sql(`delete from bot_contacts where label like 'E2E%'`);
  sql(`delete from bot_fill_tokens where created_by in (
         select id from bot_admins where telegram_id >= 970000000)`);
  sql(`delete from bot_certificates where issued_by in (
         select id from bot_admins where telegram_id >= 970000000)`);
  sql(`delete from bot_wizard_state where admin_id in (
         select id from bot_admins where telegram_id >= 970000000)`);
  sql(`delete from bot_platforms where name = 'E2E Platform'`);
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
    ENTRY,
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
  // بالنص لا بالموضع: صفّ زر النسخ يسبقهما الآن
  const kb = (m) => (m.payload.reply_markup?.inline_keyboard ?? []).flat();
  const okBtn = kb(card).find((b) => b.text.includes("تأكيد"));
  const noBtn = kb(card).find((b) => b.text.includes("إلغاء"));
  assert(!!okBtn && !!noBtn, "زرّا التأكيد والإلغاء");
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
  const ok2 = kb(card2).find((b) => b.text.includes("تأكيد"));
  await update(tap(SELLER, ok2.callback_data));
  const done = lastText("editMessageText");
  assert(done.includes("ناجحة"), "التأكيد يعلن نجاح العملية");
  assert(done.includes("إجمالي مبيعاتك: <b>1</b>"), "ويعرض عدّاد البائع");
  assert(sql(`select status from bot_cards where code='E2E-A'`) === "sold", "والبطاقة صارت مباعة");

  // تأكيد ثانٍ لنفس الرسالة
  drain();
  await update(tap(SELLER, ok2.callback_data));
  assert(last("answerCallbackQuery").payload.text.includes("مغلقة"),
         "ضغطة ثانية على تأكيد تُردّ برسالة واضحة");

  // ========== زر النسخ والتفصيل (022) ==========
  // البطاقة الأخيرة أُكِّدت أعلاه؛ نطلب واحدة جديدة لنفحص أزرارها
  drain();
  await update(tap(SELLER, yearBtn.callback_data));
  const withCopy = last("sendMessage").payload.reply_markup.inline_keyboard;
  const copyBtn = withCopy.flat().find((b) => b.copy_text);
  assert(!!copyBtn, "رسالة البطاقة فيها زر نسخ");
  assert(copyBtn.copy_text.text === "E2E-B",
         "وزر النسخ يحمل الكود نفسه، وجد: " + JSON.stringify(copyBtn.copy_text));
  assert(!copyBtn.callback_data, "زر النسخ ينسخ ولا يرسل شيئاً للبوت");

  drain();
  await update(tap(SELLER, withCopy.flat().find((b) => b.text.includes("تأكيد")).callback_data));
  const conf = lastText("editMessageText");
  assert(conf.includes("منتج الاختبار") && conf.includes("سنة"),
         "رسالة التأكيد تقول أي اشتراك بيع");
  assert(conf.includes("بعت من «سنة»: <b>2</b>"),
         "وتقول كم باع من هذه المدة تحديداً");
  assert(conf.includes("إجمالي مبيعاتك: <b>2</b>"), "وإجماليه");
  assert(!!buttons("editMessageText").find((b) => b.copy_text),
         "وزر النسخ يبقى بعد التأكيد");

  // الإلغاء يسمّي المدة كذلك
  drain();
  await update(tap(SELLER, yearBtn.callback_data));
  const c3 = last("sendMessage").payload.reply_markup.inline_keyboard.flat();
  drain();
  await update(tap(SELLER, c3.find((b) => b.text.includes("إلغاء")).callback_data));
  const canc = lastText("editMessageText");
  assert(canc.includes("سنة"), "رسالة الإلغاء تقول أي اشتراك رجع");
  assert(!canc.includes("E2E-"), "ومع ذلك تمحو الكود");

  // ========== العدّاد ==========
  drain();
  await update(message(SELLER, "/stats"));
  const mine = lastText("sendMessage");
  assert(mine.includes("عمليات ناجحة: <b>2</b>"), "/stats يعطي البائع رقمه");
  assert(mine.includes("ماذا بعت بالضبط"), "/stats يفصّل ماذا باع");
  assert(mine.includes("منتج الاختبار — سنة: <b>2</b>"),
         "والتفصيل يذكر المنتج والمدة والكمية");
  drain();
  await update(message(SELLER, "/allstats"));
  assert(lastText("sendMessage").includes("للمالك وحده"), "البائع لا يرى مبيعات غيره");
  drain();
  await update(message(OWNER, "/allstats"));
  const all = lastText("sendMessage");
  assert(all.includes("بائع الاختبار") && all.includes("🥇"), "المالك يرى ترتيب الجميع");
  assert(all.includes("منتج الاختبار — سنة: <b>2</b>"),
         "ويرى تحت كل بائع ماذا باع بالتفصيل");

  // قائمة الأدمن -> ضغطة على بائع -> تفصيله وحده
  drain();
  await update(tap(OWNER, "m:admins"));
  const admButtons = buttons("editMessageText")
    .filter((b) => (b.callback_data || "").startsWith("adm:"));
  assert(admButtons.length >= 2, "كل أدمن في القائمة زر يفتح تفصيله");
  // زرّ البائع تحديداً: أول زرّ هو المالك (بلا مبيعات) فلا يثبت شيئاً
  const sellerBtn = admButtons.find((b) => b.callback_data === `adm:${SELLER}`);
  assert(!!sellerBtn, "وزر البائع يحمل رقمه");
  drain();
  await update(tap(OWNER, sellerBtn.callback_data));
  const detail = lastText("editMessageText");
  assert(detail.includes("بائع الاختبار"), "الضغط عليه يفتح تفصيل مبيعاته باسمه");
  assert(detail.includes("منتج الاختبار — سنة: <b>2</b>"),
         "وفيه ماذا باع بالضبط وكم");

  // والبائع لا يفتح تفصيل غيره ولو خمّن الزر
  drain();
  await update(tap(SELLER, `adm:${OWNER}`));
  assert(last("answerCallbackQuery").payload.text.includes("للمالك وحده"),
         "البائع لا يفتح تفصيل غيره حتى بضغطة مباشرة");

  // ========== وثيقة الضمان (023) ==========
  // حقلان على المنتج: يوزر مطلوب وهاتف اختياري
  drain();
  await update(message(OWNER, "/addfield e2e يوزر الأنستا"));
  assert(lastText("sendMessage").includes("✅"), "المالك يضيف حقل بيانات للزبون");
  await update(message(OWNER, "/addfield e2e رقم الهاتف optional"));
  drain();
  await update(message(OWNER, "/fields"));
  const fl = lastText("sendMessage");
  assert(fl.includes("يوزر الأنستا") && fl.includes("رقم الهاتف (اختياري)"),
         "/fields يعرض الحقول ويميّز الاختياري");

  // المدة تحتاج قيمة ليُحسب الانتهاء — كما يضبطها المالك
  sql(`update bot_variants set duration_value=1, duration_unit='year'
        where code='year' and product_id=(select id from bot_products where code='e2e')`);
  sql(`select bot_add_cards(${OWNER}, (select v.id from bot_variants v
        join bot_products p on p.id=v.product_id where p.code='e2e' and v.code='year'),
        array['CERT-1'])`);

  // بيعة -> تأكيد -> البوت يسأل عن بيانات الزبون
  drain();
  await update(tap(SELLER, yearBtn.callback_data));
  const cardC = last("sendMessage");
  drain();
  await update(tap(SELLER, kb(cardC).find((b) => b.text.includes("تأكيد")).callback_data));
  // التأكيد يعرض خيارين؛ «أكتبها أنا» هو ما يفتح السؤال
  const pick = telegramCalls.filter((c) => c.method === "sendMessage")
    .find((c) => (c.payload.text || "").includes("بقيت بيانات الزبون"));
  assert(!!pick, "بعد التأكيد يعرض خياري تعبئة البيانات");
  drain();
  await update(tap(SELLER, kb(pick).find((b) =>
    (b.callback_data || "").startsWith("cf:")).callback_data));
  const askMsg = telegramCalls.filter((c) => c.method === "sendMessage")
    .find((c) => (c.payload.text || "").startsWith("🧾 بيانات الزبون"));
  assert(!!askMsg, "«أكتبها أنا» يسأل البائع عن بيانات الزبون");
  assert(askMsg.payload.reply_markup.force_reply === true, "بردّ إجباري");
  assert(askMsg.payload.text.includes("1. يوزر الأنستا"),
         "ويعرض الحقول مرقّمة بالترتيب");
  assert(askMsg.payload.text.includes("اختياري"), "ويميّز الاختياري منها");

  // ردّ ناقص: الحقل المطلوب فارغ
  drain();
  await update(message(SELLER, "-\n0550111222",
                       askMsg.payload.text.replace(/<[^>]+>/g, "")));
  assert(lastText("sendMessage").includes("ينقص حقل مطلوب: يوزر الأنستا"),
         "حقل مطلوب فارغ يوقف الإصدار ويسمّي الحقل");

  // ردّ صحيح -> الوثيقة
  drain();
  await update(message(SELLER, "@ahmed_dz\n0550111222",
                       askMsg.payload.text.replace(/<[^>]+>/g, "")));
  const certMsg = telegramCalls.filter((c) => c.method === "sendMessage")
    .find((c) => (c.payload.text || "").includes("وثيقة ضمان"));
  assert(!!certMsg, "الردّ الصحيح يُصدر الوثيقة");
  const ct = certMsg.payload.text;
  assert(ct.includes("@ahmed_dz") && ct.includes("0550111222"),
         "وفيها بيانات الزبون كما أُدخلت");
  assert(/📅 يبدأ: <b>\d{4}-\d{2}-\d{2}<\/b>/.test(ct), "وتاريخ البداية");
  assert(/📅 ينتهي: <b>\d{4}-\d{2}-\d{2}<\/b>/.test(ct), "وتاريخ النهاية");
  const certCode = (ct.match(/JNR-[A-Z0-9]+/) || [])[0];
  assert(!!certCode, "ورمز تحقّق");
  assert(!!kb(certMsg).find((b) => b.copy_text && b.copy_text.text === certCode),
         "وزر نسخ يحمل الرمز");
  assert(Number(sql(`select count(*) from bot_certificates where code='${certCode}'`)) === 1,
         "والوثيقة مخزّنة في قاعدة البيانات");

  // مراجعتها بالرمز، وبحروف صغيرة
  drain();
  await update(message(SELLER, `/cert ${certCode.toLowerCase()}`));
  assert(lastText("sendMessage").includes("@ahmed_dz"),
         "/cert يعيدها بالرمز ولو بحروف صغيرة");

  // البحث عن الزبون
  drain();
  await update(message(SELLER, "/find ahmed"));
  assert(lastText("sendMessage").includes("@ahmed_dz"), "/find يجده بيوزره");
  drain();
  await update(message(SELLER, "/find 0550111222"));
  assert(lastText("sendMessage").includes("@ahmed_dz"), "و برقم هاتفه");

  // تنتهي قريباً
  drain();
  await update(message(SELLER, "/expiring 7"));
  assert(lastText("sendMessage").includes("لا اشتراك ينتهي"),
         "اشتراك بعد سنة ليس «قريباً»");
  sql(`update bot_certificates set starts_at = now() - interval '360 days',
         ends_at = now() + interval '3 days' where code='${certCode}'`);
  drain();
  await update(message(SELLER, "/expiring 7"));
  const exp = lastText("sendMessage");
  assert(exp.includes("@ahmed_dz") && exp.includes("تنتهي خلال 7"),
         "وبعد ثلاثة أيام يظهر في القائمة");

  // ========== الزبون يعبّي بنفسه على الويب (024) ==========
  // نفس الدالة تخدم صفحات الزبون، فتُفتح هنا كما يفتحها هو
  const web = (qs, init) => fetch(`http://127.0.0.1:${BOT}/?${qs}`, init);

  await update(message(OWNER,
    "/addcontact E2E سناب | janeiro_e2e | https://snapchat.com/add/janeiro_e2e"));
  drain();
  await update(message(OWNER, "/contacts"));
  assert(lastText("sendMessage").includes("janeiro_e2e"), "المالك يضبط قنوات التواصل");

  sql(`select bot_add_cards(${OWNER}, (select v.id from bot_variants v
        join bot_products p on p.id=v.product_id where p.code='e2e' and v.code='year'),
        array['WEB-1'])`);
  drain();
  await update(tap(SELLER, yearBtn.callback_data));
  const cW = last("sendMessage");
  drain();
  await update(tap(SELLER, kb(cW).find((b) => b.text.includes("تأكيد")).callback_data));

  // بعد التأكيد: خياران، من يعبّي؟
  const choice = telegramCalls.filter((c) => c.method === "sendMessage")
    .find((c) => (c.payload.text || "").includes("بقيت بيانات الزبون"));
  assert(!!choice, "بعد التأكيد يعرض خياري التعبئة");
  const linkBtn = kb(choice).find((b) => (b.callback_data || "").startsWith("cl:"));
  assert(!!linkBtn && !!kb(choice).find((b) => (b.callback_data || "").startsWith("cf:")),
         "زر للزبون وزر للبائع");

  drain();
  await update(tap(SELLER, linkBtn.callback_data));
  const linkMsg = lastText("sendMessage");
  const token = (linkMsg.match(/\?fill=([0-9a-f]{64})/) || [])[1];
  assert(!!token, "زر «يعبّيها الزبون» ينتج رابطاً");
  assert(!!buttons("sendMessage").find((b) => b.copy_text),
         "مع زر نسخ ليُرسل في سناب أو واتساب");

  // الزبون يفتح الرابط
  const formHtml = await web(`fill=${token}`).then((r) => r.text());
  assert(formHtml.includes('dir="rtl"'), "صفحة الزبون عربية من اليمين");
  assert(formHtml.includes("يوزر الأنستا"), "وفيها الحقول المطلوبة");
  assert(!formHtml.includes("WEB-1"), "ولا تسرّب كود البطاقة أبداً");
  assert(formHtml.includes("<form method=\"POST\""), "واستمارة تُرسل");

  // ويعبّيها ويضغط إرسال
  const body = new URLSearchParams({ f0: "@self_filled" });
  const certHtml = await web(`fill=${token}`,
    { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body.toString() }).then((r) => r.text());
  assert(certHtml.includes("وثيقة ضمان"), "الإرسال يعطيه الوثيقة فوراً");
  assert(certHtml.includes("@self_filled"), "بما كتبه هو");
  assert(/يبدأ[\s\S]{0,80}\d{4}-\d{2}-\d{2}/.test(certHtml), "وتاريخ البداية");
  assert(/ينتهي[\s\S]{0,80}\d{4}-\d{2}-\d{2}/.test(certHtml), "وتاريخ النهاية");
  assert(certHtml.includes("window.print()"), "وزر حفظ أو طباعة PDF");
  assert(certHtml.includes("janeiro_e2e"), "وقنوات تواصلك أسفلها");
  assert(!certHtml.includes("WEB-1"), "ولا كود البطاقة");
  const webCode = (certHtml.match(/JNR-[A-Z0-9]+/) || [])[0];
  assert(!!webCode, "ورمز تحقّق");

  // والبائع يُبلَّغ بلا أن يسأل
  const notice = telegramCalls.filter((c) => c.method === "sendMessage")
    .find((c) => (c.payload.text || "").includes("الزبون عبّأ بياناته"));
  assert(!!notice, "والبائع يصله إشعار أن زبونه عبّأ");
  assert(notice.payload.chat_id === SELLER, "الإشعار للبائع صاحب البيعة");

  // الرابط لا يُستعمل مرتين
  const again = await web(`fill=${token}`).then((r) => r.text());
  assert(again.includes("مسبقاً"), "والرابط لا يُفتح مرة ثانية");

  // ورابط الوثيقة يبقى يعمل — الزبون يحفظه
  const revisit = await web(`cert=${webCode}`).then((r) => r.text());
  assert(revisit.includes("@self_filled") && revisit.includes("janeiro_e2e"),
         "ورابط الوثيقة نفسه يبقى مفتوحاً ليحفظه الزبون");
  const bogus = await web("cert=JNR-NOTHINGHERE00").then((r) => r.text());
  assert(bogus.includes("تعذّر"), "ورمز مخترَع لا يفتح شيئاً");

  // «من ينتهي اشتراكه اليوم؟»
  // آخر ثانية من اليوم لا ساعة ثابتة: كانت 20:00، فكان الاختبار
  // يمرّ صباحاً ويفشل مساءً — عيب في الاختبار لا في الدالة.
  sql(`update bot_certificates set starts_at = now() - interval '300 days',
        ends_at = date_trunc('day', now()) + interval '1 day' - interval '1 second'
       where code='${webCode}'`);
  drain();
  await update(tap(OWNER, "exp:0"));
  const today = lastText("editMessageText");
  assert(today.includes("تنتهي اليوم"), "زر «اليوم» يسأل عن اليوم نفسه");
  assert(today.includes("@self_filled"), "ويجد من ينتهي اشتراكه فيه");

  // ========== وثيقة التزام الخدمة (025) ==========
  // المنصة -> المدة -> الهدية -> معاينة -> تأكيد، بالأزرار كما يراها البائع
  drain();
  await update(message(SELLER, "/warranty"));
  let wz = last("sendMessage");
  assert(wz.payload.text.includes("وثيقة التزام خدمة"), "/warranty يبدأ الفلو");
  assert(wz.payload.text.includes("اختر المنصة"), "ويسأل عن المنصة أولاً");
  const platBtns = kb(wz).filter((b) => (b.callback_data || "").startsWith("wp:"));
  assert(platBtns.length === 8, "وأزرار المنصات الثمانية، وجد " + platBtns.length);
  assert(!!kb(wz).find((b) => b.text.includes("أخرى")), "وزر «أخرى» للإدخال اليدوي");
  const snap = platBtns.find((b) => b.text === "Snapchat Plus");
  assert(!!snap, "ومنها Snapchat Plus بالاسم كما هو");

  drain();
  await update(tap(SELLER, snap.callback_data));
  wz = last("editMessageText");
  assert(wz.payload.text.includes("Snapchat Plus"), "اختيار المنصة يُثبّتها في المعاينة");
  assert(wz.payload.text.includes("اختر المدة"), "ثم يسأل عن المدة");
  const mBtns = kb(wz).filter((b) => (b.callback_data || "").startsWith("wm:"));
  assert(mBtns.map((b) => b.callback_data).join(",") === "wm:1,wm:2,wm:3,wm:6,wm:12",
         "المدد 1/2/3/6/12 بهذا الترتيب");
  // ونصوصها بالعربية الصحيحة: «شهران» لا «2 شهر»
  assert(mBtns.map((b) => b.text).join(",") === "شهر,شهران,3 أشهر,6 أشهر,12 شهراً",
         "وبصيغها العربية");
  assert(kb(wz).some((b) => b.callback_data === "wz:months_manual")
      && kb(wz).some((b) => b.callback_data === "wz:days_manual"),
         "ومدّة مخصّصة: بالأشهر أو بالأيام");

  drain();
  await update(tap(SELLER, "wm:12"));
  wz = last("editMessageText");
  assert(wz.payload.text.includes("أيام هدية؟"), "ثم أيام الهدية");
  const bBtns = kb(wz).filter((b) => (b.callback_data || "").startsWith("wb:"));
  assert(bBtns.map((b) => b.text).join("|") === "لا|7|14",
         "أزرار [لا] [7] [14], وجد " + bBtns.map((b) => b.text).join("|"));
  assert(!!kb(wz).find((b) => b.callback_data === "wz:bonus_manual"),
         "وزر الإدخال اليدوي");

  // الإدخال اليدوي
  drain();
  await update(tap(SELLER, "wz:bonus_manual"));
  const bonusAsk = last("sendMessage");
  assert(bonusAsk.payload.reply_markup.force_reply === true, "اليدوي يسأل بردّ إجباري");
  drain();
  await update(message(SELLER, "150", bonusAsk.payload.text.replace(/<[^>]+>/g, "")));
  assert(lastText("sendMessage").includes("من 0 إلى 90"),
         "و150 يوماً تُرفض برسالة تقول الحدّ");
  drain();
  await update(message(SELLER, "10", bonusAsk.payload.text.replace(/<[^>]+>/g, "")));
  wz = last("sendMessage");
  assert(wz.payload.text.includes("أيام الهدية: <b>10</b>"), "و10 تُقبل");

  // المعاينة كاملة
  assert(wz.payload.text.includes("يبدأ:") && wz.payload.text.includes("ينتهي:"),
         "المعاينة تعرض التاريخين");
  // «12 شهر» كان خطأً نحوياً يقرأه الزبون في وثيقته: التمييز
  // بعد أحد عشر مفرد منصوب.
  assert(/التغطية: 12 شهراً \+ 10 أيام هدية/.test(wz.payload.text),
         "وصيغة التغطية بالعربية مع الهدية");
  // كانت تَعِد بأن البداية تُثبَّت عند تعبئة الزبون؛ صار ذلك غير
  // صحيح منذ 029 (البداية لحظة الإصدار)، فالوعد الكاذب سقط.
  assert(!wz.payload.text.includes("لحظة تعبئة الزبون"),
         "ولا تَعِد بأن البداية تُثبَّت عند التعبئة — لم تعد كذلك");
  assert(!!kb(wz).find((b) => b.callback_data === "wz:ok"), "وزر التأكيد");

  // «تعديل» يعود ويمحو
  drain();
  await update(tap(SELLER, "wz:back_months"));
  wz = last("editMessageText");
  assert(wz.payload.text.includes("اختر المدة"), "«تعديل المدة» يعود إليها");
  assert(wz.payload.text.includes("أيام الهدية: <i>—</i>"),
         "ويمحو الهدية التي بعدها، فلا تدخل المعاينة بلا أن يراها");
  assert(wz.payload.text.includes("Snapchat Plus"), "ويُبقي المنصة قبلها");

  drain();
  await update(tap(SELLER, "wm:12"));
  await update(tap(SELLER, "wb:7"));
  wz = last("editMessageText");
  assert(/التغطية: 12 شهراً \+ 7 أيام هدية/.test(wz.payload.text), "7 أيام هدية");

  // بلا هدية: لا إشارة إليها إطلاقاً
  drain();
  await update(tap(SELLER, "wz:back_bonus"));
  await update(tap(SELLER, "wb:0"));
  wz = last("editMessageText");
  assert(/التغطية: 12 شهراً</.test(wz.payload.text),
         "بلا هدية تظهر المدة وحدها");
  assert(!wz.payload.text.includes("هدية</b>") && !/\+ 0/.test(wz.payload.text),
         "ولا إشارة للهدية ولا صفر معلّق");

  // التأكيد -> الرابط
  drain();
  await update(tap(SELLER, "wb:7"));
  drain();
  await update(tap(SELLER, "wz:ok"));
  const okMsg = last("editMessageText");
  assert(okMsg.payload.text.includes("الوثيقة جاهزة"), "التأكيد يولّد الوثيقة");
  assert(/JS-[0-9A-F]{8}/.test(okMsg.payload.text), "ويعرض المرجعية JS-");
  // المسار الجميل حين يُضبط PUBLIC_SITE_URL، والمعامل حين لا يُضبط
  const claimTok = (okMsg.payload.text.match(/(?:claim\/|claim=)([0-9a-f]{64})/) || [])[1];
  assert(!!claimTok, "ورابطاً فيه رمز 64 خانة");
  assert(okMsg.payload.text.includes("72 ساعة"), "ويقول مدة صلاحيته");
  const copyLink = kb(okMsg).find((b) => b.copy_text);
  assert(!!copyLink && copyLink.copy_text.text.includes(claimTok),
         "وزر نسخ يحمل الرابط نفسه");

  // الوثيقة في القاعدة: تواريخها مثبّتة من لحظة الإصدار (029)،
  // ومعلّقة حتى يعبّئ صاحبها.
  const engCode = sql(`select code from bot_certificates
                        where platform='Snapchat Plus' and months=12 and bonus_days=7
                        order by created_at desc limit 1`);
  assert(/^JW-[0-9A-F]{10}$/.test(engCode), "والكود JW-, وجد " + engCode);
  assert(sql(`select coalesce(starts_at::text,'NULL') from bot_certificates where code='${engCode}'`)
         !== "NULL", "ولها تاريخ بداية من أول لحظة");
  assert(sql(`select bot_engagement_status(c) from bot_certificates c where c.code='${engCode}'`)
         === "pending", "وهي معلّقة حتى يعبّئ صاحبها");

  // والفلو انمحى: تأكيد ثانٍ بلا فلو
  drain();
  await update(tap(SELLER, "wz:ok"));
  assert(lastText("sendMessage").includes("/warranty"),
         "تأكيد ثانٍ بلا فلو يوجّه إلى /warranty");

  // منصة يدوية
  drain();
  await update(message(SELLER, "/warranty"));
  await update(tap(SELLER, "wz:platform_manual"));
  const pAsk = last("sendMessage");
  assert(pAsk.payload.reply_markup.force_reply === true, "«أخرى» تسأل بردّ إجباري");
  drain();
  await update(message(SELLER, "Prime Video", pAsk.payload.text.replace(/<[^>]+>/g, "")));
  assert(lastText("sendMessage").includes("Prime Video"),
         "والمنصة المكتوبة بيدٍ تُقبل بلا أن تُضاف للأزرار");
  await update(message(SELLER, "/warranty"));

  // إدارة المنصات — للمالك
  drain();
  await update(message(SELLER, "/addplatform E2E Platform"));
  assert(lastText("sendMessage").includes("للمالك وحده"), "البائع لا يضيف منصة");
  drain();
  await update(message(OWNER, "/addplatform E2E Platform"));
  assert(lastText("sendMessage").includes("✅"), "والمالك يضيف");
  drain();
  await update(message(OWNER, "/platforms"));
  assert(lastText("sendMessage").includes("E2E Platform"), "وتظهر في القائمة");

  // الإبطال وإعادة الرابط
  drain();
  await update(message(OWNER, `/relink ${engCode}`));
  const re = lastText("sendMessage");
  assert(re.includes("رابط جديد") && re.includes("أُبطل"),
         "/relink يعطي رابطاً جديداً ويقول إن القديم أُبطل");
  drain();
  await update(message(OWNER, `/revoke ${engCode}`));
  assert(lastText("sendMessage").includes("أُبطلت"), "/revoke يُبطل الوثيقة");
  assert(sql(`select revoked_at is not null from bot_certificates where code='${engCode}'`)
         === "t", "وتُسجَّل في القاعدة");
  drain();
  await update(message(OWNER, `/revoke ${engCode}`));
  assert(lastText("sendMessage").includes("ملغاة مسبقاً"), "ولا إبطال مرتين");

  // ========== صفحات وثيقة الالتزام (ج) ==========
  // نفس الدالة تخدمها؛ تُفتح هنا كما يفتحها الزبون تماماً
  const wweb = (p, init) => fetch(`http://127.0.0.1:${BOT}${p}`, init);

  /* ---------- الترويسة، لا النصّ وحده ----------
     صفحة سليمة بترويسة خاطئة تُعرض عند الزبون كوداً خاماً بأحرف
     مشوّهة بدل وثيقته. ولا يكشفه فحصُ نصٍّ: النصّ صحيح تماماً.
     وقع فعلاً على Supabase — في عين الزبون لا في اختبار. */
  for (const [p, what] of [
    ["/warranty/verify/JW-0000000000", "صفحة التحقق"],
    ["/?verify=JW-0000000000", "والشكل بالمعامل"],
  ]) {
    const head = await wweb(p);
    assert((head.headers.get("content-type") || "").replace(/\s/g, "")
           === "text/html;charset=utf-8",
           `${what} تُرسَل text/html بترميز utf-8، وجد: ` +
           head.headers.get("content-type"));
  }

  // وثيقة جديدة لأجل الصفحات
  drain();
  await update(message(SELLER, "/warranty"));
  await update(tap(SELLER, "wp:Netflix"));
  await update(tap(SELLER, "wm:6"));
  await update(tap(SELLER, "wb:14"));
  drain();
  await update(tap(SELLER, "wz:ok"));
  const wTok = (lastText("editMessageText").match(/(?:claim\/|fill=|claim=)([0-9a-f]{64})/) || [])[1];
  assert(!!wTok, "رابط تعبئة للوثيقة");

  // الاستمارة بثلاث لغات
  const formAr = await wweb(`/warranty/claim/${wTok}`).then((r) => r.text());
  assert(formAr.includes('dir="rtl"') && formAr.includes('lang="ar"'),
         "الاستمارة تفتح بالعربية من اليمين");
  assert(formAr.includes("الاسم الكامل") && formAr.includes("رقم واتساب")
         && formAr.includes("يوزر الانستغرام"), "وفيها الحقول الثلاثة");
  assert(formAr.includes("noindex"), "وممنوعة الفهرسة");
  assert(/6 أشهر \+ 14 يوماً هدية/.test(formAr), "وتقول التغطية مع الهدية");

  const formFr = await wweb(`/warranty/claim/${wTok}?lang=fr`).then((r) => r.text());
  assert(formFr.includes('lang="fr"') && formFr.includes('dir="ltr"'), "والفرنسية من اليسار");
  assert(formFr.includes("Nom complet") && formFr.includes("6 mois + 14 jours offerts"),
         "وبنصوصها الفرنسية");
  const formEn = await wweb(`/warranty/claim/${wTok}?lang=en`).then((r) => r.text());
  assert(formEn.includes("Full name") && formEn.includes("6 months + 14 days free"),
         "والإنجليزية كذلك");

  // 033: لا قوس «(اختياري)» ولا «(إجباري)» بجنب أيّ عنوان.
  // المتصفّح يقول ما ينقص، والقوس ضجيج يقرؤه الزبون ولا يفيده.
  assert(!/\(\s*اختياري\s*\)/.test(formAr) && !/\(\s*إجباري\s*\)/.test(formAr)
         && !/\(\s*مطلوب\s*\)/.test(formAr),
         "ولا قوس «اختياري» أو «إجباري» بجنب أيّ عنوان");
  assert(!/\(\s*facultatif\s*\)/i.test(formFr) && !/\(\s*optional\s*\)/i.test(formEn),
         "ولا في الفرنسية والإنجليزية");
  // والإجبار في المتصفّح يطابق الإجبار في القاعدة: حقلان لا ثلاثة
  const reqAttrs = (formAr.match(/<input[^>]*\brequired\b[^>]*>/g) || [])
    .map((t) => (t.match(/name="([a-z_]+)"/) || [])[1]).sort();
  assert(JSON.stringify(reqAttrs) === JSON.stringify(["full_name", "instagram"]),
         "الاسم واليوزر مطلوبان في المتصفّح، والرقم لا: " + JSON.stringify(reqAttrs));

  // رقم غير جزائري يُرفض داخل الاستمارة لا في صفحة ميتة.
  // ويُبعث معه يوزر صحيح، وإلا ردّت القاعدة على اليوزر ومرّ
  // الاختبار على رسالة أخرى تشبهها.
  const badPhone = await wweb(`/warranty/claim/${wTok}?lang=ar`, {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      full_name: "أحمد بن يوسف", whatsapp: "0451234567", instagram: "ahmed.dz01",
    }).toString(),
  }).then((r) => r.text());
  assert(badPhone.includes("رقم واتساب جزائري غير صحيح") && badPhone.includes("<form"),
         "رقم ثابت يُرفض برسالته هو، والاستمارة تبقى معروضة");

  // واليوزر مطلوب ولو صحّ الرقم
  const noInsta = await wweb(`/warranty/claim/${wTok}?lang=ar`, {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      full_name: "أحمد بن يوسف", whatsapp: "0550998877", instagram: "",
    }).toString(),
  }).then((r) => r.text());
  assert(noInsta.includes("يوزر انستغرام غير صحيح"), "ويوزر فارغ يُرفض برسالته هو");

  // التعبئة الصحيحة -> تحويل إلى الوثيقة
  const wDone = await wweb(`/warranty/claim/${wTok}?lang=fr`, {
    method: "POST", redirect: "manual",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      full_name: "Ahmed Benyoucef", whatsapp: "0550 99 88 77", instagram: "@ahmed.dz01",
    }).toString(),
  });
  assert(wDone.status === 303, "الإرسال يحوّل (303) فلا يعيد التحديث الإرسال");
  const wLoc = wDone.headers.get("location") || "";
  assert(!/\?[^?]*\?/.test(wLoc), "ورابط التحويل سليم بعلامة استفهام واحدة: " + wLoc);
  const wCode = (wLoc.match(/JW-[A-Z0-9]+/) || [])[0];
  assert(!!wCode, "والتحويل إلى وثيقتها: " + wLoc);

  // الوثيقة بثلاث لغات
  const docFr = await wweb(`/warranty/${wCode}?lang=fr`).then((r) => r.text());
  assert(docFr.includes("ENGAGEMENT DE SERVICE"), "العنوان الفرنسي");
  assert(docFr.includes("Plus de services. Plus de possibilités."), "والـtagline");
  assert(docFr.includes("Janeiro Store — abonnement Netflix"), "والسطر الفرعي");
  assert(docFr.includes("NOTRE ENGAGEMENT"), "وعنوان الالتزام");
  // الترقيم عنصر مستقل عن النصّ: يُلوَّن ويُحاذى في التصميم
  assert(/class="n">01</.test(docFr) && /class="n">05</.test(docFr),
         "والنقاط مرقّمة 01…05 لا bullets");
  assert(docFr.includes("Réf. Janeiro") && docFr.includes("Titulaire")
         && docFr.includes("Clé de vérification"), "والتسميات الفرنسية");
  assert(/Couvert jusqu'au[\s\S]{0,90}\d{1,2} \w+ 20\d\d/.test(docFr),
         "وتاريخ فرنسي بصيغته");
  assert(docFr.includes("Ahmed Benyoucef") && docFr.includes("@ahmed.dz01"),
         "وبيانات الزبون");
  assert(!docFr.includes("213550998877") && !docFr.includes("0550 99 88 77"),
         "ولا رقم الواتساب أبداً");
  assert(docFr.includes("<svg") && /warranty\/verify\/|[?&]verify=/.test(docFr),
         "وQR يوجّه لصفحة التحقق");
  assert(docFr.includes("window.print()"), "وزر الطباعة");

  const docAr = await wweb(`/warranty/${wCode}`).then((r) => r.text());
  assert(docAr.includes("وثيقة التزام الخدمة") && docAr.includes("التزامنا"),
         "والعربية بعنوانها");
  assert(docAr.includes("مرجع Janeiro") && docAr.includes("كلمة التحقق"),
         "وتسمياتها");
  const docEn = await wweb(`/warranty/${wCode}?lang=en`).then((r) => r.text());

  /* نسخة على القرص للمعاينة بالعين: DUMP_DIR=… node …
     الوثيقة تُطبع وتُرسل صورةً، وما يُقرأ منها لا يثبته assert. */
  if (process.env.DUMP_DIR) {
    const fs = require("fs");
    fs.mkdirSync(process.env.DUMP_DIR, { recursive: true });
    for (const [l, html] of [["ar", docAr], ["fr", docFr], ["en", docEn]]) {
      fs.writeFileSync(path.join(process.env.DUMP_DIR, `doc-${l}.html`), html);
    }
  }
  assert(docEn.includes("SERVICE COMMITMENT") && docEn.includes("OUR COMMITMENT"),
         "والإنجليزية");
  assert(/Covered until[\s\S]{0,90}\w+ \d{1,2}, 20\d\d/.test(docEn),
         "وتاريخ إنجليزي بصيغته");

  // ولا عنوان من نماذج السوق في أي لغة
  for (const [html, name] of [[docAr,"ar"],[docFr,"fr"],[docEn,"en"]]) {
    for (const banned of ["CERTIFICAT DE GARANTIE","Conditions de garantie",
                          "Numéro de commande","Nom d'utilisateur",
                          "Plateforme d'activation","Code de garantie"]) {
      assert(!html.includes(banned), `لا «${banned}» في وثيقة ${name}`);
    }
  }

  /* ---------- شروط التغطية على الوثيقة ----------
     اللقطة على الوثيقة هي ما يُعرض، لا الحيّ: زبون التُزم له
     بشروط يجدها كما هي مهما بدّل المالك بعدها. */
  sql(`update bot_certificates set terms = '{"fr":["Clause A du test","Clause B du test"]}'
        where code = '${wCode}'`);
  const docTerms = await wweb(`/warranty/${wCode}?lang=fr`).then((r) => r.text());
  assert(docTerms.includes("Clause A du test") && docTerms.includes("Clause B du test"),
         "الوثيقة تعرض لقطة شروطها");
  assert(!docTerms.includes("Pendant toute la durée indiquée"),
         "ولا تعرض المدمجة في الكود حين تكون لها لقطة");
  assert(/class="n">02</.test(docTerms) && !/class="n">03</.test(docTerms),
         "والترقيم يتبع عددها لا خمسةً دائماً");
  // ولغة بلا لقطة تسقط إلى المدمج، فلا تخرج الوثيقة بلا شروط
  const docTermsAr = await wweb(`/warranty/${wCode}`).then((r) => r.text());
  assert(docTermsAr.includes("تحت مسؤوليتنا"),
         "ولغة بلا لقطة تسقط إلى المدمج");
  sql(`update bot_certificates set terms = null where code = '${wCode}'`);

  // صفحة التحقق: تثبت بلا كشف
  const wVer = await wweb(`/warranty/verify/${wCode}?lang=fr`).then((r) => r.text());
  assert(wVer.includes("Netflix"), "التحقق يقول الخدمة");
  assert(!wVer.includes("Ahmed Benyoucef"), "ولا يكشف الاسم كاملاً");
  assert(wVer.includes("A***") || wVer.includes("***"), "بل تلميحاً");
  const wVerBad = await wweb(`/warranty/verify/JW-0000000000`).then((r) => r.text());
  assert(wVerBad.includes("لا توجد وثيقة"), "ورمز مخترَع لا يُثبت شيئاً");

  // الرابط لا يُعمَّر مرتين
  const wAgain = await wweb(`/warranty/claim/${wTok}`).then((r) => r.text());
  assert(wAgain.includes("مسبقاً"), "ورابط التعبئة لا يُفتح بعد استعماله");

  /* ==========================================================
     033: زبون بلا واتساب يأخذ وثيقته كاملة
     ==========================================================
     الرقم وسيلة تواصل لا هويّة. زبونٌ يتعامل على الانستغرام
     وحده كان يصطدم بحقل لا يستطيع تعبئته، فتبقى بيعته بلا
     وثيقة — وهي مصدَّرة ومدفوعة. اليوزر يكفي لتعريف الحساب.
     ========================================================== */
  drain();
  await update(message(SELLER, "/warranty"));
  await update(tap(SELLER, "wp:Netflix"));
  await update(tap(SELLER, "wm:3"));
  await update(tap(SELLER, "wb:0"));
  drain();
  await update(tap(SELLER, "wz:ok"));
  const nTok = (lastText("editMessageText").match(/(?:claim\/|fill=|claim=)([0-9a-f]{64})/) || [])[1];
  assert(!!nTok, "رابط تعبئة ثانٍ");

  const nDone = await wweb(`/warranty/claim/${nTok}?lang=ar`, {
    method: "POST", redirect: "manual",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      full_name: "سعاد بلحاج", whatsapp: "", instagram: "souad.b",
    }).toString(),
  });
  assert(nDone.status === 303, "إرسال بلا رقم يمرّ ويحوّل: " + nDone.status);
  const nCode = ((nDone.headers.get("location") || "").match(/JW-[A-Z0-9]+/) || [])[0];
  assert(!!nCode, "وله وثيقته");
  assert(sql(`select whatsapp is null from bot_certificates where code='${nCode}'`) === "t",
         "والرقم الفارغ يُخزَّن NULL لا نصاً فارغاً");

  const nDoc = await wweb(`/warranty/${nCode}`).then((r) => r.text());
  assert(nDoc.includes("سعاد بلحاج") && nDoc.includes("@souad.b"),
         "والوثيقة تُصدر باسمها ويوزرها");
  assert(nDoc.includes("وثيقة التزام الخدمة"), "وثيقة كاملة لا صفحة ناقصة");

  /* ==========================================================
     الوثيقة من البيعة — المسار الافتراضي
     ==========================================================
     البائع يبيع، يضغط تأكيد، ولا يُسأل إلا عن الهدية. المنصة
     والمدة والتاريخ تُقرأ من البيعة نفسها.
     ========================================================== */
  // حقول 023 كانت قد عُرّفت للمنتج في القسم السابق؛ تُزال ليعود
  // المنتج إلى المسار الافتراضي.
  sql(`delete from bot_fields where product_id in (select id from bot_products where code='e2e')`);
  sql(`insert into bot_cards (variant_id, code, added_by)
       select v.id, 'E2E-ENG-'||g, (select id from bot_admins where telegram_id=${OWNER})
         from bot_variants v join bot_products p on p.id=v.product_id,
              generate_series(1,6) g
        where p.code='e2e' and v.code='year'`);
  // نقطة بداية معلومة: بلا مدّة وبلا منصّة، مهما تركت الأقسام
  // السابقة على هذا المنتج.
  sql(`update bot_variants set duration_value=null, duration_unit=null
        where id in (select v.id from bot_variants v join bot_products p on p.id=v.product_id
                      where p.code='e2e')`);
  sql(`delete from bot_product_platforms
        where product_id in (select id from bot_products where code='e2e')`);

  const engSell = async () => {
    drain();
    await update(tap(SELLER, yearBtn.callback_data));
    const b = last("sendMessage").payload.reply_markup.inline_keyboard.flat();
    drain();
    await update(tap(SELLER, b.find((x) => x.text.includes("تأكيد")).callback_data));
  };

  // ---- ما ينقص يُقال، ولا تُخترع وثيقة ----
  await engSell();
  assert(lastText("sendMessage").includes("تحتاج مدّة"),
         "بلا مدّة للصنف: يُقال ذلك ولا تُخترع نهاية");
  assert(lastText("sendMessage").includes("البيعة مسجَّلة"),
         "ويُطمأن البائع أن بيعته لم تضع");

  sql(`select bot_set_variant_duration(${OWNER},
         (select v.id from bot_variants v join bot_products p on p.id=v.product_id
           where p.code='e2e' and v.code='year'), 1, 'year')`);
  await engSell();
  assert(lastText("sendMessage").includes("تحتاج منصّة"),
         "وبلا منصّة للمنتج: يُقال ذلك كذلك");

  // ---- منصّة واحدة: لا سؤال عنها ----
  sql(`select bot_set_product_platform(${OWNER},
         (select id from bot_products where code='e2e'), 'Spotify')`);
  await engSell();
  let eng = last("sendMessage");
  assert(eng.payload.text.includes("Spotify"), "منصّة واحدة تُختار بلا سؤال");
  assert(eng.payload.text.includes("أيام هدية"), "ويُسأل عن الهدية وحدها");
  assert(eng.payload.text.includes("شهر") && !eng.payload.text.includes("12 شهر<"),
         "والمدة معروضة بصيغتها");
  let bonusKb = eng.payload.reply_markup.inline_keyboard.flat();
  assert(["لا","7","14"].every((t) => bonusKb.some((b) => b.text === t)),
         "وأزرار الهدية: لا / 7 / 14");
  assert(bonusKb.some((b) => b.text.includes("يدوي")), "وإدخال يدوي");

  // ---- الهدية ثم الرابط والمعاينة ----
  drain();
  await update(tap(SELLER, bonusKb.find((b) => b.text === "7").callback_data));
  const engDone = last("editMessageText") ?? last("sendMessage");
  assert(engDone.payload.text.includes("الوثيقة جاهزة"), "الضغطة الواحدة تُصدر الوثيقة");
  assert(/12 شهراً \+ 7 أيام هدية/.test(engDone.payload.text), "والمعاينة تقول المدة والهدية");
  assert(engDone.payload.text.includes("يبدأ:") && engDone.payload.text.includes("ينتهي:"),
         "والتاريخين");
  assert(/JS-[0-9A-F]{8}/.test(engDone.payload.text), "ورمزها المرجعي");
  // المسار الجميل حين يُضبط PUBLIC_SITE_URL، والمعامل حين لا يُضبط
  const engTok = (engDone.payload.text.match(/(?:claim\/|claim=)([0-9a-f]{64})/) || [])[1];
  assert(!!engTok, "ورابطاً فيه رمز 64 خانة");
  const engCopy = engDone.payload.reply_markup.inline_keyboard.flat()
    .find((b) => b.copy_text);
  assert(!!engCopy && engCopy.copy_text.text.includes(engTok),
         "وزر نسخ يحمل الرابط نفسه");

  // البداية = لحظة إتمام البيعة، لا لحظة إصدار الوثيقة
  const engRow = sql(`select (c.starts_at = i.settled_at)::text
                        from bot_certificates c join bot_issues i on i.id = c.issue_id
                       where c.bonus_days = 7 and i.platform = 'Spotify'
                       order by c.created_at desc limit 1`);
  assert(engRow === "true", "وبدايتها لحظة إتمام البيعة لا لحظة إصدارها");

  // ---- منصّتان: يُسأل أيّهما ----
  sql(`select bot_add_product_platform(${OWNER},
         (select id from bot_products where code='e2e'), 'Netflix')`);
  await engSell();
  const pick2 = last("sendMessage");
  assert(pick2.payload.text.includes("على أي منصّة"), "منصّتان: يُسأل أيّهما");
  const pKb = pick2.payload.reply_markup.inline_keyboard.flat();
  const nfBtn = pKb.find((b) => b.text === "Netflix");
  assert(!!nfBtn && !!pKb.find((b) => b.text === "Spotify"), "والاثنتان معروضتان");
  drain();
  await update(tap(SELLER, nfBtn.callback_data));
  const afterPick = last("editMessageText") ?? last("sendMessage");
  assert(afterPick.payload.text.includes("Netflix"), "والمختارة تُثبَّت");
  assert(afterPick.payload.text.includes("أيام هدية"), "ثم يُسأل عن الهدية");

  // ---- «لا» هي الافتراضي الأغلب ----
  drain();
  const noBonus = afterPick.payload.reply_markup.inline_keyboard.flat()
    .find((b) => b.text === "لا");
  await update(tap(SELLER, noBonus.callback_data));
  const noneDone = last("editMessageText") ?? last("sendMessage");
  assert(noneDone.payload.text.includes("الوثيقة جاهزة"), "«لا» تُصدر كذلك");
  assert(!noneDone.payload.text.includes("هدية"), "وبلا ذكر للهدية");
  assert(sql(`select bonus_days::text from bot_certificates
               where platform='Netflix' order by created_at desc limit 1`) === "0",
         "وصفر في القاعدة");

  // ---- الإدخال اليدوي ----
  await engSell();
  const mPick = last("sendMessage").payload.reply_markup.inline_keyboard.flat();
  drain();
  await update(tap(SELLER, mPick.find((b) => b.text === "Netflix").callback_data));
  const mAsk = (last("editMessageText") ?? last("sendMessage")).payload
    .reply_markup.inline_keyboard.flat();
  drain();
  await update(tap(SELLER, mAsk.find((b) => b.text.includes("يدوي")).callback_data));
  const manualAsk = last("sendMessage");
  assert(manualAsk.payload.reply_markup.force_reply === true,
         "«يدوي» يسأل بردّ إجباري");
  drain();
  await update(message(SELLER, "200", manualAsk.payload.text.replace(/<[^>]+>/g, "")));
  assert(lastText("sendMessage").includes("0 إلى 90"), "و200 تُرفض بحدّها");
  drain();
  await update(message(SELLER, "21", manualAsk.payload.text.replace(/<[^>]+>/g, "")));
  assert(lastText("sendMessage").includes("الوثيقة جاهزة"), "و21 تُقبل");
  assert(/21 يوماً هدية/.test(lastText("sendMessage")),
         "وبصيغتها العربية الصحيحة: «21 يوماً» لا «21 أيام»");

  // ---- وثيقة واحدة لكل بيعة ----
  const dupIssue = sql(`select i.id from bot_issues i join bot_certificates c on c.issue_id=i.id
                         order by c.created_at desc limit 1`);
  drain();
  await update(tap(SELLER, `eng:${dupIssue}`));
  assert(!last("sendMessage") ||
         !lastText("sendMessage").includes("أيام هدية"),
         "وبيعة لها وثيقة لا تُسأل من جديد");

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
