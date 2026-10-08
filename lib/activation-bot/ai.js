/* ============================================================
   الـAI — موديل واحد (Gemini Flash، الاسم في AI_MODEL) لثلاث حوايج:
     1. قراية السكرينشوت       -> JSON (القسم 8)، الكود يقرر
     2. الفوكال                 -> نص + نية في نفس النداء
     3. الميساج الحر             -> نية (JSON) + جواب قصير

   الموديل يرجع JSON مقيّد بـ schema، وما يقرر حتى حاجة: القرارات
   في flow.js. كل نداء يتحسب بالدولار (usageMetadata × الأسعار)،
   وكي يوصل المصروف AI_DAILY_BUDGET_USD في النهار يرمي BudgetError
   والـhandler يحول لمالك.
   ============================================================ */

const { INTENTS } = require("./flow");
const { TYPE_LABEL } = require("./texts");

class BudgetError extends Error {
  constructor(spent, budget) {
    super(`AI daily budget reached: $${Number(spent).toFixed(2)} / $${budget}`);
    this.budget = true;
  }
}

const nullable = (type) => ({ type: [type, "null"] });

const SCREENSHOT_SCHEMA = {
  type: "object",
  required: [
    "page_type", "currency", "has_free_trial", "already_subscribed", "upcoming_plan_change",
    "plan_price_inr", "balance_inr", "country_shown", "has_continue_button", "ui_language", "confidence",
  ],
  properties: {
    page_type: { type: "string", enum: ["snap_plus_offer", "appstore_subscriptions", "appstore_account", "redeem_screen", "other"] },
    currency: { type: "string", enum: ["INR", "DZD", "EUR", "USD", "other", "none"] },
    has_free_trial: { type: "boolean" },
    already_subscribed: { type: "boolean" },
    upcoming_plan_change: { type: "boolean" },
    plan_price_inr: nullable("number"),
    balance_inr: nullable("number"),
    country_shown: nullable("string"),
    has_continue_button: { type: "boolean" },
    ui_language: { type: "string", enum: ["fr", "en", "ar"] },
    confidence: { type: "number" },
  },
};

const SCREENSHOT_SYSTEM = `You read iPhone screenshots sent by customers who are activating Snapchat+ with Indian App Store credit.
Return ONLY the JSON object the schema asks for. Describe what is visible; do not guess.

page_type:
- "snap_plus_offer": Snapchat's own Snapchat+ purchase page (plans with prices, a yellow/primary button such as "Démarrer l'essai gratuit" / "Start Free Trial" / a price button, optional free-trial wording).
- "appstore_subscriptions": App Store > Account > Subscriptions, or the Snapchat subscription detail inside it (plans, "Upcoming Plan Change", "See All Plans", renewal dates).
- "appstore_account": the App Store account page (name, Apple ID, balance/credit line such as "₹120 credit", "Country/Region") without the subscription detail.
- "redeem_screen": the black/dark "Redeem" screen showing a gift code with a Redeem button.
- "other": anything else.

Fields:
- currency: currency of the prices on the page (₹ or "Rs" = INR, "DA"/"DZD"/"د.ج" = DZD). "none" if no price is visible.
- has_free_trial: true only if a free trial ("essai gratuit", "free trial", "1 week free", "تجربة مجانية") is offered on screen.
- already_subscribed: true if the screen shows Snapchat+ is ALREADY active for this account (e.g. "Subscribed", "Abonné", an active Snapchat+ subscription with a renewal date and no purchase button).
- upcoming_plan_change: true if "Upcoming Plan Change" (or its translation: "Changement de forfait à venir") is visible under Snapchat.
- plan_price_inr: on appstore_subscriptions, the INR price of the plan the customer is switching to / currently selected (e.g. 49, 199, 299); otherwise null.
- balance_inr: the App Store credit balance in INR if visible, otherwise null.
- country_shown: the country/region name if visible (e.g. "India", "Algeria"), otherwise null.
- has_continue_button: true if a blue "Continue"/"Continuer" button is the main action on screen.
- ui_language: language of the phone's interface on the screenshot.
- confidence: 0..1, how sure you are about page_type and the fields that matter for it. Use < 0.6 if the image is blurry, cropped, or not a phone screenshot.`;

const TEXT_SCHEMA = {
  type: "object",
  required: ["intent", "reply"],
  properties: {
    intent: { type: "string", enum: INTENTS },
    reply: { type: "string" },
  },
};

