-- ============================================================
-- إضافة منتج كامل — انسخ، عدّل القيم، شغّل في Supabase → SQL Editor
--
-- منتج واحد يتوزّع على خمسة جداول. هذا الملف يملأها كلها في معاملة
-- واحدة: إما ينجح كل شيء أو لا شيء — فلا يبقى منتج بلا خطة.
--
-- آمن للتكرار: شغّله ثانيةً بنفس الـslug فيُحدِّث بدل أن يُكرِّر.
-- ============================================================
begin;

do $$
declare
  v_pid uuid;
  v_cat uuid;

  -- ==========================================================
  -- ١) عدّل هذه القيم
  -- ==========================================================
  c_slug   constant text := 'canva-pro-team';           -- معرّف فريد، حروف لاتينية وشرطات
  c_name   constant text := 'Canva Pro للفرق';
  c_cat    constant text := 'design';                    -- ai / design / work / social / fun / dev
  c_desc   constant text := 'أدوات تصميم احترافية لفريق كامل.';  -- ≤ 200 حرف
  c_accent constant text := '#00C4CC';                   -- لازم بصيغة ‎#RRGGBB
  c_status constant text := 'published';                 -- published يعني قابل للشراء
  c_order  constant int  := 11;                          -- ترتيب الظهور

  -- الضمان: none / activation / days / subscription_duration / custom
  --   'days'   ← لازم تحدّد c_warranty_days
  --   'custom' ← لازم تحدّد c_warranty_label
  c_warranty       constant text := 'subscription_duration';
  c_warranty_days  constant int  := null;
  c_warranty_label constant text := null;

  -- الشارة: hot / new / off / null
  c_badge       constant text := 'new';
  c_badge_label constant text := 'جديد';

begin
  select id into v_cat from categories where slug = c_cat;
  if v_cat is null then
    raise exception 'لا يوجد تصنيف بالـslug: %  — أضفه أولاً في جدول categories', c_cat;
  end if;

  insert into products (
    name, slug, category_id, short_description, accent_color,
    warranty_type, warranty_days, warranty_label,
    badge_type, badge_label, status, sort_order)
  values (
    c_name, c_slug, v_cat, c_desc, c_accent,
    c_warranty::warranty_type, c_warranty_days, c_warranty_label,
    nullif(c_badge,'')::text, nullif(c_badge_label,''),
    c_status::product_status, c_order)
  on conflict (slug) do update set
    name = excluded.name, category_id = excluded.category_id,
    short_description = excluded.short_description, accent_color = excluded.accent_color,
    warranty_type = excluded.warranty_type, warranty_days = excluded.warranty_days,
    warranty_label = excluded.warranty_label, badge_type = excluded.badge_type,
    badge_label = excluded.badge_label, status = excluded.status,
    sort_order = excluded.sort_order
  returning id into v_pid;

  -- إعادة البناء بدل التكديس، حتى تكون إعادة التشغيل نظيفة
  delete from product_plans        where product_id = v_pid;
  delete from product_features     where product_id = v_pid;
  delete from product_requirements where product_id = v_pid;

  -- ==========================================================
  -- ٢) الخطط والأسعار
  --    old_price لازم يكون أكبر من price، أو null
  -- ==========================================================
  insert into product_plans (product_id, name, price, old_price, sort_order) values
    (v_pid, 'شهر واحد',  2400, null, 1),
    (v_pid, '3 أشهر',    6500, 7200, 2),
    (v_pid, '12 شهراً', 22000, null, 3);

  -- ==========================================================
  -- ٣) المزايا — تظهر في صفحة المنتج
  -- ==========================================================
  insert into product_features (product_id, label, sort_order) values
    (v_pid, 'مساحة عمل للفريق كامل', 1),
    (v_pid, 'مكتبة قوالب مشتركة',    2),
    (v_pid, 'إزالة الخلفية بنقرة',   3);

  -- ==========================================================
  -- ٤) حقول التفعيل — ما تطلبه من العميل ليصلك مع الطلب
  --    field_type: email / phone / username / text / number / account_id / custom
  --    ⚠ ممنوع طلب كلمة السر — القاعدة ترفضه
  -- ==========================================================
  insert into product_requirements
    (product_id, label, field_type, placeholder, is_required, sort_order) values
    (v_pid, 'البريد الإلكتروني للحساب', 'email', 'name@example.com', true, 1);

  raise notice 'تم: % (%)', c_name, v_pid;
end $$;

commit;

-- ============================================================
-- بعد الحفظ: ارفع صورة المنتج
--
-- Supabase → Storage → product-media → Upload
--   المسار المقترح:  products/<slug>.png
--   المقاس: 1000×1000 بكسل، PNG أو WebP، ≤ 5 ميغابايت
--
-- ثم اربطها:
--   update products set poster_path = 'products/canva-pro-team.png'
--    where slug = 'canva-pro-team';
--
-- بلا صورة يظهر البوستر البديل المصمَّم — ليس عطلاً.
-- ============================================================
