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

export type Lang = "ar" | "fr" | "en";
export const LANGS: Lang[] = ["ar", "fr", "en"];
export const isLang = (v: unknown): v is Lang =>
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
export function formatDate(iso: string | null, lang: Lang): string {
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
    /* لا تُعرض: الاستمارة لا تضع قوساً بجنب أيّ عنوان. تبقى
       الكلمة مترجَمةً لأنّ حقول المنتجات (/addfield) قد تحتاجها،
       ولا تعود إلى استمارة الزبون. */
    optional: string;
    whatsappHint: string; instagramHint: string;
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

export const DOC: Record<Lang, Doc> = {
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
      instagramHint: "بلا @ — به يُعرف حسابك المفعَّل",
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
      instagramHint: "sans @ — il identifie le compte activé",
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
      instagramHint: "without @ — it identifies the activated account",
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
export const commitmentLines = (lang: Lang): string[] =>
  DOC[lang].commitment.map((t, i) => `${String(i + 1).padStart(2, "0")} · ${t}`);

/** رسالة خطأ للزبون بلغته، بلا تسريب رمز داخلي. */
export function docError(raw: string, lang: Lang): string {
  const code = raw.split(":")[0].trim().replace(/[^A-Z_]/g, "");
  return DOC[lang].errors[code] ?? DOC[lang].errors.UNKNOWN;
}
