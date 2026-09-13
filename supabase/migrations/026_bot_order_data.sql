-- bundle: bot
-- ============================================================
-- Janeiro Store — 026 معطيات الطلب: المنصة، المدة، السعر
--
-- المرحلة 1 من تصحيح الفلو.
--
-- الوثيقة صار المفروض تُولَد من البيعة نفسها بلا ما تُعاد الأسئلة
-- على الأدمن. وذاك مستحيل اليوم: bot_issues تعرف البطاقة والبائع
-- ولا تعرف لا منصة ولا مدة ولا سعر. المنصة (bot_products) منفصلة
-- كلياً عن قائمة منصات الوثيقة (bot_platforms)، والمدة على
-- bot_variants فارغة في كل صنف أُضيف باليد، والسعر غير موجود في
-- أي جدول.
--
-- فهذه الهجرة تسدّ الثقوب الثلاثة في طبقة الداتا وحدها. لا تلمس
-- البوت ولا الصفحات — ذاك في 027 وما بعدها.
--
-- العملة: دينار جزائري، ثابتة. لا عمود لها: متجر واحد ببلد واحد،
-- وعمود عملة بقيمة واحدة كذبة تُصدَّق لاحقاً.
-- ============================================================

-- ------------------------------------------------------------
-- 1. المنصة على المنتج
-- ------------------------------------------------------------
-- نصّ بمفتاح أجنبي على bot_platforms(name): المنصة تُعطَّل ولا
-- تُحذف (bot_remove_platform)، فالمفتاح لا ينكسر، ويمنع في نفس
-- الوقت كتابة «سناب شات» مرة و«Snapchat Plus» مرة فتتشتّت
-- الإحصاءات حسب المنصة.
alter table bot_products
  add column if not exists platform text;

do $$ begin
  alter table bot_products add constraint bot_products_platform_fk
    foreign key (platform) references bot_platforms(name)
    on update cascade on delete set null;
exception when duplicate_object then null; end $$;

create index if not exists idx_bot_products_platform on bot_products(platform);

-- ------------------------------------------------------------
-- 2. السعر: افتراضي على الصنف، ولقطة على العملية
-- ------------------------------------------------------------
-- عمودان لا عمود واحد. bot_variants.price هو السعر المعتاد،
-- يُبدَّل متى شاء المالك. bot_issues.price لقطة تُنسخ لحظة حجز
-- البطاقة وتبقى كما هي إلى الأبد: رفع السعر اليوم يجب ألّا يغيّر
-- مداخيل الشهر الماضي في التقارير.
alter table bot_variants add column if not exists price numeric(10,2);
alter table bot_issues   add column if not exists price numeric(10,2);

do $$ begin
  alter table bot_variants add constraint bot_variants_price_ok
    check (price is null or (price >= 0 and price < 100000000));
exception when duplicate_object then null; end $$;

do $$ begin
  alter table bot_issues add constraint bot_issues_price_ok
    check (price is null or (price >= 0 and price < 100000000));
exception when duplicate_object then null; end $$;

-- التقارير تسأل «كم بيع بين تاريخين» — فهرس على لحظة الإتمام
-- وحدها، والمؤكَّد فقط: الملغى ليس بيعاً.
create index if not exists idx_bot_issues_settled
  on bot_issues (settled_at) where status = 'confirmed';

-- ------------------------------------------------------------
-- 3. المدة بالأيام على الوثيقة
-- ------------------------------------------------------------
-- 025 عرفت الأشهر وحدها. المدة المخصّصة بالأيام (1–999) تحتاج
-- عمودها: خلطها مع bonus_days يخسر التفرقة بين ما بِيع وما أُهدي،
-- وهي التفرقة التي بُني عليها الجدول من أوّله.
alter table bot_certificates
  add column if not exists duration_days integer;

do $$ begin
  alter table bot_certificates add constraint bot_cert_duration_days_ok
    check (duration_days is null or duration_days between 1 and 999);
exception when duplicate_object then null; end $$;

-- إمّا بالأشهر وإمّا بالأيام، لا الاثنان: «3 أشهر و40 يوماً» مدة
-- لا تُعرض في أي لغة من الثلاث بشكل مفهوم.
do $$ begin
  alter table bot_certificates add constraint bot_cert_duration_one_ok
    check (months is null or duration_days is null);
exception when duplicate_object then null; end $$;

