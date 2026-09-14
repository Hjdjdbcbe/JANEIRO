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

   اسم الملف بلا أقواس، والمسار يصل في المعامل `p` من إعادة
   الكتابة في vercel.json. الشكل `api/warranty/[...path].js`
   لم يُبنَ على هذا المشروع أصلاً، فسقط الاعتماد على اكتشاف
   المسارات ذات الأقواس.

   والنداء إلى الدالة بالمعاملات لا بالمسار: بوّابة Supabase
   ردّت «Requested function was not found» على
   /functions/v1/telegram-bot/warranty/verify/… بينما
   ?verify=… يعمل. فالمسار الجميل يُترجَم هنا إلى الشكل الذي
   تقبله البوّابة، والدالة تفهم الاثنين أصلاً.

   ولا يتبع التحويلات (redirect: manual): تعبئة الزبون تردّ 303
   إلى وثيقتها، فيُنقل التحويل كما هو ليراه المتصفّح ولا يُبتلع.
   ============================================================ */

const BASE = (process.env.SUPABASE_URL || "").replace(/\/+$/, "");
const FN = process.env.TELEGRAM_FUNCTION_NAME || "telegram-bot";

/** المسار والمعاملات من الطلب، أياً كان شكله قبل إعادة الكتابة. */
function target(req) {
  const u = new URL(req.url || "/", "http://x");
  const q = u.searchParams;

  // `p` من إعادة الكتابة؛ وإن غاب فالمسار كما جاء (نداء مباشر)
  let path = q.get("p");
  q.delete("p");
  if (path === null) {
    path = u.pathname.replace(/^\/api\/warranty/, "").replace(/^\/warranty/, "");
  } else {
    path = "/" + path.replace(/^\/+/, "");
  }

  const rest = q.toString();
  return (path || "/") + (rest ? `?${rest}` : "");
}

/* المسار الجميل إلى الشكل الذي تقبله بوّابة Supabase.

     /verify/JW-x  →  ?verify=JW-x
     /claim/<tok>  →  ?claim=<tok>
     /JW-x         →  ?doc=JW-x

   الدالة تفهم الشكلين، لكن البوّابة لا تمرّر إليها مساراً تحت
   اسمها على هذا المشروع. */
function asQuery(pathAndQuery) {
  const [rawPath, rawQuery = ""] = pathAndQuery.split("?");
  const q = new URLSearchParams(rawQuery);
  const seg = rawPath.split("/").filter(Boolean);

  if (seg[0] === "verify" && seg[1]) q.set("verify", seg[1]);
  else if (seg[0] === "claim" && seg[1]) q.set("claim", seg[1]);
  else if (seg[0]) q.set("doc", seg[0]);

  const s = q.toString();
  return s ? `?${s}` : "";
}

const escapeHtml = (s) =>
  String(s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

module.exports = async function handler(req, res) {
  if (!BASE) {
    res.status(503).setHeader("content-type", "text/plain; charset=utf-8");
    return res.end("SUPABASE_URL غير مضبوط في إعدادات Vercel.");
  }

  const called = `/functions/v1/${FN}${asQuery(target(req))}`;
  const upstream = BASE + called;

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

  /* الدالة تردّ صفحة لكل حالة تعرفها، بما فيها الخطأ. فردٌّ
     بحالة 4xx/5xx معناه أن الخلل قبلها — في العنوان أو البوّابة
     — ورسالة البوّابة وحدها لا تقول أيّ عنوان نودي. فتُعرَض هنا
     مع ما نُودي به، بلا المضيف: العطب يُشخَّص من الصفحة نفسها
     بدل جولة أخرى من التخمين. */
  if (up.status >= 400) {
    const detail = await up.text().catch(() => "");
    res.status(up.status);
    res.setHeader("content-type", "text/html; charset=utf-8");
    res.setHeader("cache-control", "no-store");
    return res.end(
      `<!doctype html><html lang="ar" dir="rtl"><meta charset="utf-8">` +
      `<meta name="viewport" content="width=device-width,initial-scale=1">` +
      `<style>body{font:16px/1.7 system-ui,sans-serif;margin:0;padding:28px 18px;` +
      `background:#F7F6FB;color:#14121F}.c{max-width:560px;margin:0 auto;background:#fff;` +
      `border:1px solid #E7E4F2;border-radius:16px;padding:22px}code{background:#F1EDFF;` +
      `padding:2px 6px;border-radius:6px;word-break:break-all;font-size:13px}` +
      `h1{font-size:19px;margin:0 0 12px}p{margin:10px 0}</style>` +
      `<div class="c"><h1>تعذّر فتح الصفحة</h1>` +
      `<p>تواصل مع البائع الذي أرسل لك الرابط.</p>` +
      `<p style="color:#6B6880;font-size:13px">للمالك — الحالة ` +
      `<code>${up.status}</code>، ونودي: <code>${escapeHtml(called)}</code></p>` +
      `<p style="color:#6B6880;font-size:13px"><code>${escapeHtml(detail.slice(0, 300))}</code></p>` +
      `</div></html>`);
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
