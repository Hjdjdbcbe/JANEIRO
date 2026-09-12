// ============================================================
// POST /functions/v1/telegram-bot   — Telegram webhook
//
// بوت المخزون: خاص بالأدمن، لا يراه زبون.
//
//   يطلب البائع بطاقة  -> تُحجَز ويُعرَض كودها مع زرّين
//   ✅ تأكيد           -> نجحت العملية، البطاقة مباعة وتُحسب له
//   ❌ إلغاء           -> فشلت، البطاقة ترجع للمخزون فوراً
//
// الحالة كلها في قاعدة البيانات (021_gift_card_bot.sql). هذا
// الملف واجهة فقط: يترجم ضغطات الأزرار إلى نداءات RPC ويصيغ
// الرد بالعربية. لا قرار عمل واحد يُتَّخذ هنا.
//
// النشر: هذه الدالة تُنشر بـ --no-verify-jwt، فتليجرام لا يرسل
// مفتاح Supabase. ما يحرسها هو الترويسة السرّية أدناه، ولذلك
// ترفض العمل أصلاً إن لم يكن TELEGRAM_WEBHOOK_SECRET مضبوطاً.
// ============================================================
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { DOC, formatDate } from "./i18n.ts";

const TG_TOKEN   = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
const TG_SECRET  = Deno.env.get("TELEGRAM_WEBHOOK_SECRET") ?? "";
const OWNER_ID   = Number(Deno.env.get("TELEGRAM_OWNER_ID") ?? "0");
// api.telegram.org في التشغيل الحقيقي. المتغيّر موجود ليستطيع
// tests/local/bot-e2e.test.js توجيه النداءات إلى خادم وهمي
// ويفحص ما أرسله البوت فعلاً — لا يُضبط في الإنتاج.
const API_BASE   = Deno.env.get("TELEGRAM_API_BASE") ?? "https://api.telegram.org";
// رابط هذه الدالة نفسها، كما يفتحه الزبون. يُشتق من SUPABASE_URL
// فلا متغيّر بيئة إضافي على من يركّب.
const SELF_URL   = `${Deno.env.get("SUPABASE_URL") ?? ""}/functions/v1/telegram-bot`;
// دومين المتجر. الزبون يرى janeiro-store لا supabase.co — وهو ما
// يجعله يحسّ أن الوثيقة من الموقع. vercel.json يحوّل /warranty/*
// إلى هذه الدالة. بلا ضبطه تعمل الروابط على شكل المعاملات، فلا
// يتوقّف شيء إن نُسي.
const SITE_URL = (Deno.env.get("PUBLIC_SITE_URL") ?? "").replace(/\/+$/, "");
const claimUrl  = (t: string) =>
  SITE_URL ? `${SITE_URL}/warranty/claim/${t}` : `${SELF_URL}?fill=${t}`;
const docUrl    = (c: string) =>
  SITE_URL ? `${SITE_URL}/warranty/${c}` : `${SELF_URL}?cert=${c}`;
const verifyUrl = (c: string) =>
  SITE_URL ? `${SITE_URL}/warranty/verify/${c}` : `${SELF_URL}?verify=${c}`;
const API        = `${API_BASE}/bot${TG_TOKEN}`;

function db(): SupabaseClient {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );
}

// ------------------------------------------------------------
// Telegram helpers
// ------------------------------------------------------------
// copy_text زر نسخ أصلي في تليجرام (Bot API 7.11+): ينسخ النص
// إلى الحافظة بضغطة، بلا تحديد يدوي. الكود يبقى كذلك داخل
// <code> فوقه، فالنقر عليه ينسخ أيضاً على العملاء الأقدم.
type Button = {
  text: string;
  callback_data?: string;
  copy_text?: { text: string };
};

