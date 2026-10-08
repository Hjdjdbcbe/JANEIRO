/* ============================================================
   قرارات بوت التفعيل (flow.js) — بلا قاعدة وبلا شبكة.

     node tests/local/activation-flow.test.js

   جدول القسم 8 حالة بحالة: نفس JSON الـAI يعطي نفس القرار ديما.
   ============================================================ */
const F = require("../../lib/activation-bot/flow");
const { T } = require("../../lib/activation-bot/texts");

let passed = 0;
function eq(got, want, msg) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (ok) { passed++; console.log(`\x1b[32mPASS  ${msg}\x1b[0m`); }
  else { console.log(`\x1b[31mFAIL: ${msg}\n  got  ${JSON.stringify(got)}\n  want ${JSON.stringify(want)}\x1b[0m`); process.exitCode = 1; }
}

const shot = (o = {}) => ({
  page_type: "snap_plus_offer", currency: "INR", has_free_trial: true, already_subscribed: false,
  upcoming_plan_change: false, plan_price_inr: null, balance_inr: null, country_shown: null,
  has_continue_button: false, ui_language: "fr", confidence: 0.9, ...o,
});
const ord = (type, status, o = {}) => ({ type, status, ctx: {}, no_balance_retries: 0, ...o });
const act = (d) => d.action + (d.reason ? `:${d.reason}` : "");

// 8.1
const snap = (type, a, ctx = {}) => act(F.decideSnap(ord(type, "WAIT_SNAP_SCREENSHOT", { ctx }), shot(a)));
eq(snap("month", { has_free_trial: false }), "accept_snap", "month + ₹ without trial → accepted");
eq(snap("month", {}), "accept_snap", "month + ₹ with trial → accepted");
eq(snap("two_months", {}), "accept_snap", "two months + ₹ + trial → accepted");
eq(snap("year", {}), "accept_snap", "year + ₹ + trial → accepted");
eq(snap("two_months", { has_free_trial: false }), "human:ما كاينش تجربة مجانية", "two months without trial → owner");
eq(snap("year", { has_free_trial: false }), "human:ما كاينش تجربة مجانية", "year without trial → owner");
eq(snap("month", { currency: "DZD" }), "resend_country", "price in DZD → country video");
eq(snap("month", { currency: "EUR" }), "resend_country", "price in EUR → country video");
eq(snap("month", { page_type: "other", currency: "none" }), "where_to_shoot", "other page → where to shoot");
eq(snap("month", { page_type: "other" }, { snap_other: 2 }), "human:الصورة ما تطابق حتى حالة", "third wrong page → owner");
eq(snap("month", { already_subscribed: true }), "human:عندو اشتراك شاعل ديجا", "already subscribed → owner");
eq(snap("month", { confidence: 0.3 }), "clearer", "low confidence → ask a clearer one");
eq(snap("month", { confidence: 0.3 }, { snap_unclear: 1 }), "human:صورة مش واضحة مرتين", "low confidence twice → owner");
eq(snap("month", { confidence: undefined }), "clearer", "missing confidence counts as low");
eq(F.decideSnap(ord("month", "WAIT_SNAP_SCREENSHOT"), shot({ ui_language: "en" })).ui_language, "en", "phone language is kept for the button names");

// 8.2
const conf = (type, a, ctx = {}) => act(F.decideConfirm(ord(type, "WAIT_CONFIRM_SCREENSHOT", { ctx }), shot({ page_type: "appstore_subscriptions", ...a })));
eq(conf("two_months", { upcoming_plan_change: true, plan_price_inr: 49 }), "confirm_ok", "two months: Upcoming Plan Change ₹49 → done");
eq(conf("year", { upcoming_plan_change: true, plan_price_inr: 199 }), "confirm_ok", "year: Upcoming Plan Change ₹199 → done");
eq(conf("year", { upcoming_plan_change: true, plan_price_inr: 299 }), "wrong_12month", "year ₹299 → pick Annual");
eq(conf("year", { upcoming_plan_change: true, plan_price_inr: 299 }, { confirm_wrong: 1 }), "human:اختار 12-Month بدل Annual مرتين", "₹299 twice → owner");
eq(conf("two_months", { upcoming_plan_change: false, plan_price_inr: 99 }), "resend_plan", "no plan change → plan step again once");
eq(conf("two_months", { upcoming_plan_change: false }, { confirm_wrong: 1 }), "human:صورة التأكيد غالطة مرتين", "wrong twice → owner");
eq(conf("two_months", { upcoming_plan_change: true, plan_price_inr: 199 }), "resend_plan", "two months with ₹199 is wrong");
eq(conf("two_months", { page_type: "appstore_account" }), "no_subscriptions", "account page → how to find Subscriptions");

