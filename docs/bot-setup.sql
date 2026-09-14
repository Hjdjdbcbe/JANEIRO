-- ============================================================
-- Janeiro — بوت المخزون وحده. وُلِّد آلياً، لا تُعدّله يدوياً.
-- المصدر: supabase/migrations/001_core_schema.sql + supabase/migrations/021_gift_card_bot.sql supabase/migrations/022_bot_sales_detail.sql supabase/migrations/023_bot_certificates.sql supabase/migrations/024_bot_customer_form.sql supabase/migrations/025_service_engagement.sql supabase/migrations/026_bot_order_data.sql supabase/migrations/027_bot_markets.sql supabase/migrations/028_bot_product_platforms.sql supabase/migrations/029_engagement_from_issue.sql supabase/migrations/030_bot_catalog_commands.sql supabase/migrations/031_bot_terms.sql supabase/migrations/032_instagram_required.sql supabase/migrations/033_claim_fields.sql
--
-- الصقه كاملاً في Supabase → SQL Editor واضغط Run، مرة واحدة.
-- آمن على مشروع فيه المتجر أصلاً: لا ينشئ ما هو موجود.
-- ============================================================

-- ── ما يحتاجه البوت من 001_core_schema.sql ────────────────
create extension if not exists "pgcrypto";

-- ---------- shared updated_at trigger ----------
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- ---------- store settings (key/value) ----------
-- is_public = false keeps a setting readable by admins only.
create table if not exists store_settings (
  key        text primary key,
  value      text,
  is_public  boolean not null default true,
  updated_at timestamptz not null default now()
);
drop trigger if exists trg_settings_updated on store_settings;
create trigger trg_settings_updated before update on store_settings
  for each row execute function set_updated_at();

-- ── 021_gift_card_bot.sql ─────────────────────────────────────
-- bundle: bot
-- ============================================================
-- Janeiro Store — 021 بوت تليجرام للمخزون (Gift-card stock bot)
--
-- بوت خاص بالأدمن، منفصل تماماً عن متجر الزبائن:
--
--   الأدمن يطلب بطاقة (سنة / 3 أشهر / أي مدة تضيفها)
--     -> البوت يحجز بطاقة واحدة من المخزون ويعرض كودها
--     -> «تأكيد»  = تمّت العملية، البطاقة تصبح مباعة وتُحسب له
--     -> «إلغاء»  = فشلت العملية، البطاقة ترجع للمخزون كما كانت
--
-- المنتجات قابلة للزيادة: bot_products / bot_variants جدولان
-- عاديّان، تضيف فيهما ما شئت من البوت نفسه بلا هجرة جديدة.
--
-- لا شيء هنا مكشوف للمتصفح: كل الجداول RLS بلا أي policy، أي
-- لا anon ولا authenticated يقرأها. المنفذ الوحيد هو الدوال
-- أدناه، ولا تُنفَّذ إلا بمفتاح service_role من داخل الـEdge
-- Function — والهوية فيها هي telegram_id لا جلسة Supabase.
-- ============================================================

-- ---------- enums ----------
do $$ begin
  create type bot_admin_role as enum ('owner','admin');
exception when duplicate_object then null; end $$;

do $$ begin
  -- available -> reserved -> sold        (تأكيد)
  -- available -> reserved -> available   (إلغاء)
  create type bot_card_status as enum ('available','reserved','sold','disabled');
exception when duplicate_object then null; end $$;

do $$ begin
  create type bot_issue_status as enum ('pending','confirmed','cancelled');
exception when duplicate_object then null; end $$;

