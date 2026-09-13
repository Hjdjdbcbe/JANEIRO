-- bundle: bot
-- ============================================================
-- Janeiro Store — 027 صفحتان بعملتين
--
-- تصحيح لـ026. بُني السعر هناك على فرضية «متجر واحد بعملة
-- واحدة»: عمود سعر واحد على الصنف، والعملة دج مكتوبة في الكود.
-- والواقع صفحتان — جزائرية بالدينار الجزائري وأردنية بالدينار
-- الأردني — لنفس البضاعة ونفس المخزون.
--
-- ثلاثة أشياء تنكسر بذلك، وهذه الهجرة تصلحها:
--
--  1. سعر واحد لا يكفي صفحتين. الأسعار تنتقل إلى جدول مفتاحه
--     (الصنف، السوق).
--  2. العملة ليست ثابتة، فلا تُكتب في الكود. تُقرأ من السوق
--     وتُلقَّط على البيعة مع السعر.
--  3. الدينار الأردني ثلاث خانات عشرية (1.750 د.أ) والجزائري
--     خانتان. numeric(10,2) يقصّ الفلس الأردني صمتاً. توسيع
--     إلى numeric(12,3)، وعدد الخانات خاصية للسوق لا للكود.
--
-- والقاعدة التي تحكم التقارير لاحقاً: مبلغان بعملتين مختلفتين
-- لا يُجمعان. أبداً. لا بمتوسّط ولا بـ«تقريباً».
-- ============================================================

-- ------------------------------------------------------------
-- 1. الأسواق
-- ------------------------------------------------------------
create table if not exists bot_markets (
  code       text primary key check (code ~ '^[a-z]{2,8}$'),
  name       text not null unique check (char_length(name) between 1 and 40),
  currency   text not null check (char_length(currency) between 1 and 8),
  -- خانات العرض: دج خانتان، د.أ ثلاث. للعرض وللتقريب عند الحفظ.
  decimals   smallint not null default 2 check (decimals between 0 and 3),
  is_active  boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

-- الأردنية تُزرع معطّلة عمداً. البوت يخدم اليوم، وكل بيعة فيه
-- جزائرية فعلاً، ولا أزرار اختيار صفحة فيه بعد. سوقان نشطان
-- الآن يعني إمّا أن يقف البيع (يُسأل بلا زرّ يُضغط) وإمّا أن
-- يُخمَّن السوق. فتبقى معطّلة: سوق نشط واحد = صفر أسئلة وصفر
-- تغيير في السلوك الحالي. تُفعَّل بـbot_set_market_active يوم
-- تصير أزرارها جاهزة.
insert into bot_markets (code, name, currency, decimals, is_active, sort_order) values
  ('dz', 'الجزائر', 'دج',   2, true,  10),
  ('jo', 'الأردن',  'د.أ',  3, false, 20)
on conflict (code) do nothing;

alter table bot_markets enable row level security;
revoke all on bot_markets from anon, authenticated;

-- ------------------------------------------------------------
-- 2. الأدمن وصفحته
-- ------------------------------------------------------------
-- بائع الصفحة الأردنية لا يُسأل عن السوق أبداً: سوقه معروف.
-- والمالك يخدم الصفحتين، فسوقه يبقى فارغاً ويُسأل بضغطة واحدة
-- عند البيع. الفراغ هنا ليس نقصاً يُعمَّر، بل «هذا يبيع في
-- الاثنتين».
alter table bot_admins
  add column if not exists market text;

do $$ begin
  alter table bot_admins add constraint bot_admins_market_fk
    foreign key (market) references bot_markets(code)
    on update cascade on delete set null;
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------
-- 3. الأسعار: صفّ لكل (صنف، سوق)
-- ------------------------------------------------------------
create table if not exists bot_prices (
  variant_id uuid not null references bot_variants(id) on delete cascade,
  market     text not null references bot_markets(code) on update cascade on delete cascade,
  price      numeric(12,3) not null check (price >= 0 and price < 1000000000),
  updated_at timestamptz not null default now(),
  primary key (variant_id, market)
);
create index if not exists idx_bot_prices_market on bot_prices(market);

alter table bot_prices enable row level security;
revoke all on bot_prices from anon, authenticated;

drop trigger if exists trg_bot_prices_updated on bot_prices;
create trigger trg_bot_prices_updated before update on bot_prices
  for each row execute function set_updated_at();

-- نقل ما قد يكون كُتب في عمود 026 قبل هذا التصحيح. عملة المتجر
-- في store_settings هي دج، فالسوق الجزائري هو وجهته الطبيعية.
-- ثم يسقط العمود: عمود سعر بلا سوق صار يعني شيئين، والغموض في
-- سعر أسوأ من غيابه.
-- داخل DO لأن الاستعلام يذكر عموداً سيسقط بعد سطر منه: تشغيل
-- 027 وحدها مرتين يجعل الإشارة إليه خطأ تحليلٍ لا خطأ تنفيذ،
-- فلا يكفي «if exists».
do $$ begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'bot_variants'
                and column_name = 'price') then
    execute $q$
      insert into bot_prices (variant_id, market, price)
        select id, 'dz', price from bot_variants where price is not null
      on conflict (variant_id, market) do nothing
    $q$;
    execute 'alter table bot_variants drop column price';
  end if;
