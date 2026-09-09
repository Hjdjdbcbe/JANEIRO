-- ============================================================
-- Janeiro — بوت المخزون وحده. وُلِّد آلياً، لا تُعدّله يدوياً.
-- المصدر: supabase/migrations/001_core_schema.sql + supabase/migrations/021_gift_card_bot.sql supabase/migrations/022_bot_sales_detail.sql
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