-- والوثيقة بلا بيعة صار يكفيها أن تحمل منصة ومدة بأي من
-- الوحدتين. القيد القديم كان يشترط الأشهر تحديداً.
alter table bot_certificates drop constraint if exists bot_cert_subject_ok;
alter table bot_certificates add constraint bot_cert_subject_ok
  check (issue_id is not null
         or (platform is not null
             and (months is not null or duration_days is not null)));

-- ملاحظة: «وثيقة واحدة لكل بيعة» مضمون أصلاً. issue_id عليه قيد
-- unique من 023، وPostgreSQL يعتبر NULL مميّزاً عن NULL، فالمسار
-- اليدوي (issue_id فارغ) يبقى مفتوحاً بلا تعارض. لا فهرس جديد.

-- ------------------------------------------------------------
-- 4. حساب النهاية: نسخة رابعة الوسائط
-- ------------------------------------------------------------
-- الأشهر قبل الأيام داخل interval واحد، كما في 025. والمدة
-- بالأيام تُجمع مع الهدية في وسيط الأيام: 30 يوماً + 7 هدية = 37،
-- وهو نفس ما يعطيه التنفيذ على خطوتين.
--
-- النسخة ثلاثية الوسائط تبقى كما كانت — ينادونها bot_engagement_claim
-- وbot_wizard_preview — لكنها صارت تفوّض للجديدة، فالمنطق في مكان
-- واحد.
create or replace function bot_engagement_expiry(
  p_start timestamptz, p_months int, p_bonus_days int, p_duration_days int
) returns timestamptz
language sql immutable set search_path = public as $$
  select (((p_start at time zone 'Africa/Algiers')
           + make_interval(months => coalesce(p_months, 0),
                           days   => coalesce(p_duration_days, 0)
                                   + coalesce(p_bonus_days, 0)))
          at time zone 'Africa/Algiers');
$$;

create or replace function bot_engagement_expiry(
  p_start timestamptz, p_months int, p_bonus_days int
) returns timestamptz
language sql immutable set search_path = public as $$
  select bot_engagement_expiry(p_start, p_months, p_bonus_days, 0);
$$;

-- ------------------------------------------------------------
-- 5. المدة: من وحدات المخزون إلى وحدات الوثيقة
-- ------------------------------------------------------------
-- bot_variants تخزّن (value, unit) بأربع وحدات. الوثيقة تعرف
-- اثنتين: أشهر أو أيام. هذه هي الترجمة، في مكان واحد، تُنادى من
-- الهجرة ومن البوت على السواء.
--
--   سنة  → أشهر × 12      شهر → أشهر
--   أسبوع → أيام × 7       يوم → أيام
create or replace function bot_duration_to_engagement(
  p_value int, p_unit text
) returns jsonb
language sql immutable set search_path = public as $$
  select case
    when p_value is null or p_unit is null then
      jsonb_build_object('months', null, 'days', null)
    when p_unit = 'year'  then jsonb_build_object('months', p_value * 12, 'days', null)
    when p_unit = 'month' then jsonb_build_object('months', p_value,      'days', null)
    when p_unit = 'week'  then jsonb_build_object('months', null, 'days', p_value * 7)
    when p_unit = 'day'   then jsonb_build_object('months', null, 'days', p_value)
    else jsonb_build_object('months', null, 'days', null)
  end;
$$;

