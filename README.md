# Janeiro Store — Backend

## ⚠️ اقرأ هذا أولاً

**ما شُغِّل فعلاً:** الـmigrations وقاعدة البيانات كاملة اختُبرت على
PostgreSQL 16 محلي. وُجدت خمسة أخطاء وأُصلحت (التفاصيل في `START-HERE.md`).
شغّل كل شيء بأمر واحد، بدون حاجة إلى Supabase:

```bash
bash tests/local/run-tests.sh
```

**ما لم يُشغَّل بعد:** لا يوجد مشروع Supabase منشور. لذلك لم تُنفَّذ
الـEdge Functions على Deno قط، ولم يُرفع ملف حقيقي إلى Storage، ولم
تُرسَل رسالة Telegram واحدة. منطق قاعدة البيانات الذي تستدعيه هذه
الدوال مُختبَر بالكامل، أما الدوال نفسها فلا.

**لا تعتبر أي بند لم يُذكر أعلاه ناجحاً حتى تشغّله بنفسك بعد النشر.**

---

## 1. الملفات المُنشأة

```
janeiro-backend/
├── .env.example
├── README.md
├── supabase/
│   ├── migrations/
│   │   ├── 001_core_schema.sql      enums, profiles, categories, payment_methods, store_settings
│   │   ├── 002_products.sql         products, plans, features, requirements, images, public view
│   │   ├── 003_orders.sql           orders, items, activation data, history, notifications, rate limits
│   │   ├── 004_storage.sql          buckets + storage policies
│   │   ├── 005_rls.sql              كل سياسات RLS
│   │   ├── 006_functions.sql        phone normalize, order number, create/submit/track RPCs
│   │   └── 007_seed_products.sql    نقل المنتجات من الـfrontend
│   └── functions/
│       ├── _shared/util.ts          CORS, error mapping, service client, rate limit
│       ├── create-order/index.ts
│       ├── upload-receipt/index.ts
│       ├── submit-order/index.ts    + Telegram
│       └── track-order/index.ts
├── js/janeiro-api.js                طبقة ربط الفرونت إند
├── frontend/index.html              الموقع — مربوط بالباكند
└── tests/
    ├── backend.test.sql             اختبارات SQL
    ├── race-test.sh                 تزامن عبر Edge Functions (يحتاج نشراً)
    ├── local/                       تشغيل الباكند كاملاً بلا Supabase
    │   ├── supabase-shim.sql        auth/storage + الأدوار + الصلاحيات
    │   ├── run-tests.sh             migrations + الاختبارات دفعة واحدة
    │   └── concurrency.test.sh      تزامن حقيقي باتصالات متوازية
    └── frontend/                    اختبار المتصفح على الصفحة الحقيقية
        ├── mock-supabase.js
        └── e2e.test.js
```

**الملفات المعدّلة:** `frontend/index.html` — حُذفت منه مصفوفتا
`CATEGORIES` و`PRODUCTS` الثابتتان، وصار يقرأ كل شيء من قاعدة البيانات
عبر `js/janeiro-api.js`. التصميم لم يُمسّ.

---

## 2. جداول قاعدة البيانات

| الجدول | الغرض |
|---|---|
| `profiles` | أدوار الأدمن (`admin` / `staff`) |
| `categories` | التصنيفات |
| `products` | المنتجات (6 حالات، بدون حذف نهائي) |
| `product_plans` | الخطط والأسعار |
| `product_features` | مزايا المنتج |
| `product_requirements` | حقول التفعيل |
| `product_images` | صور المنتج |
| `payment_methods` | CCP / BaridiMob / Flexy |
| `store_settings` | إعدادات key/value |
| `orders` | الطلبات |
| `order_items` | العناصر (بـsnapshots) |
| `order_activation_data` | بيانات التفعيل (خاصة) |
| `order_status_history` | سجل الحالات (تلقائي بـtrigger) |
| `order_notifications` | سجل الإشعارات |
| `rate_limits` | الحد من التكرار |
| `daily_deals` | عروض مؤقتة على خطة محددة |

---

## 3. الدوال (RPC)

