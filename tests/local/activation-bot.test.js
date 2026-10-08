/* ============================================================
   بوت تفعيل Snapchat+ — اختبار من الأول للآخر (القسم 14).

     node tests/local/activation-bot.test.js [dbname]

   الكليان في واتساب، مالك في تيليغرام. يشغّل المنطق الحقيقي
   (handler.js)، الطبقتين الحقيقيتين (adapters/whatsapp.js و
   adapters/telegram.js)، Storage الحقيقي (storage.js) ودوال القاعدة
   الحقيقية (042 + 043). كل الشبكة وهمية داخل fetch:
     - graph.facebook.com   : يسجل كل ميساج ويرجع wamid، رفع/تنزيل الميديا
     - api.telegram.org     : يسجل كل ميساج لمالك
     - /storage/v1          : ذاكرة
     - /rest/v1/rpc/*       : SQL على psql
   والـAI نتائج مكتوبة مسبقاً.
   ============================================================ */
const { execFileSync } = require("child_process");
const { createTelegramAdapter } = require("../../lib/activation-bot/adapters/telegram");
const { createWhatsAppAdapter } = require("../../lib/activation-bot/adapters/whatsapp");
const { createDb } = require("../../lib/activation-bot/db");
const { createStorage } = require("../../lib/activation-bot/storage");
const { createHandler } = require("../../lib/activation-bot/handler");
const { BudgetError } = require("../../lib/activation-bot/ai");
const F = require("../../lib/activation-bot/flow");
const { T } = require("../../lib/activation-bot/texts");

const DB = process.argv[2] || process.env.JANEIRO_TEST_DB || "janeiro_test";
const ADMIN = "9001";
const STORE = "213555000111";
const PNID = "PNID1";

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

/* ---------- الشبكة الوهمية ---------- */
let sent = [];           // كل ما تبعث: { platform, chat, kind, text, media, buttons }
let nextTg = 1000;
let nextWa = 1;
const store = new Map(); // Supabase Storage
const waUploads = [];
const deadMedia = new Set();