// تعليمات البوت (القسم 11)، كيما كتبها مالك
const ASSISTANT_RULES = `أنت مساعد التفعيل تاع Janeiro Store. خدمتك وحدة: تعاون الكليان يكمل
خطوات تفعيل Snapchat+ لي راه فيها.

اللغة:
- تهدر دارجة جزائرية صافية، قصيرة وواضحة. بلا فصحى وبلا كلام روبوتات.
- تفهم الدارجة بالحروف العربية، بالحروف اللاتينية (3, 7, 9...)، والفرنسية.
- إذا الكليان يكتب بالفرنسية، جاوبو بالفرنسية.
- أسماء الأزرار تقولها بلغة تيليفون الكليان (كيما بانت في صورتو).
- النصوص الثابتة ما تبدلهاش. في الأجوبة الحرة استعمل صيغة تناسب الكليان.

القواعد:
- جاوب من ملف المشاكل ومن خطوات المسار برك. ما تخترعش حلول.
- إذا ما عرفتش، قول: "ابعثلي سكرينشوت نشوف" ولا حول لمالك.
- ميساج واحد قصير في كل رد، وخطوة وحدة.
- ما تهدرش على الأسعار، الدفع، التعويض ولا منتجات أخرى: "هذي يجاوبك عليها مالك."
- ما تطلبش أبدا mot de passe. إذا بعثو الكليان، قولو يمسحو ويدخلو في تيليفونو برك.
- ما تعطيش رابط رصيد من عندك. الرابط يتبعث من النظام برك.
- إذا سقساك "راك إنسان؟" قول الصح: مساعد آلي تاع المتجر، ومالك يدخل وقت الحاجة.

السياق لي يوصلك مع كل ميساج: نوع الطلب، الحالة الحالية، آخر نتيجة صورة،
وملف المشاكل.`;

const INTENT_GUIDE = `رجّع JSON برك: intent و reply.

intent (الكود هو لي يقرر واش يدير بيها):
- activated: الكليان يقول بلي تفعّل / كمل الخطوات / خلاص.
- no_balance: وهو يفعل قالولو ما كاينش رصيد، ولا طلب منو طريقة دفع (carte, moyen de paiement).
- wrong_store: قالولو راك في الستور الجزائري / الحساب مش في الهند / السعر رجع بالدينار.
- no_subscriptions: ما لقاش Subscriptions في App Store.
- redeem_screen: طلعتلو شاشة سوداء فيها كود وزر Redeem.
- continue_button: طلعتلو صفحة فيها زر Continue.
- wrong_12month: اختار 12-Month Plan تاع ₹299.
- wants_human: يحب يهدر مع إنسان / مع مالك.
- money: سؤال على الدراهم، الأسعار، الخلاص، التعويض، ولا منتجات أخرى.
- question: سؤال آخر على الخطوات تقدر تجاوب عليه من الخطوات ولا ملف المشاكل.
- unclear: ما فهمتش واش يحب، ولا ما كاينش جواب في الملف.

reply: جواب قصير (ميساج واحد، خطوة وحدة) بنفس لغة الكليان، يتستعمل برك كي intent = question.
للنيات الأخرى خليه فارغ "".`;

const VOICE_SCHEMA = {
  type: "object",
  required: ["transcript", "intent", "reply"],
  properties: {
    transcript: { type: "string" },
    intent: { type: "string", enum: INTENTS },
    reply: { type: "string" },
  },
};

const VOICE_GUIDE = `الميساج فوكال. الكليان يهدر دارجة جزائرية، ساعات مخلوطة بالفرنسية.
1. transcript: اكتب واش قال بالضبط (بالحروف لي تناسب). إذا ما فهمتش ولا ما كانش كلام، خليه فارغ "".
2. من بعد intent و reply على حساب transcript، بنفس القواعد تاع الميساج المكتوب.`;

// Gemini يحسب الصوت 32 token في الثانية
const AUDIO_TOKENS_PER_SECOND = 32;

