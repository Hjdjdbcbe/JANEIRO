/* ============================================================
   /api/activation-bot — webhook بوت تفعيل Snapchat+ (Telegram)

   تيليغرام يبعث كل update هنا. الطلب يتقبل غير إذا جاب السر
   (X-Telegram-Bot-Api-Secret-Token) لي تعطى في setWebhook — بلاه
   أي واحد يقدر يزوّر update ويطلّع أكواد رصيد.

   الجواب ديما 200 بعد المعالجة: تيليغرام يعاود يبعث كل update ما
   تجاوبش، والتكرار محبوس في القاعدة (act_seen_update).

   المنطق كامل في lib/activation-bot/. الإعداد: docs/activation-bot.md
   ============================================================ */

const crypto = require("crypto");
const { createTelegramAdapter } = require("../lib/activation-bot/adapters/telegram");
const { createDb } = require("../lib/activation-bot/db");
const { createAi } = require("../lib/activation-bot/ai");
const { createHandler } = require("../lib/activation-bot/handler");

let handler;
function getHandler() {
  if (handler) return handler;
  const env = process.env;
  handler = createHandler({
    msg: createTelegramAdapter({ token: env.ACTIVATION_BOT_TOKEN }),
    db: createDb({
      url: env.ACTIVATION_SUPABASE_URL || env.SUPABASE_URL,
      serviceKey: env.SUPABASE_SERVICE_ROLE_KEY,
    }),
    ai: createAi(),
    adminIds: (env.ADMIN_CHAT_IDS || "").split(/[\s,]+/).filter(Boolean),
    botUsername: (env.ACTIVATION_BOT_USERNAME || "").replace(/^@/, "") || undefined,
  });
  return handler;
}

function sameSecret(got, want) {
  const a = Buffer.from(String(got || ""));
  const b = Buffer.from(String(want || ""));
  return a.length === b.length && a.length > 0 && crypto.timingSafeEqual(a, b);
}

module.exports = async function activationBot(req, res) {
  if (req.method !== "POST") {
    res.status(405).setHeader("allow", "POST");
    return res.end();
  }
  if (!process.env.ACTIVATION_WEBHOOK_SECRET) {
    res.status(503);
    return res.end("ACTIVATION_WEBHOOK_SECRET not set");
  }
  if (!sameSecret(req.headers["x-telegram-bot-api-secret-token"], process.env.ACTIVATION_WEBHOOK_SECRET)) {
    res.status(401);
    return res.end();
  }

  let update = req.body;
  if (typeof update === "string") {
    try { update = JSON.parse(update); } catch { update = null; }
  }

  try {
    if (update) await getHandler().handleUpdate(update);
  } catch (e) {
    console.error("[activation-bot]", e);
  }
  res.status(200).setHeader("content-type", "application/json");
  res.end("{}");
};

