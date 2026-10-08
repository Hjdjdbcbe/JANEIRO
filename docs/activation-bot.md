# بوت تفعيل Snapchat+

بوت تيليغرام للزبائن، منفصل عن بوت المخزون. يدير **التفعيل برك**: البيع
والدفع يبقاو عند مالك. الكليان ياخذ كود طلب (`JN-4821`) ويبعثو للبوت،
والبوت يمشي معاه خطوة بخطوة. أي حاجة ما يعرفهاش تتحول لمالك.

## وين كاين الكود

| الملف | واش فيه |
|---|---|
| `api/activation-bot.js` | الـwebhook على Vercel: يتحقق من السر ويعطي الـupdate للمنطق |
| `lib/activation-bot/handler.js` | المنطق: المسارات، أوامر الأدمين، التحويل، المراجعة |
| `lib/activation-bot/flow.js` | القرارات (دوال صافية): جدول القسم 8 وملف المشاكل |
| `lib/activation-bot/texts.js` | كل النصوص الثابتة كيما كتبهم مالك |
| `lib/activation-bot/ai.js` | قراية الصور + النية/الجواب الحر (Claude) + الفوكال (STT) |
| `lib/activation-bot/adapters/telegram.js` | طبقة الميساجات. WhatsApp يجي كملف ثاني بنفس الواجهة |
| `lib/activation-bot/db.js` | نداءات Supabase (دوال `act_*`) |
| `supabase/migrations/042_activation_bot.sql` | الجداول والدوال |

الـAI ما يقررش: يرجع JSON (`page_type`, `currency`…)، والقرار في
`flow.js`. الميساجات الثابتة تتبعث بلا AI.

## التشغيل

1. **القاعدة:** طبّق `042_activation_bot.sql` (ولا الصق `docs/full-setup.sql`
   ولا `docs/bot-setup.sql` من جديد — كل شي فيهم يتعاود بلا مشاكل).
2. **البوت:** بوت جديد من @BotFather (ماشي بوت المخزون).
3. **Vercel → Settings → Environment Variables:**
   - `ACTIVATION_BOT_TOKEN`، `ACTIVATION_BOT_USERNAME` (بلا @)
   - `ACTIVATION_WEBHOOK_SECRET` — `openssl rand -hex 32`
   - `ADMIN_CHAT_IDS` — أرقام تيليغرام تاع الأدمين، بفاصلة
   - `SUPABASE_URL` (ولا `ACTIVATION_SUPABASE_URL`)، `SUPABASE_SERVICE_ROLE_KEY`
   - `ANTHROPIC_API_KEY`
   - `STT_API_KEY` (+ اختياري `STT_BASE_URL`، `STT_MODEL`)
4. **Deploy** على Vercel، ومن بعد:
   ```bash
   ACTIVATION_BOT_TOKEN=... ACTIVATION_WEBHOOK_SECRET=... \
   SITE_URL=https://janeiro-store.com bash tools/setup-activation-bot.sh
   ```
5. **أكواد الرصيد:** هي نفسها بطاقات بوت المخزون. في بوت المخزون دير
   منتج ومدد بالمبلغ (مثلا `/addproduct appleinr Apple INR` ثم
   `/addvariant appleinr r100 ₹100`) واشحن الأكواد عادي. ومن بعد في بوت
   التفعيل قولو شحال كل مدّة بالروبية:
   ```
   /giftamount appleinr r100 100
   /giftamount appleinr r250 250
   /stock
   ```
   البوت ياخذ **أصغر كود متوفر يغطي** الطلب (شهر ₹99، شهرين ₹98، سنة ₹199)،
   يعلمو `sold` في بوت المخزون، ويربطو بالطلب. كود واحد لكل طلب، ديما.
6. **الميديا:** ابعث للبوت (من حساب أدمين):
   - فيديو بـ caption `/media video_country`، و`/media video_plan_two_months`، و`/media video_plan_year`
   - صورة بـ caption `/media photo_snap_card`
   - فوكال، ورد عليه بـ `/voice voice_welcome` (ولا أي خانة أخرى)
7. **جرب بحسابك** (القسم 14). حساب الأدمين يقدر يلعب دور الكليان: أي
   ميساج ماشي أمر ولا رد على تنبيه يمشي كيما ميساج كليان.

## أوامر الأدمين

```
/new month | 2months | year      كود طلب جديد (+ رابط t.me/...?start=JN-xxxx)
/order JN-4821                   وين وصل الطلب
/orders                          المفتوحة — 🔴 تستنى مالك، 🟡 تستنى مراجعة
/take JN-4821 · /release JN-4821
/review on|off                   وضع المراجعة (شاعل في البداية)
/media <slot>                    caption على فيديو/صورة
/voice <slot>                    رد على فوكال
/voicemode <slot> text|voice|both
/problem العنوان | الأعراض | الحل [| يحول بعد كم]
/problems · /delproblem <id>
/stock · /giftamount <منتج> <مدّة> <₹>
```

كي يتحول طلب لمالك يوصل تنبيه فيه [ناخذ المحادثة] [رجع للبوت]. أي رد
(reply) على تنبيه ولا على ميساج كليان منقول يتبعث للكليان كما هو (نص،
صورة، فوكال). ميساجات الكليان توصل لمالك طول ما الطلب `HUMAN`.

## قرارات خديتها (بدّلهم إذا تحب)

- **`gift_codes`** ما كانش جدول بهذا الاسم: الستوك الموجود هو `bot_cards`.
  زدت `amount_inr` على `bot_variants` بلاصة ما نبني ستوك ثاني.
- **وضع المراجعة** يشمل كل قرار صورة (حتى "ابعث صورة أوضح")، ماشي غير
  الرابط. [رفض] = المحادثة تولي عند مالك.
- **حد الميساجات:** 20 ميساج و6 صور/فوكالات في الدقيقة لكل كليان.
- **أزرار بالعربية** (تيليفون بالعربية): «شهري» و«بدء الفترة التجريبية
  المجانية» — ما تأكدتش من النص الحقيقي تاع Snapchat؛ يتبدل في `texts.js`.
- **نصوص ما كانتش في المواصفات** (طلب الكود، "راني نشوف في الصورة"، تذكير
  الخطوة بعد /release…) كتبتهم بالدارجة في `texts.js`.
- **الموديل:** `claude-opus-5-5` بـ effort `low` باش يكون سريع.
  `ACTIVATION_AI_EFFORT=medium` إذا الصور تغلط.
- **STT:** أي خدمة متوافقة مع `/audio/transcriptions` (OpenAI، Groq…).
  جودة الدارجة لازم تتجرب.

## مازال

- WhatsApp: الطبقة معزولة، لكن `adapters/whatsapp.js` مازال ما تكتبش.
- ما تجربش مع تيليغرام وClaude وSTT الحقيقيين — الاختبارات تستعمل نسخ
  وهمية. القاعدة والمنطق مختبرين (`tests/local/activation-*.test.js`،
  `tests/activation-bot.test.sql`).
