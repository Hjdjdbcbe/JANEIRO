// ============================================================
// telegram-bot — نسخة قائمة بذاتها، وُلِّدت آلياً من
// supabase/functions/telegram-bot/ (index.ts + durations.ts + i18n.ts + qr.ts).
// لا تُعدّلها هنا؛ عدّل المصدر ثم أعد التوليد بـ
//     bash tools/build-functions.sh
// ============================================================

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

// ── durations.ts ──────────────────────────────────────────
/* ============================================================
   المدد — مصدر واحد
   ============================================================
   الأزرار المعروضة في أي مكان يُسأل فيه عن مدة، وحدودُ الإدخال
   اليدوي. القاعدة تتحقّق من المجالات نفسها (bot_set_variant_duration
   وقيود bot_certificates)، ولا تعيد القائمة: لو أعادتها لصار
   تبديلُ زرٍّ هجرةً.
   ============================================================ */

/** أزرار الأشهر. الشهران مثنّى في العربية — انظر i18n. */
const MONTH_CHOICES = [1, 2, 3, 6, 12];

/** أيام الهدية المعروضة. «لا» هو الأغلب، فهو أوّلها. */
const BONUS_CHOICES = [0, 7, 14];

/** المدة المخصّصة: أعداد صحيحة، بلا كسور. */
const CUSTOM = {
  months: { min: 1, max: 60 },
  days:   { min: 1, max: 999 },
  bonus:  { min: 0, max: 90 },
} as const;

/** يقبل الأرقام العربية الشرقية كما يقبل اللاتينية. */
function parseCount(raw: string): number | null {
  const s = raw.trim().replace(/[٠-٩]/g, (c) => String("٠١٢٣٤٥٦٧٨٩".indexOf(c)));
  if (!/^\d+$/.test(s)) return null;
  const n = Number(s);
  return Number.isSafeInteger(n) ? n : null;
}

/** داخل المجال أم لا — وبالرسالة التي تُقال للمستخدم. */
function checkRange(
  n: number | null, range: { min: number; max: number },
): string | null {
  if (n === null) return "عدد صحيح فقط، بلا كسور.";
  if (n < range.min || n > range.max) return `من ${range.min} إلى ${range.max}.`;
  return null;
}

// ── i18n.ts ───────────────────────────────────────────────
// ============================================================
// Janeiro Store — نصوص وثيقة التزام الخدمة، بثلاث لغات.
//
// كل نصّ يظهر للزبون أو في الوثيقة يعيش هنا وحده. تبديل صيغة لا
// يمسّ منطقاً ولا هجرة.
//
// النصوص أصلية لـ Janeiro Store. لا تُقتبس عبارة من أي نموذج
// شهادة ضمان في السوق — وقائمة الممنوع محروسة آلياً في
// tests/local/forbidden-text.test.sh.
// ============================================================

type Lang = "ar" | "fr" | "en";
const LANGS: Lang[] = ["ar", "fr", "en"];
const isLang = (v: unknown): v is Lang =>
  typeof v === "string" && (LANGS as string[]).includes(v);

// ------------------------------------------------------------
// التواريخ: 10 سبتمبر 2027 / 10 septembre 2027 / September 10, 2027
// ------------------------------------------------------------
const MONTHS: Record<Lang, string[]> = {
  ar: ["يناير","فبراير","مارس","أبريل","مايو","يونيو",
       "يوليو","أغسطس","سبتمبر","أكتوبر","نوفمبر","ديسمبر"],
  fr: ["janvier","février","mars","avril","mai","juin",
       "juillet","août","septembre","octobre","novembre","décembre"],
  en: ["January","February","March","April","May","June",
       "July","August","September","October","November","December"],
};

/**
 * التاريخ بتوقيت الجزائر لا بتوقيت من يقرأ: الوثيقة تقول يوماً
 * واحداً لصاحبها ولمن يتحقّق منها، أينما كانا.
 * تُبنى الصيغة بيدٍ لا بـtoLocaleDateString: العرض داخل satori
 * (توليد الصورة) لا يملك بيانات المناطق، فكانت الصيغة تختلف بين
 * الصفحة والصورة لنفس الوثيقة.
 */
function formatDate(iso: string | null, lang: Lang): string {
  if (!iso) return "—";
  const d = new Date(iso);
  // en-CA يعطي YYYY-MM-DD، وهو أضمن ما يُفكَّك بلا التباس ترتيب
  const [y, m, day] = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Africa/Algiers", year: "numeric", month: "2-digit", day: "2-digit",
  }).format(d).split("-");
  const name = MONTHS[lang][Number(m) - 1];
  const dd = String(Number(day));
  return lang === "en" ? `${name} ${dd}, ${y}` : `${dd} ${name} ${y}`;
}

// ------------------------------------------------------------
// النصوص
// ------------------------------------------------------------
type Doc = {
  dir: "rtl" | "ltr";
  title: string;
  tagline: string;
  subtitle: (platform: string) => string;
  labels: {
    ref: string; holder: string; account: string; service: string;
    coverage: string; activatedOn: string; coveredUntil: string; key: string;
  };
  /** المدة: بالأشهر أو بالأيام، مع أيام الهدية إن وُجدت. */
  duration: (months: number | null, bonus: number, days?: number | null) => string;
  /** أيام الهدية وحدها — تُعرض شارةً بجنب المدة في الوثيقة. */
  bonusPill: (n: number) => string;
  /** ثلاثة أسطر في الشريط الجانبي: ما هو المتجر، بإيجاز. */
  sideLines: string[];
  detailsHeading: string;
  verifiableRef: string;
  commitmentHeading: string;
  commitment: string[];
  status: { active: string; expired: string; revoked: string; pending: string };
  daysLeft: (n: number) => string;
  verifyHint: string;
  actions: { png: string; pdf: string; print: string };
  form: {
    heading: string; intro: string; submit: string;
    fullName: string; whatsapp: string; instagram: string;
    optional: string; whatsappHint: string; instagramHint: string;
  };
  errors: Record<string, string>;
  keep: string;
  contactsHeading: string;
};

/* ------------------------------------------------------------
   العدد في العربية
   ------------------------------------------------------------
   ثلاث صيغ لا اثنتان: مفرد (شهر)، مثنّى (شهران)، جمع قلّة من
   ثلاثة إلى عشرة (3 أشهر)، ثم تمييز مفرد منصوب من أحد عشر
   فصاعداً (12 شهراً). القاعدة نفسها لليوم.
   ------------------------------------------------------------ */
const arMonths = (n: number) =>
  n === 1 ? "شهر" : n === 2 ? "شهران" : n <= 10 ? `${n} أشهر` : `${n} شهراً`;

const arDays = (n: number) =>
  n === 1 ? "يوم" : n === 2 ? "يومان" : n <= 10 ? `${n} أيام` : `${n} يوماً`;