end $$;

-- ------------------------------------------------------------
-- 4. اللقطة على البيعة
-- ------------------------------------------------------------
-- السوق والعملة يُلقَّطان مع السعر. العملة خصوصاً: لو بدّل
-- المالك عملة سوق يوماً، البيعات القديمة تبقى تقول بأي عملة
-- بِيعت فعلاً.
alter table bot_issues
  add column if not exists market   text,
  add column if not exists currency text;

do $$ begin
  alter table bot_issues add constraint bot_issues_market_fk
    foreign key (market) references bot_markets(code) on update cascade;
exception when duplicate_object then null; end $$;

-- توسيع الخانات العشرية: الفلس الأردني كان يُقصّ صمتاً.
alter table bot_issues alter column price type numeric(12,3);
alter table bot_issues drop constraint if exists bot_issues_price_ok;
alter table bot_issues add constraint bot_issues_price_ok
  check (price is null or (price >= 0 and price < 1000000000));

create index if not exists idx_bot_issues_market on bot_issues(market);

-- ------------------------------------------------------------
-- 5. قراءة الأسواق
-- ------------------------------------------------------------
create or replace function bot_markets_list(p_telegram_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  perform bot_actor(p_telegram_id);
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', code, 'name', name, 'currency', currency,
           'decimals', decimals, 'is_active', is_active
         ) order by sort_order, name), '[]'::jsonb)
    into v_out from bot_markets where is_active;
  return v_out;
end $$;

-- السوق الذي تنتمي إليه بيعة هذا الأدمن، بلا أن يُسأل إن أمكن:
--   ما اختاره صراحةً  →  سوقه المربوط  →  السوق الوحيد إن كان
--   واحداً  →  وإلّا يُسأل.
-- لا تخمين: سوقان نشطان وأدمن غير مربوط = سؤال، لا افتراض.
create or replace function bot_resolve_market(p_admin bot_admins, p_market text)
returns text
language plpgsql stable set search_path = public as $$
declare v text; v_n int;
begin
  v := nullif(btrim(coalesce(p_market, '')), '');
  if v is not null then
    if not exists (select 1 from bot_markets where code = v and is_active) then
      raise exception 'MARKET_NOT_FOUND';
    end if;
    return v;
  end if;

  if p_admin.market is not null
     and exists (select 1 from bot_markets where code = p_admin.market and is_active) then
    return p_admin.market;
  end if;

  select count(*) into v_n from bot_markets where is_active;
  if v_n = 1 then
    select code into v from bot_markets where is_active;
    return v;
  end if;

  raise exception 'MARKET_REQUIRED';
end $$;

