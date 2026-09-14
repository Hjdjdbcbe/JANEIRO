-- bundle: bot
-- ============================================================
-- Janeiro Store — 028 البطاقة الواحدة تعمل على منصات عدّة
--
-- تصحيح لـ026/027. كان bot_products.platform عموداً واحداً:
-- منتج = منصة. والواقع أن البطاقة الواحدة قد تُفعَّل على أكثر من
-- منصة، وتُزاد لها منصات جديدة مع الوقت. فالمنصة ليست خاصية
-- للمنتج بل قائمة مربوطة به، والبائع يختار منها عند البيع.
--
-- والاختيار يُلقَّط على البيعة: الوثيقة تقول للزبون منصةً بعينها،
-- فلا بدّ أن تكون منصة هذه البيعة لا قائمةَ ما يحتمله المنتج.
--
-- ونفس قاعدة 027: واحدة في القائمة = لا سؤال. وهذا يبقي البوت
-- الحيّ يخدم كما هو، فالبطاقات الحالية على Snapchat Plus وحدها.
--
-- ولا يُرفَع خطأ إن غابت المنصة: البيع لا يحتاجها، الوثيقة هي
-- التي تحتاجها. فتُطلب عند إصدار الوثيقة لا عند تسليم البطاقة.
-- ============================================================

-- ------------------------------------------------------------
-- 1. منصات المنتج
-- ------------------------------------------------------------
create table if not exists bot_product_platforms (
  product_id uuid not null references bot_products(id) on delete cascade,
  platform   text not null references bot_platforms(name)
                  on update cascade on delete cascade,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  primary key (product_id, platform)
);
create index if not exists idx_bot_pp_platform on bot_product_platforms(platform);

alter table bot_product_platforms enable row level security;
revoke all on bot_product_platforms from anon, authenticated;

-- نقل ما كُتب في عمود 027 ثم إسقاطه: عمود يحمل واحدة وجدول
-- يحمل البقية يجعل السؤال «أين منصات هذا المنتج؟» بجوابين.
do $$ begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'bot_products'
                and column_name = 'platform') then
    execute $q$
      insert into bot_product_platforms (product_id, platform)
        select id, platform from bot_products where platform is not null
      on conflict (product_id, platform) do nothing
    $q$;
    execute 'alter table bot_products drop column platform';
  end if;
end $$;

-- ------------------------------------------------------------
-- 2. اللقطة على البيعة
-- ------------------------------------------------------------
alter table bot_issues
  add column if not exists platform text;

do $$ begin
  alter table bot_issues add constraint bot_issues_platform_fk
    foreign key (platform) references bot_platforms(name) on update cascade;
exception when duplicate_object then null; end $$;

create index if not exists idx_bot_issues_platform on bot_issues(platform);

-- ------------------------------------------------------------
-- 3. أي منصة لهذه البيعة
-- ------------------------------------------------------------
-- ما اختير صراحةً ← الوحيدة إن كانت وحيدة ← وإلّا NULL.
--
-- NULL لا خطأ: تسليم البطاقة لا يتوقّف على المنصة. من يحتاجها
-- هو إصدار الوثيقة، وهناك تُطلب. ولو رُفع خطأ هنا لتوقّف البيع
-- في البوت الحيّ لحظةَ يُضاف لمنتجٍ منصةٌ ثانية.
create or replace function bot_resolve_platform(p_product_id uuid, p_platform text)
returns text
language plpgsql stable set search_path = public as $$
declare v text; v_n int;
begin
  v := nullif(btrim(coalesce(p_platform, '')), '');
  if v is not null then
    if not exists (select 1 from bot_product_platforms
                    where product_id = p_product_id and platform = v) then
      raise exception 'PLATFORM_NOT_FOR_PRODUCT';
    end if;
    return v;
  end if;

  select count(*) into v_n from bot_product_platforms where product_id = p_product_id;
  if v_n = 1 then
    select platform into v from bot_product_platforms where product_id = p_product_id;
    return v;
  end if;

  return null;
end $$;