-- ما تحتاجه الوثيقة من صنف بعينه: المنصة والمدة مترجمة والسعر.
create or replace function bot_variant_subject(p_variant_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_variant bot_variants;
  v_product bot_products;
  v_dur     jsonb;
begin
  select * into v_variant from bot_variants where id = p_variant_id;
  if not found then raise exception 'VARIANT_NOT_FOUND'; end if;
  select * into v_product from bot_products where id = v_variant.product_id;

  v_dur := bot_duration_to_engagement(v_variant.duration_value, v_variant.duration_unit);

  return jsonb_build_object(
    'variant_id',   v_variant.id,
    'variant_name', v_variant.name,
    'product_id',   v_product.id,
    'product_name', v_product.name,
    'platform',     v_product.platform,
    'months',       v_dur->'months',
    'days',         v_dur->'days',
    'price',        v_variant.price,
    -- ما ينقص قبل أن تُولَد وثيقة من بيعة هذا الصنف
    'needs_platform', v_product.platform is null,
    'needs_duration', v_variant.duration_value is null or v_variant.duration_unit is null
  );
end $$;

-- ------------------------------------------------------------
-- 6. تعمير الناقص — أوامر المالك
-- ------------------------------------------------------------
-- المنصة تُحفظ على المنتج لا على العملية: يُسأل عنها مرة واحدة في
-- عمر المنتج، ولا يُسأل بعدها أي أدمن مرة أخرى. وإن كان الاسم
-- جديداً يُضاف إلى قائمة المنصات بدل أن يُرفض — المالك يعرف
-- بضاعته، والقائمة وُضعت للتوحيد لا للمنع.
create or replace function bot_set_product_platform(
  p_telegram_id bigint, p_product_id uuid, p_platform text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_prod bot_products; v_name text; v_next int;
begin
  perform bot_owner(p_telegram_id);
  v_name := btrim(coalesce(p_platform, ''));

  select * into v_prod from bot_products where id = p_product_id;
  if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;

  if v_name = '' then
    update bot_products set platform = null where id = p_product_id;
    return jsonb_build_object('product', v_prod.name, 'platform', null);
  end if;

  if char_length(v_name) > 60 then raise exception 'INVALID_PLATFORM'; end if;

  if not exists (select 1 from bot_platforms where name = v_name) then
    select coalesce(max(sort_order), 0) + 10 into v_next from bot_platforms;
    insert into bot_platforms (name, sort_order) values (v_name, v_next)
      on conflict (name) do nothing;
  else
    -- منصة معطّلة سابقاً تعود للعمل بمجرّد أن يُسند إليها منتج
    update bot_platforms set is_active = true where name = v_name and not is_active;
  end if;

  update bot_products set platform = v_name where id = p_product_id;
  return jsonb_build_object('product', v_prod.name, 'platform', v_name);
end $$;

-- المدة تُحفظ على الصنف، للسبب نفسه. والحدود هي حدود الوثيقة:
-- 1–60 شهراً أو 1–999 يوماً بعد الترجمة، فلا يُقبل اليوم ما
-- سيُرفض عند الإصدار.
create or replace function bot_set_variant_duration(
  p_telegram_id bigint, p_variant_id uuid, p_value int, p_unit text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_var bot_variants; v_dur jsonb; v_m int; v_d int;
begin
  perform bot_owner(p_telegram_id);

  select * into v_var from bot_variants where id = p_variant_id;
  if not found then raise exception 'VARIANT_NOT_FOUND'; end if;

  if p_value is null or p_unit is null then
    update bot_variants set duration_value = null, duration_unit = null
     where id = p_variant_id;
    return jsonb_build_object('variant', v_var.name, 'months', null, 'days', null);
  end if;

  if p_unit not in ('day','week','month','year') then raise exception 'INVALID_UNIT'; end if;
  if p_value <= 0 then raise exception 'INVALID_DURATION'; end if;

  v_dur := bot_duration_to_engagement(p_value, p_unit);
  v_m := nullif(v_dur->>'months', '')::int;
  v_d := nullif(v_dur->>'days',   '')::int;

  if v_m is not null and v_m not between 1 and 60  then raise exception 'DURATION_RANGE'; end if;
  if v_d is not null and v_d not between 1 and 999 then raise exception 'DURATION_RANGE'; end if;

  update bot_variants set duration_value = p_value, duration_unit = p_unit
   where id = p_variant_id;

  return jsonb_build_object(
    'variant', v_var.name, 'value', p_value, 'unit', p_unit,
    'months', v_m, 'days', v_d
  );
end $$;

-- السعر المعتاد للصنف. NULL يمسحه — ولا يعني صفراً: صنف بلا سعر
-- يُعدّ «غير مسعّر» في التقارير، وصنف بسعر صفر بيع مجاناً فعلاً.
create or replace function bot_set_price(
  p_telegram_id bigint, p_variant_id uuid, p_price numeric
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_var bot_variants; v_prod bot_products;
begin
  perform bot_owner(p_telegram_id);

  select * into v_var from bot_variants where id = p_variant_id;
  if not found then raise exception 'VARIANT_NOT_FOUND'; end if;
  select * into v_prod from bot_products where id = v_var.product_id;

  if p_price is not null and (p_price < 0 or p_price >= 100000000) then
    raise exception 'INVALID_PRICE';
  end if;

  update bot_variants set price = round(p_price, 2) where id = p_variant_id;

  return jsonb_build_object(
    'product', v_prod.name, 'variant', v_var.name,
    'price', round(p_price, 2), 'currency', 'DZD'
  );
end $$;

-- تعديل سعر عملية بعينها: تخفيض، صفقة، خطأ مطبعي. الملغاة لا
-- تُسعَّر — ليست بيعاً. وغير صاحب العملية لا يمسّها إلا المالك.
create or replace function bot_issue_set_price(
  p_telegram_id bigint, p_issue_id uuid, p_price numeric
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin bot_admins; v_issue bot_issues;
begin
  v_admin := bot_actor(p_telegram_id);

  select * into v_issue from bot_issues where id = p_issue_id for update;
  if not found then raise exception 'ISSUE_NOT_FOUND'; end if;
  if v_issue.admin_id <> v_admin.id and v_admin.role <> 'owner' then
    raise exception 'NOT_YOUR_ISSUE';
  end if;
  if v_issue.status = 'cancelled' then raise exception 'ISSUE_CANCELLED'; end if;

  if p_price is not null and (p_price < 0 or p_price >= 100000000) then
    raise exception 'INVALID_PRICE';
  end if;

  update bot_issues set price = round(p_price, 2) where id = p_issue_id;

  return jsonb_build_object(
    'issue_id', p_issue_id, 'price', round(p_price, 2), 'currency', 'DZD'
  );
end $$;

-- ------------------------------------------------------------
-- 7. جرد: ما هو معمّر وما هو ناقص
-- ------------------------------------------------------------
-- تُقرأ قبل أي تعمير، ليراجع المالك بعينه أيّ منتج على أيّ منصة
-- وأيّ صنف بأيّ مدة وسعر. لا تخمين ولا تعمير تلقائي في أي مكان
-- من هذه الهجرة.
create or replace function bot_data_audit(p_telegram_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_rows jsonb; v_np int; v_nd int; v_nr int;
begin
  perform bot_owner(p_telegram_id);

  select coalesce(jsonb_agg(x.j order by x.so, x.nm), '[]'::jsonb) into v_rows
  from (
    select pr.sort_order as so, pr.name as nm,
      jsonb_build_object(
        'product_id', pr.id,
        'code',       pr.code,
        'name',       pr.name,
        'is_active',  pr.is_active,
        'platform',   pr.platform,
        'variants', coalesce((
          select jsonb_agg(v.j order by v.so, v.nm)
            from (
              select va.sort_order as so, va.name as nm,
                jsonb_build_object(
                  'variant_id',     va.id,
                  'code',           va.code,
                  'name',           va.name,
                  'is_active',      va.is_active,
                  'duration_value', va.duration_value,
                  'duration_unit',  va.duration_unit,
                  'months',         bot_duration_to_engagement(
                                      va.duration_value, va.duration_unit)->'months',
                  'days',           bot_duration_to_engagement(
                                      va.duration_value, va.duration_unit)->'days',
                  'price',          va.price
                ) as j
              from bot_variants va where va.product_id = pr.id
            ) v
        ), '[]'::jsonb)
      ) as j
    from bot_products pr
  ) x;

  select count(*) into v_np from bot_products where platform is null;
  select count(*) into v_nd from bot_variants
   where duration_value is null or duration_unit is null;
  select count(*) into v_nr from bot_variants where price is null;

  return jsonb_build_object(
    'products', v_rows,
    'missing_platform', v_np,
    'missing_duration', v_nd,
    'missing_price',    v_nr,
    'currency',         'DZD'
  );
end $$;

-- ------------------------------------------------------------
-- 8. اللقطة عند الحجز
-- ------------------------------------------------------------
-- bot_request_card كما هي في 021 حرفاً بحرف، بزيادة واحدة: السعر
-- يُنسخ من الصنف إلى العملية لحظة الحجز، ويُرجَع ليُعرض على
-- البائع فيصحّحه قبل التأكيد إن لزم.
create or replace function bot_request_card(
  p_telegram_id bigint,
  p_variant_id  uuid,
  p_customer_ref text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin   bot_admins;
  v_variant bot_variants;
  v_product bot_products;
  v_card    bot_cards;
  v_issue   bot_issues;
  v_pending int;
  v_limit   int;
begin
  v_admin := bot_actor(p_telegram_id);

  select * into v_variant from bot_variants where id = p_variant_id;
  if not found or not v_variant.is_active then raise exception 'VARIANT_NOT_FOUND'; end if;

  select * into v_product from bot_products where id = v_variant.product_id;
  if not v_product.is_active then raise exception 'VARIANT_NOT_FOUND'; end if;

  select coalesce(nullif(value,'')::int, 5) into v_limit
    from store_settings where key = 'bot_pending_limit';
  v_limit := coalesce(v_limit, 5);

  select count(*) into v_pending
    from bot_issues where admin_id = v_admin.id and status = 'pending';
  if v_pending >= v_limit then
    raise exception 'PENDING_LIMIT:%', v_limit;
  end if;

  -- أقدم بطاقة أولاً (طابور)، وتخطّي أي صف يمسكه طلب متزامن آخر.
  select * into v_card
    from bot_cards
   where variant_id = p_variant_id and status = 'available'
   order by seq
   for update skip locked
   limit 1;
  if not found then raise exception 'OUT_OF_STOCK'; end if;

  update bot_cards set status = 'reserved' where id = v_card.id;

  insert into bot_issues (card_id, variant_id, admin_id, card_code, customer_ref, price)
  values (v_card.id, p_variant_id, v_admin.id, v_card.code,
          nullif(btrim(coalesce(p_customer_ref,'')), ''), v_variant.price)
  returning * into v_issue;

  return jsonb_build_object(
    'issue_id',     v_issue.id,
    'card_code',    v_card.code,
    'card_note',    v_card.note,
    'product_name', v_product.name,
    'variant_name', v_variant.name,
    'price',        v_issue.price,
    'currency',     'DZD',
    'remaining',    (select count(*) from bot_cards
                      where variant_id = p_variant_id and status = 'available'),
    'pending',      v_pending + 1
  );
end $$;

-- ونفس الشيء عند التأكيد: 022 حرفاً بحرف، بزيادة السعر والمنصة
-- والمدة في المُرجَع — هي ما ستبني عليه المرحلة 2 رابط الوثيقة
-- بلا سؤال إضافي.
create or replace function bot_confirm_issue(p_telegram_id bigint, p_issue_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin   bot_admins;
  v_issue   bot_issues;
  v_variant bot_variants;
  v_product bot_products;
  v_dur     jsonb;
  v_sales   int;
  v_of_kind int;
begin
  v_admin := bot_actor(p_telegram_id);

  select * into v_issue from bot_issues where id = p_issue_id for update;
  if not found then raise exception 'ISSUE_NOT_FOUND'; end if;
  if v_issue.admin_id <> v_admin.id and v_admin.role <> 'owner' then
    raise exception 'NOT_YOUR_ISSUE';
  end if;
  if v_issue.status <> 'pending' then
    raise exception 'ISSUE_ALREADY_SETTLED:%', v_issue.status;
  end if;

  update bot_issues
     set status = 'confirmed', settled_at = now(), settled_by = v_admin.id
   where id = p_issue_id
  returning * into v_issue;

  update bot_cards set status = 'sold', sold_at = now() where id = v_issue.card_id;

  select * into v_variant from bot_variants where id = v_issue.variant_id;
  select * into v_product from bot_products where id = v_variant.product_id;
  v_dur := bot_duration_to_engagement(v_variant.duration_value, v_variant.duration_unit);

  select count(*) into v_sales
    from bot_issues where admin_id = v_issue.admin_id and status = 'confirmed';
  -- وكم باع من هذه المدة تحديداً: الرقم الذي يسأل عنه البائع فعلاً
  select count(*) into v_of_kind
    from bot_issues
   where admin_id = v_issue.admin_id and status = 'confirmed'
     and variant_id = v_issue.variant_id;

  return jsonb_build_object(
    'issue_id', v_issue.id, 'status', 'confirmed',
    'card_code', v_issue.card_code,
    'product_name', v_product.name,
    'variant_name', v_variant.name,
    'customer_ref', v_issue.customer_ref,
    'price',    v_issue.price,
    'currency', 'DZD',
    'platform', v_product.platform,
    'months',   v_dur->'months',
    'days',     v_dur->'days',
    'needs_platform', v_product.platform is null,
    'needs_duration', v_variant.duration_value is null or v_variant.duration_unit is null,
    'seller_sales', v_sales,
    'seller_sales_of_variant', v_of_kind,
    'remaining', (select count(*) from bot_cards
                   where variant_id = v_issue.variant_id and status = 'available')
  );
end $$;

-- ============================================================
-- 9. الصلاحيات — service_role وحده، كما في 021.
-- ============================================================
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like 'bot\_%' or p.proname = 'bot_duration_to_engagement')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