-- ---------- الأدمن ----------
-- telegram_id هو الهوية. لا كلمات سر: من ليس في هذا الجدول لا
-- يرى شيئاً مهما راسل البوت.
create table if not exists bot_admins (
  id           uuid primary key default gen_random_uuid(),
  telegram_id  bigint not null unique,
  -- الاسم الذي يسمّيه به المالك عند إضافته. لا يُلمس بعدها.
  display_name text check (char_length(display_name) <= 120),
  -- ما يقوله تليجرام عنه، يُحدَّث مع كل رسالة. منفصل عن الأعلى
  -- عمداً: لولا ذلك لمحا اسمُه في تليجرام التسميةَ التي اختارها
  -- المالك أول مرة.
  username     text check (char_length(username) <= 64),
  tg_name      text check (char_length(tg_name) <= 120),
  role         bot_admin_role not null default 'admin',
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
drop trigger if exists trg_bot_admins_updated on bot_admins;
create trigger trg_bot_admins_updated before update on bot_admins
  for each row execute function set_updated_at();

-- ---------- المنتجات ووحداتها ----------
create table if not exists bot_products (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique check (code ~ '^[a-z0-9][a-z0-9_-]{0,31}$'),
  name       text not null check (char_length(name) between 1 and 80),
  is_active  boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists trg_bot_products_updated on bot_products;
create trigger trg_bot_products_updated before update on bot_products
  for each row execute function set_updated_at();

-- المدة: «سنة»، «3 أشهر»، أو أي شيء آخر. لا قيمة مُرمَّزة في الكود.
create table if not exists bot_variants (
  id         uuid primary key default gen_random_uuid(),
  product_id uuid not null references bot_products(id) on delete cascade,
  code       text not null check (code ~ '^[a-z0-9][a-z0-9_-]{0,31}$'),
  name       text not null check (char_length(name) between 1 and 80),
  is_active  boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (product_id, code)
);
create index if not exists idx_bot_variants_product on bot_variants(product_id, is_active, sort_order);
drop trigger if exists trg_bot_variants_updated on bot_variants;
create trigger trg_bot_variants_updated before update on bot_variants
  for each row execute function set_updated_at();

-- ---------- المخزون ----------
create table if not exists bot_cards (
  id         uuid primary key default gen_random_uuid(),
  -- ترتيب الطابور. ليس created_at: كل بطاقات دفعة واحدة تُدرَج
  -- في معاملة واحدة فتحمل now() نفسه بالضبط، فيصير «الأقدم
  -- أولاً» ترتيباً عشوائياً بحسب الـuuid. المتسلسلة تزيد صفاً
  -- صفاً فتصمد داخل الدفعة الواحدة.
  seq        bigserial not null,
  variant_id uuid not null references bot_variants(id) on delete restrict,
  code       text not null check (char_length(code) between 1 and 500),
  status     bot_card_status not null default 'available',
  added_by   uuid references bot_admins(id) on delete set null,
  note       text check (char_length(note) <= 300),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  sold_at    timestamptz,
  unique (variant_id, code)
);
-- الطابور: أقدم بطاقة أولاً، وفهرس جزئي حتى يبقى البحث عن
-- «أول متاحة» رخيصاً مهما كبر عدد المباعة.
create index if not exists idx_bot_cards_available
  on bot_cards(variant_id, seq) where status = 'available';
create index if not exists idx_bot_cards_status on bot_cards(status);
drop trigger if exists trg_bot_cards_updated on bot_cards;
create trigger trg_bot_cards_updated before update on bot_cards
  for each row execute function set_updated_at();

-- ---------- العمليات ----------
-- سجل كامل: كل طلب بطاقة يترك صفاً، سواء نجح أو فشل. عدّاد
-- مبيعات الأدمن يُحسب من هنا، فلا عدّاد يمكن أن يختلف عن الواقع.
create table if not exists bot_issues (
  id           uuid primary key default gen_random_uuid(),
  card_id      uuid not null references bot_cards(id) on delete restrict,
  variant_id   uuid not null references bot_variants(id) on delete restrict,
  admin_id     uuid not null references bot_admins(id) on delete restrict,
  status       bot_issue_status not null default 'pending',
  card_code    text not null,          -- لقطة: تبقى ولو حُذفت البطاقة لاحقاً
  customer_ref text check (char_length(customer_ref) <= 120),
  requested_at timestamptz not null default now(),
  settled_at   timestamptz,
  settled_by   uuid references bot_admins(id) on delete set null,
  constraint settled_shape_ok check (
    (status = 'pending' and settled_at is null) or
    (status <> 'pending' and settled_at is not null)
  )
);
create index if not exists idx_bot_issues_admin  on bot_issues(admin_id, status, requested_at desc);
create index if not exists idx_bot_issues_status on bot_issues(status, requested_at);
-- بطاقة واحدة لا يمكن أن تكون معلّقة في عمليتين في آن واحد.
create unique index if not exists uq_bot_issue_pending_card
  on bot_issues(card_id) where status = 'pending';

-- ---------- RLS: مغلق بالكامل ----------
-- لا policy على الإطلاق = لا anon ولا authenticated يمر. الوصول
-- الوحيد هو service_role (bypassrls) من داخل الـEdge Function.
alter table bot_admins   enable row level security;
alter table bot_products enable row level security;
alter table bot_variants enable row level security;
alter table bot_cards    enable row level security;
alter table bot_issues   enable row level security;

revoke all on bot_admins, bot_products, bot_variants, bot_cards, bot_issues
  from anon, authenticated;

-- ---------- إعدادات ----------
-- الحد الأقصى للعمليات المعلّقة لأدمن واحد في آن واحد: يمنع
-- استنزاف المخزون بطلبات لا يُبتّ فيها، ويبقى قابلاً للتعديل من
-- لوحة الإعدادات نفسها بلا هجرة جديدة.
insert into store_settings (key, value, is_public)
values ('bot_pending_limit', '5', false)
on conflict (key) do nothing;

-- ============================================================
-- الدوال. كلها SECURITY DEFINER لأن الجداول أعلاه مغلقة، وكلها
-- تبدأ بالتحقق من telegram_id — الهوية الوحيدة في هذا البوت.
-- ============================================================

-- ---------- من المتحدث؟ ----------
create or replace function bot_actor(p_telegram_id bigint)
returns bot_admins
language plpgsql stable security definer set search_path = public as $$
declare v bot_admins;
begin
  select * into v from bot_admins where telegram_id = p_telegram_id;
  if not found or not v.is_active then
    raise exception 'NOT_AUTHORIZED';
  end if;
  return v;
end $$;

-- يُنادى عند كل رسالة: يحدّث الاسم/المعرّف ويقول من هو المتحدث.
-- لا يرفع خطأ للمجهول — الـEdge Function هي من تقرر ماذا تردّ عليه.
create or replace function bot_identify(
  p_telegram_id bigint,
  p_username    text default null,
  p_name        text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v bot_admins;
begin
  update bot_admins
     set username = coalesce(nullif(p_username,''), username),
         tg_name  = coalesce(nullif(p_name,''), tg_name)
   where telegram_id = p_telegram_id
  returning * into v;

  if not found then
    return jsonb_build_object('known', false, 'active', false, 'role', null);
  end if;

  return jsonb_build_object(
    'known', true, 'active', v.is_active, 'role', v.role::text,
    'admin_id', v.id, 'name', coalesce(v.display_name, v.tg_name, v.username, v.telegram_id::text)
  );
end $$;

-- المالك الأول: يأتي من متغيّر البيئة TELEGRAM_OWNER_ID، فهو
-- الطريق الوحيد لفتح البوت أول مرة على قاعدة فارغة.
create or replace function bot_bootstrap_owner(
  p_telegram_id bigint,
  p_username    text default null,
  p_name        text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v bot_admins;
begin
  insert into bot_admins (telegram_id, username, tg_name, role, is_active)
  values (p_telegram_id, nullif(p_username,''), nullif(p_name,''), 'owner', true)
  on conflict (telegram_id) do update
    set role      = 'owner',
        is_active = true,
        username = coalesce(nullif(excluded.username,''), bot_admins.username),
        tg_name  = coalesce(nullif(excluded.tg_name,''),  bot_admins.tg_name)
  returning * into v;
  return jsonb_build_object('admin_id', v.id, 'role', v.role::text);
end $$;


-- ---------- القائمة والمخزون ----------
-- منتجات + مدد + كم بطاقة متاحة في كل مدة. هذه هي شاشة البيع،
-- وهي أيضاً تقرير المخزون: مصدر واحد للاثنين حتى لا يفترقا.
create or replace function bot_catalog(p_telegram_id bigint, p_only_active boolean default true)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  perform bot_actor(p_telegram_id);

  select coalesce(jsonb_agg(s.p order by s.so, s.nm), '[]'::jsonb) into v_out
  from (
    select pr.sort_order as so, pr.name as nm,
      jsonb_build_object(
        'product_id', pr.id,
        'code',       pr.code,
        'name',       pr.name,
        'is_active',  pr.is_active,
        'variants', coalesce((
          select jsonb_agg(vs.v order by vs.so, vs.nm)
            from (
              select va.sort_order as so, va.name as nm,
                jsonb_build_object(
                  'variant_id', va.id,
                  'code',       va.code,
                  'name',       va.name,
                  'is_active',  va.is_active,
                  'available',  count(*) filter (where c.status = 'available'),
                  'reserved',   count(*) filter (where c.status = 'reserved'),
                  'sold',       count(*) filter (where c.status = 'sold')
                ) as v
              from bot_variants va
              left join bot_cards c on c.variant_id = va.id
              where va.product_id = pr.id
                and (not p_only_active or va.is_active)
              group by va.id
            ) vs
        ), '[]'::jsonb)
      ) as p
    from bot_products pr
    where not p_only_active or pr.is_active
  ) s;

  return v_out;
end $$;

-- ============================================================
-- قلب البوت: طلب بطاقة، ثم تأكيد أو إلغاء.
-- ============================================================

-- ---------- 1. طلب بطاقة ----------
-- يحجز بطاقة واحدة ويعيد كودها. `for update skip locked` هو ما
-- يجعل أدمنين يضغطان «سنة» في نفس اللحظة يأخذان بطاقتين
-- مختلفتين لا بطاقة واحدة مرتين — بلا انتظار أحدهما للآخر.
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

  insert into bot_issues (card_id, variant_id, admin_id, card_code, customer_ref)
  values (v_card.id, p_variant_id, v_admin.id, v_card.code,
          nullif(btrim(coalesce(p_customer_ref,'')), ''))
  returning * into v_issue;

  return jsonb_build_object(
    'issue_id',     v_issue.id,
    'card_code',    v_card.code,
    'card_note',    v_card.note,
    'product_name', v_product.name,
    'variant_name', v_variant.name,
    'remaining',    (select count(*) from bot_cards
                      where variant_id = p_variant_id and status = 'available'),
    'pending',      v_pending + 1
  );
end $$;

-- ---------- 2. تأكيد ----------
-- نجحت العملية: البطاقة تصير مباعة نهائياً وتُحسب لصاحب الطلب.
create or replace function bot_confirm_issue(p_telegram_id bigint, p_issue_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin bot_admins;
  v_issue bot_issues;
  v_sales int;
begin
  v_admin := bot_actor(p_telegram_id);

  -- القفل قبل القراءة: ضغطتان متزامنتان على «تأكيد» لا تُنتجان
  -- تأكيدين، الثانية تجد الحالة قد تغيّرت.
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
   where id = p_issue_id;

  update bot_cards set status = 'sold', sold_at = now() where id = v_issue.card_id;

  select count(*) into v_sales
    from bot_issues where admin_id = v_issue.admin_id and status = 'confirmed';

  return jsonb_build_object(
    'issue_id', v_issue.id, 'status', 'confirmed',
    'card_code', v_issue.card_code,
    'seller_sales', v_sales,
    'remaining', (select count(*) from bot_cards
                   where variant_id = v_issue.variant_id and status = 'available')
  );
end $$;

-- ---------- 3. إلغاء ----------
-- فشلت العملية: البطاقة ترجع إلى المخزون كما كانت، ويبقى الصف
-- في السجل ملغياً — لا يُحذف، حتى يبقى أثر من طلبها ومتى.
create or replace function bot_cancel_issue(p_telegram_id bigint, p_issue_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin bot_admins;
  v_issue bot_issues;
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
     set status = 'cancelled', settled_at = now(), settled_by = v_admin.id
   where id = p_issue_id;

  -- ترجع «متاحة» فقط إن كانت لا تزال محجوزة لهذه العملية.
  update bot_cards set status = 'available'
   where id = v_issue.card_id and status = 'reserved';

  return jsonb_build_object(
    'issue_id', v_issue.id, 'status', 'cancelled',
    'card_code', v_issue.card_code,
    'remaining', (select count(*) from bot_cards
                   where variant_id = v_issue.variant_id and status = 'available')
  );
end $$;

-- ---------- العمليات المعلّقة ----------
-- المالك يرى الجميع؛ الأدمن يرى طلباته وحده.
create or replace function bot_pending(p_telegram_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_admin bot_admins; v_out jsonb;
begin
  v_admin := bot_actor(p_telegram_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'issue_id', i.id,
           'card_code', i.card_code,
           'product_name', pr.name,
           'variant_name', va.name,
           'customer_ref', i.customer_ref,
           'requested_at', i.requested_at,
           'seller', coalesce(a.display_name, a.tg_name, a.username, a.telegram_id::text),
           'mine', i.admin_id = v_admin.id
         ) order by i.requested_at), '[]'::jsonb) into v_out
    from bot_issues i
    join bot_variants va on va.id = i.variant_id
    join bot_products pr on pr.id = va.product_id
    join bot_admins   a  on a.id  = i.admin_id
   where i.status = 'pending'
     and (v_admin.role = 'owner' or i.admin_id = v_admin.id);

  return v_out;
end $$;

-- ============================================================
-- عدّاد المبيعات
-- كل رقم هنا محسوب من bot_issues مباشرة، لا عمود عدّاد يُزاد
-- يدوياً — فلا يمكن أن يقول العدّاد شيئاً والسجل شيئاً آخر.
-- ============================================================
create or replace function bot_stats(p_telegram_id bigint, p_scope text default 'me')
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_admin bot_admins; v_out jsonb;
begin
  v_admin := bot_actor(p_telegram_id);
  if p_scope = 'all' and v_admin.role <> 'owner' then raise exception 'NOT_OWNER'; end if;

  select coalesce(jsonb_agg(s.row order by s.confirmed desc, s.name), '[]'::jsonb) into v_out
  from (
    select
      coalesce(a.display_name, a.tg_name, a.username, a.telegram_id::text) as name,
      count(*) filter (where i.status = 'confirmed') as confirmed,
      jsonb_build_object(
        'admin_id',    a.id,
        'telegram_id', a.telegram_id,
        'name',        coalesce(a.display_name, a.tg_name, a.username, a.telegram_id::text),
        'role',        a.role::text,
        'is_active',   a.is_active,
        'confirmed',   count(*) filter (where i.status = 'confirmed'),
        'cancelled',   count(*) filter (where i.status = 'cancelled'),
        'pending',     count(*) filter (where i.status = 'pending'),
        'today',       count(*) filter (where i.status = 'confirmed'
                                          and i.settled_at >= date_trunc('day', now())),
        'this_month',  count(*) filter (where i.status = 'confirmed'
                                          and i.settled_at >= date_trunc('month', now()))
      ) as row
    from bot_admins a
    left join bot_issues i on i.admin_id = a.id
    where p_scope = 'all' or a.id = v_admin.id
    group by a.id
  ) s;

  return v_out;
end $$;

-- تفصيل المبيعات حسب المنتج/المدة — للمالك.
create or replace function bot_sales_breakdown(p_telegram_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_admin bot_admins; v_out jsonb;
begin
  v_admin := bot_actor(p_telegram_id);
  if v_admin.role <> 'owner' then raise exception 'NOT_OWNER'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'product_name', pr.name,
           'variant_name', va.name,
           'confirmed', count(*) filter (where i.status = 'confirmed'),
           'cancelled', count(*) filter (where i.status = 'cancelled')
         ) order by pr.sort_order, pr.name, va.sort_order, va.name), '[]'::jsonb) into v_out
    from bot_variants va
    join bot_products pr on pr.id = va.product_id
    left join bot_issues i on i.variant_id = va.id
   group by pr.id, pr.name, pr.sort_order, va.id, va.name, va.sort_order;

  return v_out;
end $$;

-- ============================================================
-- إدارة المخزون والمنتجات — للمالك وحده.
-- ============================================================

create or replace function bot_owner(p_telegram_id bigint)
returns bot_admins
language plpgsql stable security definer set search_path = public as $$
declare v bot_admins;
begin
  v := bot_actor(p_telegram_id);
  if v.role <> 'owner' then raise exception 'NOT_OWNER'; end if;
  return v;
end $$;

-- إضافة أكواد دفعة واحدة. المكرّر داخل نفس المدة يُتجاهل بهدوء
-- ويُعدّ، فلصق نفس القائمة مرتين لا يضاعف المخزون.
create or replace function bot_add_cards(
  p_telegram_id bigint,
  p_variant_id  uuid,
  p_codes       text[],
  p_note        text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin bot_admins;
  v_added int := 0;
  v_seen  int := 0;
  v_code  text;
begin
  v_admin := bot_owner(p_telegram_id);

  if not exists (select 1 from bot_variants where id = p_variant_id) then
    raise exception 'VARIANT_NOT_FOUND';
  end if;

  foreach v_code in array coalesce(p_codes, array[]::text[]) loop
    v_code := btrim(v_code);
    continue when v_code = '';
    v_seen := v_seen + 1;
    insert into bot_cards (variant_id, code, added_by, note)
    values (p_variant_id, v_code, v_admin.id, nullif(btrim(coalesce(p_note,'')),''))
    on conflict (variant_id, code) do nothing;
    if found then v_added := v_added + 1; end if;
  end loop;

  if v_seen = 0 then raise exception 'NO_CODES'; end if;

  return jsonb_build_object(
    'added', v_added,
    'duplicates', v_seen - v_added,
    'available', (select count(*) from bot_cards
                   where variant_id = p_variant_id and status = 'available')
  );
end $$;

-- منتج جديد (نتفليكس، شاهد، أي شيء) — لا هجرة، من البوت مباشرة.
create or replace function bot_add_product(p_telegram_id bigint, p_code text, p_name text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_next int;
begin
  perform bot_owner(p_telegram_id);
  p_code := lower(btrim(coalesce(p_code,'')));
  p_name := btrim(coalesce(p_name,''));
  if p_code !~ '^[a-z0-9][a-z0-9_-]{0,31}$' then raise exception 'INVALID_CODE'; end if;
  if p_name = '' then raise exception 'INVALID_NAME'; end if;
  if exists (select 1 from bot_products where code = p_code) then raise exception 'PRODUCT_EXISTS'; end if;

  select coalesce(max(sort_order), 0) + 10 into v_next from bot_products;
  insert into bot_products (code, name, sort_order) values (p_code, p_name, v_next)
  returning id into v_id;
  return jsonb_build_object('product_id', v_id, 'code', p_code, 'name', p_name);
end $$;

-- مدة جديدة داخل منتج (6 أشهر، شهر، مدى الحياة…).
create or replace function bot_add_variant(
  p_telegram_id bigint, p_product_code text, p_code text, p_name text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_prod bot_products; v_id uuid; v_next int;
begin
  perform bot_owner(p_telegram_id);
  p_code := lower(btrim(coalesce(p_code,'')));
  p_name := btrim(coalesce(p_name,''));
  if p_code !~ '^[a-z0-9][a-z0-9_-]{0,31}$' then raise exception 'INVALID_CODE'; end if;
  if p_name = '' then raise exception 'INVALID_NAME'; end if;

  select * into v_prod from bot_products where code = lower(btrim(coalesce(p_product_code,'')));
  if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;
  if exists (select 1 from bot_variants where product_id = v_prod.id and code = p_code) then
    raise exception 'VARIANT_EXISTS';
  end if;

  select coalesce(max(sort_order), 0) + 10 into v_next
    from bot_variants where product_id = v_prod.id;
  insert into bot_variants (product_id, code, name, sort_order)
  values (v_prod.id, p_code, p_name, v_next) returning id into v_id;

  return jsonb_build_object('variant_id', v_id, 'product', v_prod.name, 'name', p_name);
end $$;

-- إخفاء/إظهار منتج أو مدة بلا حذف — البطاقات وسجل المبيعات تبقى.
create or replace function bot_set_active(
  p_telegram_id bigint, p_kind text, p_id uuid, p_active boolean
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  perform bot_owner(p_telegram_id);
  if p_kind = 'product' then
    update bot_products set is_active = p_active where id = p_id;
  elsif p_kind = 'variant' then
    update bot_variants set is_active = p_active where id = p_id;
  else
    raise exception 'INVALID_KIND';
  end if;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'NOT_FOUND'; end if;
  return jsonb_build_object('kind', p_kind, 'id', p_id, 'is_active', p_active);
end $$;

-- ============================================================
-- إدارة الأدمن — للمالك وحده.
-- ============================================================
create or replace function bot_add_admin(
  p_telegram_id bigint, p_new_telegram_id bigint, p_name text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v bot_admins;
begin
  perform bot_owner(p_telegram_id);
  if p_new_telegram_id is null or p_new_telegram_id <= 0 then raise exception 'INVALID_TELEGRAM_ID'; end if;

  insert into bot_admins (telegram_id, display_name, role, is_active)
  values (p_new_telegram_id, nullif(btrim(coalesce(p_name,'')),''), 'admin', true)
  on conflict (telegram_id) do update
    set is_active    = true,
        display_name = coalesce(nullif(btrim(coalesce(p_name,'')),''), bot_admins.display_name)
  returning * into v;

  return jsonb_build_object('admin_id', v.id, 'telegram_id', v.telegram_id, 'role', v.role::text);
end $$;

-- تعطيل لا حذف: مبيعاته السابقة تبقى منسوبة إليه.
create or replace function bot_remove_admin(p_telegram_id bigint, p_target_telegram_id bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me bot_admins; v_t bot_admins;
begin
  v_me := bot_owner(p_telegram_id);
  select * into v_t from bot_admins where telegram_id = p_target_telegram_id;
  if not found then raise exception 'ADMIN_NOT_FOUND'; end if;
  if v_t.id = v_me.id then raise exception 'CANNOT_REMOVE_SELF'; end if;
  if v_t.role = 'owner' then raise exception 'CANNOT_REMOVE_OWNER'; end if;

  update bot_admins set is_active = false where id = v_t.id;

  -- طلباته المعلّقة تُلغى وبطاقاتها ترجع للمخزون، وإلا بقيت محجوزة
  -- عند شخص لم يعد يملك الدخول أصلاً.
  update bot_cards set status = 'available'
   where status = 'reserved'
     and id in (select card_id from bot_issues where admin_id = v_t.id and status = 'pending');
  update bot_issues set status = 'cancelled', settled_at = now(), settled_by = v_me.id
   where admin_id = v_t.id and status = 'pending';

  return jsonb_build_object('telegram_id', v_t.telegram_id, 'is_active', false);
end $$;

create or replace function bot_list_admins(p_telegram_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  perform bot_owner(p_telegram_id);
  select coalesce(jsonb_agg(jsonb_build_object(
           'telegram_id', a.telegram_id,
           'name', coalesce(a.display_name, a.tg_name, a.username, a.telegram_id::text),
           'username', a.username,
           'role', a.role::text,
           'is_active', a.is_active,
           'confirmed', (select count(*) from bot_issues i
                          where i.admin_id = a.id and i.status = 'confirmed')
         ) order by a.role, a.created_at), '[]'::jsonb) into v_out
    from bot_admins a;
  return v_out;
end $$;

-- ============================================================
-- بذرة البداية: منتج واحد بمدّتين، تماماً كما وُصف. زد ما شئت
-- بعدها من داخل البوت — /addproduct و /addvariant.
-- ============================================================
insert into bot_products (code, name, sort_order)
values ('giftcard', 'بطاقة جيفت كارد', 10)
on conflict (code) do nothing;

insert into bot_variants (product_id, code, name, sort_order)
select p.id, v.code, v.name, v.sort_order
  from bot_products p
  cross join (values ('year','سنة',10), ('3months','3 أشهر',20)) as v(code,name,sort_order)
 where p.code = 'giftcard'
on conflict (product_id, code) do nothing;

-- ============================================================
-- لا أحد ينادي هذه الدوال إلا service_role من داخل الـEdge
-- Function. الافتراضي في PostgreSQL هو منح التنفيذ لـPUBLIC،
-- ولأنها SECURITY DEFINER فذلك يعني أن أي زائر بمفتاح anon
-- كان سيقرأ المخزون كله بتمرير أي telegram_id. تُسحب صراحة.
-- ============================================================
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like 'bot\_%'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ── 022_bot_sales_detail.sql ─────────────────────────────────────
-- bundle: bot
-- ============================================================
-- Janeiro Store — 022 تفصيل المبيعات في البوت
--
-- ثلاثة أشياء كان البوت يعرفها ولا يقولها:
--
--   1. رسالة التأكيد لم تكن تذكر ماذا بيع — كوداً بلا اسم منتج
--      ولا مدة. البائع يغلق عشر عمليات فلا يعرف أيّها كانت أيّاً.
--   2. «مبيعاتي» رقم واحد مجمّع. كم سنة وكم 3 أشهر؟ لا جواب.
--   3. المالك يرى ترتيب البائعين، لا ماذا باع كل واحد بالضبط.
--
-- كلها كانت في bot_issues أصلاً — مسألة عرض لا جمع بيانات.
-- ============================================================

-- ------------------------------------------------------------
-- 1. التأكيد والإلغاء يقولان ماذا بيع
-- ------------------------------------------------------------
create or replace function bot_confirm_issue(p_telegram_id bigint, p_issue_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin   bot_admins;
  v_issue   bot_issues;
  v_variant bot_variants;
  v_product bot_products;
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
   where id = p_issue_id;

  update bot_cards set status = 'sold', sold_at = now() where id = v_issue.card_id;

  select * into v_variant from bot_variants where id = v_issue.variant_id;
  select * into v_product from bot_products where id = v_variant.product_id;

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
    'seller_sales', v_sales,
    'seller_sales_of_variant', v_of_kind,
    'remaining', (select count(*) from bot_cards
                   where variant_id = v_issue.variant_id and status = 'available')
  );
end $$;

create or replace function bot_cancel_issue(p_telegram_id bigint, p_issue_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin   bot_admins;
  v_issue   bot_issues;
  v_variant bot_variants;
  v_product bot_products;
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
     set status = 'cancelled', settled_at = now(), settled_by = v_admin.id
   where id = p_issue_id;

  update bot_cards set status = 'available'
   where id = v_issue.card_id and status = 'reserved';

  select * into v_variant from bot_variants where id = v_issue.variant_id;
  select * into v_product from bot_products where id = v_variant.product_id;

  return jsonb_build_object(
    'issue_id', v_issue.id, 'status', 'cancelled',
    'card_code', v_issue.card_code,
    'product_name', v_product.name,
    'variant_name', v_variant.name,
    'remaining', (select count(*) from bot_cards
                   where variant_id = v_issue.variant_id and status = 'available')
  );
end $$;

-- ------------------------------------------------------------
-- 2. من باع ماذا وكم — لكل أدمن، مفصّلاً حسب المنتج والمدة
--
--   p_scope = 'me'  -> صفّ المتحدث وحده
--   p_scope = 'all' -> كل الأدمن (للمالك)
--   p_target        -> أدمن بعينه (للمالك)
--
-- كل رقم محسوب من bot_issues لحظة القراءة، لا من عدّاد مخزّن.
-- ------------------------------------------------------------
create or replace function bot_breakdown(
  p_telegram_id bigint,
  p_scope       text   default 'me',
  p_target      bigint default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_admin bot_admins; v_out jsonb;
begin
  v_admin := bot_actor(p_telegram_id);
  if (p_scope = 'all' or p_target is not null) and v_admin.role <> 'owner' then
    raise exception 'NOT_OWNER';
  end if;
  if p_target is not null
     and not exists (select 1 from bot_admins where telegram_id = p_target) then
    raise exception 'ADMIN_NOT_FOUND';
  end if;

  select coalesce(jsonb_agg(s.row order by s.confirmed desc, s.name), '[]'::jsonb)
    into v_out
  from (
    select
      coalesce(a.display_name, a.tg_name, a.username, a.telegram_id::text) as name,
      count(i.id) filter (where i.status = 'confirmed') as confirmed,
      jsonb_build_object(
        'telegram_id', a.telegram_id,
        'name',      coalesce(a.display_name, a.tg_name, a.username, a.telegram_id::text),
        'role',      a.role::text,
        'is_active', a.is_active,
        'confirmed', count(i.id) filter (where i.status = 'confirmed'),
        'cancelled', count(i.id) filter (where i.status = 'cancelled'),
        'pending',   count(i.id) filter (where i.status = 'pending'),
        'today',     count(i.id) filter (where i.status = 'confirmed'
                                           and i.settled_at >= date_trunc('day', now())),
        'this_month',count(i.id) filter (where i.status = 'confirmed'
                                           and i.settled_at >= date_trunc('month', now())),
        -- التفصيل: سطر لكل مدة باع منها فعلاً. المدد التي لم يبع
        -- منها شيئاً لا تظهر — قائمة أصفار ليست تقريراً.
        'items', coalesce((
          select jsonb_agg(d.row order by d.confirmed desc, d.pname, d.vname)
            from (
              select pr.name as pname, va.name as vname,
                     count(*) filter (where i2.status = 'confirmed') as confirmed,
                jsonb_build_object(
                  'product',   pr.name,
                  'variant',   va.name,
                  'confirmed', count(*) filter (where i2.status = 'confirmed'),
                  'cancelled', count(*) filter (where i2.status = 'cancelled')
                ) as row
                from bot_issues i2
                join bot_variants va on va.id = i2.variant_id
                join bot_products pr on pr.id = va.product_id
               where i2.admin_id = a.id
                 and i2.status in ('confirmed','cancelled')
               group by pr.id, pr.name, va.id, va.name
              having count(*) filter (where i2.status = 'confirmed') > 0
            ) d
        ), '[]'::jsonb)
      ) as row
    from bot_admins a
    left join bot_issues i on i.admin_id = a.id
   where case
           when p_target is not null then a.telegram_id = p_target
           when p_scope = 'all'      then true
           else a.id = v_admin.id
         end
   group by a.id
  ) s;

  return v_out;
end $$;

-- ------------------------------------------------------------
-- 3. الصلاحيات — كما في 021: service_role وحده.
--    (تُعاد هنا لأن create or replace على دالة جديدة يمنح
--     PUBLIC حق التنفيذ افتراضياً.)
-- ------------------------------------------------------------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like 'bot\_%'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ── 023_bot_certificates.sql ─────────────────────────────────────
-- bundle: bot
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

-- ── 024_bot_customer_form.sql ─────────────────────────────────────
-- bundle: bot
-- ============================================================
-- Janeiro Store — 024 الزبون يعبّي بنفسه، ووثيقة يحفظها
--
--   البائع يؤكّد البيعة
--     -> يضغط «🔗 يعبّيها الزبون» فيأخذ رابطاً
--     -> يرسله للزبون في سناب أو واتساب أو أي مكان
--     -> الزبون يفتحه، يكتب رقمه ويوزره بنفسه
--     -> تظهر له الوثيقة فوراً: متى بدأ اشتراكه ومتى ينتهي،
--        وتحتها كل قنوات تواصلكم — يحفظها أو يطبعها PDF
--
-- الرابط يحمل رمزاً عشوائياً (256 بت) هو وحده مفتاحه، يُستعمل مرة
-- واحدة وينتهي بعد مدة. لا حساب ولا تسجيل دخول على الزبون.
-- ============================================================

-- ------------------------------------------------------------
-- 1. قنوات التواصل التي تظهر أسفل الوثيقة
-- ------------------------------------------------------------
create table if not exists bot_contacts (
  id         uuid primary key default gen_random_uuid(),
  label      text not null check (char_length(label) between 1 and 40),
  value      text not null check (char_length(value) between 1 and 120),
  url        text check (url is null or url ~ '^https?://'),
  icon       text check (char_length(icon) <= 8),
  is_active  boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (label)
);

-- ------------------------------------------------------------
-- 2. رابط التعبئة
-- ------------------------------------------------------------
create table if not exists bot_fill_tokens (
  token      text primary key check (char_length(token) >= 32),
  issue_id   uuid not null unique references bot_issues(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at    timestamptz
);
create index if not exists idx_bot_fill_expires on bot_fill_tokens(expires_at);

alter table bot_contacts    enable row level security;
alter table bot_fill_tokens enable row level security;
revoke all on bot_contacts, bot_fill_tokens from anon, authenticated;

-- ------------------------------------------------------------
-- 3. توليد الرابط — للبائع صاحب البيعة
-- ------------------------------------------------------------
create or replace function bot_fill_link(
  p_telegram_id bigint, p_issue_id uuid, p_days int default 7
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin bot_admins; v_issue bot_issues; v_tok bot_fill_tokens;
begin
  v_admin := bot_actor(p_telegram_id);

  select * into v_issue from bot_issues where id = p_issue_id;
  if not found then raise exception 'ISSUE_NOT_FOUND'; end if;
  if v_issue.admin_id <> v_admin.id and v_admin.role <> 'owner' then
    raise exception 'NOT_YOUR_ISSUE';
  end if;
  if v_issue.status <> 'confirmed' then
    raise exception 'ISSUE_NOT_CONFIRMED:%', v_issue.status;
  end if;
  if exists (select 1 from bot_certificates where issue_id = p_issue_id) then
    raise exception 'CERTIFICATE_EXISTS:%',
      (select code from bot_certificates where issue_id = p_issue_id);
  end if;

  -- رابط واحد لكل بيعة: طلبه مرتين يعيد نفس الرابط ويمدّد صلاحيته،
  -- فلا ينتشر رابطان لبيعة واحدة.
  insert into bot_fill_tokens (token, issue_id, expires_at)
  values (
    replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
    p_issue_id,
    now() + make_interval(days => greatest(1, least(coalesce(p_days, 7), 60)))
  )
  on conflict (issue_id) do update
    set expires_at = excluded.expires_at
  returning * into v_tok;

  return jsonb_build_object(
    'token', v_tok.token, 'expires_at', v_tok.expires_at,
    'issue_id', p_issue_id
  );
end $$;

-- ------------------------------------------------------------
-- 4. ما يراه الزبون في الاستمارة
-- ------------------------------------------------------------
-- بلا هوية: الرمز نفسه هو المفتاح. ولا يعيد كود البطاقة أبداً —
-- الزبون أخذه من البائع، ولا شأن لهذه الصفحة به.
create or replace function bot_fill_form(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tok bot_fill_tokens; v_issue bot_issues;
  v_variant bot_variants; v_product bot_products;
begin
  select * into v_tok from bot_fill_tokens where token = btrim(coalesce(p_token, ''));
  if not found then raise exception 'LINK_NOT_FOUND'; end if;
  if v_tok.used_at is not null then raise exception 'LINK_USED'; end if;
  if v_tok.expires_at <= now() then raise exception 'LINK_EXPIRED'; end if;

  select * into v_issue   from bot_issues   where id = v_tok.issue_id;
  select * into v_variant from bot_variants where id = v_issue.variant_id;
  select * into v_product from bot_products where id = v_variant.product_id;

  return jsonb_build_object(
    'product_name', v_product.name,
    'variant_name', v_variant.name,
    'fields', coalesce((
      select jsonb_agg(jsonb_build_object(
               'label', f.label, 'is_required', f.is_required) order by f.sort_order, f.label)
        from bot_fields f where f.product_id = v_product.id
    ), '[]'::jsonb)
  );
end $$;

-- ------------------------------------------------------------
-- 5. الزبون يرسل بياناته -> تصدر الوثيقة
-- ------------------------------------------------------------
create or replace function bot_fill_submit(p_token text, p_values jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tok bot_fill_tokens; v_issue bot_issues; v_seller bot_admins;
  v_res jsonb;
begin
  -- القفل قبل القراءة: ضغطتان على «إرسال» لا تنتجان وثيقتين.
  select * into v_tok from bot_fill_tokens
   where token = btrim(coalesce(p_token, '')) for update;
  if not found then raise exception 'LINK_NOT_FOUND'; end if;
  if v_tok.used_at is not null then raise exception 'LINK_USED'; end if;
  if v_tok.expires_at <= now() then raise exception 'LINK_EXPIRED'; end if;

  select * into v_issue  from bot_issues where id = v_tok.issue_id;
  select * into v_seller from bot_admins where id = v_issue.admin_id;

  -- يُصدرها باسم البائع صاحب البيعة: هو من باع، والزبون مجرد من
  -- عبّأ البيانات. فتبقى كل الفحوص في bot_issue_certificate كما هي.
  v_res := bot_issue_certificate(v_seller.telegram_id, v_tok.issue_id, p_values);

  update bot_fill_tokens set used_at = now() where token = v_tok.token;

  return v_res || jsonb_build_object('seller_telegram_id', v_seller.telegram_id);
end $$;

-- ------------------------------------------------------------
-- 6. الوثيقة كما يراها الزبون — بالرمز وحده، بلا حساب
-- ------------------------------------------------------------
-- الرمز 56 بت عشوائية، وهو نفسه بطاقة الدخول: نفس نموذج الثقة
-- الذي يعتمده أي رابط فاتورة. لا يعيد كود البطاقة ولا اسم البائع.
create or replace function bot_public_certificate(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cert bot_certificates; v_issue bot_issues;
  v_variant bot_variants; v_product bot_products;
begin
  if p_code is null or char_length(btrim(p_code)) < 8 then
    raise exception 'CERTIFICATE_NOT_FOUND';
  end if;
  select * into v_cert from bot_certificates where code = upper(btrim(p_code));
  if not found then raise exception 'CERTIFICATE_NOT_FOUND'; end if;

  select * into v_issue   from bot_issues   where id = v_cert.issue_id;
  select * into v_variant from bot_variants where id = v_issue.variant_id;
  select * into v_product from bot_products where id = v_variant.product_id;

  return jsonb_build_object(
    'code', v_cert.code,
    'product_name', v_product.name,
    'variant_name', v_variant.name,
    'customer', v_cert.customer,
    'starts_at', v_cert.starts_at,
    'ends_at', v_cert.ends_at,
    'expired', v_cert.ends_at is not null and v_cert.ends_at <= now(),
    'days_left', case when v_cert.ends_at is null then null
                      else greatest(0, (date_part('day', v_cert.ends_at - now()))::int) end,
    'issued_at', v_cert.created_at,
    'contacts', coalesce((
      select jsonb_agg(jsonb_build_object(
               'label', label, 'value', value, 'url', url, 'icon', icon)
             order by sort_order, label)
        from bot_contacts where is_active), '[]'::jsonb)
  );
end $$;

-- ------------------------------------------------------------
-- 6-ب. «من ينتهي اشتراكه اليوم؟»
-- ------------------------------------------------------------
-- p_days = 0 تعني اليوم نفسه: كل ما ينتهي قبل منتصف الليل. كانت
-- الدالة تبدأ من يوم واحد، فلم يكن لهذا السؤال جواب مباشر.
create or replace function bot_expiring(p_telegram_id bigint, p_days int default 7)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_admin bot_admins; v_until timestamptz; v_out jsonb;
begin
  v_admin := bot_actor(p_telegram_id);
  p_days := greatest(0, least(coalesce(p_days, 7), 90));

  v_until := case when p_days = 0
                  then date_trunc('day', now()) + interval '1 day'
                  else now() + make_interval(days => p_days) end;

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
       and c.ends_at <= v_until
       and (v_admin.role = 'owner' or i.admin_id = v_admin.id)
     order by c.ends_at
     limit 50
  ) r;

  return v_out;
end $$;

-- ------------------------------------------------------------
-- 7. إدارة قنوات التواصل — للمالك
-- ------------------------------------------------------------
create or replace function bot_add_contact(
  p_telegram_id bigint, p_label text, p_value text,
  p_url text default null, p_icon text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_next int; v_row bot_contacts;
begin
  perform bot_owner(p_telegram_id);
  p_label := btrim(coalesce(p_label, ''));
  p_value := btrim(coalesce(p_value, ''));
  p_url   := nullif(btrim(coalesce(p_url, '')), '');
  if p_label = '' or char_length(p_label) > 40 then raise exception 'INVALID_LABEL'; end if;
  if p_value = '' or char_length(p_value) > 120 then raise exception 'INVALID_VALUE'; end if;
  if p_url is not null and p_url !~ '^https?://' then raise exception 'INVALID_URL'; end if;

  select coalesce(max(sort_order), 0) + 10 into v_next from bot_contacts;

  -- نفس التسمية تُحدَّث لا تُكرَّر: تغيير رقم الهاتف لا يترك القديم.
  insert into bot_contacts (label, value, url, icon, sort_order)
  values (p_label, p_value, p_url, nullif(btrim(coalesce(p_icon, '')), ''), v_next)
  on conflict (label) do update
    set value = excluded.value, url = excluded.url,
        icon = coalesce(excluded.icon, bot_contacts.icon), is_active = true
  returning * into v_row;

  return jsonb_build_object('label', v_row.label, 'value', v_row.value, 'url', v_row.url);
end $$;

create or replace function bot_remove_contact(p_telegram_id bigint, p_label text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  perform bot_owner(p_telegram_id);
  delete from bot_contacts where label = btrim(coalesce(p_label, ''));
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'CONTACT_NOT_FOUND'; end if;
  return jsonb_build_object('removed', p_label);
end $$;

create or replace function bot_list_contacts(p_telegram_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  perform bot_actor(p_telegram_id);
  select coalesce(jsonb_agg(jsonb_build_object(
           'label', label, 'value', value, 'url', url, 'icon', icon, 'is_active', is_active)
         order by sort_order, label), '[]'::jsonb) into v_out from bot_contacts;
  return v_out;
end $$;

-- ------------------------------------------------------------
-- 8. الصلاحيات — service_role وحده، كما في 021.
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

-- ── 025_service_engagement.sql ─────────────────────────────────────
-- bundle: bot
-- ============================================================
-- Janeiro Store — 025 وثيقة التزام الخدمة
--
-- المرحلة أ: الداتا والحساب.
--
-- الفرق عن 023: تلك الوثيقة مشدودة إلى بيعة بطاقة من المخزون
-- (issue_id not null). وهذه تُصدر لعملية يحدّد فيها الأدمن المنصة
-- والمدة بيده — Snapchat Plus سنة + 7 أيام هدية — بلا بطاقة ولا
-- مخزون. فالمنصة والمدة وأيام الهدية تُحمل على الوثيقة نفسها.
--
-- أيام الهدية قيمة لكل عملية لا خاصية للباقة: المزوّد يعطي أسبوعاً
-- مجاناً مرة ولا يعطيه أخرى. تُخزَّن كما أُدخلت، ولا تُستنبط من
-- المدة أبداً.
--
-- كل تاريخ يُحسب هنا، في القاعدة، بتوقيت Africa/Algiers. لا
-- الفورم ولا المتصفّح يُقدّم تاريخاً ولا يُقبل منه.
-- ============================================================

-- ------------------------------------------------------------
-- 1. الوثيقة تتحرّر من المخزون
-- ------------------------------------------------------------
alter table bot_certificates
  alter column issue_id drop not null;

alter table bot_certificates
  add column if not exists platform    text,
  add column if not exists months      integer,
  add column if not exists bonus_days  integer not null default 0,
  add column if not exists ref_code    text,
  add column if not exists revoked_at  timestamptz,
  add column if not exists revoked_by  uuid references bot_admins(id) on delete set null,
  add column if not exists issued_by   uuid references bot_admins(id) on delete set null;

do $$ begin
  alter table bot_certificates add constraint bot_cert_months_ok
    check (months is null or months between 1 and 120);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table bot_certificates add constraint bot_cert_bonus_ok
    check (bonus_days between 0 and 90);
exception when duplicate_object then null; end $$;

-- وثيقة بلا بيعة مخزون يجب أن تحمل منصتها ومدتها، وإلا فهي بلا
-- موضوع. ووثيقة من بيعة تأخذهما من المنتج والمدة.
do $$ begin
  alter table bot_certificates add constraint bot_cert_subject_ok
    check (issue_id is not null or (platform is not null and months is not null));
exception when duplicate_object then null; end $$;

create unique index if not exists uq_bot_cert_ref on bot_certificates(ref_code)
  where ref_code is not null;
create index if not exists idx_bot_cert_platform on bot_certificates(platform);
create index if not exists idx_bot_cert_revoked  on bot_certificates(revoked_at);

-- ورابط التعبئة كذلك: قد يسبق وجود أي بيعة
alter table bot_fill_tokens
  alter column issue_id drop not null;
alter table bot_fill_tokens
  add column if not exists certificate_id uuid references bot_certificates(id) on delete cascade,
  add column if not exists created_by     uuid references bot_admins(id) on delete set null;
create unique index if not exists uq_bot_fill_cert on bot_fill_tokens(certificate_id)
  where certificate_id is not null;

do $$ begin
  alter table bot_fill_tokens add constraint bot_fill_target_ok
    check (issue_id is not null or certificate_id is not null);
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------
-- 2. المنصات
-- ------------------------------------------------------------
-- طلبتَ array في ملف كونفيغ. جعلتها جدولاً لأن الملف داخل الدالة
-- يحتاج إعادة نشر عند كل تعديل، والهدف كان «نزيد ونحيّ بلا ما
-- نلمس الكود» — وهذا يحقّقه أكثر: تزيد منصة بأمر من البوت،
-- وتظهر في الأزرار فوراً. القائمة الثمانية مزروعة أدناه.
create table if not exists bot_platforms (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique check (char_length(name) between 1 and 60),
  is_active  boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

insert into bot_platforms (name, sort_order) values
  ('Snapchat Plus',    10),
  ('Gemini Pro',       20),
  ('Discord Nitro',    30),
  ('Spotify',          40),
  ('Netflix',          50),
  ('YouTube Premium',  60),
  ('Canva Pro',        70),
  ('ChatGPT Plus',     80)
on conflict (name) do nothing;

-- ------------------------------------------------------------
-- 3. حالة الفلو متعدّد الخطوات
-- ------------------------------------------------------------
-- الحيلة القديمة (الحالة داخل نصّ رسالة الردّ الإجباري) تكفي سؤالاً
-- واحداً. أربع خطوات مع «تعديل» ومعاينة لا تتحمّلها: صفّ واحد لكل
-- أدمن، يُستبدل عند بداية فلو جديد ويُمحى عند التأكيد.
create table if not exists bot_wizard_state (
  admin_id     uuid primary key references bot_admins(id) on delete cascade,
  platform     text,
  months       integer check (months is null or months between 1 and 120),
  bonus_days   integer check (bonus_days is null or bonus_days between 0 and 90),
  awaiting     text check (awaiting in ('platform','months','bonus','bonus_manual','platform_manual','preview')),
  message_id   bigint,
  updated_at   timestamptz not null default now()
);
drop trigger if exists trg_bot_wizard_updated on bot_wizard_state;
create trigger trg_bot_wizard_updated before update on bot_wizard_state
  for each row execute function set_updated_at();

alter table bot_platforms    enable row level security;
alter table bot_wizard_state enable row level security;
revoke all on bot_platforms, bot_wizard_state from anon, authenticated;

-- ------------------------------------------------------------
-- 4. الأكواد
-- ------------------------------------------------------------
-- JW- للتحقق (10 خانات hex = 40 بت)، JS- للمرجعية (8 = 32 بت).
-- كلاهما من gen_random_uuid() لا gen_random_bytes(): الثانية تحتاج
-- pgcrypto، وعلى Supabase المستضاف تسكن schema اسمه extensions لا
-- يراه search_path = public — وهو ما أوقع get_certificate سابقاً.
create or replace function bot_engagement_code()
returns text language plpgsql volatile set search_path = public as $$
declare candidate text;
begin
  for attempt in 1..20 loop
    candidate := 'JW-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    if not exists (select 1 from bot_certificates where code = candidate) then
      return candidate;
    end if;
  end loop;
  raise exception 'CERTIFICATE_CODE_GENERATION_FAILED';
end $$;

create or replace function bot_engagement_ref()
returns text language plpgsql volatile set search_path = public as $$
declare candidate text;
begin
  for attempt in 1..20 loop
    candidate := 'JS-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    if not exists (select 1 from bot_certificates where ref_code = candidate) then
      return candidate;
    end if;
  end loop;
  raise exception 'REF_CODE_GENERATION_FAILED';
end $$;

-- ------------------------------------------------------------
-- 5. الحساب — نقطة واحدة، بتوقيت الجزائر
-- ------------------------------------------------------------
-- expiryDate = addDays(addMonths(start, months), bonusDays)
--
-- الحساب يجري على الوقت المحلي ثم يُعاد إلى timestamptz، فيثبت
-- وقت اليوم بعد سنة كما كان (وتُحترم أي إزاحة صيفية لو استُحدثت؛
-- الجزائر UTC+1 طوال العام اليوم).
--
-- الأشهر قبل الأيام داخل interval واحد — وهذا سلوك PostgreSQL
-- المضمون: 31 يناير + '1 month 1 day' = 1 مارس، نفس ما يعطيه
-- التنفيذ على خطوتين. مفحوص لا مفترض.
create or replace function bot_engagement_expiry(
  p_start timestamptz, p_months int, p_bonus_days int
) returns timestamptz
language sql immutable set search_path = public as $$
  select (((p_start at time zone 'Africa/Algiers')
           + make_interval(months => coalesce(p_months, 0),
                           days   => coalesce(p_bonus_days, 0)))
          at time zone 'Africa/Algiers');
$$;

-- ------------------------------------------------------------
-- 6. صاحب الاشتراك — أعمدة لا JSON
-- ------------------------------------------------------------
-- الحقول الثلاثة مثبّتة في المواصفة (الاسم، واتساب، انستغرام)،
-- فأعمدة لا مصفوفة: الداشبورد يبحث ويفلتر ويصدّر CSV عليها،
-- و«لا تُكشف الواتساب» يصير عموداً لا نختاره — أضمن من ترشيح
-- عنصر داخل JSON في كل استعلام ونسيانه مرة واحدة.
alter table bot_certificates
  add column if not exists holder_name text,
  add column if not exists whatsapp    text,
  add column if not exists instagram   text;

-- وثيقة لم تُعمَّر بعد لا تملك تاريخ بداية: البداية هي لحظة التعبئة.
-- والـdefault يُسقط كذلك، وإلا وُلدت المعلّقة ببداية بلا تعبئة —
-- وهو ما أمسكه bot_cert_claim_ok أدناه عند أول إدخال حقيقي.
alter table bot_certificates alter column starts_at drop not null;
alter table bot_certificates alter column starts_at drop default;

-- المعلّقة = بلا تاريخ بداية. وهذا يصف الفيتشرين معاً: وثيقة 023
-- تولد مكتملة ببداية (لا مرحلة تعليق فيها)، ووثيقة الالتزام تولد
-- بلا بداية ثم تُثبَّت لحظة تعبئة الزبون.
--
-- كان هنا عمود claimed_at منفصل، وقيدٌ يشترط اقترانه ببداية —
-- فكسر bot_issue_certificate في 023 التي تُدرج بداية بلا claimed_at.
-- العمود كان زائداً عن starts_at، وحذفه أزال التناقض من أصله.
-- كشفته مجموعة اختبارات 023 عند دمج المجموعتين.
do $$ begin
  alter table bot_certificates add constraint bot_cert_claim_ok check (
    starts_at is not null
    or (ends_at is null and holder_name is null and whatsapp is null and instagram is null)
  );
exception when duplicate_object then null; end $$;

create index if not exists idx_bot_cert_holder on bot_certificates(holder_name);
create index if not exists idx_bot_cert_whatsapp on bot_certificates(whatsapp);
create index if not exists idx_bot_cert_starts on bot_certificates(starts_at);

-- ------------------------------------------------------------
-- 7. رقم جزائري — تطبيع سيرفر-سايد
-- ------------------------------------------------------------
-- قائمة بذاتها لا تعتمد على normalize_dz_phone في 006: من يركّب
-- البوت وحده لا يملك تلك الهجرة.
-- تقبل 0550…، +213550…، 213550…، 00213550… وبينها مسافات أو
-- شرطات. المحمول الجزائري 05/06/07 وحده؛ الثابت يُرفض.
create or replace function bot_dz_phone(p_raw text)
returns text
language plpgsql immutable set search_path = public as $$
declare v text;
begin
  v := regexp_replace(coalesce(p_raw, ''), '[^0-9+]', '', 'g');
  v := regexp_replace(v, '^\+', '', '');
  v := regexp_replace(v, '^00', '', '');
  if v ~ '^213[567][0-9]{8}$' then return v; end if;
  if v ~ '^0[567][0-9]{8}$'   then return '213' || substr(v, 2); end if;
  return null;
end $$;

-- ------------------------------------------------------------
-- 8. حدّ المحاولات — قائم بذاته كذلك
-- ------------------------------------------------------------
create table if not exists bot_rate_limits (
  bucket   text not null,
  action   text not null,
  hits     integer not null default 1,
  window_start timestamptz not null default now(),
  primary key (bucket, action)
);
alter table bot_rate_limits enable row level security;
revoke all on bot_rate_limits from anon, authenticated;

-- الحدّ يجب أن يُنادى في معاملة مستقلة، لا من داخل الدالة التي
-- يحرسها. السبب: إن رفعت تلك الدالة استثناءً (اسم قصير، رقم غير
-- صالح، رمز مجهول) رجعت معاملتها بالكامل — ومعها زيادة العدّاد.
-- فيصير الطَّرق بمدخلات خاطئة مجانياً، وهو بالضبط ما نريد حدّه.
-- لذلك تناديه الدالة الحدّية (Edge Function) أولاً، ثم تنادي العمل.
-- كشفه الاختبار؛ لم يكن ظاهراً في القراءة.
create or replace function bot_claim_guard(p_token text, p_ip text default null)
returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  if not bot_rate_limit('tok:' || coalesce(btrim(p_token), ''), 'claim', 10, interval '10 minutes')
  then return false; end if;
  if p_ip is not null and btrim(p_ip) <> ''
     and not bot_rate_limit('ip:' || btrim(p_ip), 'claim', 20, interval '10 minutes')
  then return false; end if;
  return true;
end $$;

create or replace function bot_read_guard(p_code text, p_ip text default null)
returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  if not bot_rate_limit('code:' || upper(btrim(coalesce(p_code, ''))), 'read', 60, interval '10 minutes')
  then return false; end if;
  if p_ip is not null and btrim(p_ip) <> ''
     and not bot_rate_limit('ip:' || btrim(p_ip), 'read', 240, interval '10 minutes')
  then return false; end if;
  return true;
end $$;

create or replace function bot_rate_limit(
  p_bucket text, p_action text, p_max int, p_window interval
) returns boolean
language plpgsql volatile set search_path = public as $$
declare v_hits int;
begin
  if coalesce(btrim(p_bucket), '') = '' then return true; end if;

  delete from bot_rate_limits
   where action = p_action and window_start < now() - p_window;

  insert into bot_rate_limits (bucket, action)
  values (btrim(p_bucket), p_action)
  on conflict (bucket, action) do update
    set hits = case when bot_rate_limits.window_start < now() - p_window
                    then 1 else bot_rate_limits.hits + 1 end,
        window_start = case when bot_rate_limits.window_start < now() - p_window
                    then now() else bot_rate_limits.window_start end
  returning hits into v_hits;

  return v_hits <= p_max;
end $$;

-- ============================================================
-- 9. الفلو: منصة -> مدة -> أيام هدية -> معاينة -> تأكيد
-- ============================================================

create or replace function bot_platforms_list(p_telegram_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  perform bot_actor(p_telegram_id);
  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'is_active', is_active)
         order by sort_order, name), '[]'::jsonb) into v_out
    from bot_platforms where is_active;
  return v_out;
end $$;

create or replace function bot_add_platform(p_telegram_id bigint, p_name text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_next int;
begin
  perform bot_owner(p_telegram_id);
  p_name := btrim(coalesce(p_name, ''));
  if p_name = '' or char_length(p_name) > 60 then raise exception 'INVALID_PLATFORM'; end if;
  select coalesce(max(sort_order), 0) + 10 into v_next from bot_platforms;
  insert into bot_platforms (name, sort_order) values (p_name, v_next)
  on conflict (name) do update set is_active = true;
  return jsonb_build_object('name', p_name);
end $$;

create or replace function bot_remove_platform(p_telegram_id bigint, p_name text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  perform bot_owner(p_telegram_id);
  -- تعطيل لا حذف: الوثائق الصادرة تحمل اسم المنصة نصاً، فلا تتأثر،
  -- لكن إحصاءها حسب المنصة يبقى مفهوماً.
  update bot_platforms set is_active = false where name = btrim(coalesce(p_name, ''));
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'PLATFORM_NOT_FOUND'; end if;
  return jsonb_build_object('name', p_name, 'is_active', false);
end $$;

-- ---------- الحالة ----------
create or replace function bot_wizard_begin(p_telegram_id bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin bot_admins;
begin
  v_admin := bot_actor(p_telegram_id);
  insert into bot_wizard_state (admin_id, awaiting)
  values (v_admin.id, 'platform')
  on conflict (admin_id) do update
    set platform = null, months = null, bonus_days = null,
        awaiting = 'platform', message_id = null;
  return jsonb_build_object('awaiting', 'platform');
end $$;

-- خطوة واحدة تضبط قيمة واحدة وتقول ما بعدها. الوجهة محسوبة هنا لا
-- في الدالة، فترتيب الخطوات وقواعده في مكان واحد.
create or replace function bot_wizard_set(
  p_telegram_id bigint, p_step text, p_value text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin bot_admins; v_st bot_wizard_state; v_n int;
begin
  v_admin := bot_actor(p_telegram_id);
  select * into v_st from bot_wizard_state where admin_id = v_admin.id;
  if not found then raise exception 'WIZARD_NOT_STARTED'; end if;

  if p_step = 'platform' then
    p_value := btrim(coalesce(p_value, ''));
    if p_value = '' or char_length(p_value) > 60 then raise exception 'INVALID_PLATFORM'; end if;
    update bot_wizard_state set platform = p_value, awaiting = 'months'
     where admin_id = v_admin.id;

  elsif p_step = 'months' then
    v_n := nullif(btrim(coalesce(p_value, '')), '')::int;
    if v_n is null or v_n < 1 or v_n > 120 then raise exception 'INVALID_MONTHS'; end if;
    update bot_wizard_state set months = v_n, awaiting = 'bonus'
     where admin_id = v_admin.id;

  elsif p_step = 'bonus' then
    v_n := coalesce(nullif(btrim(coalesce(p_value, '')), '')::int, 0);
    if v_n < 0 or v_n > 90 then raise exception 'INVALID_BONUS'; end if;
    update bot_wizard_state set bonus_days = v_n, awaiting = 'preview'
     where admin_id = v_admin.id;

  -- انتظار إدخال يدوي: المنصة أو عدد الأيام
  elsif p_step in ('platform_manual', 'bonus_manual') then
    update bot_wizard_state set awaiting = p_step where admin_id = v_admin.id;

  -- «تعديل»: يعود لخطوة ويمحو ما بعدها، فلا تبقى قيمة معلّقة من
  -- مسار سابق تدخل المعاينة بلا أن يراها الأدمن.
  elsif p_step = 'back_platform' then
    update bot_wizard_state
       set awaiting = 'platform', platform = null, months = null, bonus_days = null
     where admin_id = v_admin.id;
  elsif p_step = 'back_months' then
    update bot_wizard_state
       set awaiting = 'months', months = null, bonus_days = null
     where admin_id = v_admin.id;
  elsif p_step = 'back_bonus' then
    update bot_wizard_state set awaiting = 'bonus', bonus_days = null
     where admin_id = v_admin.id;
  else
    raise exception 'INVALID_STEP:%', p_step;
  end if;

  return bot_wizard_preview(p_telegram_id);
end $$;

-- المعاينة: التواريخ المتوقّعة إن عُمِّرت الآن. البداية الحقيقية
-- تُثبَّت لحظة تعبئة الزبون، لا الآن — لذلك تُسمّى projected.
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
    'awaiting',   v_st.awaiting,
    'platform',   v_st.platform,
    'months',     v_st.months,
    'bonus_days', v_st.bonus_days,
    'ready',      v_st.platform is not null and v_st.months is not null
                  and v_st.bonus_days is not null,
    'projected_start', v_start,
    'projected_end',   case when v_st.months is null then null
                            else bot_engagement_expiry(v_start, v_st.months,
                                                       coalesce(v_st.bonus_days, 0)) end
  );
end $$;

create or replace function bot_wizard_cancel(p_telegram_id bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin bot_admins;
begin
  v_admin := bot_actor(p_telegram_id);
  delete from bot_wizard_state where admin_id = v_admin.id;
  return jsonb_build_object('cancelled', true);
end $$;

-- ============================================================
-- 10. التأكيد: وثيقة معلّقة + رابط واحد للزبون
-- ============================================================
-- الوثيقة تُنشأ الآن بلا صاحب ولا تواريخ — حالتها pending حتى
-- يعبّي الزبون. هكذا يراها الداشبورد من لحظة توليد الرابط، وهو
-- عين ما طُلب: pending = رابط مولّد وما عُمِّرش.
create or replace function bot_engagement_confirm(
  p_telegram_id bigint, p_hours int default 72
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin bot_admins; v_st bot_wizard_state;
  v_cert bot_certificates; v_token text;
begin
  v_admin := bot_actor(p_telegram_id);
  select * into v_st from bot_wizard_state where admin_id = v_admin.id;
  if not found then raise exception 'WIZARD_NOT_STARTED'; end if;
  if v_st.platform is null then raise exception 'PLATFORM_MISSING'; end if;
  if v_st.months   is null then raise exception 'MONTHS_MISSING';   end if;

  insert into bot_certificates
    (code, ref_code, platform, months, bonus_days, issued_by, customer)
  values
    (bot_engagement_code(), bot_engagement_ref(), v_st.platform, v_st.months,
     coalesce(v_st.bonus_days, 0), v_admin.id, '[]'::jsonb)
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
    'bonus_days', v_cert.bonus_days,
    'expires_at', now() + make_interval(hours => coalesce(p_hours, 72))
  );
end $$;

-- ---------- ما يراه الزبون قبل التعبئة ----------
-- الحقول الثلاثة مثبّتة، وتُعاد بمفاتيحها لا بتسمياتها: الترجمة
-- في ملفات i18n خارج القاعدة، فتبديل نصّ لا يمسّ هجرة.
create or replace function bot_engagement_claim_form(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_tok bot_fill_tokens; v_cert bot_certificates;
begin
  select * into v_tok from bot_fill_tokens where token = btrim(coalesce(p_token, ''));
  if not found then raise exception 'LINK_NOT_FOUND'; end if;
  if v_tok.certificate_id is null then raise exception 'LINK_NOT_FOUND'; end if;
  if v_tok.used_at is not null then raise exception 'LINK_USED'; end if;
  if v_tok.expires_at <= now() then raise exception 'LINK_EXPIRED'; end if;

  select * into v_cert from bot_certificates where id = v_tok.certificate_id;
  if v_cert.revoked_at is not null then raise exception 'CERTIFICATE_REVOKED'; end if;

  return jsonb_build_object(
    'platform',   v_cert.platform,
    'months',     v_cert.months,
    'bonus_days', v_cert.bonus_days,
    'fields',     jsonb_build_array('full_name', 'whatsapp', 'instagram')
  );
end $$;

-- ---------- التعبئة ----------
-- هنا تُثبَّت البداية والنهاية. لا تاريخ يُقبل من الفورم: الوسائط
-- ثلاثة نصوص فقط، والباقي يُحسب.
create or replace function bot_engagement_claim(
  p_token     text,
  p_name      text,
  p_whatsapp  text,
  p_instagram text default null,
  p_ip        text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tok bot_fill_tokens; v_cert bot_certificates;
  v_name text; v_phone text; v_insta text; v_start timestamptz;
begin
  -- لا حدّ هنا: bot_claim_guard تُنادى قبلها في معاملة مستقلة،
  -- وإلا محا فشلُ هذه الدالة عدّادَ محاولاتها.
  select * into v_tok from bot_fill_tokens
   where token = btrim(coalesce(p_token, '')) for update;
  if not found or v_tok.certificate_id is null then raise exception 'LINK_NOT_FOUND'; end if;
  if v_tok.used_at is not null then raise exception 'LINK_USED'; end if;
  if v_tok.expires_at <= now() then raise exception 'LINK_EXPIRED'; end if;

  select * into v_cert from bot_certificates where id = v_tok.certificate_id for update;
  if v_cert.revoked_at is not null then raise exception 'CERTIFICATE_REVOKED'; end if;
  if v_cert.starts_at is not null then raise exception 'ALREADY_CLAIMED'; end if;

  v_name := btrim(coalesce(p_name, ''));
  if char_length(v_name) < 3 or char_length(v_name) > 80 then raise exception 'INVALID_NAME'; end if;

  v_phone := bot_dz_phone(p_whatsapp);
  if v_phone is null then raise exception 'INVALID_PHONE'; end if;

  v_insta := nullif(regexp_replace(btrim(coalesce(p_instagram, '')), '^@+', ''), '');
  if v_insta is not null then
    if char_length(v_insta) > 40 then raise exception 'INVALID_INSTAGRAM'; end if;
    if v_insta !~ '^[A-Za-z0-9._]+$' then raise exception 'INVALID_INSTAGRAM'; end if;
  end if;

  v_start := now();

  update bot_certificates
     set holder_name = v_name,
         whatsapp    = v_phone,
         instagram   = v_insta,
         starts_at   = v_start,
         ends_at     = bot_engagement_expiry(v_start, v_cert.months, v_cert.bonus_days)
   where id = v_cert.id
  returning * into v_cert;

  update bot_fill_tokens set used_at = now() where token = v_tok.token;

  return jsonb_build_object(
    'code', v_cert.code, 'ref_code', v_cert.ref_code,
    'issued_by_telegram_id',
      (select telegram_id from bot_admins where id = v_cert.issued_by)
  );
end $$;

-- ============================================================
-- 11. القراءة العامة — الوثيقة وصفحة التحقق
-- ============================================================
-- دالة واحدة تحسب الحالة، فلا يعيد كل مستدعٍ حسابها بشكل مختلف.
create or replace function bot_engagement_status(c bot_certificates)
returns text
language sql immutable set search_path = public as $$
  select case
    when c.revoked_at is not null then 'revoked'
    when c.starts_at  is null     then 'pending'
    when c.ends_at is not null and c.ends_at <= now() then 'expired'
    else 'active' end;
$$;

-- الواتساب ليس هنا — بحكم قائمة الأعمدة لا بحكم ترشيح. ولا اسم
-- البائع، ولا كود البطاقة، ولا أي معطى داخلي.
create or replace function bot_engagement_public(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_cert bot_certificates;
begin
  if p_code is null or char_length(btrim(p_code)) < 8 then
    raise exception 'CERTIFICATE_NOT_FOUND';
  end if;
  -- الحدّ في bot_read_guard، لنفس سبب bot_claim_guard أعلاه
  select * into v_cert from bot_certificates where code = upper(btrim(p_code));
  if not found then raise exception 'CERTIFICATE_NOT_FOUND'; end if;
  if v_cert.starts_at is null then raise exception 'CERTIFICATE_PENDING'; end if;

  return jsonb_build_object(
    'code',        v_cert.code,
    'ref_code',    v_cert.ref_code,
    'holder_name', v_cert.holder_name,
    'instagram',   v_cert.instagram,
    'platform',    v_cert.platform,
    'months',      v_cert.months,
    'bonus_days',  v_cert.bonus_days,
    'starts_at',   v_cert.starts_at,
    'ends_at',     v_cert.ends_at,
    'status',      bot_engagement_status(v_cert),
    'days_left',   case when v_cert.ends_at is null then null
                        else greatest(0, (date_part('day', v_cert.ends_at - now()))::int) end,
    'contacts', coalesce((
      select jsonb_agg(jsonb_build_object(
               'label', label, 'value', value, 'url', url, 'icon', icon)
             order by sort_order, label)
        from bot_contacts where is_active), '[]'::jsonb)
  );
end $$;

-- صفحة التحقق التي يقصدها الـQR: أقل ما يثبت الصحة. لا اسم كامل
-- ولا يوزر — من يمسح الرمز قد لا يكون صاحب الوثيقة.
create or replace function bot_engagement_verify(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_cert bot_certificates;
begin
  select * into v_cert from bot_certificates
   where code = upper(btrim(coalesce(p_code, '')));
  if not found or v_cert.starts_at is null then
    return jsonb_build_object('found', false);
  end if;

  return jsonb_build_object(
    'found',      true,
    'code',       v_cert.code,
    'platform',   v_cert.platform,
    'ends_at',    v_cert.ends_at,
    'status',     bot_engagement_status(v_cert),
    -- الاسم مختصر: يكفي صاحبه ليتعرّف، ولا يكشفه لغيره
    'holder_hint', case when v_cert.holder_name is null then null
                        else left(v_cert.holder_name, 1) || '***' end
  );
end $$;

-- ============================================================
-- 12. الإبطال وإعادة الرابط — للمُصدِر أو المالك
-- ============================================================
create or replace function bot_engagement_revoke(p_telegram_id bigint, p_code text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin bot_admins; v_cert bot_certificates;
begin
  v_admin := bot_actor(p_telegram_id);
  select * into v_cert from bot_certificates
   where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then raise exception 'CERTIFICATE_NOT_FOUND'; end if;
  if v_admin.role <> 'owner' and v_cert.issued_by is distinct from v_admin.id then
    raise exception 'NOT_YOUR_ISSUE';
  end if;
  if v_cert.revoked_at is not null then raise exception 'ALREADY_REVOKED'; end if;

  update bot_certificates set revoked_at = now(), revoked_by = v_admin.id
   where id = v_cert.id;
  -- ورابط تعبئة لم يُستعمل يسقط معها
  update bot_fill_tokens set used_at = now()
   where certificate_id = v_cert.id and used_at is null;

  return jsonb_build_object('code', v_cert.code, 'status', 'revoked');
end $$;

-- إعادة إرسال الرابط: رمز جديد يُبطل القديم، فلا رابطان لوثيقة.
create or replace function bot_engagement_relink(
  p_telegram_id bigint, p_code text, p_hours int default 72
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin bot_admins; v_cert bot_certificates; v_token text;
begin
  v_admin := bot_actor(p_telegram_id);
  select * into v_cert from bot_certificates
   where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then raise exception 'CERTIFICATE_NOT_FOUND'; end if;
  if v_admin.role <> 'owner' and v_cert.issued_by is distinct from v_admin.id then
    raise exception 'NOT_YOUR_ISSUE';
  end if;
  if v_cert.revoked_at is not null then raise exception 'CERTIFICATE_REVOKED'; end if;
  if v_cert.starts_at is not null then raise exception 'ALREADY_CLAIMED'; end if;

  delete from bot_fill_tokens where certificate_id = v_cert.id;
  v_token := replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '');
  insert into bot_fill_tokens (token, certificate_id, created_by, expires_at)
  values (v_token, v_cert.id, v_admin.id,
          now() + make_interval(hours => greatest(1, least(coalesce(p_hours, 72), 720))));

  return jsonb_build_object('code', v_cert.code, 'token', v_token);
end $$;

-- ============================================================
-- 13. الداشبورد — قراءة واحدة بكل الفلاتر
-- ============================================================
-- الواتساب يظهر هنا: هذه للأدمن لا للزبون، والداشبورد محمي
-- بـ Supabase Auth. p_with_phone صريح حتى لا يُسرَّب بالغفلة.
create or replace function bot_engagement_admin_list(
  p_telegram_id bigint,
  p_query       text default null,
  p_status      text default null,
  p_platform    text default null,
  p_limit       int  default 100,
  p_offset      int  default 0,
  p_with_phone  boolean default false
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_admin  bot_admins;
  v_q      text;
  v_digits text;
  v_out    jsonb;
  v_total  int;
begin
  v_admin := bot_actor(p_telegram_id);
  v_q := nullif(btrim(coalesce(p_query, '')), '');
  p_limit  := greatest(1, least(coalesce(p_limit, 100), 500));
  p_offset := greatest(0, coalesce(p_offset, 0));

  -- أرقام البحث وحدها، وبثلاث خانات على الأقل. بلا هذا الشرط كان
  -- البحث بنصّ عربي يجرّد الحروف فيبقى '' فيصير شرط الهاتف
  -- like '%%' — فيُطابق كل زبون له رقم. كشفه الاختبار حين صار في
  -- القاعدة أكثر من صفّ واحد؛ بصفّ واحد كان يبدو سليماً.
  -- ويُطبَّع أولاً: الرقم يُخزَّن 213661445566، والناس تكتبه
  -- 0661445566. بلا التطبيع كان البحث بالشكل المحلي لا يجد صاحبه
  -- أبداً — وهو الشكل الوحيد الذي يقوله الزبون.
  v_digits := coalesce(
    bot_dz_phone(v_q),
    nullif(regexp_replace(coalesce(v_q, ''), '[^0-9]', '', 'g'), ''));
  if v_digits is not null and char_length(v_digits) < 3 then v_digits := null; end if;

  -- استعلام واحد: العدّ الكلي بنافذة، فلا يُكتب الترشيح مرتين
  -- ولا يتفرّق فرعاه عند أول تعديل.
  with matched as (
    select c.*, bot_engagement_status(c) as st,
           coalesce(a.display_name, a.tg_name, a.username, a.telegram_id::text) as seller
      from bot_certificates c
      left join bot_admins a on a.id = c.issued_by
     where (v_admin.role = 'owner' or c.issued_by = v_admin.id)
       and (p_platform is null or c.platform = p_platform)
       and (v_q is null
            or c.code     = upper(v_q)
            or c.ref_code = upper(v_q)
            or c.holder_name ilike '%' || v_q || '%'
            or c.instagram   ilike '%' || v_q || '%'
            or (v_digits is not null and c.whatsapp like '%' || v_digits || '%'))
  ), filtered as (
    select *, count(*) over () as total
      from matched
     where p_status is null or st = p_status
  ), page as (
    select * from filtered order by created_at desc limit p_limit offset p_offset
  )
  select coalesce(max(total), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'code', code, 'ref_code', ref_code,
           'created_at', created_at,
           'holder_name', holder_name,
           -- الرقم بطلب صريح فقط: عمود لا نختاره أضمن من ترشيح نُنساه
           'whatsapp', case when p_with_phone then whatsapp else null end,
           'instagram', instagram, 'platform', platform,
           'months', months, 'bonus_days', bonus_days,
           'starts_at', starts_at, 'ends_at', ends_at,
           'status', st, 'seller', seller,
           'days_left', case when ends_at is null then null
                             else (date_part('day', ends_at - now()))::int end,
           -- الشارة المطلوبة: أقل من 7 أيام وما زالت سارية
           'ending_soon', st = 'active' and ends_at is not null
                          and ends_at <= now() + interval '7 days'
         ) order by created_at desc), '[]'::jsonb)
    into v_total, v_out
    from page;

  return jsonb_build_object('total', v_total, 'rows', v_out);
end $$;

-- ============================================================
-- 14. الصلاحيات — service_role وحده، كما في 021.
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

-- ── 026_bot_order_data.sql ─────────────────────────────────────
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

-- ── 027_bot_markets.sql ─────────────────────────────────────
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
  ('dz', 'الجزائر', 'DA',  2, true,  10),
  ('jo', 'الأردن',  'JOD', 3, false, 20)
on conflict (code) do nothing;

-- تصحيح الرمزين لمن طبّق نسخة أولى من هذه الهجرة. مقصور على
-- القيمة القديمة بعينها: لو سمّى المالك عملته بغير ذلك لاحقاً
-- فتسميته تبقى، ولا يُعاد كتابتها في كل تشغيل.
update bot_markets set currency = 'DA'  where code = 'dz' and currency = 'دج';
update bot_markets set currency = 'JOD' where code = 'jo' and currency = 'د.أ';

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

-- ── 028_bot_product_platforms.sql ─────────────────────────────────────
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

-- ── 029_engagement_from_issue.sql ─────────────────────────────────────
-- bundle: bot
-- ============================================================
-- Janeiro Store — 029 الوثيقة تُولَد من البيعة
--
-- المرحلة 2. حتى الآن كانت الوثيقة تُبنى بفلو مستقلّ يسأل الأدمن
-- عن المنصة والمدة من الصفر، ولا يعرف أنه جاء من بيعة. وكل ما
-- يسأل عنه صار معروفاً في البيعة نفسها بعد 026–028. فهنا تُربط:
-- دالة واحدة تأخذ رقم البيعة وأيام الهدية، وتقرأ الباقي.
--
-- ومعها تصحيحان في حساب التواريخ:
--
-- 1. البداية = يوم البيع، لا يوم تعبئة الزبون.
--    كان starts_at يُثبَّت لحظة يملأ الزبون الاستمارة. فزبون
--    يملأها بعد خمسة أيام كان يربح خمسة أيام مجاناً، والوثيقة
--    تقول إن اشتراكه بدأ يوم لم يبدأ فيه. الاشتراك يبدأ حين
--    يسلّمه البائع.
--    ولأن «بلا بداية» كان هو علامة «لم يُعبَّأ بعد»، حلّ محلّها
--    عمود صريح: filled_at.
--
-- 2. المدة بالأيام كانت تضيع.
--    026 زادت duration_days، لكن bot_engagement_claim بقيت
--    تنادي bot_engagement_expiry بثلاث وسائط، فوثيقة مدتها 45
--    يوماً كانت تنتهي يوم صدورها. لم تصدر وثيقة كهذه بعدُ،
--    فالخطأ كامن لا واقع — ويسقط هنا قبل أن تصدر أوّلُها.
-- ============================================================

-- ------------------------------------------------------------
-- 1. علامة التعبئة
-- ------------------------------------------------------------
-- الافتراضي now(): وثائق 023 تولد كاملة (البائع كتب بيانات
-- الزبون بنفسه)، فتأخذه بلا أن تُلمس دالتها. ووثائق الالتزام
-- تمرّر null صراحةً لأن زبونها لم يعبّئ بعد.
alter table bot_certificates
  add column if not exists filled_at timestamptz;

alter table bot_certificates
  alter column filled_at set default now();

-- اليوم: بداية موجودة ⟺ مكتملة. فالنقل دقيق لا تقريبي.
update bot_certificates set filled_at = starts_at
 where filled_at is null and starts_at is not null;

create index if not exists idx_bot_cert_filled on bot_certificates(filled_at);

-- القيد القديم كان يربط اكتمال البيانات بوجود بداية. صار الربط
-- بالتعبئة، والبداية تُعرف من أول لحظة.
alter table bot_certificates drop constraint if exists bot_cert_claim_ok;
alter table bot_certificates add constraint bot_cert_claim_ok check (
  filled_at is not null
  or (holder_name is null and whatsapp is null and instagram is null)
);

-- ------------------------------------------------------------
-- 2. الحالة تُقرأ من التعبئة
-- ------------------------------------------------------------
create or replace function bot_engagement_status(c bot_certificates)
returns text
language sql immutable set search_path = public as $$
  select case
    when c.revoked_at is not null then 'revoked'
    when c.filled_at  is null     then 'pending'
    when c.ends_at is not null and c.ends_at <= now() then 'expired'
    else 'active' end;
$$;

-- ------------------------------------------------------------
-- 3. الوثيقة من البيعة
-- ------------------------------------------------------------
-- كل ما كان يُسأل عنه يُقرأ هنا: المنصة من البيعة، المدة من
-- الصنف، البداية من لحظة إتمام البيعة. ولا يبقى للأدمن إلا أيام
-- الهدية — وهي وحدها التي لا يعرفها أحد غيره.
create or replace function bot_engagement_from_issue(
  p_telegram_id bigint,
  p_issue_id    uuid,
  p_bonus_days  int default 0,
  p_hours       int default 72
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin   bot_admins;
  v_issue   bot_issues;
  v_variant bot_variants;
  v_product bot_products;
  v_dur     jsonb;
  v_months  int;
  v_days    int;
  v_bonus   int;
  v_start   timestamptz;
  v_cert    bot_certificates;
  v_token   text;
begin
  v_admin := bot_actor(p_telegram_id);

  select * into v_issue from bot_issues where id = p_issue_id for update;
  if not found then raise exception 'ISSUE_NOT_FOUND'; end if;
  if v_issue.admin_id <> v_admin.id and v_admin.role <> 'owner' then
    raise exception 'NOT_YOUR_ISSUE';
  end if;
  -- وثيقة التزام لبيعة لم تتمّ وعدٌ بما قد يُلغى بعد دقيقة
  if v_issue.status <> 'confirmed' then
    raise exception 'ISSUE_NOT_CONFIRMED:%', v_issue.status;
  end if;
  if exists (select 1 from bot_certificates where issue_id = p_issue_id) then
    raise exception 'CERTIFICATE_EXISTS';
  end if;

  select * into v_variant from bot_variants where id = v_issue.variant_id;
  select * into v_product from bot_products where id = v_variant.product_id;

  -- المنصة: لقطة البيعة لا قائمة المنتج. الوثيقة تقول للزبون
  -- منصةً بعينها، فإن لم تُحدَّد بعدُ فالبوت يسأل ثم يعيد النداء.
  if v_issue.platform is null then raise exception 'PLATFORM_REQUIRED'; end if;

  v_dur := bot_duration_to_engagement(v_variant.duration_value, v_variant.duration_unit);
  v_months := nullif(v_dur->>'months', '')::int;
  v_days   := nullif(v_dur->>'days',   '')::int;
  if v_months is null and v_days is null then raise exception 'DURATION_MISSING'; end if;

  v_bonus := coalesce(p_bonus_days, 0);
  if v_bonus < 0 or v_bonus > 90 then raise exception 'INVALID_BONUS'; end if;

  -- يوم البيع، لا يوم التعبئة ولا يوم النداء: بائع يصدر الوثيقة
  -- بعد ساعة من البيعة لا يزيح بدايتها ساعة.
  v_start := coalesce(v_issue.settled_at, now());

  insert into bot_certificates
    (code, ref_code, issue_id, platform, months, duration_days, bonus_days,
     starts_at, ends_at, issued_by, customer, filled_at)
  values
    (bot_engagement_code(), bot_engagement_ref(), p_issue_id, v_issue.platform,
     v_months, v_days, v_bonus,
     v_start, bot_engagement_expiry(v_start, v_months, v_bonus, v_days),
     v_admin.id, '[]'::jsonb, null)
  returning * into v_cert;

  v_token := replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '');

  insert into bot_fill_tokens (token, certificate_id, created_by, expires_at)
  values (v_token, v_cert.id, v_admin.id,
          now() + make_interval(hours => greatest(1, least(coalesce(p_hours, 72), 720))));

  return jsonb_build_object(
    'code',        v_cert.code,
    'ref_code',    v_cert.ref_code,
    'token',       v_token,
    'issue_id',    p_issue_id,
    'platform',    v_cert.platform,
    'product_name', v_product.name,
    'variant_name', v_variant.name,
    'months',      v_cert.months,
    'duration_days', v_cert.duration_days,
    'bonus_days',  v_cert.bonus_days,
    'starts_at',   v_cert.starts_at,
    'ends_at',     v_cert.ends_at,
    'expires_at',  now() + make_interval(hours => coalesce(p_hours, 72))
  );
end $$;

-- ------------------------------------------------------------
-- 4. الفلو اليدوي يثبّت بدايته كذلك
-- ------------------------------------------------------------
-- /warranty للحالات الخاصة: بيعة قديمة، أو بيعة خارج البوت.
-- بدايتها لحظة إصدارها — وهي أقرب ما يُعرف عنها.
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
  if v_st.months   is null then raise exception 'MONTHS_MISSING';   end if;

  v_start := now();

  insert into bot_certificates
    (code, ref_code, platform, months, bonus_days, starts_at, ends_at,
     issued_by, customer, filled_at)
  values
    (bot_engagement_code(), bot_engagement_ref(), v_st.platform, v_st.months,
     coalesce(v_st.bonus_days, 0), v_start,
     bot_engagement_expiry(v_start, v_st.months, coalesce(v_st.bonus_days, 0), null),
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
    'bonus_days', v_cert.bonus_days,
    'starts_at', v_cert.starts_at, 'ends_at', v_cert.ends_at,
    'expires_at', now() + make_interval(hours => coalesce(p_hours, 72))
  );
end $$;

-- ------------------------------------------------------------
-- 5. التعبئة: بيانات الزبون وحدها
-- ------------------------------------------------------------
-- لم تعد تحسب تواريخ. التواريخ ثُبّتت يوم البيع، ولا يملك الزبون
-- أن يزيحها بأن يتأخّر في التعبئة.
create or replace function bot_engagement_claim(
  p_token     text,
  p_name      text,
  p_whatsapp  text,
  p_instagram text default null,
  p_ip        text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tok bot_fill_tokens; v_cert bot_certificates;
  v_name text; v_phone text; v_insta text; v_start timestamptz;
begin
  -- لا حدّ هنا: bot_claim_guard تُنادى قبلها في معاملة مستقلة،
  -- وإلا محا فشلُ هذه الدالة عدّادَ محاولاتها.
  select * into v_tok from bot_fill_tokens
   where token = btrim(coalesce(p_token, '')) for update;
  if not found or v_tok.certificate_id is null then raise exception 'LINK_NOT_FOUND'; end if;
  if v_tok.used_at is not null then raise exception 'LINK_USED'; end if;
  if v_tok.expires_at <= now() then raise exception 'LINK_EXPIRED'; end if;

  select * into v_cert from bot_certificates where id = v_tok.certificate_id for update;
  if v_cert.revoked_at is not null then raise exception 'CERTIFICATE_REVOKED'; end if;
  if v_cert.filled_at is not null then raise exception 'ALREADY_CLAIMED'; end if;

  v_name := btrim(coalesce(p_name, ''));
  if char_length(v_name) < 3 or char_length(v_name) > 80 then raise exception 'INVALID_NAME'; end if;

  v_phone := bot_dz_phone(p_whatsapp);
  if v_phone is null then raise exception 'INVALID_PHONE'; end if;

  v_insta := nullif(regexp_replace(btrim(coalesce(p_instagram, '')), '^@+', ''), '');
  if v_insta is not null then
    if char_length(v_insta) > 40 then raise exception 'INVALID_INSTAGRAM'; end if;
    if v_insta !~ '^[A-Za-z0-9._]+$' then raise exception 'INVALID_INSTAGRAM'; end if;
  end if;

  -- وثيقة أُصدرت قبل 029 لا بداية لها؛ تُثبَّت الآن بالحساب
  -- الكامل (الأشهر والأيام والهدية) لا بالناقص الذي كان.
  v_start := coalesce(v_cert.starts_at, now());

  update bot_certificates
     set holder_name = v_name,
         whatsapp    = v_phone,
         instagram   = v_insta,
         filled_at   = now(),
         starts_at   = v_start,
         ends_at     = coalesce(
                         v_cert.ends_at,
                         bot_engagement_expiry(v_start, v_cert.months,
                                               v_cert.bonus_days, v_cert.duration_days))
   where id = v_cert.id
  returning * into v_cert;

  update bot_fill_tokens set used_at = now() where token = v_tok.token;

  return jsonb_build_object(
    'code', v_cert.code, 'ref_code', v_cert.ref_code,
    'issued_by_telegram_id',
      (select telegram_id from bot_admins where id = v_cert.issued_by)
  );
end $$;

-- ------------------------------------------------------------
-- 6. القراءة والإبطال يتبعان علامة التعبئة
-- ------------------------------------------------------------
-- الوثيقة لا تُعرض قبل أن يعبّئ صاحبها: بلا اسم لا تُثبت شيئاً،
-- ولو صارت تواريخها معروفة.
create or replace function bot_engagement_public(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_cert bot_certificates;
begin
  if p_code is null or char_length(btrim(p_code)) < 8 then
    raise exception 'CERTIFICATE_NOT_FOUND';
  end if;
  -- الحدّ في bot_read_guard، لنفس سبب bot_claim_guard أعلاه
  select * into v_cert from bot_certificates where code = upper(btrim(p_code));
  if not found then raise exception 'CERTIFICATE_NOT_FOUND'; end if;
  if v_cert.filled_at is null then raise exception 'CERTIFICATE_PENDING'; end if;

  return jsonb_build_object(
    'code',        v_cert.code,
    'ref_code',    v_cert.ref_code,
    'holder_name', v_cert.holder_name,
    'instagram',   v_cert.instagram,
    'platform',    v_cert.platform,
    'months',      v_cert.months,
    'duration_days', v_cert.duration_days,
    'bonus_days',  v_cert.bonus_days,
    'starts_at',   v_cert.starts_at,
    'ends_at',     v_cert.ends_at,
    'status',      bot_engagement_status(v_cert),
    'days_left',   case when v_cert.ends_at is null then null
                        else greatest(0, (date_part('day', v_cert.ends_at - now()))::int) end
  );
end $$;

create or replace function bot_engagement_verify(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_cert bot_certificates;
begin
  select * into v_cert from bot_certificates
   where code = upper(btrim(coalesce(p_code, '')));
  if not found or v_cert.filled_at is null then
    return jsonb_build_object('found', false);
  end if;

  return jsonb_build_object(
    'found',      true,
    'code',       v_cert.code,
    'platform',   v_cert.platform,
    'ends_at',    v_cert.ends_at,
    'status',     bot_engagement_status(v_cert),
    -- الاسم مختصر: يكفي صاحبه ليتعرّف، ولا يكشفه لغيره
    'holder_hint', case when v_cert.holder_name is null then null
                        else left(v_cert.holder_name, 1) || '***' end
  );
end $$;

create or replace function bot_engagement_relink(
  p_telegram_id bigint, p_code text, p_hours int default 72
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin bot_admins; v_cert bot_certificates; v_token text;
begin
  v_admin := bot_actor(p_telegram_id);
  select * into v_cert from bot_certificates
   where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then raise exception 'CERTIFICATE_NOT_FOUND'; end if;
  if v_admin.role <> 'owner' and v_cert.issued_by is distinct from v_admin.id then
    raise exception 'NOT_YOUR_ISSUE';
  end if;
  if v_cert.revoked_at is not null then raise exception 'CERTIFICATE_REVOKED'; end if;
  if v_cert.filled_at is not null then raise exception 'ALREADY_CLAIMED'; end if;

  delete from bot_fill_tokens where certificate_id = v_cert.id;
  v_token := replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '');
  insert into bot_fill_tokens (token, certificate_id, created_by, expires_at)
  values (v_token, v_cert.id, v_admin.id,
          now() + make_interval(hours => greatest(1, least(coalesce(p_hours, 72), 720))));

  return jsonb_build_object(
    'code', v_cert.code, 'token', v_token,
    'expires_at', now() + make_interval(hours => coalesce(p_hours, 72))
  );
end $$;

-- ------------------------------------------------------------
-- 7. حالة البيعة بالنسبة للوثيقة
-- ------------------------------------------------------------
-- يسألها البوت بعد التأكيد ليعرف: أيسأل عن المنصة؟ عن المدة؟ أم
-- يكفيه أن يسأل عن الهدية ثم يولّد الرابط؟
create or replace function bot_issue_engagement(p_telegram_id bigint, p_issue_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_admin bot_admins; v_issue bot_issues;
  v_variant bot_variants; v_product bot_products;
  v_dur jsonb; v_cert bot_certificates;
begin
  v_admin := bot_actor(p_telegram_id);

  select * into v_issue from bot_issues where id = p_issue_id;
  if not found then raise exception 'ISSUE_NOT_FOUND'; end if;
  if v_issue.admin_id <> v_admin.id and v_admin.role <> 'owner' then
    raise exception 'NOT_YOUR_ISSUE';
  end if;

  select * into v_variant from bot_variants where id = v_issue.variant_id;
  select * into v_product from bot_products where id = v_variant.product_id;
  v_dur := bot_duration_to_engagement(v_variant.duration_value, v_variant.duration_unit);
  select * into v_cert from bot_certificates where issue_id = p_issue_id;

  return jsonb_build_object(
    'issue_id',     p_issue_id,
    'status',       v_issue.status,
    'product_name', v_product.name,
    'variant_name', v_variant.name,
    'platform',     v_issue.platform,
    'platforms',    bot_product_platforms_list(p_telegram_id, v_product.id),
    'months',       v_dur->'months',
    'days',         v_dur->'days',
    'needs_platform', v_issue.platform is null,
    'needs_duration', v_dur->'months' = 'null'::jsonb and v_dur->'days' = 'null'::jsonb,
    'has_certificate', v_cert.id is not null,
    'certificate_code', v_cert.code,
    -- ما ستكون عليه لو أُصدرت الآن بلا هدية: معاينة قبل السؤال
    'projected_start', coalesce(v_issue.settled_at, now()),
    'projected_end',   case
      when v_dur->'months' = 'null'::jsonb and v_dur->'days' = 'null'::jsonb then null
      else bot_engagement_expiry(
             coalesce(v_issue.settled_at, now()),
             nullif(v_dur->>'months','')::int, 0, nullif(v_dur->>'days','')::int)
      end
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

-- ── 030_bot_catalog_commands.sql ─────────────────────────────────────
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

-- ── 031_bot_terms.sql ─────────────────────────────────────
-- bundle: bot
-- ============================================================
-- Janeiro Store — 031 شروط التغطية: للمالك، ولكل خدمة
--
-- كانت النقاط الخمس مكتوبة في i18n.ts: تبديلها يحتاج نشر
-- الدالة، وهي واحدة لكل الخدمات. وسناب ليس نتفليكس: ما يُغطّى
-- في هذه لا يُغطّى في تلك.
--
-- وفخُّ التخزين وحده: لو قُرئت الشروط من الجدول وقت العرض،
-- لتبدّلت الوثائق التي في أيدي الزبائن بأثر رجعي. زبون التُزم
-- له بشروط، ثم يفتح رابطه فيجد غيرها. وهذه وثيقة التزام — ما
-- وُعد به يبقى.
--
-- فالشروط تُلقَّط على الوثيقة يوم صدورها:
--   الوثيقة القديمة تبقى على وعدها.
--   والجديدة تأخذ الجديد.
--   وما صدر قبل هذه الهجرة (terms فارغ) يقرأ الحيّ ثم المدمج
--   في الكود — فلا وثيقة بلا شروط.
-- ============================================================

-- ------------------------------------------------------------
-- 1. الجدول
-- ------------------------------------------------------------
-- platform فارغ = الشروط العامة، تُستعمل لكل خدمة لم تُفرَد
-- بشروطها. ولغة بلا شروط تسقط إلى العامة ثم إلى المدمج، فلا
-- يُجبَر المالك على كتابة الثلاث دفعةً.
create table if not exists bot_terms (
  id         uuid primary key default gen_random_uuid(),
  platform   text references bot_platforms(name) on update cascade on delete cascade,
  lang       text not null check (lang in ('ar','fr','en')),
  sort_order integer not null,
  body       text not null check (char_length(btrim(body)) between 3 and 400),
  updated_at timestamptz not null default now(),
  unique (platform, lang, sort_order)
);
create index if not exists idx_bot_terms_lookup on bot_terms(platform, lang, sort_order);

alter table bot_terms enable row level security;
revoke all on bot_terms from anon, authenticated;

-- اللقطة على الوثيقة: {"ar":[...],"fr":[...],"en":[...]}
alter table bot_certificates
  add column if not exists terms jsonb;

-- ------------------------------------------------------------
-- 2. القراءة
-- ------------------------------------------------------------
-- الخاصة بالخدمة، وإلّا العامة، وإلّا فارغ — والفراغ يعني
-- «استعمل المدمج في الكود»، لا «بلا شروط».
create or replace function bot_terms_for(p_platform text, p_lang text)
returns text[]
language sql stable set search_path = public as $$
  select coalesce(
    (select array_agg(body order by sort_order) from bot_terms
      where platform = p_platform and lang = p_lang),
    (select array_agg(body order by sort_order) from bot_terms
      where platform is null and lang = p_lang)
  );
$$;

-- اللقطة كاملة باللغات الثلاث، كما تُكتب على الوثيقة.
create or replace function bot_terms_snapshot(p_platform text)
returns jsonb
language sql stable set search_path = public as $$
  select coalesce(jsonb_object_agg(l.lang, to_jsonb(t.lines))
                    filter (where t.lines is not null), '{}'::jsonb)
    from (values ('ar'),('fr'),('en')) as l(lang)
    cross join lateral (select bot_terms_for(p_platform, l.lang) as lines) t;
$$;

create or replace function bot_terms_list(
  p_telegram_id bigint, p_platform text default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_plat text;
begin
  perform bot_owner(p_telegram_id);
  v_plat := nullif(btrim(coalesce(p_platform, '')), '');

  return jsonb_build_object(
    'platform', v_plat,
    -- الخاصة بهذه الخدمة وحدها، بلا سقوط: ليرى المالك ما كتبه هو
    'own', (select coalesce(jsonb_object_agg(x.lang, x.lines), '{}'::jsonb)
              from (select lang, to_jsonb(array_agg(body order by sort_order)) as lines
                      from bot_terms
                     where platform is not distinct from v_plat
                     group by lang) x),
    -- وما سيُطبَّق فعلاً بعد السقوط
    'effective', bot_terms_snapshot(v_plat),
    -- والخدمات التي أُفردت بشروط
    'overridden', (select coalesce(jsonb_agg(distinct platform), '[]'::jsonb)
                     from bot_terms where platform is not null)
  );
end $$;

-- ------------------------------------------------------------
-- 3. الكتابة — للمالك وحده
-- ------------------------------------------------------------
-- استبدال كامل لا إضافة: الشروط تُقرأ كمجموعة، وتحرير سطر
-- بعينه من تليجرام أبواب أخطاء لا تُغلق.
create or replace function bot_set_terms(
  p_telegram_id bigint, p_platform text, p_lang text, p_lines text[]
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_plat text; v_line text; v_n int := 0;
begin
  perform bot_owner(p_telegram_id);

  if p_lang not in ('ar','fr','en') then raise exception 'INVALID_LANG'; end if;
  v_plat := nullif(btrim(coalesce(p_platform, '')), '');
  if v_plat is not null
     and not exists (select 1 from bot_platforms where name = v_plat) then
    raise exception 'PLATFORM_NOT_FOUND';
  end if;

  delete from bot_terms
   where platform is not distinct from v_plat and lang = p_lang;

  foreach v_line in array coalesce(p_lines, array[]::text[]) loop
    continue when btrim(v_line) = '';
    if char_length(btrim(v_line)) > 400 then raise exception 'LINE_TOO_LONG'; end if;
    v_n := v_n + 1;
    if v_n > 12 then raise exception 'TOO_MANY_LINES'; end if;
    insert into bot_terms (platform, lang, sort_order, body)
    values (v_plat, p_lang, v_n * 10, btrim(v_line));
  end loop;

  return jsonb_build_object(
    'platform', v_plat, 'lang', p_lang, 'count', v_n,
    'effective', bot_terms_snapshot(v_plat)
  );
end $$;

-- ------------------------------------------------------------
-- 4. اللقطة عند الإصدار
-- ------------------------------------------------------------
create or replace function bot_engagement_from_issue(
  p_telegram_id bigint,
  p_issue_id    uuid,
  p_bonus_days  int default 0,
  p_hours       int default 72
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin   bot_admins;
  v_issue   bot_issues;
  v_variant bot_variants;
  v_product bot_products;
  v_dur     jsonb;
  v_months  int;
  v_days    int;
  v_bonus   int;
  v_start   timestamptz;
  v_cert    bot_certificates;
  v_token   text;
begin
  v_admin := bot_actor(p_telegram_id);

  select * into v_issue from bot_issues where id = p_issue_id for update;
  if not found then raise exception 'ISSUE_NOT_FOUND'; end if;
  if v_issue.admin_id <> v_admin.id and v_admin.role <> 'owner' then
    raise exception 'NOT_YOUR_ISSUE';
  end if;
  if v_issue.status <> 'confirmed' then
    raise exception 'ISSUE_NOT_CONFIRMED:%', v_issue.status;
  end if;
  if exists (select 1 from bot_certificates where issue_id = p_issue_id) then
    raise exception 'CERTIFICATE_EXISTS';
  end if;

  select * into v_variant from bot_variants where id = v_issue.variant_id;
  select * into v_product from bot_products where id = v_variant.product_id;

  if v_issue.platform is null then raise exception 'PLATFORM_REQUIRED'; end if;

  v_dur := bot_duration_to_engagement(v_variant.duration_value, v_variant.duration_unit);
  v_months := nullif(v_dur->>'months', '')::int;
  v_days   := nullif(v_dur->>'days',   '')::int;
  if v_months is null and v_days is null then raise exception 'DURATION_MISSING'; end if;

  v_bonus := coalesce(p_bonus_days, 0);
  if v_bonus < 0 or v_bonus > 90 then raise exception 'INVALID_BONUS'; end if;

  v_start := coalesce(v_issue.settled_at, now());

  insert into bot_certificates
    (code, ref_code, issue_id, platform, months, duration_days, bonus_days,
     starts_at, ends_at, issued_by, customer, filled_at, terms)
  values
    (bot_engagement_code(), bot_engagement_ref(), p_issue_id, v_issue.platform,
     v_months, v_days, v_bonus,
     v_start, bot_engagement_expiry(v_start, v_months, v_bonus, v_days),
     v_admin.id, '[]'::jsonb, null,
     bot_terms_snapshot(v_issue.platform))
  returning * into v_cert;

  v_token := replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '');

  insert into bot_fill_tokens (token, certificate_id, created_by, expires_at)
  values (v_token, v_cert.id, v_admin.id,
          now() + make_interval(hours => greatest(1, least(coalesce(p_hours, 72), 720))));

  return jsonb_build_object(
    'code',        v_cert.code,
    'ref_code',    v_cert.ref_code,
    'token',       v_token,
    'issue_id',    p_issue_id,
    'platform',    v_cert.platform,
    'product_name', v_product.name,
    'variant_name', v_variant.name,
    'months',      v_cert.months,
    'duration_days', v_cert.duration_days,
    'bonus_days',  v_cert.bonus_days,
    'starts_at',   v_cert.starts_at,
    'ends_at',     v_cert.ends_at,
    'expires_at',  now() + make_interval(hours => coalesce(p_hours, 72))
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
     starts_at, ends_at, issued_by, customer, filled_at, terms)
  values
    (bot_engagement_code(), bot_engagement_ref(), v_st.platform,
     v_st.months, v_st.duration_days, coalesce(v_st.bonus_days, 0), v_start,
     bot_engagement_expiry(v_start, v_st.months,
                           coalesce(v_st.bonus_days, 0), v_st.duration_days),
     v_admin.id, '[]'::jsonb, null, bot_terms_snapshot(v_st.platform))
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

-- ------------------------------------------------------------
-- 5. القراءة العامة تحمل شروطها
-- ------------------------------------------------------------
-- لقطة الوثيقة أولاً. وإن كانت فارغة (وثيقة صدرت قبل 031)
-- فالحيّ، وإن لم يكن فالمدمج في الكود — تقرّره الصفحة.
create or replace function bot_engagement_public(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_cert bot_certificates; v_terms jsonb;
begin
  if p_code is null or char_length(btrim(p_code)) < 8 then
    raise exception 'CERTIFICATE_NOT_FOUND';
  end if;
  select * into v_cert from bot_certificates where code = upper(btrim(p_code));
  if not found then raise exception 'CERTIFICATE_NOT_FOUND'; end if;
  if v_cert.filled_at is null then raise exception 'CERTIFICATE_PENDING'; end if;

  v_terms := case
    when v_cert.terms is not null and v_cert.terms <> '{}'::jsonb then v_cert.terms
    else bot_terms_snapshot(v_cert.platform) end;

  return jsonb_build_object(
    'code',        v_cert.code,
    'ref_code',    v_cert.ref_code,
    'holder_name', v_cert.holder_name,
    'instagram',   v_cert.instagram,
    'platform',    v_cert.platform,
    'months',      v_cert.months,
    'duration_days', v_cert.duration_days,
    'bonus_days',  v_cert.bonus_days,
    'starts_at',   v_cert.starts_at,
    'ends_at',     v_cert.ends_at,
    'status',      bot_engagement_status(v_cert),
    'terms',       v_terms,
    'days_left',   case when v_cert.ends_at is null then null
                        else greatest(0, (date_part('day', v_cert.ends_at - now()))::int) end
  );
end $$;

-- ------------------------------------------------------------
-- 6. أمر البوت بالرمز النصّي
-- ------------------------------------------------------------
create or replace function bot_cmd_terms(
  p_telegram_id bigint, p_platform text, p_lang text, p_lines text[]
) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform bot_owner(p_telegram_id);
  -- «-» تعني الشروط العامة: أسهل من خانة فارغة في سطر أمر
  return bot_set_terms(p_telegram_id,
    case when btrim(coalesce(p_platform, '')) in ('', '-') then null else p_platform end,
    p_lang, p_lines);
end $$;

-- ============================================================
-- 7. الصلاحيات — service_role وحده، كما في 021.
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

-- ── 032_instagram_required.sql ─────────────────────────────────────
-- bundle: bot
-- ============================================================
-- Janeiro Store — 032 يوزر الإنستغرام مطلوب
--
-- كان اختيارياً. وهو الحقل الذي يُعرف به الحساب المفعَّل: بلاه
-- تقول الوثيقة «هذا الاشتراك لك» ولا تقول على أي حساب. والبائع
-- لا يملك إصلاح ذلك بعد أن يعبّئ الزبون ويُستهلك الرابط.
--
-- الوثائق الصادرة قبل هذا لا تتأثّر: الشرط على التعبئة الجديدة
-- وحدها، ولا قيد على العمود.
-- ============================================================

create or replace function bot_engagement_claim(
  p_token     text,
  p_name      text,
  p_whatsapp  text,
  p_instagram text default null,
  p_ip        text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tok bot_fill_tokens; v_cert bot_certificates;
  v_name text; v_phone text; v_insta text; v_start timestamptz;
begin
  -- لا حدّ هنا: bot_claim_guard تُنادى قبلها في معاملة مستقلة،
  -- وإلا محا فشلُ هذه الدالة عدّادَ محاولاتها.
  select * into v_tok from bot_fill_tokens
   where token = btrim(coalesce(p_token, '')) for update;
  if not found or v_tok.certificate_id is null then raise exception 'LINK_NOT_FOUND'; end if;
  if v_tok.used_at is not null then raise exception 'LINK_USED'; end if;
  if v_tok.expires_at <= now() then raise exception 'LINK_EXPIRED'; end if;

  select * into v_cert from bot_certificates where id = v_tok.certificate_id for update;
  if v_cert.revoked_at is not null then raise exception 'CERTIFICATE_REVOKED'; end if;
  if v_cert.filled_at is not null then raise exception 'ALREADY_CLAIMED'; end if;

  v_name := btrim(coalesce(p_name, ''));
  if char_length(v_name) < 3 or char_length(v_name) > 80 then raise exception 'INVALID_NAME'; end if;

  v_phone := bot_dz_phone(p_whatsapp);
  if v_phone is null then raise exception 'INVALID_PHONE'; end if;

  -- مطلوب: به يُعرف الحساب المفعَّل، وبلاه لا تقول الوثيقة على
  -- أيّ حساب هذا الاشتراك.
  v_insta := nullif(regexp_replace(btrim(coalesce(p_instagram, '')), '^@+', ''), '');
  if v_insta is null then raise exception 'INVALID_INSTAGRAM'; end if;
  if char_length(v_insta) > 40 then raise exception 'INVALID_INSTAGRAM'; end if;
  if v_insta !~ '^[A-Za-z0-9._]+$' then raise exception 'INVALID_INSTAGRAM'; end if;

  -- وثيقة أُصدرت قبل 029 لا بداية لها؛ تُثبَّت الآن بالحساب
  -- الكامل (الأشهر والأيام والهدية) لا بالناقص الذي كان.
  v_start := coalesce(v_cert.starts_at, now());

  update bot_certificates
     set holder_name = v_name,
         whatsapp    = v_phone,
         instagram   = v_insta,
         filled_at   = now(),
         starts_at   = v_start,
         ends_at     = coalesce(
                         v_cert.ends_at,
                         bot_engagement_expiry(v_start, v_cert.months,
                                               v_cert.bonus_days, v_cert.duration_days))
   where id = v_cert.id
  returning * into v_cert;

  update bot_fill_tokens set used_at = now() where token = v_tok.token;

  return jsonb_build_object(
    'code', v_cert.code, 'ref_code', v_cert.ref_code,
    'issued_by_telegram_id',
      (select telegram_id from bot_admins where id = v_cert.issued_by)
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

-- ── 033_claim_fields.sql ─────────────────────────────────────
-- bundle: bot
-- ============================================================
-- Janeiro Store — 033 الاسم واليوزر مطلوبان، والرقم اختياري
--
-- الاسم واليوزر هما ما تقوم عليه الوثيقة: لمن هي، وعلى أيّ
-- حساب. والرقم وسيلة تواصل، والزبون يُوجَد بيوزره كما يُوجَد
-- برقمه — فلا يُحتجز الإصدار عليه.
--
-- والرقم إن أُعطي يُتحقَّق منه كما كان: اختياريٌّ لا يعني مقبولاً
-- على أيّ صورة.
--
-- الوثائق الصادرة لا تتأثّر: الشرط على التعبئة الجديدة وحدها.
-- ============================================================

create or replace function bot_engagement_claim(
  p_token     text,
  p_name      text,
  p_whatsapp  text,
  p_instagram text default null,
  p_ip        text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tok bot_fill_tokens; v_cert bot_certificates;
  v_name text; v_phone text; v_insta text; v_start timestamptz;
begin
  -- لا حدّ هنا: bot_claim_guard تُنادى قبلها في معاملة مستقلة،
  -- وإلا محا فشلُ هذه الدالة عدّادَ محاولاتها.
  select * into v_tok from bot_fill_tokens
   where token = btrim(coalesce(p_token, '')) for update;
  if not found or v_tok.certificate_id is null then raise exception 'LINK_NOT_FOUND'; end if;
  if v_tok.used_at is not null then raise exception 'LINK_USED'; end if;
  if v_tok.expires_at <= now() then raise exception 'LINK_EXPIRED'; end if;

  select * into v_cert from bot_certificates where id = v_tok.certificate_id for update;
  if v_cert.revoked_at is not null then raise exception 'CERTIFICATE_REVOKED'; end if;
  if v_cert.filled_at is not null then raise exception 'ALREADY_CLAIMED'; end if;

  -- مطلوب: وثيقة بلا صاحب لا تُثبت شيئاً
  v_name := btrim(coalesce(p_name, ''));
  if char_length(v_name) < 3 or char_length(v_name) > 80 then raise exception 'INVALID_NAME'; end if;

  -- مطلوب: به يُعرف الحساب المفعَّل
  v_insta := nullif(regexp_replace(btrim(coalesce(p_instagram, '')), '^@+', ''), '');
  if v_insta is null then raise exception 'INVALID_INSTAGRAM'; end if;
  if char_length(v_insta) > 40 then raise exception 'INVALID_INSTAGRAM'; end if;
  if v_insta !~ '^[A-Za-z0-9._]+$' then raise exception 'INVALID_INSTAGRAM'; end if;

  -- اختياري. وإن أُعطي فبصورة صحيحة: اختياريٌّ لا يعني مقبولاً
  -- على أيّ صورة، ورقمٌ مكسور أسوأ من لا رقم.
  if nullif(btrim(coalesce(p_whatsapp, '')), '') is null then
    v_phone := null;
  else
    v_phone := bot_dz_phone(p_whatsapp);
    if v_phone is null then raise exception 'INVALID_PHONE'; end if;
  end if;

  -- وثيقة أُصدرت قبل 029 لا بداية لها؛ تُثبَّت الآن بالحساب
  -- الكامل (الأشهر والأيام والهدية) لا بالناقص الذي كان.
  v_start := coalesce(v_cert.starts_at, now());

  update bot_certificates
     set holder_name = v_name,
         whatsapp    = v_phone,
         instagram   = v_insta,
         filled_at   = now(),
         starts_at   = v_start,
         ends_at     = coalesce(
                         v_cert.ends_at,
                         bot_engagement_expiry(v_start, v_cert.months,
                                               v_cert.bonus_days, v_cert.duration_days))
   where id = v_cert.id
  returning * into v_cert;

  update bot_fill_tokens set used_at = now() where token = v_tok.token;

  return jsonb_build_object(
    'code', v_cert.code, 'ref_code', v_cert.ref_code,
    'issued_by_telegram_id',
      (select telegram_id from bot_admins where id = v_cert.issued_by)
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