create or replace function bot_product_platforms_list(
  p_telegram_id bigint, p_product_id uuid
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  perform bot_actor(p_telegram_id);
  select coalesce(jsonb_agg(pp.platform order by pp.sort_order, pp.platform), '[]'::jsonb)
    into v_out
    from bot_product_platforms pp
    join bot_platforms pl on pl.name = pp.platform
   where pp.product_id = p_product_id and pl.is_active;
  return v_out;
end $$;

-- ------------------------------------------------------------
-- 4. إضافة منصة لمنتج وحذفها
-- ------------------------------------------------------------
-- واسم غير موجود في قائمة المنصات يُضاف إليها بدل أن يُرفض:
-- المالك يعرف بضاعته، والقائمة للتوحيد لا للمنع.
create or replace function bot_add_product_platform(
  p_telegram_id bigint, p_product_id uuid, p_platform text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_prod bot_products; v_name text; v_next int;
begin
  perform bot_owner(p_telegram_id);
  v_name := btrim(coalesce(p_platform, ''));
  if v_name = '' or char_length(v_name) > 60 then raise exception 'INVALID_PLATFORM'; end if;

  select * into v_prod from bot_products where id = p_product_id;
  if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;

  if not exists (select 1 from bot_platforms where name = v_name) then
    select coalesce(max(sort_order), 0) + 10 into v_next from bot_platforms;
    insert into bot_platforms (name, sort_order) values (v_name, v_next)
      on conflict (name) do nothing;
  else
    update bot_platforms set is_active = true where name = v_name and not is_active;
  end if;

  select coalesce(max(sort_order), 0) + 10 into v_next
    from bot_product_platforms where product_id = p_product_id;
  insert into bot_product_platforms (product_id, platform, sort_order)
  values (p_product_id, v_name, v_next)
  on conflict (product_id, platform) do nothing;

  return jsonb_build_object(
    'product', v_prod.name, 'platform', v_name,
    'platforms', bot_product_platforms_list(p_telegram_id, p_product_id)
  );
end $$;

-- الحذف من المنتج لا من القائمة العامة، والبيعات السابقة تحمل
-- اسم منصتها نصّاً فلا تتأثّر.
create or replace function bot_remove_product_platform(
  p_telegram_id bigint, p_product_id uuid, p_platform text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_prod bot_products; v_n int;
begin
  perform bot_owner(p_telegram_id);

  select * into v_prod from bot_products where id = p_product_id;
  if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;

  delete from bot_product_platforms
   where product_id = p_product_id
     and platform = btrim(coalesce(p_platform, ''));
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'PLATFORM_NOT_FOR_PRODUCT'; end if;

  return jsonb_build_object(
    'product', v_prod.name,
    'platforms', bot_product_platforms_list(p_telegram_id, p_product_id)
  );
end $$;

-- نسخة 027 تبقى تعمل بمعنى «اجعل منصاته هذه وحدها»: من نادى بها
-- من قبل لا ينكسر أمره، ومن ينادي بها الآن يفهم منها ما تفعله.
create or replace function bot_set_product_platform(
  p_telegram_id bigint, p_product_id uuid, p_platform text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_prod bot_products; v_name text;
begin
  perform bot_owner(p_telegram_id);
  v_name := btrim(coalesce(p_platform, ''));

  select * into v_prod from bot_products where id = p_product_id;
  if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;

  delete from bot_product_platforms where product_id = p_product_id;
  if v_name = '' then
    return jsonb_build_object('product', v_prod.name, 'platforms', '[]'::jsonb);
  end if;

  return bot_add_product_platform(p_telegram_id, p_product_id, v_name);
end $$;

-- ------------------------------------------------------------
-- 5. الحجز يلقّط المنصة
-- ------------------------------------------------------------
drop function if exists bot_request_card(bigint, uuid, text, text);

create or replace function bot_request_card(
  p_telegram_id bigint,
  p_variant_id  uuid,
  p_customer_ref text default null,
  p_market text default null,
  p_platform text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin   bot_admins;
  v_variant bot_variants;
  v_product bot_products;
  v_card    bot_cards;
  v_issue   bot_issues;
  v_mk      bot_markets;
  v_plat    text;
  v_price   numeric;
  v_pending int;
  v_limit   int;
begin
  v_admin := bot_actor(p_telegram_id);

  select * into v_variant from bot_variants where id = p_variant_id;
  if not found or not v_variant.is_active then raise exception 'VARIANT_NOT_FOUND'; end if;

  select * into v_product from bot_products where id = v_variant.product_id;
  if not v_product.is_active then raise exception 'VARIANT_NOT_FOUND'; end if;

  -- السوق والمنصة قبل البطاقة: خطأ بعد الحجز يترك بطاقة محجوزة
  -- لبيعة لم تبدأ.
  select * into v_mk from bot_markets
   where code = bot_resolve_market(v_admin, p_market);
  v_plat := bot_resolve_platform(v_product.id, p_platform);

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

  select price into v_price from bot_prices
   where variant_id = p_variant_id and market = v_mk.code;

  insert into bot_issues (card_id, variant_id, admin_id, card_code, customer_ref,
                          price, market, currency, platform)
  values (v_card.id, p_variant_id, v_admin.id, v_card.code,
          nullif(btrim(coalesce(p_customer_ref,'')), ''),
          v_price, v_mk.code, v_mk.currency, v_plat)
  returning * into v_issue;

  return jsonb_build_object(
    'issue_id',     v_issue.id,
    'card_code',    v_card.code,
    'card_note',    v_card.note,
    'product_name', v_product.name,
    'variant_name', v_variant.name,
    'platform',     v_plat,
    'platforms',    bot_product_platforms_list(p_telegram_id, v_product.id),
    'price',        v_issue.price,
    'market',       v_mk.code,
    'market_name',  v_mk.name,
    'currency',     v_mk.currency,
    'decimals',     v_mk.decimals,
    'remaining',    (select count(*) from bot_cards
                      where variant_id = p_variant_id and status = 'available'),
    'pending',      v_pending + 1
  );
end $$;

-- تثبيت منصة بيعة بعد تسليمها: البائع سُئل عند إصدار الوثيقة لا
-- عند التسليم، فهنا يُسجَّل جوابه. ولا تُبدَّل منصة بيعة صدرت
-- وثيقتها: الوثيقة في يد الزبون تقول شيئاً، والسجل يجب أن يقوله.
create or replace function bot_issue_set_platform(
  p_telegram_id bigint, p_issue_id uuid, p_platform text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin bot_admins; v_issue bot_issues; v_variant bot_variants; v_name text;
begin
  v_admin := bot_actor(p_telegram_id);
  v_name := btrim(coalesce(p_platform, ''));

  select * into v_issue from bot_issues where id = p_issue_id for update;
  if not found then raise exception 'ISSUE_NOT_FOUND'; end if;
  if v_issue.admin_id <> v_admin.id and v_admin.role <> 'owner' then
    raise exception 'NOT_YOUR_ISSUE';
  end if;
  if exists (select 1 from bot_certificates where issue_id = p_issue_id) then
    raise exception 'CERTIFICATE_EXISTS';
  end if;

  select * into v_variant from bot_variants where id = v_issue.variant_id;
  if not exists (select 1 from bot_product_platforms
                  where product_id = v_variant.product_id and platform = v_name) then
    raise exception 'PLATFORM_NOT_FOR_PRODUCT';
  end if;

  update bot_issues set platform = v_name where id = p_issue_id;
  return jsonb_build_object('issue_id', p_issue_id, 'platform', v_name);
end $$;

-- ------------------------------------------------------------
-- 6. التأكيد يرجّع منصة البيعة
-- ------------------------------------------------------------
create or replace function bot_confirm_issue(p_telegram_id bigint, p_issue_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin   bot_admins;
  v_issue   bot_issues;
  v_variant bot_variants;
  v_product bot_products;
  v_dur     jsonb;
  v_plats   jsonb;
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
  v_dur   := bot_duration_to_engagement(v_variant.duration_value, v_variant.duration_unit);
  v_plats := bot_product_platforms_list(p_telegram_id, v_product.id);

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
    'market',   v_issue.market,
    'market_name', (select name from bot_markets where code = v_issue.market),
    'currency', v_issue.currency,
    'platform',  v_issue.platform,
    'platforms', v_plats,
    'months',   v_dur->'months',
    'days',     v_dur->'days',
    -- ما ينقص الوثيقة: منصة لهذه البيعة، ومدة للصنف
    'needs_platform', v_issue.platform is null,
    'needs_duration', v_variant.duration_value is null or v_variant.duration_unit is null,
    'seller_sales', v_sales,
    'seller_sales_of_variant', v_of_kind,
    'remaining', (select count(*) from bot_cards
                   where variant_id = v_issue.variant_id and status = 'available')
  );
end $$;

-- ------------------------------------------------------------
-- 7. الصنف والجرد
-- ------------------------------------------------------------
create or replace function bot_variant_subject(p_variant_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_variant bot_variants;
  v_product bot_products;
  v_dur     jsonb;
  v_prices  jsonb;
  v_plats   jsonb;
begin
  select * into v_variant from bot_variants where id = p_variant_id;
  if not found then raise exception 'VARIANT_NOT_FOUND'; end if;
  select * into v_product from bot_products where id = v_variant.product_id;

  v_dur := bot_duration_to_engagement(v_variant.duration_value, v_variant.duration_unit);

  select coalesce(jsonb_agg(pp.platform order by pp.sort_order, pp.platform), '[]'::jsonb)
    into v_plats from bot_product_platforms pp where pp.product_id = v_product.id;

  select coalesce(jsonb_object_agg(m.code, jsonb_build_object(
           'price', pp.price, 'currency', m.currency, 'name', m.name
         )), '{}'::jsonb)
    into v_prices
    from bot_markets m
    left join bot_prices pp on pp.variant_id = p_variant_id and pp.market = m.code
   where m.is_active;

  return jsonb_build_object(
    'variant_id',   v_variant.id,
    'variant_name', v_variant.name,
    'product_id',   v_product.id,
    'product_name', v_product.name,
    'platforms',    v_plats,
    'months',       v_dur->'months',
    'days',         v_dur->'days',
    'prices',       v_prices,
    'needs_platform', jsonb_array_length(v_plats) = 0,
    'needs_duration', v_variant.duration_value is null or v_variant.duration_unit is null
  );
end $$;

create or replace function bot_data_audit(p_telegram_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_rows jsonb; v_admins jsonb; v_np int; v_nd int; v_nr int;
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
        'platforms', coalesce((
          select jsonb_agg(pp.platform order by pp.sort_order, pp.platform)
            from bot_product_platforms pp where pp.product_id = pr.id), '[]'::jsonb),
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
                  'prices', coalesce((
                    select jsonb_object_agg(m.code, pp.price)
                      from bot_markets m
                      join bot_prices pp
                        on pp.variant_id = va.id and pp.market = m.code
                     where m.is_active), '{}'::jsonb)
                ) as j
              from bot_variants va where va.product_id = pr.id
            ) v
        ), '[]'::jsonb)
      ) as j
    from bot_products pr
  ) x;

  -- ومن يبيع في أي صفحة. الفارغ هنا يعني «في الاثنتين، ويُسأل».
  select coalesce(jsonb_agg(jsonb_build_object(
           'telegram_id', a.telegram_id,
           'name', coalesce(a.display_name, a.tg_name),
           'role', a.role::text,
           'market', a.market
         ) order by a.role, a.created_at), '[]'::jsonb)
    into v_admins from bot_admins a where a.is_active;

  select count(*) into v_np from bot_products pr
   where not exists (select 1 from bot_product_platforms pp where pp.product_id = pr.id);
  select count(*) into v_nd from bot_variants
   where duration_value is null or duration_unit is null;
  select count(*) into v_nr from bot_variants va
   where exists (select 1 from bot_markets m where m.is_active
                  and not exists (select 1 from bot_prices pp
                                   where pp.variant_id = va.id and pp.market = m.code));

  return jsonb_build_object(
    'products', v_rows,
    'admins',   v_admins,
    'markets',  (select coalesce(jsonb_agg(jsonb_build_object(
                          'code', code, 'name', name, 'currency', currency)
                        order by sort_order), '[]'::jsonb)
                   from bot_markets where is_active),
    'missing_platform', v_np,
    'missing_duration', v_nd,
    'missing_price',    v_nr
  );
end $$;

-- ============================================================
-- 8. الصلاحيات — service_role وحده، كما في 021.
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