| الدالة | الوصول |
|---|---|
| `normalize_dz_phone(text)` | عام |
| `generate_order_number()` | داخلي (مسحوبة من `anon`) |
| `create_order(...)` | **service role فقط** |
| `submit_order(...)` | **service role فقط** |
| `track_order(number, last4)` | عام |
| `count_active_orders(phone)` | داخلي |
| `check_rate_limit(...)` | داخلي |
| `is_admin()` | متاحة للجميع **عمداً** — كل سياسة RLS تستدعيها بدور صاحب الطلب، وسحبها يكسر وصول الأدمن كلياً |
| `active_deal_price(uuid,uuid)` | داخلي — سعر العرض الحيّ لخطة، أو NULL |
| `safe_inet(text)` | داخلي — يمنع ترويسة IP مشوّهة من إفشال الطلب |

---

## 4. Edge Functions

| الدالة | المسار |
|---|---|
| إنشاء طلب | `POST /functions/v1/create-order` |
| رفع الوصل | `POST /functions/v1/upload-receipt` |
| تأكيد الطلب + Telegram | `POST /functions/v1/submit-order` |
| تتبع الطلب | `POST /functions/v1/track-order` |

---

## 5. Storage

| Bucket | عام؟ | من يقرأ |
|---|---|---|
| `product-media` | ✅ نعم | الجميع (صور المنتجات عامة) |
| `receipts` | ❌ **لا** | الأدمن فقط. الرفع عبر Edge Function بمفتاح service role حصراً |

---

## 6. المتغيرات المطلوبة منك

**آمنة في المتصفح** (تضعها في `js/janeiro-api.js`):
```
SUPABASE_URL
SUPABASE_ANON_KEY
```

**سرّية — ممنوعة في الفرونت إند** (تضعها بـ`supabase secrets set`):
```
SUPABASE_SERVICE_ROLE_KEY
TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID
ALLOWED_ORIGIN
```

**في قاعدة البيانات وليس في ملفات** — رقم واتساب وبيانات CCP/BaridiMob/Flexy.

---

## 7. خطوات الإعداد

```bash
# 1) اربط المشروع
supabase link --project-ref YOUR-PROJECT-REF

# 2) شغّل الـmigrations
supabase db push

# 3) الأسرار (لا تضعها في أي ملف)
supabase secrets set TELEGRAM_BOT_TOKEN=123456:AA...
supabase secrets set TELEGRAM_CHAT_ID=-1001234567890
supabase secrets set ALLOWED_ORIGIN=https://your-domain.com

# 4) انشر الدوال
supabase functions deploy create-order
supabase functions deploy upload-receipt
supabase functions deploy submit-order
supabase functions deploy track-order
```

### إنشاء حساب أدمن
```sql
-- بعد تسجيل المستخدم عبر Supabase Auth:
insert into profiles (id, role) values ('USER-UUID-HERE', 'admin');
```

### Telegram Bot
1. راسل `@BotFather` → `/newbot` → خذ الـtoken
2. أضف البوت لمجموعتك (أو راسله مباشرة)
3. للحصول على `chat_id`: افتح `https://api.telegram.org/bot<TOKEN>/getUpdates` بعد إرسال رسالة
4. `supabase secrets set TELEGRAM_CHAT_ID=...`

### رقم واتساب وبيانات الدفع
```sql
update store_settings set value = '213XXXXXXXXX' where key = 'whatsapp_number';

update payment_methods
   set account_holder = 'الاسم واللقب',
       account_number = 'رقم الحساب',
       instructions   = 'تعليمات الدفع'
 where type = 'ccp';
```

---

## 8. ربط الفرونت إند — تم

`frontend/index.html` مربوط بالفعل. لا يبقى إلا وضع المفاتيح:

```html
<!-- قبل وسم <script type="module"> مباشرة -->
<script>window.JANEIRO_CONFIG = {
  SUPABASE_URL: "https://xxxx.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOi..."
};</script>
```

أو عدّل `PLACEHOLDER` داخل `js/janeiro-api.js`. المفتاح `anon` عام
بالتصميم — RLS هو ما يحمي البيانات، لا سرّية المفتاح.

**ما يحدث الآن عند الإقلاع:** `boot()` يحمّل الإعدادات والتصنيفات
والمنتجات وطرق الدفع بالتوازي، مع skeletons أثناء الانتظار وError state
مع زر إعادة محاولة عند الفشل.