function createAi({ db, env = process.env, fetchImpl = fetch } = {}) {
  const apiKey = env.GEMINI_API_KEY;
  const model = env.AI_MODEL || "gemini-3.8-flash";
  const base = (env.AI_BASE_URL || "https://generativelanguage.googleapis.com/v1beta").replace(/\/+$/, "");
  const thinkingLevel = env.AI_THINKING_LEVEL ?? "low";
  const budget = Number(env.AI_DAILY_BUDGET_USD || 5);
  const price = {
    input: Number(env.AI_PRICE_INPUT_PER_M || 0.75),
    audio: Number(env.AI_PRICE_AUDIO_INPUT_PER_M || 1.5),
    output: Number(env.AI_PRICE_OUTPUT_PER_M || 3.75),
  };
  const temp = {
    image: Number(env.AI_IMAGE_TEMPERATURE ?? 0.1),
    text: Number(env.AI_TEXT_TEMPERATURE ?? 0.4),
  };

  function cost(u = {}) {
    const audioIn = (u.promptTokensDetails || [])
      .filter((d) => d.modality === "AUDIO").reduce((n, d) => n + (d.tokenCount || 0), 0);
    const otherIn = Math.max((u.promptTokenCount || 0) - audioIn, 0);
    const out = (u.candidatesTokenCount || 0) + (u.thoughtsTokenCount || 0);
    return { usd: (otherIn * price.input + audioIn * price.audio + out * price.output) / 1e6, audioIn };
  }

  async function generate({ system, parts, schema, temperature }) {
    if (!apiKey) throw new Error("GEMINI_API_KEY missing");
    if (budget > 0 && db) {
      const spent = Number(await db.aiSpendToday());
      if (spent >= budget) throw new BudgetError(spent, budget);
    }
    const generationConfig = {
      temperature,
      responseMimeType: "application/json",
      responseJsonSchema: schema,
      maxOutputTokens: 4096,
    };
    if (thinkingLevel) generationConfig.thinkingConfig = { thinkingLevel };

    const res = await fetchImpl(`${base}/models/${encodeURIComponent(model)}:generateContent`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-goog-api-key": apiKey },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: system }] },
        contents: [{ role: "user", parts }],
        generationConfig,
      }),
    });
    const data = await res.json().catch(() => ({}));
    const c = cost(data.usageMetadata);
    if (db && c.usd > 0) await db.aiSpendAdd(c.usd).catch(() => {});
    if (!res.ok) throw new Error(`gemini ${res.status}: ${(data.error && data.error.message) || ""}`);
    if (data.promptFeedback && data.promptFeedback.blockReason) throw new Error(`gemini blocked: ${data.promptFeedback.blockReason}`);
    const cand = (data.candidates || [])[0];
    if (!cand || !cand.content) throw new Error(`gemini empty (${cand && cand.finishReason})`);
    const text = (cand.content.parts || []).filter((p) => !p.thought && p.text).map((p) => p.text).join("");
    return { json: JSON.parse(text), audioSeconds: c.audioIn / AUDIO_TOKENS_PER_SECOND };
  }

  const inline = (bytes, mime) => ({ inlineData: { mimeType: mime, data: bytes.toString("base64") } });

  function context(order, problems, lastAnalysis) {
    const problemFile = (problems || [])
      .map((p) => `- ${p.title}${p.symptoms ? ` (${p.symptoms})` : ""}: ${p.solution_text}`)
      .join("\n");
    return `نوع الطلب: سناب بلس ${TYPE_LABEL[order.type] || order.type}\n` +
      `الحالة الحالية: ${order.status}\n` +
      `آخر نتيجة صورة: ${lastAnalysis ? JSON.stringify(lastAnalysis) : "ما كاينش"}\n\n` +
      `ملف المشاكل:\n${problemFile || "فارغ"}`;
  }

  function clean(out) {
    if (!INTENTS.includes(out.intent)) out.intent = "unclear";
    out.reply = String(out.reply || "").trim().slice(0, 800);
    return out;
  }

  /** السكرينشوت -> JSON القسم 8. */
  async function analyzeScreenshot({ bytes, mime, order }) {
    const media = /^image\//.test(mime || "") ? mime : "image/jpeg";
    const { json } = await generate({
      system: SCREENSHOT_SYSTEM,
      schema: SCREENSHOT_SCHEMA,
      temperature: temp.image,
      parts: [inline(bytes, media), { text: `Order type: ${order.type}. Current step: ${order.status}.` }],
    });
    return json;
  }

  /** ميساج حر -> { intent, reply }. */
  async function interpretText({ text, order, problems, lastAnalysis }) {
    const { json } = await generate({
      system: `${ASSISTANT_RULES}\n\n${INTENT_GUIDE}`,
      schema: TEXT_SCHEMA,
      temperature: temp.text,
      parts: [{ text: context(order, problems, lastAnalysis) }, { text: `ميساج الكليان:\n${String(text).slice(0, 2000)}` }],
    });
    return clean(json);
  }

  /** فوكال -> { transcript, intent, reply, seconds } في نداء واحد. */
  async function interpretVoice({ bytes, mime, order, problems, lastAnalysis }) {
    const { json, audioSeconds } = await generate({
      system: `${ASSISTANT_RULES}\n\n${INTENT_GUIDE}\n\n${VOICE_GUIDE}`,
      schema: VOICE_SCHEMA,
      temperature: temp.text,
      parts: [{ text: context(order, problems, lastAnalysis) }, inline(bytes, (mime || "audio/ogg").split(";")[0])],
    });
    const out = clean(json);
    out.transcript = String(out.transcript || "").trim();
    out.seconds = audioSeconds;
    return out;
  }

  return { analyzeScreenshot, interpretText, interpretVoice };
}

module.exports = { createAi, BudgetError, SCREENSHOT_SCHEMA, TEXT_SCHEMA, VOICE_SCHEMA };
