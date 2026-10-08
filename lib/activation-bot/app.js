/* ============================================================
   تركيب البوت من متغيرات البيئة — نفس الـhandler للزوج webhooks:
     api/whatsapp.js       الكليان (WhatsApp Cloud API)
     api/activation-bot.js الأدمين (Telegram)
   ============================================================ */

const { createTelegramAdapter } = require("./adapters/telegram");
const { createWhatsAppAdapter } = require("./adapters/whatsapp");
const { createDb } = require("./db");
const { createStorage } = require("./storage");
const { createAi } = require("./ai");
const { createHandler } = require("./handler");

let app;
function getApp(env = process.env) {
  if (app) return app;
  const url = env.ACTIVATION_SUPABASE_URL || env.SUPABASE_URL;
  const db = createDb({ url, serviceKey: env.SUPABASE_SERVICE_ROLE_KEY });
  const channels = {};
  if (env.WHATSAPP_TOKEN && env.WHATSAPP_PHONE_NUMBER_ID) {
    channels.whatsapp = createWhatsAppAdapter({
      token: env.WHATSAPP_TOKEN,
      phoneNumberId: env.WHATSAPP_PHONE_NUMBER_ID,
      graphVersion: env.WHATSAPP_GRAPH_VERSION || undefined,
      onSent: (ids) => db.markSent("whatsapp", ids),
    });
  }
  if (env.ACTIVATION_BOT_TOKEN) channels.telegram = createTelegramAdapter({ token: env.ACTIVATION_BOT_TOKEN });

  app = createHandler({
    channels,
    admin: channels.telegram,
    db,
    storage: createStorage({ url, serviceKey: env.SUPABASE_SERVICE_ROLE_KEY }),
    ai: createAi({ db, env }),
    adminIds: (env.ADMIN_CHAT_IDS || "").split(/[\s,]+/).filter(Boolean),
    storeWhatsapp: (env.WHATSAPP_STORE_NUMBER || "").replace(/\D/g, "") || undefined,
  });
  return app;
}

module.exports = { getApp };
