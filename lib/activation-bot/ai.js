/* ============================================================
   الـAI — ثلاث حوايج برك (القسم 2):
     1. قراية السكرينشوت       -> JSON (القسم 8)، الكود يقرر
     2. فهم الفوكال (STT)       -> نص يتعامل كيما ميساج مكتوب
     3. الميساج الحر             -> نية (JSON) + جواب قصير

   الموديل يرجع JSON مقيّد بـ schema (structured outputs)، وما
   يقررش حتى حاجة: القرارات في flow.js.
   ============================================================ */

const Anthropic = require("@anthropic-ai/sdk");
const { INTENTS } = require("./flow");
const { TYPE_LABEL } = require("./texts");

const nullable = (type, extra = {}) => ({ anyOf: [{ type, ...extra }, { type: "null" }] });

const SCREENSHOT_SCHEMA = {
  type: "object",
  additionalProperties: false,
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
  additionalProperties: false,
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

function createAi({
  apiKey = process.env.ANTHROPIC_API_KEY,
  model = process.env.ACTIVATION_AI_MODEL || "claude-opus-5-5",
  effort = process.env.ACTIVATION_AI_EFFORT || "low",
  sttKey = process.env.STT_API_KEY,
  sttBase = process.env.STT_BASE_URL || "https://api.openai.com/v1",
  sttModel = process.env.STT_MODEL || "gpt-4o-transcribe",
  fetchImpl = fetch,
  client,
} = {}) {
  const anthropic = client || new Anthropic({ apiKey, timeout: 40_000, maxRetries: 1 });

  async function jsonCall({ system, content, schema, maxTokens }) {
    const response = await anthropic.beta.messages.create({
      model,
      max_tokens: maxTokens,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      output_config: { effort, format: { type: "json_schema", schema } },
      system,
      messages: [{ role: "user", content }],
    });
    if (response.stop_reason === "refusal") throw new Error("ai refusal");
    if (response.stop_reason === "max_tokens") throw new Error("ai max_tokens");
    const text = response.content.filter((b) => b.type === "text").map((b) => b.text).join("");
    return JSON.parse(text);
  }

  /** السكرينشوت -> JSON القسم 8. */
  async function analyzeScreenshot({ bytes, mime, order }) {
    const media = ["image/jpeg", "image/png", "image/webp", "image/gif"].includes(mime) ? mime : "image/jpeg";
    return jsonCall({
      system: SCREENSHOT_SYSTEM,
      schema: SCREENSHOT_SCHEMA,
      maxTokens: 4000,
      content: [
        { type: "image", source: { type: "base64", media_type: media, data: bytes.toString("base64") } },
        { type: "text", text: `Order type: ${order.type}. Current step: ${order.status}.` },
      ],
    });
  }

  /** ميساج حر -> { intent, reply }. */
  async function interpretText({ text, order, problems, lastAnalysis }) {
    const problemFile = (problems || [])
      .map((p) => `- ${p.title}${p.symptoms ? ` (${p.symptoms})` : ""}: ${p.solution_text}`)
      .join("\n");
    const context =
      `نوع الطلب: سناب بلس ${TYPE_LABEL[order.type] || order.type}\n` +
      `الحالة الحالية: ${order.status}\n` +
      `آخر نتيجة صورة: ${lastAnalysis ? JSON.stringify(lastAnalysis) : "ما كاينش"}\n\n` +
      `ملف المشاكل:\n${problemFile || "فارغ"}`;
    const out = await jsonCall({
      system: [{ type: "text", text: `${ASSISTANT_RULES}\n\n${INTENT_GUIDE}` }],
      schema: TEXT_SCHEMA,
      maxTokens: 3000,
      content: [
        { type: "text", text: context },
        { type: "text", text: `ميساج الكليان:\n${String(text).slice(0, 2000)}` },
      ],
    });
    if (!INTENTS.includes(out.intent)) out.intent = "unclear";
    out.reply = String(out.reply || "").trim().slice(0, 800);
    return out;
  }

  /** فوكال -> نص (أي خدمة STT متوافقة مع /audio/transcriptions). */
  async function transcribe({ bytes, mime, ext }) {
    if (!sttKey) throw new Error("STT_API_KEY missing");
    const form = new FormData();
    form.append("file", new Blob([bytes], { type: mime || "audio/ogg" }), `voice.${ext === "oga" ? "ogg" : ext || "ogg"}`);
    form.append("model", sttModel);
    form.append("prompt", "Algerian Darija mixed with French. Snapchat+, App Store, Subscriptions, Redeem, iCloud.");
    const res = await fetchImpl(`${sttBase.replace(/\/+$/, "")}/audio/transcriptions`, {
      method: "POST",
      headers: { authorization: `Bearer ${sttKey}` },
      body: form,
    });
    if (!res.ok) throw new Error(`stt ${res.status}`);
    const data = await res.json();
    return String(data.text || "").trim();
  }

  return { analyzeScreenshot, interpretText, transcribe };
}

module.exports = { createAi, SCREENSHOT_SCHEMA, TEXT_SCHEMA };