async function rpcFetch(url, init) {
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

async function storageFetch(url, init = {}) {
  const path = decodeURIComponent(new URL(url).pathname.replace("/storage/v1/object/bot-media/", ""));
  if (init.method === "POST") {
    store.set(path, { bytes: Buffer.from(init.body), mime: init.headers["content-type"] });
    return new Response("{}", { status: 200 });
  }
  if (init.method === "DELETE") {
    for (const p of JSON.parse(init.body).prefixes) store.delete(p);
    return new Response("[]", { status: 200 });
  }
  const f = store.get(path);
  return f ? new Response(f.bytes, { status: 200, headers: { "content-type": f.mime } }) : new Response("nf", { status: 404 });
}

async function graphFetch(url, init = {}) {
  const u = new URL(url);
  if (u.hostname === "lookaside.example") return new Response(Buffer.from(`bytes-of-${u.pathname}`), { status: 200 });
  const path = u.pathname.replace(/^\/v[\d.]+\//, "");
  if (path === `${PNID}/media`) {
    const id = `WA_MEDIA_${nextWa++}`;
    waUploads.push({ id, type: init.body.get("type") });
    return Response.json({ id });
  }
  if (path === `${PNID}/messages`) {
    const b = JSON.parse(init.body);
    const m = b[b.type] || {};
    if (m.id && deadMedia.has(m.id)) {
      return Response.json({ error: { code: 131053, message: "Media upload error" } }, { status: 400 });
    }
    const rec = { platform: "wa", chat: b.to || `u:${b.recipient}`, kind: b.type };
    if (b.type === "text") rec.text = b.text.body;
    if (b.type === "interactive") {
      rec.text = b.interactive.body.text;
      rec.buttons = b.interactive.action.buttons.map((x) => x.reply);
    }
    if (["image", "video", "audio"].includes(b.type)) { rec.media = m.id; rec.voice = m.voice; }
    const id = `wamid.out.${nextWa++}`;
    sent.push({ ...rec, id });
    return Response.json({ messages: [{ id }] });
  }
  // GET /{media-id}
  return Response.json({ url: `https://lookaside.example/${path}`, mime_type: path.startsWith("aud") ? "audio/ogg" : "image/jpeg" });
}

async function tgFetch(url, init = {}) {
  if (url.includes("/file/bot")) return new Response(Buffer.from("tg-file"), { status: 200 });
  const method = url.split("/").pop();
  if (init.body instanceof FormData) { // sendFile (صورة/فوكال كليان لمالك)
    const id = nextTg++;
    sent.push({ platform: "tg", chat: init.body.get("chat_id"), kind: method, upload: true, id });
    return Response.json({ ok: true, result: { message_id: id } });
  }
  const body = init.body ? JSON.parse(init.body) : {};
  if (method === "getFile") {
    const fid = String(body.file_id);
    const ext = fid.startsWith("TGVID") ? "mp4" : fid.startsWith("TGV") ? "oga" : "jpg";
    return Response.json({ ok: true, result: { file_path: `f/${fid}.${ext}`, file_size: 7 } });
  }
  if (["answerCallbackQuery", "editMessageReplyMarkup", "deleteMessage"].includes(method)) return Response.json({ ok: true, result: true });
  const id = nextTg++;
  sent.push({ platform: "tg", chat: String(body.chat_id), kind: method, text: body.text, media: body.voice || body.video || body.photo,
              buttons: body.reply_markup && body.reply_markup.inline_keyboard, id });
  return Response.json({ ok: true, result: { message_id: id } });
}

/* ---------- الـAI الوهمي ---------- */
const shots = [];
const voices = [];
let aiBudgetHit = false;
function intentOf(text) {
  const t = text.toLowerCase();
  if (/rasid|رصيد|paiement/.test(t)) return { intent: "no_balance", reply: "" };
  if (/algérie|الجزائري|dz/.test(t)) return { intent: "wrong_store", reply: "" };
  if (/insan|إنسان|مالك/.test(t)) return { intent: "wants_human", reply: "" };
  if (/prix|سومة|شحال/.test(t)) return { intent: "money", reply: "" };
  if (/subscriptions/.test(t)) return { intent: "no_subscriptions", reply: "" };
  if (/kifach|كيفاش/.test(t)) return { intent: "question", reply: "جواب حر" };
  return { intent: "unclear", reply: "" };
}
const ai = {
  async analyzeScreenshot() {
    if (aiBudgetHit) throw new BudgetError(5, 5);
    if (!shots.length) throw new Error("no scripted analysis");
    return shots.shift();
  },
  async interpretText({ text }) {
    if (aiBudgetHit) throw new BudgetError(5, 5);
    return intentOf(text);
  },
  async interpretVoice() {
    const v = voices.shift() || { transcript: "" };
    return { ...intentOf(v.transcript), transcript: v.transcript, seconds: v.seconds || 5 };
  },
};

/* ---------- البوت ---------- */
const db = createDb({ url: "http://db.local", serviceKey: "svc", fetchImpl: rpcFetch });
const wa = createWhatsAppAdapter({ token: "WA", phoneNumberId: PNID, fetchImpl: graphFetch, onSent: (ids) => db.markSent("whatsapp", ids) });
const tg = createTelegramAdapter({ token: "TG", fetchImpl: tgFetch });
const storage = createStorage({ url: "http://db.local", serviceKey: "svc", fetchImpl: storageFetch });
const errors = [];
const bot = createHandler({
  channels: { whatsapp: wa, telegram: tg }, admin: tg, db, storage, ai,
  adminIds: [ADMIN], storeWhatsapp: STORE, log: (e) => errors.push(e),
});

/* ---------- مساعدين ---------- */
let n = 1;
const waBody = (value) => ({ object: "whatsapp_business_account", entry: [{ id: "WABA", changes: [{ field: "messages", value }] }] });
async function waSend(chat, message) {
  sent = [];
  await bot.handleWebhook("whatsapp", waBody({ messaging_product: "whatsapp", messages: [{ from: chat, id: `wamid.in.${n++}`, timestamp: "1", ...message }] }));
  return sent;
}
const text = (chat, body) => waSend(chat, { type: "text", text: { body } });
async function photo(chat, analysis) {
  shots.length = 0;
  if (analysis) shots.push(analysis);
  return waSend(chat, { type: "image", image: { id: `img${n}`, mime_type: "image/jpeg" } });
}
async function voice(chat, transcript, seconds) {
  voices.length = 0;
  voices.push({ transcript, seconds });
  return waSend(chat, { type: "audio", audio: { id: `aud${n}`, mime_type: "audio/ogg; codecs=opus", voice: true } });
}
const press = (chat, id) => waSend(chat, { type: "interactive", interactive: { type: "button_reply", button_reply: { id, title: "x" } } });
async function echo(chat, id = `wamid.echo.${n++}`) {
  sent = [];
  await bot.handleWebhook("whatsapp", { entry: [{ changes: [{ field: "smb_message_echoes",
    value: { messaging_product: "whatsapp", message_echoes: [{ from: STORE, to: chat, id, timestamp: "1", type: "text", text: { body: "salam" } }] } }] }] });
  return sent;
}

let upd = 1;
let tgMid = 1;
const tgBase = (chat) => ({ message_id: tgMid++, chat: { id: Number(chat), type: "private" }, from: { id: Number(chat) } });
async function tgMsg(chat, message) {
  sent = [];
  await bot.handleWebhook("telegram", { update_id: upd++, message: { ...tgBase(chat), ...message } });
  return sent;
}
const admin = (t, extra = {}) => tgMsg(ADMIN, { text: t, ...extra });
async function adminPress(data, messageId = 1) {
  sent = [];
  await bot.handleWebhook("telegram", { update_id: upd++, callback_query: { id: `cb${upd}`, from: { id: Number(ADMIN) }, data,
    message: { message_id: messageId, chat: { id: Number(ADMIN), type: "private" } } } });
  return sent;
}

const to = (out, chat) => out.filter((m) => String(m.chat) === String(chat));
const texts = (out, chat) => to(out, chat).filter((m) => m.text).map((m) => m.text);
const has = (out, chat, needle) => texts(out, chat).some((t) => t.includes(needle));
const order = (code) => JSON.parse(sql(`select to_json(o) from activation_orders o where code = '${code}'`));
const btnData = (out, chat) => to(out, chat).flatMap((m) => (m.buttons || []).flat()).map((b) => b.callback_data || b.id);
async function newOrder(type) {
  const out = await admin(`/new ${type}`);
  const link = texts(out, ADMIN).find((t) => t.startsWith("https://wa.me/"));
  assert(link && /^https:\/\/wa\.me\/213555000111\?text=JN-\d{4}$/.test(link), `/new ${type} → copy-ready wa.me link alone in its message`);
  return link.split("=")[1];
}

const snapPage = (o = {}) => ({
  page_type: "snap_plus_offer", currency: "INR", has_free_trial: true, already_subscribed: false,
  upcoming_plan_change: false, plan_price_inr: null, balance_inr: null, country_shown: null,
  has_continue_button: false, ui_language: "fr", confidence: 0.95, ...o,
});
const subsPage = (o = {}) => snapPage({ page_type: "appstore_subscriptions", has_free_trial: false, ...o });

/* ============================================================ */
async function main() {
  sql(`delete from activation_admin_msgs; delete from bot_events; delete from activation_chats;
       update bot_cards set status = 'disabled' where status = 'available';
       delete from activation_orders; delete from activation_updates; delete from bot_media; delete from bot_media_drafts;
       delete from ai_spend; delete from store_settings where key = 'activation_last_sweep';
       select act_set_review(false);`);
  sql(`insert into bot_products(code, name) values ('appleinr', 'Apple INR') on conflict (code) do nothing;
       insert into bot_variants(product_id, code, name) select id, 'r100', '₹100' from bot_products where code='appleinr' on conflict do nothing;
       insert into bot_variants(product_id, code, name) select id, 'r250', '₹250' from bot_products where code='appleinr' on conflict do nothing;
       delete from bot_cards where code like 'TEST-GIFT-%';`);

  // ---------- الستوك ----------
  let out = await admin("/giftamount appleinr r100 100");
  assert(has(out, ADMIN, "₹100"), "/giftamount marks a stock variant as ₹100 credit");
  await admin("/giftamount appleinr r250 250");
  sql(`insert into bot_cards(variant_id, code) select v.id, 'TEST-GIFT-100-' || g from bot_variants v
         join bot_products p on p.id = v.product_id, generate_series(1,3) g where p.code='appleinr' and v.code='r100';
       insert into bot_cards(variant_id, code) select v.id, 'TEST-GIFT-250-' || g from bot_variants v
         join bot_products p on p.id = v.product_id, generate_series(1,3) g where p.code='appleinr' and v.code='r250';`);
  out = await admin("/stock");
  assert(has(out, ADMIN, "₹100: 3") && has(out, ADMIN, "₹250: 3"), "/stock shows credit codes by amount");

  // ---------- الميديا: caption، ثم بالأزرار ----------
  out = await tgMsg(ADMIN, { caption: "/media video_country", video: { file_id: "TGVIDCOUNTRY", duration: 30, mime_type: "video/mp4" } });
  assert(has(out, ADMIN, "video_country"), "/media caption saves the country video");
  assert(store.has("media/video_country.mp4"), "…the original goes to Supabase Storage");
  assert(waUploads.some((u) => u.type === "video/mp4"), "…and is uploaded to WhatsApp media");

  out = await tgMsg(ADMIN, { photo: [{ file_id: "TGPHCARD" }] });
  let picks = btnData(out, ADMIN);
  assert(has(out, ADMIN, "وين تحب تحط هذي الصورة") && picks.some((d) => d.endsWith(":photo_snap_card")), "a photo with no command → slot buttons");
  out = await adminPress(picks.find((d) => d.endsWith(":photo_snap_card")));
  assert(has(out, ADMIN, "تحفظ ✅"), "picking the slot saves the photo");

  // فوكال بالأزرار: الخانة ثم الطريقة، ثم معاينة
  out = await tgMsg(ADMIN, { voice: { file_id: "TGVWELCOME", duration: 9, mime_type: "audio/ogg" } });
  picks = btnData(out, ADMIN);
  assert(has(out, ADMIN, "وين تحب تحط هذا الفوكال") && picks.length >= 11, "a voice note → «where to put it» with every step + problem file");
  out = await adminPress(picks.find((d) => d.endsWith(":voice_welcome")));
  const modes = btnData(out, ADMIN);
  assert(modes.length === 3 && modes.every((d) => d.startsWith("m:")), "then [فوكال برك] [نص برك] [الاثنين]");
  out = await adminPress(modes.find((d) => d.endsWith(":both")));
  assert(has(out, ADMIN, "تحفظ ✅") && has(out, ADMIN, "نبداو التفعيل") && to(out, ADMIN).some((m) => m.kind === "sendVoice"),
    "saved ✅ + preview: the welcome text and the voice, as the customer will see them");
  assert(store.has("media/voice_welcome.ogg") && waUploads.some((u) => u.type === "audio/ogg"), "voice stored and uploaded to WhatsApp as ogg");
  out = await adminPress(modes.find((d) => d.endsWith(":both")));
  assert(has(out, ADMIN, "تحفظ ديجا"), "a second press saves nothing");

  // فوكال مشكل + /voices + مسح
  out = await tgMsg(ADMIN, { voice: { file_id: "TGVPROB", duration: 4, mime_type: "audio/ogg" } });
  out = await adminPress(btnData(out, ADMIN).find((d) => d.endsWith(":pl")));
  const probBtn = btnData(out, ADMIN).find((d) => /voice_problem_\d+$/.test(d));
  assert(probBtn, "«مشكل من الملف» lists the problems");
  out = await adminPress(probBtn);
  out = await adminPress(btnData(out, ADMIN).find((d) => d.endsWith(":voice")));
  assert(has(out, ADMIN, "تحفظ ✅") && has(out, ADMIN, "فوكال برك"), "problem voice saved in voice-only mode");
  out = await admin("/voices");
  const vlist = btnData(out, ADMIN);
  assert(vlist.includes("vl:voice_welcome") && vlist.some((d) => /^vd:voice_problem_/.test(d)), "/voices lists saved voices with [اسمع] [امسح]");
  out = await adminPress("vl:voice_welcome");
  assert(to(out, ADMIN).some((m) => m.kind === "sendVoice"), "[اسمع] plays it");
  const probSlot = vlist.find((d) => /^vd:voice_problem_/.test(d)).slice(3);
  out = await adminPress(`vd:${probSlot}`);
  assert(has(out, ADMIN, "تمسح") && sql(`select count(*) from bot_media where slot = '${probSlot}'`) === "0", "[امسح] deletes it");

  // ---------- الرقم مشترك: البوت ساكت ----------
  const STRANGER = "213700000001";
  out = await text(STRANGER, "salam, 3andkom netflix?");
  assert(out.length === 0, "a number with no order and no code gets nothing (sales chat)");
  assert(sql(`select count(*) from bot_events where chat_id = '${STRANGER}'`) === "0", "…and nothing is logged about it");

  // ---------- مسار شهر كامل ----------
  const C1 = "213600000001";
  const m1 = await newOrder("month");
  out = await text(C1, `${m1} salam khouya`);
  const welcome = to(out, C1).find((m) => m.kind === "interactive");
  assert(welcome && welcome.text.includes("طلبك: سناب بلس شهر. نبداو التفعيل") && welcome.buttons[0].id === "c:problem",
    "code found inside the message → welcome with [عندي مشكل] button");
  assert(to(out, C1).some((m) => m.kind === "video") && to(out, C1).some((m) => m.kind === "image"), "welcome carries the country video and the card photo");
  assert(to(out, C1).some((m) => m.kind === "audio" && m.voice === true), "owner's voice goes out as a WhatsApp voice note");
  assert(order(m1).status === "WAIT_SNAP_SCREENSHOT" && order(m1).customer_chat_id === C1, "order bound to the customer's number");

  out = await photo(C1, snapPage({ currency: "DZD" }));
  assert(has(out, C1, "البلاد ما تبدلتش") && to(out, C1).some((m) => m.kind === "video"), "price in dinars: country video is sent again");

  out = await photo(C1, snapPage({ has_free_trial: false, ui_language: "en" }));
  const link1 = texts(out, C1).find((t) => t.includes("apps.apple.com/redeem"));
  assert(link1 && link1.includes("TEST-GIFT-100-"), "month accepted without a trial: smallest covering code (₹100)");
  const act1 = to(out, C1).find((m) => m.kind === "interactive");
  assert(act1 && act1.text.includes("Monthly") && act1.text.includes("الزر الأصفر لتحت") &&
         act1.buttons.map((b) => b.id).join() === "c:activated,c:problem", "activation steps with [تفعّل ✅] [عندي مشكل]");

  out = await press(C1, "c:activated");
  assert(has(out, C1, "كيفاش يمشي اشتراك سناب بلس (شهر)") && order(m1).status === "DONE", "[تفعّل ✅] → final month message, DONE");
  out = await text(C1, "merci bzf");
  assert(out.length === 0, "after DONE the bot is silent again (the owner's chat)");

  // ---------- أكواد غالطة ----------
  const C9 = "213600000009";
  out = await text(C9, m1);
  assert(has(out, C9, "في إنستا"), "a code bound to another number is refused");
  for (let i = 0; i < 3; i++) await text(C9, "JN-0000");
  out = await text(C9, "JN-0001");
  assert(has(out, C9, T.badCode), "5th wrong code still answered");
  out = await text(C9, "JN-0002");
  assert(out.length === 0, "after 5 wrong codes: silent for an hour");

  // ---------- شهرين بلا تجربة مجانية → مالك يجاوب من التطبيق ----------
  const C2 = "213600000002";
  const m2 = await newOrder("2months");
  await text(C2, m2);
  out = await photo(C2, snapPage({ has_free_trial: false }));
  assert(has(out, C2, T.holdOn) && !has(out, C2, "apps.apple.com"), "two months without trial: no link, customer told to wait");
  const alert2 = to(out, ADMIN).find((m) => (m.text || "").includes("ما كاينش تجربة مجانية"));
  assert(alert2 && alert2.text.includes("واتساب بزنس") &&
         alert2.buttons.flat().map((b) => b.callback_data).join() === `a:release:${m2},a:close:${m2}`, "owner alert: [رجع للبوت] [غلق الطلب]");
  assert(to(out, ADMIN).some((m) => m.upload && m.kind === "sendPhoto"), "…with the customer's screenshot");
  out = await text(C2, "wach rak");
  assert(out.length === 0, "HUMAN: the bot is silent; the owner answers from the WhatsApp Business app");
  out = await adminPress(`a:release:${m2}`);
  assert(order(m2).status === "WAIT_SNAP_SCREENSHOT" && has(out, C2, T.resume), "[رجع للبوت] → back to the same step");
  const botMsg = to(out, C2)[0].id;

  // ---------- مالك كتب من التطبيق (echo) ----------
  out = await echo(C2, botMsg);
  assert(order(m2).status === "WAIT_SNAP_SCREENSHOT", "an echo of the bot's own message does not pause it");
  out = await echo(C2);
  assert(order(m2).status === "HUMAN" && has(out, ADMIN, "كتبت من التطبيق"), "owner typing in the app pauses the bot on that order");
  out = await text(C2, "ok");
  assert(out.length === 0, "…and the bot stays quiet");
  await admin(`/release ${m2}`);
  out = await echo("213699999999");
  assert(out.length === 0, "an echo in a sales chat (no order) does nothing");

  // ---------- سنة ----------
  const C3 = "213600000003";
  const y = await newOrder("year");
  await text(C3, y);
  out = await photo(C3, snapPage());
  assert(texts(out, C3).some((t) => t.includes("TEST-GIFT-250-")), "year needs ₹199: ₹250 code chosen, not ₹100");
  out = await press(C3, "c:activated");
  assert(has(out, C3, "Annual Plan") && order(y).status === "WAIT_PLAN_CHANGE", "activated year → plan change step");
  out = await photo(C3, subsPage({ upcoming_plan_change: true, plan_price_inr: 299 }));
  assert(has(out, C3, T.wrong12Month), "₹299 → pick Annual ₹199");
  out = await photo(C3, subsPage({ upcoming_plan_change: true, plan_price_inr: 199 }));
  assert(has(out, C3, T.congrats) && has(out, C3, "(سنة)") && order(y).status === "DONE", "₹199 → congrats + final year");

  // ---------- ما كاينش رصيد ×3 ----------
  const C4 = "213600000004";
  const m4 = await newOrder("2months");
  await text(C4, m4);
  out = await photo(C4, snapPage());
  const gift4 = /code=([^\s]+)/.exec(texts(out, C4).join("\n"))[1];
  out = await text(C4, "ma kanch rasid");
  assert(texts(out, C4).some((t) => t.includes(gift4)), "no balance #1: same link");
  out = await text(C4, "ma kanch rasid");
  out = await text(C4, "ma kanch rasid");
  assert(has(out, C4, T.pAskBalanceShot), "no balance #3: balance screenshot");
  assert(sql(`select count(*) from bot_cards where note like '%${m4}%'`) === "1", "still one credit code for this order");
  out = await photo(C4, snapPage({ page_type: "appstore_account", balance_inr: 100 }));
  assert(has(out, C4, T.pBalanceOkRetry), "balance covers → activation again");
  out = await photo(C4, snapPage({ page_type: "appstore_account", balance_inr: 10 }));
  assert(order(m4).status === "HUMAN" && has(out, ADMIN, "الرصيد ناقص"), "balance short → owner");

  // ---------- المشاكل، الدراهم، كلمة السر، الفوكالات ----------
  const C5 = "213600000005";
  const m5 = await newOrder("month");
  await text(C5, m5);
  out = await photo(C5, snapPage());
  const gift5 = /code=([^\s]+)/.exec(texts(out, C5).join("\n"))[1];
  out = await photo(C5, snapPage({ page_type: "other", currency: "none", has_continue_button: true }));
  assert(texts(out, C5).some((t) => t.includes(gift5) && t.includes("Continue")), "Continue screen → same link again");
  out = await photo(C5, snapPage({ page_type: "redeem_screen", currency: "none" }));
  assert(has(out, C5, T.pRedeemScreen), "black Redeem screen → normal");
  sql(`update activation_chats set rl_count = 0, rl_media = 0 where chat_id = '${C5}'`);
  out = await text(C5, "raki f store algérie");
  assert(has(out, C5, T.pRestartPhone), "Algerian store #1 → restart");
  out = await text(C5, "mazal algérie");
  assert(has(out, C5, T.pAskCountryShot), "Algerian store #2 → account screenshot");
  out = await text(C5, "kifach ndir?");
  assert(has(out, C5, "جواب حر"), "free question → AI answer");
  out = await text(C5, "mot de passe ta3i Ahmed2024!");
  assert(has(out, C5, "ما تبعثش mot de passe") && sql(`select count(*) from bot_events where data::text like '%Ahmed2024%'`) === "0",
    "a password is never logged; customer told to delete it");
  out = await voice(C5, "ممم");
  assert(has(out, C5, T.voiceUnclear), "unclear voice");
  out = await voice(C5, "ما لقيتش subscriptions");
  assert(has(out, C5, T.pNoSubscriptions), "voice handled like a written message");
  out = await voice(C5, "حكاية طويلة", 95);
  assert(order(m5).status === "HUMAN" && to(out, ADMIN).some((m) => m.upload && m.kind === "sendVoice"), "voice over a minute → owner, with the voice");
  await admin(`/release ${m5}`);
  out = await text(C5, "ch7al sooma? prix");
  assert(has(out, C5, T.moneyQuestion) && order(m5).status === "HUMAN", "money question → owner");
  await admin(`/release ${m5}`);

  // ---------- وضع المراجعة ----------
  await admin("/review on");
  const C6 = "213600000006";
  const m6 = await newOrder("month");
  await text(C6, m6);
  out = await photo(C6, snapPage());
  assert(has(out, C6, T.reviewWait) && !has(out, C6, "apps.apple.com"), "review on: the link waits for the owner");
  const review = to(out, ADMIN).find((m) => /مراجعة/.test(m.text || ""));
  assert(review && review.buttons[0].length === 2 && to(out, ADMIN).some((m) => m.upload), "owner gets the AI opinion + the photo + accept/reject");
  out = await adminPress(`a:accept:${m6}`, review.id);
  assert(has(out, C6, "apps.apple.com"), "accept → link sent");
  out = await adminPress(`a:accept:${m6}`, review.id);
  assert(has(out, ADMIN, "تقرر ديجا"), "a second accept does nothing");
  await admin("/review off");

  // ---------- media_id مات: يتعاود الرفع من Storage ----------
  const deadId = sql(`select file_id from bot_media where slot = 'video_country' and platform = 'whatsapp'`);
  deadMedia.add(deadId);
  const C7 = "213600000007";
  const m7 = await newOrder("year");
  const uploadsBefore = waUploads.length;
  out = await text(C7, m7);
  const newId = sql(`select file_id from bot_media where slot = 'video_country' and platform = 'whatsapp'`);
  assert(newId !== deadId && waUploads.length === uploadsBefore + 1 && to(out, C7).some((m) => m.kind === "video" && m.media === newId),
    "expired WhatsApp media_id → re-uploaded from Storage and sent");

  // ---------- الستوك فارغ ثم [رجع للبوت] ----------
  sql(`update bot_cards set status = 'disabled' where code like 'TEST-GIFT-%' and status = 'available'`);
  out = await photo(C7, snapPage());
  assert(has(out, C7, T.justAMinute) && has(out, ADMIN, "عاجل"), "empty stock: customer waits, urgent alert");
  sql(`insert into bot_cards(variant_id, code) select v.id, 'TEST-GIFT-250-9' from bot_variants v
         join bot_products p on p.id = v.product_id where p.code='appleinr' and v.code='r250'`);
  out = await adminPress(`a:release:${m7}`);
  assert(texts(out, C7).some((t) => t.includes("TEST-GIFT-250-9")), "after restocking, release sends the link right away");

  // ---------- نافذة 24 ساعة ----------
  await admin(`/take ${m7}`);
  sql(`update activation_orders set window_expires_at = now() - interval '1 minute' where code = '${m7}'`);
  out = await admin(`/release ${m7}`);
  assert(to(out, C7).length === 0 && has(out, ADMIN, "نافذة 24 ساعة"), "outside the 24h window the bot does not write; owner told why");
  out = await text(C7, "rani hna");
  assert(to(out, C7).length > 0, "the customer writes → window reopens and the bot answers");

  // ---------- /stop و [غلق الطلب] ----------
  out = await admin(`/stop ${m7}`);
  assert(order(m7).status === "CLOSED" && has(out, ADMIN, "تغلق"), "/stop closes the order");
  out = await text(C7, "allo?");
  assert(out.length === 0, "closed: the bot never talks in that chat again");
  out = await text(C7, m7);
  assert(has(out, C7, T.badCode), "a closed code no longer works");
  out = await adminPress(`a:close:${m5}`);
  assert(order(m5).status === "CLOSED", "[غلق الطلب] closes from the alert");

  // ---------- 48 ساعة بلا ما يكمل ----------
  const C8 = "213600000008";
  const m8 = await newOrder("month");
  await text(C8, m8);
  sql(`set session_replication_role = replica;
       update activation_orders set updated_at = now() - interval '49 hours' where code = '${m8}';
       set session_replication_role = origin;
       delete from store_settings where key = 'activation_last_sweep';`);
  out = await text(STRANGER, "salam");
  assert(order(m8).status === "CLOSED" && has(out, ADMIN, m8) && has(out, ADMIN, "48 ساعة"), "unfinished after 48h → closed + owner alert");

  // ---------- ميزانية الـAI ----------
  const C10 = "213600000010";
  const m10 = await newOrder("month");
  await text(C10, m10);
  aiBudgetHit = true;
  out = await photo(C10, null);
  assert(order(m10).status === "HUMAN" && has(out, ADMIN, "الميزانية") && has(out, ADMIN, "عاجل"), "AI budget reached → owner (urgent the first time)");
  await admin(`/release ${m10}`);
  out = await text(C10, "kifach?");
  assert(has(out, ADMIN, "الميزانية") && !has(out, ADMIN, "عاجل"), "…not urgent again the same day");
  aiBudgetHit = false;

  // ---------- احتياط: نفس الكود في تيليغرام ----------
  const C11 = "213600000011";
  const m11 = await newOrder("month");
  await text(C11, m11);
  out = await tgMsg("4242", { text: m11 });
  assert(order(m11).platform === "telegram" && has(out, "4242", "صورلي صفحة سناب") && has(out, ADMIN, "كمل من telegram"),
    "same code from another channel continues where it stopped, owner informed");
  out = await text(C11, "salam");
  assert(out.length === 0, "the old WhatsApp chat no longer drives the order");

  // ---------- أوامر الأدمين ما تخدمش لغيرو + update مكرر ----------
  out = await tgMsg("4242", { text: "/new year" });
  assert(!has(out, "4242", "wa.me"), "/new from a non-admin creates nothing");
  out = await text(C11, "/new year");
  assert(out.length === 0, "the WhatsApp number accepts no commands");
  const before = sql("select count(*) from bot_events");
  await bot.handleWebhook("whatsapp", waBody({ messages: [{ from: C1, id: "wamid.in.1", type: "text", text: { body: m1 } }] }));
  assert(sql("select count(*) from bot_events") === before, "a re-delivered WhatsApp message is ignored");

  out = await admin("/orders");
  assert(has(out, ADMIN, m4) && !has(out, ADMIN, m7), "/orders lists open orders, not closed ones");

  // ---------- دوال Vercel ----------
  process.env.WHATSAPP_VERIFY_TOKEN = "vt";
  process.env.WHATSAPP_APP_SECRET = "appsecret";
  const waEntry = require("../../api/whatsapp.js");
  let r = await waEntry.GET(new Request("https://x/api/whatsapp?hub.mode=subscribe&hub.verify_token=vt&hub.challenge=42"));
  assert(r.status === 200 && (await r.text()) === "42", "Meta webhook verification answers the challenge");
  r = await waEntry.GET(new Request("https://x/api/whatsapp?hub.mode=subscribe&hub.verify_token=no&hub.challenge=42"));
  assert(r.status === 403, "wrong verify token refused");
  r = await waEntry.POST(new Request("https://x/api/whatsapp", { method: "POST", body: "{}", headers: { "x-hub-signature-256": "sha256=00" } }));
  assert(r.status === 401, "bad X-Hub-Signature-256 refused");
  const crypto = require("crypto");
  const raw = '{"entry":[],"note":"\\u00e9"}';
  const sig = "sha256=" + crypto.createHmac("sha256", "appsecret").update(raw).digest("hex");
  assert(waEntry.validSignature(Buffer.from(raw), sig, "appsecret") && !waEntry.validSignature(Buffer.from(raw.replace("\\u00e9", "é")), sig, "appsecret"),
    "signature is checked on the exact raw bytes");

  process.env.ACTIVATION_WEBHOOK_SECRET = "s3cret";
  const tgEntry = require("../../api/activation-bot.js");
  const call = async (method, secret) => {
    const res = { code: 0, status(c) { this.code = c; return this; }, setHeader() { return this; }, end() {} };
    await tgEntry({ method, headers: secret ? { "x-telegram-bot-api-secret-token": secret } : {}, body: { update_id: 1 } }, res);
    return res.code;
  };
  assert(await call("GET") === 405 && await call("POST", "wrong") === 401, "Telegram webhook: GET and wrong secret refused");

  assert(F.looksLikePassword("Ahmed@2024") && !F.looksLikePassword("JN-1234"), "password detection sanity");

  if (errors.length) console.log(errors);
  assert(errors.length === 0, "no handler errors");
  sql(`delete from bot_cards where code like 'TEST-GIFT-%' and status <> 'sold';`);
  console.log(green(`===== activation bot: ${passed} checks passed =====`));
}

main().catch((e) => { console.error(e); if (errors.length) console.error(errors); process.exitCode = 1; });
