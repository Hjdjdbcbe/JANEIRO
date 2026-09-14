-- bundle: bot
-- ============================================================
-- Janeiro Store — 030 الكتالوج يُدار من البوت
--
-- المنصات والمدد والأسعار كلها تُضبط اليوم بنداء RPC برقم uuid،
-- أي بلصق SQL في لوحة Supabase. وهذا يناقض ما بُني عليه البوت من
-- أوّله: «لا هجرة ولا نشر — من داخل البوت».
--
-- فهنا أغلفة بالرموز النصّية نفسها التي يعرفها المالك من
-- /addvariant و/addcards: رمز المنتج ورمز المدة. الدوال الأصلية
-- بالـuuid تبقى كما هي — هذه تُترجم إليها لا أكثر.
-- ============================================================

-- ------------------------------------------------------------
-- 1. من رمزين إلى صنف
-- ------------------------------------------------------------
create or replace function bot_variant_by_code(
  p_product_code text, p_variant_code text
) returns bot_variants
language plpgsql stable set search_path = public as $$
declare v_prod bot_products; v_var bot_variants;
begin
  select * into v_prod from bot_products
   where code = lower(btrim(coalesce(p_product_code, '')));
  if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;

  select * into v_var from bot_variants
   where product_id = v_prod.id and code = lower(btrim(coalesce(p_variant_code, '')));
  if not found then raise exception 'VARIANT_NOT_FOUND'; end if;
  return v_var;
end $$;

create or replace function bot_product_by_code(p_product_code text)
returns bot_products
language plpgsql stable set search_path = public as $$
declare v_prod bot_products;
begin
  select * into v_prod from bot_products
   where code = lower(btrim(coalesce(p_product_code, '')));
  if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;
  return v_prod;
end $$;

