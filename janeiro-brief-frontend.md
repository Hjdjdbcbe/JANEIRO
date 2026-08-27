# Janeiro Store — Frontend Redesign Brief

تعامل مع هذا المشروع كـ **Senior UI/UX Designer + Senior Frontend Engineer**، وليس كمساعد يعدّل CSS.

---

## 0. الوضع الحالي — اقرأ هذا أولاً

**النطاق: Frontend فقط. لا باكند في هذه المرحلة.**

- ما لديّ حالياً هو **نموذج تصميم بملف HTML واحد** (مرفق) — مرجع للوظائف والمنطق فقط، **وليس مرجعاً للتصميم**.
- **لا يوجد**: قاعدة بيانات، Supabase، استضافة، ربط WhatsApp فعلي، APIs، environment variables.
- **لا تبنِ أي باكند الآن**، ولا تربط أي خدمة خارجية، ولا تنشر على أي استضافة.
- كل البيانات (منتجات، تصنيفات، أسعار) تبقى في **ملف بيانات محلي** (مثلاً `data/products.ts`).
- **مهم**: صمّم البنية بحيث يسهل لاحقاً استبدال مصدر البيانات المحلي بـAPI حقيقي دون إعادة كتابة الواجهة. افصل طبقة البيانات عن طبقة العرض.

اقترح الـstack المناسب أولاً (أفكّر في Next.js أو Vite + React) وانتظر موافقتي قبل التنفيذ.

---

## 1. الهوية

المشروع: **Janeiro Store** — متجر جزائري للمنتجات والخدمات الرقمية.

**ممنوع تماماً:**
Dark futuristic · Cyberpunk · Neon · بنفسجي في كل مكان · Glassmorphism مبالغ فيه · Gradient على كل card · أشكال عشوائية · واجهات Crypto/Gaming · تقليد Foxy Store أو أي متجر آخر.

**المطلوب:** Digital Commerce Brand حقيقي ومستقل.

الكلمات المفتاحية: Clean · Premium · Bright · Modern · Editorial · Friendly · Trustworthy · Minimal but not empty · Distinctive.

الهدف: أن يتعرّف المستخدم على تصميم Janeiro حتى بدون رؤية الاسم.

---

## 2. الألوان

**Light Theme أساساً.** التوزيع تقريباً: 70% أبيض · 15% رمادي/نصوص · 10% أزرق · 5% بنفسجي.

```
Background          #FFFFFF
Secondary BG        #F7F8FC
Soft Surface        #F3F5FA
Primary Text        #11131A
Secondary Text      #656B7A
Border              #E8EAF1
Primary Blue        #3478F6
Janeiro Purple      #7357FF
Soft Purple         #F1EDFF
```

Gradient (بنفسجي → أزرق) يُستخدم **فقط** في: Primary CTA · badges صغيرة · selected states · لمسات هوية صغيرة · بعض الـartwork.

**لا** كخلفية لكل section أو card. الأبيض هو المسيطر. White space جزء من التصميم.

---

## 3. Typography

عربي RTL — الخط جزء أساسي من الهوية.

- **Alexandria** — العناوين الرئيسية وعناوين الأقسام
- **IBM Plex Sans Arabic** أو **Tajawal** — النصوص، الأسعار، عناصر الواجهة

Hierarchy واضحة: Hero = ExtraBold · Section titles = Bold · Product titles = SemiBold · Body = Regular · Labels = Medium.

**لا تجعل كل شيء Bold.** line-height مريح. تأكد أن الأرقام والنص الإنجليزي داخل RTL يظهران بشكل صحيح.

---

## 4. Header

**Desktop:** Logo · Navigation · Search · Cart · Track Order
**Mobile:** Logo · Cart · Menu

Clean · Compact · Sticky بشكل أنيق. خلفية بيضاء أو شبه شفافة مع blur خفيف جداً عند Scroll. **لا Header ضخم.**

---

## 5. Mobile Drawer

نظيف جداً، يحتوي: الرئيسية · كل المنتجات · الأكثر مبيعاً · العروض · من نحن · تتبع الطلب · السياسات والشروط.

ثم قسم **تصفح حسب التصنيف** بأيقونات صغيرة متناسقة.

spacing جيد. لا يبدو كقائمة إعدادات تطبيق. CTA واضح بالأسفل إن ناسب.

---

## 6. Hero

**لا** مستطيل Gradient عليه نص.

**Desktop:** نص على جهة · Visual Product Composition على الجهة الأخرى.
**Mobile:** النص أولاً ثم الـcomposition.

- عنوان قصير قوي: مثلاً «كل أدواتك الرقمية، في مكان واحد»
- Subtitle: منتجات رقمية موثوقة، بأسعار مناسبة للسوق الجزائري وتفعيل سريع
- CTA رئيسي: **تصفح المنتجات** · CTA ثانوي: **اكتشف العروض**
- Trust points صغيرة: تفعيل سريع · دفع آمن · دعم مباشر · منتجات موثوقة

---

## 7. Janeiro Signature Visual — مهم

عنصر بصري خاص بالبراند بدل Hero تقليدي.

