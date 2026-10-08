/* ============================================================
   الـAI (Gemini) — بلا شبكة: fetch وهمي يرجع ردود Gemini.

     node tests/local/activation-ai.test.js

   يتأكد من شكل الطلب (الموديل، JSON schema، temperature، الصورة
   والفوكال inline)، من حساب المصروف، ومن الحد اليومي.
   ============================================================ */
const { createAi, BudgetError } = require("../../lib/activation-bot/ai");

let passed = 0;
function assert(cond, msg) {
  if (cond) { passed++; console.log(`\x1b[32mPASS  ${msg}\x1b[0m`); }
  else { console.log(`\x1b[31mFAIL: ${msg}\x1b[0m`); process.exitCode = 1; throw new Error(msg); }
}

let calls = [];
let reply;
const fetchImpl = async (url, init) => {
  calls.push({ url, headers: init.headers, body: JSON.parse(init.body) });
  return new Response(JSON.stringify(reply), { status: reply.error ? 400 : 200 });
};
let spent = 0;
const added = [];
const db = { aiSpendToday: async () => spent, aiSpendAdd: async (u) => { added.push(u); spent += u; return spent; } };
const env = { GEMINI_API_KEY: "k", AI_MODEL: "gemini-3.8-flash", AI_DAILY_BUDGET_USD: "1" };
const ai = createAi({ db, env, fetchImpl });
const gemini = (obj, usage, extraParts = []) => ({
  candidates: [{ finishReason: "STOP", content: { parts: [...extraParts, { text: JSON.stringify(obj) }] } }],
  usageMetadata: usage,
});

(async () => {
  const shot = { page_type: "snap_plus_offer", currency: "INR", has_free_trial: true, already_subscribed: false,
    upcoming_plan_change: false, plan_price_inr: null, balance_inr: null, country_shown: null,
    has_continue_button: false, ui_language: "fr", confidence: 0.9 };
  reply = gemini(shot, { promptTokenCount: 1000, candidatesTokenCount: 100, thoughtsTokenCount: 100 },
                 [{ thought: true, text: "thinking…" }]);
  const a = await ai.analyzeScreenshot({ bytes: Buffer.from("img"), mime: "image/png", order: { type: "month", status: "WAIT_SNAP_SCREENSHOT" } });
  const c = calls[0];
  assert(a.page_type === "snap_plus_offer", "screenshot JSON parsed (thought parts skipped)");
  assert(c.url.endsWith("/models/gemini-3.8-flash:generateContent") && c.headers["x-goog-api-key"] === "k", "model from AI_MODEL, key in header");
  assert(c.body.generationConfig.responseMimeType === "application/json" && c.body.generationConfig.responseJsonSchema.required.length === 11,
    "JSON output constrained by the section-8 schema");
  assert(c.body.generationConfig.temperature <= 0.2, "low temperature for screenshots");
  assert(c.body.contents[0].parts[0].inlineData.mimeType === "image/png", "image sent inline");
  assert(Math.abs(added[0] - (1000 * 0.75 + 200 * 3.75) / 1e6) < 1e-12, "cost = input + (output + thinking) at the configured prices");

  calls = [];
  reply = gemini({ transcript: "ما لقيتش subscriptions", intent: "no_subscriptions", reply: "" },
    { promptTokenCount: 2000, promptTokensDetails: [{ modality: "AUDIO", tokenCount: 1920 }, { modality: "TEXT", tokenCount: 80 }], candidatesTokenCount: 20 });
  const v = await ai.interpretVoice({ bytes: Buffer.from("ogg"), mime: "audio/ogg; codecs=opus", order: { type: "year", status: "WAIT_PLAN_CHANGE" } });
  assert(v.intent === "no_subscriptions" && v.transcript.includes("subscriptions"), "voice: transcript + intent in one call (no separate STT)");
  assert(Math.round(v.seconds) === 60, "voice length measured from audio tokens (32/s)");
  assert(calls[0].body.contents[0].parts[1].inlineData.mimeType === "audio/ogg", "audio sent inline, codec suffix stripped");
  assert(Math.abs(added[1] - (80 * 0.75 + 1920 * 1.5 + 20 * 3.75) / 1e6) < 1e-12, "audio tokens priced separately");

  reply = gemini({ intent: "dance", reply: "  hi  " }, { promptTokenCount: 10, candidatesTokenCount: 5 });
  const t = await ai.interpretText({ text: "x", order: { type: "month", status: "WAIT_ACTIVATION_DONE" }, problems: [] });
  assert(t.intent === "unclear" && t.reply === "hi", "unknown intent falls back to unclear");

  spent = 1;
  calls = [];
  let e;
  try { await ai.interpretText({ text: "x", order: { type: "month", status: "DONE" } }); } catch (x) { e = x; }
  assert(e instanceof BudgetError && e.budget && calls.length === 0, "daily budget reached → BudgetError before any call");

  spent = 0;
  reply = { error: { message: "quota" } };
  try { await ai.interpretText({ text: "x", order: { type: "month", status: "DONE" } }); e = null; } catch (x) { e = x; }
  assert(e && /gemini 400/.test(e.message), "API errors surface (the handler hands over to the owner)");

  console.log(`\x1b[32m===== activation AI: ${passed} checks passed =====\x1b[0m`);
})().catch((e) => { console.error(e); process.exitCode = 1; });