**تدفق الطلب:** الخطوات الأربع على الشاشة كما هي. تحتها، زر التأكيد
النهائي ينفّذ:

```
createOrder()  →  uploadReceipt()  →  submitOrder()  →  واتساب
```

واتساب **لا يُفتح** إلا بعد نجاح `submitOrder`، برقم من `store_settings`
وبرقم الطلب الذي أصدره الخادم. مفتاح idempotency واحد لكل محاولة،
يُعاد استخدامه عند إعادة المحاولة، فلا ينشأ طلبان.

**ما بقي عليك:** رفع صور المنتجات إلى `product-media` وتحديث
`poster_path` — البنية جاهزة والمنتج بلا صورة يعرض البوستر البديل
المصمَّم.

## 9. القرارات المعمارية

**لماذا الحد الأقصى يُفرض عند التأكيد لا عند الإنشاء؟**
حسب §12 الطلب بحالة `awaiting_receipt` ليس طلباً نهائياً، وحسب §17 لا يُحتسب نشطاً. لذا الفحص يجري **مرتين**: عند الإنشاء (لتجربة مستخدم أفضل) وعند التأكيد (الضمان الحقيقي) — كلاهما تحت `pg_advisory_xact_lock` على رقم الهاتف.

✅ **تم قياسه:** 10 اتصالات متوازية حقيقية → طلبان نشطان بالضبط، في
الحالتين (إنشاء+تأكيد في معاملة واحدة، وتأكيدات متزامنة لطلبات أُنشئت
منفصلة). انظر `tests/local/concurrency.test.sh`.

**قيد قاعدة البيانات على الوصل (§27)**
`receipt_required_after_submit` يمنع فيزيائياً وجود طلب `pending_payment_review` بلا وصل — حتى لو أخطأ كود مستقبلي.

**فحص نوع الصورة**
`Content-Type` قابل للتزوير، لذا `upload-receipt` يفحص **البايتات الأولى** فعلياً (magic bytes). ملف `.exe` مُسمّى `.jpg` سيُرفض.

⚠️ هذا المنطق **لم يُنفَّذ على Deno بعد** — لا يوجد نشر. اختبره يدوياً
بعد النشر.

**التتبع لا يميّز بين الأخطاء**
"رقم طلب خاطئ" و"هاتف خاطئ" يعطيان نفس الرد بالضبط — وإلا أصبح المسار أداة لاستكشاف أرقام الطلبات.

---

## 10. التشغيل محلياً

```bash
supabase start
supabase db reset          # يشغّل كل الـmigrations + seed
supabase functions serve   # الدوال على localhost:54321
```

---

## 11. الاختبار

### بلا نشر — يعمل الآن

```bash
bash tests/local/run-tests.sh
```

يُنشئ قاعدة بيانات مؤقتة، يطبّق الـshim ثم الـmigrations السبعة، يعيد
تطبيقها للتأكد من قابلية التكرار، ثم يشغّل:

| الملف | ما يغطيه | النتيجة |
|---|---|---|
| `tests/backend.test.sql` | 59 تأكيداً: تطبيع الهاتف، التسعير من قاعدة البيانات، idempotency، حد الطلبين، الوصل، التتبع، RLS، واختبارات تراجُع للأخطاء الخمسة | ✅ تمر |
| `tests/local/concurrency.test.sh` | 4 حالات تزامن باتصالات متوازية حقيقية | ✅ تمر |

`tests/local/supabase-shim.sql` يعيد بناء ما تعتمد عليه الـmigrations من
Supabase: مخططا `auth` و`storage`، أدوار `anon`/`authenticated`/
`service_role`، وصلاحيات Supabase الافتراضية على `public`. **ليس ملف
migration** — أداة اختبار فقط، ولا يُنشر.

كل اختبار تراجُع تم التحقق من أنه يفشل عند إرجاع الإصلاح الذي يحرسه.
اختبار التأكيد المزدوج يفرض التشابك بحاجز `pg_advisory_lock` لأن
التوقيت وحده لا يعيد إنتاجه.

### اختبار الواجهة

