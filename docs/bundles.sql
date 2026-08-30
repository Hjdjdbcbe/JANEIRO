-- ============================================================
-- الباقات — هذا هو الملف الذي تعدّله لإضافة باقة أو تغييرها أو حذفها.
--
--   تشغيله:  psql -d janeiro_test -f docs/bundles.sql
--   (وعلى Supabase: الصق محتواه في SQL Editor ثم Run)
--
-- تشغيله مرة أو عشر مرات سيّان: كل باقة تُكتب من جديد في كل مرة،
-- فلا تتكرر ولا تتراكم.
--
-- تستطيع فعل الشيء نفسه من لوحة التحكم في تبويب «الباقات» بالضغط
-- بدل الكتابة. هذا الملف للمن يفضّل النص، ولنسخ باقاتك بين قاعدتين.
--
-- ─────────────────────────────────────────────────────────────
-- القواعد التي تفرضها قاعدة البيانات (وستخبرك إن خالفتها):
--
--   • منتجان على الأقل في الباقة المعروضة.
--   • سعر الباقة أقل من مجموع أسعار خططها منفردة.
--   • كل سطر يختار خطة بعينها من المنتج، لأن سعر المنتج يختلف بين
--     خطة وأخرى، ومجموع الأسعار لا يُعرف بدون تحديد الخطة.
--   • السعر تكتبه أنت كاملاً بالدينار. لا يُحسب كنسبة.
--
-- ملاحظة على الترتيب: الباقة تُكتب موقوفة أولاً، ثم تُضاف منتجاتها،
-- ثم تُفعّل. السبب أن قاعدة البيانات تفحص الشكل فوراً عند كل تغيير،
-- والباقة في منتصف تعديلها تكون لحظةً بمنتج واحد.
-- ============================================================

begin;

-- ════════════════════════════════════════════════════════════
-- باقة ١ — انسخ هذا القالب كاملاً لكل باقة جديدة
-- ════════════════════════════════════════════════════════════
do $$
declare
  -- ── عدّل هذه الأسطر وحدها ──────────────────────────────────
  v_slug   text := 'ai-tools';                       -- معرّف بالحروف اللاتينية الصغيرة
  v_name   text := 'باقة أدوات الذكاء الاصطناعي';
  v_desc   text := 'ثلاث أدوات تستعملها كل يوم، بسعر واحد.';
  v_price  numeric := 3555;                          -- سعر الباقة كاملاً بالدينار
  v_active boolean := true;                          -- false لإخفائها مؤقتاً
  v_order  int := 1;                                 -- ترتيب ظهورها

  -- المنتجات: معرّف المنتج (slug) واسم الخطة كما هو في لوحة التحكم.
  -- اترك اسم الخطة فارغاً ('') لاختيار أول خطة نشطة للمنتج.
  v_items  text[][] := array[
    ['gemini-pro',  ''],
    ['notion-plus', ''],
    ['canva-pro',   '']
  ];
  -- ──────────────────────────────────────────────────────────

  v_id     uuid;
  v_pid    uuid;
  v_plid   uuid;
  v_pprice numeric;      -- سعر الخطة المختارة، منفصل عن سعر الباقة
  v_list   numeric := 0;
  i        int;
begin
  -- الباقة نفسها، موقوفة في هذه المرحلة
  insert into bundles (slug, name, short_description, bundle_price, is_active, sort_order)
  values (v_slug, v_name, nullif(v_desc,''), v_price, false, v_order)
  on conflict (slug) do update set
    name = excluded.name,
    short_description = excluded.short_description,
    bundle_price = excluded.bundle_price,
    is_active = false,
    sort_order = excluded.sort_order
  returning id into v_id;

  delete from bundle_items where bundle_id = v_id;

  for i in 1 .. array_length(v_items, 1) loop
    select p.id into v_pid from products p where p.slug = v_items[i][1];
    if v_pid is null then
      raise exception 'لا يوجد منتج بالمعرّف "%" — راجع قائمة المنتجات', v_items[i][1];
    end if;

    if coalesce(v_items[i][2], '') = '' then
      select pl.id, pl.price into v_plid, v_pprice
        from product_plans pl
       where pl.product_id = v_pid and pl.is_active
       order by pl.sort_order limit 1;
    else
      select pl.id, pl.price into v_plid, v_pprice
        from product_plans pl
       where pl.product_id = v_pid and pl.name = v_items[i][2] and pl.is_active;
    end if;

    if v_plid is null then
      raise exception 'المنتج "%" ليس له خطة نشطة بالاسم "%"', v_items[i][1], v_items[i][2];
    end if;

    insert into bundle_items (bundle_id, product_id, plan_id, sort_order)
    values (v_id, v_pid, v_plid, i);

    v_list := v_list + v_pprice;
  end loop;

  -- التفعيل أخيراً: هنا تفحص قاعدة البيانات الشكل كاملاً
  if v_active then
    update bundles set is_active = true where id = v_id;
  end if;

  raise notice 'الباقة "%": % منتجات، مجموع الخطط % دج، سعر الباقة % دج، التوفير % دج',
    v_name, array_length(v_items,1), v_list, v_price, v_list - v_price;
end $$;

-- ════════════════════════════════════════════════════════════
-- لحذف باقة: أزل علامتَي التعليق واكتب معرّفها
-- ════════════════════════════════════════════════════════════
-- delete from bundles where slug = 'ai-tools';
--
-- الطلبات التي بيعت بهذه الباقة تبقى كما هي: أسطرها تحتفظ باسم
-- الباقة كما كان وقت البيع، وتفقد الإشارة إليها فقط.

commit;

-- ما هو معروض الآن:
select slug, name, bundle_price, list_total, saving_pct
  from public_bundles order by sort_order;
