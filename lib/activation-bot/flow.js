/* ============================================================
   القرارات — دوال صافية بلا شبكة ولا قاعدة.

   الـAI يرجع JSON (قراية الصورة، نية الميساج)، وهنا الكود هو لي
   يقرر واش يصرا. كل دالة ترجع قرار { action, ... } والـhandler
   هو لي ينفذو. القرار يتخزن كما هو في وضع المراجعة، فلازم يبقى
   JSON عادي.
   ============================================================ */

const MIN_CONFIDENCE = 0.6;

const REQUIRED_INR = { month: 99, two_months: 98, year: 199 };
const PLAN_PRICE = { two_months: 49, year: 199 };

const STATES = [
  "WAIT_CODE", "WAIT_SNAP_SCREENSHOT", "LINK_SENT", "WAIT_ACTIVATION_DONE",
  "WAIT_PLAN_CHANGE", "WAIT_CONFIRM_SCREENSHOT", "DONE", "HUMAN",
];

const human = (reason, extra = {}) => ({ action: "human", reason, ...extra });
const ctxOf = (order) => order.ctx || {};
const n = (v) => (typeof v === "number" && Number.isFinite(v) ? v : 0);

/** صورة مش واضحة: مرة وحدة نطلب أوضح، الثانية لمالك. */
function unclear(order, counter) {
  if (n(ctxOf(order)[counter]) >= 1) return human("صورة مش واضحة مرتين");
  return { action: "clearer", ctx: { [counter]: n(ctxOf(order)[counter]) + 1 } };
}

const isInr = (a) => a.currency === "INR";
const isForeignCurrency = (a) => a.currency && a.currency !== "INR" && a.currency !== "none";

/* ---------- 8.1 صورة Snap+ ---------- */
function decideSnap(order, a) {
  const ctx = ctxOf(order);
  if (!(n(a.confidence) >= MIN_CONFIDENCE)) return unclear(order, "snap_unclear");
  if (a.already_subscribed) return human("عندو اشتراك شاعل ديجا");

  if (a.page_type === "snap_plus_offer") {
    if (isInr(a)) {
      if (order.type === "month" || a.has_free_trial === true) {
        return {
          action: "accept_snap",
          ctx: { snap_ok: true, has_free_trial: a.has_free_trial === true },
          ui_language: a.ui_language || null,
        };
      }
      return human("ما كاينش تجربة مجانية", { customerText: "holdOn" });
    }
    if (isForeignCurrency(a)) return { action: "resend_country" };
  }

  // صفحة أخرى: نعاود "من وين يصور"، وبعد مرتين لمالك
  if (n(ctx.snap_other) >= 2) return human("الصورة ما تطابق حتى حالة");
  return { action: "where_to_shoot", ctx: { snap_other: n(ctx.snap_other) + 1 } };
}

const isAlgeria = (s) => /alg[eé]r|الجزائر/i.test(s || "");
const isIndia = (s) => /india|\binde\b|الهند/i.test(s || "");

/* ---------- صور وقت التفعيل (ملف المشاكل) ---------- */
function decideActivationImage(order, a) {
  const ctx = ctxOf(order);
  const need = REQUIRED_INR[order.type];
  if (!(n(a.confidence) >= MIN_CONFIDENCE)) return unclear(order, "act_unclear");

  // صورة الرصيد لي طلبناها بعد مرتين "ما كاينش رصيد" (المشكل 5)
  if (ctx.awaiting === "balance") {
    if (typeof a.balance_inr !== "number") return unclear(order, "act_unclear");
    if (a.balance_inr < need) return human("الرصيد ناقص", { ctx: { awaiting: null } });
    if (ctx.balance_ok_retried) return human("الرصيد يكفي والتفعيل ما مشاش", { ctx: { awaiting: null } });
    return { action: "balance_ok_retry", ctx: { awaiting: null, balance_ok_retried: true } };
  }

  // صورة البلاد لي طلبناها في المشكل 6
  if (ctx.awaiting === "country") {
    if (isAlgeria(a.country_shown)) return { action: "resend_country", ctx: { awaiting: null, restart_done: false } };
    if (isIndia(a.country_shown)) return human("البلاد India والمشكل باقي", { ctx: { awaiting: null } });
    return unclear(order, "act_unclear");
  }

  if (a.has_continue_button) return { action: "continue_problem" };
  if (a.page_type === "redeem_screen") return { action: "redeem_screen" };
  if (a.already_subscribed) return { action: "activated" };

  if (typeof a.balance_inr === "number") {
    if (a.balance_inr >= need) return { action: "balance_shown" };
    return human("الرصيد ناقص");
  }

  if (a.page_type === "snap_plus_offer") {
    if (isForeignCurrency(a)) return decideWrongStore(order);
    if (isInr(a)) return { action: "resend_activation" };
  }

  return human("الصورة ما تطابق حتى حالة");
}

