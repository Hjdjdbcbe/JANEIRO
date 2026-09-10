-- ============================================================
-- Janeiro Store — 023 وثيقة ضمان لكل بيعة من البوت
--
--   البائع يضغط ✅ تأكيد
--     -> البوت يسأله عن بيانات الزبون (يوزر الأنستا، السناب،
--        الاسم، الهاتف — ما تحدّده أنت لكل منتج)
--     -> يردّ عليه بها
--     -> تصدر الوثيقة فوراً: متى بدأ الاشتراك ومتى ينتهي، مع
--        رمز تحقّق، ويرسلها للزبون
--
-- تاريخ الانتهاء يُحسب من مدة المدّة نفسها (سنة، 3 أشهر…)، فلا
-- يكتبه أحد بيده ولا يخطئ فيه.
--
-- لماذا جدول مستقل عن warranty_certificates في 020: ذاك مربوط
-- بـ order_item_id not null — أي بطلب من المتجر. بيعة البوت ليست
-- طلباً، ولا يوجد order_item لتعلّقها به، ومن يركّب البوت وحده لا
-- يملك جدول order_items أصلاً. نفس الفكرة، مصدر مختلف.
-- ============================================================

-- ------------------------------------------------------------
-- 1. المدة تصير رقماً، لا اسماً فقط
-- ------------------------------------------------------------
-- «سنة» و«3 أشهر» كانا نصّين للعرض. بلا قيمة محسوبة لا يمكن
-- معرفة متى ينتهي الاشتراك.
alter table bot_variants
  add column if not exists duration_value integer,
  add column if not exists duration_unit  text;

do $$ begin
  alter table bot_variants add constraint bot_variants_duration_value_ok
    check (duration_value is null or duration_value > 0);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table bot_variants add constraint bot_variants_duration_unit_ok
    check (duration_unit in ('day','week','month','year') or duration_unit is null);
exception when duplicate_object then null; end $$;

-- المدّتان المزروعتان تأخذان مدّتيهما. الشرط `is null` يجعلها
-- تُملأ مرة واحدة ولا تدهس تعديلاً لاحقاً من المالك.
update bot_variants set duration_value = 1, duration_unit = 'year'
 where code = 'year'    and duration_value is null;
update bot_variants set duration_value = 3, duration_unit = 'month'
 where code = '3months' and duration_value is null;

-- ------------------------------------------------------------
-- 2. أي بيانات يُسأل عنها البائع — لكل منتج على حدة
-- ------------------------------------------------------------
-- منتج يُفعَّل بيوزر أنستا، وآخر بيوزر سناب، وثالث يحتاج الاسم
-- والهاتف. تُحرَّر من داخل البوت بلا هجرة.
create table if not exists bot_fields (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid not null references bot_products(id) on delete cascade,
  label       text not null check (char_length(label) between 1 and 60),
  is_required boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  unique (product_id, label),
  -- نفس حارس المتجر: لا نجمع كلمات سر من أحد، أبداً.
  constraint bot_fields_no_password check (
    label !~* '(password|passe|كلمة السر|كلمة المرور|الباسورد)'
  )
);
create index if not exists idx_bot_fields_product on bot_fields(product_id, sort_order);

-- ------------------------------------------------------------
-- 3. الوثيقة
-- ------------------------------------------------------------
create table if not exists bot_certificates (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique check (char_length(code) >= 12),
  issue_id   uuid not null unique references bot_issues(id) on delete restrict,
  -- لقطة: [{label, value}]. تبقى كما كانت يوم البيع ولو أعاد
  -- المالك تسمية الحقول بعدها.
  customer   jsonb not null default '[]'::jsonb,
  starts_at  timestamptz not null default now(),
  ends_at    timestamptz,
  created_at timestamptz not null default now(),
  constraint bot_cert_window_ok check (ends_at is null or ends_at > starts_at)
);
create index if not exists idx_bot_cert_ends on bot_certificates(ends_at);
create index if not exists idx_bot_cert_customer on bot_certificates using gin (customer);

alter table bot_fields       enable row level security;
alter table bot_certificates enable row level security;
revoke all on bot_fields, bot_certificates from anon, authenticated;

-- ------------------------------------------------------------
-- 4. رمز الوثيقة
-- ------------------------------------------------------------
-- gen_random_uuid() لا gen_random_bytes(): الثانية تحتاج pgcrypto،
-- وعلى Supabase المستضاف تسكن schema اسمه extensions لا يراه
-- search_path = public. هذا بالضبط ما أوقع get_certificate سابقاً.
create or replace function bot_certificate_code()
returns text language plpgsql volatile set search_path = public as $$
declare candidate text;
begin
  for attempt in 1..20 loop
    candidate := 'JNR-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 14));
    if not exists (select 1 from bot_certificates where code = candidate) then
      return candidate;
    end if;
  end loop;
  raise exception 'CERTIFICATE_CODE_GENERATION_FAILED';
