/* ============================================================
   بوت تفعيل Snapchat+ — المنطق.

   زوج قنوات:
     - الكليان: WhatsApp (رقم المتجر، مشترك مع مالك). تيليغرام يبقى
       قناة احتياط للكليان (نفس الكود يكمل في أي قناة).
     - الأدمين: Telegram برك — الأوامر، التنبيهات، المراجعة، الفوكالات.

   المنطق ما يعرفش واتساب ولا تيليغرام: يتعامل مع ميساج موحّد من
   adapters/ ويقرر بـflow.js.

   deps = { channels: {whatsapp?, telegram?}, admin, db, storage, ai,
            adminIds, storeWhatsapp?, log? }
   ============================================================ */

const { T, BTN, TYPE_LABEL, finalText } = require("./texts");
const F = require("./flow");

const MEDIA_SLOTS = ["video_country", "photo_snap_card", "video_plan_two_months", "video_plan_year"];
const VOICE_SLOTS = [
  "voice_welcome", "voice_country", "voice_snap_screenshot", "voice_link", "voice_activation",
  "voice_plan_two_months", "voice_plan_year", "voice_final_month", "voice_final_two_months", "voice_final_year",
];
const isVoiceSlot = (s) => VOICE_SLOTS.includes(s) || /^voice_problem_\d+$/.test(s);

const SLOT_LABEL = {
  voice_welcome: "الترحيب", voice_country: "تبديل البلاد", voice_snap_screenshot: "صورة سناب",
  voice_link: "الرابط", voice_activation: "التفعيل", voice_plan_two_months: "خطة الشهرين",
  voice_plan_year: "خطة السنة", voice_final_month: "الأخير · شهر", voice_final_two_months: "الأخير · شهرين",
  voice_final_year: "الأخير · سنة",
  video_country: "فيديو البلاد", photo_snap_card: "صورة البطاقة",
  video_plan_two_months: "فيديو خطة الشهرين", video_plan_year: "فيديو خطة السنة",
};
const MODE_LABEL = { voice: "فوكال برك", text: "نص برك", both: "الاثنين" };

// قرار -> مشكل في الملف (للفوكال voice_problem_<id>)
const ACTION_PROBLEM = {
  no_subscriptions: "no_subscriptions", redeem_screen: "redeem_screen", continue_problem: "continue_button",
  balance_shown: "balance_shown", no_balance_retry: "no_balance", ask_balance_shot: "no_balance",
  restart_phone: "wrong_store", ask_country_shot: "wrong_store", wrong_12month: "wrong_annual_plan",
};

const FINAL_VOICE = { month: "voice_final_month", two_months: "voice_final_two_months", year: "voice_final_year" };
const TERMINAL = new Set(["DONE", "CLOSED"]);
const MEDIA_MAX_AGE_MS = 29 * 24 * 3600 * 1000; // media_id تاع واتساب يعيش 30 يوم

const ADMIN_COMMANDS = new Set([
  "new", "order", "orders", "media", "voice", "voices", "voicemode", "problem", "problems", "delproblem",
  "take", "release", "stop", "review", "stock", "giftamount", "help", "start",
]);