```bash
psql -d janeiro_test -f tests/frontend/fixtures.sql
npm i pg playwright
PGUSER="$(whoami)" node tests/frontend/mock-supabase.js &
node tests/frontend/e2e.test.js    # الكتالوج والسلة والطلب والتتبع
node tests/frontend/ui.test.js     # الأيقونات والعروض والحركة والعرض الضيق
node tests/frontend/admin.test.js  # لوحة الطلبات والصلاحيات
```

في Chromium على `frontend/index.html` نفسه، مقابل Supabase وهمي مدعوم
بقاعدة البيانات المحلية:

| الملف | ما يغطيه |
|---|---|
| `e2e.test.js` | التصنيفات والمنتجات والأسعار من قاعدة البيانات، منتج `coming_soon` غير قابل للشراء، تدفق الطلب كاملاً، رابط واتساب، التتبع بهاتف صحيح وخاطئ |
| `ui.test.js` | بلاطة الأيقونة في مواضعها الثلاثة، صورة مرفوعة كسولة بأبعاد ثابتة، الرجوع للأيقونة المصممة عند الفشل، قسم العروض والعدّاد الحيّ، وصول سعر العرض للسلة، إخفاء القسم بلا عروض، حدود الحركة، و`prefers-reduced-motion`، حفظ موضع التمرير، وغياب التمرير الأفقي عند 375/390/430px |
| `admin.test.js` | رفض كلمة سر خاطئة، رفض مستخدم مسجَّل ليس أدمن، الطابور والطلب وبيانات التفعيل، توقيع رابط الوصل ورفضه بلا جلسة، عرض النقلات المسموحة فقط، وقيادة طلب من المراجعة إلى «مكتمل» ثم التأكد أن صفحة تتبّع العميل توافق |

`run-tests.sh` يحذف القاعدة ويعيد بناءها، فأعد تطبيق `fixtures.sql` بعده
وإلا اختفى قسم العروض بحق وفشلت اختباراته. التفاصيل في
`tests/frontend/README.md`.

### بعد النشر — لم يُشغَّل بعد

```bash
export SUPABASE_URL=... SUPABASE_ANON_KEY=...
export PRODUCT_ID=... PLAN_ID=... PAYMENT_METHOD_ID=...
export ACTIVATION='[{"label":"اسم المستخدم في ديسكورد","value":"racer"}]'
bash tests/race-test.sh
```

`ACTIVATION` ضروري: `create_order` يرفض عنصراً ينقصه حقل تفعيل مطلوب،
فبدونه تفشل كل الطلبات لسبب آخر ولا يُختبر التزامن أصلاً. خذ التسميات من:

```sql
select label from product_requirements where product_id = '<PRODUCT_ID>';
```

يبقى بعد ذلك ما لا يمكن اختباره إلا على مشروع حقيقي:

- رفع وصل صالح / أكبر من 5 ميغابايت / PDF / صورة مزوّرة الترويسة
- وصول رسالة Telegram وصورة الوصل
- فشل Telegram → الطلب يبقى محفوظاً
- محاولة `anon` قراءة bucket `receipts`

### طلب كامل يدوياً
```bash
# 1) إنشاء
curl -X POST "$SUPABASE_URL/functions/v1/create-order" \
  -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d '{"name":"اختبار","phone":"0550123456","payment_method_id":"<PM>",
       "idempotency_key":"test-001",
       "items":[{"product_id":"<P>","plan_id":"<PL>","quantity":1,
                 "activation":[{"label":"بريد Gmail للتفعيل","value":"a@b.com"},
                               {"label":"رقم الهاتف المرتبط","value":"0550111111"}]}]}'

# 2) رفع الوصل
curl -X POST "$SUPABASE_URL/functions/v1/upload-receipt" \
  -H "apikey: $ANON" -F "order_id=<ORDER_ID>" -F "file=@receipt.jpg"

# 3) التأكيد
curl -X POST "$SUPABASE_URL/functions/v1/submit-order" \
  -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d '{"order_id":"<ORDER_ID>","payment_reference":"4821990"}'

# 4) التتبع
curl -X POST "$SUPABASE_URL/functions/v1/track-order" \
  -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d '{"order_number":"JNR-260826-A7K3","phone_last4":"3456"}'
```