/* ---------- 8.2 صورة التأكيد (شهرين وسنة) ---------- */
function decideConfirm(order, a) {
  const ctx = ctxOf(order);
  if (!(n(a.confidence) >= MIN_CONFIDENCE)) return unclear(order, "confirm_unclear");

  const expected = PLAN_PRICE[order.type];
  const wrongOnce = n(ctx.confirm_wrong) >= 1;
  const counted = { confirm_wrong: n(ctx.confirm_wrong) + 1 };

  if (a.page_type === "appstore_subscriptions" || a.upcoming_plan_change) {
    if (a.upcoming_plan_change && a.plan_price_inr === expected) return { action: "confirm_ok" };
    if (order.type === "year" && a.plan_price_inr === 299) {
      if (wrongOnce) return human("اختار 12-Month بدل Annual مرتين");
      return { action: "wrong_12month", ctx: counted };
    }
    if (wrongOnce) return human("صورة التأكيد غالطة مرتين");
    return { action: "resend_plan", ctx: counted };
  }

  // صفحة الحساب بلا Subscriptions: المشكل 1، بلا ما نحسبوها غلطة
  if (a.page_type === "appstore_account") return { action: "no_subscriptions" };

  if (wrongOnce) return human("صورة التأكيد غالطة مرتين");
  return { action: "resend_plan", ctx: counted };
}

function decideImage(order, a) {
  switch (order.status) {
    case "WAIT_SNAP_SCREENSHOT": return decideSnap(order, a);
    case "LINK_SENT":
    case "WAIT_ACTIVATION_DONE": return decideActivationImage(order, a);
    case "WAIT_PLAN_CHANGE":
    case "WAIT_CONFIRM_SCREENSHOT": return decideConfirm(order, a);
    default: return human("صورة بعد ما كمل الطلب");
  }
}

/* ---------- المشكل 5: ما كاينش رصيد ---------- */
function decideNoBalance(order) {
  const tries = n(order.no_balance_retries);
  if (tries < 2) return { action: "no_balance_retry", no_balance_retries: tries + 1 };
  if (ctxOf(order).awaiting === "balance") return { action: "ask_balance_shot" };
  return { action: "ask_balance_shot", ctx: { awaiting: "balance" } };
}

/* ---------- المشكل 6: الستور الجزائري ---------- */
function decideWrongStore(order) {
  if (!ctxOf(order).restart_done) return { action: "restart_phone", ctx: { restart_done: true } };
  return { action: "ask_country_shot", ctx: { awaiting: "country" } };
}

/* ---------- الميساجات المكتوبة (بعد ما الـAI يعطي النية) ---------- */
const INTENTS = [
  "activated", "no_balance", "wrong_store", "no_subscriptions", "redeem_screen",
  "continue_button", "wrong_12month", "wants_human", "money", "question", "unclear",
];

function decideText(order, intent) {
  if (intent === "wants_human") return human("الكليان طلب إنسان");
  if (intent === "money") return human("سؤال على الدراهم", { customerText: "money" });

  const s = order.status;
  if (s === "WAIT_ACTIVATION_DONE" || s === "LINK_SENT") {
    switch (intent) {
      case "activated": return { action: "activated" };
      case "no_balance": return decideNoBalance(order);
      case "wrong_store": return decideWrongStore(order);
      case "no_subscriptions": return { action: "no_subscriptions" };
      case "redeem_screen": return { action: "redeem_screen" };
      case "continue_button": return { action: "continue_problem" };
    }
  }
  if (s === "WAIT_PLAN_CHANGE" || s === "WAIT_CONFIRM_SCREENSHOT") {
    switch (intent) {
      case "no_subscriptions": return { action: "no_subscriptions" };
      case "wrong_12month": return { action: "resend_plan" };
      case "activated": return { action: "step_reminder" };
    }
  }
  if (s === "WAIT_SNAP_SCREENSHOT" && intent === "activated") return { action: "step_reminder" };

  if (intent === "question") return { action: "answer" };
  return { action: "send_screenshot" };
}

/* ---------- كلمة السر في الشات ---------- */
const PASS_WORDS = /(mot\s*de\s*pa?sse|password|\bmdp\b|\bpass\b|كلمة\s*(السر|المرور|السرية)|مودباس|موديباس|المودباس|باسورد|الباسوورد)/i;

function looksLikePassword(text) {
  const t = String(text || "").trim();
  if (!t) return false;
  // كلمة "mot de passe" وحدها سؤال، مش كلمة سر. لازم يكون معاها شي حاجة تشبهها
  if (PASS_WORDS.test(t)) {
    const rest = t.replace(PASS_WORDS, " ").trim();
    return rest.split(/\s+/).some((w) => w.length >= 6 && /\d/.test(w) && /[A-Za-z]/.test(w));
  }
  // كلمة وحدة فيها حروف وأرقام ورمز: هذي باينة كلمة سر
  if (/\s/.test(t) || t.length < 6 || t.length > 64) return false;
  if (/^JN-?\d+$/i.test(t) || /^https?:/i.test(t) || /@.+\./.test(t)) return false;
  return /[A-Za-z]/.test(t) && /\d/.test(t) && /[^A-Za-z0-9]/.test(t);
}

/* ---------- كود الطلب ---------- */
const CODE_RE = /\bJN[\s-]?(\d{4,6})\b/i;
function extractOrderCode(text) {
  const m = CODE_RE.exec(String(text || ""));
  return m ? `JN-${m[1]}` : null;
}

function parseOrderType(s) {
  const v = String(s || "").toLowerCase().replace(/[\s_-]/g, "");
  if (["month", "1month", "شهر"].includes(v)) return "month";
  if (["2months", "twomonths", "2month", "شهرين"].includes(v)) return "two_months";
  if (["year", "1year", "annual", "سنة", "عام"].includes(v)) return "year";
  return null;
}

module.exports = {
  MIN_CONFIDENCE, REQUIRED_INR, PLAN_PRICE, STATES, INTENTS,
  decideSnap, decideActivationImage, decideConfirm, decideImage,
  decideText, decideNoBalance, decideWrongStore,
  looksLikePassword, extractOrderCode, parseOrderType,
};