استلهم من **حرف J في الشعار** وفكرة **Orbit / مدار حول J** — بأسلوب فاتح وراقٍ.

Composition من 3–4 product cards تطفو بلطف حول مدار Janeiro. استخدم: بطاقات بيضاء · ظلال ناعمة · لمسات أزرق/بنفسجي خفيفة · أشكال صغيرة عائمة · gradients خفيفة جداً. **بدون Neon.**

هذا العنصر يجب أن يصير جزءاً من الهوية البصرية.

---

## 8. Categories

**لا** مربعات Gradient كبيرة.

Cards فاتحة (أبيض أو surface فاتح جداً)، كل واحدة تحتوي: أيقونة/رسمة خاصة · اسم التصنيف · وصف قصير أو عدد المنتجات.

التصنيفات: الذكاء الاصطناعي · التصميم والإبداع · الإنتاجية والعمل · التواصل · الترفيه · التطوير.

Accent color بسيط لكل تصنيف مع الحفاظ على وحدة الهوية. Hover (Desktop): رفع بسيط · ظل ناعم · حركة أيقونة خفيفة. **بدون مبالغة.**

---

## 9. Product Cards — أهم جزء

**ممنوع:** Gradient + حرف أول من اسم المنتج. هذا ليس تصميماً نهائياً.

المطلوب **Product Poster System** حقيقي: كل منتج له artwork مميز، لكن كل البوسترات تتبع نفس الـGrid والـTypography والـRadius والـSpacing ونظام الـBadges وتوقيع البراند — بحيث تبدو مختلفة لكن واضح أنها كلها من Janeiro Store.

### الصور والـAssets — مهم

**لا تخترع شعارات أو صوراً للمنتجات.**

ابنِ **architecture للـassets** بحيث يملك كل منتج في ملف البيانات:
`image` · `poster` · `thumbnail` · `accentColor` · `badge`

مع **fallback احترافي مصمَّم بعناية** يعمل عند غياب الصورة (وليس مجرد حرف أول على gradient). سأوفّر أنا الصور والشعارات لاحقاً وأضعها في مجلد الـassets.

### بنية البوستر

داخل الجزء البصري: شعار المنتج · اسم المنتج · label تصنيف صغير · 2–3 micro benefits عند الحاجة (تفعيل سريع · ضمان الاشتراك · دعم مباشر).

Badge اختياري: «الأكثر طلباً» / «عرض» / «جديد» — **فقط إذا كانت البيانات تدعم ذلك فعلاً.**

لا تحشر معلومات كثيرة داخل الصورة. يجب أن تبدو mini advertising poster.

### معلومات البطاقة (تحت الـArtwork)

اسم المنتج · وصف قصير · المدة/الخطة · السعر الحالي · السعر القديم (فقط عند وجود خصم حقيقي) · Badge خصم · CTA: **اشترِ الآن** أو **عرض التفاصيل**.

السعر واضح جداً. العملة: **دج / DA**.

---

## 10. Product Grid على الجوال — حرج

اختبر فعلياً على: **375px · 390px · 430px**.

عمودان مقبولان **فقط** إذا بقي المحتوى مقروءاً حقاً. إذا ضاقت البطاقات، انتقل لعمود واحد أو adaptive grid. **الجودة أهم من إجبار صفّين.**

ممنوع: overflow · نص مقصوص · أزرار خارج البطاقة · تمرير أفقي للصفحة.

---

## 11. أقسام إضافية

**الأكثر مبيعاً** — عنوان قوي + subtitle بسيط + رابط «عرض الكل ←». بدون Gradient ضخم خلف العنوان.

**Promotional Banner** — مختلف عن الـHero. خلفية بنفسجي/أزرق شاحبة جداً. مثال: «وفّر أكثر مع باقات Janeiro» + CTA «اكتشف الباقات» + illustration أو مجموعة أشكال على الطرف الآخر.

**لماذا Janeiro؟** — 4 نقاط بأيقونات بسيطة: تفعيل سريع · أسعار مناسبة · دعم مباشر · منتجات موثوقة. بدون cards ثقيلة، على خلفية off-white.

---

## 12. Search

Placeholder: «ابحث عن ChatGPT، Canva، Discord…»
Desktop: داخل الـHeader أو منطقة واضحة. Mobile: overlay أو expandable search.
النتائج واضحة وفورية.

---

## 13. WhatsApp

زر التواصل يبقى، لكن **لا يغطي أي محتوى**: أصغر · أنظف · safe-area spacing صحيح. تأكد على الجوال أنه لا يغطي CTA أو السعر أو التنقل أو البطاقات.

*(الرابط الفعلي يُضاف لاحقاً — اتركه كـ placeholder قابل للتهيئة من ملف الإعدادات.)*

---

## 14. صفحة تفاصيل المنتج

بنفس الهوية: artwork كبير · الاسم · السعر · الخطط/الخيارات · الوصف · المزايا · معلومات التسليم · CTA الشراء · معلومات الدعم · Trust information واضحة.

---

## 15. Order Flow

خطوات الشراء واضحة جداً. اعرض **Summary قبل الإرسال**: المنتج · الخطة · السعر · بيانات العميل. ثم زر «إكمال الطلب عبر واتساب».

