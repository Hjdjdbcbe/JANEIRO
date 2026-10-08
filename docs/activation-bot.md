# بوت تفعيل Snapchat+

البوت يدير **التفعيل برك**. البيع والدفع يصراو في إنستغرام مع مالك.

- **الكليان** في **واتساب**، على نفس رقم المتجر (WhatsApp Cloud API، وضع Coexistence).
  الرقم مشترك مع مالك، فالبوت **ساكت** إلا مع رقم بعث كود طلب صحيح ولا عندو طلب مفتوح.
- **مالك** في **تيليغرام**: الأوامر، التنبيهات، قبول/رفض الصور، وحفظ الفوكالات بالأزرار.

```
إنستا: البيع ← /new month في تيليغرام ← https://wa.me/213…?text=JN-4821
      ← الكليان يضغط ويبعث ← البوت يبدا معاه في واتساب
```

## وين كاين الكود

| الملف | واش فيه |
|---|---|
| `api/whatsapp.js` | webhook واتساب: تحقق Meta (GET)، توقيع `X-Hub-Signature-256` على البايتات الخام، 200 فورا والمعالجة في `waitUntil` |
| `api/activation-bot.js` | webhook تيليغرام (الأدمين) بالسر |
| `lib/activation-bot/handler.js` | المنطق: المسارات، الصمت الافتراضي، echoes، التحويل، المراجعة، الأوامر، حفظ الميديا |
| `lib/activation-bot/flow.js` | القرارات (دوال صافية): جدول القسم 8 وملف المشاكل |
| `lib/activation-bot/texts.js` | كل النصوص الثابتة |
| `lib/activation-bot/ai.js` | Gemini: الصور، الفوكالات والأجوبة في موديل واحد + الحد اليومي |
| `lib/activation-bot/adapters/whatsapp.js` · `telegram.js` | طبقة الميساجات (نفس الواجهة) |
| `lib/activation-bot/storage.js` | Supabase Storage (bucket `bot-media`) |
| `supabase/migrations/042_…` · `043_…` | الجداول والدوال |

الـAI ما يقررش: يرجع JSON، والقرار في `flow.js`. الميساجات الثابتة تتبعث بلا AI.

## التشغيل — واش لازم تدير بيدك

1. **SQL:** في Supabase SQL Editor الصق `supabase/migrations/042_activation_bot.sql`
   ثم `043_activation_whatsapp.sql` (ولا `docs/bot-setup.sql` كامل). كل شي يتعاود بلا مشاكل.
2. **ربط واتساب (Coexistence):** في Meta Business، اربط رقم المتجر بالـCloud API
   بـ Embedded Signup (مسار Coexistence، غالبا عن طريق مزود معتمد). تأكد بلي +213 مقبول.
   من بعد عاود اربط واتساب ويب، وحل التطبيق مرة كل 13 يوم على الأقل.
3. **Webhook واتساب** (App → WhatsApp → Configuration):
   - Callback URL: `https://janeiro-store.com/api/whatsapp`
   - Verify token: نفس `WHATSAPP_VERIFY_TOKEN`
   - اشترك في الحقول: **`messages`** و **`smb_message_echoes`** (هذا لي يوقف البوت كي تكتب من التطبيق).
4. **تيليغرام:** بوت من @BotFather (جديد ولا الموجود)، ومن بعد:
   ```bash
   ACTIVATION_BOT_TOKEN=... ACTIVATION_WEBHOOK_SECRET=... \
   SITE_URL=https://janeiro-store.com bash tools/setup-activation-bot.sh
   ```