async function tg(method: string, body: unknown): Promise<Record<string, unknown> | null> {
  try {
    const r = await fetch(`${API}/${method}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const out = await r.json();
    if (!out.ok) console.error(`telegram ${method} failed`, out);
    return out.result ?? null;
  } catch (err) {
    console.error(`telegram ${method} threw`, err);
    return null;
  }
}

const send = (chat: number, text: string, rows: Button[][] = []) =>
  tg("sendMessage", {
    chat_id: chat, text, parse_mode: "HTML",
    ...(rows.length ? { reply_markup: { inline_keyboard: rows } } : {}),
  });

const edit = (chat: number, msg: number, text: string, rows: Button[][] = []) =>
  tg("editMessageText", {
    chat_id: chat, message_id: msg, text, parse_mode: "HTML",
    reply_markup: { inline_keyboard: rows },
  });

/** سؤال يُجاب عليه بالردّ على الرسالة — بديل جدول حالة كامل. */
const ask = (chat: number, text: string) =>
  tg("sendMessage", {
    chat_id: chat, text, parse_mode: "HTML",
    reply_markup: { force_reply: true, input_field_placeholder: "الصق الأكواد هنا" },
  });

const answer = (id: string, text = "", alert = false) =>
  tg("answerCallbackQuery", { callback_query_id: id, text, show_alert: alert });

/** تليجرام يفسّر < > & كوسوم HTML. كل نص من المستخدم يمرّ من هنا. */
function esc(s: unknown): string {
  return String(s ?? "")
    .replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

// ------------------------------------------------------------
// أخطاء قاعدة البيانات -> عربية
// ------------------------------------------------------------
const ERRORS: Record<string, string> = {
  NOT_AUTHORIZED:        "لا تملك صلاحية استعمال هذا البوت.",
  NOT_OWNER:             "هذا الأمر للمالك وحده.",
  NOT_YOUR_ISSUE:        "هذه العملية ليست لك.",
  ISSUE_NOT_FOUND:       "لم أجد هذه العملية.",
  ISSUE_ALREADY_SETTLED: "هذه العملية مغلقة من قبل.",
  OUT_OF_STOCK:          "نفد المخزون من هذه المدة. أبلغ المالك ليشحنها.",
  VARIANT_NOT_FOUND:     "هذه المدة لم تعد متاحة.",
  PRODUCT_NOT_FOUND:     "لا يوجد منتج بهذا الرمز.",
  PRODUCT_EXISTS:        "يوجد منتج بهذا الرمز مسبقاً.",
  VARIANT_EXISTS:        "توجد مدة بهذا الرمز داخل المنتج مسبقاً.",
  PENDING_LIMIT:         "لديك عمليات معلّقة كثيرة. أغلقها بتأكيد أو إلغاء أولاً.",
  NO_CODES:              "لم أجد أي كود في رسالتك.",
  INVALID_CODE:          "الرمز يجب أن يكون حروفاً لاتينية صغيرة وأرقاماً و - أو _ فقط.",
  INVALID_NAME:          "الاسم فارغ.",
  INVALID_TELEGRAM_ID:   "رقم تليجرام غير صالح.",
  ADMIN_NOT_FOUND:       "لا يوجد أدمن بهذا الرقم.",
  CANNOT_REMOVE_SELF:    "لا يمكنك حذف نفسك.",
  CANNOT_REMOVE_OWNER:   "لا يمكن حذف المالك.",
  NOT_FOUND:             "لم أجد المطلوب.",
  ISSUE_NOT_CONFIRMED:   "الوثيقة تصدر بعد تأكيد البيعة فقط.",
  CERTIFICATE_NOT_FOUND: "لا توجد وثيقة بهذا الرمز.",
  FIELD_EXISTS:          "هذا الحقل موجود في المنتج مسبقاً.",
  FIELD_NOT_FOUND:       "لا يوجد حقل بهذا الاسم في المنتج.",
  INVALID_LABEL:         "اسم الحقل فارغ أو طويل جداً.",
  QUERY_TOO_SHORT:       "اكتب حرفين على الأقل للبحث.",
  WIZARD_NOT_STARTED:    "ابدأ من /warranty.",
  INVALID_PLATFORM:      "اسم المنصة فارغ أو طويل جداً.",
  INVALID_MONTHS:        "المدة بالأشهر، من 1 إلى 120.",
  INVALID_BONUS:         "أيام الهدية من 0 إلى 90.",
  PLATFORM_MISSING:      "لم تُختَر المنصة بعد.",
  MONTHS_MISSING:        "لم تُختَر المدة بعد.",
  PLATFORM_NOT_FOUND:    "لا توجد منصة بهذا الاسم.",
  ALREADY_CLAIMED:       "عُمِّرت هذه الوثيقة، فلا رابط جديد لها.",
  ALREADY_REVOKED:       "هذه الوثيقة ملغاة مسبقاً.",
  CERTIFICATE_REVOKED:   "هذه الوثيقة ملغاة.",
  CERTIFICATE_PENDING:   "لم يعبّئها الزبون بعد.",
  LINK_NOT_FOUND:        "هذا الرابط غير صحيح أو استُبدل.",
  LINK_USED:             "استُعمل هذا الرابط مسبقاً.",
  LINK_EXPIRED:          "انتهت صلاحية الرابط.",
  RATE_LIMITED:          "محاولات كثيرة. انتظر قليلاً.",
  INVALID_KIND:          "نوع غير معروف.",
};

function human(err: unknown): string {
  const raw  = String((err as { message?: string })?.message ?? err ?? "");
  const code = raw.split(":")[0].trim().replace(/[^A-Z_]/g, "");
  if (code === "PENDING_LIMIT") {
    const n = raw.split(":")[1]?.trim();
    return n ? `الحد ${n} عمليات معلّقة. أغلق واحدة بتأكيد أو إلغاء أولاً.` : ERRORS.PENDING_LIMIT;
  }
  if (code === "FIELD_REQUIRED") {
    const f = raw.split(":").slice(1).join(":").trim();
    return f ? `ينقص حقل مطلوب: ${f}` : "ينقص حقل مطلوب.";
  }
  if (code === "CERTIFICATE_EXISTS") {
    const c = raw.split(":").slice(1).join(":").trim();
    return c ? `صدرت وثيقة لهذه البيعة مسبقاً: ${c}` : "صدرت وثيقة لهذه البيعة مسبقاً.";
  }
  if (code === "FIELD_TOO_LONG") return "إحدى القيم طويلة جداً.";
  if (ERRORS[code]) return ERRORS[code];
  console.error("unmapped bot error:", raw);
  return "حدث خطأ غير متوقع. حاول مرة أخرى.";
}

/** كل نداء RPC يمرّ من هنا: إما بيانات وإما رسالة عربية جاهزة. */
async function rpc<T = unknown>(
  client: SupabaseClient, fn: string, args: Record<string, unknown>,
): Promise<{ data: T; error: null } | { data: null; error: string }> {
  const { data, error } = await client.rpc(fn, args);
  if (error) return { data: null, error: human(error) };
  return { data: data as T, error: null };
}

// ------------------------------------------------------------
// القوائم
// ------------------------------------------------------------
type Variant = {
  variant_id: string; code: string; name: string;
  available: number; reserved: number; sold: number;
};
type Product = {
  product_id: string; code: string; name: string;
  is_active: boolean; variants: Variant[];
};

function mainMenu(isOwner: boolean): Button[][] {
  const rows: Button[][] = [
    [{ text: "🛒 بيع بطاقة", callback_data: "m:sell" }],
    [{ text: "⏳ المعلّقة", callback_data: "m:pending" },
     { text: "📊 مبيعاتي", callback_data: "m:stats" }],
  ];
  rows.push([{ text: "🧾 وثيقة التزام", callback_data: "wz:start" }]);
  rows.push([{ text: "⏰ تنتهي قريباً", callback_data: "m:exp" },
             { text: "🔎 بحث عن زبون", callback_data: "m:find" }]);
  if (isOwner) {
    rows.push([{ text: "📦 المخزون", callback_data: "m:stock" },
               { text: "🏆 مبيعات الكل", callback_data: "m:all" }]);
    rows.push([{ text: "➕ شحن أكواد", callback_data: "m:load" },
               { text: "👥 الأدمن", callback_data: "m:admins" }]);
  }
  return rows;
}

const backRow: Button[] = [{ text: "⬅️ القائمة", callback_data: "m:home" }];

function homeText(name: string, isOwner: boolean): string {
  return `أهلاً ${esc(name)} 👋\n\n` +
    (isOwner ? "أنت المالك: تشحن المخزون وتضيف الأدمن وترى مبيعات الجميع.\n\n" : "") +
    "اختر من الأزرار، أو اكتب /help لكل الأوامر.";
}

// ------------------------------------------------------------
// نصوص جاهزة
// ------------------------------------------------------------
function stockText(catalog: Product[]): string {
  if (!catalog.length) return "لا يوجد أي منتج بعد. أضف واحداً بـ /addproduct";
  const out = ["📦 <b>المخزون</b>", ""];
  for (const p of catalog) {
    out.push(`<b>${esc(p.name)}</b>  <code>${esc(p.code)}</code>`);
    if (!p.variants.length) out.push("   (لا مدد بعد — /addvariant)");
    for (const v of p.variants) {
      out.push(`   • ${esc(v.name)} — متاحة <b>${v.available}</b>` +
               `${v.reserved ? ` · محجوزة ${v.reserved}` : ""}` +
               `${v.sold ? ` · مباعة ${v.sold}` : ""}`);
    }
    out.push("");
  }
  return out.join("\n").trim();
}

type BreakItem = {
  product: string; variant: string; confirmed: number; cancelled: number;
};
type Stat = {
  telegram_id: number; name: string; role: string; is_active: boolean;
  confirmed: number; cancelled: number; pending: number; today: number; this_month: number;
  items: BreakItem[];
};

/** «• نتفليكس — سنة: 8» — سطر لكل مدة بيعت فعلاً. */
function itemLines(items: BreakItem[], pad = "   "): string[] {
  return (items ?? []).map((it) =>
    `${pad}• ${esc(it.product)} — ${esc(it.variant)}: <b>${it.confirmed}</b>` +
    (it.cancelled ? ` <i>(ملغاة ${it.cancelled})</i>` : ""));
}

function statsText(rows: Stat[], all: boolean, title?: string): string {
  if (!rows.length) return "لا مبيعات بعد.";

  if (!all) {
    const s = rows[0];
    const out = [
      title ?? "📊 <b>مبيعاتك</b>", "",
      `✅ عمليات ناجحة: <b>${s.confirmed}</b>`,
      `📅 اليوم: <b>${s.today}</b>`,
      `🗓 هذا الشهر: <b>${s.this_month}</b>`,
      `❌ ملغاة: ${s.cancelled}`,
      `⏳ معلّقة الآن: ${s.pending}`,
    ];
    if (s.items?.length) out.push("", "<b>ماذا بعت بالضبط:</b>", ...itemLines(s.items, ""));
    return out.join("\n");
  }

  const out = ["🏆 <b>مبيعات كل الأدمن</b>", ""];
  rows.forEach((s, i) => {
    const medal = ["🥇", "🥈", "🥉"][i] ?? `${i + 1}.`;
    out.push(`${medal} <b>${esc(s.name)}</b>${s.is_active ? "" : " (معطّل)"}`);
    out.push(`   ✅ ${s.confirmed} · اليوم ${s.today} · الشهر ${s.this_month}` +
             ` · ❌ ${s.cancelled} · ⏳ ${s.pending}`);
    out.push(...itemLines(s.items));
    out.push("");
  });
  const total = rows.reduce((n, s) => n + s.confirmed, 0);
  out.push(`الإجمالي: <b>${total}</b> عملية ناجحة`);
  return out.join("\n").replace(/\n{3,}/g, "\n\n");
}

type CustomerField = { label: string; value: string };

type Certificate = {
  code: string; product_name: string; variant_name: string;
  card_code?: string; seller?: string; customer: CustomerField[];
  starts_at: string; ends_at: string | null;
  days_left: number | null; expired?: boolean;
};

/** يوم واحد بصيغة ثابتة: 2026-09-10 */
const day = (iso: string | null): string =>
  iso ? new Date(iso).toISOString().slice(0, 10) : "—";

/**
 * الوثيقة كما تُرسل للزبون: رسالة واحدة قائمة بذاتها يعيد البائع
 * توجيهها كما هي. لا رابط ولا مرفق — تعمل على أي هاتف بلا إنترنت
 * إضافي، ورمز التحقق فيها يكفي لمراجعتها لاحقاً بـ/cert.
 */
function certificateText(c: Certificate): string {
  const out = [
    "🧾 <b>وثيقة ضمان — Janeiro</b>", "",
    `<b>${esc(c.product_name)} — ${esc(c.variant_name)}</b>`, "",
  ];
  if (c.customer?.length) {
    out.push("👤 <b>الزبون</b>");
    for (const f of c.customer) out.push(`${esc(f.label)}: <b>${esc(f.value)}</b>`);
    out.push("");
  }
  out.push(`📅 يبدأ: <b>${day(c.starts_at)}</b>`);
  if (c.ends_at) {
    out.push(`📅 ينتهي: <b>${day(c.ends_at)}</b>` +
      (c.expired ? " — <b>منتهٍ</b>"
                 : c.days_left !== null ? ` (${c.days_left} يوماً)` : ""));
  } else {
    out.push("📅 المدة: غير محدّدة");
  }
  out.push("", `🔖 رمز التحقق: <code>${esc(c.code)}</code>`);
  if (c.seller) out.push(`البائع: ${esc(c.seller)}`);
  return out.join("\n");
}

type Expiring = {
  code: string; product_name: string; variant_name: string;
  customer: CustomerField[]; ends_at: string; days_left: number; seller: string;
};

const who = (c: CustomerField[]): string =>
  c?.length ? c.map((f) => esc(f.value)).join(" · ") : "—";

function expiringText(rows: Expiring[], days: number): string {
  const span = days === 0 ? "اليوم" : `خلال ${days} يوماً`;
  if (!rows.length) return `⏰ لا اشتراك ينتهي ${span}.`;
  const out = [`⏰ <b>تنتهي ${span}</b> — ${rows.length}`, ""];
  for (const r of rows) {
    out.push(`• <b>${who(r.customer)}</b>`);
    out.push(`  ${esc(r.product_name)} — ${esc(r.variant_name)}`);
    out.push(`  ينتهي ${day(r.ends_at)} — <b>${r.days_left}</b> يوماً`);
    out.push(`  <code>${esc(r.code)}</code>`);
    out.push("");
  }
  return out.join("\n").trim();
}

function foundText(rows: Certificate[]): string {
  if (!rows.length) return "لم أجد زبوناً بهذا الاسم أو الرمز.";
  const out = [`🔎 <b>${rows.length} نتيجة</b>`, ""];
  for (const r of rows) {
    out.push(`• <b>${who(r.customer)}</b>`);
    out.push(`  ${esc(r.product_name)} — ${esc(r.variant_name)}`);
    out.push(`  ${day(r.starts_at)} ← ${day(r.ends_at)}` +
             (r.expired ? " — <b>منتهٍ</b>" : ""));
    out.push(`  <code>${esc(r.code)}</code>`);
    out.push("");
  }
  out.push("للوثيقة كاملة: <code>/cert الرمز</code>");
  return out.join("\n").trim();
}

type Pending = {
  issue_id: string; card_code: string; product_name: string; variant_name: string;
  customer_ref: string | null; requested_at: string; seller: string; mine: boolean;
};

function pendingText(rows: Pending[]): string {
  if (!rows.length) return "⏳ لا توجد عمليات معلّقة.";
  const out = ["⏳ <b>عمليات معلّقة</b>", ""];
  for (const p of rows) {
    out.push(`• ${esc(p.product_name)} — ${esc(p.variant_name)}`);
    out.push(`  <code>${esc(p.card_code)}</code>`);
    if (!p.mine) out.push(`  البائع: ${esc(p.seller)}`);
    if (p.customer_ref) out.push(`  الزبون: ${esc(p.customer_ref)}`);
    out.push("");
  }
  out.push("اضغط على كل واحدة أدناه لإغلاقها.");
  return out.join("\n").trim();
}

/** رسالة البطاقة الصادرة: الكود + زرّا تأكيد/إلغاء. */
function issueText(d: {
  product_name: string; variant_name: string; card_code: string;
  card_note?: string | null; remaining: number;
}): string {
  return [
    `🎟 <b>${esc(d.product_name)} — ${esc(d.variant_name)}</b>`, "",
    `<code>${esc(d.card_code)}</code>`,
    ...(d.card_note ? ["", `📝 ${esc(d.card_note)}`] : []),
    "", `المتبقي في المخزون: <b>${d.remaining}</b>`,
    "", "سلّم الكود للزبون، ثم:",
    "✅ تأكيد إن نجحت العملية — ❌ إلغاء إن فشلت (ترجع البطاقة للمخزون).",
  ].join("\n");
}

const issueButtons = (id: string, code: string): Button[][] => [
  [{ text: "📋 نسخ الكود", copy_text: { text: code } }],
  [{ text: "✅ تأكيد", callback_data: `ok:${id}` },
   { text: "❌ إلغاء", callback_data: `no:${id}` }],
];

const HELP = [
  "<b>الأوامر</b>", "",
  "/menu — القائمة",
  "/stock — المخزون",
  "/stats — مبيعاتك",
  "/pending — عملياتك المعلّقة",
  "/warranty — وثيقة التزام خدمة جديدة",
  "/revoke &lt;JW-…&gt; — إبطال وثيقة",
  "/relink &lt;JW-…&gt; — رابط جديد لوثيقة لم تُعمَّر",
  "/cert &lt;الرمز&gt; — وثيقة ضمان بالرمز",
  "/find &lt;اسم أو يوزر أو رقم&gt; — ابحث عن زبون",
  "/expiring [أيام] — اشتراكات تنتهي قريباً (7 افتراضياً)",
  "/id — رقمك في تليجرام",
  "", "<b>للمالك</b>", "",
  "/admins — قائمة الأدمن",
  "/addadmin &lt;رقم تليجرام&gt; [الاسم]",
  "/deladmin &lt;رقم تليجرام&gt;",
  "/addproduct &lt;رمز&gt; &lt;الاسم&gt;",
  "   مثال: <code>/addproduct netflix نتفليكس</code>",
  "/addvariant &lt;رمز المنتج&gt; &lt;رمز المدة&gt; &lt;الاسم&gt;",
  "   مثال: <code>/addvariant netflix 6months 6 أشهر</code>",
  "/addcards &lt;رمز المنتج&gt; &lt;رمز المدة&gt; ثم الأكواد سطراً سطراً:",
  "<code>/addcards giftcard year\nCODE-1\nCODE-2</code>",
  "/allstats — مبيعات الجميع",
  "/breakdown — المبيعات حسب المنتج",
  "/contacts — قنوات التواصل أسفل وثيقة الزبون",
  "/addcontact &lt;التسمية&gt; | &lt;القيمة&gt; | [رابط]",
  "/delcontact &lt;التسمية&gt;",
  "/platforms — منصات أزرار الوثيقة",
  "/addplatform &lt;الاسم&gt;   ·   /delplatform &lt;الاسم&gt;",
  "/fields — بيانات الزبون المطلوبة لكل منتج",
  "/addfield &lt;رمز المنتج&gt; &lt;اسم الحقل&gt; [optional]",
  "   مثال: <code>/addfield giftcard يوزر الأنستا</code>",
  "/delfield &lt;رمز المنتج&gt; &lt;اسم الحقل&gt;",
].join("\n");

// ------------------------------------------------------------
// القارئ المشترك: من المتحدث، ومسموح له؟
// ------------------------------------------------------------
type Identity = { known: boolean; active: boolean; role: string | null; name?: string };

async function identify(
  client: SupabaseClient, tgId: number, username?: string, name?: string,
): Promise<Identity> {
  // المالك الأول يُفتح من متغيّر البيئة: بلا هذا لا سبيل لدخول
  // قاعدة فارغة أصلاً.
  if (OWNER_ID && tgId === OWNER_ID) {
    await client.rpc("bot_bootstrap_owner", {
      p_telegram_id: tgId, p_username: username ?? null, p_name: name ?? null,
    });
  }
  const { data } = await client.rpc("bot_identify", {
    p_telegram_id: tgId, p_username: username ?? null, p_name: name ?? null,
  });
  return (data ?? { known: false, active: false, role: null }) as Identity;
}

async function catalog(client: SupabaseClient, tgId: number, onlyActive = true) {
  return await rpc<Product[]>(client, "bot_catalog",
    { p_telegram_id: tgId, p_only_active: onlyActive });
}

/** يجد مدة بالرمز داخل منتج بالرمز. */
function findVariant(cat: Product[], productCode: string, variantCode: string) {
  const p = cat.find((x) => x.code === productCode.toLowerCase());
  if (!p) return { error: "لا يوجد منتج بهذا الرمز. /stock يعرض الرموز." };
  const v = p.variants.find((x) => x.code === variantCode.toLowerCase());
  if (!v) return { error: `المنتج «${esc(p.name)}» ليس فيه مدة بهذا الرمز.` };
  return { product: p, variant: v };
}

// ------------------------------------------------------------
// شحن الأكواد بالأزرار: السؤال يحمل الرمزين في نصّه، والردّ
// عليه يعيدهما. حالة المحادثة تعيش في تليجرام لا في جدول.
// ------------------------------------------------------------
const LOAD_PROMPT = "📥 شحن أكواد";
const LOAD_RE = new RegExp(`^${LOAD_PROMPT} — (\\S+) / (\\S+)`);

// بيانات الزبون بعد التأكيد: رقم العملية داخل نصّ السؤال نفسه،
// فلا حاجة لجدول حالة — نفس حيلة شحن الأكواد.
const CERT_PROMPT = "🧾 بيانات الزبون";
const CERT_RE = new RegExp(`^${CERT_PROMPT} — ([0-9a-f-]{36})`);

const FIND_PROMPT = "🔎 بحث عن زبون";

function parseCodes(body: string): string[] {
  return body.split(/[\n\r,;]+/).map((c) => c.trim()).filter(Boolean);
}

async function loadCards(
  client: SupabaseClient, chat: number, tgId: number,
  productCode: string, variantCode: string, codes: string[],
) {
  if (!codes.length) { await send(chat, "لم أجد أي كود. أرسل كوداً في كل سطر."); return; }

  const cat = await catalog(client, tgId, false);
  if (cat.error) { await send(chat, cat.error); return; }
  const found = findVariant(cat.data!, productCode, variantCode);
  if ("error" in found) { await send(chat, found.error!); return; }

  const res = await rpc<{ added: number; duplicates: number; available: number }>(
    client, "bot_add_cards",
    { p_telegram_id: tgId, p_variant_id: found.variant!.variant_id, p_codes: codes },
  );
  if (res.error) { await send(chat, res.error); return; }

  const d = res.data!;
  await send(chat, [
    `✅ <b>${esc(found.product!.name)} — ${esc(found.variant!.name)}</b>`,
    `أُضيفت: <b>${d.added}</b>` + (d.duplicates ? `\nمكرّرة تُجوهلت: ${d.duplicates}` : ""),
    `المتاح الآن: <b>${d.available}</b>`,
  ].join("\n"), [backRow]);
}

// ============================================================
// صفحات الزبون — نفس الدالة تخدمها عبر GET/POST عاديين.
//
// الزبون لا يملك تليجرام بالضرورة ولا حساباً عندنا. الرمز في
// الرابط هو مفتاحه الوحيد: 256 بت للاستمارة (مرة واحدة، وتنتهي)،
// و56 بت للوثيقة (دائمة، كأي رابط فاتورة).
// ============================================================
type Contact = { label: string; value: string; url: string | null; icon: string | null };

function page(title: string, body: string, extraHead = ""): Response {
  return new Response(
    `<!doctype html><html lang="ar" dir="rtl"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title><style>
:root{--ink:#14121F;--muted:#6B6880;--line:#E7E4F2;--bg:#F7F6FB;--card:#fff;--accent:#6C35FF;--soft:#F1EDFF}
@media(prefers-color-scheme:dark){:root{--ink:#F3F1FA;--muted:#A7A3BC;--line:#2C2842;--bg:#131120;--card:#1B1830;--soft:#241F3E}}
*{box-sizing:border-box}
body{margin:0;padding:20px 14px;background:var(--bg);color:var(--ink);
 font:16px/1.65 system-ui,"Segoe UI",Tahoma,sans-serif;-webkit-text-size-adjust:100%}
.wrap{max-width:520px;margin:0 auto}
.card{background:var(--card);border:1px solid var(--line);border-radius:18px;padding:22px;
 box-shadow:0 1px 2px rgba(20,18,31,.04),0 8px 28px rgba(20,18,31,.06)}
h1{font-size:20px;margin:0 0 4px}
.sub{color:var(--muted);font-size:14px;margin:0 0 20px}
label{display:block;font-size:14px;font-weight:600;margin:16px 0 6px}
.opt{color:var(--muted);font-weight:400}
input{width:100%;padding:13px 14px;font:inherit;color:inherit;background:var(--bg);
 border:1px solid var(--line);border-radius:12px}
input:focus{outline:2px solid var(--accent);outline-offset:1px;border-color:transparent}
button{width:100%;margin-top:22px;padding:14px;font:inherit;font-weight:700;color:#fff;
 background:var(--accent);border:0;border-radius:12px;cursor:pointer}
button:active{transform:translateY(1px)}
.badge{display:inline-block;background:var(--soft);color:var(--accent);border-radius:999px;
 padding:4px 12px;font-size:13px;font-weight:700;margin-bottom:14px}
.dl{margin:0;border-top:1px solid var(--line)}
.dl>div{display:flex;justify-content:space-between;gap:14px;padding:11px 0;
 border-bottom:1px solid var(--line);font-size:15px}
.dl span{color:var(--muted)}
.dl b{text-align:left;word-break:break-word}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.4px}
.note{margin-top:18px;padding:13px 15px;background:var(--soft);border-radius:12px;
 font-size:14px;color:var(--ink)}
.err{border-color:#E5484D;color:#E5484D;background:rgba(229,72,77,.06)}
.contacts{margin-top:22px;padding-top:18px;border-top:2px dashed var(--line)}
.contacts h2{font-size:15px;margin:0 0 12px}
.contacts a,.contacts div.c{display:flex;align-items:center;gap:10px;padding:11px 13px;
 margin-bottom:8px;background:var(--bg);border:1px solid var(--line);border-radius:12px;
 color:inherit;text-decoration:none;font-size:15px}
.contacts b{margin-inline-start:auto;font-weight:600}
.brand{text-align:center;color:var(--muted);font-size:13px;margin-top:22px}
@media print{body{background:#fff;padding:0}.noprint{display:none!important}
 .card{border:0;box-shadow:none}}
</style>${extraHead}</head><body><div class="wrap">${body}</div></body></html>`,
    { status: 200, headers: { "Content-Type": "text/html; charset=utf-8" } },
  );
}

const errPage = (msg: string) =>
  page("Janeiro", `<div class="card"><h1>تعذّر فتح الصفحة</h1>
    <p class="sub">${esc(msg)}</p>
    <div class="note">تواصل مع البائع الذي أرسل لك الرابط.</div></div>`);

/** الاستمارة: الزبون يكتب بياناته بنفسه. */
function formPage(token: string, d: {
  product_name: string; variant_name: string;
  fields: { label: string; is_required: boolean }[];
}): Response {
  const inputs = d.fields.map((f, i) => `
    <label for="f${i}">${esc(f.label)}${f.is_required ? "" : ' <span class="opt">(اختياري)</span>'}</label>
    <input id="f${i}" name="f${i}" ${f.is_required ? "required" : ""}
           autocomplete="off" placeholder="${esc(f.label)}">`).join("");

  return page("بياناتك — Janeiro", `<div class="card">
    <span class="badge">${esc(d.product_name)} — ${esc(d.variant_name)}</span>
    <h1>أدخل بياناتك</h1>
    <p class="sub">لتصدر لك وثيقة ضمان اشتراكك. تُملأ مرة واحدة.</p>
    <form method="POST" action="?fill=${encodeURIComponent(token)}">
      ${inputs}
      <button type="submit">إصدار الوثيقة</button>
    </form>
  </div><p class="brand">Janeiro</p>`);
}

/** الوثيقة: يحفظها الزبون أو يطبعها PDF، وتحتها قنوات التواصل. */
function certPage(c: Certificate & { contacts?: Contact[] }): Response {
  const rows = (c.customer ?? []).map((f) =>
    `<div><span>${esc(f.label)}</span><b>${esc(f.value)}</b></div>`).join("");

  const contacts = (c.contacts ?? []).map((k) => {
    const inner = `<span>${k.icon ? esc(k.icon) + " " : ""}${esc(k.label)}</span>` +
                  `<b>${esc(k.value)}</b>`;
    return k.url
      ? `<a href="${esc(k.url)}" target="_blank" rel="noopener">${inner}</a>`
      : `<div class="c">${inner}</div>`;
  }).join("");

  return page("وثيقة الضمان — Janeiro", `<div class="card">
    <span class="badge">وثيقة ضمان</span>
    <h1>${esc(c.product_name)} — ${esc(c.variant_name)}</h1>
    <p class="sub">${c.expired ? "انتهت مدة هذا الاشتراك."
      : c.days_left !== null ? `يتبقّى ${c.days_left} يوماً.` : "اشتراك سارٍ."}</p>
    <div class="dl">
      ${rows}
      <div><span>يبدأ</span><b class="mono">${day(c.starts_at)}</b></div>
      ${c.ends_at ? `<div><span>ينتهي</span><b class="mono">${day(c.ends_at)}</b></div>` : ""}
      <div><span>رمز التحقق</span><b class="mono">${esc(c.code)}</b></div>
    </div>
    <div class="note">احفظ هذه الصفحة أو خزّن الرابط. رمز التحقق أعلاه يثبت اشتراكك عند أي مراجعة.</div>
    ${contacts ? `<div class="contacts"><h2>للتواصل معنا</h2>${contacts}</div>` : ""}
    <button class="noprint" onclick="window.print()">حفظ أو طباعة PDF</button>
  </div><p class="brand">Janeiro</p>`);
}

// ------------------------------------------------------------
// الوثيقة: بعد التأكيد، تُجمع بيانات الزبون ثم تصدر
// ------------------------------------------------------------
type IssueFields = {
  fields: { label: string; is_required: boolean }[];
  duration_value: number | null;
  has_certificate: boolean;
};

/** يسأل عن الحقول، أو يصدر مباشرة إن لم يكن للمنتج حقول. */
async function afterConfirm(
  client: SupabaseClient, chat: number, tgId: number, issueId: string,
) {
  const f = await rpc<IssueFields>(client, "bot_issue_fields",
    { p_telegram_id: tgId, p_issue_id: issueId });
  if (f.error) return;                       // التأكيد نجح؛ الوثيقة إضافة
  const d = f.data!;
  if (d.has_certificate) return;

  if (d.fields.length) {
    // من يعبّي؟ الزبون أدقّ في يوزره ورقمه، والبائع أسرع إن كان
    // الزبون أمامه. الاثنان متاحان، وأول من يعبّي يُصدر الوثيقة.
    await send(chat, [
      "🧾 <b>بقيت بيانات الزبون</b>", "",
      "المطلوب: " + d.fields.map((x) =>
        `<b>${esc(x.label)}</b>${x.is_required ? "" : " (اختياري)"}`).join(" · "),
    ].join("\n"), [
      [{ text: "🔗 يعبّيها الزبون بنفسه", callback_data: `cl:${issueId}` }],
      [{ text: "✍️ أكتبها أنا", callback_data: `cf:${issueId}` }],
    ]);
    return;
  }

  // بلا حقول: إن كانت للمدة مدّة محسوبة فالوثيقة تُصدر بتاريخيها.
  if (d.duration_value === null) return;
  await issueCertificate(client, chat, tgId, issueId, []);
}

async function issueCertificate(
  client: SupabaseClient, chat: number, tgId: number,
  issueId: string, values: { label: string; value: string }[],
) {
  const r = await rpc<Certificate>(client, "bot_issue_certificate",
    { p_telegram_id: tgId, p_issue_id: issueId, p_values: values });
  if (r.error) { await send(chat, r.error, [backRow]); return; }

  await send(chat, certificateText(r.data!), [
    // النسخ يشمل الرمز وحده: هو ما يُراجَع به لاحقاً
    [{ text: "📋 نسخ رمز التحقق", copy_text: { text: r.data!.code } }],
    [{ text: "🛒 بيع أخرى", callback_data: "m:sell" }],
    backRow,
  ]);
  await send(chat, "⬆️ أعد توجيه الرسالة أعلاه للزبون — هي وثيقته.");
}

/** «أكتبها أنا»: يعرض الحقول مرقّمة ويطلب ردّاً. */
async function askCertificateFields(
  client: SupabaseClient, chat: number, tgId: number, issueId: string,
) {
  const f = await rpc<IssueFields>(client, "bot_issue_fields",
    { p_telegram_id: tgId, p_issue_id: issueId });
  if (f.error) { await send(chat, f.error); return; }
  const lines = f.data!.fields.map((x, i) =>
    `${i + 1}. ${esc(x.label)}${x.is_required ? "" : " <i>(اختياري)</i>"}`);
  await ask(chat, [
    `${CERT_PROMPT} — ${issueId}`, "",
    "ردّ على هذه الرسالة ببيانات الزبون، قيمة في كل سطر وبنفس الترتيب:",
    "", ...lines,
    "", "<i>سطر فارغ أو «-» يتخطّى حقلاً اختيارياً.</i>",
  ].join("\n"));
}

/** «يعبّيها الزبون»: رابط يُرسل له في سناب أو واتساب. */
async function sendFillLink(
  client: SupabaseClient, chat: number, tgId: number, issueId: string,
) {
  const r = await rpc<{ token: string; expires_at: string }>(
    client, "bot_fill_link", { p_telegram_id: tgId, p_issue_id: issueId, p_days: 7 });
  if (r.error) { await send(chat, r.error, [backRow]); return; }

  const link = `${SELF_URL}?fill=${r.data!.token}`;
  await send(chat, [
    "🔗 <b>رابط الزبون</b>", "",
    "أرسله له في سناب أو واتساب. يفتحه، يكتب بياناته، وتظهر له",
    "الوثيقة جاهزة للحفظ أو الطباعة.", "",
    `<code>${esc(link)}</code>`, "",
    `<i>صالح حتى ${day(r.data!.expires_at)}، ويُستعمل مرة واحدة.</i>`,
  ].join("\n"), [
    [{ text: "📋 نسخ الرابط", copy_text: { text: link } }],
    [{ text: "✍️ أكتبها أنا بدلاً منه", callback_data: `cf:${issueId}` }],
    backRow,
  ]);
}

/** ردّ البائع: قيمة في كل سطر، بترتيب الحقول المعروضة. */
async function certificateFromReply(
  client: SupabaseClient, chat: number, tgId: number, issueId: string, body: string,
) {
  const f = await rpc<IssueFields>(client, "bot_issue_fields",
    { p_telegram_id: tgId, p_issue_id: issueId });
  if (f.error) { await send(chat, f.error); return; }

  const lines = body.split("\n").map((l) => l.trim());
  const values = f.data!.fields
    .map((x, i) => ({ label: x.label, value: (lines[i] ?? "").replace(/^-+$/, "").trim() }))
    .filter((v) => v.value !== "");

  await issueCertificate(client, chat, tgId, issueId, values);
}

// ============================================================
// وثيقة التزام الخدمة — الفلو في البوت
//
//   /warranty  ->  المنصة  ->  المدة  ->  أيام الهدية  ->  معاينة
//                                          -> تأكيد فيُولَّد رابط
//
// الحالة في bot_wizard_state لا في نصّ الرسائل: أربع خطوات مع
// «تعديل» لا تتحمّلها حيلة force_reply.
// ============================================================
const WZ_BONUS_PROMPT    = "🎁 أيام الهدية";
const WZ_PLATFORM_PROMPT = "🏷 اسم المنصة";
const WZ_BONUS_RE    = new RegExp(`^${WZ_BONUS_PROMPT}`);
const WZ_PLATFORM_RE = new RegExp(`^${WZ_PLATFORM_PROMPT}`);

/** المدد المعروضة. القائمة هنا لأنها شكل أزرار لا بيانات عمل. */
const MONTH_CHOICES = [1, 3, 6, 12];
const BONUS_CHOICES = [0, 7, 14];

type Wizard = {
  awaiting: string | null;
  platform: string | null;
  months: number | null;
  bonus_days: number | null;
  ready: boolean;
  projected_start: string;
  projected_end: string | null;
};

/** يوم بصيغة عربية للبائع — الوثيقة نفسها تتبع لغة الزبون. */
const dayAr = (iso: string | null) => formatDate(iso, "ar");

function wizardText(w: Wizard): string {
  const line = (label: string, value: string | null) =>
    `${label}: ${value ? `<b>${esc(value)}</b>` : "<i>—</i>"}`;

  const out = ["🧾 <b>وثيقة التزام خدمة</b>", ""];
  out.push(line("المنصة", w.platform));
  out.push(line("المدة", w.months ? `${w.months} شهر` : null));
  out.push(line("أيام الهدية",
    w.bonus_days === null ? null : w.bonus_days === 0 ? "لا" : `${w.bonus_days}`));

  if (w.ready) {
    out.push("", `📅 يبدأ: <b>${dayAr(w.projected_start)}</b>`);
    out.push(`📅 ينتهي: <b>${dayAr(w.projected_end)}</b>`);
    out.push("", `<i>التغطية: ${esc(DOC.ar.duration(w.months!, w.bonus_days!))}</i>`);
    out.push("", "<i>البداية الحقيقية تُثبَّت لحظة تعبئة الزبون، لا الآن.</i>");
  } else {
    out.push("", ({
      platform:        "اختر المنصة:",
      months:          "اختر المدة:",
      bonus:           "أيام هدية؟",
      bonus_manual:    "أرسل عدد الأيام (0–90).",
      platform_manual: "أرسل اسم المنصة.",
    } as Record<string, string>)[w.awaiting ?? ""] ?? "");
  }
  return out.join("\n").trim();
}

async function wizardKeyboard(
  client: SupabaseClient, tgId: number, w: Wizard,
): Promise<Button[][]> {
  if (w.ready) {
    return [
      [{ text: "✅ تأكيد وتوليد الرابط", callback_data: "wz:ok" }],
      [{ text: "✏️ المنصة", callback_data: "wz:back_platform" },
       { text: "✏️ المدة",  callback_data: "wz:back_months" },
       { text: "✏️ الهدية", callback_data: "wz:back_bonus" }],
      [{ text: "✖️ إلغاء", callback_data: "wz:cancel" }],
    ];
  }

  const rows: Button[][] = [];
  if (w.awaiting === "platform") {
    const r = await rpc<{ name: string }[]>(client, "bot_platforms_list",
      { p_telegram_id: tgId });
    const names = r.data ?? [];
    // اثنتان في السطر: أسماء المنصات طويلة على هاتف
    for (let i = 0; i < names.length; i += 2) {
      rows.push(names.slice(i, i + 2).map((p) => ({
        text: p.name, callback_data: `wp:${p.name}`,
      })));
    }
    rows.push([{ text: "✏️ أخرى…", callback_data: "wz:platform_manual" }]);
  } else if (w.awaiting === "months") {
    rows.push(MONTH_CHOICES.map((m) => ({
      text: `${m} شهر`, callback_data: `wm:${m}`,
    })));
  } else if (w.awaiting === "bonus") {
    rows.push(BONUS_CHOICES.map((b) => ({
      text: b === 0 ? "لا" : `${b} أيام`, callback_data: `wb:${b}`,
    })));
    rows.push([{ text: "✏️ إدخال يدوي", callback_data: "wz:bonus_manual" }]);
  }
  rows.push([{ text: "✖️ إلغاء", callback_data: "wz:cancel" }]);
  return rows;
}

/** يرسم الخطوة الحالية: تعديل الرسالة نفسها إن كانت من زر. */
async function wizardRender(
  client: SupabaseClient, chat: number, tgId: number,
  w: Wizard, msg?: number,
) {
  const kb = await wizardKeyboard(client, tgId, w);
  if (msg) await edit(chat, msg, wizardText(w), kb);
  else      await send(chat, wizardText(w), kb);
}

async function wizardStep(
  client: SupabaseClient, chat: number, tgId: number,
  step: string, value: string, msg?: number,
) {
  const r = await rpc<Wizard>(client, "bot_wizard_set",
    { p_telegram_id: tgId, p_step: step, p_value: value });
  if (r.error) { await send(chat, r.error, [backRow]); return; }
  await wizardRender(client, chat, tgId, r.data!, msg);
}

/** التأكيد: الوثيقة معلّقة، والرابط جاهز للنسخ. */
async function wizardConfirm(
  client: SupabaseClient, chat: number, tgId: number, msg?: number,
) {
  const r = await rpc<{
    code: string; ref_code: string; token: string;
    platform: string; months: number; bonus_days: number; expires_at: string;
  }>(client, "bot_engagement_confirm", { p_telegram_id: tgId, p_hours: 72 });
  if (r.error) { await send(chat, r.error, [backRow]); return; }

  const d = r.data!;
  const link = claimUrl(d.token);
  const body = [
    "✅ <b>الوثيقة جاهزة</b>", "",
    `🏷 ${esc(d.platform)} — ${esc(DOC.ar.duration(d.months, d.bonus_days))}`,
    `🔖 ${esc(d.ref_code)}`, "",
    "أرسل هذا الرابط للزبون. يكتب اسمه ورقمه ويوزره، فتصدر له",
    "الوثيقة جاهزة للتحميل أو الطباعة.", "",
    `<code>${esc(link)}</code>`, "",
    `<i>صالح حتى ${dayAr(d.expires_at)} — 72 ساعة، ويُستعمل مرة واحدة.</i>`,
  ].join("\n");
  const kb: Button[][] = [
    [{ text: "📋 نسخ الرابط", copy_text: { text: link } }],
    [{ text: "🧾 وثيقة أخرى", callback_data: "wz:start" }],
    backRow,
  ];
  if (msg) await edit(chat, msg, body, kb); else await send(chat, body, kb);
}

// ------------------------------------------------------------
// الأوامر النصية
// ------------------------------------------------------------
async function handleCommand(
  client: SupabaseClient, chat: number, tgId: number, ident: Identity, text: string,
) {
  const isOwner = ident.role === "owner";
  // "/addcards giftcard year" ثم الأكواد في بقية الرسالة
  const [head, ...bodyLines] = text.split("\n");
  const parts = head.trim().split(/\s+/);
  const cmd   = parts[0].split("@")[0].toLowerCase();
  const args  = parts.slice(1);

  switch (cmd) {
    case "/start":
    case "/menu":
      await send(chat, homeText(ident.name ?? "", isOwner), mainMenu(isOwner));
      return;

    case "/help":
      await send(chat, HELP, [backRow]);
      return;

    case "/stock": {
      const cat = await catalog(client, tgId, false);
      await send(chat, cat.error ?? stockText(cat.data!), [backRow]);
      return;
    }

    case "/stats": {
      const r = await rpc<Stat[]>(client, "bot_breakdown",
        { p_telegram_id: tgId, p_scope: "me", p_target: null });
      await send(chat, r.error ?? statsText(r.data!, false), [backRow]);
      return;
    }

    case "/allstats": {
      const r = await rpc<Stat[]>(client, "bot_breakdown",
        { p_telegram_id: tgId, p_scope: "all", p_target: null });
      await send(chat, r.error ?? statsText(r.data!, true), [backRow]);
      return;
    }

    case "/breakdown": {
      const r = await rpc<{ product_name: string; variant_name: string;
                            confirmed: number; cancelled: number }[]>(
        client, "bot_sales_breakdown", { p_telegram_id: tgId });
      if (r.error) { await send(chat, r.error); return; }
      const rows = r.data!.filter((x) => x.confirmed || x.cancelled);
      await send(chat, rows.length
        ? ["📈 <b>المبيعات حسب المنتج</b>", "", ...rows.map((x) =>
            `• ${esc(x.product_name)} — ${esc(x.variant_name)}: ✅ ${x.confirmed} · ❌ ${x.cancelled}`)].join("\n")
        : "لا مبيعات بعد.", [backRow]);
      return;
    }

    case "/pending": {
      const r = await rpc<Pending[]>(client, "bot_pending", { p_telegram_id: tgId });
      if (r.error) { await send(chat, r.error); return; }
      await send(chat, pendingText(r.data!), pendingButtons(r.data!));
      return;
    }

    case "/id":
      await send(chat, `رقمك في تليجرام: <code>${tgId}</code>`);
      return;

    case "/cert": {
      if (!args[0]) { await send(chat, "الصيغة: <code>/cert JNR-XXXXXXXX</code>"); return; }
      const r = await rpc<Certificate>(client, "bot_certificate",
        { p_telegram_id: tgId, p_code: args[0] });
      await send(chat, r.error ?? certificateText(r.data!), [backRow]);
      return;
    }

    case "/find": {
      const q = args.join(" ");
      if (!q) { await send(chat, "الصيغة: <code>/find اسم أو يوزر أو رقم</code>"); return; }
      const r = await rpc<Certificate[]>(client, "bot_find_customer",
        { p_telegram_id: tgId, p_query: q });
      await send(chat, r.error ?? foundText(r.data!), [backRow]);
      return;
    }

    case "/expiring": {
      const d = args[0] === undefined || Number.isNaN(Number(args[0])) ? 7 : Number(args[0]);
      const r = await rpc<Expiring[]>(client, "bot_expiring",
        { p_telegram_id: tgId, p_days: d });
      await send(chat, r.error ?? expiringText(r.data!, d), [backRow]);
      return;
    }

    case "/warranty": {
      const r = await rpc<Wizard>(client, "bot_wizard_begin", { p_telegram_id: tgId });
      if (r.error) { await send(chat, r.error); return; }
      const w = await rpc<Wizard>(client, "bot_wizard_preview", { p_telegram_id: tgId });
      if (w.error) { await send(chat, w.error); return; }
      await wizardRender(client, chat, tgId, w.data!);
      return;
    }

    case "/platforms": {
      const r = await rpc<{ name: string }[]>(client, "bot_platforms_list",
        { p_telegram_id: tgId });
      if (r.error) { await send(chat, r.error); return; }
      await send(chat, ["🏷 <b>المنصات</b>", "",
        ...r.data!.map((p) => `• ${esc(p.name)}`), "",
        "إضافة: <code>/addplatform Prime Video</code>",
        "إخفاء: <code>/delplatform Prime Video</code>"].join("\n"), [backRow]);
      return;
    }

    case "/addplatform": {
      const name = text.slice(cmd.length).trim();
      if (!name) { await send(chat, "الصيغة: <code>/addplatform Prime Video</code>"); return; }
      const r = await rpc(client, "bot_add_platform",
        { p_telegram_id: tgId, p_name: name });
      await send(chat, r.error ?? `✅ أُضيفت «${esc(name)}» إلى أزرار المنصات.`, [backRow]);
      return;
    }

    case "/delplatform": {
      const name = text.slice(cmd.length).trim();
      if (!name) { await send(chat, "الصيغة: <code>/delplatform Prime Video</code>"); return; }
      const r = await rpc(client, "bot_remove_platform",
        { p_telegram_id: tgId, p_name: name });
      await send(chat, r.error ??
        `✅ أُخفيت «${esc(name)}». الوثائق الصادرة بها لا تتأثر.`, [backRow]);
      return;
    }

    case "/revoke": {
      if (!args[0]) { await send(chat, "الصيغة: <code>/revoke JW-XXXXXXXXXX</code>"); return; }
      const r = await rpc(client, "bot_engagement_revoke",
        { p_telegram_id: tgId, p_code: args[0] });
      await send(chat, r.error ?? `✅ أُبطلت <code>${esc(args[0].toUpperCase())}</code>.`,
        [backRow]);
      return;
    }

    case "/relink": {
      if (!args[0]) { await send(chat, "الصيغة: <code>/relink JW-XXXXXXXXXX</code>"); return; }
      const r = await rpc<{ code: string; token: string }>(client, "bot_engagement_relink",
        { p_telegram_id: tgId, p_code: args[0], p_hours: 72 });
      if (r.error) { await send(chat, r.error, [backRow]); return; }
      const link = claimUrl(r.data!.token);
      await send(chat, ["🔗 <b>رابط جديد</b>", "",
        "<i>الرابط القديم أُبطل، فلا رابطان لوثيقة واحدة.</i>", "",
        `<code>${esc(link)}</code>`].join("\n"),
        [[{ text: "📋 نسخ الرابط", copy_text: { text: link } }], backRow]);
      return;
    }

    case "/contacts": {
      const r = await rpc<Contact[]>(client, "bot_list_contacts", { p_telegram_id: tgId });
      if (r.error) { await send(chat, r.error); return; }
      const out = ["📇 <b>قنوات التواصل</b>", "",
                   "<i>تظهر أسفل وثيقة كل زبون.</i>", ""];
      if (!r.data!.length) out.push("لا شيء بعد.");
      for (const k of r.data!) {
        out.push(`${k.icon ?? "•"} <b>${esc(k.label)}</b>: ${esc(k.value)}` +
                 (k.url ? `\n   <code>${esc(k.url)}</code>` : ""));
      }
      out.push("", "الإضافة — الأجزاء مفصولة بـ <code>|</code>:",
        "<code>/addcontact سناب شات | janeiro_store | https://snapchat.com/add/janeiro_store</code>",
        "<code>/addcontact الهاتف | 0550112233</code>",
        "<code>/addcontact تليجرام | @janeiro | https://t.me/janeiro</code>",
        "الحذف: <code>/delcontact سناب شات</code>");
      await send(chat, out.join("\n"), [backRow]);
      return;
    }

    case "/addcontact": {
      // الفصل بـ | لا بمسافة: التسميات عربية وفيها مسافات
      const parts = text.slice(cmd.length).split("|").map((x) => x.trim());
      if (parts.length < 2 || !parts[0] || !parts[1]) {
        await send(chat, "الصيغة:\n<code>/addcontact سناب شات | janeiro_store | " +
                         "https://snapchat.com/add/janeiro_store</code>\n\n" +
                         "الرابط اختياري. نفس التسمية تُحدَّث ولا تتكرّر.");
        return;
      }
      const r = await rpc(client, "bot_add_contact", {
        p_telegram_id: tgId, p_label: parts[0], p_value: parts[1],
        p_url: parts[2] || null, p_icon: parts[3] || null,
      });
      await send(chat, r.error ??
        `✅ حُفظت «${esc(parts[0])}». ستظهر أسفل وثيقة كل زبون.`, [backRow]);
      return;
    }

    case "/delcontact": {
      const label = text.slice(cmd.length).trim();
      if (!label) { await send(chat, "الصيغة: <code>/delcontact سناب شات</code>"); return; }
      const r = await rpc(client, "bot_remove_contact",
        { p_telegram_id: tgId, p_label: label });
      await send(chat, r.error ?? "✅ حُذفت.", [backRow]);
      return;
    }

    case "/fields": {
      const r = await rpc<{ product_code: string; product: string;
                            fields: { label: string; is_required: boolean }[] }[]>(
        client, "bot_fields_of", { p_telegram_id: tgId });
      if (r.error) { await send(chat, r.error); return; }
      const out = ["🧾 <b>بيانات الزبون المطلوبة لكل منتج</b>", ""];
      for (const p of r.data!) {
        out.push(`<b>${esc(p.product)}</b>  <code>${esc(p.product_code)}</code>`);
        if (!p.fields.length) out.push("   (لا حقول — الوثيقة تصدر بالتواريخ فقط)");
        for (const f of p.fields) {
          out.push(`   • ${esc(f.label)}${f.is_required ? "" : " (اختياري)"}`);
        }
        out.push("");
      }
      out.push("إضافة: <code>/addfield insta يوزر الأنستا</code>",
               "اختياري: <code>/addfield insta رقم الهاتف optional</code>",
               "حذف: <code>/delfield insta يوزر الأنستا</code>");
      await send(chat, out.join("\n"), [backRow]);
      return;
    }

    case "/addfield": {
      if (args.length < 2) {
        await send(chat, "الصيغة: <code>/addfield insta يوزر الأنستا</code>\n" +
                         "لجعله اختيارياً أضف <code>optional</code> في آخره.");
        return;
      }
      // الكلمة الأخيرة optional تعني حقلاً غير مطلوب
      const optional = args[args.length - 1].toLowerCase() === "optional";
      const label = args.slice(1, optional ? -1 : undefined).join(" ");
      const r = await rpc(client, "bot_add_field", {
        p_telegram_id: tgId, p_product_code: args[0],
        p_label: label, p_required: !optional,
      });
      await send(chat, r.error ??
        `✅ أُضيف «${esc(label)}». سيُسأل عنه البائع بعد كل تأكيد لهذا المنتج.`,
        [backRow]);
      return;
    }

    case "/delfield": {
      if (args.length < 2) {
        await send(chat, "الصيغة: <code>/delfield insta يوزر الأنستا</code>"); return;
      }
      const r = await rpc(client, "bot_remove_field", {
        p_telegram_id: tgId, p_product_code: args[0], p_label: args.slice(1).join(" "),
      });
      await send(chat, r.error ??
        "✅ حُذف الحقل. الوثائق الصادرة لا تتأثر — بياناتها محفوظة فيها.", [backRow]);
      return;
    }

    case "/admins": {
      const r = await rpc<{ telegram_id: number; name: string; role: string;
                            is_active: boolean; confirmed: number }[]>(
        client, "bot_list_admins", { p_telegram_id: tgId });
      if (r.error) { await send(chat, r.error); return; }
      await send(chat, ["👥 <b>الأدمن</b>", "", ...r.data!.map((a) =>
        `${a.role === "owner" ? "👑" : "•"} <b>${esc(a.name)}</b> — <code>${a.telegram_id}</code>` +
        `${a.is_active ? "" : " (معطّل)"} · ✅ ${a.confirmed}`)].join("\n"), [backRow]);
      return;
    }

    case "/addadmin": {
      const id = Number(args[0]);
      if (!Number.isInteger(id) || id <= 0) {
        await send(chat, "الصيغة: <code>/addadmin 123456789 الاسم</code>\n" +
                         "ليعرف الشخص رقمه، يفتح البوت ويرسل /id");
        return;
      }
      const r = await rpc(client, "bot_add_admin",
        { p_telegram_id: tgId, p_new_telegram_id: id, p_name: args.slice(1).join(" ") || null });
      await send(chat, r.error ?? `✅ أُضيف <code>${id}</code> كأدمن. ليبدأ، يفتح البوت ويرسل /start`,
        [backRow]);
      return;
    }

    case "/deladmin": {
      const id = Number(args[0]);
      if (!Number.isInteger(id) || id <= 0) {
        await send(chat, "الصيغة: <code>/deladmin 123456789</code>"); return;
      }
      const r = await rpc(client, "bot_remove_admin",
        { p_telegram_id: tgId, p_target_telegram_id: id });
      await send(chat, r.error ??
        `✅ عُطِّل <code>${id}</code>. بطاقاته المعلّقة رجعت للمخزون، ومبيعاته السابقة محفوظة.`,
        [backRow]);
      return;
    }

    case "/addproduct": {
      if (args.length < 2) {
        await send(chat, "الصيغة: <code>/addproduct netflix نتفليكس</code>\n" +
                         "الرمز بحروف لاتينية صغيرة بلا مسافات، والاسم كما يظهر في الأزرار.");
        return;
      }
      const r = await rpc(client, "bot_add_product",
        { p_telegram_id: tgId, p_code: args[0], p_name: args.slice(1).join(" ") });
      await send(chat, r.error ??
        `✅ أُضيف المنتج. الآن أضف مدده:\n<code>/addvariant ${esc(args[0].toLowerCase())} year سنة</code>`,
        [backRow]);
      return;
    }

    case "/addvariant": {
      if (args.length < 3) {
        await send(chat, "الصيغة: <code>/addvariant netflix 6months 6 أشهر</code>"); return;
      }
      const r = await rpc(client, "bot_add_variant", {
        p_telegram_id: tgId, p_product_code: args[0],
        p_code: args[1], p_name: args.slice(2).join(" "),
      });
      await send(chat, r.error ??
        `✅ أُضيفت المدة. اشحنها بـ:\n<code>/addcards ${esc(args[0].toLowerCase())} ` +
        `${esc(args[1].toLowerCase())}\nCODE-1\nCODE-2</code>`, [backRow]);
      return;
    }

    case "/addcards": {
      if (args.length < 2) {
        await send(chat, "الصيغة — الأمر في سطر والأكواد بعده سطراً سطراً:\n" +
                         "<code>/addcards giftcard year\nCODE-1\nCODE-2</code>");
        return;
      }
      await loadCards(client, chat, tgId, args[0], args[1],
                      parseCodes([...args.slice(2), ...bodyLines].join("\n")));
      return;
    }

    default:
      await send(chat, "أمر غير معروف. /help لكل الأوامر.", mainMenu(isOwner));
  }
}

function pendingButtons(rows: Pending[]): Button[][] {
  const out: Button[][] = rows.slice(0, 8).map((p) => [
    { text: `✅ ${p.card_code.slice(0, 18)}`, callback_data: `ok:${p.issue_id}` },
    { text: "❌", callback_data: `no:${p.issue_id}` },
  ]);
  out.push(backRow);
  return out;
}

// ------------------------------------------------------------
// الأزرار
// ------------------------------------------------------------
async function handleCallback(
  client: SupabaseClient, chat: number, msg: number, tgId: number,
  ident: Identity, data: string, cbId: string,
) {
  const isOwner = ident.role === "owner";
  const [verb, arg] = [data.slice(0, data.indexOf(":")), data.slice(data.indexOf(":") + 1)];

  // ---------- القوائم ----------
  if (verb === "m") {
    switch (arg) {
      case "home":
        await answer(cbId);
        await edit(chat, msg, homeText(ident.name ?? "", isOwner), mainMenu(isOwner));
        return;

      case "sell":
      case "load": {
        const loading = arg === "load";
        if (loading && !isOwner) { await answer(cbId, ERRORS.NOT_OWNER, true); return; }
        const cat = await catalog(client, tgId, !loading);
        if (cat.error) { await answer(cbId, cat.error, true); return; }
        const products = cat.data!;
        await answer(cbId);
        if (!products.length) {
          await edit(chat, msg, "لا يوجد أي منتج بعد. أضف واحداً بـ /addproduct", [backRow]);
          return;
        }
        // منتج واحد فقط؟ لا معنى لخطوة اختيار بينه وبين نفسه.
        if (products.length === 1) {
          await showVariants(chat, msg, products[0], loading);
          return;
        }
        await edit(chat, msg, loading ? "اختر المنتج لشحنه:" : "اختر المنتج:", [
          ...products.map((p) => [{
            text: p.name, callback_data: `${loading ? "lp" : "p"}:${p.product_id}`,
          }]),
          backRow,
        ]);
        return;
      }

      case "exp": {
        const r = await rpc<Expiring[]>(client, "bot_expiring",
          { p_telegram_id: tgId, p_days: 7 });
        if (r.error) { await answer(cbId, r.error, true); return; }
        await answer(cbId);
        await edit(chat, msg, expiringText(r.data!, 7), [
          [{ text: "اليوم", callback_data: "exp:0" },
           { text: "30 يوماً", callback_data: "exp:30" },
           { text: "90 يوماً", callback_data: "exp:90" }],
          backRow,
        ]);
        return;
      }

      case "find":
        await answer(cbId);
        await ask(chat, `${FIND_PROMPT}\n\n` +
          "ردّ على هذه الرسالة باسم الزبون أو يوزره أو رقم هاتفه أو رمز وثيقته.");
        return;

      case "stock": {
        const cat = await catalog(client, tgId, false);
        await answer(cbId);
        await edit(chat, msg, cat.error ?? stockText(cat.data!), [backRow]);
        return;
      }

      case "stats":
      case "all": {
        const all = arg === "all";
        const r = await rpc<Stat[]>(client, "bot_breakdown",
          { p_telegram_id: tgId, p_scope: all ? "all" : "me", p_target: null });
        if (r.error) { await answer(cbId, r.error, true); return; }
        await answer(cbId);
        await edit(chat, msg, statsText(r.data!, all), [backRow]);
        return;
      }

      case "pending": {
        const r = await rpc<Pending[]>(client, "bot_pending", { p_telegram_id: tgId });
        if (r.error) { await answer(cbId, r.error, true); return; }
        await answer(cbId);
        await edit(chat, msg, pendingText(r.data!), pendingButtons(r.data!));
        return;
      }

      case "admins": {
        const r = await rpc<{ telegram_id: number; name: string; role: string;
                              is_active: boolean; confirmed: number }[]>(
          client, "bot_list_admins", { p_telegram_id: tgId });
        if (r.error) { await answer(cbId, r.error, true); return; }
        await answer(cbId);
        // كل أدمن زر: الضغط عليه يفتح ماذا باع بالضبط وكم من كل مدة
        const rows: Button[][] = r.data!.map((a) => [{
          text: `${a.role === "owner" ? "👑" : "👤"} ${a.name} — ✅ ${a.confirmed}`,
          callback_data: `adm:${a.telegram_id}`,
        }]);
        await edit(chat, msg, ["👥 <b>الأدمن</b>", "", ...r.data!.map((a) =>
          `${a.role === "owner" ? "👑" : "•"} <b>${esc(a.name)}</b> — <code>${a.telegram_id}</code>` +
          `${a.is_active ? "" : " (معطّل)"} · ✅ ${a.confirmed}`),
          "", "اضغط على أحدهم لترى ماذا باع بالتفصيل.",
          "لإضافة أدمن: <code>/addadmin رقمه الاسم</code>",
          "لتعطيله: <code>/deladmin رقمه</code>"].join("\n"), [...rows, backRow]);
        return;
      }
    }
    await answer(cbId);
    return;
  }

  // ---------- وثيقة التزام الخدمة ----------
  if (verb === "wz") {
    if (arg === "start") {
      await answer(cbId);
      const b = await rpc<Wizard>(client, "bot_wizard_begin", { p_telegram_id: tgId });
      if (b.error) { await answer(cbId, b.error, true); return; }
      const w = await rpc<Wizard>(client, "bot_wizard_preview", { p_telegram_id: tgId });
      if (!w.error) await wizardRender(client, chat, tgId, w.data!);
      return;
    }
    if (arg === "cancel") {
      await answer(cbId, "أُلغي");
      await rpc(client, "bot_wizard_cancel", { p_telegram_id: tgId });
      await edit(chat, msg, "✖️ أُلغيت الوثيقة.", mainMenu(isOwner));
      return;
    }
    if (arg === "ok") { await answer(cbId); await wizardConfirm(client, chat, tgId, msg); return; }

    // الإدخال اليدوي: سؤال بردّ إجباري، والحالة في القاعدة لا في نصّه
    if (arg === "bonus_manual" || arg === "platform_manual") {
      await answer(cbId);
      const r = await rpc<Wizard>(client, "bot_wizard_set",
        { p_telegram_id: tgId, p_step: arg, p_value: "" });
      if (r.error) { await answer(cbId, r.error, true); return; }
      await ask(chat, arg === "bonus_manual"
        ? `${WZ_BONUS_PROMPT}\n\nردّ على هذه الرسالة بعدد الأيام (0–90).`
        : `${WZ_PLATFORM_PROMPT}\n\nردّ على هذه الرسالة باسم المنصة.`);
      return;
    }

    // back_platform / back_months / back_bonus
    await answer(cbId);
    await wizardStep(client, chat, tgId, arg, "", msg);
    return;
  }

  if (verb === "wp") { await answer(cbId); await wizardStep(client, chat, tgId, "platform", arg, msg); return; }
  if (verb === "wm") { await answer(cbId); await wizardStep(client, chat, tgId, "months",   arg, msg); return; }
  if (verb === "wb") { await answer(cbId); await wizardStep(client, chat, tgId, "bonus",    arg, msg); return; }

  // ---------- بيانات الزبون: من يعبّيها ----------
  if (verb === "cf") { await answer(cbId); await askCertificateFields(client, chat, tgId, arg); return; }
  if (verb === "cl") { await answer(cbId); await sendFillLink(client, chat, tgId, arg); return; }

  // ---------- مدى أطول لقائمة «تنتهي قريباً» ----------
  if (verb === "exp") {
    // Number(arg) || 7 كان يبتلع الصفر ويحوّل «اليوم» إلى أسبوع
    const d = arg === "" || Number.isNaN(Number(arg)) ? 7 : Number(arg);
    const r = await rpc<Expiring[]>(client, "bot_expiring",
      { p_telegram_id: tgId, p_days: d });
    if (r.error) { await answer(cbId, r.error, true); return; }
    await answer(cbId);
    await edit(chat, msg, expiringText(r.data!, d), [
      [{ text: "اليوم", callback_data: "exp:0" },
       { text: "7 أيام", callback_data: "exp:7" },
       { text: "30 يوماً", callback_data: "exp:30" },
       { text: "90 يوماً", callback_data: "exp:90" }],
      backRow,
    ]);
    return;
  }

  // ---------- تفصيل مبيعات أدمن بعينه (للمالك) ----------
  if (verb === "adm") {
    const r = await rpc<Stat[]>(client, "bot_breakdown",
      { p_telegram_id: tgId, p_scope: "me", p_target: Number(arg) });
    if (r.error) { await answer(cbId, r.error, true); return; }
    await answer(cbId);
    const who = r.data![0];
    await edit(chat, msg,
      who ? statsText(r.data!, false, `📊 <b>مبيعات ${esc(who.name)}</b>`)
          : "لا مبيعات لهذا الأدمن بعد.",
      [[{ text: "⬅️ الأدمن", callback_data: "m:admins" }], backRow]);
    return;
  }

  // ---------- اختيار منتج -> مدده ----------
  if (verb === "p" || verb === "lp") {
    const loading = verb === "lp";
    if (loading && !isOwner) { await answer(cbId, ERRORS.NOT_OWNER, true); return; }
    const cat = await catalog(client, tgId, !loading);
    if (cat.error) { await answer(cbId, cat.error, true); return; }
    const p = cat.data!.find((x) => x.product_id === arg);
    if (!p) { await answer(cbId, "هذا المنتج لم يعد موجوداً.", true); return; }
    await answer(cbId);
    await showVariants(chat, msg, p, loading);
    return;
  }

  // ---------- اختيار مدة -> شحن ----------
  if (verb === "lv") {
    if (!isOwner) { await answer(cbId, ERRORS.NOT_OWNER, true); return; }
    const cat = await catalog(client, tgId, false);
    if (cat.error) { await answer(cbId, cat.error, true); return; }
    let found: { p: Product; v: Variant } | null = null;
    for (const p of cat.data!) {
      const v = p.variants.find((x) => x.variant_id === arg);
      if (v) { found = { p, v }; break; }
    }
    if (!found) { await answer(cbId, ERRORS.VARIANT_NOT_FOUND, true); return; }
    await answer(cbId);
    await ask(chat, `${LOAD_PROMPT} — ${esc(found.p.code)} / ${esc(found.v.code)}\n\n` +
      `<b>${esc(found.p.name)} — ${esc(found.v.name)}</b>\n` +
      "ردّ على هذه الرسالة بالأكواد، كوداً في كل سطر.");
    return;
  }

  // ---------- اختيار مدة -> بيع ----------
  if (verb === "v") {
    const r = await rpc<{
      issue_id: string; card_code: string; card_note: string | null;
      product_name: string; variant_name: string; remaining: number;
    }>(client, "bot_request_card", { p_telegram_id: tgId, p_variant_id: arg });
    if (r.error) { await answer(cbId, r.error, true); return; }
    await answer(cbId, "تم حجز بطاقة");
    // رسالة جديدة لا تعديل: تبقى القائمة في مكانها ليبيع مرة أخرى.
    await send(chat, issueText(r.data!), issueButtons(r.data!.issue_id, r.data!.card_code));
    return;
  }

  // ---------- تأكيد ----------
  if (verb === "ok") {
    const r = await rpc<{
      card_code: string; product_name: string; variant_name: string;
      customer_ref: string | null; seller_sales: number;
      seller_sales_of_variant: number; remaining: number;
    }>(client, "bot_confirm_issue", { p_telegram_id: tgId, p_issue_id: arg });
    if (r.error) { await answer(cbId, r.error, true); return; }
    const d = r.data!;
    await answer(cbId, `✅ ${d.variant_name}`);
    await edit(chat, msg, [
      "✅ <b>عملية ناجحة</b>", "",
      // ماذا بيع، لا الكود وحده: البائع يغلق عشر عمليات في اليوم
      // ولا يميّز بينها من كود مجرّد.
      `🎟 <b>${esc(d.product_name)} — ${esc(d.variant_name)}</b>`,
      `<code>${esc(d.card_code)}</code>`,
      ...(d.customer_ref ? [`👤 ${esc(d.customer_ref)}`] : []),
      "",
      `بعت من «${esc(d.variant_name)}»: <b>${d.seller_sales_of_variant}</b>`,
      `إجمالي مبيعاتك: <b>${d.seller_sales}</b>`,
      `المتبقي في المخزون: ${d.remaining}`,
    ].join("\n"), [
      [{ text: "📋 نسخ الكود", copy_text: { text: d.card_code } }],
      // «تمت العملية» يفتح الوثيقة كذلك، كما طُلب — لا /warranty وحده
      [{ text: "🧾 وثيقة التزام", callback_data: "wz:start" }],
      [{ text: "🛒 بيع أخرى", callback_data: "m:sell" }],
      backRow,
    ]);
    // ثم الوثيقة: يسأل عن بيانات الزبون، أو يصدرها فوراً إن لم
    // يكن للمنتج حقول. البيعة مثبتة أصلاً، فتعثّر الوثيقة لا يمسّها.
    await afterConfirm(client, chat, tgId, arg);
    return;
  }

  // ---------- إلغاء ----------
  if (verb === "no") {
    const r = await rpc<{
      product_name: string; variant_name: string; remaining: number;
    }>(client, "bot_cancel_issue", { p_telegram_id: tgId, p_issue_id: arg });
    if (r.error) { await answer(cbId, r.error, true); return; }
    const d = r.data!;
    await answer(cbId, "❌ أُلغيت");
    // الكود يُمحى من الرسالة: البطاقة رجعت للمخزون وقد تُسلَّم
    // لزبون آخر، فلا تبقى معروضة في محادثة قديمة. واسم المدة يبقى
    // ليعرف البائع أيّ عملية أُلغيت.
    await edit(chat, msg, [
      "❌ <b>عملية ملغاة</b>", "",
      `🎟 ${esc(d.product_name)} — ${esc(d.variant_name)}`, "",
      "رجعت البطاقة إلى المخزون ولم تُحسب لك.",
      `المتاح الآن: <b>${d.remaining}</b>`,
    ].join("\n"), [[{ text: "🛒 بيع أخرى", callback_data: "m:sell" }], backRow]);
    return;
  }

  await answer(cbId);
}

async function showVariants(chat: number, msg: number, p: Product, loading: boolean) {
  if (!p.variants.length) {
    await edit(chat, msg,
      `«${esc(p.name)}» بلا مدد بعد.\n<code>/addvariant ${esc(p.code)} year سنة</code>`, [backRow]);
    return;
  }
  const rows = p.variants.map((v) => [{
    text: loading ? `${v.name} (${v.available})`
                  : `${v.name} — ${v.available > 0 ? `${v.available} متاحة` : "نفدت"}`,
    callback_data: `${loading ? "lv" : "v"}:${v.variant_id}`,
  }]);
  await edit(chat, msg,
    loading ? `📥 <b>${esc(p.name)}</b> — اختر المدة لشحنها:`
            : `<b>${esc(p.name)}</b> — اختر المدة:`,
    [...rows, backRow]);
}

// ============================================================
// المدخل
// ============================================================
/** أخطاء الروابط -> عربية للزبون، لا للبائع. */
const LINK_ERRORS: Record<string, string> = {
  LINK_NOT_FOUND: "هذا الرابط غير صحيح.",
  LINK_USED:      "عُبِّئت البيانات من هذا الرابط مسبقاً.",
  LINK_EXPIRED:   "انتهت صلاحية هذا الرابط.",
  CERTIFICATE_NOT_FOUND: "لا توجد وثيقة بهذا الرمز.",
  CERTIFICATE_EXISTS: "صدرت الوثيقة لهذه العملية مسبقاً.",
};
const linkError = (raw: string): string =>
  LINK_ERRORS[raw.split(":")[0].trim().replace(/[^A-Z_]/g, "")] ?? "تعذّر إتمام الطلب.";

/**
 * صفحات الزبون. لا تمرّ بالترويسة السرّية — الزبون ليس تليجرام
 * ولا يملكها. ما يحرسها الرمز في الرابط نفسه، ولذلك تُفصل بمعامل
 * صريح في العنوان: لا يمكن لطلب استمارة أن يُقرأ كتحديث تليجرام
 * ولا العكس.
 */
async function customerRoute(req: Request, url: URL): Promise<Response | null> {
  const fill = url.searchParams.get("fill");
  const cert = url.searchParams.get("cert");
  if (!fill && !cert) return null;

  const client = db();

  if (cert) {
    const { data, error } = await client.rpc("bot_public_certificate", { p_code: cert });
    if (error) return errPage(linkError(String(error.message ?? "")));
    return certPage(data as Certificate & { contacts: Contact[] });
  }

  if (req.method === "GET") {
    const { data, error } = await client.rpc("bot_fill_form", { p_token: fill });
    if (error) return errPage(linkError(String(error.message ?? "")));
    return formPage(fill!, data as {
      product_name: string; variant_name: string;
      fields: { label: string; is_required: boolean }[];
    });
  }

  if (req.method === "POST") {
    // الحقول تصل بترتيبها f0, f1, … كما بنتها formPage
    const form = await req.formData().catch(() => null);
    if (!form) return errPage("تعذّر قراءة البيانات.");

    const shape = await client.rpc("bot_fill_form", { p_token: fill });
    if (shape.error) return errPage(linkError(String(shape.error.message ?? "")));
    const fields = (shape.data as { fields: { label: string }[] }).fields;

    const values = fields
      .map((f, i) => ({ label: f.label, value: String(form.get(`f${i}`) ?? "").trim() }))
      .filter((v) => v.value !== "");

    const { data, error } = await client.rpc("bot_fill_submit",
      { p_token: fill, p_values: values });
    if (error) return errPage(linkError(String(error.message ?? "")));

    const c = data as Certificate & { seller_telegram_id: number };

    // البائع يعرف أن زبونه عبّأ، بلا أن يسأل
    await send(Number(c.seller_telegram_id), [
      "✅ <b>الزبون عبّأ بياناته</b>", "",
      `🎟 ${esc(c.product_name)} — ${esc(c.variant_name)}`,
      ...(c.customer ?? []).map((f) => `${esc(f.label)}: <b>${esc(f.value)}</b>`),
      "", `🔖 <code>${esc(c.code)}</code>`,
    ].join("\n"));

    const full = await client.rpc("bot_public_certificate", { p_code: c.code });
    return certPage((full.data ?? c) as Certificate & { contacts: Contact[] });
  }

  return errPage("طلب غير مدعوم.");
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  // صفحات الزبون أولاً: لها مفتاحها الخاص في العنوان.
  const customer = await customerRoute(req, url).catch((e) => {
    console.error("customer route failed", e);
    return errPage("حدث خطأ غير متوقع.");
  });
  if (customer) return customer;

  if (req.method !== "POST") return new Response("ok");

  // الترويسة السرّية هي كل الحماية: بدونها يستطيع أي أحد يعرف
  // رابط الدالة أن ينتحل رقم أدمن ويفرّغ المخزون. فإن لم تُضبط،
  // لا يعمل البوت أصلاً — الفشل مغلق لا مفتوح.
  if (!TG_SECRET) {
    console.error("TELEGRAM_WEBHOOK_SECRET is not set — refusing every update");
    return new Response("not configured", { status: 503 });
  }
  if (req.headers.get("x-telegram-bot-api-secret-token") !== TG_SECRET) {
    return new Response("forbidden", { status: 401 });
  }
  if (!TG_TOKEN) {
    console.error("TELEGRAM_BOT_TOKEN is not set");
    return new Response("not configured", { status: 503 });
  }

  let update: {
    message?: {
      chat: { id: number };
      from?: { id: number; username?: string; first_name?: string; last_name?: string };
      text?: string;
      reply_to_message?: { text?: string };
    };
    callback_query?: {
      id: string;
      data?: string;
      from: { id: number; username?: string; first_name?: string; last_name?: string };
      message?: { chat: { id: number }; message_id: number };
    };
  };
  try {
    update = await req.json();
  } catch {
    return new Response("bad request", { status: 400 });
  }

  // من هنا فصاعداً نردّ 200 دائماً: خطأ عندنا لا يجعل تليجرام
  // يعيد إرسال نفس التحديث إلى الأبد.
  try {
    const client = db();
    const src = update.callback_query?.from ?? update.message?.from;
    const chat = update.callback_query?.message?.chat.id ?? update.message?.chat.id;
    if (!src || !chat) return new Response("ok");

    const name = [src.first_name, src.last_name].filter(Boolean).join(" ");
    const ident = await identify(client, src.id, src.username, name);

    if (!ident.known || !ident.active) {
      // لا نقول له شيئاً عن المخزون ولا عن وجود بوت أصلاً أكثر
      // من هذا؛ ورقمه معروض ليعطيه للمالك إن كان يُفترض دخوله.
      if (update.callback_query) await answer(update.callback_query.id, ERRORS.NOT_AUTHORIZED, true);
      else await send(chat, `${ERRORS.NOT_AUTHORIZED}\nرقمك: <code>${src.id}</code>`);
      return new Response("ok");
    }

    if (update.callback_query?.data && update.callback_query.message) {
      await handleCallback(
        client, chat, update.callback_query.message.message_id, src.id,
        ident, update.callback_query.data, update.callback_query.id,
      );
      return new Response("ok");
    }

    const text = update.message?.text?.trim();
    if (!text) return new Response("ok");

    // ردّ على سؤال «شحن أكواد»؟ الرمزان في نصّ السؤال نفسه.
    const replied = update.message?.reply_to_message?.text ?? "";

    const m = replied.match(LOAD_RE);
    if (m) {
      await loadCards(client, chat, src.id, m[1], m[2], parseCodes(text));
      return new Response("ok");
    }

    const c = replied.match(CERT_RE);
    if (c) {
      await certificateFromReply(client, chat, src.id, c[1], text);
      return new Response("ok");
    }

    if (WZ_BONUS_RE.test(replied)) {
      await wizardStep(client, chat, src.id, "bonus", text);
      return new Response("ok");
    }
    if (WZ_PLATFORM_RE.test(replied)) {
      await wizardStep(client, chat, src.id, "platform", text);
      return new Response("ok");
    }

    if (replied.startsWith(FIND_PROMPT)) {
      const r = await rpc<Certificate[]>(client, "bot_find_customer",
        { p_telegram_id: src.id, p_query: text });
      await send(chat, r.error ?? foundText(r.data!), [backRow]);
      return new Response("ok");
    }

    if (text.startsWith("/")) {
      await handleCommand(client, chat, src.id, ident, text);
    } else {
      await send(chat, "اختر من القائمة، أو /help لكل الأوامر.",
                 mainMenu(ident.role === "owner"));
    }
  } catch (err) {
    console.error("telegram-bot handler failed", err);
  }
  return new Response("ok");
});