---

## 12. ما زال يحتاج إجراءً يدوياً منك

- [x] ربط `janeiro-api.js` بالـHTML (خطوة 8)
- [x] إضافة skeletons وError state
- [x] تشغيل اختبارات قاعدة البيانات — `bash tests/local/run-tests.sh`
- [ ] إنشاء مشروع Supabase وتشغيل `db push` — **يحتاج حسابك**
- [ ] وضع `SUPABASE_URL` و`ANON_KEY` (خطوة 8)
- [ ] إنشاء بوت Telegram وضبط الأسرار
- [ ] تعبئة رقم واتساب في `store_settings`
- [ ] تعبئة بيانات CCP/BaridiMob/Flexy في `payment_methods`
- [ ] إنشاء حساب أدمن وإضافة صفه في `profiles`
- [ ] رفع صور المنتجات إلى `product-media` وتحديث `poster_path`
- [ ] ضبط `ALLOWED_ORIGIN` على نطاقك الحقيقي قبل الإطلاق
- [ ] **تشغيل الاختبارات التي تحتاج نشراً** — `tests/race-test.sh`،
      رفع وصل حقيقي، ورسالة Telegram

---

## 13. عروض اليوم

العرض سعر مؤقت على **خطة واحدة** من منتج واحد. لا يعدّل
`product_plans.price` إطلاقاً، فالسعر الأصلي يبقى للشطب وينتهي العرض
وحده دون تدخّل.

### إضافة عرض

```sql
insert into daily_deals (product_id, plan_id, deal_price, starts_at, ends_at, sort_order)
select p.id, pl.id,
       1200,                                  -- سعر العرض
       now(),                                 -- يبدأ الآن
       now() + interval '12 hours',           -- ينتهي بعد 12 ساعة
       1                                      -- ترتيب العرض في القسم
  from products p
  join product_plans pl on pl.product_id = p.id
 where p.slug = 'spotify-premium'             -- المنتج
   and pl.name = 'شهر واحد';                  -- الخطة بالضبط
```

قاعدة البيانات ترفض العرض إن لم يكن **أقل فعلاً** من سعر الخطة
(`DEAL_PRICE_NOT_LOWER`)، أو إن كانت الخطة تخصّ منتجاً آخر
(`DEAL_PLAN_PRODUCT_MISMATCH`)، أو إن كان `ends_at` قبل `starts_at`.

### إنهاء عرض قبل موعده

```sql
update daily_deals set is_active = false where id = '<DEAL-ID>';
-- أو
update daily_deals set ends_at = now() where id = '<DEAL-ID>';
```

### ما يظهر وما لا يظهر

`public_daily_deals` هو ما يقرأه الموقع، وهو يفلتر خادمياً: العرض
المنتهي أو الذي لم يبدأ أو المعطّل **لا يصل المتصفح أصلاً**. وسياسة RLS
على الجدول نفسه تفرض القاعدة ذاتها، فعرض مجدول لا يمكن استكشافه قبل
موعده.

### الأهم: السعر يُحسب في الخادم

`create_order` تسأل `active_deal_price` قبل أن تقع على سعر الخطة. فلو
انتهى العرض بين لحظة عرض الصفحة ولحظة التأكيد، يُحتسب السعر الأصلي —
والسلة لا تستطيع اختراع خصم. مُختبَر في `tests/backend.test.sql`.

### العدّاد التنازلي

يُحسب من `ends_at` القادم من الخادم. الصفحة تقيس فرق ساعة المتصفح عن
ساعة الخادم مرة واحدة عند التحميل (من عمود `server_now` في الـview)،
فجهاز بساعة خاطئة يظل يعدّ نحو الوقت الصحيح. وعند انتهاء العدّاد يعيد
السؤال من الخادم بدل أن يلفّ من جديد.

**إن لم يوجد عرض حيّ، القسم لا يظهر إطلاقاً** — لا رسالة "لا توجد
عروض" ولا عرض تجريبي.

---

## 14. أيقونات التصنيفات

`categories.icon_path` يحمل مساراً داخل bucket `product-media` العام،
تماماً كـ`products.poster_path`.

```sql
update categories set icon_path = 'categories/ai.png' where slug = 'ai';
```