// القسم 9 وقت التفعيل
const actImg = (type, a, ctx = {}) => act(F.decideActivationImage(ord(type, "WAIT_ACTIVATION_DONE", { ctx }), shot(a)));
eq(actImg("month", { page_type: "other", currency: "none", has_continue_button: true }), "continue_problem", "Continue screen → same link again");
eq(actImg("month", { page_type: "redeem_screen", currency: "none" }), "redeem_screen", "black Redeem screen → normal");
eq(actImg("month", { page_type: "appstore_account", balance_inr: 120 }), "balance_shown", "balance visible and enough → go activate");
eq(actImg("year", { page_type: "appstore_account", balance_inr: 120 }), "human:الرصيد ناقص", "balance below ₹199 for a year → owner");
eq(actImg("two_months", { page_type: "appstore_account", balance_inr: 98 }, { awaiting: "balance" }), "balance_ok_retry", "requested balance ≥ ₹98 → activation again");
eq(actImg("two_months", { page_type: "appstore_account", balance_inr: 98 }, { awaiting: "balance", balance_ok_retried: true }), "human:الرصيد يكفي والتفعيل ما مشاش", "enough balance but still failing → owner");
eq(actImg("month", { page_type: "appstore_account", balance_inr: 0 }, { awaiting: "balance" }), "human:الرصيد ناقص", "balance 0 → owner");
eq(actImg("month", { page_type: "appstore_account", country_shown: "Algérie" }, { awaiting: "country" }), "resend_country", "store says Algeria → country video");
eq(actImg("month", { page_type: "appstore_account", country_shown: "India" }, { awaiting: "country" }), "human:البلاد India والمشكل باقي", "store says India and still failing → owner");
eq(actImg("month", { currency: "DZD" }), "restart_phone", "Snap+ in dinars while activating → restart the phone");
eq(actImg("month", { page_type: "other", currency: "none" }), "human:الصورة ما تطابق حتى حالة", "unknown screenshot → owner");
eq(actImg("month", { already_subscribed: true }), "activated", "screenshot showing it is active counts as activated");

// المشكل 5 و 6 بالكتابة
const txt = (type, intent, o = {}) => act(F.decideText(ord(type, "WAIT_ACTIVATION_DONE", o), intent));
eq(txt("month", "no_balance"), "no_balance_retry", "no balance #1 → same link");
eq(txt("month", "no_balance", { no_balance_retries: 1 }), "no_balance_retry", "no balance #2 → same link");
eq(txt("month", "no_balance", { no_balance_retries: 2 }), "ask_balance_shot", "no balance #3 → balance screenshot");
eq(txt("month", "wrong_store"), "restart_phone", "Algerian store #1 → restart");
eq(txt("month", "wrong_store", { ctx: { restart_done: true } }), "ask_country_shot", "Algerian store #2 → account screenshot");
eq(txt("month", "money"), "human:سؤال على الدراهم", "money → owner");
eq(txt("month", "wants_human"), "human:الكليان طلب إنسان", "asks for a human → owner");
eq(txt("month", "unclear"), "send_screenshot", "unclear → send me a screenshot");
eq(txt("month", "question"), "answer", "question → free answer");

// النصوص
eq(T.activation("two_months", "en", true).includes("Start Free Trial"), true, "English phone → Start Free Trial");
eq(T.activation("month", "fr", false).includes("الزر الأصفر لتحت"), true, "month without trial → yellow button wording");
eq(T.activation("month", "fr", true).includes("💬"), false, "month: nothing appended");
eq(T.activation("year", "ar", true).includes("اشتراك عام"), true, "year tail appended");
eq(T.link("AB CD").endsWith("code=AB%20CD"), true, "gift code is URL-encoded in the link");

// الكود وكلمة السر
eq(F.extractOrderCode("salam jn 4821 svp"), "JN-4821", "order code found inside a message, any case");
eq(F.extractOrderCode("/start JN-4821"), "JN-4821", "deep-link /start payload");
eq(F.parseOrderType("2months"), "two_months", "/new 2months");
eq(["Ahmed@2024", "mdp: Ahmed2024x", "kifach ndir mot de passe?", "JN-1234", "iphone 13", "salam"].map(F.looksLikePassword),
   [true, true, false, false, false, false], "password detection");

console.log(`\x1b[32m===== activation flow: ${passed} checks passed =====\x1b[0m`);