function createHandler(deps) {
  const { channels, db, ai, storage } = deps;
  const admin = deps.admin;
  const adminIds = new Set([...(deps.adminIds || [])].map(String));
  const report = deps.log || ((e) => console.error("[activation-bot]", e));

  const isAdmin = (inc) => inc.platform === "telegram" && adminIds.has(String(inc.userId)) && inc.isPrivate !== false;
  const chOf = (order) => channels[order.platform];
  const isOpen = (order) => !!order && !TERMINAL.has(order.status);

  /* ---------- كاش لكل update ---------- */
  function requestCache() {
    const media = {};
    let problems;
    return {
      media: async (platform) => (media[platform] ??= (await db.mediaAll(platform)) || {}),
      problems: async () => (problems ??= (await db.problems()) || []),
    };
  }

  /* ============================================================
     الميديا: Storage هي الأصل، واتساب ياخذ media_id يموت بعد 30 يوم
     ============================================================ */
  async function reupload(ch, slot, row) {
    const file = await storage.download(row.storage_path);
    const mime = row.mime || file.mime;
    const id = await ch.uploadMedia(file.bytes, mime, row.storage_path.split("/").pop());
    await db.mediaSet(ch.platform, slot, row.kind, id, row.storage_path, mime);
    row.file_id = id;
    row.updated_at = new Date().toISOString();
    await db.log(null, null, "media_reuploaded", { slot, platform: ch.platform }).catch(() => {});
    return id;
  }

  async function sendSlot(ch, chatId, slot, row) {
    const canReupload = ch.uploadMedia && row.storage_path;
    if (canReupload && row.updated_at && Date.now() - Date.parse(row.updated_at) > MEDIA_MAX_AGE_MS) {
      await reupload(ch, slot, row);
    }
    try {
      return await ch.sendMedia(chatId, row.kind, row.file_id);
    } catch (e) {
      if (!canReupload || (ch.isMediaError && !ch.isMediaError(e))) throw e;
      await reupload(ch, slot, row);
      return ch.sendMedia(chatId, row.kind, row.file_id);
    }
  }

  /* ---------- البعث للكليان، مع الفوكال والمرفقات ---------- */
  async function say(cache, order, text, { buttons, voice, attach = [] } = {}) {
    const ch = chOf(order);
    const chatId = order.customer_chat_id;
    const media = await cache.media(order.platform);
    const v = voice && media[voice];
    const hasVoice = v && v.kind === "voice" && v.file_id;
    const mode = (v && v.voice_mode) || (hasVoice ? "both" : "text");
    // الأزرار والروابط لازمهم نص، حتى في وضع "voice"
    const needsText = !hasVoice || mode !== "voice" || (buttons && buttons.length) || /https?:\/\//.test(text || "");

    if (text && needsText) await ch.sendText(chatId, text, { buttons });
    for (const slot of attach) {
      const m = media[slot];
      if (m && m.file_id && m.kind) await sendSlot(ch, chatId, slot, m);
      else await db.log(order.id, chatId, "media_missing", { slot }).catch(() => {});
    }
    if (hasVoice && mode !== "text") await sendSlot(ch, chatId, voice, v);
  }

  const sendTo = (order, text, opts) => chOf(order).sendText(order.customer_chat_id, text, opts);

  async function problemVoice(cache, action) {
    const key = ACTION_PROBLEM[action];
    if (!key) return undefined;
    const p = (await cache.problems()).find((x) => x.key === key);
    return p ? `voice_problem_${p.id}` : undefined;
  }

  /** واتساب: ما نقدروش نبعثو برّا نافذة 24 ساعة بلا template. */
  function canReach(order) {
    if (order.platform !== "whatsapp") return true;
    return !!order.window_expires_at && Date.parse(order.window_expires_at) > Date.now();
  }

  async function patch(order, p) {
    const r = await db.updateOrder(order.id, p);
    Object.assign(order, r.order);
    return order;
  }

  /* ============================================================
     التنبيهات لمالك (تيليغرام)
     ============================================================ */
  function header(order, extra) {
    const step = order.status === "HUMAN" && order.resume_status ? order.resume_status : order.status;
    return `🔔 ${order.code} · ${TYPE_LABEL[order.type]} · ${step}` + (extra ? `\n${extra}` : "");
  }

  const handoffButtons = (order) => [[
    { text: BTN.release, data: `a:release:${order.code}` },
    { text: BTN.close, data: `a:close:${order.code}` },
  ]];

  /** ينقل ميساج الكليان (صورة، فوكال، نص) لمالك. file: إذا تنزّل ديجا. */
  async function forward(adminChat, order, inc, file) {
    if (!inc) return null;
    if (inc.platform === "telegram") return admin.copyMessage(adminChat, inc.chatId, inc.messageId);
    if (inc.kind === "text") return admin.sendText(adminChat, `💬 ${inc.text}`);
    if (!["photo", "voice", "video"].includes(inc.kind) || !inc.fileId) return null;
    const f = file || (await channels[inc.platform].downloadFile(inc.fileId));
    return admin.sendFile(adminChat, inc.kind, f.bytes, f.mime || inc.mime);
  }

  async function notifyAdmins(order, text, { forwardInc, file, buttons } = {}) {
    if (!admin) return;
    for (const a of adminIds) {
      try {
        const id = await admin.sendText(a, text, { buttons });
        if (order) await db.adminMsgAdd(a, id, order.id);
        const fid = await forward(a, order, forwardInc, file);
        if (fid && order) await db.adminMsgAdd(a, fid, order.id);
      } catch (e) { report(e); }
    }
  }

  /** تحويل لمالك: البوت يسكت (HUMAN) ويرجع لنفس الحالة بعد /release. */
  async function handoff(cache, order, reason, { customerText = "handoff", forwardInc, file, alert = true, urgent = false } = {}) {
    if (order.status !== "HUMAN") {
      await patch(order, { status: "HUMAN", resume_status: order.status, human_reason: reason });
    } else {
      await patch(order, { human_reason: reason });
    }
    await db.log(order.id, order.customer_chat_id, "handoff", { reason });
    if (customerText) {
      const text = { handoff: T.handoff, holdOn: T.holdOn, money: `${T.moneyQuestion} ${T.handoff}`, justAMinute: T.justAMinute }[customerText] || T.handoff;
      if (canReach(order)) await sendTo(order, text);
    }
    if (alert) {
      const how = order.platform === "whatsapp" ? "\nجاوبو من تطبيق واتساب بزنس، ومن بعد [رجع للبوت]." : "";
      await notifyAdmins(order, (urgent ? "🚨 عاجل\n" : "") + header(order, `السبب: ${reason}`) + how,
        { forwardInc, file, buttons: handoffButtons(order) });
    }
  }

  /** الـAI وقف (الميزانية ولا خطأ): لمالك، ماشي للكليان. */
  async function aiFailed(cache, order, e, inc, file) {
    if (e && e.budget) {
      const first = await db.aiBudgetAlert().catch(() => true);
      return handoff(cache, order, "الميزانية اليومية تاع الـAI وصلت", { forwardInc: inc, file, urgent: first });
    }
    report(e);
    return handoff(cache, order, "الـAI ما خدمش (خطأ تقني)", { forwardInc: inc, file });
  }

  /* ============================================================
     المسار (القسم 7)
     ============================================================ */
  async function sendLinkFlow(cache, order) {
    const gift = await db.assignGift(order.id);
    if (!gift || gift.error) {
      return handoff(cache, order, "الستوك فارغ — ما كاينش كود رصيد يغطي الطلب", { customerText: "justAMinute", urgent: true });
    }
    await patch(order, { status: "LINK_SENT" });
    await say(cache, order, T.link(gift.code), { voice: "voice_link" });
    await sendActivation(cache, order);
    await patch(order, { status: "WAIT_ACTIVATION_DONE" });
    await db.log(order.id, order.customer_chat_id, "link_sent", { amount_inr: gift.amount_inr, reused: !!gift.reused });
  }

  async function sendActivation(cache, order) {
    const ctx = order.ctx || {};
    await say(cache, order, T.activation(order.type, order.ui_language || "fr", ctx.has_free_trial), {
      voice: "voice_activation",
      buttons: [[{ text: BTN.activated, data: "c:activated" }, { text: BTN.problem, data: "c:problem" }]],
    });
  }

  async function giftCode(order) {
    const o = await db.getOrder(order.code);
    return o && o.gift_code;
  }

  async function sendPlan(cache, order) {
    if (order.type === "two_months") {
      await say(cache, order, T.planTwoMonths, { voice: "voice_plan_two_months", attach: ["video_plan_two_months"] });
    } else {
      await say(cache, order, T.planYear, { voice: "voice_plan_year", attach: ["video_plan_year"] });
    }
  }

  async function sendWelcome(cache, order) {
    await say(cache, order, T.welcome(order.type), {
      voice: "voice_welcome",
      attach: ["video_country", "photo_snap_card"],
      buttons: [[{ text: BTN.problem, data: "c:problem" }]],
    });
  }

  async function stepReminder(cache, order) {
    if (order.status === "WAIT_ACTIVATION_DONE" || order.status === "LINK_SENT") return sendActivation(cache, order);
    const f = T.stepReminder[order.status];
    await sendTo(order, f ? f() : T.sendScreenshot);
  }

  async function finish(cache, order, congrats) {
    await patch(order, { status: "DONE" });
    if (congrats) await sendTo(order, T.congrats);
    await say(cache, order, finalText(order.type), { voice: FINAL_VOICE[order.type] });
    await db.log(order.id, order.customer_chat_id, "done", {});
  }

  /* ---------- تنفيذ قرار ---------- */
  async function apply(cache, order, d, { forwardInc, file } = {}) {
    const p = {};
    if (d.ctx) p.ctx_merge = d.ctx;
    if (d.ui_language) p.ui_language = d.ui_language;
    if (typeof d.no_balance_retries === "number") p.no_balance_retries = d.no_balance_retries;
    if (Object.keys(p).length) await patch(order, p);
    await db.log(order.id, order.customer_chat_id, "decision", { action: d.action, reason: d.reason });

    const pv = await problemVoice(cache, d.action);
    switch (d.action) {
      case "human":
        return handoff(cache, order, d.reason, { customerText: d.customerText, forwardInc, file });
      case "accept_snap":
        return sendLinkFlow(cache, order);
      case "resend_country":
        return say(cache, order, T.countryNotChanged, { voice: "voice_country", attach: ["video_country"] });
      case "where_to_shoot":
        return say(cache, order, T.whereToShoot, { voice: "voice_snap_screenshot", attach: ["photo_snap_card"] });
      case "clearer":
        return sendTo(order, T.clearerPhoto);
      case "continue_problem":
        return say(cache, order, T.pContinue(await giftCode(order)), { voice: pv });
      case "redeem_screen":
        return say(cache, order, T.pRedeemScreen, { voice: pv });
      case "balance_shown":
        return say(cache, order, T.pBalanceShown, { voice: pv });
      case "balance_ok_retry":
        await sendTo(order, T.pBalanceOkRetry);
        return sendActivation(cache, order);
      case "resend_activation":
        return sendActivation(cache, order);
      case "no_balance_retry":
        return say(cache, order, T.pNoBalanceRetry(await giftCode(order)), { voice: pv });
      case "ask_balance_shot":
        return say(cache, order, T.pAskBalanceShot, { voice: pv });
      case "restart_phone":
        return say(cache, order, T.pRestartPhone, { voice: pv });
      case "ask_country_shot":
        return say(cache, order, T.pAskCountryShot, { voice: pv });
      case "no_subscriptions":
        return say(cache, order, T.pNoSubscriptions, { voice: pv });
      case "activated":
        if (order.type === "month") return finish(cache, order, false);
        await patch(order, { status: "WAIT_PLAN_CHANGE" });
        return sendPlan(cache, order);
      case "resend_plan":
        if (order.status === "WAIT_PLAN_CHANGE") await patch(order, { status: "WAIT_CONFIRM_SCREENSHOT" });
        return sendPlan(cache, order);
      case "wrong_12month":
        if (order.status === "WAIT_PLAN_CHANGE") await patch(order, { status: "WAIT_CONFIRM_SCREENSHOT" });
        return say(cache, order, T.wrong12Month, { voice: pv });
      case "confirm_ok":
        return finish(cache, order, true);
      case "step_reminder":
        return stepReminder(cache, order);
      case "send_screenshot":
        return sendTo(order, T.sendScreenshot);
      default:
        report(new Error(`unknown action ${d.action}`));
        return sendTo(order, T.sendScreenshot);
    }
  }

  /* ---------- الصور ---------- */
  async function handlePhoto(cache, order, inc, review) {
    let analysis, file;
    try {
      file = await channels[inc.platform].downloadFile(inc.fileId);
      analysis = await ai.analyzeScreenshot({ bytes: file.bytes, mime: file.mime || inc.mime, order });
    } catch (e) {
      return aiFailed(cache, order, e, inc, file);
    }
    await db.log(order.id, order.customer_chat_id, "screenshot", { analysis });
    const d = F.decideImage(order, analysis);
    await patch(order, { ctx_merge: { last_analysis: analysis } });

    // وضع المراجعة: مالك يأكد قبل ما يتنفذ القرار
    if (review && d.action !== "human") {
      await patch(order, { ctx_merge: { review_pending: { decision: d } } });
      await sendTo(order, T.reviewWait);
      const summary =
        `🔎 مراجعة ${order.code} · ${TYPE_LABEL[order.type]} · ${order.status}\n` +
        `قرار الـAI: ${d.action}${d.reason ? ` (${d.reason})` : ""}\n` +
        `الصفحة: ${analysis.page_type} · العملة: ${analysis.currency} · تجربة: ${analysis.has_free_trial ? "إيه" : "لا"}` +
        (analysis.plan_price_inr != null ? ` · السعر: ₹${analysis.plan_price_inr}` : "") +
        (analysis.balance_inr != null ? ` · الرصيد: ₹${analysis.balance_inr}` : "") +
        (analysis.upcoming_plan_change ? " · Upcoming Plan Change" : "") +
        ` · الثقة: ${Math.round(Number(analysis.confidence || 0) * 100)}%`;
      return notifyAdmins(order, summary, {
        forwardInc: inc, file,
        buttons: [[{ text: BTN.accept, data: `a:accept:${order.code}` }, { text: BTN.reject, data: `a:reject:${order.code}` }]],
      });
    }
    return apply(cache, order, d, { forwardInc: inc, file });
  }

  /* ---------- النص ---------- */
  async function handleText(cache, order, text, inc) {
    let r;
    try {
      r = await ai.interpretText({ text, order, problems: await cache.problems(), lastAnalysis: (order.ctx || {}).last_analysis });
    } catch (e) {
      if (e && e.budget) return aiFailed(cache, order, e, inc);
      report(e);
      r = { intent: "unclear", reply: "" };
    }
    return actOnIntent(cache, order, r);
  }

  async function actOnIntent(cache, order, r) {
    await db.log(order.id, order.customer_chat_id, "intent", { intent: r.intent });
    const d = F.decideText(order, r.intent);
    if (d.action === "answer") return sendTo(order, r.reply || T.sendScreenshot);
    return apply(cache, order, d);
  }

  /* ---------- الفوكال (10.1): نفس الموديل يسمع ويفهم ---------- */
  async function handleVoice(cache, order, inc) {
    let r, file;
    try {
      file = await channels[inc.platform].downloadFile(inc.fileId);
      if (inc.duration && inc.duration > 60) {
        return handoff(cache, order, "فوكال طويل (أكثر من دقيقة)", { forwardInc: inc, file });
      }
      r = await ai.interpretVoice({
        bytes: file.bytes, mime: file.mime || inc.mime, order,
        problems: await cache.problems(), lastAnalysis: (order.ctx || {}).last_analysis,
      });
    } catch (e) {
      return aiFailed(cache, order, e, inc, file);
    }
    if (r.seconds > 60) return handoff(cache, order, "فوكال طويل (أكثر من دقيقة)", { forwardInc: inc, file });
    const letters = (r.transcript || "").replace(/[^\p{L}]/gu, "");
    if (letters.length < 4) return sendTo(order, T.voiceUnclear);
    await db.log(order.id, inc.chatId, "voice_text", { length: r.transcript.length, intent: r.intent });
    if (F.looksLikePassword(r.transcript)) return sendTo(order, T.password);
    return actOnIntent(cache, order, r);
  }

  /* ============================================================
     الكليان
     ============================================================ */
  async function handleCustomer(ch, inc) {
    const cache = requestCache();
    const isMedia = ["photo", "voice", "video", "document"].includes(inc.kind);
    const touch = await db.touchChat(ch.platform, inc.chatId, isMedia);
    if (inc.kind === "callback") await ch.answerCallback(inc.callbackId);
    let order = touch.order;
    const code = inc.kind === "text" ? F.extractOrderCode(inc.text) : null;
    const open = isOpen(order);

    // الرقم مشترك مع مالك: بلا طلب مفتوح وبلا كود، البوت ما يشوفش حتى (لا سجل، لا AI)
    if (ch.sharedInbox && !open && !code) return;
    if (touch.blocked) return;
    if (!touch.allowed) {
      if (touch.warn) await ch.sendText(inc.chatId, T.rateLimited);
      return;
    }

    // كلمة السر: ما تتسجلش، تتمسح (إذا القناة تسمح)، ونقولو ما يبعثهاش
    if ((inc.kind === "text" || inc.kind === "photo") && inc.text && F.looksLikePassword(inc.text)) {
      await ch.deleteMessage(inc.chatId, inc.messageId);
      await db.log(order && order.id, inc.chatId, "password_redacted", {});
      return ch.sendText(inc.chatId, T.password);
    }

    // كود طلب (ولا /start JN-1234 في تيليغرام)
    if (code && !(order && order.code === code && open)) {
      const r = await db.claimCode(ch.platform, inc.chatId, code);
      await db.log(r.order && r.order.id, inc.chatId, "in", { kind: "code", result: r.result });
      if (r.result === "blocked") return;
      if (r.result === "invalid") return ch.sendText(inc.chatId, T.badCode);
      order = r.order;
      if (r.result === "ok") return sendWelcome(cache, order);
      if (r.result === "moved") {
        await notifyAdmins(order, header(order, `↪️ الكليان كمل من ${ch.platform} (كان في ${r.from}).`));
      }
      if (order.status === "HUMAN") return ch.sharedInbox ? undefined : ch.sendText(inc.chatId, T.handoff);
      if (order.status === "DONE") return ch.sendText(inc.chatId, T.done);
      return stepReminder(cache, order);
    }

    if (!open) {
      if (!order) return ch.sendText(inc.chatId, T.askCode);
      if (order.status === "DONE") return ch.sendText(inc.chatId, T.done);
      return; // CLOSED: ساكت
    }
    if (inc.kind === "text" && /^\/start\b/.test(inc.text)) return stepReminder(cache, order);

    // مالك عندو المحادثة: البوت يسكت. في واتساب مالك يشوف الميساجات في التطبيق
    if (order.status === "HUMAN") {
      if (inc.kind === "callback" || ch.sharedInbox) return;
      await notifyAdmins(order, `💬 ${order.code}:`, { forwardInc: inc });
      return;
    }

    await db.log(order.id, inc.chatId, "in", {
      kind: inc.kind,
      text: inc.kind === "text" ? String(inc.text).slice(0, 500) : undefined,
      data: inc.callbackData,
    });

    if ((order.ctx || {}).review_pending) return sendTo(order, T.stillReviewing);

    switch (inc.kind) {
      case "callback":
        if (inc.messageId && inc.callbackData === "c:activated") await ch.clearButtons(inc.chatId, inc.messageId);
        if (inc.callbackData === "c:problem") return sendTo(order, T.problemPrompt);
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
        return handleText(cache, order, inc.text, inc);
      default:
        return sendTo(order, T.sendScreenshot);
    }
  }

  /* ---------- مالك كتب من تطبيق واتساب بزنس (message echo) ---------- */
  async function handleEcho(ch, inc) {
    if (await db.isSent(ch.platform, inc.messageId)) return; // ميساج تاع البوت
    const order = await db.openOrderFor(ch.platform, inc.chatId);
    if (!order || order.status === "HUMAN") return;
    const o = (await db.updateOrder(order.id, { status: "HUMAN", resume_status: order.status, human_reason: "مالك كتب من التطبيق" })).order;
    await db.log(o.id, inc.chatId, "owner_echo", {});
    await notifyAdmins(o, header(o, "✋ كتبت من التطبيق: البوت سكت في هذي المحادثة."), { buttons: handoffButtons(o) });
  }

  /* ============================================================
     الأدمين (تيليغرام)
     ============================================================ */
  async function releaseOrder(adminChat, code) {
    const cache = requestCache();
    let order = await db.getOrder(code);
    if (!order) return admin.sendText(adminChat, `ما لقيتش ${code}`);
    if (order.status !== "HUMAN") return admin.sendText(adminChat, `${order.code} راهو ${order.status === "CLOSED" ? "مغلوق" : `عند البوت ديجا (${order.status})`}.`);
    const back = order.resume_status || (order.customer_chat_id ? "WAIT_SNAP_SCREENSHOT" : "WAIT_CODE");
    order = (await db.updateOrder(order.id, { status: back, resume_status: null, human_reason: null,
                                               ctx_merge: { review_pending: null } })).order;
    await db.log(order.id, null, "release", { by: adminChat, to: back });
    if (!order.customer_chat_id || back === "DONE") return admin.sendText(adminChat, `↩️ ${order.code} رجع للبوت في ${back}.`);
    if (!canReach(order)) {
      return admin.sendText(adminChat,
        `↩️ ${order.code} رجع للبوت في ${back}، بصح نافذة 24 ساعة تاع واتساب سكرت: البوت يكمل كي يبعث الكليان ميساج.`);
    }
    await admin.sendText(adminChat, `↩️ ${order.code} رجع للبوت في ${back}.`);
    await sendTo(order, T.resume);
    // صورة Snap+ تقبلت والستوك كان فارغ: نكملو الرابط مباشرة
    if (back === "WAIT_SNAP_SCREENSHOT" && (order.ctx || {}).snap_ok) return sendLinkFlow(cache, order);
    return stepReminder(cache, order);
  }

  async function takeOrder(adminChat, code) {
    const order = await db.getOrder(code);
    if (!order) return admin.sendText(adminChat, `ما لقيتش ${code}`);
    if (!order.customer_chat_id) return admin.sendText(adminChat, `${order.code} مازال ما تستعملش.`);
    if (!isOpen(order)) return admin.sendText(adminChat, `${order.code} ${order.status}.`);
    if (order.status !== "HUMAN") {
      await db.updateOrder(order.id, { status: "HUMAN", resume_status: order.status, human_reason: "مالك خذا المحادثة" });
    }
    await db.log(order.id, null, "take", { by: adminChat });
    const how = order.platform === "whatsapp"
      ? "جاوبو من تطبيق واتساب بزنس."
      : `رد (reply) على هذا الميساج باش يوصل للكليان.`;
    const id = await admin.sendText(adminChat, `✅ ${order.code} عندك. ${how}`, { buttons: handoffButtons(order) });
    await db.adminMsgAdd(adminChat, id, order.id);
  }

  async function closeOrder(adminChat, code) {
    const o = await db.closeOrder(code, "مالك غلق الطلب");
    return admin.sendText(adminChat, o ? `⛔ ${o.code} تغلق. البوت ما يهدرش في هذي المحادثة.` : `${code}: ما لقيتوش ولا مغلوق ديجا.`);
  }

  async function reviewDecision(adminChat, code, accept) {
    const cache = requestCache();
    const order = await db.getOrder(code);
    // واحد برك يربح إذا زوج أدمين ضغطو في نفس الوقت
    const r = order && (await db.takeReview(order.id));
    if (!r) return admin.sendText(adminChat, `${code}: تقرر ديجا.`);
    const { pending, order: o } = r;
    await db.log(o.id, null, "review", { accept, action: pending.decision.action, by: adminChat });
    if (!accept) {
      await admin.sendText(adminChat, `❌ ${code}: المحادثة عندك دروك.`);
      return handoff(cache, o, "مالك رفض قرار الصورة", { alert: false });
    }
    if (!canReach(o)) {
      await patch(o, { ctx_merge: { review_pending: pending } });
      return admin.sendText(adminChat, `${code}: نافذة 24 ساعة سكرت. القرار يتنفذ كي يبعث الكليان ميساج.`);
    }
    await admin.sendText(adminChat, `✅ ${code}: ${pending.decision.action}`);
    return apply(cache, o, pending.decision);
  }

  /** رد مالك في تيليغرام على ميساج طلب -> للكليان (قناة تيليغرام برك). */
  async function relayAdminReply(inc) {
    const order = await db.adminMsgOrder(inc.chatId, inc.replyTo);
    if (!order) return false;
    if (order.platform !== "telegram") {
      await admin.sendText(inc.chatId, `${order.code} في واتساب: جاوبو من تطبيق واتساب بزنس.`);
      return true;
    }
    if (order.status !== "HUMAN") {
      await admin.sendText(inc.chatId, `${order.code} راهو عند البوت. /take ${order.code} الأول.`);
      return true;
    }
    await admin.copyMessage(order.customer_chat_id, inc.chatId, inc.messageId);
    await db.log(order.id, order.customer_chat_id, "admin_reply", { kind: inc.kind });
    return true;
  }

  /* ---------- حفظ الفوكالات والفيديوهات (10.2) ---------- */
  async function saveMedia(slot, kind, tgFileId, mime, mode) {
    const file = await admin.downloadFile(tgFileId);
    const isVoice = kind === "voice";
    const ext = isVoice ? "ogg" : file.ext === "jpeg" ? "jpg" : file.ext || (kind === "video" ? "mp4" : "jpg");
    const type = isVoice ? "audio/ogg" : file.mime || mime || (kind === "video" ? "video/mp4" : "image/jpeg");
    const path = `media/${slot}.${ext}`;
    await storage.upload(path, file.bytes, type);
    await db.mediaSet("telegram", slot, kind, tgFileId, path, type);
    if (channels.whatsapp) {
      const id = await channels.whatsapp.uploadMedia(file.bytes, type, `${slot}.${ext}`);
      await db.mediaSet("whatsapp", slot, kind, id, path, type);
    }
    if (mode) {
      for (const p of Object.keys(channels)) await db.voiceModeSet(p, slot, mode);
    }
    await db.log(null, null, "media_saved", { slot, kind, mode: mode || null });
  }

  function previewText(slot, problems) {
    const m = /^voice_problem_(\d+)$/.exec(slot);
    if (m) {
      const p = (problems || []).find((x) => String(x.id) === m[1]);
      return p ? p.solution_text : "";
    }
    return {
      voice_welcome: T.welcome("month"), voice_country: T.countryNotChanged, voice_snap_screenshot: T.whereToShoot,
      voice_link: T.link("XXXX-XXXX-XXXX"), voice_activation: T.activation("month", "fr", true),
      voice_plan_two_months: T.planTwoMonths, voice_plan_year: T.planYear,
      voice_final_month: finalText("month"), voice_final_two_months: finalText("two_months"), voice_final_year: finalText("year"),
    }[slot] || "";
  }

  async function slotLabel(slot) {
    const m = /^voice_problem_(\d+)$/.exec(slot);
    if (!m) return SLOT_LABEL[slot] || slot;
    const p = ((await db.problems()) || []).find((x) => String(x.id) === m[1]);
    return `مشكل: ${p ? p.title : m[1]}`;
  }

  /** معاينة كيما يشوفها الكليان (في تيليغرام). */
  async function preview(adminChat, slot) {
    const rows = (await db.mediaAll("telegram")) || {};
    const row = rows[slot];
    const mode = (row && row.voice_mode) || "both";
    if (mode !== "voice") {
      const t = previewText(slot, await db.problems());
      if (t) await admin.sendText(adminChat, t);
    }
    if (row && row.file_id && mode !== "text") await admin.sendMedia(adminChat, row.kind, row.file_id);
  }

  const pairs = (list) => list.reduce((rows, b, i) => (i % 2 ? rows[rows.length - 1].push(b) : rows.push([b]), rows), []);

  async function askSlot(adminChat, inc) {
    const kind = inc.kind;
    const id = await db.draftAdd(adminChat, kind, inc.fileId, inc.mime);
    if (kind === "voice") {
      const buttons = pairs(VOICE_SLOTS.map((s) => ({ text: SLOT_LABEL[s], data: `d:${id}:${s}` })));
      buttons.push([{ text: "مشكل من الملف", data: `d:${id}:pl` }]);
      return admin.sendText(adminChat, "وين تحب تحط هذا الفوكال؟", { buttons });
    }
    const slots = MEDIA_SLOTS.filter((s) => (kind === "photo" ? s.startsWith("photo_") : s.startsWith("video_")));
    return admin.sendText(adminChat, kind === "photo" ? "وين تحب تحط هذي الصورة؟" : "وين تحب تحط هذا الفيديو؟",
      { buttons: pairs(slots.map((s) => ({ text: SLOT_LABEL[s], data: `d:${id}:${s}` }))) });
  }

  async function handleDraftCallback(adminChat, data) {
    const [kindTag, idStr, arg] = data.split(":");
    const id = Number(idStr);
    if (kindTag === "d") {
      if (arg === "pl") {
        const problems = (await db.problems()) || [];
        return admin.sendText(adminChat, "أنا واش من مشكل؟", {
          buttons: problems.map((p) => [{ text: p.title.slice(0, 40), data: `d:${id}:voice_problem_${p.id}` }]),
        });
      }
      const d = await db.draftSetSlot(id, adminChat, arg);
      if (!d) return admin.sendText(adminChat, "هذا الملف تحفظ ولا راح. عاود ابعثو.");
      if (d.kind === "voice") {
        return admin.sendText(adminChat, `${await slotLabel(arg)}: كيفاش يتبعث للكليان؟`, {
          buttons: [["voice", "text", "both"].map((m) => ({ text: MODE_LABEL[m], data: `m:${id}:${m}` }))],
        });
      }
      const taken = await db.draftTake(id, adminChat);
      if (!taken) return admin.sendText(adminChat, "تحفظ ديجا.");
      await saveMedia(arg, taken.kind, taken.tg_file_id, taken.mime);
      await admin.sendText(adminChat, `تحفظ ✅ ${await slotLabel(arg)}`);
      return preview(adminChat, arg);
    }
    if (kindTag === "m") {
      const taken = await db.draftTake(id, adminChat);
      if (!taken || !taken.slot) return admin.sendText(adminChat, "تحفظ ديجا.");
      await saveMedia(taken.slot, "voice", taken.tg_file_id, taken.mime, arg);
      await admin.sendText(adminChat, `تحفظ ✅ ${await slotLabel(taken.slot)} · ${MODE_LABEL[arg]}\nهكذا يشوفها الكليان 👇`);
      return preview(adminChat, taken.slot);
    }
  }

  async function listVoices(adminChat) {
    const rows = ((await db.mediaList()) || []).filter((r) => r.platform === "telegram" && r.kind === "voice" && r.file_id);
    if (!rows.length) return admin.sendText(adminChat, "ما كاين حتى فوكال محفوظ. ابعثلي فوكال وأنا نسقسيك وين نحطو.");
    const buttons = [];
    for (const r of rows) {
      const label = await slotLabel(r.slot);
      buttons.push([
        { text: `▶️ ${label} · ${MODE_LABEL[r.voice_mode || "both"]}`.slice(0, 60), data: `vl:${r.slot}` },
        { text: "🗑", data: `vd:${r.slot}` },
      ]);
    }
    return admin.sendText(adminChat, "الفوكالات المحفوظة:", { buttons });
  }

  async function handleAdminCallback(inc) {
    const data = inc.callbackData;
    await admin.answerCallback(inc.callbackId);
    if (/^[dm]:/.test(data)) {
      if (inc.messageId) await admin.clearButtons(inc.chatId, inc.messageId);
      return handleDraftCallback(inc.chatId, data);
    }
    if (data.startsWith("vl:")) return preview(inc.chatId, data.slice(3));
    if (data.startsWith("vd:")) {
      const slot = data.slice(3);
      const paths = await db.mediaDelete(slot);
      await storage.remove(paths);
      return admin.sendText(inc.chatId, `🗑 ${await slotLabel(slot)} تمسح.`);
    }
    const [, verb, code] = data.split(":");
    if (inc.messageId && ["accept", "reject"].includes(verb)) await admin.clearButtons(inc.chatId, inc.messageId);
    if (verb === "take") return takeOrder(inc.chatId, code);
    if (verb === "release") return releaseOrder(inc.chatId, code);
    if (verb === "close") return closeOrder(inc.chatId, code);
    if (verb === "accept") return reviewDecision(inc.chatId, code, true);
    if (verb === "reject") return reviewDecision(inc.chatId, code, false);
  }

  const HELP =
    "أوامر بوت التفعيل:\n" +
    "/new month | 2months | year — كود طلب جديد + رابط واتساب\n" +
    "/order JN-1234 — وين وصل الطلب\n" +
    "/orders — الطلبات المفتوحة\n" +
    "/take JN-1234 · /release JN-1234 · /stop JN-1234\n" +
    "/review on|off — وضع المراجعة\n" +
    "ابعث فوكال، فيديو ولا صورة: نسقسيك وين نحطو 👌\n" +
    "/voices — الفوكالات المحفوظة\n" +
    `/media <slot> — كـ caption (${MEDIA_SLOTS.join(", ")})\n` +
    "/voice <slot> — رد على فوكال · /voicemode <slot> text|voice|both\n" +
    "/problem العنوان | الأعراض | الحل [| يحول بعد كم مرة]\n" +
    "/problems · /delproblem <id>\n" +
    "/stock · /giftamount <منتج> <مدّة> <₹>";

  async function handleAdminCommand(inc, cmd, args) {
    const chat = inc.chatId;
    switch (cmd) {
      case "new": {
        const type = F.parseOrderType(args[0]);
        if (!type) return admin.sendText(chat, "استعمل: /new month | 2months | year");
        const o = await db.newOrder(type, String(inc.userId));
        const number = deps.storeWhatsapp || String(o.store_whatsapp || "").replace(/\D/g, "");
        await admin.sendText(chat, `🆕 ${o.code} · سناب بلس ${TYPE_LABEL[type]}\nيموت بعد 48 ساعة إذا ما تستعملش. انسخ الرابط 👇`);
        if (!number) return admin.sendText(chat, `${o.code}\n⚠️ رقم واتساب المتجر ما كاينش (WHATSAPP_STORE_NUMBER ولا whatsapp_number في الإعدادات).`);
        // وحدو في ميساج: ضغطة وحدة وينتسخ
        return admin.sendText(chat, `https://wa.me/${number}?text=${o.code}`);
      }
      case "order": {
        const o = args[0] && (await db.getOrder(args[0]));
        if (!o) return admin.sendText(chat, "ما لقيتش هذا الطلب.");
        const ctx = o.ctx || {};
        return admin.sendText(chat,
          `📦 ${o.code} · ${TYPE_LABEL[o.type]}\n` +
          `الحالة: ${o.status}${o.status === "HUMAN" ? ` (يرجع لـ ${o.resume_status})` : ""}\n` +
          (o.human_reason ? `السبب: ${o.human_reason}\n` : "") +
          (o.closed_reason ? `تغلق: ${o.closed_reason}\n` : "") +
          `الكليان: ${o.customer_chat_id ? `${o.platform} ${o.customer_chat_id}` : "مازال"}\n` +
          `رصيد: ${o.gift_amount_inr ? `₹${o.gift_amount_inr}` : "مازال"} · ما كاينش رصيد: ${o.no_balance_retries}\n` +
          (ctx.review_pending ? "⏳ يستنى مراجعتك\n" : "") +
          (o.platform === "whatsapp" ? `نافذة واتساب: ${canReach(o) ? "مفتوحة" : "سكرت"}\n` : "") +
          `تحديث: ${String(o.updated_at).slice(0, 16).replace("T", " ")}`);
      }
      case "orders": {
        const list = (await db.openOrders()) || [];
        if (!list.length) return admin.sendText(chat, "ما كاين حتى طلب مفتوح ✅");
        const lines = list.slice(0, 40).map((o) =>
          `${o.status === "HUMAN" ? "🔴" : (o.ctx || {}).review_pending ? "🟡" : "⚪"} ${o.code} · ${TYPE_LABEL[o.type]} · ${o.status}` +
          (o.status === "HUMAN" && o.human_reason ? ` — ${o.human_reason}` : ""));
        return admin.sendText(chat, lines.join("\n"));
      }
      case "media": {
        const slot = args[0];
        if (!MEDIA_SLOTS.includes(slot)) return admin.sendText(chat, `الخانات: ${MEDIA_SLOTS.join(", ")}`);
        const own = inc.kind === "photo" || inc.kind === "video";
        const kind = own ? inc.kind : inc.replyToKind;
        const fileId = own ? inc.fileId : inc.replyToFileId;
        if (!fileId || !["photo", "video"].includes(kind)) return admin.sendText(chat, "ابعث /media <slot> كـ caption على فيديو ولا صورة (ولا رد عليهم).");
        await saveMedia(slot, kind, fileId, inc.mime);
        return admin.sendText(chat, `✅ ${slot} تحفظ (${kind}).`);
      }
      case "voice": {
        const slot = args[0];
        if (!slot || !isVoiceSlot(slot)) return admin.sendText(chat, `الخانات: ${VOICE_SLOTS.join(", ")}, voice_problem_<id>`);
        const fileId = inc.kind === "voice" ? inc.fileId : inc.replyToKind === "voice" ? inc.replyToFileId : null;
        if (!fileId) return admin.sendText(chat, "رد على فوكال بـ /voice <slot>.");
        await saveMedia(slot, "voice", fileId, "audio/ogg");
        await admin.sendText(chat, `✅ ${slot} تحفظ.`);
        return preview(chat, slot);
      }
      case "voices":
        return listVoices(chat);
      case "voicemode": {
        const [slot, mode] = args;
        if (!slot || !isVoiceSlot(slot) || !["text", "voice", "both"].includes(mode)) {
          return admin.sendText(chat, "استعمل: /voicemode <slot> text|voice|both");
        }
        for (const p of Object.keys(channels)) await db.voiceModeSet(p, slot, mode);
        return admin.sendText(chat, `✅ ${slot}: ${mode}`);
      }
      case "problem": {
        const parts = args.join(" ").split("|").map((s) => s.trim());
        if (parts.length < 3 || !parts[0] || !parts[2]) {
          return admin.sendText(chat, "استعمل: /problem العنوان | الأعراض | الحل [| يحول بعد كم مرة]");
        }
        const esc = parts[3] && /^\d+$/.test(parts[3]) ? Number(parts[3]) : null;
        const p = await db.problemAdd(parts[0], parts[1], parts[2], [], esc);
        return admin.sendText(chat, `✅ المشكل #${p.id} تزاد: ${p.title}\nفوكال: ابعث فوكال واختار «مشكل من الملف».`);
      }
      case "problems": {
        const list = (await db.problems()) || [];
        return admin.sendText(chat, list.map((p) => `#${p.id} ${p.title}${p.key ? "" : " (مزاد)"}`).join("\n") || "فارغ");
      }
      case "delproblem": {
        const ok = await db.problemDel(Number(args[0]));
        return admin.sendText(chat, ok ? "✅ تنحى." : "ما لقيتوش (المشاكل الأصلية ما تتنحاش).");
      }
      case "take":
        if (!args[0]) return admin.sendText(chat, "استعمل: /take JN-1234");
        return takeOrder(chat, args[0]);
      case "release":
        if (!args[0]) return admin.sendText(chat, "استعمل: /release JN-1234");
        return releaseOrder(chat, args[0]);
      case "stop":
        if (!args[0]) return admin.sendText(chat, "استعمل: /stop JN-1234");
        return closeOrder(chat, args[0]);
      case "review": {
        const v = (args[0] || "").toLowerCase();
        if (!["on", "off"].includes(v)) return admin.sendText(chat, "استعمل: /review on|off");
        await db.setReview(v === "on");
        return admin.sendText(chat, v === "on" ? "🟡 وضع المراجعة شاعل: كل صورة تستنى قرارك." : "🟢 وضع المراجعة طافي: البوت يقرر وحدو.");
      }
      case "stock": {
        const s = (await db.giftStock()) || [];
        const spent = Number(await db.aiSpendToday().catch(() => 0));
        if (!s.length) return admin.sendText(chat, "ما كاين حتى مدّة بمبلغ. استعمل /giftamount.");
        return admin.sendText(chat, "أكواد الرصيد:\n" + s.map((x) => `₹${x.amount_inr}: ${x.available}`).join("\n") +
          `\n\nمصروف الـAI اليوم: $${spent.toFixed(2)}`);
      }
      case "giftamount": {
        const [product, variant, amount] = args;
        if (!product || !variant || !/^\d+$/.test(amount || "")) {
          return admin.sendText(chat, "استعمل: /giftamount <رمز المنتج> <رمز المدّة> <المبلغ ₹>");
        }
        try {
          const r = await db.setGiftAmount(product, variant, Number(amount));
          return admin.sendText(chat, `✅ ${r.variant} = ₹${r.amount_inr}`);
        } catch {
          return admin.sendText(chat, "ما لقيتش هذي المدّة في بوت المخزون.");
        }
      }
      default:
        return admin.sendText(chat, HELP);
    }
  }

  async function handleAdmin(inc) {
    if (inc.kind === "callback") return handleAdminCallback(inc);
    const m = /^\/([a-z]+)(?:@\w+)?(?:\s+([\s\S]*))?$/i.exec((inc.text || "").trim());
    if (m && ADMIN_COMMANDS.has(m[1].toLowerCase())) {
      const cmd = m[1].toLowerCase();
      const args = (m[2] || "").trim().split(/\s+/).filter(Boolean);
      // /problem يحتاج النص كامل بالفواصل
      return handleAdminCommand(inc, cmd, cmd === "problem" ? [(m[2] || "").trim()] : args);
    }
    if (inc.replyTo && (await relayAdminReply(inc))) return;
    // فوكال، فيديو ولا صورة بلا أمر: نسقسيو وين نحطوه
    if (["voice", "video", "photo"].includes(inc.kind) && inc.fileId) return askSlot(inc.chatId, inc);
    return admin.sendText(inc.chatId, HELP);
  }

  /* ============================================================
     المدخل
     ============================================================ */
  async function handleIncoming(ch, inc) {
    inc.platform = ch.platform;
    if (!inc.chatId) return;
    if (!(await db.seenUpdate(ch.platform, inc.updateId))) return;
    if (inc.kind === "echo") return handleEcho(ch, inc);
    if (isAdmin(inc)) {
      try {
        return await handleAdmin(inc);
      } catch (e) {
        report(e);
        // مثلا فيديو أكبر من 16MB لواتساب، ولا ملف تيليغرام فوق 20MB
        return admin.sendText(inc.chatId, `⚠️ ما خدمتش: ${String(e.message || e).slice(0, 300)}`).catch(() => {});
      }
    }
    if (ch.platform === "telegram") {
      if (inc.kind === "callback" && inc.callbackData.startsWith("a:")) return ch.answerCallback(inc.callbackId);
      const m = inc.kind === "text" && /^\/([a-z]+)/i.exec(inc.text.trim());
      if (m && ADMIN_COMMANDS.has(m[1].toLowerCase()) && m[1].toLowerCase() !== "start") {
        await db.log(null, inc.chatId, "admin_cmd_denied", { cmd: m[1] });
        return;
      }
    }
    if (!inc.isPrivate) return;
    return handleCustomer(ch, inc);
  }

  /** الطلبات لي ما كملوش في 48 ساعة: تتغلق وتنبيه لمالك. */
  async function sweep() {
    const closed = (await db.sweepStale()) || [];
    for (const o of closed) {
      await notifyAdmins(o, `⏱ ${o.code} · ${TYPE_LABEL[o.type]} تغلق: ما كملش في 48 ساعة.`);
    }
  }

  async function handleWebhook(platform, body) {
    const ch = channels[platform];
    if (!ch) throw new Error(`channel ${platform} not configured`);
    await sweep().catch(report);
    for (const inc of ch.parseUpdates(body)) {
      try { await handleIncoming(ch, inc); } catch (e) { report(e); }
    }
  }

  return { handleWebhook };
}

module.exports = { createHandler, MEDIA_SLOTS, VOICE_SLOTS };
