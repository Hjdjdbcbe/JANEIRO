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

const TG_TOKEN   = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
const TG_SECRET  = Deno.env.get("TELEGRAM_WEBHOOK_SECRET") ?? "";
const OWNER_ID   = Number(Deno.env.get("TELEGRAM_OWNER_ID") ?? "0");
// api.telegram.org في التشغيل الحقيقي. المتغيّر موجود ليستطيع
// tests/local/bot-e2e.test.js توجيه النداءات إلى خادم وهمي
// ويفحص ما أرسله البوت فعلاً — لا يُضبط في الإنتاج.
const API_BASE   = Deno.env.get("TELEGRAM_API_BASE") ?? "https://api.telegram.org";
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
type Button = { text: string; callback_data: string };

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
  INVALID_KIND:          "نوع غير معروف.",
};

function human(err: unknown): string {
  const raw  = String((err as { message?: string })?.message ?? err ?? "");
  const code = raw.split(":")[0].trim().replace(/[^A-Z_]/g, "");
  if (code === "PENDING_LIMIT") {
    const n = raw.split(":")[1]?.trim();
    return n ? `الحد ${n} عمليات معلّقة. أغلق واحدة بتأكيد أو إلغاء أولاً.` : ERRORS.PENDING_LIMIT;
  }
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

type Stat = {
  telegram_id: number; name: string; role: string; is_active: boolean;
  confirmed: number; cancelled: number; pending: number; today: number; this_month: number;
};

function statsText(rows: Stat[], all: boolean): string {
  if (!rows.length) return "لا مبيعات بعد.";
  if (!all) {
    const s = rows[0];
    return [
      "📊 <b>مبيعاتك</b>", "",
      `✅ عمليات ناجحة: <b>${s.confirmed}</b>`,
      `📅 اليوم: <b>${s.today}</b>`,
      `🗓 هذا الشهر: <b>${s.this_month}</b>`,
      `❌ ملغاة: ${s.cancelled}`,
      `⏳ معلّقة الآن: ${s.pending}`,
    ].join("\n");
  }
  const out = ["🏆 <b>مبيعات كل الأدمن</b>", ""];
  rows.forEach((s, i) => {
    const medal = ["🥇", "🥈", "🥉"][i] ?? `${i + 1}.`;
    out.push(`${medal} <b>${esc(s.name)}</b>${s.is_active ? "" : " (معطّل)"}`);
    out.push(`     ✅ ${s.confirmed} · اليوم ${s.today} · الشهر ${s.this_month}` +
             ` · ❌ ${s.cancelled} · ⏳ ${s.pending}`);
  });
  const total = rows.reduce((n, s) => n + s.confirmed, 0);
  out.push("", `الإجمالي: <b>${total}</b> عملية ناجحة`);
  return out.join("\n");
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

const issueButtons = (id: string): Button[][] => [[
  { text: "✅ تأكيد", callback_data: `ok:${id}` },
  { text: "❌ إلغاء", callback_data: `no:${id}` },
]];

const HELP = [
  "<b>الأوامر</b>", "",
  "/menu — القائمة",
  "/stock — المخزون",
  "/stats — مبيعاتك",
  "/pending — عملياتك المعلّقة",
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
      const r = await rpc<Stat[]>(client, "bot_stats", { p_telegram_id: tgId, p_scope: "me" });
      await send(chat, r.error ?? statsText(r.data!, false), [backRow]);
      return;
    }

    case "/allstats": {
      const r = await rpc<Stat[]>(client, "bot_stats", { p_telegram_id: tgId, p_scope: "all" });
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

      case "stock": {
        const cat = await catalog(client, tgId, false);
        await answer(cbId);
        await edit(chat, msg, cat.error ?? stockText(cat.data!), [backRow]);
        return;
      }

      case "stats":
      case "all": {
        const all = arg === "all";
        const r = await rpc<Stat[]>(client, "bot_stats",
          { p_telegram_id: tgId, p_scope: all ? "all" : "me" });
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
        await edit(chat, msg, ["👥 <b>الأدمن</b>", "", ...r.data!.map((a) =>
          `${a.role === "owner" ? "👑" : "•"} <b>${esc(a.name)}</b> — <code>${a.telegram_id}</code>` +
          `${a.is_active ? "" : " (معطّل)"} · ✅ ${a.confirmed}`),
          "", "لإضافة أدمن: <code>/addadmin رقمه الاسم</code>",
          "لتعطيله: <code>/deladmin رقمه</code>"].join("\n"), [backRow]);
        return;
      }
    }
    await answer(cbId);
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
    await send(chat, issueText(r.data!), issueButtons(r.data!.issue_id));
    return;
  }

  // ---------- تأكيد ----------
  if (verb === "ok") {
    const r = await rpc<{ card_code: string; seller_sales: number; remaining: number }>(
      client, "bot_confirm_issue", { p_telegram_id: tgId, p_issue_id: arg });
    if (r.error) { await answer(cbId, r.error, true); return; }
    await answer(cbId, "✅ تمّت");
    await edit(chat, msg, [
      "✅ <b>عملية ناجحة</b>", "",
      `<code>${esc(r.data!.card_code)}</code>`, "",
      `مبيعاتك الآن: <b>${r.data!.seller_sales}</b>`,
      `المتبقي في المخزون: ${r.data!.remaining}`,
    ].join("\n"), [[{ text: "🛒 بيع أخرى", callback_data: "m:sell" }], backRow]);
    return;
  }

  // ---------- إلغاء ----------
  if (verb === "no") {
    const r = await rpc<{ remaining: number }>(
      client, "bot_cancel_issue", { p_telegram_id: tgId, p_issue_id: arg });
    if (r.error) { await answer(cbId, r.error, true); return; }
    await answer(cbId, "❌ أُلغيت");
    // الكود يُمحى من الرسالة: البطاقة رجعت للمخزون وقد تُسلَّم
    // لزبون آخر، فلا تبقى معروضة في محادثة قديمة.
    await edit(chat, msg, [
      "❌ <b>عملية ملغاة</b>", "",
      "رجعت البطاقة إلى المخزون ولم تُحسب لك.",
      `المتاح الآن: <b>${r.data!.remaining}</b>`,
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
Deno.serve(async (req) => {
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