5. **متغيرات Vercel** (كاملين في `.env.example`):
   `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_APP_SECRET`, `WHATSAPP_VERIFY_TOKEN`,
   `WHATSAPP_STORE_NUMBER`, `ACTIVATION_BOT_TOKEN`, `ACTIVATION_WEBHOOK_SECRET`, `ADMIN_CHAT_IDS`,
   `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `GEMINI_API_KEY`, `AI_MODEL`, `AI_DAILY_BUDGET_USD`.
   ثم **Redeploy**.
6. **أكواد الرصيد:** هي بطاقات بوت المخزون. قولو شحال كل مدّة بالروبية:
   `/giftamount appleinr r100 100` … و`/stock`. البوت ياخذ **أصغر كود متوفر يغطي**
   (شهر ₹99، شهرين ₹98، سنة ₹199)، كود واحد لكل طلب.
7. **الميديا:** ابعث للبوت في تيليغرام الفيديوهات، الصورة والفوكالات **بلا أوامر**:
   يسقسيك وين تحطهم (وللفوكال: فوكال برك / نص برك / الاثنين)، ويوريلك معاينة.
   النسخة الأصلية تتحفظ في Storage وتترفع لواتساب؛ إذا مات `media_id` يتعاود الرفع وحدو.
8. **جرب بتيليفونك** (القسم 14) قبل أول كليان. `/review on` شاعل من الأول.

## أوامر مالك (تيليغرام)

```
/new month | 2months | year      كود + رابط wa.me في ميساج وحدو (للنسخ)
/order JN-4821 · /orders
/release JN-4821                 يرجع للبوت في نفس الخطوة   ([رجع للبوت])
/stop JN-4821                    يغلق الطلب، البوت يسكت نهائيا ([غلق الطلب])
/take JN-4821                    يسكت البوت؛ تجاوب أنت من واتساب بزنس
/review on|off
/voices                          الفوكالات المحفوظة: [اسمع] [امسح]
/voice <slot> · /voicemode <slot> text|voice|both · /media <slot>   (الطريقة القديمة، مازالت تخدم)
/problem العنوان | الأعراض | الحل · /problems · /delproblem <id>
/stock · /giftamount <منتج> <مدّة> <₹>
```

**التحويل:** كي يتحول طلب ليك، جاوب الكليان **من تطبيق واتساب بزنس** مباشرة. البوت ساكت
في هذاك الطلب حتى تضغط [رجع للبوت]. وإذا كتبت بيدك في محادثة فيها طلب مفتوح، البوت
يسكت وحدو ويبعثلك تنبيه.

## قواعد مهمة

- **الصمت:** رقم بلا طلب مفتوح وبلا كود ← لا جواب، لا سجل، لا AI. بعد `DONE` البوت يسكت تاني.
- **نافذة 24 ساعة:** البوت ما يكتبش برّا النافذة (يلزم templates). إذا ضغطت [رجع للبوت]
  والنافذة سكرت، يقولك، ويكمل كي يبعث الكليان ميساج.
- **48 ساعة:** كود ما تستعملش يموت؛ طلب بدا وما كملش يتغلق وتوصلك رسالة.
- **قناة أخرى (احتياط):** نفس الكود من تيليغرام يكمل من وين وقف (وتوصلك رسالة). من رقم
  واتساب آخر: مرفوض.
- **ميزانية الـAI:** كي يوصل `AI_DAILY_BUDGET_USD`، كل حالة تحتاج AI تتحول ليك (تنبيه
  عاجل مرة في النهار). المصروف يبان في `/stock`.

## قرارات تقنية

- **الموديل:** `gemini-3.8-flash` (آخر Flash عادي في SDK تاع Google وقت الكتابة). يتبدل
  من `AI_MODEL`. الأسعار في `.env.example` تقديرات للحساب (من جداول أسعار منشورة، ماشي
  من صفحة Google مباشرة). بعض المصادر تقول بلي سعر Flash يتضاعف في 1 جانفي 2027: تأكد وبدلهم.
- **صوت الكليان:** واتساب ما يعطيش المدّة؛ تتقاس من tokens الصوت (32 في الثانية)، فالفوكال
  الطويل يتحسب قبل ما يتحول.
- **Temperature منخفضة للصور** (0.1) كيما طلبت. إذا شفت أجوبة غريبة ولا تكرار، جرب
  `AI_IMAGE_TEMPERATURE=1` (القيمة الافتراضية تاع الموديل).
- **Echoes:** شكل `smb_message_echoes` ما قدرتش نتأكد منو من وثائق Meta (محبوسة من هنا).
  الكود يقرا `value.message_echoes[].to`. جربو بأول ميساج تكتبو من التطبيق.
