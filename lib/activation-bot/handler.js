/* ============================================================
   بوت تفعيل Snapchat+ — المنطق.

   يستقبل ميساج موحّد من طبقة الميساجات (adapters/)، ويقرر بـflow.js،
   ويبعث بطبقة الميساجات. ما يعرفش تيليغرام وما يعرفش Vercel.

   deps = { msg, db, ai, adminIds: Set<string>, botUsername?, log? }
   ============================================================ */

const { T, BTN, TYPE_LABEL, finalText } = require("./texts");
const F = require("./flow");

const MEDIA_SLOTS = ["video_country", "photo_snap_card", "video_plan_two_months", "video_plan_year"];
const VOICE_SLOTS = [
  "voice_welcome", "voice_country", "voice_snap_screenshot", "voice_link", "voice_activation",
  "voice_plan_two_months", "voice_plan_year", "voice_final_month", "voice_final_two_months", "voice_final_year",
];
const isVoiceSlot = (s) => VOICE_SLOTS.includes(s) || /^voice_problem_\d+$/.test(s);

// قرار -> مشكل في الملف (للفوكال voice_problem_<id>)
const ACTION_PROBLEM = {
  no_subscriptions: "no_subscriptions", redeem_screen: "redeem_screen", continue_problem: "continue_button",
  balance_shown: "balance_shown", no_balance_retry: "no_balance", ask_balance_shot: "no_balance",
  restart_phone: "wrong_store", ask_country_shot: "wrong_store", wrong_12month: "wrong_annual_plan",
};

const FINAL_VOICE = { month: "voice_final_month", two_months: "voice_final_two_months", year: "voice_final_year" };

const ADMIN_COMMANDS = new Set([
  "new", "order", "orders", "media", "voice", "voicemode", "problem", "problems", "delproblem",
  "take", "release", "review", "stock", "giftamount", "help",
]);

