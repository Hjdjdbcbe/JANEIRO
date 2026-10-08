/* ============================================================
   بوت تفعيل Snapchat+ — اختبار من الأول للآخر (القسم 14).

     node tests/local/activation-bot.test.js [dbname]

   يشغّل المنطق الحقيقي (handler.js) وطبقة تيليغرام الحقيقية
   (adapters/telegram.js) ودوال القاعدة الحقيقية (migration 042):
     - تيليغرام: fetch وهمي يسجل كل ميساج تبعث ويرجع message_id
     - Supabase: fetch وهمي يحوّل كل /rest/v1/rpc/* لـ SQL على psql
     - الـAI: نتائج مكتوبة مسبقاً (الصورة، النية، الفوكال)
   ============================================================ */
const { execFileSync } = require("child_process");
const { createTelegramAdapter } = require("../../lib/activation-bot/adapters/telegram");
const { createDb } = require("../../lib/activation-bot/db");
const { createHandler } = require("../../lib/activation-bot/handler");
const F = require("../../lib/activation-bot/flow");
const { T } = require("../../lib/activation-bot/texts");

const DB = process.argv[2] || process.env.JANEIRO_TEST_DB || "janeiro_test";
const ADMIN = "9001";

let passed = 0;
const green = (s) => `\x1b[32m${s}\x1b[0m`;
const red = (s) => `\x1b[31m${s}\x1b[0m`;
function assert(cond, msg) {
  if (cond) { passed++; console.log(green(`PASS  ${msg}`)); }
  else { console.log(red(`FAIL: ${msg}`)); process.exitCode = 1; throw new Error(msg); }
}