const DOC: Record<Lang, Doc> = {
  // ---------------------------------------------------------- AR
  ar: {
    dir: "rtl",
    title: "وثيقة التزام الخدمة",
    tagline: "المزيد من الخدمات. مزيد من الإمكانيات.",
    subtitle: (p) => `Janeiro Store — اشتراك ${p}`,
    labels: {
      ref: "مرجع Janeiro",
      holder: "صاحب الاشتراك",
      account: "الحساب المنشّط",
      service: "الخدمة",
      coverage: "التغطية",
      activatedOn: "نُشّط في",
      coveredUntil: "مغطّى حتى",
      key: "كلمة التحقق",
    },
    // العربية تعدّ على ثلاث صيغ لا اثنتين: مفرد، مثنّى، ثم جمع
    // إلى العشرة، ثم تمييز مفرد منصوب من الأحد عشر فصاعداً.
    // «2 شهر» و«12 أشهر» كلاهما خطأ.
    duration: (m, b, d) => {
      const base = m ? arMonths(m) : arDays(d ?? 0);
      return b > 0 ? `${base} + ${arDays(b)} هدية` : base;
    },
    bonusPill: (n) => `+ ${arDays(n)} هدية`,
    sideLines: ["اشتراكات رقمية", "خدمات أونلاين", "وصولك أبسط"],
    detailsHeading: "تفاصيل اشتراكك",
    verifiableRef: "مرجع قابل للتحقّق",
    commitmentHeading: "التزامنا",
    commitment: [
      "طيلة المدة المذكورة أعلاه، هذا الحساب يبقى تحت مسؤوليتنا.",
      "توقّفت الخدمة؟ راسلنا. نعيد لك الوصول، وإذا تعذّر ذلك نغطّي لك الأيام المتبقية.",
      "نبدأ المعالجة في أجل 24 ساعة من رسالتك.",
      "خارج التغطية: تغيير كلمة السر، مشاركة الحساب، أو عقوبة صادرة من المنصة نفسها.",
      "هذه المرجعية صالحة حتى التاريخ المذكور. احتفظ بها.",
    ],
    status: { active: "سارٍ", expired: "انتهى", revoked: "ملغى", pending: "غير مُعمَّر" },
    daysLeft: (n) => `يتبقّى ${n} ${n === 1 ? "يوم" : "يوماً"}`,
    verifyHint: "وثيقة صادرة عن Janeiro Store",
    actions: { png: "تحميل صورة", pdf: "تحميل PDF", print: "طباعة" },
    form: {
      heading: "أدخل بياناتك",
      intro: "لإصدار وثيقة التزام اشتراكك. تُملأ مرة واحدة.",
      submit: "إصدار الوثيقة",
      fullName: "الاسم الكامل",
      whatsapp: "رقم واتساب",
      instagram: "يوزر الانستغرام",
      optional: "اختياري",
      whatsappHint: "رقم جزائري: 0550… أو +213550…",
      instagramHint: "بلا @",
    },
    errors: {
      LINK_NOT_FOUND: "هذا الرابط غير صحيح.",
      LINK_USED: "عُبِّئت البيانات من هذا الرابط مسبقاً.",
      LINK_EXPIRED: "انتهت صلاحية هذا الرابط.",
      CERTIFICATE_NOT_FOUND: "لا توجد وثيقة بهذه الكلمة.",
      CERTIFICATE_PENDING: "لم تُعمَّر هذه الوثيقة بعد.",
      CERTIFICATE_REVOKED: "هذه الوثيقة ملغاة.",
      ALREADY_CLAIMED: "عُمِّرت هذه الوثيقة مسبقاً.",
      INVALID_NAME: "اكتب اسمك الكامل.",
      INVALID_PHONE: "رقم واتساب جزائري غير صحيح.",
      INVALID_INSTAGRAM: "يوزر انستغرام غير صحيح.",
      RATE_LIMITED: "محاولات كثيرة. انتظر قليلاً.",
      UNKNOWN: "تعذّر إتمام الطلب.",
    },
    keep: "احفظ هذه الوثيقة أو خزّن رابطها.",
    contactsHeading: "للتواصل معنا",
  },

  // ---------------------------------------------------------- FR
  fr: {
    dir: "ltr",
    title: "ENGAGEMENT DE SERVICE",
    tagline: "Plus de services. Plus de possibilités.",
    subtitle: (p) => `Janeiro Store — abonnement ${p}`,
    labels: {
      ref: "Réf. Janeiro",
      holder: "Titulaire",
      account: "Compte activé",
      service: "Service",
      coverage: "Couverture",
      activatedOn: "Activé le",
      coveredUntil: "Couvert jusqu'au",
      key: "Clé de vérification",
    },
    // « mois » invariable au pluriel
    duration: (m, b, d) => {
      const base = m ? `${m} mois` : `${d} ${d === 1 ? "jour" : "jours"}`;
      return b > 0
        ? `${base} + ${b} ${b === 1 ? "jour offert" : "jours offerts"}`
        : base;
    },
    bonusPill: (n) => `+ ${n} ${n === 1 ? "jour offert" : "jours offerts"}`,
    sideLines: ["Abonnements digitaux", "Services en ligne", "Votre accès simplifié"],
    detailsHeading: "Détails de votre abonnement",
    verifiableRef: "Référence vérifiable",
    commitmentHeading: "NOTRE ENGAGEMENT",
    commitment: [
      "Pendant toute la durée indiquée ci-dessus, ce compte reste sous notre responsabilité.",
      "Une interruption de service ? Écrivez-nous. Nous rétablissons l'accès, et si cela s'avère impossible, nous couvrons les jours restants.",
      "Notre prise en charge démarre sous 24 h après votre message.",
      "Hors couverture : modification du mot de passe, partage du compte, ou sanction émise par la plateforme elle-même.",
      "Cette référence reste valable jusqu'à la date indiquée. Conservez-la.",
    ],
    status: { active: "En cours", expired: "Expiré", revoked: "Annulé", pending: "Non renseigné" },
    daysLeft: (n) => `${n} ${n === 1 ? "jour restant" : "jours restants"}`,
    verifyHint: "Document émis par Janeiro Store",
    actions: { png: "Télécharger l'image", pdf: "Télécharger le PDF", print: "Imprimer" },
    form: {
      heading: "Vos informations",
      intro: "Pour émettre l'engagement de votre abonnement. À remplir une seule fois.",
      submit: "Émettre le document",
      fullName: "Nom complet",
      whatsapp: "Numéro WhatsApp",
      instagram: "Identifiant Instagram",
      optional: "facultatif",
      whatsappHint: "Numéro algérien : 0550… ou +213550…",
      instagramHint: "sans @",
    },
    errors: {
      LINK_NOT_FOUND: "Ce lien n'est pas valide.",
      LINK_USED: "Ce lien a déjà été utilisé.",
      LINK_EXPIRED: "Ce lien a expiré.",
      CERTIFICATE_NOT_FOUND: "Aucun document ne correspond à cette clé.",
      CERTIFICATE_PENDING: "Ce document n'a pas encore été renseigné.",
      CERTIFICATE_REVOKED: "Ce document a été annulé.",
      ALREADY_CLAIMED: "Ce document a déjà été renseigné.",
      INVALID_NAME: "Indiquez votre nom complet.",
      INVALID_PHONE: "Numéro WhatsApp algérien invalide.",
      INVALID_INSTAGRAM: "Identifiant Instagram invalide.",
      RATE_LIMITED: "Trop de tentatives. Patientez un instant.",
      UNKNOWN: "La demande n'a pas pu aboutir.",
    },
    keep: "Conservez ce document ou son lien.",
    contactsHeading: "Nous contacter",
  },

  // ---------------------------------------------------------- EN
  en: {
    dir: "ltr",
    title: "SERVICE COMMITMENT",
    // لم تُعطَ بالإنجليزية؛ هذه ترجمة الفرنسية — راجعها
    tagline: "More services. More possibilities.",
    subtitle: (p) => `Janeiro Store — ${p} subscription`,
    labels: {
      ref: "Janeiro Ref.",
      holder: "Holder",
      account: "Activated account",
      service: "Service",
      coverage: "Coverage",
      activatedOn: "Activated on",
      coveredUntil: "Covered until",
      key: "Verification key",
    },
    duration: (m, b, d) => {
      const base = m ? `${m} ${m === 1 ? "month" : "months"}`
                     : `${d} ${d === 1 ? "day" : "days"}`;
      return b > 0 ? `${base} + ${b} ${b === 1 ? "day" : "days"} free` : base;
    },
    bonusPill: (n) => `+ ${n} ${n === 1 ? "day" : "days"} free`,
    sideLines: ["Digital subscriptions", "Online services", "Your access, simplified"],
    detailsHeading: "Your subscription details",
    verifiableRef: "Verifiable reference",
    commitmentHeading: "OUR COMMITMENT",
    commitment: [
      "For the full period shown above, this account stays our responsibility.",
      "Service stopped? Message us. We restore access — and if that proves impossible, we cover the remaining days.",
      "We start handling your case within 24 hours.",
      "Not covered: password changes, account sharing, or penalties issued by the platform itself.",
      "This reference stays valid until the date shown. Keep it.",
    ],
    status: { active: "Active", expired: "Expired", revoked: "Cancelled", pending: "Not filled in" },
    daysLeft: (n) => `${n} ${n === 1 ? "day" : "days"} left`,
    verifyHint: "Document issued by Janeiro Store",
    actions: { png: "Download image", pdf: "Download PDF", print: "Print" },
    form: {
      heading: "Your details",
      intro: "To issue the commitment for your subscription. Filled in once.",
      submit: "Issue the document",
      fullName: "Full name",
      whatsapp: "WhatsApp number",
      instagram: "Instagram handle",
      optional: "optional",
      whatsappHint: "Algerian number: 0550… or +213550…",
      instagramHint: "without @",
    },
    errors: {
      LINK_NOT_FOUND: "This link is not valid.",
      LINK_USED: "This link has already been used.",
      LINK_EXPIRED: "This link has expired.",
      CERTIFICATE_NOT_FOUND: "No document matches this key.",
      CERTIFICATE_PENDING: "This document has not been filled in yet.",
      CERTIFICATE_REVOKED: "This document has been cancelled.",
      ALREADY_CLAIMED: "This document has already been filled in.",
      INVALID_NAME: "Enter your full name.",
      INVALID_PHONE: "Invalid Algerian WhatsApp number.",
      INVALID_INSTAGRAM: "Invalid Instagram handle.",
      RATE_LIMITED: "Too many attempts. Please wait a moment.",
      UNKNOWN: "The request could not be completed.",
    },
    keep: "Keep this document or save its link.",
    contactsHeading: "Contact us",
  },
};

/** النقاط مرقّمة «01 ·» لا bullets — كما حُدّد. */
const commitmentLines = (lang: Lang): string[] =>
  DOC[lang].commitment.map((t, i) => `${String(i + 1).padStart(2, "0")} · ${t}`);

/** رسالة خطأ للزبون بلغته، بلا تسريب رمز داخلي. */
function docError(raw: string, lang: Lang): string {
  const code = raw.split(":")[0].trim().replace(/[^A-Z_]/g, "");
  return DOC[lang].errors[code] ?? DOC[lang].errors.UNKNOWN;
}

// ── qr.ts ─────────────────────────────────────────────────
// ============================================================
// Janeiro Store — مُرمِّز QR صغير، بلا اعتماديات.
//
// وضع البايت، تصحيح خطأ M، النسخ 1–10 (حتى 213 بايتاً) — يكفي
// رابط تحقّق بمراحل.
//
// لماذا مكتوب هنا لا مستورَد: الدالة تعمل على Deno داخل Supabase،
// وكل استيراد خارجي نقطة فشل في وقت التشغيل لا يكشفها اختبار
// محلي. وهذا الملف يُقارَن بايتاً ببايت بمكتبة `qrcode` المرجعية
// في tests/local/qr.test.js، فصحّته مبرهنة لا مفترضة.
//
// المرجع: ISO/IEC 18004.
// ============================================================

// النسخة -> [كلمات التصحيح لكل كتلة, كتل المجموعة1, بيانات ك1, كتل م2, بيانات ك2]
const EC_M: Record<number, [number, number, number, number, number]> = {
  1: [10, 1, 16, 0, 0],   2: [16, 1, 28, 0, 0],   3: [26, 1, 44, 0, 0],
  4: [18, 2, 32, 0, 0],   5: [24, 2, 43, 0, 0],   6: [16, 4, 27, 0, 0],
  7: [18, 4, 31, 0, 0],   8: [22, 2, 38, 2, 39],  9: [22, 3, 36, 2, 37],
  10:[26, 4, 43, 1, 44],
};

// مراكز أنماط المحاذاة لكل نسخة
const ALIGN: Record<number, number[]> = {
  1: [], 2: [6,18], 3: [6,22], 4: [6,26], 5: [6,30],
  6: [6,34], 7: [6,22,38], 8: [6,24,42], 9: [6,26,46], 10:[6,28,50],
};

// ---------- حقل جالوا GF(256) ----------
const EXP = new Uint8Array(512);
const LOG = new Uint8Array(256);
(() => {
  let x = 1;
  for (let i = 0; i < 255; i++) {
    EXP[i] = x; LOG[x] = i;
    x <<= 1;
    if (x & 0x100) x ^= 0x11d;          // كثير الحدود البدائي
  }
  for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
})();

const mul = (a: number, b: number) =>
  a === 0 || b === 0 ? 0 : EXP[LOG[a] + LOG[b]];

/** كثير حدود المولّد لعدد كلمات تصحيح. */
function generator(n: number): Uint8Array {
  let g = new Uint8Array([1]);
  for (let i = 0; i < n; i++) {
    const next = new Uint8Array(g.length + 1);
    for (let j = 0; j < g.length; j++) {
      next[j] ^= g[j];
      next[j + 1] ^= mul(g[j], EXP[i]);
    }
    g = next;
  }
  return g;
}

