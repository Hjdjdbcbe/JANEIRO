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
  sql(`update bot_certificates set starts_at = now() - interval '300 days',
        ends_at = date_trunc('day', now()) + interval '20 hours' where code='${webCode}'`);
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
  assert(mBtns.map((b) => b.callback_data).join(",") === "wm:1,wm:3,wm:6,wm:12",
         "المدد 1/3/6/12 بهذا الترتيب");

  drain();
  await update(tap(SELLER, "wm:12"));
  wz = last("editMessageText");
  assert(wz.payload.text.includes("أيام هدية؟"), "ثم أيام الهدية");
  const bBtns = kb(wz).filter((b) => (b.callback_data || "").startsWith("wb:"));
  assert(bBtns.map((b) => b.text).join("|") === "لا|7 أيام|14 أيام",
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
  assert(/التغطية: 12 شهر \+ 10 أيام هدية/.test(wz.payload.text),
         "وصيغة التغطية بالعربية مع الهدية");
  assert(wz.payload.text.includes("لحظة تعبئة الزبون"),
         "وتقول صراحةً أن البداية تُثبَّت عند التعبئة لا الآن");
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
  assert(/التغطية: 12 شهر \+ 7 أيام هدية/.test(wz.payload.text), "7 أيام هدية");

  // بلا هدية: لا إشارة إليها إطلاقاً
  drain();
  await update(tap(SELLER, "wz:back_bonus"));
  await update(tap(SELLER, "wb:0"));
  wz = last("editMessageText");
  assert(/التغطية: 12 شهر</.test(wz.payload.text),
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
  const claimTok = (okMsg.payload.text.match(/claim\/([0-9a-f]{64})|fill=([0-9a-f]{64})/) || [])
                     .slice(1).find(Boolean);
  assert(!!claimTok, "ورابطاً فيه رمز 64 خانة");
  assert(okMsg.payload.text.includes("72 ساعة"), "ويقول مدة صلاحيته");
  const copyLink = kb(okMsg).find((b) => b.copy_text);
  assert(!!copyLink && copyLink.copy_text.text.includes(claimTok),
         "وزر نسخ يحمل الرابط نفسه");

  // الوثيقة في القاعدة: معلّقة بلا تواريخ
  const engCode = sql(`select code from bot_certificates
                        where platform='Snapchat Plus' and months=12 and bonus_days=7
                        order by created_at desc limit 1`);
  assert(/^JW-[0-9A-F]{10}$/.test(engCode), "والكود JW-, وجد " + engCode);
  assert(sql(`select coalesce(starts_at::text,'NULL') from bot_certificates where code='${engCode}'`)
         === "NULL", "وهي معلّقة بلا تاريخ بداية");

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
