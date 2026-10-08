/* ============================================================
   /api/activation-bot — webhook بوت التفعيل على Telegram (الأدمين)

   الأوامر، التنبيهات، قبول/رفض الصور، وحفظ الفوكالات بالأزرار.
   الكليان راه في واتساب (api/whatsapp.js).

   تيليغرام يبعث كل update هنا. الطلب يتقبل غير إذا جاب السر
   (X-Telegram-Bot-Api-Secret-Token) لي تعطى في setWebhook.
   الجواب ديما 200 بعد المعالجة، والتكرار محبوس في القاعدة.
   ============================================================ */

const crypto = require("crypto");
const { getApp } = require("../lib/activation-bot/app");

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
    if (update) await getApp().handleWebhook("telegram", update);
  } catch (e) {
    console.error("[activation-bot]", e);
  }
  res.status(200).setHeader("content-type", "application/json");
  res.end("{}");
};
