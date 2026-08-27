# Janeiro Store — Backend

## ⚠️ اقرأ هذا أولاً

الكود هنا **مكتوب بالكامل وجاهز للنشر**، لكنه **لم يُشغَّل ولم يُختبر فعلياً** — البيئة التي كُتب فيها بلا اتصال إنترنت، فلا يمكن إنشاء مشروع Supabase أو تشغيل migrations أو إرسال رسالة Telegram.

**لا تعتبر أي بند من §61 ناجحاً حتى تشغّله بنفسك.** ملفات الاختبار موجودة وجاهزة (`tests/`) — شغّلها بعد النشر.

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
└── tests/
    ├── backend.test.sql             اختبارات SQL
    └── race-test.sh                 اختبار التزامن
```

**الملفات المعدّلة:** لا شيء. `janeiro-store-v4.html` لم يُمسّ — الربط يتم بإضافة `js/janeiro-api.js` (خطوة 8 أدناه).

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

---

## 3. الدوال (RPC)

| الدالة | الوصول |
|---|---|
| `normalize_dz_phone(text)` | عام |
| `generate_order_number()` | داخلي |
| `create_order(...)` | **service role فقط** |
| `submit_order(...)` | **service role فقط** |
| `track_order(number, last4)` | عام |
| `count_active_orders(phone)` | داخلي |
| `check_rate_limit(...)` | داخلي |
| `is_admin()` | داخلي (تستخدمها كل سياسات الأدمن) |

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

## 8. ربط الفرونت إند

في `janeiro-store-v4.html`:

1. ضع `js/janeiro-api.js` بجانب الملف، وعدّل `JANEIRO_CONFIG` بمفاتيحك
2. غيّر وسم السكربت إلى `<script type="module">`
3. احذف مصفوفتي `CATEGORIES` و`PRODUCTS` الثابتتين واستبدلهما:

```js
import * as API from './js/janeiro-api.js';

let CATEGORIES = [], PRODUCTS = [], PAYMENT_METHODS = [], SETTINGS = {};

async function boot() {
  showSkeletons();
  try {
    [SETTINGS, CATEGORIES, PRODUCTS, PAYMENT_METHODS] = await Promise.all([
      API.loadStoreSettings(), API.loadCategories(),
      API.loadProducts(), API.loadPaymentMethods(),
    ]);
    renderCats(); renderAll();
  } catch (e) {
    showErrorState('تعذر تحميل المنتجات.', boot); // زر إعادة المحاولة
  }
}
boot();
```

4. تدفق الطلب يصبح:

```js
const key = API.newIdempotencyKey();          // مرة واحدة لكل محاولة
const order = await API.createOrder({...});    // → awaiting_receipt
await API.uploadReceipt(order.order_id, file, pct => setProgress(pct));
const { order: final, whatsappNumber } = await API.submitOrder(order.order_id, ref);
window.open(API.buildWhatsAppUrl(whatsappNumber, final, items), '_blank');
```

**مهم:** لا تفتح واتساب إلا بعد نجاح `submitOrder`.

---

## 9. القرارات المعمارية

**لماذا الحد الأقصى يُفرض عند التأكيد لا عند الإنشاء؟**
حسب §12 الطلب بحالة `awaiting_receipt` ليس طلباً نهائياً، وحسب §17 لا يُحتسب نشطاً. لذا الفحص يجري **مرتين**: عند الإنشاء (لتجربة مستخدم أفضل) وعند التأكيد (الضمان الحقيقي) — كلاهما تحت `pg_advisory_xact_lock` على رقم الهاتف، فحتى مع 10 طلبات متزامنة لا يتجاوز العدد 2.

**قيد قاعدة البيانات على الوصل (§27)**
`receipt_required_after_submit` يمنع فيزيائياً وجود طلب `pending_payment_review` بلا وصل — حتى لو أخطأ كود مستقبلي.

**فحص نوع الصورة**
`Content-Type` قابل للتزوير، لذا `upload-receipt` يفحص **البايتات الأولى** فعلياً (magic bytes). ملف `.exe` مُسمّى `.jpg` سيُرفض.

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

```bash
# اختبارات SQL (على قاعدة غير إنتاجية — كل شيء داخل rollback)
psql "$DATABASE_URL" -f tests/backend.test.sql

# اختبار التزامن
export SUPABASE_URL=... SUPABASE_ANON_KEY=... PRODUCT_ID=... PLAN_ID=... PAYMENT_METHOD_ID=...
bash tests/race-test.sh
```

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

- [ ] إنشاء مشروع Supabase وتشغيل `db push`
- [ ] وضع `SUPABASE_URL` و`ANON_KEY` في `js/janeiro-api.js`
- [ ] إنشاء بوت Telegram وضبط الأسرار
- [ ] تعبئة رقم واتساب في `store_settings`
- [ ] تعبئة بيانات CCP/BaridiMob/Flexy في `payment_methods`
- [ ] إنشاء حساب أدمن وإضافة صفه في `profiles`
- [ ] رفع صور المنتجات إلى `product-media` وتحديث `poster_path`
- [ ] ربط `janeiro-api.js` بالـHTML (خطوة 8)
- [ ] إضافة skeletons وError state — البنية جاهزة، التصميم عليك
- [ ] ضبط `ALLOWED_ORIGIN` على نطاقك الحقيقي قبل الإطلاق
- [ ] **تشغيل كل الاختبارات**

---

## 13. تنبيه أمني أخير

- ✅ `SERVICE_ROLE_KEY` غير موجود في أي ملف فرونت إند
- ✅ `TELEGRAM_BOT_TOKEN` في Supabase Secrets فقط
- ✅ `.env` الحقيقي **لا يُرفع لـgit** — أضف `.env` إلى `.gitignore`
- ⚠️ قبل الإطلاق: غيّر `ALLOWED_ORIGIN` من `*` إلى نطاقك، وإلا أي موقع يستطيع استدعاء دوالك