create or replace function bot_set_market_active(
  p_telegram_id bigint, p_market text, p_active boolean
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_mk bot_markets; v_n int;
begin
  perform bot_owner(p_telegram_id);

  select * into v_mk from bot_markets
   where code = nullif(btrim(coalesce(p_market, '')), '');
  if not found then raise exception 'MARKET_NOT_FOUND'; end if;

  -- لا تُطفأ آخر صفحة: بلا سوق نشط لا يُباع شيء.
  if not p_active then
    select count(*) into v_n from bot_markets where is_active and code <> v_mk.code;
    if v_n = 0 then raise exception 'LAST_MARKET'; end if;
  end if;

  update bot_markets set is_active = p_active where code = v_mk.code;

  return jsonb_build_object(
    'code', v_mk.code, 'name', v_mk.name,
    'currency', v_mk.currency, 'is_active', p_active
  );
end $$;

create or replace function bot_set_admin_market(
  p_telegram_id bigint, p_target_telegram_id bigint, p_market text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_t bot_admins; v_m text;
begin
  perform bot_owner(p_telegram_id);
  v_m := nullif(btrim(coalesce(p_market, '')), '');

  select * into v_t from bot_admins where telegram_id = p_target_telegram_id;
  if not found then raise exception 'ADMIN_NOT_FOUND'; end if;

  if v_m is not null
     and not exists (select 1 from bot_markets where code = v_m and is_active) then
    raise exception 'MARKET_NOT_FOUND';
  end if;

  update bot_admins set market = v_m where id = v_t.id;

  return jsonb_build_object(
    'telegram_id', v_t.telegram_id,
    'name', coalesce(v_t.display_name, v_t.tg_name),
    'market', v_m,
    'market_name', (select name from bot_markets where code = v_m)
  );
end $$;

-- ------------------------------------------------------------
-- 6. التسعير — للمالك وحده، في كل شيء
-- ------------------------------------------------------------
-- نسخة 026 ثلاثية الوسائط (بلا سوق) تسقط: إبقاؤها يجعل
-- bot_set_price(x, y, 100) تعني «في أي سوق؟» ولا جواب.
drop function if exists bot_set_price(bigint, uuid, numeric);

create or replace function bot_set_price(
  p_telegram_id bigint, p_variant_id uuid, p_market text, p_price numeric
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_var bot_variants; v_prod bot_products; v_mk bot_markets; v_p numeric;
begin
  perform bot_owner(p_telegram_id);

  select * into v_var from bot_variants where id = p_variant_id;
  if not found then raise exception 'VARIANT_NOT_FOUND'; end if;
  select * into v_prod from bot_products where id = v_var.product_id;

  select * into v_mk from bot_markets
   where code = nullif(btrim(coalesce(p_market, '')), '');
  if not found then raise exception 'MARKET_NOT_FOUND'; end if;

  -- NULL يمسح السعر في هذا السوق وحده، ولا يمسّ السوق الآخر.
  if p_price is null then
    delete from bot_prices where variant_id = p_variant_id and market = v_mk.code;
    return jsonb_build_object(
      'product', v_prod.name, 'variant', v_var.name,
      'market', v_mk.code, 'market_name', v_mk.name,
      'price', null, 'currency', v_mk.currency
    );
  end if;

  if p_price < 0 or p_price >= 1000000000 then raise exception 'INVALID_PRICE'; end if;
  v_p := round(p_price, v_mk.decimals);

  insert into bot_prices (variant_id, market, price)
  values (p_variant_id, v_mk.code, v_p)
  on conflict (variant_id, market) do update set price = excluded.price;

  return jsonb_build_object(
    'product', v_prod.name, 'variant', v_var.name,
    'market', v_mk.code, 'market_name', v_mk.name,
    'price', v_p, 'currency', v_mk.currency, 'decimals', v_mk.decimals
  );
end $$;

-- تصحيح سعر بيعة بعينها: للمالك وحده كذلك. البائع يبيع
-- بالسعر المحدَّد ولا يمسّه — وهذا ما طُلب صراحةً.
create or replace function bot_issue_set_price(
  p_telegram_id bigint, p_issue_id uuid, p_price numeric
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_issue bot_issues; v_mk bot_markets; v_p numeric;
begin
  perform bot_owner(p_telegram_id);

  select * into v_issue from bot_issues where id = p_issue_id for update;
  if not found then raise exception 'ISSUE_NOT_FOUND'; end if;
  if v_issue.status = 'cancelled' then raise exception 'ISSUE_CANCELLED'; end if;

  select * into v_mk from bot_markets where code = v_issue.market;

  if p_price is not null then
    if p_price < 0 or p_price >= 1000000000 then raise exception 'INVALID_PRICE'; end if;
    v_p := round(p_price, coalesce(v_mk.decimals, 2));
  end if;

  update bot_issues set price = v_p where id = p_issue_id;

  return jsonb_build_object(
    'issue_id', p_issue_id, 'price', v_p,
    'market', v_issue.market, 'currency', v_issue.currency
  );
end $$;

-- ------------------------------------------------------------
-- 7. ما تحتاجه الوثيقة والبيعة من الصنف
-- ------------------------------------------------------------
create or replace function bot_variant_subject(p_variant_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_variant bot_variants;
  v_product bot_products;
  v_dur     jsonb;
  v_prices  jsonb;
begin
  select * into v_variant from bot_variants where id = p_variant_id;
  if not found then raise exception 'VARIANT_NOT_FOUND'; end if;
  select * into v_product from bot_products where id = v_variant.product_id;

  v_dur := bot_duration_to_engagement(v_variant.duration_value, v_variant.duration_unit);

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
    'platform',     v_product.platform,
    'months',       v_dur->'months',
    'days',         v_dur->'days',
    'prices',       v_prices,
    'needs_platform', v_product.platform is null,
    'needs_duration', v_variant.duration_value is null or v_variant.duration_unit is null
  );
end $$;

-- ------------------------------------------------------------
-- 8. الحجز: السوق ثم السعر
-- ------------------------------------------------------------
-- النسخة ثلاثية الوسائط (021 و026) تسقط، ولا تبقى إلى جانب
-- الرباعية: النداء بوسيطين يصير غامضاً بينهما فيفشل.
drop function if exists bot_request_card(bigint, uuid, text);

create or replace function bot_request_card(
  p_telegram_id bigint,
  p_variant_id  uuid,
  p_customer_ref text default null,
  p_market text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin   bot_admins;
  v_variant bot_variants;
  v_product bot_products;
  v_card    bot_cards;
  v_issue   bot_issues;
  v_mk      bot_markets;
  v_price   numeric;
  v_pending int;
  v_limit   int;
begin
  v_admin := bot_actor(p_telegram_id);

  select * into v_variant from bot_variants where id = p_variant_id;
  if not found or not v_variant.is_active then raise exception 'VARIANT_NOT_FOUND'; end if;

  select * into v_product from bot_products where id = v_variant.product_id;
  if not v_product.is_active then raise exception 'VARIANT_NOT_FOUND'; end if;

  -- السوق قبل البطاقة: لو رُفع MARKET_REQUIRED بعد الحجز لبقيت
  -- بطاقة محجوزة لبيعة لم تبدأ.
  select * into v_mk from bot_markets
   where code = bot_resolve_market(v_admin, p_market);

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
                          price, market, currency)
  values (v_card.id, p_variant_id, v_admin.id, v_card.code,
          nullif(btrim(coalesce(p_customer_ref,'')), ''),
          v_price, v_mk.code, v_mk.currency)
  returning * into v_issue;

  return jsonb_build_object(
    'issue_id',     v_issue.id,
    'card_code',    v_card.code,
    'card_note',    v_card.note,
    'product_name', v_product.name,
    'variant_name', v_variant.name,
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
    'market',   v_issue.market,
    'market_name', (select name from bot_markets where code = v_issue.market),
    'currency', v_issue.currency,
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

-- ------------------------------------------------------------
-- 9. الجرد — بسعر لكل صفحة
-- ------------------------------------------------------------
create or replace function bot_data_audit(p_telegram_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_rows jsonb; v_admins jsonb; v_np int; v_nd int; v_nr int; v_mk int;
begin
  perform bot_owner(p_telegram_id);

  select count(*) into v_mk from bot_markets where is_active;

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

  select count(*) into v_np from bot_products where platform is null;
  select count(*) into v_nd from bot_variants
   where duration_value is null or duration_unit is null;
  -- ناقص السعر = صنف فعّال ينقصه سعر في سوق فعّال واحد على الأقل
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
-- 10. الصلاحيات — service_role وحده، كما في 021.
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
