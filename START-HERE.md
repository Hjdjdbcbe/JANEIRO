# Janeiro Store — ابدأ من هنا

متجر رقمي جزائري لبيع الاشتراكات والخدمات الرقمية.

---

## حالة المشروع الآن

| الجزء | الحالة |
|---|---|
| **الفرونت إند** | ✅ مكتمل بصرياً — `frontend/index.html` |
| **الباكند** | ✅ **شُغِّل واختُبر فعلياً على PostgreSQL محلي، وأُصلحت 5 أخطاء** |
| **الربط بينهما** | ✅ تم — الفرونت يقرأ كل شيء من قاعدة البيانات |
| **أيقونات التصنيفات** | ✅ بنية تستقبل صور 128×128، مع أيقونة مصممة بديلة (README §14) |
| **عروض اليوم** | ✅ جدول `daily_deals` + عدّاد خادمي، والسعر يُحتسب في `create_order` (README §13) |
| **لوحة التحكم** | ✅ `dashboard/` — تطبيق مستقل يُنشر على نطاق منفصل: نظرة عامة + إدارة الطلبات (README §15) |
| **النشر على Supabase** | ❌ **لم يتم — يحتاج حسابك أنت** (اقرأ §"الخطوة المتبقية") |

---

## ما الذي شُغِّل فعلاً

كل ما يلي نُفِّذ وشوهدت نتيجته — لا شيء منه مُفترض:

- ✅ الـmigrations السبعة طُبِّقت على PostgreSQL 16 نظيف، ثم طُبِّقت **مرة ثانية** للتأكد من قابلية التكرار
- ✅ `tests/backend.test.sql` — 59 تأكيداً (assert) موزعة على 27 مجموعة، كلها تمر
- ✅ `tests/local/concurrency.test.sh` — 4 حالات تزامن باتصالات متوازية حقيقية
- ✅ `tests/frontend/e2e.test.js` — 25 فحصاً في Chromium على الصفحة الحقيقية
- ✅ `tests/frontend/ui.test.js` — 38 فحصاً: الأيقونات، العروض والعدّاد، حدود الحركة، والعرض عند 375/390/430px
- ✅ كل اختبار تراجُع (regression) تم التحقق من أنه **يفشل** عند إرجاع الخطأ الذي يحرسه

```bash
bash tests/local/run-tests.sh        # الباكند كاملاً، بدون Supabase
```

**ما لم يُشغَّل** (يحتاج مشروعاً منشوراً): الـEdge Functions على Deno،
رفع ملف حقيقي إلى Storage، وإرسال رسالة Telegram. منطق قاعدة البيانات
الذي تستدعيه هذه الدوال مُختبَر بالكامل، لكن الدوال نفسها لم تُنفَّذ قط.

---

## الأخطاء التي وُجدت وأُصلحت

الكود لم يكن مُختبراً، وكان فيه خمسة أخطاء حقيقية:

| # | الخطأ | الأثر |
|---|---|---|
| 1 | `create_order` مع نفس `idempotency_key` في وقت واحد | نقرة مزدوجة → خطأ 500 للعميل |
| 2 | `X-Forwarded-For` غير صالح يكسر `client_ip::inet` | ترويسة غريبة → الطلب يفشل كلياً |
| 3 | `submit_order` بلا حارس على الحالة | تأكيدان متزامنان → **رسالتا Telegram** لطلب واحد |
| 4 | `create trigger` بلا `drop if exists` | `db push` مرة ثانية يفشل |
| 5 | `payment_methods` بلا مفتاح فريد | إعادة تشغيل الـseed **تُكرِّر** كل طرق الدفع |

وكذلك: اختبارات الـRLS كانت **لا يمكن أن تفشل** — كانت ترفع `FAILED`
داخل كتلة تلتقطها بـ`when others`، فتبتلع إشارة فشلها. أُعيدت كتابتها.

---

## الملفات

