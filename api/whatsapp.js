/* ============================================================
   /api/whatsapp — webhook تاع WhatsApp Cloud API (قناة الكليان)

   GET   تحقق Meta وقت ربط الـwebhook (hub.verify_token)
   POST  الميساجات. يتقبل غير إذا X-Hub-Signature-256 = HMAC-SHA256
         تاع البايتات الخام بـ WHATSAPP_APP_SECRET. لهذا الملف يستعمل
         صيغة Web (Request) ماشي (req, res): Vercel تقرا الـbody قبل
         الـhandler، والتوقيع لازمو البايتات كما جاو بالضبط.

   الجواب 200 فورا، والمعالجة تكمل في waitUntil: Meta تعاود تبعث
   إذا ما جاوبناش بسرعة، والتكرار محبوس في القاعدة على كل حال.
   ============================================================ */

const crypto = require("crypto");
const { waitUntil } = require("@vercel/functions");
const { getApp } = require("../lib/activation-bot/app");

function validSignature(raw, header, secret) {
  if (!secret || !header || !header.startsWith("sha256=")) return false;
  const want = Buffer.from(crypto.createHmac("sha256", secret).update(raw).digest("hex"));
  const got = Buffer.from(header.slice(7));
  return want.length === got.length && crypto.timingSafeEqual(want, got);
}

async function GET(request) {
  const q = new URL(request.url).searchParams;
  const token = process.env.WHATSAPP_VERIFY_TOKEN;
  if (token && q.get("hub.mode") === "subscribe" && q.get("hub.verify_token") === token) {
    return new Response(q.get("hub.challenge") || "", { status: 200 });
  }
  return new Response("forbidden", { status: 403 });
}

async function POST(request) {
  const raw = Buffer.from(await request.arrayBuffer());
  if (!validSignature(raw, request.headers.get("x-hub-signature-256"), process.env.WHATSAPP_APP_SECRET)) {
    return new Response("bad signature", { status: 401 });
  }
  let body;
  try { body = JSON.parse(raw.toString("utf8")); } catch { return new Response("{}", { status: 200 }); }

  const work = getApp().handleWebhook("whatsapp", body).catch((e) => console.error("[whatsapp]", e));
  waitUntil(work);
  return new Response("{}", { status: 200, headers: { "content-type": "application/json" } });
}

module.exports = { GET, POST, validSignature };