/** كلمات تصحيح Reed-Solomon لكتلة بيانات. */
function ecBytes(data: Uint8Array, n: number): Uint8Array {
  const g = generator(n);
  const res = new Uint8Array(data.length + n);
  res.set(data);
  for (let i = 0; i < data.length; i++) {
    const factor = res[i];
    if (factor === 0) continue;
    for (let j = 0; j < g.length; j++) res[i + j] ^= mul(g[j], factor);
  }
  return res.slice(data.length);
}

// ---------- معلومات الصيغة والنسخة ----------
function formatBits(mask: number): number {
  // مستوى M = 00
  let v = (0b00 << 3) | mask;
  let d = v << 10;
  for (let i = 4; i >= 0; i--) {
    if (d & (1 << (i + 10))) d ^= 0b10100110111 << i;
  }
  return ((v << 10) | d) ^ 0b101010000010010;
}

function versionBits(version: number): number {
  let d = version << 12;
  for (let i = 5; i >= 0; i--) {
    if (d & (1 << (i + 12))) d ^= 0b1111100100101 << i;
  }
  return (version << 12) | d;
}

// ---------- البناء ----------
type Grid = { size: number; mod: Int8Array; fn: Uint8Array };

const at = (g: { size: number; mod: Int8Array }, r: number, c: number) =>
  g.mod[r * g.size + c];
const set = (g: Grid, r: number, c: number, v: number, isFn = false) => {
  g.mod[r * g.size + c] = v;
  if (isFn) g.fn[r * g.size + c] = 1;
};

function placeFunctionPatterns(g: Grid, version: number) {
  const n = g.size;

  // أنماط البحث الثلاثة ومناطق فصلها
  for (const [br, bc] of [[0, 0], [0, n - 7], [n - 7, 0]] as const) {
    for (let r = -1; r <= 7; r++) {
      for (let c = -1; c <= 7; c++) {
        const rr = br + r, cc = bc + c;
        if (rr < 0 || rr >= n || cc < 0 || cc >= n) continue;
        const on = (r >= 0 && r <= 6 && (c === 0 || c === 6)) ||
                   (c >= 0 && c <= 6 && (r === 0 || r === 6)) ||
                   (r >= 2 && r <= 4 && c >= 2 && c <= 4);
        set(g, rr, cc, on ? 1 : 0, true);
      }
    }
  }

  // أنماط المحاذاة، عدا ما يصطدم بأنماط البحث
  const centers = ALIGN[version];
  for (const r of centers) {
    for (const c of centers) {
      if ((r === 6 && c === 6) || (r === 6 && c === n - 7) || (r === n - 7 && c === 6)) continue;
      for (let dr = -2; dr <= 2; dr++) {
        for (let dc = -2; dc <= 2; dc++) {
          const on = Math.max(Math.abs(dr), Math.abs(dc)) !== 1;
          set(g, r + dr, c + dc, on ? 1 : 0, true);
        }
      }
    }
  }

  // أنماط التوقيت
  for (let i = 8; i < n - 8; i++) {
    const v = i % 2 === 0 ? 1 : 0;
    set(g, 6, i, v, true);
    set(g, i, 6, v, true);
  }

  // الوحدة الداكنة، ومواضع الصيغة محجوزة
  set(g, n - 8, 8, 1, true);
  for (let i = 0; i < 9; i++) {
    if (i !== 6) { set(g, 8, i, 0, true); set(g, i, 8, 0, true); }
  }
  for (let i = 0; i < 8; i++) {
    set(g, 8, n - 1 - i, 0, true);
    if (n - 1 - i !== n - 8) set(g, n - 1 - i, 8, 0, true);
  }

  // معلومات النسخة (7 فأعلى)
  if (version >= 7) {
    const bits = versionBits(version);
    for (let i = 0; i < 18; i++) {
      const b = (bits >> i) & 1;
      const r = Math.floor(i / 3), c = i % 3;
      set(g, n - 11 + c, r, b, true);
      set(g, r, n - 11 + c, b, true);
    }
  }
}

function placeFormat(g: Grid, mask: number) {
  const n = g.size;
  const bits = formatBits(mask);
  for (let i = 0; i < 15; i++) {
    // الأعلى قيمةً أولاً. كان الترتيب معكوساً، فكانت الصيغة تُقرأ
    // مقلوبة — والرمز يبدو سليماً تماماً ولا يُقرأ. كشفته المقارنة
    // بالمرجع، لا النظر.
    const b = (bits >> (14 - i)) & 1;

    // النسخة الأولى، حول نمط البحث الأعلى-يسار
    if (i < 6)        set(g, 8, i, b, true);
    else if (i === 6) set(g, 8, 7, b, true);
    else if (i === 7) set(g, 8, 8, b, true);
    else if (i === 8) set(g, 7, 8, b, true);
    else              set(g, 14 - i, 8, b, true);

    // والنسخة الثانية: سبعة بتات صاعدة في العمود 8، ثم ثمانية في
    // الصفّ 8. الحدّ عند 7 لا 8: الموضع (n-8, 8) هو الوحدة الداكنة
    // الثابتة لا بت صيغة، وكتابته كانت تزيح كل ما بعده.
    if (i < 7) set(g, n - 1 - i, 8, b, true);
    else       set(g, 8, n - 15 + i, b, true);
  }
  // والوحدة الداكنة تبقى داكنة مهما جرى
  set(g, n - 8, 8, 1, true);
}