| البند | القيمة |
|---|---|
| المقاس | **128×128 بكسل** |
| الصيغة | PNG بخلفية شفافة (أو WebP) |
| الوجهة | bucket `product-media` → مجلد `categories/` |
| المسار | `categories/<slug>.png` مثل `categories/ai.png` |

الأيقونة تُعرض بـ28px في شرائح التصنيفات و34px في القائمة الجانبية،
فـ128px يغطي حتى كثافة ~3.8x. اترك الرسم داخل مساحة آمنة ~112px حتى لا
يصطدم بالزوايا الدائرية، واجعله واضحاً على خلفية داكنة — البلاطة خلفه
تدرّج شفاف لا لون صلب.

**بلا صورة، أو إن فشل تحميلها، تظهر الأيقونة المصممة** تلقائياً: البلاطة
الزجاجية بلون التصنيف مع توهج ناعم وحد ضوئي علوي. الرمز المصمم موجود
دائماً **خلف** الصورة، فحتى الصورة الكسولة التي لم تصل بعد لا تترك
بلاطة فارغة.

---

## 15. لوحة الطلبات (الأدمن)

`admin/index.html` — صفحة منفصلة عن المتجر، لا تُفهرس، بلا أي اعتمادية.
هي الطريقة الوحيدة لتحريك طلب؛ قبلها كان ذلك يتم بتعديل الجدول يدوياً.

### إنشاء حساب أدمن

```sql
-- 1) أنشئ المستخدم من Supabase → Authentication → Add user
-- 2) ثم امنحه الدور:
insert into profiles (id, role, full_name)
values ('USER-UUID-HERE', 'admin', 'اسمك')
on conflict (id) do update set role = 'admin';
```

المفاتيح تُوضع كما في المتجر (خطوة 8)، أو بتعديل `CFG` أعلى السكربت.

### ما تفعله

| | |
|---|---|
| **الطابور** | شرائح بعدد الطلبات في كل حالة، تفتح على «مراجعة الدفع» — ما ينتظرك أولاً |
| **الطلب** | العميل وهاتفه، بيانات التفعيل بأزرار نسخ، رقم العملية، ورابط مؤقّت (5 دقائق) لصورة الوصل |
| **النقل** | أزرار الحالات المسموحة فقط، مع خانة سبب تُحفظ في سجل الطلب |
| **السجل** | كل تغيّر حالة: من ماذا إلى ماذا، ومتى، وبأي سبب، وبيد من |

### قواعد النقل

مخزَّنة في جدول `order_status_transitions`، لا في الكود — تقرأها وتعدّلها
بـSQL. الأزرار في اللوحة تُبنى من هذا الجدول، فما تمنعه القاعدة لا يظهر
أصلاً كزر:

```sql
select from_status, to_status from order_status_transitions order by 1;
```

`awaiting_receipt` و`pending_payment_review` حالتان يصل إليهما العميل
عبر `create_order` و`submit_order`؛ الأدمن لا يُسندهما يدوياً. و`cancelled`
و`refunded` نهائيتان.

### الأمان

- لا مفتاح `service_role` في الصفحة. تحمل جلسة مستخدم عادي فقط.
- `admin_update_order_status` تفحص `is_admin()` بنفسها في الخادم — فحتى
  مستخدم مسجَّل غير أدمن يُرفض، وهو **مُختبَر** في `tests/backend.test.sql`.
- الجلسة في `sessionStorage` لا `localStorage`: إغلاق التبويب ينهي الوردية.
- bucket الوصولات يبقى خاصاً؛ الرابط يُوقَّع عند الطلب ولمدة 5 دقائق.

---

## 16. تنبيه أمني أخير

- ✅ `SERVICE_ROLE_KEY` غير موجود في أي ملف فرونت إند
- ✅ `TELEGRAM_BOT_TOKEN` في Supabase Secrets فقط
- ✅ `.env` الحقيقي **لا يُرفع لـgit** — `.env` مضاف إلى `.gitignore` بالفعل
- ⚠️ قبل الإطلاق: غيّر `ALLOWED_ORIGIN` من `*` إلى نطاقك، وإلا أي موقع يستطيع استدعاء دوالك