function createHandler(deps) {
  const { msg, db, ai } = deps;
  const adminIds = new Set([...(deps.adminIds || [])].map(String));
  const platform = msg.platform;
  const report = deps.log || ((e) => console.error("[activation-bot]", e));

  const isAdmin = (inc) => adminIds.has(String(inc.userId)) && inc.isPrivate !== false;

  /* ---------- كاش لكل update ---------- */
  function requestCache() {
    let media, problems;
    return {
      media: async () => (media ??= (await db.mediaAll(platform)) || {}),
      problems: async () => (problems ??= (await db.problems()) || []),
    };
  }

  /* ---------- البعث مع الفوكال والمرفقات ---------- */
  async function say(cache, chatId, text, { buttons, voice, attach = [] } = {}) {
    const media = await cache.media();
    const v = voice && media[voice];
    const hasVoice = v && v.kind === "voice" && v.file_id;
    const mode = (v && v.voice_mode) || (hasVoice ? "both" : "text");
    // الأزرار والروابط لازمهم نص، حتى في وضع "voice"
    const needsText = !hasVoice || mode !== "voice" || (buttons && buttons.length) || /https?:\/\//.test(text || "");

    if (text && needsText) await msg.sendText(chatId, text, { buttons });
    for (const slot of attach) {
      const m = media[slot];
      if (m && m.file_id && m.kind) await msg.sendMedia(chatId, m.kind, m.file_id);
      else await db.log(null, chatId, "media_missing", { slot }).catch(() => {});
    }
    if (hasVoice && mode !== "text") await msg.sendMedia(chatId, "voice", v.file_id);
  }

  async function problemVoice(cache, action) {
    const key = ACTION_PROBLEM[action];
    if (!key) return undefined;
    const p = (await cache.problems()).find((x) => x.key === key);
    return p ? `voice_problem_${p.id}` : undefined;
  }

  /* ---------- تحديث الطلب ---------- */
  async function patch(order, p) {
    const r = await db.updateOrder(order.id, p);
    Object.assign(order, r.order);
    return order;
  }

  /* ---------- التنبيهات لمالك ---------- */
  function header(order, extra) {
    return `🔔 ${order.code} · ${TYPE_LABEL[order.type]} · ${order.resume_status && order.status === "HUMAN" ? order.resume_status : order.status}` +
      (extra ? `\n${extra}` : "");
  }

  async function notifyAdmins(order, text, { copyFrom, buttons } = {}) {
    for (const admin of adminIds) {
      try {
        const id = await msg.sendText(admin, text, { buttons });
        await db.adminMsgAdd(admin, id, order.id);
        if (copyFrom) {
          const cid = await msg.copyMessage(admin, copyFrom.chatId, copyFrom.messageId);
          await db.adminMsgAdd(admin, cid, order.id);
        }
      } catch (e) { report(e); }
    }
  }

  const handoffButtons = (order) => [[
    { text: BTN.take, data: `a:take:${order.code}` },
    { text: BTN.release, data: `a:release:${order.code}` },
  ]];

  /** تحويل لمالك: البوت يسكت (HUMAN) ويرجع لنفس الحالة بعد /release. */
  async function handoff(cache, order, reason, { customerText = "handoff", copyFrom, alert = true, urgent = false } = {}) {
    if (order.status !== "HUMAN") {
      await patch(order, { status: "HUMAN", resume_status: order.status, human_reason: reason });
    } else {
      await patch(order, { human_reason: reason });
    }
    await db.log(order.id, order.customer_chat_id, "handoff", { reason });
    const text = { handoff: T.handoff, holdOn: T.holdOn, money: `${T.moneyQuestion} ${T.handoff}`, justAMinute: T.justAMinute }[customerText] || T.handoff;
    await msg.sendText(order.customer_chat_id, text);
    if (alert) {
      await notifyAdmins(order, (urgent ? "🚨 عاجل\n" : "") + header(order, `السبب: ${reason}`),
        { copyFrom, buttons: handoffButtons(order) });
    }
  }

  /* ---------- رابط الرصيد + خطوات التفعيل (7.3) ---------- */
  async function sendLinkFlow(cache, order) {
    const gift = await db.assignGift(order.id);
    if (!gift || gift.error) {
      return handoff(cache, order, "الستوك فارغ — ما كاينش كود رصيد يغطي الطلب", { customerText: "justAMinute", urgent: true });
    }
    await patch(order, { status: "LINK_SENT" });
    await say(cache, order.customer_chat_id, T.link(gift.code), { voice: "voice_link" });
    await sendActivation(cache, order);
    await patch(order, { status: "WAIT_ACTIVATION_DONE" });
    await db.log(order.id, order.customer_chat_id, "link_sent", { amount_inr: gift.amount_inr, reused: !!gift.reused });
  }

  async function sendActivation(cache, order) {
    const ctx = order.ctx || {};
    await say(cache, order.customer_chat_id,
      T.activation(order.type, order.ui_language || "fr", ctx.has_free_trial),
      { voice: "voice_activation", buttons: [[{ text: BTN.activated, data: "c:activated" }, { text: BTN.problem, data: "c:problem" }]] });
  }

  async function giftCode(order) {
    const o = await db.getOrder(order.code);
    return o && o.gift_code;
  }

  async function sendPlan(cache, order) {
    if (order.type === "two_months") {
      await say(cache, order.customer_chat_id, T.planTwoMonths, { voice: "voice_plan_two_months", attach: ["video_plan_two_months"] });
    } else {
      await say(cache, order.customer_chat_id, T.planYear, { voice: "voice_plan_year", attach: ["video_plan_year"] });
    }
  }

  async function sendWelcome(cache, order) {
    await say(cache, order.customer_chat_id, T.welcome(order.type), {
      voice: "voice_welcome",
      attach: ["video_country", "photo_snap_card"],
      buttons: [[{ text: BTN.problem, data: "c:problem" }]],
    });
  }

  async function stepReminder(cache, order) {
    const f = T.stepReminder[order.status];
    if (order.status === "WAIT_ACTIVATION_DONE") return sendActivation(cache, order);
    await msg.sendText(order.customer_chat_id, f ? f() : T.sendScreenshot);
  }

  /* ---------- تنفيذ قرار ---------- */
  async function apply(cache, order, d, { copyFrom } = {}) {
    const p = {};
    if (d.ctx) p.ctx_merge = d.ctx;
    if (d.ui_language) p.ui_language = d.ui_language;
    if (typeof d.no_balance_retries === "number") p.no_balance_retries = d.no_balance_retries;
    if (Object.keys(p).length) await patch(order, p);
    await db.log(order.id, order.customer_chat_id, "decision", { action: d.action, reason: d.reason });

    const chat = order.customer_chat_id;
    const pv = await problemVoice(cache, d.action);
    switch (d.action) {
      case "human":
        return handoff(cache, order, d.reason, { customerText: d.customerText, copyFrom });
      case "accept_snap":
        return sendLinkFlow(cache, order);
      case "resend_country":
        return say(cache, chat, T.countryNotChanged, { voice: "voice_country", attach: ["video_country"] });
      case "where_to_shoot":
        return say(cache, chat, T.whereToShoot, { voice: "voice_snap_screenshot", attach: ["photo_snap_card"] });
      case "clearer":
        return msg.sendText(chat, T.clearerPhoto);
      case "continue_problem":
        return say(cache, chat, T.pContinue(await giftCode(order)), { voice: pv });
      case "redeem_screen":
        return say(cache, chat, T.pRedeemScreen, { voice: pv });
      case "balance_shown":
        return say(cache, chat, T.pBalanceShown, { voice: pv });
      case "balance_ok_retry":
        await msg.sendText(chat, T.pBalanceOkRetry);
        return sendActivation(cache, order);
      case "resend_activation":
        return sendActivation(cache, order);
      case "no_balance_retry":
        return say(cache, chat, T.pNoBalanceRetry(await giftCode(order)), { voice: pv });
      case "ask_balance_shot":
        return say(cache, chat, T.pAskBalanceShot, { voice: pv });
      case "restart_phone":
        return say(cache, chat, T.pRestartPhone, { voice: pv });
      case "ask_country_shot":
        return say(cache, chat, T.pAskCountryShot, { voice: pv });
      case "no_subscriptions":
        return say(cache, chat, T.pNoSubscriptions, { voice: pv });
      case "activated":
        if (order.type === "month") return finish(cache, order, false);
        await patch(order, { status: "WAIT_PLAN_CHANGE" });
        return sendPlan(cache, order);
      case "resend_plan":
        if (order.status === "WAIT_PLAN_CHANGE") await patch(order, { status: "WAIT_CONFIRM_SCREENSHOT" });
        return sendPlan(cache, order);
      case "wrong_12month":
        if (order.status === "WAIT_PLAN_CHANGE") await patch(order, { status: "WAIT_CONFIRM_SCREENSHOT" });
        return say(cache, chat, T.wrong12Month, { voice: pv });
      case "confirm_ok":
        return finish(cache, order, true);
      case "step_reminder":
        return stepReminder(cache, order);
      case "send_screenshot":
        return msg.sendText(chat, T.sendScreenshot);
      default:
        report(new Error(`unknown action ${d.action}`));
        return msg.sendText(chat, T.sendScreenshot);
    }
  }

  async function finish(cache, order, congrats) {
    await patch(order, { status: "DONE" });
    if (congrats) await msg.sendText(order.customer_chat_id, T.congrats);
    await say(cache, order.customer_chat_id, finalText(order.type), { voice: FINAL_VOICE[order.type] });
    await db.log(order.id, order.customer_chat_id, "done", {});
  }

  /* ---------- الصور ---------- */
  async function handlePhoto(cache, order, inc, review) {
    if (order.status === "DONE") return handoff(cache, order, "صورة بعد ما كمل الطلب", { copyFrom: inc });
    let analysis;
    try {
      const file = await msg.downloadFile(inc.fileId);
      analysis = await ai.analyzeScreenshot({ bytes: file.bytes, mime: file.mime || inc.mime, order });
    } catch (e) {
      report(e);
      return handoff(cache, order, "ما قدرتش نقرا الصورة (خطأ تقني)", { copyFrom: inc });
    }
    await db.log(order.id, order.customer_chat_id, "screenshot", { analysis });
    const d = F.decideImage(order, analysis);
    await patch(order, { ctx_merge: { last_analysis: analysis } });

    // وضع المراجعة: مالك يأكد قبل ما يتنفذ القرار
    if (review && d.action !== "human") {
      await patch(order, { ctx_merge: { review_pending: { decision: d, photo: { chatId: inc.chatId, messageId: inc.messageId } } } });
      await msg.sendText(order.customer_chat_id, T.reviewWait);
      const summary =
        `🔎 مراجعة ${order.code} · ${TYPE_LABEL[order.type]} · ${order.status}\n` +
        `قرار الـAI: ${d.action}${d.reason ? ` (${d.reason})` : ""}\n` +
        `الصفحة: ${analysis.page_type} · العملة: ${analysis.currency} · تجربة: ${analysis.has_free_trial ? "إيه" : "لا"}` +
        (analysis.plan_price_inr != null ? ` · السعر: ₹${analysis.plan_price_inr}` : "") +
        (analysis.balance_inr != null ? ` · الرصيد: ₹${analysis.balance_inr}` : "") +
        (analysis.upcoming_plan_change ? " · Upcoming Plan Change" : "") +
        ` · الثقة: ${Math.round(Number(analysis.confidence || 0) * 100)}%`;
      return notifyAdmins(order, summary, {
        copyFrom: inc,
        buttons: [[{ text: BTN.accept, data: `a:accept:${order.code}` }, { text: BTN.reject, data: `a:reject:${order.code}` }]],
      });
    }
    return apply(cache, order, d, { copyFrom: inc });
  }

  /* ---------- النص ---------- */
  async function handleText(cache, order, text) {
    let r;
    try {
      r = await ai.interpretText({ text, order, problems: await cache.problems(), lastAnalysis: (order.ctx || {}).last_analysis });
    } catch (e) {
      report(e);
      r = { intent: "unclear", reply: "" };
    }
    await db.log(order.id, order.customer_chat_id, "intent", { intent: r.intent });
    const d = F.decideText(order, r.intent);
    if (d.action === "answer") return msg.sendText(order.customer_chat_id, r.reply || T.sendScreenshot);
    return apply(cache, order, d);
  }

  /* ---------- الكليان ---------- */
  async function handleCustomer(inc) {
    const cache = requestCache();
    const isMedia = ["photo", "voice", "video", "document"].includes(inc.kind);
    const touch = await db.touchChat(platform, inc.chatId, isMedia);
    if (inc.kind === "callback") await msg.answerCallback(inc.callbackId);
    if (touch.blocked) return;
    if (!touch.allowed) {
      if (touch.warn) await msg.sendText(inc.chatId, T.rateLimited);
      return;
    }
    let order = touch.order;

    // كلمة السر: ما تتسجلش، تتمسح، ونقولو ما يبعثهاش
    if ((inc.kind === "text" || inc.kind === "photo") && inc.text && F.looksLikePassword(inc.text)) {
      await msg.deleteMessage(inc.chatId, inc.messageId);
      await db.log(order && order.id, inc.chatId, "password_redacted", {});
      return msg.sendText(inc.chatId, T.password);
    }

    await db.log(order && order.id, inc.chatId, "in", {
      kind: inc.kind,
      text: inc.kind === "text" ? String(inc.text).slice(0, 500) : undefined,
      data: inc.callbackData,
    });

    // كود طلب (ولا /start JN-1234)
    const code = inc.kind === "text" ? F.extractOrderCode(inc.text) : null;
    if (code && !(order && order.code === code)) {
      const r = await db.claimCode(platform, inc.chatId, code);
      if (r.result === "blocked") return;
      if (r.result === "invalid") return msg.sendText(inc.chatId, T.badCode);
      order = r.order;
      if (r.result === "ok") return sendWelcome(cache, order);
      // resumed: يكمل من وين وقف
      if (order.status === "HUMAN") return msg.sendText(inc.chatId, T.handoff);
      if (order.status === "DONE") return msg.sendText(inc.chatId, T.done);
      return stepReminder(cache, order);
    }

    if (!order) return msg.sendText(inc.chatId, T.askCode);
    if (inc.kind === "text" && /^\/start\b/.test(inc.text)) return stepReminder(cache, order);

    // مالك عندو المحادثة: البوت يسكت، والميساجات توصل لمالك
    if (order.status === "HUMAN") {
      if (inc.kind === "callback") return;
      await notifyAdmins(order, `💬 ${order.code}:`, { copyFrom: inc });
      return;
    }

    if ((order.ctx || {}).review_pending) return msg.sendText(inc.chatId, T.stillReviewing);

    switch (inc.kind) {
      case "callback":
        if (inc.messageId && inc.callbackData === "c:activated") await msg.clearButtons(inc.chatId, inc.messageId);
        if (inc.callbackData === "c:problem") return msg.sendText(inc.chatId, T.problemPrompt);
        if (inc.callbackData === "c:activated") {
          if (order.status === "WAIT_ACTIVATION_DONE" || order.status === "LINK_SENT") {
            return apply(cache, order, { action: "activated" });
          }
          return stepReminder(cache, order);
        }
        return;
      case "photo":
        return handlePhoto(cache, order, inc, touch.review_mode === "on");
      case "voice":
        return handleVoice(cache, order, inc);
      case "text":
        return handleText(cache, order, inc.text);
      default:
        return msg.sendText(inc.chatId, T.sendScreenshot);
    }
  }

  /* ---------- الفوكال (10.1) ---------- */
  async function handleVoice(cache, order, inc) {
    if (inc.duration && inc.duration > 60) {
      return handoff(cache, order, "فوكال طويل (أكثر من دقيقة)", { copyFrom: inc });
    }
    let text = "";
    try {
      const file = await msg.downloadFile(inc.fileId);
      text = await ai.transcribe({ bytes: file.bytes, mime: file.mime || inc.mime, ext: file.ext });
    } catch (e) {
      report(e);
    }
    const letters = text.replace(/[^\p{L}]/gu, "");
    if (letters.length < 4) return msg.sendText(inc.chatId, T.voiceUnclear);
    await db.log(order.id, inc.chatId, "voice_text", { length: text.length });
    if (F.looksLikePassword(text)) return msg.sendText(inc.chatId, T.password);
    return handleText(cache, order, text);
  }

  /* ============================================================
     الأدمين
     ============================================================ */
  async function takeOrder(adminChat, code) {
    const order = await db.getOrder(code);
    if (!order) return msg.sendText(adminChat, `ما لقيتش ${code}`);
    if (!order.customer_chat_id) return msg.sendText(adminChat, `${order.code} مازال ما تستعملش.`);
    if (order.status !== "HUMAN") {
      await db.updateOrder(order.id, { status: "HUMAN", resume_status: order.status, human_reason: "مالك خذا المحادثة" });
    }
    await db.log(order.id, null, "take", { by: adminChat });
    const id = await msg.sendText(adminChat,
      `✅ ${order.code} عندك. رد (reply) على هذا الميساج ولا على أي ميساج تاع ${order.code} باش يوصل للكليان.\n/release ${order.code} باش ترجعو للبوت.`);
    await db.adminMsgAdd(adminChat, id, order.id);
  }

  async function releaseOrder(adminChat, code) {
    const cache = requestCache();
    let order = await db.getOrder(code);
    if (!order) return msg.sendText(adminChat, `ما لقيتش ${code}`);
    if (order.status !== "HUMAN") return msg.sendText(adminChat, `${order.code} راهو عند البوت ديجا (${order.status}).`);
    const back = order.resume_status || (order.customer_chat_id ? "WAIT_SNAP_SCREENSHOT" : "WAIT_CODE");
    order = (await db.updateOrder(order.id, { status: back, resume_status: null, human_reason: null,
                                               ctx_merge: { review_pending: null } })).order;
    await db.log(order.id, null, "release", { by: adminChat, to: back });
    await msg.sendText(adminChat, `↩️ ${order.code} رجع للبوت في ${back}.`);
    if (!order.customer_chat_id) return;
    await msg.sendText(order.customer_chat_id, T.resume);
    // صورة Snap+ تقبلت والستوك كان فارغ: نكملو الرابط مباشرة
    if (back === "WAIT_SNAP_SCREENSHOT" && (order.ctx || {}).snap_ok) return sendLinkFlow(cache, order);
    if (back === "DONE") return;
    return stepReminder(cache, order);
  }

  async function reviewDecision(adminChat, code, accept) {
    const cache = requestCache();
    const order = await db.getOrder(code);
    // واحد برك يربح إذا زوج أدمين ضغطو في نفس الوقت
    const r = order && (await db.takeReview(order.id));
    if (!r) return msg.sendText(adminChat, `${code}: تقرر ديجا.`);
    const { pending, order: o } = r;
    await db.log(o.id, null, "review", { accept, action: pending.decision.action, by: adminChat });
    if (accept) {
      await msg.sendText(adminChat, `✅ ${code}: ${pending.decision.action}`);
      return apply(cache, o, pending.decision, { copyFrom: pending.photo });
    }
    await msg.sendText(adminChat, `❌ ${code}: المحادثة عندك دروك. رد على ميساجات ${code} باش تهدر معاه.`);
    return handoff(cache, o, "مالك رفض قرار الصورة", { alert: false });
  }

  async function handleAdminCallback(inc) {
    const [, verb, code] = inc.callbackData.split(":");
    await msg.answerCallback(inc.callbackId);
    if (inc.messageId && (verb === "accept" || verb === "reject")) await msg.clearButtons(inc.chatId, inc.messageId);
    if (verb === "take") return takeOrder(inc.chatId, code);
    if (verb === "release") return releaseOrder(inc.chatId, code);
    if (verb === "accept") return reviewDecision(inc.chatId, code, true);
    if (verb === "reject") return reviewDecision(inc.chatId, code, false);
  }

  /** رد مالك على ميساج تاع طلب -> يتبعث للكليان. */
  async function relayAdminReply(inc) {
    const order = await db.adminMsgOrder(inc.chatId, inc.replyTo);
    if (!order) return false;
    if (order.status !== "HUMAN") {
      await msg.sendText(inc.chatId, `${order.code} راهو عند البوت. اضغط [${BTN.take}] ولا /take ${order.code} الأول.`);
      return true;
    }
    await msg.copyMessage(order.customer_chat_id, inc.chatId, inc.messageId);
    await db.log(order.id, order.customer_chat_id, "admin_reply", { kind: inc.kind });
    return true;
  }

  const HELP =
    "أوامر بوت التفعيل:\n" +
    "/new month | 2months | year — كود طلب جديد\n" +
    "/order JN-1234 — وين وصل الطلب\n" +
    "/orders — الطلبات المفتوحة\n" +
    "/take JN-1234 · /release JN-1234\n" +
    "/review on|off — وضع المراجعة\n" +
    `/media <slot> — كـ caption على فيديو/صورة (${MEDIA_SLOTS.join(", ")})\n` +
    "/voice <slot> — رد على فوكال (voice_welcome, voice_link, … voice_problem_<id>)\n" +
    "/voicemode <slot> text|voice|both\n" +
    "/problem العنوان | الأعراض | الحل [| يحول بعد كم مرة]\n" +
    "/problems · /delproblem <id>\n" +
    "/stock — أكواد الرصيد المتوفرة\n" +
    "/giftamount <منتج> <مدّة> <₹> — مدّة من بوت المخزون كرصيد بالروبية";

  async function handleAdminCommand(inc, cmd, args) {
    const chat = inc.chatId;
    switch (cmd) {
      case "new": {
        const type = F.parseOrderType(args[0]);
        if (!type) return msg.sendText(chat, "استعمل: /new month | 2months | year");
        const o = await db.newOrder(type, String(inc.userId));
        const link = deps.botUsername ? `\nhttps://t.me/${deps.botUsername}?start=${o.code}` : "";
        return msg.sendText(chat, `🆕 ${o.code} · سناب بلس ${TYPE_LABEL[type]}\nيموت بعد 48 ساعة إذا ما تستعملش.${link}`);
      }
      case "order": {
        const o = args[0] && (await db.getOrder(args[0]));
        if (!o) return msg.sendText(chat, "ما لقيتش هذا الطلب.");
        const ctx = o.ctx || {};
        return msg.sendText(chat,
          `📦 ${o.code} · ${TYPE_LABEL[o.type]}\n` +
          `الحالة: ${o.status}${o.status === "HUMAN" ? ` (يرجع لـ ${o.resume_status})` : ""}\n` +
          (o.human_reason ? `السبب: ${o.human_reason}\n` : "") +
          `الكليان: ${o.customer_chat_id ? "مربوط" : "مازال"}\n` +
          `رصيد: ${o.gift_amount_inr ? `₹${o.gift_amount_inr}` : "مازال"} · ما كاينش رصيد: ${o.no_balance_retries}\n` +
          (ctx.review_pending ? "⏳ يستنى مراجعتك\n" : "") +
          `تحديث: ${String(o.updated_at).slice(0, 16).replace("T", " ")}`);
      }
      case "orders": {
        const list = (await db.openOrders()) || [];
        if (!list.length) return msg.sendText(chat, "ما كاين حتى طلب مفتوح ✅");
        const lines = list.slice(0, 40).map((o) =>
          `${o.status === "HUMAN" ? "🔴" : (o.ctx || {}).review_pending ? "🟡" : "⚪"} ${o.code} · ${TYPE_LABEL[o.type]} · ${o.status}` +
          (o.status === "HUMAN" && o.human_reason ? ` — ${o.human_reason}` : ""));
        return msg.sendText(chat, lines.join("\n"));
      }
      case "media": {
        const slot = args[0];
        if (!MEDIA_SLOTS.includes(slot)) return msg.sendText(chat, `الخانات: ${MEDIA_SLOTS.join(", ")}`);
        const kind = inc.kind === "photo" || inc.kind === "video" ? inc.kind : inc.replyToKind;
        const fileId = inc.kind === "photo" || inc.kind === "video" ? inc.fileId : inc.replyToFileId;
        if (!fileId || !["photo", "video"].includes(kind)) return msg.sendText(chat, "ابعث /media <slot> كـ caption على فيديو ولا صورة (ولا رد عليهم).");
        await db.mediaSet(platform, slot, kind, fileId);
        return msg.sendText(chat, `✅ ${slot} تحفظ (${kind}).`);
      }
      case "voice": {
        const slot = args[0];
        if (!slot || !isVoiceSlot(slot)) return msg.sendText(chat, `الخانات: ${VOICE_SLOTS.join(", ")}, voice_problem_<id>`);
        const fileId = inc.kind === "voice" ? inc.fileId : inc.replyToKind === "voice" ? inc.replyToFileId : null;
        if (!fileId) return msg.sendText(chat, "رد على فوكال بـ /voice <slot>.");
        await db.mediaSet(platform, slot, "voice", fileId);
        return msg.sendText(chat, `✅ ${slot} تحفظ. يتبعث مع النص (both) — بدلها بـ /voicemode.`);
      }
      case "voicemode": {
        const [slot, mode] = args;
        if (!slot || !isVoiceSlot(slot) || !["text", "voice", "both"].includes(mode)) {
          return msg.sendText(chat, "استعمل: /voicemode <slot> text|voice|both");
        }
        await db.voiceModeSet(platform, slot, mode);
        return msg.sendText(chat, `✅ ${slot}: ${mode}`);
      }
      case "problem": {
        const parts = args.join(" ").split("|").map((s) => s.trim());
        if (parts.length < 3 || !parts[0] || !parts[2]) {
          return msg.sendText(chat, "استعمل: /problem العنوان | الأعراض | الحل [| يحول بعد كم مرة]");
        }
        const esc = parts[3] && /^\d+$/.test(parts[3]) ? Number(parts[3]) : null;
        const p = await db.problemAdd(parts[0], parts[1], parts[2], [], esc);
        return msg.sendText(chat, `✅ المشكل #${p.id} تزاد: ${p.title}\nفوكال: /voice voice_problem_${p.id}`);
      }
      case "problems": {
        const list = (await db.problems()) || [];
        return msg.sendText(chat, list.map((p) => `#${p.id} ${p.title}${p.key ? "" : " (مزاد)"}`).join("\n") || "فارغ");
      }
      case "delproblem": {
        const ok = await db.problemDel(Number(args[0]));
        return msg.sendText(chat, ok ? "✅ تنحى." : "ما لقيتوش (المشاكل الأصلية ما تتنحاش).");
      }
      case "take":
        if (!args[0]) return msg.sendText(chat, "استعمل: /take JN-1234");
        return takeOrder(chat, args[0]);
      case "release":
        if (!args[0]) return msg.sendText(chat, "استعمل: /release JN-1234");
        return releaseOrder(chat, args[0]);
      case "review": {
        const v = (args[0] || "").toLowerCase();
        if (!["on", "off"].includes(v)) return msg.sendText(chat, "استعمل: /review on|off");
        await db.setReview(v === "on");
        return msg.sendText(chat, v === "on" ? "🟡 وضع المراجعة شاعل: كل صورة تستنى قرارك." : "🟢 وضع المراجعة طافي: البوت يقرر وحدو.");
      }
      case "stock": {
        const s = (await db.giftStock()) || [];
        if (!s.length) return msg.sendText(chat, "ما كاين حتى مدّة بمبلغ. استعمل /giftamount.");
        return msg.sendText(chat, "أكواد الرصيد:\n" + s.map((x) => `₹${x.amount_inr}: ${x.available}`).join("\n"));
      }
      case "giftamount": {
        const [product, variant, amount] = args;
        if (!product || !variant || !/^\d+$/.test(amount || "")) {
          return msg.sendText(chat, "استعمل: /giftamount <رمز المنتج> <رمز المدّة> <المبلغ ₹>");
        }
        try {
          const r = await db.setGiftAmount(product, variant, Number(amount));
          return msg.sendText(chat, `✅ ${r.variant} = ₹${r.amount_inr}`);
        } catch {
          return msg.sendText(chat, "ما لقيتش هذي المدّة في بوت المخزون.");
        }
      }
      default:
        return msg.sendText(chat, HELP);
    }
  }

  async function handleAdmin(inc) {
    if (inc.kind === "callback" && inc.callbackData.startsWith("a:")) {
      await handleAdminCallback(inc);
      return true;
    }
    const m = /^\/([a-z]+)(?:@\w+)?(?:\s+([\s\S]*))?$/i.exec((inc.text || "").trim());
    if (m && ADMIN_COMMANDS.has(m[1].toLowerCase())) {
      const args = (m[2] || "").trim().split(/\s+/).filter(Boolean);
      // /problem يحتاج النص كامل بالفواصل
      const cmd = m[1].toLowerCase();
      await handleAdminCommand(inc, cmd, cmd === "problem" ? [(m[2] || "").trim()] : args);
      return true;
    }
    if (inc.replyTo && !(m && m[1])) return relayAdminReply(inc);
    return false;
  }

  /* ---------- المدخل ---------- */
  async function handleUpdate(raw) {
    const inc = msg.parseUpdate(raw);
    if (!inc || !inc.chatId) return;
    if (!(await db.seenUpdate(platform, inc.updateId))) return;

    if (isAdmin(inc)) {
      // مالك يقدر يجرب البوت كليان بحسابو: كل شي ماشي أمر ولا رد يمشي لمسار الكليان
      if (await handleAdmin(inc)) return;
    } else if (inc.kind === "callback" && inc.callbackData.startsWith("a:")) {
      return msg.answerCallback(inc.callbackId);
    } else if (inc.kind === "text") {
      const m = /^\/([a-z]+)/i.exec(inc.text.trim());
      if (m && ADMIN_COMMANDS.has(m[1].toLowerCase())) {
        await db.log(null, inc.chatId, "admin_cmd_denied", { cmd: m[1] });
        return;
      }
    }
    if (!inc.isPrivate) return;
    return handleCustomer(inc);
  }

  return { handleUpdate };
}

module.exports = { createHandler, MEDIA_SLOTS, VOICE_SLOTS };