const MASKS: ((r: number, c: number) => boolean)[] = [
  (r, c) => (r + c) % 2 === 0,
  (r) => r % 2 === 0,
  (_r, c) => c % 3 === 0,
  (r, c) => (r + c) % 3 === 0,
  (r, c) => (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0,
  (r, c) => ((r * c) % 2) + ((r * c) % 3) === 0,
  (r, c) => (((r * c) % 2) + ((r * c) % 3)) % 2 === 0,
  (r, c) => (((r + c) % 2) + ((r * c) % 3)) % 2 === 0,
];

/** عقوبات النمط الأربع — اختيار القناع يتبعها. */
function penalty(g: Grid): number {
  const [a, b, c, d] = penaltyParts(g);
  return a + b + c + d;
}

/** مفصّلة، ليقارنها الاختبار قاعدةً بقاعدة بالمرجع. */
function penaltyParts(g: { size: number; mod: Int8Array }): number[] {
  const n = g.size;
  let p1 = 0, p2 = 0, p3 = 0, p4 = 0;

  // 1: خمسة متتالية فأكثر
  for (const byRow of [true, false]) {
    for (let a = 0; a < n; a++) {
      let run = 1, prev = -1;
      for (let b = 0; b < n; b++) {
        const v = byRow ? at(g, a, b) : at(g, b, a);
        if (v === prev) { run++; if (run === 5) p1 += 3; else if (run > 5) p1++; }
        else { prev = v; run = 1; }
      }
    }
  }
  // 2: مربعات 2×2
  for (let r = 0; r < n - 1; r++) {
    for (let c = 0; c < n - 1; c++) {
      const v = at(g, r, c);
      if (v === at(g, r, c + 1) && v === at(g, r + 1, c) && v === at(g, r + 1, c + 1)) p2 += 3;
    }
  }
  // 3: النمط 1011101 مع أربع فراغات
  const A = [1,0,1,1,1,0,1,0,0,0,0], B = [0,0,0,0,1,0,1,1,1,0,1];
  for (const byRow of [true, false]) {
    for (let a = 0; a < n; a++) {
      for (let b = 0; b + 10 < n; b++) {
        let mA = true, mB = true;
        for (let k = 0; k < 11; k++) {
          const v = byRow ? at(g, a, b + k) : at(g, b + k, a);
          if (v !== A[k]) mA = false;
          if (v !== B[k]) mB = false;
        }
        if (mA) p3 += 40;
        if (mB) p3 += 40;
      }
    }
  }
  // 4: انحراف نسبة الداكن عن النصف
  let dark = 0;
  for (let i = 0; i < n * n; i++) if (g.mod[i] === 1) dark++;
  p4 = Math.floor(Math.abs(dark * 20 - n * n * 10) / (n * n)) * 10;
  return [p1, p2, p3, p4];
}

/** النص -> مصفوفة وحدات. */
function qrMatrix(text: string, forceMask?: number): number[][] {
  const bytes = new TextEncoder().encode(text);

  // أصغر نسخة تتّسع
  let version = 0;
  for (let v = 1; v <= 10; v++) {
    const [ec, b1, d1, b2, d2] = EC_M[v];
    const dataWords = b1 * d1 + b2 * d2;
    const countBits = v >= 10 ? 16 : 8;
    if (bytes.length <= Math.floor((dataWords * 8 - 4 - countBits) / 8)) { version = v; break; }
  }
  if (!version) throw new Error("QR_TOO_LONG");

  const [ecLen, b1, d1, b2, d2] = EC_M[version];
  const dataWords = b1 * d1 + b2 * d2;
  const countBits = version >= 10 ? 16 : 8;

  // ---- تيار البتات ----
  const bits: number[] = [];
  const push = (val: number, len: number) => {
    for (let i = len - 1; i >= 0; i--) bits.push((val >> i) & 1);
  };
  push(0b0100, 4);                 // وضع البايت
  push(bytes.length, countBits);
  for (const b of bytes) push(b, 8);

  const cap = dataWords * 8;
  push(0, Math.min(4, cap - bits.length));        // منهي
  while (bits.length % 8) bits.push(0);
  const pad = [0xec, 0x11];
  for (let i = 0; bits.length < cap; i++) push(pad[i % 2], 8);

  const words = new Uint8Array(dataWords);
  for (let i = 0; i < dataWords; i++) {
    for (let j = 0; j < 8; j++) words[i] = (words[i] << 1) | bits[i * 8 + j];
  }

  // ---- الكتل والتشابك ----
  const blocks: Uint8Array[] = [];
  const ecs: Uint8Array[] = [];
  let off = 0;
  for (let i = 0; i < b1 + b2; i++) {
    const len = i < b1 ? d1 : d2;
    const blk = words.slice(off, off + len);
    off += len;
    blocks.push(blk);
    ecs.push(ecBytes(blk, ecLen));
  }
  const total = EC_M[version] && (dataWords + ecLen * (b1 + b2));
  const out = new Uint8Array(total);
  let k = 0;
  for (let i = 0; i < Math.max(d1, d2); i++) {
    for (const blk of blocks) if (i < blk.length) out[k++] = blk[i];
  }
  for (let i = 0; i < ecLen; i++) {
    for (const e of ecs) out[k++] = e[i];
  }

  // ---- الشبكة ----
  const size = version * 4 + 17;
  const base: Grid = { size, mod: new Int8Array(size * size).fill(-1), fn: new Uint8Array(size * size) };
  placeFunctionPatterns(base, version);

  // ---- وضع البتات في مسار الثعبان ----
  const dataBits: number[] = [];
  for (const b of out) for (let i = 7; i >= 0; i--) dataBits.push((b >> i) & 1);

  let bi = 0, up = true;
  const place = (g: Grid) => {
    for (let col = size - 1; col > 0; col -= 2) {
      if (col === 6) col--;                       // عمود التوقيت يُتخطّى
      for (let i = 0; i < size; i++) {
        const row = up ? size - 1 - i : i;
        for (const c of [col, col - 1]) {
          if (g.fn[row * size + c]) continue;
          g.mod[row * size + c] = bi < dataBits.length ? dataBits[bi++] : 0;
        }
      }
      up = !up;
    }
  };
  place(base);

  // ---- اختيار القناع بأقل عقوبة ----
  let best: Grid | null = null, bestScore = Infinity;
  for (let m = 0; m < 8; m++) {
    if (forceMask !== undefined && m !== forceMask) continue;
    const g: Grid = { size, mod: base.mod.slice(), fn: base.fn.slice() };
    for (let r = 0; r < size; r++) {
      for (let c = 0; c < size; c++) {
        if (g.fn[r * size + c]) continue;
        if (MASKS[m](r, c)) g.mod[r * size + c] ^= 1;
      }
    }
    placeFormat(g, m);
    const sc = penalty(g);
    if (sc < bestScore) { bestScore = sc; best = g; }
  }

  const g = best!;
  const grid: number[][] = [];
  for (let r = 0; r < size; r++) {
    grid.push(Array.from(g.mod.slice(r * size, (r + 1) * size), (v) => (v === 1 ? 1 : 0)));
  }
  return grid;
}

/** SVG مضمّن — لا ملف ولا طلب شبكة. */
/** للاختبار: المصفوفة كـGrid لحساب العقوبات عليها. */
function gridOf(matrix: number[][]): { size: number; mod: Int8Array } {
  const size = matrix.length;
  const mod = new Int8Array(size * size);
  for (let r = 0; r < size; r++) for (let c = 0; c < size; c++) mod[r * size + c] = matrix[r][c];
  return { size, mod };
}

function qrSvg(text: string, px = 80): string {
  let grid: number[][];
  try { grid = qrMatrix(text); }
  catch { return ""; }               // رابط طويل جداً: تُحذف الصورة لا تُكسر الصفحة
  const n = grid.length;
  const quiet = 2;                   // الهامش الصامت يصغَّر إلى 2 لتوفير مساحة
  const dim = n + quiet * 2;
  let d = "";
  for (let r = 0; r < n; r++) {
    for (let c = 0; c < n; c++) {
      if (grid[r][c]) d += `M${c + quiet} ${r + quiet}h1v1h-1z`;
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${px}" ` +
    `viewBox="0 0 ${dim} ${dim}" shape-rendering="crispEdges" role="img" aria-hidden="true">` +
    `<rect width="${dim}" height="${dim}" fill="#fff"/>` +
    `<path d="${d}" fill="#000"/></svg>`;
}

// ── index.ts ──────────────────────────────────────────────
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
// الاحتياط بمعاملات خاصة بوثيقة الالتزام (claim/doc/verify) لا
// بـ fill/cert: هذان لفيتشر 024 وبياناتهما مختلفة، وخلطهما كان
// يرسل زبون الالتزام إلى استمارة لا تخصّه.
const claimUrl  = (t: string) =>
  SITE_URL ? `${SITE_URL}/warranty/claim/${t}` : `${SELF_URL}?claim=${t}`;
const docUrl    = (c: string) =>
  SITE_URL ? `${SITE_URL}/warranty/${c}` : `${SELF_URL}?doc=${c}`;
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
const ask = (chat: number, text: string, placeholder = "الصق الأكواد هنا") =>
  tg("sendMessage", {
    chat_id: chat, text, parse_mode: "HTML",
    reply_markup: { force_reply: true, input_field_placeholder: placeholder },
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
  "", "<b>الكتالوج</b> — ما تحتاجه الوثيقة", "",
  "/catalog — جرد: منصّة ومدّة وسعر كل صنف، وما ينقص",
  "/platform &lt;رمز المنتج&gt; &lt;المنصّة&gt;   ·   /unplatform …",
  "   مثال: <code>/platform giftcard Netflix</code>",
  "/duration &lt;رمز المنتج&gt; &lt;رمز المدة&gt; &lt;عدد&gt; &lt;يوم|أسبوع|شهر|سنة&gt;",
  "   مثال: <code>/duration giftcard year 1 سنة</code>",
  "/price &lt;رمز المنتج&gt; &lt;رمز المدة&gt; &lt;dz|jo&gt; &lt;المبلغ&gt;",
  "   مثال: <code>/price giftcard year dz 3500</code>",
  "/market &lt;dz|jo&gt; &lt;on|off&gt; — فتح صفحة أو غلقها",
  "/seller &lt;رقم تليجرام&gt; &lt;dz|jo|-&gt; — صفحة البائع",
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

function page(
  title: string, body: string, extraHead = "",
  opts: { lang?: Lang; noindex?: boolean; wide?: boolean } = {},
): Response {
  const lang = opts.lang ?? "ar";
  const dir  = DOC[lang].dir;
  return new Response(
    `<!doctype html><html lang="${lang}" dir="${dir}"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
${opts.noindex ? '<meta name="robots" content="noindex, nofollow">' : ""}
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
</style>${opts.wide ? "<style>.wrap{max-width:860px}</style>" : ""}${extraHead}</head><body><div class="wrap">${body}</div></body></html>`,
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

// ============================================================
// صفحات وثيقة التزام الخدمة — بثلاث لغات
// ============================================================
type Engagement = {
  code: string; ref_code: string; holder_name: string; instagram: string | null;
  platform: string; months: number | null; duration_days: number | null;
  bonus_days: number;
  starts_at: string; ends_at: string | null;
  status: "active" | "expired" | "revoked" | "pending";
  days_left: number | null; contacts?: Contact[];
};

/** مبدّل اللغة: نفس المسار، بمعامل lang. */
function langSwitch(path: string, current: Lang): string {
  const names: Record<Lang, string> = { ar: "العربية", fr: "Français", en: "English" };
  return `<div class="langs noprint">` + LANGS.map((l) =>
    l === current
      ? `<span class="on">${names[l]}</span>`
      : `<a href="${esc(path)}?lang=${l}">${names[l]}</a>`).join("") + `</div>`;
}

const ENG_CSS = `
.langs{display:flex;gap:6px;justify-content:center;margin-bottom:14px}
.langs a,.langs span{padding:6px 12px;border-radius:999px;font-size:13px;
 text-decoration:none;border:1px solid var(--line);color:var(--muted)}
.langs .on{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:700}
.head{background:#17142B;color:#fff;margin:-22px -22px 20px;padding:24px 22px;
 border-radius:18px 18px 0 0}
.head .brand{font-size:12px;letter-spacing:.14em;text-transform:uppercase;opacity:.62}
.head h1{font-size:20px;margin:8px 0 6px;letter-spacing:.02em}
.head .sub{font-size:14px;opacity:.82;margin:0}
.head .tag{font-size:12px;opacity:.52;margin:10px 0 0}
.eng{margin-top:22px;padding-top:18px;border-top:2px dashed var(--line)}
.eng h2{font-size:13px;letter-spacing:.1em;margin:0 0 12px}
.eng ol{list-style:none;margin:0;padding:0}
.eng li{display:flex;gap:10px;font-size:14px;line-height:1.6;margin-bottom:10px;color:var(--muted)}
.eng .n{color:var(--accent);font-weight:700;font-variant-numeric:tabular-nums;flex:none}
.qr{display:flex;align-items:center;gap:14px;margin-top:20px;padding-top:16px;
 border-top:1px solid var(--line);font-size:13px;color:var(--muted)}
.acts{display:flex;gap:8px;margin-top:20px}
.acts a,.acts button{flex:1;margin:0;padding:12px;font-size:14px;text-align:center;
 text-decoration:none;border-radius:12px;border:1px solid var(--line);
 background:var(--bg);color:var(--ink);font-weight:600;cursor:pointer}
.acts .primary{background:var(--accent);border-color:var(--accent);color:#fff}
.st{display:inline-block;padding:3px 11px;border-radius:999px;font-size:12px;font-weight:700}
.st.active{background:#E7F7EE;color:#11794A}
.st.expired,.st.revoked{background:#FBE9E9;color:#B42318}
@media(prefers-color-scheme:dark){.st.active{background:#12301F;color:#66D9A0}
 .st.expired,.st.revoked{background:#3A1A1A;color:#F5837C}}
@media print{.head{margin:0 0 18px;border-radius:0}}
`;

/** استمارة الزبون — الحقول الثلاثة، بلغته. */
function engFormPage(token: string, d: {
  platform: string; months: number | null; duration_days: number | null;
  bonus_days: number;
}, lang: Lang): Response {
  const t = DOC[lang];
  const f = t.form;
  const field = (id: string, label: string, hint: string, req: boolean, extra = "") => `
    <label for="${id}">${esc(label)}${req ? "" : ` <span class="opt">(${esc(f.optional)})</span>`}</label>
    <input id="${id}" name="${id}" ${req ? "required" : ""} autocomplete="off" ${extra}>
    <p class="hint">${esc(hint)}</p>`;

  return page(`${t.form.heading} — Janeiro Store`, `
    ${langSwitch(`/warranty/claim/${token}`, lang)}
    <div class="card">
      <span class="badge">${esc(t.subtitle(d.platform))}</span>
      <h1>${esc(f.heading)}</h1>
      <p class="sub">${esc(f.intro)}</p>
      <p class="sub"><b>${esc(t.labels.coverage)}:</b> ${esc(t.duration(d.months, d.bonus_days, d.duration_days))}</p>
      <form method="POST" action="/warranty/claim/${esc(token)}?lang=${lang}">
        ${field("full_name", f.fullName, "", true, 'maxlength="80"')}
        ${field("whatsapp", f.whatsapp, f.whatsappHint, true,
                'inputmode="tel" placeholder="0550 00 00 00"')}
        ${field("instagram", f.instagram, f.instagramHint, false, 'maxlength="40"')}
        <button type="submit">${esc(f.submit)}</button>
      </form>
    </div><p class="brand">Janeiro Store</p>`,
    `<style>${ENG_CSS}.hint{margin:6px 0 0;font-size:12px;color:var(--muted)}</style>`,
    { lang, noindex: true });
}

/* ------------------------------------------------------------
   الوثيقة نفسها
   ------------------------------------------------------------
   ورقة بشريط جانبي بنفسجي ومتن كريمي، على نسبة A4 — لأنها
   تُطبع وتُحفظ وتُرسل صورةً، لا تُقرأ في تبويب وتُنسى.

   وعلى الهاتف ينقلب الشريط إلى شارة علوية: نفس المحتوى بلا
   تمرير أفقي. والألوان تُطبع كما تُعرض (print-color-adjust)،
   وإلا خرج الشريط أبيض وضاعت الهوية.
   ------------------------------------------------------------ */
const DOC_CSS = `
.sheet{display:flex;background:#F8F6F1;color:#14121F;border-radius:16px;overflow:hidden;
 box-shadow:0 1px 2px rgba(20,18,31,.06),0 12px 40px rgba(20,18,31,.10)}
.side{flex:none;width:190px;background:#6C35FF;color:#fff;padding:26px 22px;
 display:flex;flex-direction:column;gap:18px}
.side .logo{font-size:30px;font-weight:800;letter-spacing:-.02em;line-height:1}
.side .logo small{display:block;font-size:11px;font-weight:600;letter-spacing:.34em;
 margin-top:4px;opacity:.9}
.side hr{width:52px;height:3px;background:#fff;border:0;margin:4px 0;opacity:.9}
.side ul{list-style:none;margin:0;padding:0;font-size:14px;line-height:1.5;opacity:.95}
.side li{margin-bottom:9px}
.side .foot{margin-top:auto;display:flex;flex-direction:column;gap:10px}
.side .lbl{font-size:10px;font-weight:700;letter-spacing:.14em;text-transform:uppercase;
 opacity:.85;line-height:1.4}
.side .qrbox{background:#fff;padding:7px;border-radius:8px;width:max-content}
.side .qrbox svg{display:block}
.main{flex:1;min-width:0;padding:26px 30px 22px}
.tag{text-align:end;font-size:12px;font-weight:700;color:#6C35FF;line-height:1.5;
 margin:0 0 14px}
.doc-h1{font-size:30px;font-weight:800;letter-spacing:-.01em;margin:0;line-height:1.1;
 text-transform:uppercase}
.doc-sub{font-size:16px;font-weight:700;margin:6px 0 0}
.win{display:flex;gap:0;background:#EFE9FF;border-radius:12px;padding:14px 16px;margin:18px 0}
.win>div{flex:1;display:flex;gap:11px;align-items:center;min-width:0}
.win>div+div{border-inline-start:1px solid #D6C9FF;padding-inline-start:16px}
.win .ic{flex:none;color:#6C35FF}
.win .k{font-size:10px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;
 color:#6C35FF;margin:0 0 2px}
.win .v{font-size:17px;font-weight:700;margin:0;line-height:1.25}
.det{border:1px solid #E2DDD2;border-radius:12px;padding:16px 18px;background:#FDFCFA}
.det h2{font-size:16px;font-weight:700;margin:0 0 10px}
.det .r{display:flex;justify-content:space-between;align-items:center;gap:14px;
 padding:9px 0;border-top:1px solid #EDE8DE;font-size:14px}
.det .r:first-of-type{border-top:0}
.det .r span{color:#6B6880}
.det .r b{text-align:end;word-break:break-word;font-weight:700}
.pill{display:inline-block;background:#6C35FF;color:#fff;border-radius:999px;
 padding:3px 11px;font-size:12px;font-weight:700;margin-inline-start:8px;white-space:nowrap}
.st{display:inline-block;padding:3px 11px;border-radius:999px;font-size:12px;font-weight:700}
.st.active{background:#E7F7EE;color:#11794A}
.st.pending{background:#FFF3DC;color:#8A5A00}
.st.expired,.st.revoked{background:#FBE9E9;color:#B42318}
.commit{margin-top:20px}
.commit h2{font-size:19px;font-weight:800;margin:0 0 6px;text-transform:uppercase}
.commit ol{list-style:none;margin:0;padding:0}
.commit li{display:flex;gap:13px;align-items:flex-start;padding:11px 0;
 border-top:1px solid #E7E2D8;font-size:14px;line-height:1.55}
.commit li:first-child{border-top:0}
.commit .n{flex:none;font-size:18px;font-weight:800;color:#6C35FF;
 font-variant-numeric:tabular-nums;min-width:2.1em}
.commit .d{flex:none;color:#6C35FF;font-weight:800;margin-inline-end:2px}
.dfoot{display:flex;align-items:center;gap:16px;margin-top:20px;padding-top:16px;
 border-top:1px solid #E2DDD2}
.dfoot .b{font-size:19px;font-weight:800;color:#6C35FF;line-height:1.2}
.dfoot .t{flex:1;font-size:12px;color:#6B6880;line-height:1.45;
 border-inline-start:1px solid #E2DDD2;padding-inline-start:16px}
.dfoot .u{display:block;margin-top:3px;font-size:10px;word-break:break-all;opacity:.8;
 font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.dfoot .q{flex:none;border:1px solid #E2DDD2;border-radius:9px;padding:6px;background:#fff}
.dfoot .q svg{display:block}
@media(max-width:620px){
 .sheet{flex-direction:column}
 .side{width:auto;flex-direction:row;flex-wrap:wrap;align-items:center;gap:14px;padding:18px}
 .side ul,.side hr{display:none}
 .side .foot{margin:0 0 0 auto;flex-direction:row;align-items:center}
 .main{padding:20px 18px}
 .doc-h1{font-size:23px}
 .win{flex-direction:column;gap:12px}
 .win>div+div{border-inline-start:0;border-top:1px solid #D6C9FF;
  padding-inline-start:0;padding-top:12px}
}
@media print{
 body{background:#fff;padding:0}
 .sheet{border-radius:0;box-shadow:none;min-height:100vh}
 .side,.pill,.win{-webkit-print-color-adjust:exact;print-color-adjust:exact}
}
`;

function engDocPage(d: Engagement, lang: Lang): Response {
  const t = DOC[lang];
  const L = t.labels;
  const row = (label: string, value: string, extra = "") =>
    `<div class="r"><span>${esc(label)}</span><b>${esc(value)}${extra}</b></div>`;

  const cal = `<svg class="ic" width="26" height="26" viewBox="0 0 24 24" fill="none"
    stroke="currentColor" stroke-width="1.7" stroke-linecap="round" aria-hidden="true">
    <rect x="3" y="5" width="18" height="16" rx="2.5"/><path d="M3 10h18M8 3v4M16 3v4"/></svg>`;

  const when = (label: string, value: string) =>
    `<div>${cal}<div><p class="k">${esc(label)}</p><p class="v">${esc(value)}</p></div></div>`;

  const contacts = (d.contacts ?? []).map((k) => {
    const inner = `<span>${k.icon ? esc(k.icon) + " " : ""}${esc(k.label)}</span><b>${esc(k.value)}</b>`;
    return k.url ? `<a href="${esc(k.url)}" target="_blank" rel="noopener">${inner}</a>`
                 : `<div class="c">${inner}</div>`;
  }).join("");

  // الشعار بالعربية كذلك: هو اسم المتجر لا يُترجم، لكن سطر
  // الوسم يُعرض بلغة الصفحة والعربية معاً كما في النموذج.
  const tagline = lang === "ar" ? esc(t.tagline)
    : `${esc(t.tagline)}<br>${esc(DOC.ar.tagline)}`;

  return page(`${t.title} — Janeiro Store`, `
    ${langSwitch(`/warranty/${d.code}`, lang)}
    <div class="sheet">
      <aside class="side">
        <div class="logo">janeiro<small>STORE</small></div>
        <hr>
        <ul>${t.sideLines.map((x) => `<li>${esc(x)}</li>`).join("")}</ul>
        <div class="foot">
          <p class="lbl">${esc(t.verifiableRef)}</p>
          <div class="qrbox">${qrSvg(verifyUrl(d.code), 92)}</div>
        </div>
      </aside>

      <main class="main">
        <p class="tag">${tagline}</p>
        <h1 class="doc-h1">${esc(t.title)}</h1>
        <p class="doc-sub">${esc(t.subtitle(d.platform))}</p>

        <div class="win">
          ${when(L.activatedOn, formatDate(d.starts_at, lang))}
          ${d.ends_at ? when(L.coveredUntil, formatDate(d.ends_at, lang)) : ""}
        </div>

        <section class="det">
          <h2>${esc(t.detailsHeading)}
            <span class="st ${d.status}">${esc(t.status[d.status])}</span>${
              d.status === "active" && d.days_left !== null
                ? ` <span class="st active">${esc(t.daysLeft(d.days_left))}</span>` : ""}</h2>
          ${row(L.ref, d.ref_code)}
          ${row(L.holder, d.holder_name)}
          ${d.instagram ? row(L.account, "@" + d.instagram) : ""}
          ${row(L.service, d.platform)}
          ${row(L.coverage, t.duration(d.months, 0, d.duration_days),
                d.bonus_days > 0 ? `<span class="pill">${esc(t.bonusPill(d.bonus_days))}</span>` : "")}
          ${row(L.key, d.code)}
        </section>

        <section class="commit">
          <h2>${esc(t.commitmentHeading)}</h2>
          <ol>${commitmentLines(lang).map((line) =>
            `<li><span class="n">${esc(line.slice(0, 2))}</span>` +
            `<span class="d">·</span><span>${esc(line.slice(5))}</span></li>`).join("")}</ol>
        </section>

        <footer class="dfoot">
          <div class="b">Janeiro Store</div>
          <div class="t">${esc(t.verifyHint)}
            <span class="u">${esc(verifyUrl(d.code))}</span></div>
          <div class="q">${qrSvg(verifyUrl(d.code), 64)}</div>
        </footer>
      </main>
    </div>

    <div class="acts noprint">
      <a class="primary" href="/warranty/${esc(d.code)}/image?lang=${lang}"
         download="janeiro-${esc(d.code)}.png">${esc(t.actions.png)}</a>
      <a href="/warranty/${esc(d.code)}/pdf?lang=${lang}">${esc(t.actions.pdf)}</a>
      <button onclick="window.print()">${esc(t.actions.print)}</button>
    </div>
    <p class="note noprint">${esc(t.keep)}</p>
    ${contacts ? `<div class="card contacts noprint"><h2>${esc(t.contactsHeading)}</h2>${contacts}</div>` : ""}`,
    `<style>${ENG_CSS}${DOC_CSS}</style>`, { lang, noindex: true, wide: true });
}

function engVerifyPage(v: {
  found: boolean; code?: string; platform?: string; ends_at?: string | null;
  status?: Engagement["status"]; holder_hint?: string | null;
}, lang: Lang): Response {
  const t = DOC[lang];
  if (!v.found) {
    return page(`Janeiro Store`, `${langSwitch("/warranty/verify/-", lang)}
      <div class="card"><h1>${esc(t.errors.CERTIFICATE_NOT_FOUND)}</h1></div>`,
      `<style>${ENG_CSS}</style>`, { lang, noindex: true });
  }
  return page(`${t.labels.key} — Janeiro Store`, `
    ${langSwitch(`/warranty/verify/${v.code}`, lang)}
    <div class="card">
      <div class="head">
        <div class="brand">Janeiro Store</div>
        <h1>${esc(t.title)}</h1>
        <p class="sub">${esc(t.verifyHint)}</p>
      </div>
      <p class="sub"><span class="st ${v.status}">${esc(t.status[v.status!])}</span></p>
      <div class="dl">
        ${v.holder_hint ? `<div><span>${esc(t.labels.holder)}</span><b>${esc(v.holder_hint)}</b></div>` : ""}
        <div><span>${esc(t.labels.service)}</span><b>${esc(v.platform ?? "")}</b></div>
        ${v.ends_at ? `<div><span>${esc(t.labels.coveredUntil)}</span><b>${esc(formatDate(v.ends_at, lang))}</b></div>` : ""}
        <div><span>${esc(t.labels.key)}</span><b class="mono">${esc(v.code ?? "")}</b></div>
      </div>
    </div><p class="brand">Janeiro Store</p>`,
    `<style>${ENG_CSS}</style>`, { lang, noindex: true });
}

// ------------------------------------------------------------
// الوثيقة: بعد التأكيد، تُجمع بيانات الزبون ثم تصدر
// ------------------------------------------------------------
type IssueFields = {
  fields: { label: string; is_required: boolean }[];
  duration_value: number | null;
  has_certificate: boolean;
};

/* ------------------------------------------------------------
   بعد التأكيد
   ------------------------------------------------------------
   المسار الافتراضي هو وثيقة الالتزام: كل ما كانت تسأل عنه صار
   معروفاً في البيعة، فلا يبقى إلا أيام الهدية.

   ومسار 023 (حقول يكتبها البائع) يبقى كما هو، لكن للمنتجات التي
   عُرّفت لها حقول صراحةً. الاثنان لا يجتمعان على بيعة واحدة —
   issue_id فريد في bot_certificates — فمن عرّف حقولاً لمنتج فقد
   اختار لهذا المنتج ذاك المسار.
   ------------------------------------------------------------ */
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

  await engagementStep(client, chat, tgId, issueId);
}

// ------------------------------------------------------------
// وثيقة الالتزام من البيعة
// ------------------------------------------------------------
type IssueEngagement = {
  issue_id: string;
  status: string;
  product_name: string;
  variant_name: string;
  platform: string | null;
  platforms: string[];
  months: number | null;
  days: number | null;
  needs_platform: boolean;
  needs_duration: boolean;
  has_certificate: boolean;
  certificate_code: string | null;
  projected_start: string | null;
  projected_end: string | null;
};

const BONUS_PROMPT = "🎁 أيام الهدية";
const BONUS_RE = new RegExp(`^${BONUS_PROMPT} — ([0-9a-f-]{36})`);

/** الخطوة التالية للوثيقة: منصة، أم هدية، أم لا شيء لأن شيئاً ينقص. */
async function engagementStep(
  client: SupabaseClient, chat: number, tgId: number, issueId: string, msg?: number,
) {
  const r = await rpc<IssueEngagement>(client, "bot_issue_engagement",
    { p_telegram_id: tgId, p_issue_id: issueId });
  if (r.error) return;                       // البيعة مثبتة؛ الوثيقة إضافة
  const d = r.data!;
  if (d.has_certificate) return;

  const head = `🎟 <b>${esc(d.product_name)} — ${esc(d.variant_name)}</b>`;

  // المدة خاصية للصنف، والبائع لا يملك الكتالوج. فيُقال ما ينقص
  // ولمن يُقال، بدل أن تُخترع مدة أو يُصمَت.
  if (d.needs_duration) {
    await send(chat, [
      "🧾 <b>الوثيقة تحتاج مدّة</b>", "", head, "",
      `لم تُحدَّد مدّة «${esc(d.variant_name)}» بعد، فلا تُعرف نهاية الاشتراك.`,
      "على المالك أن يحدّدها مرة واحدة، ثم تُصدر الوثائق وحدها.", "",
      "<i>البيعة مسجَّلة والبطاقة سُلّمت — الناقص هو الوثيقة وحدها.</i>",
    ].join("\n"), [backRow]);
    return;
  }

  if (d.needs_platform) {
    if (!d.platforms.length) {
      await send(chat, [
        "🧾 <b>الوثيقة تحتاج منصّة</b>", "", head, "",
        `لم تُربط «${esc(d.product_name)}» بأي منصّة، والوثيقة تقول للزبون`,
        "على أي منصّة اشتراكه.",
        "على المالك أن يربطها مرة واحدة.", "",
        "<i>البيعة مسجَّلة والبطاقة سُلّمت — الناقص هو الوثيقة وحدها.</i>",
      ].join("\n"), [backRow]);
      return;
    }
    // الفهرس لا الاسم: حدّ callback_data 64 بايت، وأسماء المنصات
    // تطول. والقائمة نفسها تُقرأ من جديد عند الضغط.
    const rows: Button[][] = [];
    for (let i = 0; i < d.platforms.length; i += 2) {
      rows.push(d.platforms.slice(i, i + 2).map((p, j) => ({
        text: p, callback_data: `ep:${issueId}:${i + j}`,
      })));
    }
    rows.push(backRow);
    const body = [
      "🧾 <b>وثيقة الالتزام</b>", "", head, "",
      "🎯 على أي منصّة هذا الاشتراك؟",
    ].join("\n");
    if (msg) await edit(chat, msg, body, rows); else await send(chat, body, rows);
    return;
  }

  await askBonus(client, chat, tgId, d, msg);
}

/** السؤال الوحيد الباقي: أيام الهدية. */
async function askBonus(
  client: SupabaseClient, chat: number, tgId: number,
  d: IssueEngagement, msg?: number,
) {
  const body = [
    "🧾 <b>وثيقة الالتزام</b>", "",
    `🎟 <b>${esc(d.product_name)} — ${esc(d.variant_name)}</b>`,
    `🏷 ${esc(d.platform ?? "")}`,
    `⏳ ${esc(DOC.ar.duration(d.months, 0, d.days))}`,
    `📅 ${dayAr(d.projected_start)} ← ${dayAr(d.projected_end)}`,
    "", "🎁 <b>أيام هدية من المزوّد؟</b>",
    "<i>«لا» هو الأغلب — تُزاد فقط إن أعطاها المزوّد فعلاً.</i>",
  ].join("\n");
  const kb: Button[][] = [
    [{ text: "لا",  callback_data: `eb:${d.issue_id}:0` },
     { text: "7",   callback_data: `eb:${d.issue_id}:7` },
     { text: "14",  callback_data: `eb:${d.issue_id}:14` },
     { text: "✏️ يدوي", callback_data: `ebm:${d.issue_id}` }],
    backRow,
  ];
  if (msg) await edit(chat, msg, body, kb); else await send(chat, body, kb);
}

/** الإصدار: رابط للزبون ومعاينة قصيرة لما سيقرأه. */
async function engagementIssue(
  client: SupabaseClient, chat: number, tgId: number,
  issueId: string, bonus: number, msg?: number,
) {
  const r = await rpc<{
    code: string; ref_code: string; token: string;
    platform: string; product_name: string; variant_name: string;
    months: number | null; duration_days: number | null; bonus_days: number;
    starts_at: string; ends_at: string; expires_at: string;
  }>(client, "bot_engagement_from_issue",
     { p_telegram_id: tgId, p_issue_id: issueId, p_bonus_days: bonus, p_hours: 72 });
  if (r.error) { await send(chat, r.error, [backRow]); return; }

  const d = r.data!;
  const link = claimUrl(d.token);
  const body = [
    "✅ <b>الوثيقة جاهزة</b>", "",
    `🎟 ${esc(d.product_name)} — ${esc(d.variant_name)}`,
    `🏷 ${esc(d.platform)}`,
    `⏳ ${esc(DOC.ar.duration(d.months, d.bonus_days, d.duration_days))}`,
    `📅 يبدأ: <b>${dayAr(d.starts_at)}</b>`,
    `📅 ينتهي: <b>${dayAr(d.ends_at)}</b>`,
    `🔖 ${esc(d.ref_code)}`, "",
    "أرسل هذا الرابط للزبون. يكتب اسمه ورقمه ويوزره، فتصدر له",
    "الوثيقة جاهزة للتحميل أو الطباعة.", "",
    `<code>${esc(link)}</code>`, "",
    `<i>صالح حتى ${dayAr(d.expires_at)} — 72 ساعة، ويُستعمل مرة واحدة.</i>`,
  ].join("\n");
  const kb: Button[][] = [
    [{ text: "📋 نسخ الرابط", copy_text: { text: link } }],
    [{ text: "🛒 بيع أخرى", callback_data: "m:sell" }],
    backRow,
  ];
  if (msg) await edit(chat, msg, body, kb); else await send(chat, body, kb);
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
const WZ_MONTHS_PROMPT   = "⏳ المدة بالأشهر";
const WZ_DAYS_PROMPT     = "⏳ المدة بالأيام";
const WZ_BONUS_RE    = new RegExp(`^${WZ_BONUS_PROMPT}`);
const WZ_PLATFORM_RE = new RegExp(`^${WZ_PLATFORM_PROMPT}`);
const WZ_MONTHS_RE   = new RegExp(`^${WZ_MONTHS_PROMPT}`);
const WZ_DAYS_RE     = new RegExp(`^${WZ_DAYS_PROMPT}`);

type Wizard = {
  awaiting: string | null;
  platform: string | null;
  months: number | null;
  duration_days: number | null;
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
  out.push(line("المدة",
    w.months || w.duration_days
      ? DOC.ar.duration(w.months, 0, w.duration_days)
      : null));
  out.push(line("أيام الهدية",
    w.bonus_days === null ? null : w.bonus_days === 0 ? "لا" : `${w.bonus_days}`));

  if (w.ready) {
    out.push("", `📅 يبدأ: <b>${dayAr(w.projected_start)}</b>`);
    out.push(`📅 ينتهي: <b>${dayAr(w.projected_end)}</b>`);
    out.push("", `<i>التغطية: ${
      esc(DOC.ar.duration(w.months, w.bonus_days!, w.duration_days))}</i>`);
  } else {
    out.push("", ({
      platform:        "اختر المنصة:",
      months:          "اختر المدة:",
      bonus:           "أيام هدية؟",
      bonus_manual:    `أرسل عدد أيام الهدية (${CUSTOM.bonus.min}–${CUSTOM.bonus.max}).`,
      platform_manual: "أرسل اسم المنصة.",
      months_manual:   `أرسل عدد الأشهر (${CUSTOM.months.min}–${CUSTOM.months.max}).`,
      days_manual:     `أرسل عدد الأيام (${CUSTOM.days.min}–${CUSTOM.days.max}).`,
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
      text: DOC.ar.duration(m, 0, null), callback_data: `wm:${m}`,
    })));
    rows.push([
      { text: "✏️ أشهر أخرى", callback_data: "wz:months_manual" },
      { text: "✏️ بالأيام",   callback_data: "wz:days_manual" },
    ]);
  } else if (w.awaiting === "bonus") {
    rows.push(BONUS_CHOICES.map((b) => ({
      text: b === 0 ? "لا" : String(b), callback_data: `wb:${b}`,
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
    platform: string; months: number | null; duration_days: number | null;
    bonus_days: number; starts_at: string; ends_at: string; expires_at: string;
  }>(client, "bot_engagement_confirm", { p_telegram_id: tgId, p_hours: 72 });
  if (r.error) { await send(chat, r.error, [backRow]); return; }

  const d = r.data!;
  const link = claimUrl(d.token);
  const body = [
    "✅ <b>الوثيقة جاهزة</b>", "",
    `🏷 ${esc(d.platform)}`,
    `⏳ ${esc(DOC.ar.duration(d.months, d.bonus_days, d.duration_days))}`,
    `📅 يبدأ: <b>${dayAr(d.starts_at)}</b>`,
    `📅 ينتهي: <b>${dayAr(d.ends_at)}</b>`,
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

/* وحدات المخزون الأربع إلى وحدتي الوثيقة، كما في
   bot_duration_to_engagement — والترجمة هناك هي المرجع، وهذه
   للعرض وحده. */
function durationText(value: number | null, unit: string | null): string {
  if (!value || !unit) return "<i>بلا مدّة</i>";
  if (unit === "year")  return DOC.ar.duration(value * 12, 0, null);
  if (unit === "month") return DOC.ar.duration(value, 0, null);
  if (unit === "week")  return DOC.ar.duration(null, 0, value * 7);
  return DOC.ar.duration(null, 0, value);
}

/** جرد الكتالوج: ما هو معمَّر وما ينقص، وأمر تصحيحه بجنبه. */
async function catalogReport(
  client: SupabaseClient, chat: number, tgId: number,
) {
  type Cat = {
    products: {
      code: string; name: string; is_active: boolean; platforms: string[];
      variants: {
        code: string; name: string; is_active: boolean;
        value: number | null; unit: string | null; stock: number;
        prices: Record<string, number>;
      }[];
    }[];
    markets: { code: string; name: string; currency: string }[];
    sellers: { telegram_id: number; name: string; role: string; market: string | null }[];
  };
  const r = await rpc<Cat>(client, "bot_catalog_report", { p_telegram_id: tgId });
  if (r.error) { await send(chat, r.error, [backRow]); return; }
  const d = r.data!;
  const cur = Object.fromEntries(d.markets.map((m) => [m.code, m.currency]));

  const out: string[] = ["🗂 <b>الكتالوج</b>"];
  for (const p of d.products) {
    out.push("", `<b>${esc(p.name)}</b> <code>${esc(p.code)}</code>` +
      (p.is_active ? "" : " <i>(مخفيّ)</i>"));
    out.push(p.platforms.length
      ? "🏷 " + p.platforms.map(esc).join(" · ")
      : `🏷 <i>بلا منصّة</i> — <code>/platform ${esc(p.code)} Netflix</code>`);

    for (const v of p.variants) {
      const dur = durationText(v.value, v.unit);
      const price = d.markets.map((m) =>
        v.prices[m.code] === undefined
          ? `${m.code}: —`
          : `${m.code}: ${v.prices[m.code]} ${cur[m.code]}`).join(" · ");
      out.push(`  • <b>${esc(v.name)}</b> <code>${esc(v.code)}</code> — ` +
        `${dur} — مخزون ${v.stock}`);
      out.push(`    💰 ${esc(price)}`);
      if (!v.value) out.push(`    <code>/duration ${esc(p.code)} ${esc(v.code)} 1 سنة</code>`);
      if (d.markets.some((m) => v.prices[m.code] === undefined)) {
        out.push(`    <code>/price ${esc(p.code)} ${esc(v.code)} ` +
          `${esc(d.markets[0].code)} 3500</code>`);
      }
    }
  }

  out.push("", "📄 <b>الصفحات</b>: " +
    d.markets.map((m) => `${esc(m.name)} (${esc(m.currency)})`).join(" · "));
  out.push("👥 <b>البائعون</b>");
  for (const sl of d.sellers) {
    const mk = d.markets.find((m) => m.code === sl.market);
    out.push(`  • ${esc(sl.name)} <code>${sl.telegram_id}</code> — ` +
      (mk ? esc(mk.name) : "<i>الصفحتان</i>"));
  }

  await send(chat, out.join("\n"), [backRow]);
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

    // ---------- الكتالوج: منصات ومدد وأسعار ----------
    case "/platform":
    case "/unplatform": {
      const rm = cmd === "/unplatform";
      if (args.length < 2) {
        await send(chat, `الصيغة: <code>${cmd} giftcard Netflix</code>` +
          (rm ? "" : "\n\nاسم غير موجود في القائمة يُضاف إليها."));
        return;
      }
      const r = await rpc<{ product: string; platforms: string[] }>(
        client, "bot_cmd_platform", {
          p_telegram_id: tgId, p_product_code: args[0],
          p_platform: args.slice(1).join(" "), p_remove: rm,
        });
      if (r.error) { await send(chat, r.error, [backRow]); return; }
      const list = r.data!.platforms;
      await send(chat, [
        `✅ <b>${esc(r.data!.product)}</b>`, "",
        list.length
          ? "منصّاته الآن: " + list.map((x) => `<b>${esc(x)}</b>`).join(" · ")
          : "<i>بلا منصّات — الوثيقة لن تعرف ما تكتب.</i>",
      ].join("\n"), [backRow]);
      return;
    }

    case "/duration": {
      if (args.length < 4) {
        await send(chat, [
          "الصيغة: <code>/duration giftcard year 1 سنة</code>", "",
          "الوحدات: يوم · أسبوع · شهر · سنة",
          "<i>تُحسب منها نهاية الاشتراك في وثيقة الزبون.</i>",
        ].join("\n"));
        return;
      }
      const r = await rpc<{ variant: string; months: number | null; days: number | null }>(
        client, "bot_cmd_duration", {
          p_telegram_id: tgId, p_product_code: args[0], p_variant_code: args[1],
          p_value: Number(args[2]), p_unit: args.slice(3).join(" "),
        });
      if (r.error) { await send(chat, r.error, [backRow]); return; }
      await send(chat,
        `✅ <b>${esc(r.data!.variant)}</b> — ` +
        esc(DOC.ar.duration(r.data!.months, 0, r.data!.days)), [backRow]);
      return;
    }

    case "/price": {
      if (args.length < 4) {
        const mk = await rpc<{ code: string; name: string; currency: string }[]>(
          client, "bot_markets_list", { p_telegram_id: tgId });
        await send(chat, [
          "الصيغة: <code>/price giftcard year dz 3500</code>", "",
          "الصفحات: " + (mk.data ?? []).map((m) =>
            `<code>${esc(m.code)}</code> ${esc(m.name)} (${esc(m.currency)})`).join(" · "),
          "", "<i>سعر لكل صفحة. و<code>-</code> بدل المبلغ يمسحه.</i>",
        ].join("\n"));
        return;
      }
      const raw = args[3];
      const r = await rpc<{ product: string; variant: string; market_name: string;
                            price: number | null; currency: string }>(
        client, "bot_cmd_price", {
          p_telegram_id: tgId, p_product_code: args[0], p_variant_code: args[1],
          p_market: args[2], p_price: raw === "-" ? null : Number(raw),
        });
      if (r.error) { await send(chat, r.error, [backRow]); return; }
      const d = r.data!;
      await send(chat, d.price === null
        ? `✅ مُسح سعر <b>${esc(d.variant)}</b> في ${esc(d.market_name)}`
        : `✅ <b>${esc(d.product)} — ${esc(d.variant)}</b>\n` +
          `${esc(d.market_name)}: <b>${d.price} ${esc(d.currency)}</b>`, [backRow]);
      return;
    }

    case "/market": {
      if (args.length < 2) {
        await send(chat, "الصيغة: <code>/market jo on</code> — أو <code>off</code>");
        return;
      }
      const on = ["on", "1", "نعم", "فتح"].includes(args[1].toLowerCase());
      const r = await rpc<{ name: string; currency: string; is_active: boolean }>(
        client, "bot_set_market_active",
        { p_telegram_id: tgId, p_market: args[0], p_active: on });
      if (r.error) { await send(chat, r.error, [backRow]); return; }
      await send(chat, `✅ صفحة <b>${esc(r.data!.name)}</b> (${esc(r.data!.currency)}) — ` +
        (r.data!.is_active ? "مفتوحة" : "مغلقة"), [backRow]);
      return;
    }

    case "/seller": {
      if (args.length < 2) {
        await send(chat, [
          "الصيغة: <code>/seller 123456789 dz</code>", "",
          "<i>يربط البائع بصفحته فلا يُسأل عنها. و<code>-</code> يفكّ",
          "الربط: يبيع في الصفحتين ويُسأل عند كل بيعة.</i>",
        ].join("\n"));
        return;
      }
      const r = await rpc<{ name: string; market: string | null; market_name: string | null }>(
        client, "bot_set_admin_market", {
          p_telegram_id: tgId, p_target_telegram_id: Number(args[0]),
          p_market: args[1] === "-" ? null : args[1],
        });
      if (r.error) { await send(chat, r.error, [backRow]); return; }
      const d = r.data!;
      await send(chat, d.market
        ? `✅ <b>${esc(d.name)}</b> → صفحة ${esc(d.market_name ?? d.market)}`
        : `✅ <b>${esc(d.name)}</b> → الصفحتان، ويُسأل عند كل بيعة`, [backRow]);
      return;
    }

    case "/catalog": {
      await catalogReport(client, chat, tgId);
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
    if (["bonus_manual", "platform_manual", "months_manual", "days_manual"]
          .includes(arg)) {
      await answer(cbId);
      const r = await rpc<Wizard>(client, "bot_wizard_set",
        { p_telegram_id: tgId, p_step: arg, p_value: "" });
      if (r.error) { await answer(cbId, r.error, true); return; }
      const prompts: Record<string, [string, string, string]> = {
        bonus_manual:   [WZ_BONUS_PROMPT,
          `بعدد أيام الهدية (${CUSTOM.bonus.min}–${CUSTOM.bonus.max}).`, "عدد الأيام"],
        months_manual:  [WZ_MONTHS_PROMPT,
          `بعدد الأشهر (${CUSTOM.months.min}–${CUSTOM.months.max}).`, "عدد الأشهر"],
        days_manual:    [WZ_DAYS_PROMPT,
          `بعدد الأيام (${CUSTOM.days.min}–${CUSTOM.days.max}).`, "عدد الأيام"],
        platform_manual: [WZ_PLATFORM_PROMPT, "باسم المنصة.", "اسم المنصة"],
      };
      const [head, tail, ph] = prompts[arg];
      await ask(chat, `${head}\n\nردّ على هذه الرسالة ${tail}`, ph);
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
  // ---------- وثيقة الالتزام من البيعة ----------
  if (verb === "ep") {
    // arg = "<issueId>:<index>" — الفهرس يُحلّ إلى اسم من القائمة
    // الحيّة، فمنصة حُذفت بين العرض والضغط لا تمرّ.
    const at = arg.lastIndexOf(":");
    const issueId = arg.slice(0, at);
    const idx = Number(arg.slice(at + 1));
    const st = await rpc<IssueEngagement>(client, "bot_issue_engagement",
      { p_telegram_id: tgId, p_issue_id: issueId });
    if (st.error) { await answer(cbId, st.error, true); return; }
    const name = st.data!.platforms[idx];
    if (!name) { await answer(cbId, "المنصّة لم تعد متاحة", true); return; }
    const r = await rpc(client, "bot_issue_set_platform",
      { p_telegram_id: tgId, p_issue_id: issueId, p_platform: name });
    if (r.error) { await answer(cbId, r.error, true); return; }
    await answer(cbId, name);
    await engagementStep(client, chat, tgId, issueId, msg);
    return;
  }

  if (verb === "eb") {
    const at = arg.lastIndexOf(":");
    await answer(cbId);
    await engagementIssue(client, chat, tgId,
      arg.slice(0, at), Number(arg.slice(at + 1)), msg);
    return;
  }

  if (verb === "ebm") {
    await answer(cbId);
    await ask(chat, [
      `${BONUS_PROMPT} — ${arg}`, "",
      "ردّ على هذه الرسالة بعدد أيام الهدية (0 إلى 90).",
    ].join("\n"), "عدد الأيام");
    return;
  }

  if (verb === "eng") { await answer(cbId); await engagementStep(client, chat, tgId, arg, msg); return; }

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
      // وثيقة هذه البيعة، لا فلو جديد من الصفر: الزرّ يحمل رقمها
      [{ text: "🧾 وثيقة التزام", callback_data: `eng:${arg}` }],
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
  // المسارات الجميلة على دومين المتجر أولاً (vercel.json يحوّلها
  // إلى هنا)، ثم المعاملات كاحتياط إن لم يُضبط PUBLIC_SITE_URL.
  const p = url.pathname.replace(/\/+$/, "");
  const mClaim  = p.match(/\/warranty\/claim\/([0-9a-f]{32,})$/i);
  const mVerify = p.match(/\/warranty\/verify\/([A-Za-z0-9-]{8,})$/);
  const mDoc    = p.match(/\/warranty\/(JW-[A-Za-z0-9]{6,})$/i);

  const claim  = mClaim?.[1]  ?? url.searchParams.get("claim");
  const verify = mVerify?.[1] ?? url.searchParams.get("verify");
  const doc    = mDoc?.[1]    ?? url.searchParams.get("doc");
  const fill = url.searchParams.get("fill");
  const cert = url.searchParams.get("cert");
  if (!claim && !verify && !doc && !fill && !cert) return null;

  const client = db();
  const q = url.searchParams.get("lang");
  const lang: Lang = isLang(q) ? q : "ar";
  const ip = req.headers.get("x-forwarded-for")?.split(",")[0].trim() ?? "";

  // ---------- وثيقة التزام الخدمة ----------
  if (verify) {
    const { data, error } = await client.rpc("bot_engagement_verify", { p_code: verify });
    if (error) return page("Janeiro Store",
      `<div class="card"><h1>${esc(docError(String(error.message ?? ""), lang))}</h1></div>`,
      "", { lang, noindex: true });
    return engVerifyPage(data as Parameters<typeof engVerifyPage>[0], lang);
  }

  if (doc) {
    const { data, error } = await client.rpc("bot_engagement_public", { p_code: doc });
    if (error) return page("Janeiro Store",
      `<div class="card"><h1>${esc(docError(String(error.message ?? ""), lang))}</h1></div>`,
      "", { lang, noindex: true });
    return engDocPage(data as Engagement, lang);
  }

  if (claim) {
    const shape = await client.rpc("bot_engagement_claim_form", { p_token: claim });
    if (shape.error) return page("Janeiro Store",
      `<div class="card"><h1>${esc(docError(String(shape.error.message ?? ""), lang))}</h1></div>`,
      "", { lang, noindex: true });

    if (req.method === "GET") {
      return engFormPage(claim, shape.data as {
        platform: string; months: number | null; duration_days: number | null;
  bonus_days: number;
      }, lang);
    }

    const form = await req.formData().catch(() => null);
    if (!form) return errPage(DOC[lang].errors.UNKNOWN);

    // الحدّ في نداء مستقل قبل العمل: استثناء الدالة يُرجِع
    // معاملتها ومعها عدّاد المحاولات، فتصير المحاولة الفاشلة مجانية.
    const guard = await client.rpc("bot_claim_guard", { p_token: claim, p_ip: ip });
    if (guard.data === false) return page("Janeiro Store",
      `<div class="card"><h1>${esc(DOC[lang].errors.RATE_LIMITED)}</h1></div>`,
      "", { lang, noindex: true });

    const { data, error } = await client.rpc("bot_engagement_claim", {
      p_token: claim,
      p_name: String(form.get("full_name") ?? ""),
      p_whatsapp: String(form.get("whatsapp") ?? ""),
      p_instagram: String(form.get("instagram") ?? "") || null,
      p_ip: ip,
    });
    if (error) {
      // الخطأ يُعاد داخل الاستمارة نفسها لا في صفحة ميتة
      const body = (engFormPage(claim, shape.data as {
        platform: string; months: number | null; duration_days: number | null;
  bonus_days: number;
      }, lang) as Response);
      const html = await body.text();
      return new Response(html.replace("<form",
        `<div class="note err">${esc(docError(String(error.message ?? ""), lang))}</div><form`),
        { status: 200, headers: { "Content-Type": "text/html; charset=utf-8" } });
    }

    const out = data as { code: string; issued_by_telegram_id: number };
    await send(Number(out.issued_by_telegram_id), [
      "✅ <b>الزبون عبّأ وثيقته</b>", "",
      `🔖 <code>${esc(out.code)}</code>`, "",
      `<a href="${esc(docUrl(out.code))}">الوثيقة</a>`,
    ].join("\n"));

    // إعادة توجيه إلى الوثيقة: التحديث لا يعيد الإرسال.
    // الفاصل يُحسب لا يُفترض: الشكل الاحتياطي فيه «؟» أصلاً،
    // فكان الرابط يخرج ?doc=JW-…?lang=fr بعلامتَي استفهام.
    const base = docUrl(out.code);
    return new Response(null, {
      status: 303,
      headers: { Location: `${base}${base.includes("?") ? "&" : "?"}lang=${lang}` },
    });
  }


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

    const eb = replied.match(BONUS_RE);
    if (eb) {
      const n = Number(text.trim().replace(/[٠-٩]/g, (c) => String("٠١٢٣٤٥٦٧٨٩".indexOf(c))));
      if (!Number.isInteger(n) || n < 0 || n > 90) {
        await send(chat, "🎁 عدد صحيح من 0 إلى 90 — أعد الضغط على «يدوي».");
      } else {
        await engagementIssue(client, chat, src.id, eb[1], n);
      }
      return new Response("ok");
    }

    for (const [re, step, range] of [
      [WZ_MONTHS_RE, "months", CUSTOM.months],
      [WZ_DAYS_RE,   "days",   CUSTOM.days],
    ] as const) {
      if (!re.test(replied)) continue;
      const n = parseCount(text);
      const bad = checkRange(n, range);
      if (bad) { await send(chat, `⏳ ${bad}`); return new Response("ok"); }
      await wizardStep(client, chat, src.id, step, String(n));
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