const sql = (t) => execFileSync("psql", ["-d", DB, "-X", "-A", "-t", "-q", "-v", "ON_ERROR_STOP=1", "-c", t],
  { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();

function lit(v) {
  if (v === null || v === undefined) return "null";
  if (typeof v === "number") return String(v);
  if (typeof v === "boolean") return v ? "true" : "false";
  if (Array.isArray(v)) return `array[${v.map(lit).join(",")}]::text[]`;
  if (typeof v === "object") return `$j$${JSON.stringify(v)}$j$::jsonb`;
  return `$q$${String(v)}$q$`;
}

/* ---------- Supabase وهمي: PostgREST -> psql ---------- */
async function dbFetch(url, init) {
  const fn = new URL(url).pathname.replace("/rest/v1/rpc/", "");
  const args = JSON.parse(init.body || "{}");
  const named = Object.entries(args).map(([k, v]) => `${k} => ${lit(v)}`).join(", ");
  try {
    const out = sql(`select to_json(${fn}(${named}))`);
    return new Response(out === "" ? "null" : out, { status: 200 });
  } catch (e) {
    const m = String(e.stderr || e.message).match(/ERROR:\s+(.*)/);
    return new Response(JSON.stringify({ message: m ? m[1] : "err" }), { status: 400 });
  }
}

/* ---------- تيليغرام وهمي ---------- */
let sent = [];
let nextId = 1000;
const deleted = [];
async function tgFetch(url, init) {
  if (url.includes("/file/bot")) return new Response(Buffer.from("fake-image"), { status: 200 });
  const method = url.split("/").pop();
  const body = init && init.body ? JSON.parse(init.body) : {};
  if (method === "getFile") return Response.json({ ok: true, result: { file_path: `photos/${body.file_id}.jpg` } });
  if (method === "deleteMessage") { deleted.push(body); return Response.json({ ok: true, result: true }); }
  const id = nextId++;
  sent.push({ method, ...body, message_id: id });
  return Response.json({ ok: true, result: { message_id: id } });
}

/* ---------- AI وهمي ---------- */
const shots = [];
const voices = [];
const ai = {
  async analyzeScreenshot() {
    if (!shots.length) throw new Error("no scripted analysis");
    return shots.shift();
  },
  async interpretText({ text }) {
    const t = text.toLowerCase();
    if (/rasid|رصيد|paiement/.test(t)) return { intent: "no_balance", reply: "" };
    if (/algérie|الجزائري|dz/.test(t)) return { intent: "wrong_store", reply: "" };
    if (/insan|إنسان|مالك/.test(t)) return { intent: "wants_human", reply: "" };
    if (/prix|سومة|شحال/.test(t)) return { intent: "money", reply: "" };
    if (/subscriptions/.test(t)) return { intent: "no_subscriptions", reply: "" };
    if (/kifach|كيفاش/.test(t)) return { intent: "question", reply: "جواب حر" };
    return { intent: "unclear", reply: "" };
  },
  async transcribe() { return voices.shift() || ""; },
};

const msg = createTelegramAdapter({ token: "TEST", fetchImpl: tgFetch });
const db = createDb({ url: "http://db.local", serviceKey: "svc", fetchImpl: dbFetch });
const errors = [];
const bot = createHandler({ msg, db, ai, adminIds: [ADMIN], botUsername: "janeiro_act_bot", log: (e) => errors.push(e) });

/* ---------- مساعدين ---------- */
let upd = 1;
let mid = 1;
const base = (chat) => ({ message_id: mid++, chat: { id: Number(chat), type: "private" }, from: { id: Number(chat) } });
async function text(chat, t, extra = {}) {
  sent = [];
  await bot.handleUpdate({ update_id: upd++, message: { ...base(chat), text: t, ...extra } });
  return sent;
}
async function photo(chat, analysis, caption) {
  sent = [];
  shots.length = 0;
  if (analysis) shots.push(analysis);
  await bot.handleUpdate({ update_id: upd++, message: { ...base(chat), caption, photo: [{ file_id: "s" }, { file_id: `ph${upd}` }] } });
  return sent;
}
async function voice(chat, transcript, duration = 5, extra = {}) {
  sent = [];
  if (transcript !== null) voices.push(transcript);
  await bot.handleUpdate({ update_id: upd++, message: { ...base(chat), voice: { file_id: `v${upd}`, duration, mime_type: "audio/ogg" }, ...extra } });
  return sent;
}
async function press(chat, data, messageId = 1) {
  sent = [];
  await bot.handleUpdate({ update_id: upd++, callback_query: { id: `cb${upd}`, from: { id: Number(chat) }, data,
    message: { message_id: messageId, chat: { id: Number(chat), type: "private" } } } });
  return sent;
}
const texts = (out, chat) => out.filter((m) => m.method === "sendMessage" && (!chat || String(m.chat_id) === String(chat))).map((m) => m.text);
const has = (out, chat, needle) => texts(out, chat).some((t) => t.includes(needle));
const order = (code) => JSON.parse(sql(`select to_json(o) from activation_orders o where code = '${code}'`));
async function newOrder(type) {
  const out = await text(ADMIN, `/new ${type}`);
  const m = /JN-\d+/.exec(texts(out, ADMIN)[0] || "");
  assert(m, `/new ${type} returns a code`);
  return m[0];
}

const snapPage = (o = {}) => ({
  page_type: "snap_plus_offer", currency: "INR", has_free_trial: true, already_subscribed: false,
  upcoming_plan_change: false, plan_price_inr: null, balance_inr: null, country_shown: null,
  has_continue_button: false, ui_language: "fr", confidence: 0.95, ...o,
});
const subsPage = (o = {}) => snapPage({ page_type: "appstore_subscriptions", has_free_trial: false, ...o });

/* ============================================================ */
async function main() {
  // نظافة + ستوك: مدّتين بالروبية (₹100 و ₹250) من بوت المخزون
  sql(`delete from activation_admin_msgs; delete from bot_events; delete from activation_chats;
       update bot_cards set status = 'disabled' where status = 'available';
       delete from activation_orders; delete from activation_updates; delete from bot_media;
       select act_set_review(false);`);
  sql(`insert into bot_products(code, name) values ('appleinr', 'Apple INR') on conflict (code) do nothing;
       insert into bot_variants(product_id, code, name) select id, 'r100', '₹100' from bot_products where code='appleinr' on conflict do nothing;
       insert into bot_variants(product_id, code, name) select id, 'r250', '₹250' from bot_products where code='appleinr' on conflict do nothing;
       delete from bot_cards where code like 'TEST-GIFT-%';`);

  // ---------- /giftamount ----------
  let out = await text(ADMIN, "/giftamount appleinr r100 100");
  assert(has(out, ADMIN, "₹100"), "/giftamount marks a stock variant as ₹100 credit");
  await text(ADMIN, "/giftamount appleinr r250 250");
  sql(`insert into bot_cards(variant_id, code) select v.id, 'TEST-GIFT-100-' || g from bot_variants v
         join bot_products p on p.id = v.product_id, generate_series(1,3) g where p.code='appleinr' and v.code='r100';
       insert into bot_cards(variant_id, code) select v.id, 'TEST-GIFT-250-' || g from bot_variants v
         join bot_products p on p.id = v.product_id, generate_series(1,3) g where p.code='appleinr' and v.code='r250';`);
  out = await text(ADMIN, "/stock");
  assert(has(out, ADMIN, "₹100: 3") && has(out, ADMIN, "₹250: 3"), "/stock shows credit codes by amount");

  // ---------- /media و /voice ----------
  sent = [];
  await bot.handleUpdate({ update_id: upd++, message: { ...base(ADMIN), caption: "/media video_country", video: { file_id: "VID_COUNTRY", duration: 30 } } });
  assert(texts(sent, ADMIN).some((t) => t.includes("video_country")), "/media saves a video into its slot");
  await bot.handleUpdate({ update_id: upd++, message: { ...base(ADMIN), caption: "/media photo_snap_card", photo: [{ file_id: "PH_CARD" }] } });
  const voiceMsgId = mid;
  await bot.handleUpdate({ update_id: upd++, message: { ...base(ADMIN), voice: { file_id: "VOICE_WELCOME", duration: 9 } } });
  out = await text(ADMIN, "/voice voice_welcome", { reply_to_message: { message_id: voiceMsgId, voice: { file_id: "VOICE_WELCOME" } } });
  assert(has(out, ADMIN, "voice_welcome"), "/voice (as a reply to a voice note) saves it into its slot");

  // ---------- مسار شهر كامل ----------
  const C1 = "111";
  const m1 = await newOrder("month");
  out = await text(C1, "salam");
  assert(has(out, C1, "كود الطلب"), "no order yet: the bot asks for the order code");
  out = await text(C1, `/start ${m1}`);
  assert(has(out, C1, "طلبك: سناب بلس شهر"), "a valid code starts the flow with the welcome message");
  assert(out.some((m) => m.method === "sendVideo" && m.video === "VID_COUNTRY"), "welcome carries the country video");
  assert(out.some((m) => m.method === "sendPhoto" && m.photo === "PH_CARD"), "welcome carries the snap card photo");
  assert(out.some((m) => m.method === "sendVoice" && m.voice === "VOICE_WELCOME"), "owner's saved voice is sent at its step");
  assert(order(m1).status === "WAIT_SNAP_SCREENSHOT", "order moves to WAIT_SNAP_SCREENSHOT");

  out = await photo(C1, snapPage({ currency: "DZD" }));
  assert(has(out, C1, "البلاد ما تبدلتش") && out.some((m) => m.method === "sendVideo"), "price in dinars: country video is sent again");
  assert(!has(out, C1, "apps.apple.com"), "…and no credit link");

  out = await photo(C1, snapPage({ has_free_trial: false, ui_language: "en" }));
  const link1 = texts(out, C1).find((t) => t.includes("apps.apple.com/redeem"));
  assert(link1 && link1.includes("TEST-GIFT-100-"), "month accepted without a trial: smallest covering code (₹100) is linked");
  const act1 = texts(out, C1).find((t) => t.includes("بعدها روحي سناب"));
  assert(act1 && act1.includes("Monthly") && act1.includes("الزر الأصفر لتحت"), "activation text follows the phone language, and no-trial wording");
  assert(order(m1).status === "WAIT_ACTIVATION_DONE", "order waits for activation");

  out = await press(C1, "c:activated");
  assert(has(out, C1, "كيفاش يمشي اشتراك سناب بلس (شهر)"), "[تفعّل ✅] on a month order sends the final month message");
  assert(order(m1).status === "DONE", "month order is DONE");

  // ---------- كود مستعمل من حساب آخر، وكود غالط ----------
  out = await text("222", m1);
  assert(has(out, "222", T.badCode), "a code bound to another account is refused");
  out = await text(C1, m1);
  assert(!has(out, C1, T.badCode), "the same customer re-sending their code is not refused");
  for (let i = 0; i < 3; i++) await text("222", "JN-0000"); // + the bound code above = 4
  out = await text("222", "JN-0001");
  assert(has(out, "222", T.badCode), "5th wrong code still answered");
  out = await text("222", "JN-0002");
  assert(out.length === 0, "after 5 wrong codes the bot stays silent for an hour");

  // ---------- شهرين بلا تجربة مجانية ----------
  const C2 = "333";
  const m2 = await newOrder("2months");
  await text(C2, m2);
  out = await photo(C2, snapPage({ has_free_trial: false }));
  assert(has(out, C2, T.holdOn) && !has(out, C2, "apps.apple.com"), "two months without a free trial: no link, customer told to wait");
  assert(has(out, ADMIN, "ما كاينش تجربة مجانية") && out.some((m) => m.method === "copyMessage" && String(m.chat_id) === ADMIN),
    "owner gets the alert with the screenshot");
  assert(order(m2).status === "HUMAN" && order(m2).resume_status === "WAIT_SNAP_SCREENSHOT", "order is HUMAN and remembers its step");

  // /take + رد مالك + /release
  out = await text(C2, "wach rak");
  assert(out.every((m) => String(m.chat_id) === ADMIN), "in HUMAN the bot is silent; customer messages go to the owner");
  out = await text(ADMIN, `/take ${m2}`);
  const takeMsg = out.find((m) => String(m.chat_id) === ADMIN).message_id;
  out = await text(ADMIN, "راني معاك", { reply_to_message: { message_id: takeMsg } });
  assert(out.some((m) => m.method === "copyMessage" && String(m.chat_id) === C2), "owner's reply is relayed to the customer");
  out = await text(ADMIN, `/release ${m2}`);
  assert(order(m2).status === "WAIT_SNAP_SCREENSHOT" && has(out, C2, T.resume), "/release returns the order to the same step");

  // ---------- سنة: 12-Month بالغلط ثم Annual ----------
  const C3 = "444";
  const y = await newOrder("year");
  await text(C3, y);
  out = await photo(C3, snapPage());
  assert(texts(out, C3).some((t) => t.includes("TEST-GIFT-250-")), "year needs ₹199: the ₹250 code is chosen, not ₹100");
  assert(has(out, C3, "اشتراك عام") && has(out, C3, "Démarrer l'essai gratuit"), "year activation text has the year tail and French buttons");
  out = await press(C3, "c:activated");
  assert(has(out, C3, "Annual Plan") && order(y).status === "WAIT_PLAN_CHANGE", "activated year → plan change step");
  out = await photo(C3, subsPage({ upcoming_plan_change: true, plan_price_inr: 299 }));
  assert(has(out, C3, T.wrong12Month), "₹299 → told to pick Annual ₹199");
  out = await photo(C3, subsPage({ upcoming_plan_change: true, plan_price_inr: 199 }));
  assert(has(out, C3, T.congrats) && has(out, C3, "(سنة)") && order(y).status === "DONE", "Upcoming Plan Change ₹199 → congrats + final year");

  // ---------- "ما كاينش رصيد" ثلاث مرات: نفس الرابط، بلا كود ثاني ----------
  const C4 = "555";
  const m4 = await newOrder("2months");
  await text(C4, m4);
  out = await photo(C4, snapPage());
  const gift4 = /code=([^\s]+)/.exec(texts(out, C4).join("\n"))[1];
  out = await text(C4, "ma kanch rasid");
  assert(texts(out, C4).some((t) => t.includes(gift4)), "no balance #1: same link re-sent");
  out = await text(C4, "ma kanch rasid");
  assert(texts(out, C4).some((t) => t.includes(gift4)), "no balance #2: same link re-sent");
  out = await text(C4, "ma kanch rasid");
  assert(has(out, C4, T.pAskBalanceShot), "no balance #3: asks for the balance screenshot");
  assert(sql(`select count(*) from bot_cards where note like '%${m4}%'`) === "1", "still exactly one credit code for this order");
  out = await photo(C4, snapPage({ page_type: "appstore_account", currency: "INR", balance_inr: 100 }));
  assert(has(out, C4, T.pBalanceOkRetry), "balance covers ₹98 → activation steps again");
  out = await photo(C4, snapPage({ page_type: "appstore_account", currency: "INR", balance_inr: 10 }));
  assert(order(m4).status === "HUMAN" && has(out, ADMIN, "الرصيد ناقص"), "balance short → owner, with the screenshot");

  // ---------- المشاكل 2، 3، 6 ----------
  const C5 = "666";
  const m5 = await newOrder("month");
  await text(C5, m5);
  out = await photo(C5, snapPage());
  const gift5 = /code=([^\s]+)/.exec(texts(out, C5).join("\n"))[1];
  out = await photo(C5, snapPage({ page_type: "other", currency: "none", has_continue_button: true }));
  assert(has(out, C5, "اضغط Continue") && texts(out, C5).some((t) => t.includes(gift5)), "Continue screen → same link again");
  out = await photo(C5, snapPage({ page_type: "redeem_screen", currency: "none" }));
  assert(has(out, C5, T.pRedeemScreen), "black Redeem screen → normal, go activate");
  out = await text(C5, "goulili raki f store algérie");
  assert(has(out, C5, T.pRestartPhone), "Algerian store #1 → restart phone");
  out = await text(C5, "mazal algérie");
  assert(has(out, C5, T.pAskCountryShot), "Algerian store #2 → asks App Store account screenshot");
  out = await photo(C5, snapPage({ page_type: "appstore_account", currency: "none", country_shown: "Algeria" }));
  assert(has(out, C5, "البلاد ما تبدلتش"), "account shows Algeria → country video again");
  out = await text(C5, "kifach ndir?");
  assert(has(out, C5, "جواب حر"), "a free question gets the AI answer");
  out = await text(C5, "ch7al sooma? prix");
  assert(has(out, C5, T.moneyQuestion) && order(m5).status === "HUMAN", "money question → owner");
  await text(ADMIN, `/release ${m5}`);

  // ---------- كلمة السر ----------
  out = await text(C5, "mot de passe ta3i Ahmed2024!");
  assert(has(out, C5, "ما تبعثش mot de passe") && deleted.length === 1, "a password is deleted and the customer warned");
  assert(sql(`select count(*) from bot_events where data::text like '%Ahmed2024%'`) === "0", "the password never reaches the log");

  // ---------- الفوكالات ----------
  sql(`update activation_chats set rl_count = 0, rl_media = 0 where chat_id = '${C5}'`);
  out = await voice(C5, "ممم");
  assert(has(out, C5, T.voiceUnclear), "unclear voice → asked to write or send a screenshot");
  out = await voice(C5, "ما لقيتش subscriptions في الستور");
  assert(has(out, C5, T.pNoSubscriptions), "voice transcript is handled like a written message");
  out = await voice(C5, null, 95);
  assert(has(out, C5, T.handoff) && order(m5).status === "HUMAN", "voice over a minute → owner");
  assert(out.some((m) => m.method === "copyMessage" && String(m.chat_id) === ADMIN), "…with the voice note forwarded");
  await text(ADMIN, `/release ${m5}`);

  // ---------- وضع المراجعة ----------
  await text(ADMIN, "/review on");
  const C6 = "777";
  const m6 = await newOrder("month");
  await text(C6, m6);
  out = await photo(C6, snapPage());
  assert(has(out, C6, T.reviewWait) && !has(out, C6, "apps.apple.com"), "review on: the link waits for the owner");
  const review = out.find((m) => String(m.chat_id) === ADMIN && /مراجعة/.test(m.text || ""));
  assert(review && review.reply_markup.inline_keyboard[0].length === 2, "owner gets the AI opinion with accept/reject");
  out = await text(C6, "?");
  assert(has(out, C6, T.stillReviewing), "customer waiting during review");
  out = await press(ADMIN, `a:accept:${m6}`, review.message_id);
  assert(has(out, C6, "apps.apple.com"), "accept → link sent");
  out = await press(ADMIN, `a:accept:${m6}`, review.message_id);
  assert(has(out, ADMIN, "تقرر ديجا") && !has(out, C6, "apps.apple.com"), "a second accept does nothing");
  await text(ADMIN, "/review off");

  // ---------- الستوك فارغ ثم /release ----------
  sql(`update bot_cards set status = 'disabled' where code like 'TEST-GIFT-%' and status = 'available'`);
  const C7 = "888";
  const m7 = await newOrder("year");
  await text(C7, m7);
  out = await photo(C7, snapPage());
  assert(has(out, C7, T.justAMinute) && has(out, ADMIN, "عاجل"), "empty stock: customer waits, owner gets an urgent alert");
  sql(`insert into bot_cards(variant_id, code) select v.id, 'TEST-GIFT-250-9' from bot_variants v
         join bot_products p on p.id = v.product_id where p.code='appleinr' and v.code='r250'`);
  out = await text(ADMIN, `/release ${m7}`);
  assert(texts(out, C7).some((t) => t.includes("TEST-GIFT-250-9")), "after restocking, /release sends the link right away");

  // ---------- حد الميساجات ----------
  let limited = [];
  for (let i = 0; i < 8; i++) limited = limited.concat(await photo("999", null));
  assert(texts(limited, "999").filter((t) => t === T.rateLimited).length === 1, "media flood: one warning, then silence");

  // ---------- أوامر مرفوضة لغير الأدمين + update مكرر ----------
  out = await text(C7, "/new year");
  assert(!has(out, C7, "JN-"), "/new from a customer creates nothing");
  const before = sql("select count(*) from bot_events");
  await bot.handleUpdate({ update_id: upd - 1, message: { ...base(C7), text: "/new year" } });
  assert(sql("select count(*) from bot_events") === before, "a re-delivered update is ignored");

  out = await text(ADMIN, "/orders");
  assert(has(out, ADMIN, m4), "/orders lists the order waiting for the owner");
  out = await text(ADMIN, `/order ${m4}`);
  assert(has(out, ADMIN, "HUMAN"), "/order shows where an order is");

  // ---------- حماية: كلمة السر (دالة) ----------
  assert(F.looksLikePassword("Ahmed@2024") && !F.looksLikePassword("JN-1234") && !F.looksLikePassword("kifach ndir mot de passe?"),
    "password detection: obvious passwords yes, codes and questions no");

  // ---------- دالة Vercel: السر ----------
  process.env.ACTIVATION_WEBHOOK_SECRET = "s3cret";
  const entry = require("../../api/activation-bot.js");
  const call = async (method, secret) => {
    const res = { code: 0, status(c) { this.code = c; return this; }, setHeader() { return this; }, end() {} };
    await entry({ method, headers: secret ? { "x-telegram-bot-api-secret-token": secret } : {}, body: { update_id: 1 } }, res);
    return res.code;
  };
  assert(await call("GET") === 405, "webhook: GET refused");
  assert(await call("POST") === 401 && await call("POST", "wrong") === 401, "webhook: missing or wrong secret refused");

  if (errors.length) console.log(errors);
  assert(errors.length === 0, "no handler errors");
  sql(`delete from bot_cards where code like 'TEST-GIFT-%' and status <> 'sold';`);
  console.log(green(`===== activation bot: ${passed} checks passed =====`));
}

main().catch((e) => { console.error(e); process.exitCode = 1; });