-- ------------------------------------------------------------
-- 2. المنصات
-- ------------------------------------------------------------
create or replace function bot_cmd_platform(
  p_telegram_id bigint, p_product_code text, p_platform text,
  p_remove boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_prod bot_products;
begin
  perform bot_owner(p_telegram_id);
  v_prod := bot_product_by_code(p_product_code);
  if p_remove then
    return bot_remove_product_platform(p_telegram_id, v_prod.id, p_platform);
  end if;
  return bot_add_product_platform(p_telegram_id, v_prod.id, p_platform);
end $$;

-- ------------------------------------------------------------
-- 3. المدة
-- ------------------------------------------------------------
-- بالعربية كما تُكتب، وبالإنجليزية كما في العمود. من يكتب «شهر»
-- لا يُطالَب بأن يتعلّم 'month'.
create or replace function bot_duration_unit(p_word text)
returns text
language sql immutable set search_path = public as $$
  select case lower(btrim(coalesce(p_word, '')))
    when 'يوم'   then 'day'   when 'أيام'  then 'day'   when 'ايام' then 'day'
    when 'day'   then 'day'   when 'days'  then 'day'
    when 'أسبوع' then 'week'  when 'اسبوع' then 'week'  when 'أسابيع' then 'week'
    when 'اسابيع' then 'week' when 'week'  then 'week'  when 'weeks' then 'week'
    when 'شهر'   then 'month' when 'أشهر'  then 'month' when 'اشهر' then 'month'
    when 'شهور'  then 'month' when 'month' then 'month' when 'months' then 'month'
    when 'سنة'   then 'year'  when 'سنوات' then 'year'  when 'عام'  then 'year'
    when 'year'  then 'year'  when 'years' then 'year'
    else null end;
$$;

create or replace function bot_cmd_duration(
  p_telegram_id bigint, p_product_code text, p_variant_code text,
  p_value int, p_unit text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_var bot_variants; v_unit text;
begin
  perform bot_owner(p_telegram_id);
  v_var := bot_variant_by_code(p_product_code, p_variant_code);

  v_unit := bot_duration_unit(p_unit);
  if v_unit is null then raise exception 'INVALID_UNIT'; end if;

  return bot_set_variant_duration(p_telegram_id, v_var.id, p_value, v_unit);
end $$;

-- ------------------------------------------------------------
-- 4. السعر
-- ------------------------------------------------------------
create or replace function bot_cmd_price(
  p_telegram_id bigint, p_product_code text, p_variant_code text,
  p_market text, p_price numeric
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_var bot_variants;
begin
  perform bot_owner(p_telegram_id);
  v_var := bot_variant_by_code(p_product_code, p_variant_code);
  return bot_set_price(p_telegram_id, v_var.id, p_market, p_price);
end $$;

-- ------------------------------------------------------------
-- 5. الجرد كنصّ جاهز للعرض
-- ------------------------------------------------------------
-- bot_data_audit تعطي البنية كاملة؛ هذه تعطي ما يُقرأ في رسالة
-- تليجرام: سطر لكل صنف، وما ينقصه معلَّماً.
create or replace function bot_catalog_report(p_telegram_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb; v_mk jsonb;
begin
  perform bot_owner(p_telegram_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'code', code, 'name', name, 'currency', currency)
         order by sort_order), '[]'::jsonb)
    into v_mk from bot_markets where is_active;

  select coalesce(jsonb_agg(x.j order by x.so, x.nm), '[]'::jsonb) into v_out
  from (
    select pr.sort_order as so, pr.name as nm,
      jsonb_build_object(
        'code', pr.code,
        'name', pr.name,
        'is_active', pr.is_active,
        'platforms', coalesce((
          select jsonb_agg(pp.platform order by pp.sort_order, pp.platform)
            from bot_product_platforms pp where pp.product_id = pr.id), '[]'::jsonb),
        'variants', coalesce((
          select jsonb_agg(v.j order by v.so, v.nm)
            from (
              select va.sort_order as so, va.name as nm,
                jsonb_build_object(
                  'code', va.code,
                  'name', va.name,
                  'is_active', va.is_active,
                  'value', va.duration_value,
                  'unit',  va.duration_unit,
                  'stock', (select count(*) from bot_cards c
                             where c.variant_id = va.id and c.status = 'available'),
                  'prices', coalesce((
                    select jsonb_object_agg(m.code, pp.price)
                      from bot_markets m
                      join bot_prices pp on pp.variant_id = va.id and pp.market = m.code
                     where m.is_active), '{}'::jsonb)
                ) as j
              from bot_variants va where va.product_id = pr.id
            ) v
        ), '[]'::jsonb)
      ) as j
    from bot_products pr
  ) x;

  return jsonb_build_object(
    'products', v_out,
    'markets',  v_mk,
    'sellers', coalesce((
      select jsonb_agg(jsonb_build_object(
               'telegram_id', a.telegram_id,
               'name', coalesce(a.display_name, a.tg_name, a.telegram_id::text),
               'role', a.role::text, 'market', a.market)
             order by a.role, a.created_at)
        from bot_admins a where a.is_active), '[]'::jsonb)
  );
end $$;

-- ============================================================
-- 6. الصلاحيات — service_role وحده، كما في 021.
-- ============================================================
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

-- ============================================================
-- 7. المدة المخصّصة في الفلو اليدوي
-- ============================================================
-- كانت الحالة تعرف الأشهر وحدها، وأزرارها 1/3/6/12 بلا شهرين
-- وبلا مخصّص. والمدة قد تكون بالأيام (بطاقة 45 يوماً)، فتُحفظ
-- في عمودها لا في أيام الهدية: الهدية شيء والمدة شيء.
alter table bot_wizard_state
  add column if not exists duration_days integer;

do $$ begin
  alter table bot_wizard_state add constraint bot_wizard_days_ok
    check (duration_days is null or duration_days between 1 and 999);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table bot_wizard_state add constraint bot_wizard_duration_one_ok
    check (months is null or duration_days is null);
exception when duplicate_object then null; end $$;

alter table bot_wizard_state drop constraint if exists bot_wizard_state_awaiting_check;
alter table bot_wizard_state add constraint bot_wizard_state_awaiting_check
  check (awaiting in ('platform','months','bonus','preview',
                      'platform_manual','bonus_manual',
                      'months_manual','days_manual'));

create or replace function bot_wizard_set(
  p_telegram_id bigint, p_step text, p_value text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin bot_admins; v_n int; v_name text;
begin
  v_admin := bot_actor(p_telegram_id);
  if not exists (select 1 from bot_wizard_state where admin_id = v_admin.id) then
    raise exception 'WIZARD_NOT_STARTED';
  end if;

  if p_step = 'platform' then
    v_name := btrim(coalesce(p_value, ''));
    if v_name = '' or char_length(v_name) > 60 then raise exception 'INVALID_PLATFORM'; end if;
    update bot_wizard_state set platform = v_name, awaiting = 'months'
     where admin_id = v_admin.id;

  elsif p_step = 'months' then
    v_n := nullif(btrim(coalesce(p_value, '')), '')::int;
    if v_n is null or v_n < 1 or v_n > 60 then raise exception 'INVALID_MONTHS'; end if;
    update bot_wizard_state
       set months = v_n, duration_days = null, awaiting = 'bonus'
     where admin_id = v_admin.id;

  -- المدة بالأيام: تُمسح الأشهر معها، فلا تجتمع وحدتان
  elsif p_step = 'days' then
    v_n := nullif(btrim(coalesce(p_value, '')), '')::int;
    if v_n is null or v_n < 1 or v_n > 999 then raise exception 'INVALID_DAYS'; end if;
    update bot_wizard_state
       set duration_days = v_n, months = null, awaiting = 'bonus'
     where admin_id = v_admin.id;

  elsif p_step = 'bonus' then
    v_n := coalesce(nullif(btrim(coalesce(p_value, '')), '')::int, 0);
    if v_n < 0 or v_n > 90 then raise exception 'INVALID_BONUS'; end if;
    update bot_wizard_state set bonus_days = v_n, awaiting = 'preview'
     where admin_id = v_admin.id;

  -- انتظار إدخال يدوي: المنصة، أو المدة بإحدى وحدتيها، أو الهدية
  elsif p_step in ('platform_manual', 'bonus_manual', 'months_manual', 'days_manual') then
    update bot_wizard_state set awaiting = p_step where admin_id = v_admin.id;

  -- «تعديل»: يعود لخطوة ويمحو ما بعدها، فلا تبقى قيمة معلّقة من
  -- مسار سابق تدخل المعاينة بلا أن يراها الأدمن.
  elsif p_step = 'back_platform' then
    update bot_wizard_state
       set awaiting = 'platform', platform = null, months = null,
           duration_days = null, bonus_days = null
     where admin_id = v_admin.id;
  elsif p_step = 'back_months' then
    update bot_wizard_state
       set awaiting = 'months', months = null, duration_days = null, bonus_days = null
     where admin_id = v_admin.id;
  elsif p_step = 'back_bonus' then
    update bot_wizard_state set bonus_days = null, awaiting = 'bonus'
     where admin_id = v_admin.id;
  else
    raise exception 'UNKNOWN_STEP:%', p_step;
  end if;

  return bot_wizard_preview(p_telegram_id);
end $$;

create or replace function bot_wizard_preview(p_telegram_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_admin bot_admins; v_st bot_wizard_state; v_start timestamptz;
begin
  v_admin := bot_actor(p_telegram_id);
  select * into v_st from bot_wizard_state where admin_id = v_admin.id;
  if not found then raise exception 'WIZARD_NOT_STARTED'; end if;

  v_start := now();
  return jsonb_build_object(
    'platform',      v_st.platform,
    'months',        v_st.months,
    'duration_days', v_st.duration_days,
    'bonus_days',    v_st.bonus_days,
    'awaiting',      v_st.awaiting,
    'ready',         v_st.platform is not null
                     and (v_st.months is not null or v_st.duration_days is not null)
                     and v_st.bonus_days is not null,
    'projected_start', v_start,
    'projected_end',   case
      when v_st.months is null and v_st.duration_days is null then null
      else bot_engagement_expiry(v_start, v_st.months,
                                 coalesce(v_st.bonus_days, 0), v_st.duration_days) end
  );
end $$;

create or replace function bot_engagement_confirm(
  p_telegram_id bigint, p_hours int default 72
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin bot_admins; v_st bot_wizard_state;
  v_cert bot_certificates; v_token text; v_start timestamptz;
begin
  v_admin := bot_actor(p_telegram_id);
  select * into v_st from bot_wizard_state where admin_id = v_admin.id;
  if not found then raise exception 'WIZARD_NOT_STARTED'; end if;
  if v_st.platform is null then raise exception 'PLATFORM_MISSING'; end if;
  if v_st.months is null and v_st.duration_days is null then
    raise exception 'MONTHS_MISSING';
  end if;

  v_start := now();

  insert into bot_certificates
    (code, ref_code, platform, months, duration_days, bonus_days,
     starts_at, ends_at, issued_by, customer, filled_at)
  values
    (bot_engagement_code(), bot_engagement_ref(), v_st.platform,
     v_st.months, v_st.duration_days, coalesce(v_st.bonus_days, 0), v_start,
     bot_engagement_expiry(v_start, v_st.months,
                           coalesce(v_st.bonus_days, 0), v_st.duration_days),
     v_admin.id, '[]'::jsonb, null)
  returning * into v_cert;

  v_token := replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '');

  insert into bot_fill_tokens (token, certificate_id, created_by, expires_at)
  values (v_token, v_cert.id, v_admin.id,
          now() + make_interval(hours => greatest(1, least(coalesce(p_hours, 72), 720))));

  delete from bot_wizard_state where admin_id = v_admin.id;

  return jsonb_build_object(
    'code', v_cert.code, 'ref_code', v_cert.ref_code, 'token', v_token,
    'platform', v_cert.platform, 'months', v_cert.months,
    'duration_days', v_cert.duration_days, 'bonus_days', v_cert.bonus_days,
    'starts_at', v_cert.starts_at, 'ends_at', v_cert.ends_at,
    'expires_at', now() + make_interval(hours => coalesce(p_hours, 72))
  );
end $$;

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