النص المرسَل يجب أن يكون منظماً ومقروءاً.

*(في هذه المرحلة الطلب لا يُحفظ في أي قاعدة بيانات — فقط الواجهة والمنطق المحلي.)*

---

## 16. السوق الجزائري

عربي RTL. طرق الدفع المعروضة: **CCP · BaridiMob · Flexy** فقط.

**لا تعرض** Visa · Mastercard · Apple Pay · Google Pay. الثقة أهم من الشكل.

---

## 17. لا تخترع بيانات — قاعدة صارمة

ممنوع تماماً اختراع: Reviews · Testimonials · عدد العملاء · عدد الطلبات · **Ratings ونجوم** · خصومات · مخزون.

**خصوصاً: لا تعرض تقييمات بالنجوم إطلاقاً** حتى يوجد نظام تقييم حقيقي — النموذج المرفق فيه نجوم وهمية، احذفها.

إذا احتجت هذه العناصر مستقبلاً: صمّم مكانها فقط، أو لا تعرضها.

---

## 18. Responsive

**Mobile First.** اختبر: 320 · 360 · 375 · 390 · 430 · 768 · 1024 · 1440px+

راجع: header · menu · hero · search · categories · product cards · buttons · forms · footer · زر واتساب العائم.

**صفر horizontal overflow.**

---

## 19. Design Tokens

أنشئ tokens واضحة لـ: colors · typography · spacing · radius · shadows · breakpoints.

**Spacing:** 4 · 8 · 12 · 16 · 24 · 32 · 48 · 64 · 80 — بدون مسافات عشوائية.

**Radius:** أزرار 12–14px · بطاقات 18–22px · أقسام كبيرة 24–28px · badges = pill.

**Shadows:** ناعمة جداً، مثل `0 8px 30px rgba(20,30,60,.06)`. بدون glow قوي. بدون ظل بنفسجي على كل شيء.

---

## 20. Animations

fade/slide عند الظهور · card lift عند hover · button feedback · انتقالات قائمة سلسة · حركة orbit خفيفة في الـHero إن لم تؤثر على الأداء.

احترم `prefers-reduced-motion`. **لا تجعل الموقع يبدو كعرض animation.**

---

## 21. Code Quality

Components قابلة لإعادة الاستخدام:
`Header` · `MobileMenu` · `Hero` · `JaneiroOrbit` · `CategoryCard` · `ProductCard` · `ProductPoster` · `SectionHeader` · `PromoBanner` · `TrustSection` · `Footer`

**Data-driven بالكامل** — لا تكرر HTML يدوياً لكل منتج. لا ملف ضخم واحد.

---

## 22. Performance · Accessibility · SEO

- **Performance:** حسّن الصور والخطوط والـassets · lazy loading · تجنّب المكتبات الثقيلة غير الضرورية.
- **Accessibility:** تباين جيد · focus states ظاهرة · تنقّل بالكيبورد · HTML دلالي · ARIA عند الحاجة · touch targets كبيرة كفاية · طباعة عربية مقروءة.
- **SEO:** title · meta description · Open Graph · headings دلالية · لا تُكثر من H1.

---

## 23. المطلوب فعلاً

**لا أريد** تغييراً تجميلياً: تبديل لون، تغيير radius، تغيير خط، انتهى.

**أريد Visual Redesign حقيقي** — لغة تصميم Janeiro خاصة بنا.

النتيجة المطلوبة عند فتح الموقع: متجر رقمي حقيقي · Brand له شخصية · يبدو مصمَّماً يدوياً · Premium وبسيط · مناسب للسوق الجزائري · ممتاز على الهاتف · سريع · واضح · موثوق.

**وليس:** AI-generated landing page.

---

## 24. خطة التنفيذ

**Phase 1 — Audit**
افحص الملف المرفق واكتب باختصار: الوظائف الموجودة · مشاكل الـUI/UX · مشاكل الجوال · ما يستحق الاحتفاظ به منطقياً. ثم اقترح الـstack وانتظر موافقتي.

**Phase 2 — Design System**
Design tokens · نظام المكونات · بنية ملف البيانات وassets المنتجات.

**Phase 3 — Redesign**
Header · Mobile navigation · Hero + Janeiro Orbit · Categories · Best sellers · Product posters · Promo section · Why Janeiro · Footer · Product details · Order flow.

**Phase 4 — Responsive QA**
كل المقاسات المذكورة أعلاه.

**Phase 5 — Functional QA**
التنقل · البحث · الفلاتر · صفحات المنتجات · تدفق الطلب · لا أخطاء console · لا روابط مكسورة.

**Phase 6 — Final Polish**
RTL · typography · spacing · اتساق بصري · أداء · accessibility.

---

## ملاحظة أخيرة

خذ شعار Janeiro الحالي كمرجع للهوية، لكن **لا تجعل الصفحة كلها بنفسجية**. البنفسجي والأزرق = توقيع بصري فقط.

**White space جزء من التصميم. لا تقلّد أي متجر آخر — ابنِ Janeiro Design Language.**
