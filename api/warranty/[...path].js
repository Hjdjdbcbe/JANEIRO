/* ============================================================
   /warranty/*  —  وسيط صفحات الزبون
   ============================================================
   Supabase تمنع دوال Edge من بعث HTML: تستبدل Content-Type
   بـ text/plain وتضيف `Content-Security-Policy: default-src
   'none'; sandbox`. سياسة أمان عندها — دالة على نطاق مشترك لا
   تُستعمل في التصيّد — ولا تُلغى من كودنا مهما وضعنا من ترويسات.

   فالصفحة تُجلب من الدالة وتُعاد من هنا: Vercel تخدم ما نعطيها
   بالترويسة التي نعطيها. الدالة تبقى المصدر الوحيد للمنطق
   والقراءة من القاعدة؛ هذا الملف لا يعرف شيئاً عنها، ينقل لا
   يفسّر.

   لا يتبع التحويلات (redirect: manual): تعبئة الزبون تردّ 303
   إلى وثيقته، فيُنقل التحويل كما هو ليراه المتصفّح ولا يُبتلع.
   ============================================================ */

const BASE = (process.env.SUPABASE_URL || "").replace(/\/+$/, "");
const FN = process.env.TELEGRAM_FUNCTION_NAME || "telegram-bot";

/** المسار بعد /warranty، أياً كان شكل العنوان قبل إعادة الكتابة. */
function tail(rawUrl) {
  const u = new URL(rawUrl || "/", "http://x");
  const p = u.pathname
    .replace(/^\/api\/warranty/, "")
    .replace(/^\/warranty/, "");
  return (p || "/") + u.search;
}

module.exports = async function handler(req, res) {
  if (!BASE) {
    res.status(503).setHeader("content-type", "text/plain; charset=utf-8");
    return res.end("SUPABASE_URL غير مضبوط في إعدادات Vercel.");
  }

  const upstream = `${BASE}/functions/v1/${FN}/warranty${tail(req.url)}`;

  const init = {
    method: req.method,
    redirect: "manual",
    headers: {
      // لغة المتصفّح تُنقل: الدالة تختار لغة الصفحة بها
      "accept-language": req.headers["accept-language"] || "",
      // عنوان الزبون للحدّ على المحاولات — وإلا رأت الدالة عنوان
      // Vercel وحده فصار الحدّ مشتركاً بين كل الزوّار
      "x-forwarded-for":
        (req.headers["x-forwarded-for"] || "").toString().split(",")[0].trim(),
    },
  };

  if (req.method === "POST") {
    // الاستمارة ثلاثة حقول؛ تُعاد بترميزها كما جاءت
    const body = req.body;
    init.body =
      typeof body === "string" ? body : new URLSearchParams(body || {}).toString();
    init.headers["content-type"] = "application/x-www-form-urlencoded";
  }

  let up;
  try {
    up = await fetch(upstream, init);
  } catch {
    res.status(502).setHeader("content-type", "text/html; charset=utf-8");
    return res.end("<!doctype html><meta charset=utf-8><p>تعذّر الوصول للخدمة. أعد المحاولة.</p>");
  }

  const loc = up.headers.get("location");
  if (loc) res.setHeader("location", loc);

  // ترويسة من عندنا لا من الدالة: ترويسة الدالة هي المشكلة نفسها
  res.setHeader("content-type", "text/html; charset=utf-8");
  res.setHeader("x-robots-tag", "noindex, nofollow");
  res.setHeader("cache-control", "no-store");
  res.setHeader("referrer-policy", "no-referrer");
  res.status(up.status);
  res.end(Buffer.from(await up.arrayBuffer()));
};
