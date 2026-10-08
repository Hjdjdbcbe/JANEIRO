/* ============================================================
   نصوص بوت التفعيل — كيما كتبها مالك (القسم 7).
   النصوص الثابتة تتبعث فورا بلا AI. ما تتبدلش هنا إلا بطلب منو.
   ============================================================ */

const TYPE_LABEL = { month: "شهر", two_months: "شهرين", year: "سنة" };

// أسماء الأزرار حسب لغة تيليفون الكليان (كيما بانت في الصورة)
const UI = {
  fr: { monthly: "Mensuel", trial: "Démarrer l'essai gratuit" },
  en: { monthly: "Monthly", trial: "Start Free Trial" },
  ar: { monthly: "شهري", trial: "بدء الفترة التجريبية المجانية" },
};

const BTN = {
  problem: "عندي مشكل",
  activated: "تفعّل ✅",
  take: "ناخذ المحادثة",
  release: "رجع للبوت",
  close: "غلق الطلب",
  accept: "قبول",
  reject: "رفض",
};

const T = {
  askCode:
    "مرحبا 👋 ابعثلي كود الطلب لي عطاهولك Janeiro Store (مثال: JN-1234).",
  badCode: "الكود هذا مش صحيح. تأكد منو ولا راسل Janeiro Store في إنستا.",

  welcome: (type) =>
    `مرحبا 👋 طلبك: سناب بلس ${TYPE_LABEL[type]}. نبداو التفعيل.\n\n` +
    "1️⃣ بدل بلاد App Store كيما في الفيديو 👇\n" +
    "2️⃣ كي تكمل، حل سناب ← البروفيل ← البطاقة بالإطار الأصفر تحت الاسم ← Suivant، وصورلي الصفحة لي تطلعلك 📸",

  whereToShoot:
    "حل سناب ← البروفيل ← البطاقة بالإطار الأصفر تحت الاسم ← Suivant، وصورلي الصفحة لي تطلعلك 📸",
  countryNotChanged:
    "البلاد ما تبدلتش 🙏 بدل بلاد App Store كيما في الفيديو 👇 ومن بعد عاود صورلي صفحة سناب.",
  clearerPhoto: "الصورة ما بانتش مليح 🙏 تقدر تبعثلي صورة أوضح؟",
  holdOn: "دقيقة، راح يكمل معاك مالك.",
  handoff: "دقيقة، راح يكمل معاك مالك 🙏",
  justAMinute: "دقيقة برك 🙏",
  reviewWait: "دقيقة برك، راني نشوف في الصورة 🙏",
  stillReviewing: "مازال نشوف في الصورة، دقيقة برك 🙏",

  link: (giftCode) =>
    "صورتك صحيحة ✅\n" +
    "اضغط على هذا الرابط 👇 ابقى فيه 20 ثانية واخرج منو:\n" +
    `https://apps.apple.com/redeem/?code=${encodeURIComponent(giftCode)}`,

  sameLink: (giftCode) =>
    `https://apps.apple.com/redeem/?code=${encodeURIComponent(giftCode)}`,

  activation: (type, lang, hasTrial) => {
    const ui = UI[lang] || UI.fr;
    const step2 = type === "month" && hasTrial === false
      ? "2️⃣ كليكي على الزر الأصفر لتحت."
      : `2️⃣ كليكي على « ${ui.trial} ».`;
    const tail = {
      month: "",
      two_months: "\n\n💬 كي يكمل، غير راسلني ميساج باش نقولك كيفاه نديروه اشتراك شهرين. 🙌",
      year: "\n\n💬 كي يكمل، غير راسلني ميساج ونكمّلهولك باش يولي اشتراك عام. 🙌",
    }[type];
    return (
      "بعدها روحي سناب ديري هكدا:\n\n" +
      `1️⃣ خلّيها على الخيار اللوّل (${ui.monthly}) — ما تبدّل والو.\n` +
      `${step2}\n` +
      "3️⃣ كليكي مرتين على الزر الجانبي (اللي تقفل بيه التيليفون).\n" +
      "4️⃣ يمكن يطلب منك mot de passe تاع iCloud — دخّلو.\n" +
      "5️⃣ كليكي OK.\n" +
      "6️⃣ من بعد كليكي Agree.\n\n" +
      "✅ ويتفعّل عندك Snapchat+." + tail
    );
  },

  planTwoMonths:
    "دروك نرجعوه اشتراك شهرين، دير كيما في الفيديو 👇\n" +
    "App Store ← البروفيل ← Subscriptions ← Snapchat ← See All Plans ← اختار الخيار الثاني « Snapchat+ Monthly Plan — ₹49 » ← Change Subscription ← كليكي مرتين على الزر الجانبي.\n" +
    "كي تكمل، صورلي صفحة Subscriptions 📸",

  planYear:
    "دروك نرجعوه اشتراك عام، دير كيما في الفيديو 👇\n" +
    "App Store ← البروفيل ← Subscriptions ← Snapchat ← See All Plans ← اهبط لتحت واختار « Snapchat+ (Annual Plan) — ₹199 per year » ← Change Subscription ← كليكي مرتين على الزر الجانبي.\n" +
    "⚠️ اختار لي مكتوب فيه Annual Plan و ₹199، مش « 12-Month Plan » تاع ₹299.\n" +
    "كي تكمل، صورلي صفحة Subscriptions 📸",

  congrats: "مبروك، كلش تمام ✅",
  wrong12Month: "اخترت 12-Month بالغلط، ارجع واختار Annual Plan ₹199.",

  finalMonth:
    "كيفاش يمشي اشتراك سناب بلس (شهر):\n\n" +
    "1️⃣ الأسبوع الأول مجاني 🎁 ما يتنحالك والو.\n" +
    "2️⃣ بعد الأسبوع يتنحى ثمن الشهر الأول (₹99).\n\n" +
    "🚫 الرصيد اللي في Apple Store خاص بسناب بلس برك، ما تشري بيه حتى اشتراك ولا حاجة في حتى تطبيق آخر، وإلا ما يكفيش لاشتراك شهر.",

  finalTwoMonths:
    "كيفاش يمشي اشتراك سناب بلس (شهرين):\n\n" +
    "1️⃣ الأسبوع الأول مجاني 🎁 ما يتنحالك والو.\n" +
    "2️⃣ بعد الأسبوع يتنحى ثمن الشهر الأول (₹49).\n" +
    "3️⃣ كي يكمل الشهر الأول يتجدد الاشتراك أوتوماتيكياً ويتنحى ثمن الشهر الثاني (₹49).\n" +
    "4️⃣ من بعد ما يتنحى الشهر الثاني ✅ تقدر ترجع حسابك في App Store لبلاد الجزائر 🇩🇿.\n\n" +
    "🚫 الرصيد اللي في Apple Store خاص بسناب بلس برك، ما تشري بيه حتى اشتراك ولا حاجة في حتى تطبيق آخر، وإلا ما يكفيش لتجديد الشهر الثاني.",

  finalYear:
    "كيفاش يمشي اشتراك سناب بلس (سنة):\n\n" +
    "1️⃣ الأسبوع الأول مجاني 🎁 ما يتنحالك والو.\n" +
    "2️⃣ بعد الأسبوع يتنحى ثمن السنة (₹199).\n" +
    "3️⃣ من بعد ما يتنحى ثمن السنة ✅ تقدر ترجع حسابك في App Store لبلاد الجزائر 🇩🇿.\n\n" +
    "🚫 الرصيد اللي في Apple Store خاص بسناب بلس برك، ما تشري بيه حتى اشتراك ولا حاجة في حتى تطبيق آخر، وإلا ما يكفيش لاشتراك السنة.",

  // ملف المشاكل (القسم 9)
  pNoSubscriptions:
    "كي تضغط على البروفيل في App Store، اضغط على اسمك الفوق، تتحل صفحة فيها Subscriptions.",
  pRedeemScreen: "عادي. اخرج منها برك وروح دير خطوات التفعيل.",
  pContinue: (giftCode) =>
    "اضغط Continue، ومن بعد ارجع اضغط على الرابط من جديد، ابقى فيه 20 ثانية واخرج.\n" +
    T.sameLink(giftCode),
  pBalanceShown: "مليح، الرصيد تزاد، روح فعّل.",
  pNoBalanceRetry: (giftCode) =>
    "ارجع اضغط على الرابط، ابقى فيه 20 ثانية واخرج، وعاود التفعيل.\n" + T.sameLink(giftCode),
  pAskBalanceShot:
    "حل App Store، اضغط على البروفيل، اضغط على اسمك، وصورلي الصفحة باش نشوفو الرصيد.",
  pBalanceOkRetry: "الرصيد يكفي ✅ عاود خطوات التفعيل:",
  pRestartPhone: "طفي التيليفون وعاود شعلو، ومن بعد عاود خطوات التفعيل.",
  pAskCountryShot:
    "حل App Store، اضغط على البروفيل، اضغط على اسمك، وصورلي الصفحة باش نشوفو البلاد.",
  sendScreenshot: "ابعثلي سكرينشوت نعطيك الحل 📸",
  problemPrompt: "قولي واش صرالك، ولا خير: ابعثلي سكرينشوت نعطيك الحل 📸",

  // الفوكالات
  voiceUnclear: "ما سمعتش الفوكال مليح 🙏 تقدر تكتبلي ولا تبعثلي سكرينشوت؟",

  password:
    "⚠️ ما تبعثش mot de passe في الشات! امسحو، ودخّلو في تيليفونك برك كي يطلبو منك.",
  moneyQuestion: "هذي يجاوبك عليها مالك.",
  rateLimited: "شوية شوية 🙏 استنى دقيقة وعاود.",
  resume: "رجعت معاك 👋 نكملو.",
  done: "اشتراكك كامل ✅ إذا عندك سؤال، راسل Janeiro Store في إنستا.",

  // تذكير الخطوة بعد /release
  stepReminder: {
    WAIT_SNAP_SCREENSHOT: () =>
      "صورلي صفحة سناب: البروفيل ← البطاقة بالإطار الأصفر تحت الاسم ← Suivant 📸",
    WAIT_ACTIVATION_DONE: () => "كي يتفعّل عندك Snapchat+، اضغط [تفعّل ✅].",
    WAIT_PLAN_CHANGE: () => "كي تكمل تبديل الخطة، صورلي صفحة Subscriptions 📸",
    WAIT_CONFIRM_SCREENSHOT: () => "كي تكمل تبديل الخطة، صورلي صفحة Subscriptions 📸",
  },
};

function finalText(type) {
  return { month: T.finalMonth, two_months: T.finalTwoMonths, year: T.finalYear }[type];
}

module.exports = { T, BTN, UI, TYPE_LABEL, finalText };