```
frontend/index.html          الموقع كامل — يقرأ البيانات من Supabase الآن
js/janeiro-api.js            طبقة الربط — مربوطة ومُختبرة
dashboard/                   لوحة التحكم — تُنشر وحدها، لا مع المتجر

supabase/migrations/         7 ملفات SQL بالترتيب
supabase/functions/          4 Edge Functions

tests/backend.test.sql       اختبارات SQL
tests/race-test.sh           اختبار التزامن عبر Edge Functions (يحتاج نشراً)
tests/local/                 تشغيل الباكند كاملاً بلا Supabase
tests/frontend/              اختبار المتصفح على الصفحة الحقيقية

README.md                    ⭐ التوثيق الكامل
.env.example                 المتغيرات المطلوبة
```

---

## الخطوة المتبقية — النشر (تحتاج حسابك)

لم أستطع إنشاء مشروع Supabase: البيئة التي عملت فيها تحجب
`api.supabase.com` (رفض 403 على مستوى الشبكة)، ولا تملك بيانات حسابك
أصلاً. هذه الخطوة تحتاجك أنت:

```bash
supabase link --project-ref YOUR-PROJECT-REF
supabase db push

supabase secrets set TELEGRAM_BOT_TOKEN=...
supabase secrets set TELEGRAM_CHAT_ID=...
supabase secrets set ALLOWED_ORIGIN=https://your-domain.com

supabase functions deploy create-order
supabase functions deploy upload-receipt
supabase functions deploy submit-order
supabase functions deploy track-order
```

ثم ضع المفاتيح للفرونت إند (المفتاح `anon` عام وآمن في المتصفح):

```html
<!-- قبل وسم <script type="module"> في frontend/index.html -->
<script>window.JANEIRO_CONFIG = {
  SUPABASE_URL: "https://xxxx.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOi..."
};</script>
```

بعد النشر شغّل ما لم يمكن تشغيله هنا (تفاصيلها في README §11):
`tests/race-test.sh`، ورفع وصل حقيقي، ورسالة Telegram.

---

## قواعد لا تُكسر

- **لا تعِد تصميم الفرونت إند.** الهوية البصرية نهائية ومتفق عليها.
- **لا تخترع بيانات.** ممنوع تقييمات نجوم، آراء عملاء، أعداد طلبات، خصومات — إلا ما هو موجود فعلاً في قاعدة البيانات.
- **لا تضع أي سرّ في الفرونت إند.** `SERVICE_ROLE_KEY` و`TELEGRAM_BOT_TOKEN` في Supabase Secrets فقط.
- **الفرونت إند ليس مصدر الحقيقة.** الأسعار والإجماليات وأرقام الطلبات تُحسب في الخادم دائماً.
- **لا تقل "تم الاختبار بنجاح" قبل أن تشغّله فعلاً** وترى النتيجة.

---

## قرارات معمارية مقصودة (لا تغيّرها بدون سبب)

1. **حد الطلبين يُفرض عند التأكيد لا الإنشاء** — لأن `awaiting_receipt` ليس طلباً نهائياً. الفحص يجري مرتين تحت `pg_advisory_xact_lock`.
   ✅ تم التحقق: 10 اتصالات متوازية → طلبان نشطان بالضبط.
2. **`create_order` و`submit_order` ممنوعتان على `anon`** — تمر عبر Edge Functions حصراً. ✅ تم التحقق.
3. **فحص الصور بالبايتات لا بالـContent-Type** — الترويسة قابلة للتزوير.
   ⚠️ منطق الفحص مكتوب لكنه لم يُنفَّذ على Deno بعد.
4. **التتبع لا يميّز بين "رقم خاطئ" و"هاتف خاطئ"** — منعاً لاستكشاف أرقام الطلبات. ✅ تم التحقق.

---

## قبل الإطلاق

- [ ] نشر مشروع Supabase (الخطوة أعلاه)
- [ ] `ALLOWED_ORIGIN` من `*` إلى النطاق الحقيقي
- [ ] رقم واتساب في `store_settings`
- [ ] بيانات CCP/BaridiMob/Flexy في `payment_methods`
- [ ] صور المنتجات في bucket `product-media`
- [x] `.env` في `.gitignore`