end $$;

-- ------------------------------------------------------------
-- 5. ماذا يُسأل عنه البائع بعد التأكيد
-- ------------------------------------------------------------
create or replace function bot_issue_fields(p_telegram_id bigint, p_issue_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_admin bot_admins; v_issue bot_issues;
  v_variant bot_variants; v_product bot_products;
begin
  v_admin := bot_actor(p_telegram_id);
  select * into v_issue from bot_issues where id = p_issue_id;
  if not found then raise exception 'ISSUE_NOT_FOUND'; end if;
  if v_issue.admin_id <> v_admin.id and v_admin.role <> 'owner' then
    raise exception 'NOT_YOUR_ISSUE';
  end if;

  select * into v_variant from bot_variants where id = v_issue.variant_id;
  select * into v_product from bot_products where id = v_variant.product_id;

  return jsonb_build_object(
    'issue_id',     v_issue.id,
    'status',       v_issue.status::text,
    'product_name', v_product.name,
    'variant_name', v_variant.name,
    'has_certificate', exists (select 1 from bot_certificates where issue_id = p_issue_id),
    'duration_value', v_variant.duration_value,
    'duration_unit',  v_variant.duration_unit,
    'fields', coalesce((
      select jsonb_agg(jsonb_build_object(
               'label', f.label, 'is_required', f.is_required) order by f.sort_order, f.label)
        from bot_fields f where f.product_id = v_product.id
    ), '[]'::jsonb)
  );
end $$;

-- ------------------------------------------------------------
-- 6. إصدار الوثيقة
-- ------------------------------------------------------------
-- تُنادى بعد التأكيد ببيانات الزبون. تُصدر مرة واحدة لكل عملية:
-- المفتاح الفريد على issue_id هو ما يضمنها، لا فحص سبَقَها.
create or replace function bot_issue_certificate(
  p_telegram_id bigint,
  p_issue_id    uuid,
  p_values      jsonb default '[]'::jsonb   -- [{"label":..,"value":..}, …]
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin   bot_admins;
  v_issue   bot_issues;
  v_variant bot_variants;
  v_product bot_products;
  v_seller  bot_admins;
  v_cert    bot_certificates;
  v_ends    timestamptz;
  v_clean   jsonb := '[]'::jsonb;
  v_row     jsonb;
  v_label   text;
  v_value   text;
  v_missing text;
begin
  v_admin := bot_actor(p_telegram_id);

  select * into v_issue from bot_issues where id = p_issue_id for update;
  if not found then raise exception 'ISSUE_NOT_FOUND'; end if;
  if v_issue.admin_id <> v_admin.id and v_admin.role <> 'owner' then
    raise exception 'NOT_YOUR_ISSUE';
  end if;
  -- الوثيقة تشهد ببيعة تمّت. عملية معلّقة أو ملغاة ليست بيعة.
  if v_issue.status <> 'confirmed' then
    raise exception 'ISSUE_NOT_CONFIRMED:%', v_issue.status;
  end if;

  select * into v_cert from bot_certificates where issue_id = p_issue_id;
  if found then raise exception 'CERTIFICATE_EXISTS:%', v_cert.code; end if;

  select * into v_variant from bot_variants where id = v_issue.variant_id;
  select * into v_product from bot_products where id = v_variant.product_id;
  select * into v_seller  from bot_admins   where id = v_issue.admin_id;

  -- ---- تنظيف القيم الواردة والتحقق من المطلوب ----
  for v_row in select * from jsonb_array_elements(coalesce(p_values, '[]'::jsonb)) loop
    v_label := btrim(coalesce(v_row->>'label', ''));
    v_value := btrim(coalesce(v_row->>'value', ''));
    continue when v_label = '' or v_value = '';
    if char_length(v_value) > 200 then raise exception 'FIELD_TOO_LONG:%', v_label; end if;
    v_clean := v_clean || jsonb_build_array(
      jsonb_build_object('label', v_label, 'value', v_value));
  end loop;

  -- حقل مطلوب بلا قيمة يوقف الإصدار: وثيقة بلا صاحب لا تُثبت شيئاً
  select f.label into v_missing
    from bot_fields f
   where f.product_id = v_product.id and f.is_required
     and not exists (
       select 1 from jsonb_array_elements(v_clean) e where e->>'label' = f.label)
   order by f.sort_order, f.label
   limit 1;
  if v_missing is not null then raise exception 'FIELD_REQUIRED:%', v_missing; end if;

  -- ---- نهاية الاشتراك، محسوبة من المدة نفسها ----
  v_ends := case v_variant.duration_unit
    when 'day'   then now() + make_interval(days   => v_variant.duration_value)
    when 'week'  then now() + make_interval(weeks  => v_variant.duration_value)
    when 'month' then now() + make_interval(months => v_variant.duration_value)
    when 'year'  then now() + make_interval(years  => v_variant.duration_value)
    else null end;

  insert into bot_certificates (code, issue_id, customer, starts_at, ends_at)
  values (bot_certificate_code(), p_issue_id, v_clean, now(), v_ends)
  returning * into v_cert;

  return jsonb_build_object(
    'code', v_cert.code,
    'issue_id', v_issue.id,
    'product_name', v_product.name,
    'variant_name', v_variant.name,
    'card_code', v_issue.card_code,
    'seller', coalesce(v_seller.display_name, v_seller.tg_name,
                       v_seller.username, v_seller.telegram_id::text),
    'customer', v_cert.customer,
    'starts_at', v_cert.starts_at,
    'ends_at', v_cert.ends_at,
    'days_left', case when v_cert.ends_at is null then null
                      else greatest(0, (date_part('day', v_cert.ends_at - now()))::int) end
  );
end $$;

-- ------------------------------------------------------------
-- 7. قراءة وثيقة بالرمز
-- ------------------------------------------------------------
create or replace function bot_certificate(p_telegram_id bigint, p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_admin bot_admins; v_cert bot_certificates; v_issue bot_issues;
  v_variant bot_variants; v_product bot_products; v_seller bot_admins;
begin
  v_admin := bot_actor(p_telegram_id);
  if p_code is null or char_length(btrim(p_code)) < 8 then
    raise exception 'CERTIFICATE_NOT_FOUND';
  end if;

  select * into v_cert from bot_certificates where code = upper(btrim(p_code));
  if not found then raise exception 'CERTIFICATE_NOT_FOUND'; end if;

  select * into v_issue   from bot_issues   where id = v_cert.issue_id;
  select * into v_variant from bot_variants where id = v_issue.variant_id;
  select * into v_product from bot_products where id = v_variant.product_id;
  select * into v_seller  from bot_admins   where id = v_issue.admin_id;

  -- البائع يرى وثائقه، والمالك يرى الكل.
  if v_issue.admin_id <> v_admin.id and v_admin.role <> 'owner' then
    raise exception 'NOT_YOUR_ISSUE';
  end if;

  return jsonb_build_object(
    'code', v_cert.code,
    'product_name', v_product.name,
    'variant_name', v_variant.name,
    'card_code', v_issue.card_code,
    'seller', coalesce(v_seller.display_name, v_seller.tg_name,
                       v_seller.username, v_seller.telegram_id::text),
    'customer', v_cert.customer,
    'starts_at', v_cert.starts_at,
    'ends_at', v_cert.ends_at,
    'expired', v_cert.ends_at is not null and v_cert.ends_at <= now(),
    'days_left', case when v_cert.ends_at is null then null
                      else greatest(0, (date_part('day', v_cert.ends_at - now()))::int) end,
    'issued_at', v_cert.created_at
  );
end $$;

-- ------------------------------------------------------------
-- 8. تحرير حقول الزبون — للمالك
-- ------------------------------------------------------------
create or replace function bot_add_field(
  p_telegram_id bigint, p_product_code text, p_label text,
  p_required boolean default true
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_prod bot_products; v_next int; v_id uuid;
begin
  perform bot_owner(p_telegram_id);
  p_label := btrim(coalesce(p_label, ''));
  if p_label = '' or char_length(p_label) > 60 then raise exception 'INVALID_LABEL'; end if;

  select * into v_prod from bot_products
   where code = lower(btrim(coalesce(p_product_code, '')));
  if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;
  if exists (select 1 from bot_fields where product_id = v_prod.id and label = p_label) then
    raise exception 'FIELD_EXISTS';
  end if;

  select coalesce(max(sort_order), 0) + 10 into v_next
    from bot_fields where product_id = v_prod.id;
  insert into bot_fields (product_id, label, is_required, sort_order)
  values (v_prod.id, p_label, coalesce(p_required, true), v_next)
  returning id into v_id;

  return jsonb_build_object('field_id', v_id, 'product', v_prod.name, 'label', p_label);
end $$;

create or replace function bot_remove_field(
  p_telegram_id bigint, p_product_code text, p_label text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_prod bot_products; v_n int;
begin
  perform bot_owner(p_telegram_id);
  select * into v_prod from bot_products
   where code = lower(btrim(coalesce(p_product_code, '')));
  if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;

  delete from bot_fields
   where product_id = v_prod.id and label = btrim(coalesce(p_label, ''));
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'FIELD_NOT_FOUND'; end if;
  -- الوثائق الصادرة لا تتأثر: قيمها لقطة داخل bot_certificates.customer
  return jsonb_build_object('removed', p_label, 'product', v_prod.name);
end $$;

create or replace function bot_fields_of(p_telegram_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  perform bot_actor(p_telegram_id);
  select coalesce(jsonb_agg(jsonb_build_object(
           'product_code', p.code, 'product', p.name,
           'fields', coalesce((
             select jsonb_agg(jsonb_build_object('label', f.label, 'is_required', f.is_required)
                              order by f.sort_order, f.label)
               from bot_fields f where f.product_id = p.id), '[]'::jsonb)
         ) order by p.sort_order, p.name), '[]'::jsonb) into v_out
    from bot_products p;
  return v_out;
end $$;

-- ------------------------------------------------------------
-- 9. البحث عن زبون، والاشتراكات المقاربة على الانتهاء
-- ------------------------------------------------------------
-- «هذا الزبون، متى ينتهي اشتراكه؟» — يُبحث في أي حقل، فلا يهم
-- أكان يوزر أنستا أم سناب أم رقم هاتف.
create or replace function bot_find_customer(p_telegram_id bigint, p_query text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_admin bot_admins; v_q text; v_out jsonb;
begin
  v_admin := bot_actor(p_telegram_id);
  v_q := btrim(coalesce(p_query, ''));
  if char_length(v_q) < 2 then raise exception 'QUERY_TOO_SHORT'; end if;

  select coalesce(jsonb_agg(r.row order by r.created_at desc), '[]'::jsonb) into v_out
  from (
    select c.created_at,
      jsonb_build_object(
        'code', c.code,
        'product_name', pr.name,
        'variant_name', va.name,
        'customer', c.customer,
        'starts_at', c.starts_at,
        'ends_at', c.ends_at,
        'expired', c.ends_at is not null and c.ends_at <= now(),
        'seller', coalesce(a.display_name, a.tg_name, a.username, a.telegram_id::text)
      ) as row
      from bot_certificates c
      join bot_issues   i  on i.id = c.issue_id
      join bot_variants va on va.id = i.variant_id
      join bot_products pr on pr.id = va.product_id
      join bot_admins   a  on a.id = i.admin_id
     where (v_admin.role = 'owner' or i.admin_id = v_admin.id)
       and (c.code = upper(v_q)
            or exists (select 1 from jsonb_array_elements(c.customer) e
                        where e->>'value' ilike '%' || v_q || '%'))
     order by c.created_at desc
     limit 20
  ) r;

  return v_out;
end $$;

-- من ينتهي اشتراكه قريباً — فرصة تجديد لا تُنسى.
create or replace function bot_expiring(p_telegram_id bigint, p_days int default 7)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_admin bot_admins; v_out jsonb;
begin
  v_admin := bot_actor(p_telegram_id);
  p_days := greatest(1, least(coalesce(p_days, 7), 90));

  select coalesce(jsonb_agg(r.row order by r.ends_at), '[]'::jsonb) into v_out
  from (
    select c.ends_at,
      jsonb_build_object(
        'code', c.code,
        'product_name', pr.name,
        'variant_name', va.name,
        'customer', c.customer,
        'ends_at', c.ends_at,
        'days_left', greatest(0, (date_part('day', c.ends_at - now()))::int),
        'seller', coalesce(a.display_name, a.tg_name, a.username, a.telegram_id::text)
      ) as row
      from bot_certificates c
      join bot_issues   i  on i.id = c.issue_id
      join bot_variants va on va.id = i.variant_id
      join bot_products pr on pr.id = va.product_id
      join bot_admins   a  on a.id = i.admin_id
     where c.ends_at is not null
       and c.ends_at > now()
       and c.ends_at <= now() + make_interval(days => p_days)
       and (v_admin.role = 'owner' or i.admin_id = v_admin.id)
     order by c.ends_at
     limit 50
  ) r;

  return v_out;
end $$;

-- ------------------------------------------------------------
-- 10. الصلاحيات — service_role وحده، كما في 021.
-- ------------------------------------------------------------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like 'bot\_%'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
