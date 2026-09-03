-- ============================================================
-- Janeiro Store — كل الهجرات مدمجة، وُلِّدت آلياً.
-- المصدر: supabase/migrations/*.sql — لا تُعدّل هذا الملف يدوياً.
-- الصقه كاملاً في Supabase SQL Editor واضغط Run، مرة واحدة.
-- ============================================================

-- ── 001_core_schema.sql ──────────────────────────────────────
-- ============================================================
-- Janeiro Store — 001 core schema
-- enums, profiles (admin foundation), categories,
-- payment methods, store settings
-- ============================================================

create extension if not exists "pgcrypto";

-- ---------- enums ----------
do $$ begin
  create type product_status as enum
    ('published','temporarily_unavailable','coming_soon','draft','hidden','archived');
exception when duplicate_object then null; end $$;

do $$ begin
  create type order_status as enum
    ('awaiting_receipt','pending_payment_review','payment_confirmed',
     'activating','needs_info','completed','cancelled','refunded');
exception when duplicate_object then null; end $$;

do $$ begin
  create type warranty_type as enum
    ('none','activation','days','subscription_duration','custom');
exception when duplicate_object then null; end $$;

do $$ begin
  create type requirement_field_type as enum
    ('email','phone','username','text','number','account_id','custom');
exception when duplicate_object then null; end $$;

do $$ begin
  create type payment_method_type as enum ('ccp','baridimob','flexy');
exception when duplicate_object then null; end $$;

do $$ begin
  create type image_type as enum ('poster','thumbnail','gallery');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app_role as enum ('admin','staff');
exception when duplicate_object then null; end $$;

-- ---------- shared updated_at trigger ----------
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- ---------- profiles (admin foundation) ----------
create table if not exists profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  role        app_role not null default 'staff',
  full_name   text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
drop trigger if exists trg_profiles_updated on profiles;
create trigger trg_profiles_updated before update on profiles
  for each row execute function set_updated_at();

-- helper used by every admin policy. SECURITY DEFINER so it can read
-- profiles without tripping the policies defined on profiles itself.
create or replace function is_admin()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

-- ---------- categories ----------
create table if not exists categories (
  id           uuid primary key default gen_random_uuid(),
  name         text not null check (char_length(name) between 1 and 80),
  slug         text not null unique check (char_length(slug) between 1 and 80),
  icon         text,
  accent_color text check (accent_color ~ '^#[0-9A-Fa-f]{6}$'),
  description  text check (char_length(description) <= 400),
  is_active    boolean not null default true,
  sort_order   integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists idx_categories_active on categories(is_active, sort_order);
drop trigger if exists trg_categories_updated on categories;
create trigger trg_categories_updated before update on categories
  for each row execute function set_updated_at();

-- ---------- payment methods ----------
create table if not exists payment_methods (
  id             uuid primary key default gen_random_uuid(),
  type           payment_method_type not null,
  label          text not null check (char_length(label) between 1 and 60),
  account_holder text check (char_length(account_holder) <= 120),
  account_number text check (char_length(account_number) <= 60),
  extra_info     text check (char_length(extra_info) <= 200),
  instructions   text check (char_length(instructions) <= 600),
  is_active      boolean not null default true,
  sort_order     integer not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists idx_payment_active on payment_methods(is_active, sort_order);
-- One row per method type. Without this the seed's ON CONFLICT has no
-- arbiter to match and a re-run silently duplicates every method.
do $$ begin
  alter table payment_methods add constraint payment_methods_type_key unique (type);
exception when duplicate_table or duplicate_object then null; end $$;
drop trigger if exists trg_payment_updated on payment_methods;
create trigger trg_payment_updated before update on payment_methods
  for each row execute function set_updated_at();

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

insert into store_settings (key, value, is_public) values
  ('store_name',         'Janeiro Store', true),
  ('currency',           'دج',            true),
  ('whatsapp_number',    '',              true),   -- e.g. 213XXXXXXXXX (no +)
  ('instagram_username', 'janeiro_service', true),
  ('telegram_username',  '',              true),
  ('support_hours',      'يومياً من 9ص إلى 11م', true),
  ('support_message',    'نرد عادة خلال وقت قصير.', true),
  ('receipt_max_size',   '5242880',       true),   -- 5 MB
  ('max_active_orders',  '2',             true)
on conflict (key) do nothing;

-- ── 002_products.sql ──────────────────────────────────────
-- ============================================================
-- Janeiro Store — 002 products
-- ============================================================

create table if not exists products (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null check (char_length(name) between 1 and 120),
  slug                text not null unique check (char_length(slug) between 1 and 120),
  category_id         uuid references categories(id) on delete restrict,
  short_description   text check (char_length(short_description) <= 200),
  description         text check (char_length(description) <= 4000),

  poster_path         text,
  thumbnail_path      text,
  accent_color        text check (accent_color ~ '^#[0-9A-Fa-f]{6}$'),

  -- how the product is activated (informational, drives copy)
  activation_type     text check (char_length(activation_type) <= 40),
  activation_label    text check (char_length(activation_label) <= 120),

  -- delivery window
  delivery_type       text check (char_length(delivery_type) <= 40),
  delivery_min        integer check (delivery_min is null or delivery_min >= 0),
  delivery_max        integer check (delivery_max is null or delivery_max >= 0),
  delivery_unit       text check (delivery_unit in ('minutes','hours','days') or delivery_unit is null),
  delivery_label      text check (char_length(delivery_label) <= 120),

  -- structured warranty
  warranty_type        warranty_type not null default 'none',
  warranty_days        integer check (warranty_days is null or warranty_days > 0),
  warranty_label       text check (char_length(warranty_label) <= 120),
  warranty_description text check (char_length(warranty_description) <= 1000),
  warranty_covers      text[],
  warranty_exclusions  text[],

  badge_type          text check (badge_type in ('hot','new','off') or badge_type is null),
  badge_label         text check (char_length(badge_label) <= 40),

  status              product_status not null default 'draft',
  sort_order          integer not null default 0,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  archived_at         timestamptz,

  constraint delivery_range_ok
    check (delivery_min is null or delivery_max is null or delivery_max >= delivery_min),
  -- 'days' warranty must carry a day count; 'custom' must carry a label
  constraint warranty_shape_ok check (
    (warranty_type <> 'days'   or warranty_days is not null) and
    (warranty_type <> 'custom' or warranty_label is not null)
  )
);
create index if not exists idx_products_status   on products(status, sort_order);
create index if not exists idx_products_category on products(category_id);
drop trigger if exists trg_products_updated on products;
create trigger trg_products_updated before update on products
  for each row execute function set_updated_at();

-- ---------- plans ----------
create table if not exists product_plans (
  id             uuid primary key default gen_random_uuid(),
  product_id     uuid not null references products(id) on delete cascade,
  name           text not null check (char_length(name) between 1 and 80),
  duration_value integer check (duration_value is null or duration_value > 0),
  duration_unit  text check (duration_unit in ('day','week','month','year') or duration_unit is null),
  price          numeric(12,2) not null check (price >= 0),
  old_price      numeric(12,2) check (old_price is null or old_price >= 0),
  is_active      boolean not null default true,
  sort_order     integer not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint old_price_higher check (old_price is null or old_price > price)
);
create index if not exists idx_plans_product on product_plans(product_id, is_active, sort_order);
drop trigger if exists trg_plans_updated on product_plans;
create trigger trg_plans_updated before update on product_plans
  for each row execute function set_updated_at();

-- ---------- features ----------
create table if not exists product_features (
  id         uuid primary key default gen_random_uuid(),
  product_id uuid not null references products(id) on delete cascade,
  label      text not null check (char_length(label) between 1 and 200),
  sort_order integer not null default 0
);
create index if not exists idx_features_product on product_features(product_id, sort_order);

-- ---------- activation requirements ----------
create table if not exists product_requirements (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid not null references products(id) on delete cascade,
  label       text not null check (char_length(label) between 1 and 120),
  field_type  requirement_field_type not null default 'text',
  placeholder text check (char_length(placeholder) <= 120),
  is_required boolean not null default true,
  sort_order  integer not null default 0,
  -- guardrail: we never collect account passwords
  constraint no_password_field check (
    label !~* '(password|كلمة السر|كلمة المرور|mot de passe)'
  )
);
create index if not exists idx_reqs_product on product_requirements(product_id, sort_order);

-- ---------- images ----------
create table if not exists product_images (
  id           uuid primary key default gen_random_uuid(),
  product_id   uuid not null references products(id) on delete cascade,
  storage_path text not null,
  image_type   image_type not null default 'gallery',
  sort_order   integer not null default 0,
  created_at   timestamptz not null default now()
);
create index if not exists idx_images_product on product_images(product_id, image_type, sort_order);

-- ---------- public read view ----------
-- Frontend reads this instead of joining by hand; it also guarantees
-- that only purchasable/visible products ever leave the database.
-- DROP then CREATE, not CREATE OR REPLACE. A later migration extends this
-- view (013 adds icon_path), and CREATE OR REPLACE cannot remove a column
-- that a later migration added -- so on the second pass of the migration
-- runner this file would fail with "cannot drop columns from view" and the
-- idempotency check would break. Dropping first makes the order of passes
-- irrelevant. Nothing depends on this view, and 005 re-grants it.
drop view if exists public_products;
create view public_products as
select
  p.id, p.name, p.slug, p.short_description, p.description,
  p.poster_path, p.thumbnail_path, p.accent_color,
  p.activation_type, p.activation_label,
  p.delivery_min, p.delivery_max, p.delivery_unit, p.delivery_label,
  p.warranty_type, p.warranty_days, p.warranty_label, p.warranty_description,
  p.warranty_covers, p.warranty_exclusions,
  p.badge_type, p.badge_label, p.status, p.sort_order,
  c.slug as category_slug, c.name as category_name, c.accent_color as category_accent
from products p
left join categories c on c.id = p.category_id
where p.status in ('published','temporarily_unavailable','coming_soon')
  and p.archived_at is null;

-- ── 003_orders.sql ──────────────────────────────────────
-- ============================================================
-- Janeiro Store — 003 orders
-- ============================================================

create table if not exists orders (
  id                 uuid primary key default gen_random_uuid(),
  order_number       text not null unique,

  customer_name      text not null check (char_length(customer_name) between 2 and 80),
  customer_phone     text not null check (char_length(customer_phone) between 6 and 20),
  normalized_phone   text not null check (normalized_phone ~ '^213[5-7][0-9]{8}$'),
  customer_wilaya    text check (char_length(customer_wilaya) <= 60),

  payment_method_id  uuid references payment_methods(id) on delete restrict,
  payment_reference  text check (char_length(payment_reference) <= 60),

  receipt_path       text,
  receipt_uploaded_at timestamptz,

  subtotal           numeric(12,2) not null default 0 check (subtotal >= 0),
  total              numeric(12,2) not null default 0 check (total >= 0),
  currency           text not null default 'دج',

  status             order_status not null default 'awaiting_receipt',
  idempotency_key    text not null unique check (char_length(idempotency_key) between 8 and 100),

  client_ip          inet,
  submitted_at       timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  -- §27 invariant, enforced at database level:
  -- an order past awaiting_receipt MUST carry a receipt.
  constraint receipt_required_after_submit check (
    status = 'awaiting_receipt'
    or status in ('cancelled')
    or (receipt_path is not null and receipt_uploaded_at is not null)
  ),
  constraint submitted_at_set check (
    status = 'awaiting_receipt' or status = 'cancelled' or submitted_at is not null
  ),
  constraint receipt_pair check (
    (receipt_path is null) = (receipt_uploaded_at is null)
  )
);
create index if not exists idx_orders_phone_status on orders(normalized_phone, status);
create index if not exists idx_orders_status       on orders(status, created_at desc);
create index if not exists idx_orders_number       on orders(order_number);
drop trigger if exists trg_orders_updated on orders;
create trigger trg_orders_updated before update on orders
  for each row execute function set_updated_at();

-- ---------- order items (with snapshots) ----------
create table if not exists order_items (
  id                     uuid primary key default gen_random_uuid(),
  order_id               uuid not null references orders(id) on delete cascade,
  product_id             uuid references products(id) on delete set null,
  plan_id                uuid references product_plans(id) on delete set null,

  product_name_snapshot  text not null,
  plan_name_snapshot     text not null,
  unit_price             numeric(12,2) not null check (unit_price >= 0),
  quantity               integer not null check (quantity between 1 and 10),
  total_price            numeric(12,2) not null check (total_price >= 0),
  warranty_label_snapshot text,
  created_at             timestamptz not null default now()
);
create index if not exists idx_items_order on order_items(order_id);

-- ---------- activation data (private) ----------
create table if not exists order_activation_data (
  id            uuid primary key default gen_random_uuid(),
  order_item_id uuid not null references order_items(id) on delete cascade,
  field_label   text not null check (char_length(field_label) <= 120),
  field_type    requirement_field_type not null default 'text',
  field_value   text not null check (char_length(field_value) between 1 and 300),
  created_at    timestamptz not null default now()
);
create index if not exists idx_activation_item on order_activation_data(order_item_id);

-- ---------- status history ----------
create table if not exists order_status_history (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null references orders(id) on delete cascade,
  old_status order_status,
  new_status order_status not null,
  changed_by uuid references auth.users(id) on delete set null,
  note       text check (char_length(note) <= 400),
  created_at timestamptz not null default now()
);
create index if not exists idx_history_order on order_status_history(order_id, created_at desc);

create or replace function log_order_status()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into order_status_history(order_id, old_status, new_status, changed_by)
    values (new.id, null, new.status, auth.uid());
  elsif new.status is distinct from old.status then
    insert into order_status_history(order_id, old_status, new_status, changed_by)
    values (new.id, old.status, new.status, auth.uid());
  end if;
  return new;
end $$;

drop trigger if exists trg_order_status_ins on orders;
create trigger trg_order_status_ins after insert on orders
  for each row execute function log_order_status();
drop trigger if exists trg_order_status_upd on orders;
create trigger trg_order_status_upd after update of status on orders
  for each row execute function log_order_status();

-- ---------- notification logs ----------
create table if not exists order_notifications (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references orders(id) on delete cascade,
  channel       text not null check (channel in ('telegram')),
  status        text not null check (status in ('sent','failed','retrying')),
  error_message text check (char_length(error_message) <= 1000),
  created_at    timestamptz not null default now()
);
create index if not exists idx_notif_order on order_notifications(order_id, created_at desc);

-- ---------- rate limiting ----------
-- one row per (key, action) bucket; pruned by the check function itself.
create table if not exists rate_limits (
  id         bigserial primary key,
  bucket_key text not null,
  action     text not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_rate on rate_limits(bucket_key, action, created_at desc);

-- ── 004_storage.sql ──────────────────────────────────────
-- ============================================================
-- Janeiro Store — 004 storage
-- product-media : PUBLIC read  (product posters/thumbnails)
-- receipts      : PRIVATE      (payment receipts, admin only)
-- ============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'product-media','product-media', true, 5242880,
  array['image/jpeg','image/png','image/webp','image/svg+xml']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'receipts','receipts', false, 5242880,
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ---------- product-media policies ----------
drop policy if exists "product media public read"   on storage.objects;
drop policy if exists "product media admin write"   on storage.objects;
drop policy if exists "product media admin update"  on storage.objects;
drop policy if exists "product media admin delete"  on storage.objects;

create policy "product media public read" on storage.objects
  for select using (bucket_id = 'product-media');

create policy "product media admin write" on storage.objects
  for insert with check (bucket_id = 'product-media' and is_admin());

create policy "product media admin update" on storage.objects
  for update using (bucket_id = 'product-media' and is_admin());

create policy "product media admin delete" on storage.objects
  for delete using (bucket_id = 'product-media' and is_admin());

-- ---------- receipts policies ----------
-- No public policy at all: anon/authenticated customers can neither
-- read nor list this bucket. Uploads go exclusively through the
-- upload-receipt Edge Function using the service role key.
drop policy if exists "receipts admin read"   on storage.objects;
drop policy if exists "receipts admin delete" on storage.objects;

create policy "receipts admin read" on storage.objects
  for select using (bucket_id = 'receipts' and is_admin());

create policy "receipts admin delete" on storage.objects
  for delete using (bucket_id = 'receipts' and is_admin());

-- ── 005_rls.sql ──────────────────────────────────────
-- ============================================================
-- Janeiro Store — 005 Row Level Security
--
-- Model:
--   anon/authenticated  -> READ ONLY, and only on catalog data
--   admin (profiles.role='admin') -> full management
--   orders/receipts/activation data -> NO public access at all;
--       writes happen only through SECURITY DEFINER RPCs and
--       the service-role Edge Functions.
-- ============================================================

alter table profiles              enable row level security;
alter table categories            enable row level security;
alter table products              enable row level security;
alter table product_plans         enable row level security;
alter table product_features      enable row level security;
alter table product_requirements  enable row level security;
alter table product_images        enable row level security;
alter table payment_methods       enable row level security;
alter table store_settings        enable row level security;
alter table orders                enable row level security;
alter table order_items           enable row level security;
alter table order_activation_data enable row level security;
alter table order_status_history  enable row level security;
alter table order_notifications   enable row level security;
alter table rate_limits           enable row level security;

-- ---------- profiles ----------
drop policy if exists "read own profile"   on profiles;
drop policy if exists "admin all profiles" on profiles;
create policy "read own profile" on profiles
  for select using (id = auth.uid());
create policy "admin all profiles" on profiles
  for all using (is_admin()) with check (is_admin());

-- ---------- categories ----------
drop policy if exists "public read active categories" on categories;
drop policy if exists "admin manage categories"       on categories;
create policy "public read active categories" on categories
  for select using (is_active = true);
create policy "admin manage categories" on categories
  for all using (is_admin()) with check (is_admin());

-- ---------- products ----------
-- Draft / hidden / archived products are invisible to the public.
drop policy if exists "public read visible products" on products;
drop policy if exists "admin manage products"        on products;
create policy "public read visible products" on products
  for select using (
    status in ('published','temporarily_unavailable','coming_soon')
    and archived_at is null
  );
create policy "admin manage products" on products
  for all using (is_admin()) with check (is_admin());

-- ---------- plans ----------
drop policy if exists "public read active plans" on product_plans;
drop policy if exists "admin manage plans"       on product_plans;
create policy "public read active plans" on product_plans
  for select using (
    is_active = true
    and exists (
      select 1 from products p
      where p.id = product_id
        and p.status in ('published','temporarily_unavailable','coming_soon')
        and p.archived_at is null
    )
  );
create policy "admin manage plans" on product_plans
  for all using (is_admin()) with check (is_admin());

-- ---------- features ----------
drop policy if exists "public read features" on product_features;
drop policy if exists "admin manage features" on product_features;
create policy "public read features" on product_features
  for select using (
    exists (select 1 from products p where p.id = product_id
            and p.status in ('published','temporarily_unavailable','coming_soon')
            and p.archived_at is null)
  );
create policy "admin manage features" on product_features
  for all using (is_admin()) with check (is_admin());

-- ---------- requirements ----------
drop policy if exists "public read requirements" on product_requirements;
drop policy if exists "admin manage requirements" on product_requirements;
create policy "public read requirements" on product_requirements
  for select using (
    exists (select 1 from products p where p.id = product_id
            and p.status in ('published','temporarily_unavailable','coming_soon')
            and p.archived_at is null)
  );
create policy "admin manage requirements" on product_requirements
  for all using (is_admin()) with check (is_admin());

-- ---------- images ----------
drop policy if exists "public read images"  on product_images;
drop policy if exists "admin manage images" on product_images;
create policy "public read images" on product_images
  for select using (
    exists (select 1 from products p where p.id = product_id
            and p.status in ('published','temporarily_unavailable','coming_soon')
            and p.archived_at is null)
  );
create policy "admin manage images" on product_images
  for all using (is_admin()) with check (is_admin());

-- ---------- payment methods ----------
drop policy if exists "public read active payment" on payment_methods;
drop policy if exists "admin manage payment"       on payment_methods;
create policy "public read active payment" on payment_methods
  for select using (is_active = true);
create policy "admin manage payment" on payment_methods
  for all using (is_admin()) with check (is_admin());

-- ---------- store settings ----------
drop policy if exists "public read public settings" on store_settings;
drop policy if exists "admin manage settings"       on store_settings;
create policy "public read public settings" on store_settings
  for select using (is_public = true);
create policy "admin manage settings" on store_settings
  for all using (is_admin()) with check (is_admin());

-- ---------- orders & everything private ----------
-- Deliberately NO public policy. With RLS enabled and no permissive
-- policy, anon/authenticated get zero rows and cannot insert/update.
-- Order creation happens via SECURITY DEFINER RPCs (006) only.
drop policy if exists "admin manage orders" on orders;
create policy "admin manage orders" on orders
  for all using (is_admin()) with check (is_admin());

drop policy if exists "admin manage items" on order_items;
create policy "admin manage items" on order_items
  for all using (is_admin()) with check (is_admin());

drop policy if exists "admin read activation" on order_activation_data;
create policy "admin read activation" on order_activation_data
  for all using (is_admin()) with check (is_admin());

drop policy if exists "admin read history" on order_status_history;
create policy "admin read history" on order_status_history
  for select using (is_admin());

drop policy if exists "admin read notifications" on order_notifications;
create policy "admin read notifications" on order_notifications
  for select using (is_admin());

-- rate_limits: service-role / definer functions only. No policies.

-- ---------- view permissions ----------
grant select on public_products to anon, authenticated;

-- ── 006_functions.sql ──────────────────────────────────────
-- ============================================================
-- Janeiro Store — 006 functions & RPCs
-- All business rules live here. The frontend is never trusted.
-- ============================================================

-- ------------------------------------------------------------
-- Algerian phone normalization
-- 0550123456 / +213550123456 / 213550123456 / 00213550123456
--   -> 213550123456
-- Returns NULL when the number is not a valid DZ mobile.
-- ------------------------------------------------------------
create or replace function normalize_dz_phone(raw text)
returns text language plpgsql immutable as $$
declare d text; begin
  if raw is null then return null; end if;
  d := regexp_replace(raw, '[^0-9]', '', 'g');

  if      d like '00213%' then d := substr(d, 6);
  elsif   d like '213%'   then d := substr(d, 4);
  elsif   d like '0%'     then d := substr(d, 2);
  end if;

  -- national mobile part must be 9 digits starting 5, 6 or 7
  if d ~ '^[5-7][0-9]{8}$' then
    return '213' || d;
  end if;
  return null;
end $$;

-- ------------------------------------------------------------
-- Order number: JNR-YYMMDD-XXXX (Crockford-ish, no ambiguous chars)
-- Retries on the tiny chance of a collision.
-- ------------------------------------------------------------
create or replace function generate_order_number()
returns text language plpgsql volatile as $$
declare
  alphabet constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  candidate text;
  suffix    text;
  i         int;
begin
  for attempt in 1..20 loop
    suffix := '';
    for i in 1..4 loop
      suffix := suffix || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    candidate := 'JNR-' || to_char(now() at time zone 'UTC', 'YYMMDD') || '-' || suffix;
    if not exists (select 1 from orders where order_number = candidate) then
      return candidate;
    end if;
  end loop;
  raise exception 'ORDER_NUMBER_GENERATION_FAILED';
end $$;

-- ------------------------------------------------------------
-- X-Forwarded-For is attacker-influenced text, and a bare ::inet
-- cast raises on anything unexpected (a host:port pair, "unknown",
-- an empty hop). That would turn a cosmetic header into a failed
-- order, so parse defensively and fall back to NULL.
-- ------------------------------------------------------------
create or replace function safe_inet(raw text)
returns inet language plpgsql immutable as $$
declare v text; begin
  v := trim(coalesce(raw, ''));
  if v = '' then return null; end if;
  -- strip a trailing :port from IPv4 (some proxies add one)
  if v ~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+$' then
    v := split_part(v, ':', 1);
  end if;
  return v::inet;
exception when others then
  return null;
end $$;

-- ------------------------------------------------------------
-- Rate limiting. Returns true when the action is allowed.
-- ------------------------------------------------------------
create or replace function check_rate_limit(
  p_key text, p_action text, p_max int, p_window interval
) returns boolean
language plpgsql security definer set search_path = public as $$
declare hits int; begin
  delete from rate_limits where created_at < now() - interval '1 day';

  select count(*) into hits
  from rate_limits
  where bucket_key = p_key and action = p_action
    and created_at > now() - p_window;

  if hits >= p_max then return false; end if;

  insert into rate_limits(bucket_key, action) values (p_key, p_action);
  return true;
end $$;

-- ------------------------------------------------------------
-- Active order counter (shared by create + submit)
-- ------------------------------------------------------------
create or replace function count_active_orders(p_phone text)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from orders
  where normalized_phone = p_phone
    and status in ('pending_payment_review','payment_confirmed','activating','needs_info');
$$;

-- ------------------------------------------------------------
-- CREATE ORDER  (status = awaiting_receipt)
--
-- p_items: [{ "product_id":uuid, "plan_id":uuid, "quantity":int,
--             "activation":[{"label":..,"value":..}] }]
-- Prices are ALWAYS read from the database. Anything price-like
-- coming from the client is ignored outright.
-- ------------------------------------------------------------
create or replace function create_order(
  p_name             text,
  p_phone            text,
  p_wilaya           text,
  p_payment_method   uuid,
  p_items            jsonb,
  p_idempotency_key  text,
  p_client_ip        text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_phone     text;
  v_order_id  uuid;
  v_number    text;
  v_subtotal  numeric(12,2) := 0;
  v_currency  text;
  v_max_active int;
  v_item      jsonb;
  v_product   products%rowtype;
  v_plan      product_plans%rowtype;
  v_qty       int;
  v_line      numeric(12,2);
  v_item_id   uuid;
  v_req       product_requirements%rowtype;
  v_act       jsonb;
  v_value     text;
  v_existing  orders%rowtype;
  v_warranty  text;
begin
  -- ---------- idempotency: same key -> same order ----------
  select * into v_existing from orders where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'order_id', v_existing.id,
      'order_number', v_existing.order_number,
      'subtotal', v_existing.subtotal,      -- same shape as the fresh path
      'total', v_existing.total,
      'currency', v_existing.currency,
      'status', v_existing.status,
      'idempotent_replay', true
    );
  end if;

  -- ---------- basic input validation ----------
  if p_name is null or char_length(trim(p_name)) < 2 then
    raise exception 'INVALID_NAME';
  end if;
  if char_length(p_name) > 80 then raise exception 'INVALID_NAME'; end if;

  v_phone := normalize_dz_phone(p_phone);
  if v_phone is null then raise exception 'INVALID_PHONE'; end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'EMPTY_CART';
  end if;
  if jsonb_array_length(p_items) > 20 then raise exception 'CART_TOO_LARGE'; end if;

  if p_payment_method is null
     or not exists (select 1 from payment_methods where id = p_payment_method and is_active) then
    raise exception 'INVALID_PAYMENT_METHOD';
  end if;

  -- ---------- rate limit ----------
  if not check_rate_limit(v_phone, 'create_order', 8, interval '10 minutes') then
    raise exception 'RATE_LIMITED';
  end if;

  -- ---------- serialize per customer, then check the cap ----------
  perform pg_advisory_xact_lock(hashtext('janeiro_orders_' || v_phone));

  select coalesce((select value::int from store_settings where key = 'max_active_orders'), 2)
    into v_max_active;

  if count_active_orders(v_phone) >= v_max_active then
    raise exception 'ACTIVE_ORDER_LIMIT';
  end if;

  select coalesce((select value from store_settings where key = 'currency'), 'دج')
    into v_currency;

  v_number := generate_order_number();

  -- The SELECT above only catches a *sequential* replay. Two requests in
  -- flight at once both miss it, and the loser hits the unique index. That
  -- must still read as a replay, not as a failure: the double-click case is
  -- precisely what the idempotency key exists for.
  begin
    insert into orders (
      order_number, customer_name, customer_phone, normalized_phone, customer_wilaya,
      payment_method_id, subtotal, total, currency, status, idempotency_key, client_ip
    ) values (
      v_number, trim(p_name), p_phone, v_phone, nullif(trim(coalesce(p_wilaya,'')), ''),
      p_payment_method, 0, 0, v_currency, 'awaiting_receipt', p_idempotency_key,
      safe_inet(p_client_ip)
    ) returning id into v_order_id;
  exception when unique_violation then
    -- The winner has committed by the time we get here (the insert blocked
    -- until it did), so this SELECT sees its row.
    select * into v_existing from orders where idempotency_key = p_idempotency_key;
    if not found then raise; end if;   -- a different unique index tripped
    return jsonb_build_object(
      'order_id', v_existing.id,
      'order_number', v_existing.order_number,
      'subtotal', v_existing.subtotal,
      'total', v_existing.total,
      'currency', v_existing.currency,
      'status', v_existing.status,
      'idempotent_replay', true
    );
  end;

  -- ---------- items ----------
  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_product from products
      where id = (v_item->>'product_id')::uuid;
    if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;

    -- only genuinely purchasable products
    if v_product.status <> 'published' or v_product.archived_at is not null then
      raise exception 'PRODUCT_NOT_PURCHASABLE:%', v_product.name;
    end if;

    select * into v_plan from product_plans
      where id = (v_item->>'plan_id')::uuid;
    if not found then raise exception 'PLAN_NOT_FOUND'; end if;
    if v_plan.product_id <> v_product.id then raise exception 'PLAN_PRODUCT_MISMATCH'; end if;
    if not v_plan.is_active then raise exception 'PLAN_INACTIVE'; end if;

    v_qty := coalesce((v_item->>'quantity')::int, 1);
    if v_qty < 1 or v_qty > 10 then raise exception 'INVALID_QUANTITY'; end if;

    v_line := v_plan.price * v_qty;          -- price from DB, never from client
    v_subtotal := v_subtotal + v_line;

    v_warranty := case v_product.warranty_type
      when 'subscription_duration' then 'ضمان طوال مدة الاشتراك'
      when 'days'      then 'ضمان ' || v_product.warranty_days || ' يوم'
      when 'activation'then 'ضمان التفعيل'
      when 'custom'    then v_product.warranty_label
      else null end;

    insert into order_items (
      order_id, product_id, plan_id, product_name_snapshot, plan_name_snapshot,
      unit_price, quantity, total_price, warranty_label_snapshot
    ) values (
      v_order_id, v_product.id, v_plan.id, v_product.name, v_plan.name,
      v_plan.price, v_qty, v_line, v_warranty
    ) returning id into v_item_id;

    -- ---------- activation data ----------
    for v_req in
      select * from product_requirements where product_id = v_product.id order by sort_order
    loop
      v_value := null;
      for v_act in select * from jsonb_array_elements(coalesce(v_item->'activation','[]'::jsonb)) loop
        if v_act->>'label' = v_req.label then
          v_value := nullif(trim(v_act->>'value'), '');
        end if;
      end loop;

      if v_req.is_required and v_value is null then
        raise exception 'MISSING_ACTIVATION_FIELD:%', v_req.label;
      end if;

      if v_value is not null then
        if char_length(v_value) > 300 then raise exception 'ACTIVATION_VALUE_TOO_LONG'; end if;
        if v_req.field_type = 'email' and v_value !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
          raise exception 'INVALID_EMAIL_FIELD:%', v_req.label;
        end if;
        insert into order_activation_data (order_item_id, field_label, field_type, field_value)
        values (v_item_id, v_req.label, v_req.field_type, v_value);
      end if;
    end loop;
  end loop;

  update orders set subtotal = v_subtotal, total = v_subtotal where id = v_order_id;

  return jsonb_build_object(
    'order_id', v_order_id,
    'order_number', v_number,
    'subtotal', v_subtotal,
    'total', v_subtotal,
    'currency', v_currency,
    'status', 'awaiting_receipt',
    'idempotent_replay', false
  );
end $$;

-- ------------------------------------------------------------
-- SUBMIT ORDER: awaiting_receipt -> pending_payment_review
-- Re-validates everything. This is the only place an order
-- becomes "real".
-- ------------------------------------------------------------
create or replace function submit_order(
  p_order_id          uuid,
  p_payment_reference text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_order      orders%rowtype;
  v_max_active int;
begin
  select * into v_order from orders where id = p_order_id;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;

  -- already submitted -> idempotent success
  if v_order.status <> 'awaiting_receipt' then
    return jsonb_build_object(
      'order_id', v_order.id, 'order_number', v_order.order_number,
      'status', v_order.status, 'total', v_order.total,
      'currency', v_order.currency, 'already_submitted', true
    );
  end if;

  if v_order.receipt_path is null or v_order.receipt_uploaded_at is null then
    raise exception 'RECEIPT_REQUIRED';
  end if;
  if not exists (select 1 from order_items where order_id = v_order.id) then
    raise exception 'EMPTY_ORDER';
  end if;
  if v_order.total <= 0 then raise exception 'INVALID_TOTAL'; end if;
  if p_payment_reference is not null and char_length(p_payment_reference) > 60 then
    raise exception 'INVALID_PAYMENT_REFERENCE';
  end if;

  -- re-check the cap under the same per-customer lock
  perform pg_advisory_xact_lock(hashtext('janeiro_orders_' || v_order.normalized_phone));
  select coalesce((select value::int from store_settings where key = 'max_active_orders'), 2)
    into v_max_active;
  if count_active_orders(v_order.normalized_phone) >= v_max_active then
    raise exception 'ACTIVE_ORDER_LIMIT';
  end if;

  -- Guard on the status too. Matching on id alone let a second concurrent
  -- submit re-apply the update and report already_submitted = false as well,
  -- so submit-order sent the admin two Telegram messages for one order.
  update orders set
    status = 'pending_payment_review',
    submitted_at = now(),
    payment_reference = coalesce(nullif(trim(p_payment_reference),''), payment_reference)
  where id = p_order_id
    and status = 'awaiting_receipt'
  returning * into v_order;

  if not found then
    -- A concurrent call won the race; report its result, don't notify again.
    select * into v_order from orders where id = p_order_id;
    if not found then raise exception 'ORDER_NOT_FOUND'; end if;
    return jsonb_build_object(
      'order_id', v_order.id, 'order_number', v_order.order_number,
      'status', v_order.status, 'total', v_order.total,
      'currency', v_order.currency, 'already_submitted', true
    );
  end if;

  return jsonb_build_object(
    'order_id', v_order.id, 'order_number', v_order.order_number,
    'status', v_order.status, 'total', v_order.total,
    'currency', v_order.currency, 'already_submitted', false
  );
end $$;

-- ------------------------------------------------------------
-- TRACK ORDER: order_number + last 4 digits of the phone.
-- Returns the bare minimum. Never phone, receipt, activation data
-- or payment account details.
--
-- Dropped first: a later migration renames this function's second
-- parameter, and postgres refuses to rename a parameter through
-- create or replace. The guard keeps a full replay of every
-- migration in order idempotent no matter what a later file does
-- to this signature.
-- ------------------------------------------------------------
drop function if exists track_order(text, text);
create or replace function track_order(p_order_number text, p_phone_last4 text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_order orders%rowtype; v_items jsonb; begin
  if p_order_number is null or p_phone_last4 !~ '^[0-9]{4}$' then
    raise exception 'INVALID_TRACKING_INPUT';
  end if;

  if not check_rate_limit(upper(trim(p_order_number)), 'track', 10, interval '10 minutes') then
    raise exception 'RATE_LIMITED';
  end if;

  select * into v_order from orders
   where order_number = upper(trim(p_order_number))
     and right(normalized_phone, 4) = p_phone_last4
     and status <> 'awaiting_receipt';

  if not found then raise exception 'ORDER_NOT_FOUND'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'name', product_name_snapshot,
           'plan', plan_name_snapshot,
           'quantity', quantity)), '[]'::jsonb)
    into v_items from order_items where order_id = v_order.id;

  return jsonb_build_object(
    'order_number', v_order.order_number,
    'status', v_order.status,
    'status_label', case v_order.status
        when 'pending_payment_review' then 'مراجعة الدفع'
        when 'payment_confirmed'      then 'تم تأكيد الدفع'
        when 'activating'             then 'جاري التفعيل'
        when 'needs_info'             then 'نحتاج معلومات إضافية'
        when 'completed'              then 'مكتمل'
        when 'cancelled'              then 'ملغي'
        when 'refunded'               then 'تم الاسترجاع'
        else 'قيد المعالجة' end,
    'items', v_items,
    'created_at', v_order.created_at,
    'updated_at', v_order.updated_at
  );
end $$;

-- ------------------------------------------------------------
-- Public entrypoints. create_order / submit_order are intentionally
-- NOT granted to anon: they run through the Edge Functions, which
-- add IP-based rate limiting and hold the service role key.
-- ------------------------------------------------------------
revoke all on function create_order(text,text,text,uuid,jsonb,text,text) from public, anon, authenticated;
revoke all on function submit_order(uuid,text)                          from public, anon, authenticated;
revoke all on function check_rate_limit(text,text,int,interval)         from public, anon, authenticated;
revoke all on function count_active_orders(text)                        from public, anon, authenticated;

revoke all on function generate_order_number()                   from public, anon, authenticated;
revoke all on function safe_inet(text)                          from public, anon, authenticated;

grant execute on function track_order(text,text)          to anon, authenticated;
grant execute on function normalize_dz_phone(text)         to anon, authenticated;

-- ── 007_seed_products.sql ──────────────────────────────────────
-- ============================================================
-- Janeiro Store — 007 seed
-- Migrates the CATEGORIES / PRODUCTS arrays that currently live in
-- janeiro-store-v4.html. Values are copied verbatim — nothing invented.
-- Idempotent: safe to re-run.
-- ============================================================

-- ---------- categories ----------
insert into categories (name, slug, accent_color, sort_order) values
  ('الذكاء الاصطناعي', 'ai',     '#7357FF', 1),
  ('التصميم والإبداع', 'design', '#EC4899', 2),
  ('الإنتاجية والعمل', 'work',   '#F59E0B', 3),
  ('التواصل',          'social', '#3478F6', 4),
  ('الترفيه',          'fun',    '#10B981', 5),
  ('التطوير',          'dev',    '#0EA5E9', 6)
on conflict (slug) do update
  set name = excluded.name,
      accent_color = excluded.accent_color,
      sort_order = excluded.sort_order;

-- ---------- payment methods ----------
-- Account details are intentionally blank: fill them from the
-- Supabase dashboard, they must never be committed to git.
-- Conflict target is the type: re-running must update, never duplicate.
-- account_holder / account_number / instructions are deliberately NOT
-- touched here, so a re-run never wipes details entered in the dashboard.
insert into payment_methods (type, label, sort_order, is_active) values
  ('ccp',       'CCP',        1, true),
  ('baridimob', 'BaridiMob',  2, true),
  ('flexy',     'Flexy',      3, true)
on conflict (type) do update
  set label = excluded.label,
      sort_order = excluded.sort_order;

-- ---------- products ----------
do $$
declare
  v_pid uuid;
  v_cat uuid;
begin
  ------------------------------------------------------------------
  -- ChatGPT Plus
  ------------------------------------------------------------------
  select id into v_cat from categories where slug = 'ai';
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, badge_type, badge_label, status, sort_order)
  values ('ChatGPT Plus','chatgpt-plus',v_cat,
    'وصول كامل لأحدث النماذج بسرعة استجابة أعلى.','#10A37F',
    'subscription_duration','hot','الأكثر طلباً','published',1)
  on conflict (slug) do update set short_description = excluded.short_description
  returning id into v_pid;

  delete from product_plans        where product_id = v_pid;
  delete from product_features     where product_id = v_pid;
  delete from product_requirements where product_id = v_pid;

  insert into product_plans (product_id, name, price, sort_order) values
    (v_pid,'شهر واحد',3200,1),(v_pid,'3 أشهر',9000,2);
  insert into product_features (product_id, label, sort_order) values
    (v_pid,'استخدام غير محدود للنماذج المتقدمة',1),
    (v_pid,'أولوية في أوقات الضغط',2),
    (v_pid,'تفعيل على حسابك الشخصي',3);
  insert into product_requirements (product_id, label, field_type, placeholder, sort_order) values
    (v_pid,'البريد الإلكتروني للحساب','email','name@example.com',1);

  ------------------------------------------------------------------
  -- Gemini Pro
  ------------------------------------------------------------------
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, badge_type, badge_label, status, sort_order)
  values ('Gemini Pro','gemini-pro',v_cat,
    'باقة Google المتقدمة للذكاء الاصطناعي مع مساحة تخزين.','#3478F6',
    'subscription_duration','hot','الأكثر طلباً','published',2)
  on conflict (slug) do update set short_description = excluded.short_description
  returning id into v_pid;

  delete from product_plans        where product_id = v_pid;
  delete from product_features     where product_id = v_pid;
  delete from product_requirements where product_id = v_pid;

  insert into product_plans (product_id, name, price, sort_order) values
    (v_pid,'شهر واحد',1900,1),(v_pid,'3 أشهر',4500,2),(v_pid,'12 شهراً',14000,3);
  insert into product_features (product_id, label, sort_order) values
    (v_pid,'نماذج Gemini المتقدمة',1),
    (v_pid,'تكامل مع تطبيقات Google',2),
    (v_pid,'مساحة تخزين إضافية',3);
  insert into product_requirements (product_id, label, field_type, placeholder, sort_order) values
    (v_pid,'بريد Gmail للتفعيل','email','name@gmail.com',1),
    (v_pid,'رقم الهاتف المرتبط','phone','0X XX XX XX XX',2);

  ------------------------------------------------------------------
  -- Canva Pro
  ------------------------------------------------------------------
  select id into v_cat from categories where slug = 'design';
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, status, sort_order)
  values ('Canva Pro','canva-pro',v_cat,
    'أدوات تصميم احترافية ومكتبة قوالب ضخمة.','#00C4CC',
    'subscription_duration','published',3)
  on conflict (slug) do update set short_description = excluded.short_description
  returning id into v_pid;

  delete from product_plans        where product_id = v_pid;
  delete from product_features     where product_id = v_pid;
  delete from product_requirements where product_id = v_pid;

  insert into product_plans (product_id, name, price, sort_order) values
    (v_pid,'شهر واحد',1200,1),(v_pid,'12 شهراً',9500,2);
  insert into product_features (product_id, label, sort_order) values
    (v_pid,'ملايين القوالب والعناصر',1),
    (v_pid,'إزالة الخلفية بنقرة',2),
    (v_pid,'مساحة تخزين للفرق',3);
  insert into product_requirements (product_id, label, field_type, placeholder, sort_order) values
    (v_pid,'البريد الإلكتروني للحساب','email','name@example.com',1);

  ------------------------------------------------------------------
  -- Adobe Creative Cloud
  ------------------------------------------------------------------
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, status, sort_order)
  values ('Adobe Creative Cloud','adobe-creative-cloud',v_cat,
    'حزمة أدوبي الكاملة للتصميم والمونتاج.','#DA1B2C',
    'subscription_duration','published',4)
  on conflict (slug) do update set short_description = excluded.short_description
  returning id into v_pid;

  delete from product_plans        where product_id = v_pid;
  delete from product_features     where product_id = v_pid;
  delete from product_requirements where product_id = v_pid;

  insert into product_plans (product_id, name, price, sort_order) values
    (v_pid,'شهر واحد',4800,1),(v_pid,'12 شهراً',38000,2);
  insert into product_features (product_id, label, sort_order) values
    (v_pid,'Photoshop وIllustrator وPremiere',1),
    (v_pid,'تحديثات مستمرة',2),
    (v_pid,'مساحة سحابية',3);
  insert into product_requirements (product_id, label, field_type, placeholder, sort_order) values
    (v_pid,'البريد الإلكتروني للحساب','email','name@example.com',1);

  ------------------------------------------------------------------
  -- Notion Plus
  ------------------------------------------------------------------
  select id into v_cat from categories where slug = 'work';
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, badge_type, badge_label, status, sort_order)
  values ('Notion Plus','notion-plus',v_cat,
    'مساحة عمل واحدة للملاحظات والمهام وقواعد البيانات.','#111318',
    'subscription_duration','new','جديد','published',5)
  on conflict (slug) do update set short_description = excluded.short_description
  returning id into v_pid;

  delete from product_plans        where product_id = v_pid;
  delete from product_features     where product_id = v_pid;
  delete from product_requirements where product_id = v_pid;

  insert into product_plans (product_id, name, price, sort_order) values
    (v_pid,'شهر واحد',1400,1),(v_pid,'12 شهراً',12000,2);
  insert into product_features (product_id, label, sort_order) values
    (v_pid,'رفع ملفات بلا حدود',1),
    (v_pid,'سجل نسخ أطول',2),
    (v_pid,'دعوة ضيوف',3);
  insert into product_requirements (product_id, label, field_type, placeholder, sort_order) values
    (v_pid,'البريد الإلكتروني للحساب','email','name@example.com',1);

  ------------------------------------------------------------------
  -- Discord Nitro
  ------------------------------------------------------------------
  select id into v_cat from categories where slug = 'social';
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, status, sort_order)
  values ('Discord Nitro','discord-nitro',v_cat,
    'مزايا إضافية للبث والرموز والملفات داخل ديسكورد.','#5865F2',
    'subscription_duration','published',6)
  on conflict (slug) do update set short_description = excluded.short_description
  returning id into v_pid;

  delete from product_plans        where product_id = v_pid;
  delete from product_features     where product_id = v_pid;
  delete from product_requirements where product_id = v_pid;

  insert into product_plans (product_id, name, price, sort_order) values
    (v_pid,'شهر واحد',1400,1),(v_pid,'12 شهراً',12000,2);
  insert into product_features (product_id, label, sort_order) values
    (v_pid,'بث بجودة أعلى',1),
    (v_pid,'رفع ملفات أكبر',2),
    (v_pid,'رموز مخصصة في كل السيرفرات',3);
  insert into product_requirements (product_id, label, field_type, placeholder, sort_order) values
    (v_pid,'اسم المستخدم في ديسكورد','username','username',1);

  ------------------------------------------------------------------
  -- Snapchat Plus  (the one product with a real discount)
  ------------------------------------------------------------------
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, badge_type, badge_label, status, sort_order)
  values ('Snapchat Plus','snapchat-plus',v_cat,
    'مزايا حصرية داخل سناب شات.','#F5A524',
    'subscription_duration','off','عرض','published',7)
  on conflict (slug) do update set short_description = excluded.short_description
  returning id into v_pid;

  delete from product_plans        where product_id = v_pid;
  delete from product_features     where product_id = v_pid;
  delete from product_requirements where product_id = v_pid;

  insert into product_plans (product_id, name, price, old_price, sort_order) values
    (v_pid,'شهر واحد',700,950,1),(v_pid,'12 شهراً',5500,null,2);
  insert into product_features (product_id, label, sort_order) values
    (v_pid,'مزايا حصرية للمشتركين',1),
    (v_pid,'تخصيص أيقونة التطبيق',2),
    (v_pid,'إحصاءات إضافية',3);
  insert into product_requirements (product_id, label, field_type, placeholder, sort_order) values
    (v_pid,'اسم المستخدم في سناب شات','username','@username',1);

  ------------------------------------------------------------------
  -- Spotify Premium
  ------------------------------------------------------------------
  select id into v_cat from categories where slug = 'fun';
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, status, sort_order)
  values ('Spotify Premium','spotify-premium',v_cat,
    'استماع بلا إعلانات وتحميل للاستماع دون اتصال.','#1DB954',
    'subscription_duration','published',8)
  on conflict (slug) do update set short_description = excluded.short_description
  returning id into v_pid;

  delete from product_plans        where product_id = v_pid;
  delete from product_features     where product_id = v_pid;
  delete from product_requirements where product_id = v_pid;

  insert into product_plans (product_id, name, price, sort_order) values
    (v_pid,'شهر واحد',1100,1),(v_pid,'3 أشهر',2900,2);
  insert into product_features (product_id, label, sort_order) values
    (v_pid,'بدون إعلانات',1),
    (v_pid,'تحميل للاستماع دون اتصال',2),
    (v_pid,'جودة صوت أعلى',3);
  insert into product_requirements (product_id, label, field_type, placeholder, sort_order) values
    (v_pid,'البريد الإلكتروني للحساب','email','name@example.com',1);

  ------------------------------------------------------------------
  -- Apple One  (coming soon — no plans, matches current frontend)
  ------------------------------------------------------------------
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, status, sort_order)
  values ('Apple One','apple-one',v_cat,
    'حزمة خدمات Apple في اشتراك واحد.','#3A3D46',
    'none','coming_soon',9)
  on conflict (slug) do update set status = excluded.status
  returning id into v_pid;

  ------------------------------------------------------------------
  -- GitHub Copilot
  ------------------------------------------------------------------
  select id into v_cat from categories where slug = 'dev';
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, status, sort_order)
  values ('GitHub Copilot','github-copilot',v_cat,
    'مساعد برمجي داخل محرر الأكواد.','#24292F',
    'subscription_duration','published',10)
  on conflict (slug) do update set short_description = excluded.short_description
  returning id into v_pid;

  delete from product_plans        where product_id = v_pid;
  delete from product_features     where product_id = v_pid;
  delete from product_requirements where product_id = v_pid;

  insert into product_plans (product_id, name, price, sort_order) values
    (v_pid,'شهر واحد',1600,1),(v_pid,'12 شهراً',14500,2);
  insert into product_features (product_id, label, sort_order) values
    (v_pid,'اقتراحات كود فورية',1),
    (v_pid,'دعم أغلب المحررات',2),
    (v_pid,'شرح وإصلاح الأخطاء',3);
  insert into product_requirements (product_id, label, field_type, placeholder, sort_order) values
    (v_pid,'اسم المستخدم في GitHub','username','username',1);
end $$;

-- ── 008_category_icons.sql ──────────────────────────────────────
-- ============================================================
-- Janeiro Store — 008 category icon assets
--
-- Mirrors products.poster_path: the column holds a path inside the
-- PUBLIC product-media bucket, not a URL. The frontend builds the URL,
-- so moving buckets or domains never touches the data.
--
-- Empty is the normal state. A category without an icon renders the
-- designed fallback, so this is additive and breaks nothing.
--
-- ASSET SPEC — what to upload:
--   size   : 128x128 px
--   format : PNG with a transparent background (or WebP)
--   why    : the icon renders at 28px in the category chips and 34px in
--            the side menu; 128px covers those at up to ~3.8x DPR with
--            room for larger placements later.
--   bucket : product-media  (public read, see migration 004)
--   path   : categories/<slug>.png   e.g. categories/ai.png
--
--   Keep the artwork inside a ~112px safe area so it does not collide
--   with the tile's rounded corners, and make it legible on a dark
--   ground -- the tile behind it is a low-opacity tint, not a solid.
-- ============================================================

alter table categories add column if not exists icon_path text;

comment on column categories.icon_path is
  'Path inside the public product-media bucket, e.g. categories/ai.png. '
  '128x128 transparent PNG. NULL renders the designed fallback icon.';

-- ── 009_daily_deals.sql ──────────────────────────────────────
-- ============================================================
-- Janeiro Store — 009 daily deals
--
-- A deal is a time-boxed price on ONE plan of ONE product. It never
-- edits product_plans.price, so the original price survives for the
-- struck-through display and the deal simply expires on its own.
--
-- The frontend reads deals only to DISPLAY them. create_order re-reads
-- the deal price from this table, so a tampered cart cannot invent a
-- discount and a deal that expired mid-checkout is charged at full
-- price. Same rule as every other price in this schema.
-- ============================================================

create table if not exists daily_deals (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid not null references products(id)      on delete cascade,
  plan_id     uuid not null references product_plans(id) on delete cascade,

  deal_price  numeric(12,2) not null check (deal_price >= 0),
  starts_at   timestamptz not null default now(),
  ends_at     timestamptz not null,

  is_active   boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint deal_window_ok check (ends_at > starts_at)
);

create index if not exists idx_deals_live
  on daily_deals(is_active, starts_at, ends_at, sort_order);
create index if not exists idx_deals_plan
  on daily_deals(plan_id);

drop trigger if exists trg_deals_updated on daily_deals;
create trigger trg_deals_updated before update on daily_deals
  for each row execute function set_updated_at();

-- ------------------------------------------------------------
-- deal_price must actually be a discount, and the plan must belong
-- to the product. Neither can be a CHECK constraint -- both read
-- another table -- so they are enforced by trigger instead.
-- ------------------------------------------------------------
create or replace function validate_daily_deal()
returns trigger language plpgsql as $$
declare v_price numeric(12,2); v_product uuid;
begin
  select price, product_id into v_price, v_product
    from product_plans where id = new.plan_id;
  if not found then
    raise exception 'DEAL_PLAN_NOT_FOUND';
  end if;
  if v_product <> new.product_id then
    raise exception 'DEAL_PLAN_PRODUCT_MISMATCH';
  end if;
  if new.deal_price >= v_price then
    raise exception 'DEAL_PRICE_NOT_LOWER';
  end if;
  return new;
end $$;

drop trigger if exists trg_deals_validate on daily_deals;
create trigger trg_deals_validate before insert or update on daily_deals
  for each row execute function validate_daily_deal();

-- ------------------------------------------------------------
-- The live deal price for a plan, or NULL. SECURITY DEFINER so
-- create_order can call it; not granted to anon.
--
-- ends_at is exclusive: a deal ending at 20:00 is over at 20:00.
-- sort_order then id keeps the result deterministic if two deals
-- overlap on the same plan.
-- ------------------------------------------------------------
create or replace function active_deal_price(p_product uuid, p_plan uuid)
returns numeric
language sql stable security definer set search_path = public as $$
  select d.deal_price
    from daily_deals d
   where d.product_id = p_product
     and d.plan_id    = p_plan
     and d.is_active
     and now() >= d.starts_at
     and now() <  d.ends_at
   order by d.sort_order, d.id
   limit 1;
$$;

-- ------------------------------------------------------------
-- RLS: the public sees live deals only. An upcoming or expired deal
-- is invisible, so a scheduled deal cannot be read before it starts.
-- ------------------------------------------------------------
alter table daily_deals enable row level security;

drop policy if exists "public read live deals" on daily_deals;
drop policy if exists "admin manage deals"     on daily_deals;

create policy "public read live deals" on daily_deals
  for select using (
    is_active
    and now() >= starts_at
    and now() <  ends_at
  );

create policy "admin manage deals" on daily_deals
  for all using (is_admin()) with check (is_admin());

-- ------------------------------------------------------------
-- What the storefront reads. Joins in the original price so the
-- struck-through figure and the discount percentage come from the
-- server, and carries server_now so the countdown can measure the
-- browser's clock offset instead of trusting it.
-- ------------------------------------------------------------
create or replace view public_daily_deals as
select
  d.id,
  d.product_id,
  d.plan_id,
  d.deal_price,
  pl.price       as original_price,
  pl.name        as plan_name,
  p.slug         as product_slug,
  p.name         as product_name,
  d.starts_at,
  d.ends_at,
  d.sort_order,
  now()          as server_now
from daily_deals d
join product_plans pl on pl.id = d.plan_id
join products      p  on p.id  = d.product_id
where d.is_active
  and now() >= d.starts_at
  and now() <  d.ends_at
  and pl.is_active
  and p.status = 'published'
  and p.archived_at is null;

grant select on public_daily_deals to anon, authenticated;

revoke all on function active_deal_price(uuid,uuid) from public, anon, authenticated;

-- ------------------------------------------------------------
-- CREATE ORDER — reissued so the line price honours a live deal.
--
-- Identical to 006 except for the unit price: the client sends no
-- price at all, and the server now asks daily_deals before falling
-- back to the plan's list price.
-- ------------------------------------------------------------
create or replace function create_order(
  p_name             text,
  p_phone            text,
  p_wilaya           text,
  p_payment_method   uuid,
  p_items            jsonb,
  p_idempotency_key  text,
  p_client_ip        text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_phone     text;
  v_order_id  uuid;
  v_number    text;
  v_subtotal  numeric(12,2) := 0;
  v_currency  text;
  v_max_active int;
  v_item      jsonb;
  v_product   products%rowtype;
  v_plan      product_plans%rowtype;
  v_qty       int;
  v_unit      numeric(12,2);
  v_line      numeric(12,2);
  v_item_id   uuid;
  v_req       product_requirements%rowtype;
  v_act       jsonb;
  v_value     text;
  v_existing  orders%rowtype;
  v_warranty  text;
begin
  -- ---------- idempotency: same key -> same order ----------
  select * into v_existing from orders where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'order_id', v_existing.id,
      'order_number', v_existing.order_number,
      'subtotal', v_existing.subtotal,
      'total', v_existing.total,
      'currency', v_existing.currency,
      'status', v_existing.status,
      'idempotent_replay', true
    );
  end if;

  -- ---------- basic input validation ----------
  if p_name is null or char_length(trim(p_name)) < 2 then
    raise exception 'INVALID_NAME';
  end if;
  if char_length(p_name) > 80 then raise exception 'INVALID_NAME'; end if;

  v_phone := normalize_dz_phone(p_phone);
  if v_phone is null then raise exception 'INVALID_PHONE'; end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'EMPTY_CART';
  end if;
  if jsonb_array_length(p_items) > 20 then raise exception 'CART_TOO_LARGE'; end if;

  if p_payment_method is null
     or not exists (select 1 from payment_methods where id = p_payment_method and is_active) then
    raise exception 'INVALID_PAYMENT_METHOD';
  end if;

  -- ---------- rate limit ----------
  if not check_rate_limit(v_phone, 'create_order', 8, interval '10 minutes') then
    raise exception 'RATE_LIMITED';
  end if;

  -- ---------- serialize per customer, then check the cap ----------
  perform pg_advisory_xact_lock(hashtext('janeiro_orders_' || v_phone));

  select coalesce((select value::int from store_settings where key = 'max_active_orders'), 2)
    into v_max_active;

  if count_active_orders(v_phone) >= v_max_active then
    raise exception 'ACTIVE_ORDER_LIMIT';
  end if;

  select coalesce((select value from store_settings where key = 'currency'), 'دج')
    into v_currency;

  v_number := generate_order_number();

  begin
    insert into orders (
      order_number, customer_name, customer_phone, normalized_phone, customer_wilaya,
      payment_method_id, subtotal, total, currency, status, idempotency_key, client_ip
    ) values (
      v_number, trim(p_name), p_phone, v_phone, nullif(trim(coalesce(p_wilaya,'')), ''),
      p_payment_method, 0, 0, v_currency, 'awaiting_receipt', p_idempotency_key,
      safe_inet(p_client_ip)
    ) returning id into v_order_id;
  exception when unique_violation then
    select * into v_existing from orders where idempotency_key = p_idempotency_key;
    if not found then raise; end if;
    return jsonb_build_object(
      'order_id', v_existing.id,
      'order_number', v_existing.order_number,
      'subtotal', v_existing.subtotal,
      'total', v_existing.total,
      'currency', v_existing.currency,
      'status', v_existing.status,
      'idempotent_replay', true
    );
  end;

  -- ---------- items ----------
  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_product from products
      where id = (v_item->>'product_id')::uuid;
    if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;

    if v_product.status <> 'published' or v_product.archived_at is not null then
      raise exception 'PRODUCT_NOT_PURCHASABLE:%', v_product.name;
    end if;

    select * into v_plan from product_plans
      where id = (v_item->>'plan_id')::uuid;
    if not found then raise exception 'PLAN_NOT_FOUND'; end if;
    if v_plan.product_id <> v_product.id then raise exception 'PLAN_PRODUCT_MISMATCH'; end if;
    if not v_plan.is_active then raise exception 'PLAN_INACTIVE'; end if;

    v_qty := coalesce((v_item->>'quantity')::int, 1);
    if v_qty < 1 or v_qty > 10 then raise exception 'INVALID_QUANTITY'; end if;

    -- price from the DB: a live deal if there is one, else the list price.
    -- Nothing price-like from the client is consulted, deal or not.
    v_unit := coalesce(active_deal_price(v_product.id, v_plan.id), v_plan.price);
    v_line := v_unit * v_qty;
    v_subtotal := v_subtotal + v_line;

    v_warranty := case v_product.warranty_type
      when 'subscription_duration' then 'ضمان طوال مدة الاشتراك'
      when 'days'      then 'ضمان ' || v_product.warranty_days || ' يوم'
      when 'activation'then 'ضمان التفعيل'
      when 'custom'    then v_product.warranty_label
      else null end;

    insert into order_items (
      order_id, product_id, plan_id, product_name_snapshot, plan_name_snapshot,
      unit_price, quantity, total_price, warranty_label_snapshot
    ) values (
      v_order_id, v_product.id, v_plan.id, v_product.name, v_plan.name,
      v_unit, v_qty, v_line, v_warranty
    ) returning id into v_item_id;

    -- ---------- activation data ----------
    for v_req in
      select * from product_requirements where product_id = v_product.id order by sort_order
    loop
      v_value := null;
      for v_act in select * from jsonb_array_elements(coalesce(v_item->'activation','[]'::jsonb)) loop
        if v_act->>'label' = v_req.label then
          v_value := nullif(trim(v_act->>'value'), '');
        end if;
      end loop;

      if v_req.is_required and v_value is null then
        raise exception 'MISSING_ACTIVATION_FIELD:%', v_req.label;
      end if;

      if v_value is not null then
        if char_length(v_value) > 300 then raise exception 'ACTIVATION_VALUE_TOO_LONG'; end if;
        if v_req.field_type = 'email' and v_value !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
          raise exception 'INVALID_EMAIL_FIELD:%', v_req.label;
        end if;
        insert into order_activation_data (order_item_id, field_label, field_type, field_value)
        values (v_item_id, v_req.label, v_req.field_type, v_value);
      end if;
    end loop;
  end loop;

  update orders set subtotal = v_subtotal, total = v_subtotal where id = v_order_id;

  return jsonb_build_object(
    'order_id', v_order_id,
    'order_number', v_number,
    'subtotal', v_subtotal,
    'total', v_subtotal,
    'currency', v_currency,
    'status', 'awaiting_receipt',
    'idempotent_replay', false
  );
end $$;

revoke all on function create_order(text,text,text,uuid,jsonb,text,text) from public, anon, authenticated;

-- ── 010_admin_orders.sql ──────────────────────────────────────
-- ============================================================
-- Janeiro Store — 010 admin order handling
--
-- Until now nothing could move an order forward. completed, cancelled
-- and refunded were reachable only by editing the table by hand, which
-- meant the customer's tracking page could never show them.
--
-- The rules live in a table rather than in a CASE block, so the legal
-- lifecycle is data you can read and change without touching code.
-- ============================================================

-- ------------------------------------------------------------
-- Which moves are legal. Absent pair = refused.
--
-- awaiting_receipt and pending_payment_review are customer-flow states
-- reached by create_order and submit_order; an admin can only cancel
-- out of the first, never assign either. cancelled and refunded are
-- terminal, so they appear as a source nowhere below.
-- ------------------------------------------------------------
create table if not exists order_status_transitions (
  from_status order_status not null,
  to_status   order_status not null,
  primary key (from_status, to_status)
);

insert into order_status_transitions (from_status, to_status) values
  -- the customer never paid: the only way out is to drop it
  ('awaiting_receipt',       'cancelled'),

  -- you have the receipt in hand and are judging it
  ('pending_payment_review', 'payment_confirmed'),
  ('pending_payment_review', 'needs_info'),
  ('pending_payment_review', 'cancelled'),

  -- money is good, now fulfil
  ('payment_confirmed',      'activating'),
  ('payment_confirmed',      'needs_info'),
  ('payment_confirmed',      'cancelled'),
  ('payment_confirmed',      'refunded'),

  ('activating',             'completed'),
  ('activating',             'needs_info'),
  ('activating',             'cancelled'),
  ('activating',             'refunded'),

  -- waiting on the customer; resumes wherever it left off
  ('needs_info',             'payment_confirmed'),
  ('needs_info',             'activating'),
  ('needs_info',             'cancelled'),
  ('needs_info',             'refunded'),

  -- a warranty case or a late dispute after delivery
  ('completed',              'refunded')
on conflict do nothing;

alter table order_status_transitions enable row level security;
drop policy if exists "admin read transitions" on order_status_transitions;
create policy "admin read transitions" on order_status_transitions
  for select using (is_admin());
grant select on order_status_transitions to authenticated;

-- ------------------------------------------------------------
-- Carry the admin's reason into the history row. The trigger writes
-- that row, so the note is handed over through a transaction-local
-- setting rather than by updating the row afterwards.
-- ------------------------------------------------------------
create or replace function log_order_status()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_note text;
begin
  v_note := nullif(current_setting('janeiro.status_note', true), '');
  if tg_op = 'INSERT' then
    insert into order_status_history(order_id, old_status, new_status, changed_by, note)
    values (new.id, null, new.status, auth.uid(), v_note);
  elsif new.status is distinct from old.status then
    insert into order_status_history(order_id, old_status, new_status, changed_by, note)
    values (new.id, old.status, new.status, auth.uid(), v_note);
  end if;
  return new;
end $$;

-- ------------------------------------------------------------
-- The one way an order moves. Admins only, one legal step at a time.
-- ------------------------------------------------------------
create or replace function admin_update_order_status(
  p_order_id   uuid,
  p_new_status order_status,
  p_note       text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_order orders%rowtype; v_old order_status;
begin
  if not is_admin() then
    raise exception 'NOT_AUTHORIZED';
  end if;
  if p_note is not null and char_length(p_note) > 400 then
    raise exception 'NOTE_TOO_LONG';
  end if;

  -- Lock the row: two staff opening the same order must not both move it.
  select * into v_order from orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;

  v_old := v_order.status;

  -- Re-applying the current status is a no-op, not an error: a double
  -- click on the same button should be harmless.
  if v_old = p_new_status then
    return jsonb_build_object(
      'order_id', v_order.id, 'order_number', v_order.order_number,
      'status', v_old, 'changed', false
    );
  end if;

  if not exists (
    select 1 from order_status_transitions
     where from_status = v_old and to_status = p_new_status
  ) then
    raise exception 'INVALID_STATUS_TRANSITION:% -> %', v_old, p_new_status;
  end if;

  perform set_config('janeiro.status_note', coalesce(p_note, ''), true);

  update orders set status = p_new_status where id = p_order_id
  returning * into v_order;

  return jsonb_build_object(
    'order_id', v_order.id, 'order_number', v_order.order_number,
    'previous_status', v_old, 'status', v_order.status, 'changed', true
  );
end $$;

-- ------------------------------------------------------------
-- Queue counts for the console header.
-- ------------------------------------------------------------
create or replace function admin_order_counts()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not is_admin() then raise exception 'NOT_AUTHORIZED'; end if;
  select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) into v
    from (select status::text as status, count(*) as n from orders group by status) s;
  return v;
end $$;

revoke all on function admin_update_order_status(uuid,order_status,text) from public, anon;
revoke all on function admin_order_counts()                              from public, anon;
grant execute on function admin_update_order_status(uuid,order_status,text) to authenticated;
grant execute on function admin_order_counts()                              to authenticated;

-- ── 011_dashboard_stats.sql ──────────────────────────────────────
-- ============================================================
-- Janeiro Store — 011 dashboard figures
--
-- One admin-only call for the overview screen, so the dashboard makes
-- a single round trip instead of a dozen.
--
-- What counts as revenue, stated once here rather than implied in the
-- UI: an order counts from the moment its payment is confirmed, and
-- stops counting if it is refunded. Orders still awaiting a receipt or
-- under payment review are NOT revenue -- they are not money yet, and
-- showing them as such would flatter the number.
-- ============================================================

create or replace function admin_dashboard_stats()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_earned constant order_status[] :=
    array['payment_confirmed','activating','needs_info','completed']::order_status[];
  v_actionable constant order_status[] :=
    array['pending_payment_review','payment_confirmed','activating','needs_info']::order_status[];
  v jsonb;
begin
  if not is_admin() then raise exception 'NOT_AUTHORIZED'; end if;

  select jsonb_build_object(

    -- ---------- today, and the same figure yesterday to compare ----------
    'today', (
      select jsonb_build_object(
        'orders',  count(*) filter (where submitted_at >= current_date),
        'revenue', coalesce(sum(total) filter (
                     where submitted_at >= current_date and status = any(v_earned)), 0),
        'completed', count(*) filter (
                     where submitted_at >= current_date and status = 'completed'))
        from orders),

    'yesterday', (
      select jsonb_build_object(
        'orders',  count(*) filter (
                     where submitted_at >= current_date - 1 and submitted_at < current_date),
        'revenue', coalesce(sum(total) filter (
                     where submitted_at >= current_date - 1 and submitted_at < current_date
                       and status = any(v_earned)), 0))
        from orders),

    'week', (
      select jsonb_build_object(
        'orders',  count(*) filter (where submitted_at >= current_date - 6),
        'revenue', coalesce(sum(total) filter (
                     where submitted_at >= current_date - 6 and status = any(v_earned)), 0))
        from orders),

    -- ---------- what is waiting on you right now ----------
    'needs_you', (
      select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
        from (select status::text as status, count(*) as n
                from orders where status = any(v_actionable)
               group by status) s),

    'oldest_waiting_hours', (
      select round(extract(epoch from (now() - min(submitted_at))) / 3600)
        from orders where status = 'pending_payment_review'),

    -- ---------- a seven-day sparkline, one row per day, zeros included ----------
    'daily', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'day', d::date, 'orders', o.n, 'revenue', o.rev) order by d), '[]'::jsonb)
        from generate_series(current_date - 6, current_date, interval '1 day') d
        left join lateral (
          select count(*) as n,
                 coalesce(sum(total) filter (where status = any(v_earned)), 0) as rev
            from orders
           where submitted_at >= d and submitted_at < d + interval '1 day') o on true),

    -- ---------- what actually sells, last 30 days ----------
    'top_products', (
      select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select i.product_name_snapshot as name,
               sum(i.quantity)::int    as sold,
               sum(i.total_price)      as revenue
          from order_items i
          join orders o on o.id = i.order_id
         where o.submitted_at >= current_date - 29
           and o.status = any(v_earned)
         group by i.product_name_snapshot
         order by sum(i.total_price) desc
         limit 5) t),

    -- ---------- lifetime, for context ----------
    'totals', (
      select jsonb_build_object(
        'orders',    count(*),
        'customers', count(distinct normalized_phone),
        'revenue',   coalesce(sum(total) filter (where status = any(v_earned)), 0),
        'refunded',  coalesce(sum(total) filter (where status = 'refunded'), 0))
        from orders where status <> 'awaiting_receipt')

  ) into v;
  return v;
end $$;

revoke all on function admin_dashboard_stats() from public, anon;
grant execute on function admin_dashboard_stats() to authenticated;

-- ── 012_admin_products.sql ──────────────────────────────────────
-- ============================================================
-- Janeiro Store — 012 product management
--
-- A product spans five tables. Writing it from the dashboard one table
-- at a time would leave half-built products behind whenever a request
-- failed midway, so the whole thing goes through one function and one
-- transaction: it all lands or none of it does.
-- ============================================================

-- ------------------------------------------------------------
-- Everything an admin needs to list and edit products, including the
-- ones the public cannot see. Admins already have full RLS access to
-- these tables; this exists so the dashboard makes one call instead of
-- five per product.
-- ------------------------------------------------------------
create or replace function admin_list_products()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not is_admin() then raise exception 'NOT_AUTHORIZED'; end if;

  select coalesce(jsonb_agg(row order by row->>'sort_order', row->>'name'), '[]'::jsonb)
    into v
  from (
    select jsonb_build_object(
      'id', p.id, 'slug', p.slug, 'name', p.name, 'status', p.status,
      'sort_order', p.sort_order, 'poster_path', p.poster_path,
      'accent_color', p.accent_color, 'category_slug', c.slug,
      'short_description', p.short_description, 'description', p.description,
      'warranty_type', p.warranty_type, 'warranty_days', p.warranty_days,
      'warranty_label', p.warranty_label,
      'badge_type', p.badge_type, 'badge_label', p.badge_label,
      'delivery_min', p.delivery_min, 'delivery_max', p.delivery_max,
      'delivery_unit', p.delivery_unit, 'delivery_label', p.delivery_label,
      'plans', coalesce((select jsonb_agg(jsonb_build_object(
                  'id', pl.id, 'name', pl.name, 'price', pl.price,
                  'old_price', pl.old_price, 'duration_value', pl.duration_value,
                  'duration_unit', pl.duration_unit, 'is_active', pl.is_active,
                  'sort_order', pl.sort_order) order by pl.sort_order)
                from product_plans pl where pl.product_id = p.id), '[]'::jsonb),
      'features', coalesce((select jsonb_agg(f.label order by f.sort_order)
                from product_features f where f.product_id = p.id), '[]'::jsonb),
      'requirements', coalesce((select jsonb_agg(jsonb_build_object(
                  'label', r.label, 'field_type', r.field_type,
                  'placeholder', r.placeholder, 'is_required', r.is_required)
                  order by r.sort_order)
                from product_requirements r where r.product_id = p.id), '[]'::jsonb),
      -- how many orders reference it: the dashboard warns before archiving
      'order_count', (select count(*) from order_items i where i.product_id = p.id)
    ) as row
    from products p
    left join categories c on c.id = p.category_id
    where p.archived_at is null
  ) s;
  return v;
end $$;

-- ------------------------------------------------------------
-- Create or update a whole product.
--
-- Plans are matched by id, not replaced wholesale. Two reasons that
-- matter: order_items.plan_id points at them, and daily_deals cascades
-- on delete -- dropping a plan would silently delete its deal. A plan
-- the editor no longer lists is deactivated, never deleted, so past
-- orders and their history stay intact.
--
-- Features and requirements carry no foreign keys (activation data
-- snapshots the label as text), so those are rebuilt each save.
-- ------------------------------------------------------------
create or replace function admin_upsert_product(p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id        uuid;
  v_slug      text;
  v_cat       uuid;
  v_status    product_status;
  v_plan      jsonb;
  v_req       jsonb;
  v_feat      jsonb;
  v_plan_id   uuid;
  v_kept      uuid[] := '{}';
  v_active    int := 0;
  i           int := 0;
begin
  if not is_admin() then raise exception 'NOT_AUTHORIZED'; end if;

  v_slug := lower(trim(coalesce(p_payload->>'slug', '')));
  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
    raise exception 'INVALID_SLUG';
  end if;
  if char_length(trim(coalesce(p_payload->>'name',''))) < 1 then
    raise exception 'INVALID_NAME';
  end if;

  select id into v_cat from categories where slug = p_payload->>'category_slug';
  if v_cat is null then raise exception 'CATEGORY_NOT_FOUND'; end if;

  v_status := coalesce(nullif(p_payload->>'status',''), 'draft')::product_status;

  -- A published product with nothing to buy is a dead end for the
  -- customer, so it is refused here rather than discovered on the shop.
  for v_plan in select * from jsonb_array_elements(coalesce(p_payload->'plans','[]'::jsonb)) loop
    if coalesce((v_plan->>'is_active')::boolean, true) then v_active := v_active + 1; end if;
  end loop;
  if v_status = 'published' and v_active = 0 then
    raise exception 'PUBLISHED_NEEDS_A_PLAN';
  end if;

  -- ---------- the product row ----------
  insert into products (
    slug, name, category_id, short_description, description, accent_color,
    poster_path, thumbnail_path,
    warranty_type, warranty_days, warranty_label,
    badge_type, badge_label,
    delivery_min, delivery_max, delivery_unit, delivery_label,
    status, sort_order)
  values (
    v_slug,
    trim(p_payload->>'name'),
    v_cat,
    nullif(trim(coalesce(p_payload->>'short_description','')), ''),
    nullif(trim(coalesce(p_payload->>'description','')), ''),
    nullif(p_payload->>'accent_color',''),
    nullif(p_payload->>'poster_path',''),
    nullif(p_payload->>'thumbnail_path',''),
    coalesce(nullif(p_payload->>'warranty_type',''),'none')::warranty_type,
    nullif(p_payload->>'warranty_days','')::int,
    nullif(trim(coalesce(p_payload->>'warranty_label','')), ''),
    nullif(p_payload->>'badge_type',''),
    nullif(trim(coalesce(p_payload->>'badge_label','')), ''),
    nullif(p_payload->>'delivery_min','')::int,
    nullif(p_payload->>'delivery_max','')::int,
    nullif(p_payload->>'delivery_unit',''),
    nullif(trim(coalesce(p_payload->>'delivery_label','')), ''),
    v_status,
    coalesce(nullif(p_payload->>'sort_order','')::int, 0))
  on conflict (slug) do update set
    name = excluded.name, category_id = excluded.category_id,
    short_description = excluded.short_description, description = excluded.description,
    accent_color = excluded.accent_color, poster_path = excluded.poster_path,
    thumbnail_path = excluded.thumbnail_path,
    warranty_type = excluded.warranty_type, warranty_days = excluded.warranty_days,
    warranty_label = excluded.warranty_label,
    badge_type = excluded.badge_type, badge_label = excluded.badge_label,
    delivery_min = excluded.delivery_min, delivery_max = excluded.delivery_max,
    delivery_unit = excluded.delivery_unit, delivery_label = excluded.delivery_label,
    status = excluded.status, sort_order = excluded.sort_order
  returning id into v_id;

  -- ---------- plans ----------
  i := 0;
  for v_plan in select * from jsonb_array_elements(coalesce(p_payload->'plans','[]'::jsonb)) loop
    i := i + 1;
    v_plan_id := nullif(v_plan->>'id','')::uuid;

    if v_plan_id is not null then
      update product_plans set
        name = trim(v_plan->>'name'),
        price = (v_plan->>'price')::numeric,
        old_price = nullif(v_plan->>'old_price','')::numeric,
        duration_value = nullif(v_plan->>'duration_value','')::int,
        duration_unit = nullif(v_plan->>'duration_unit',''),
        is_active = coalesce((v_plan->>'is_active')::boolean, true),
        sort_order = i
      where id = v_plan_id and product_id = v_id;
      if not found then raise exception 'PLAN_NOT_ON_THIS_PRODUCT'; end if;
    else
      insert into product_plans (product_id, name, price, old_price,
                                 duration_value, duration_unit, is_active, sort_order)
      values (v_id, trim(v_plan->>'name'), (v_plan->>'price')::numeric,
              nullif(v_plan->>'old_price','')::numeric,
              nullif(v_plan->>'duration_value','')::int,
              nullif(v_plan->>'duration_unit',''),
              coalesce((v_plan->>'is_active')::boolean, true), i)
      returning id into v_plan_id;
    end if;
    v_kept := v_kept || v_plan_id;
  end loop;

  -- a plan dropped from the editor is retired, not destroyed
  update product_plans set is_active = false
   where product_id = v_id and not (id = any(v_kept));

  -- ---------- features ----------
  delete from product_features where product_id = v_id;
  i := 0;
  for v_feat in select * from jsonb_array_elements(coalesce(p_payload->'features','[]'::jsonb)) loop
    i := i + 1;
    if char_length(trim(v_feat #>> '{}')) > 0 then
      insert into product_features (product_id, label, sort_order)
      values (v_id, trim(v_feat #>> '{}'), i);
    end if;
  end loop;

  -- ---------- activation fields ----------
  delete from product_requirements where product_id = v_id;
  i := 0;
  for v_req in select * from jsonb_array_elements(coalesce(p_payload->'requirements','[]'::jsonb)) loop
    i := i + 1;
    if char_length(trim(coalesce(v_req->>'label',''))) = 0 then continue; end if;
    insert into product_requirements
      (product_id, label, field_type, placeholder, is_required, sort_order)
    values (v_id, trim(v_req->>'label'),
            coalesce(nullif(v_req->>'field_type',''),'text')::requirement_field_type,
            nullif(trim(coalesce(v_req->>'placeholder','')), ''),
            coalesce((v_req->>'is_required')::boolean, true), i);
  end loop;

  return jsonb_build_object('id', v_id, 'slug', v_slug, 'status', v_status);
end $$;

-- ------------------------------------------------------------
-- Archiving instead of deleting: order history keeps pointing at the
-- product, and the public view already hides archived rows.
-- ------------------------------------------------------------
create or replace function admin_archive_product(p_slug text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not is_admin() then raise exception 'NOT_AUTHORIZED'; end if;
  update products set archived_at = now(), status = 'archived'
   where slug = p_slug and archived_at is null
  returning id into v_id;
  if v_id is null then raise exception 'PRODUCT_NOT_FOUND'; end if;
  return jsonb_build_object('id', v_id, 'archived', true);
end $$;

revoke all on function admin_list_products()          from public, anon;
revoke all on function admin_upsert_product(jsonb)    from public, anon;
revoke all on function admin_archive_product(text)    from public, anon;
grant execute on function admin_list_products()       to authenticated;
grant execute on function admin_upsert_product(jsonb) to authenticated;
grant execute on function admin_archive_product(text) to authenticated;

-- ── 013_product_icons.sql ──────────────────────────────────────
-- ============================================================
-- Janeiro Store — 013 product brand icons
--
-- The hero orbit shows a ring of product logos. Until now the only
-- sources for those were cdn.simpleicons.org -- a third party in the
-- critical path of the first paint, on the mobile connections this
-- store is for -- and a single-letter monogram fallback. A ring of
-- letters is not the feature; the logos are.
--
-- Mirrors categories.icon_path (migration 008) exactly: the column
-- holds a PATH inside the public product-media bucket, never a URL, so
-- moving buckets or domains never touches the data.
--
-- Empty is the normal state. A product without an icon falls back to
-- simpleicons and then to the monogram, so this is additive and breaks
-- nothing.
--
-- ASSET SPEC — what to upload:
--   size   : 256x256 px, square
--   format : PNG or WebP, transparent background
--   why    : the icon renders at 56px in the orbit and 24px in the cart
--            thumbnail. 256px covers 56px at up to 4.5x DPR, which is
--            more headroom than categories' 128px because the orbit
--            tile is twice the size of a category chip.
--   bucket : product-media  (public read, admin write -- migration 004)
--   path   : products/icons/<slug>.png   e.g. products/icons/canva-pro.png
--
--   Keep the mark inside a ~224px safe area: the orbit tile is rounded
--   and clips the corners. The tile behind it is a solid surface in
--   both themes, so a mark that is pure white will vanish in the light
--   theme -- upload the coloured or dark version, not the knockout.
--
-- WHY NOT SVG
--   Every image in this project is validated by magic bytes rather than
--   by Content-Type, on purpose. SVG is XML: it has no signature to
--   check, and an SVG served from a public bucket as image/svg+xml runs
--   any script it carries when its object URL is opened directly. That
--   trades the whole point of the magic-byte rule for sharper edges.
--   Raster only.
-- ============================================================

alter table products add column if not exists icon_path text;

comment on column products.icon_path is
  'Path inside the public product-media bucket, e.g. products/icons/canva-pro.png. '
  '256x256 transparent PNG or WebP. NULL falls back to the brand icon CDN, '
  'then to the designed monogram.';

-- The path is built by the dashboard, but a hand-written row or a future
-- import should not be able to smuggle a URL, a traversal or a bucket
-- name into a column the frontend concatenates into a public URL.
alter table products drop constraint if exists products_icon_path_shape;
alter table products add constraint products_icon_path_shape check (
  icon_path is null
  or icon_path ~ '^products/icons/[a-z0-9]+(-[a-z0-9]+)*\.(png|webp)$'
);

-- ---------- expose it to the public read view ----------
-- Same reason as 002: drop first so neither file cares which ran last.
drop view if exists public_products;
create view public_products as
select
  p.id, p.name, p.slug, p.short_description, p.description,
  p.poster_path, p.thumbnail_path, p.accent_color,
  p.activation_type, p.activation_label,
  p.delivery_min, p.delivery_max, p.delivery_unit, p.delivery_label,
  p.warranty_type, p.warranty_days, p.warranty_label, p.warranty_description,
  p.warranty_covers, p.warranty_exclusions,
  p.badge_type, p.badge_label, p.status, p.sort_order,
  c.slug as category_slug, c.name as category_name, c.accent_color as category_accent,
  -- appended rather than slotted next to poster_path: CREATE OR REPLACE VIEW
  -- can only add columns at the end, and dropping the view to reorder them
  -- would drop its grants with it.
  p.icon_path
from products p
left join categories c on c.id = p.category_id
where p.status in ('published','temporarily_unavailable','coming_soon')
  and p.archived_at is null;

grant select on public_products to anon, authenticated;

-- ---------- carry it through the admin RPCs ----------
-- Both are replaced wholesale rather than patched: 012 defines them with
-- an explicit column list, and a product saved through an editor that did
-- not know about icon_path would silently blank it on every save.

create or replace function admin_list_products()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not is_admin() then raise exception 'NOT_AUTHORIZED'; end if;

  select coalesce(jsonb_agg(row order by row->>'sort_order', row->>'name'), '[]'::jsonb)
    into v
  from (
    select jsonb_build_object(
      'id', p.id, 'slug', p.slug, 'name', p.name, 'status', p.status,
      'sort_order', p.sort_order, 'poster_path', p.poster_path,
      'icon_path', p.icon_path,
      'accent_color', p.accent_color, 'category_slug', c.slug,
      'short_description', p.short_description, 'description', p.description,
      'warranty_type', p.warranty_type, 'warranty_days', p.warranty_days,
      'warranty_label', p.warranty_label,
      'badge_type', p.badge_type, 'badge_label', p.badge_label,
      'delivery_min', p.delivery_min, 'delivery_max', p.delivery_max,
      'delivery_unit', p.delivery_unit, 'delivery_label', p.delivery_label,
      'plans', coalesce((select jsonb_agg(jsonb_build_object(
                  'id', pl.id, 'name', pl.name, 'price', pl.price,
                  'old_price', pl.old_price, 'duration_value', pl.duration_value,
                  'duration_unit', pl.duration_unit, 'is_active', pl.is_active,
                  'sort_order', pl.sort_order) order by pl.sort_order)
                from product_plans pl where pl.product_id = p.id), '[]'::jsonb),
      'features', coalesce((select jsonb_agg(f.label order by f.sort_order)
                from product_features f where f.product_id = p.id), '[]'::jsonb),
      'requirements', coalesce((select jsonb_agg(jsonb_build_object(
                  'label', r.label, 'field_type', r.field_type,
                  'placeholder', r.placeholder, 'is_required', r.is_required)
                  order by r.sort_order)
                from product_requirements r where r.product_id = p.id), '[]'::jsonb),
      'order_count', (select count(*) from order_items i where i.product_id = p.id)
    ) as row
    from products p
    left join categories c on c.id = p.category_id
    where p.archived_at is null
  ) s;
  return v;
end $$;

-- Only the product row changes in the upsert; plans, features and
-- requirements are untouched, so those blocks are carried over verbatim
-- from 012.
create or replace function admin_upsert_product(p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id        uuid;
  v_slug      text;
  v_cat       uuid;
  v_status    product_status;
  v_plan      jsonb;
  v_req       jsonb;
  v_feat      jsonb;
  v_plan_id   uuid;
  v_kept      uuid[] := '{}';
  v_active    int := 0;
  i           int := 0;
begin
  if not is_admin() then raise exception 'NOT_AUTHORIZED'; end if;

  v_slug := lower(trim(coalesce(p_payload->>'slug', '')));
  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
    raise exception 'INVALID_SLUG';
  end if;
  if char_length(trim(coalesce(p_payload->>'name',''))) < 1 then
    raise exception 'INVALID_NAME';
  end if;

  select id into v_cat from categories where slug = p_payload->>'category_slug';
  if v_cat is null then raise exception 'CATEGORY_NOT_FOUND'; end if;

  v_status := coalesce(nullif(p_payload->>'status',''), 'draft')::product_status;

  for v_plan in select * from jsonb_array_elements(coalesce(p_payload->'plans','[]'::jsonb)) loop
    if coalesce((v_plan->>'is_active')::boolean, true) then v_active := v_active + 1; end if;
  end loop;
  if v_status = 'published' and v_active = 0 then
    raise exception 'PUBLISHED_NEEDS_A_PLAN';
  end if;

  insert into products (
    slug, name, category_id, short_description, description, accent_color,
    poster_path, thumbnail_path, icon_path,
    warranty_type, warranty_days, warranty_label,
    badge_type, badge_label,
    delivery_min, delivery_max, delivery_unit, delivery_label,
    status, sort_order)
  values (
    v_slug,
    trim(p_payload->>'name'),
    v_cat,
    nullif(trim(coalesce(p_payload->>'short_description','')), ''),
    nullif(trim(coalesce(p_payload->>'description','')), ''),
    nullif(p_payload->>'accent_color',''),
    nullif(p_payload->>'poster_path',''),
    nullif(p_payload->>'thumbnail_path',''),
    nullif(p_payload->>'icon_path',''),
    coalesce(nullif(p_payload->>'warranty_type',''),'none')::warranty_type,
    nullif(p_payload->>'warranty_days','')::int,
    nullif(trim(coalesce(p_payload->>'warranty_label','')), ''),
    nullif(p_payload->>'badge_type',''),
    nullif(trim(coalesce(p_payload->>'badge_label','')), ''),
    nullif(p_payload->>'delivery_min','')::int,
    nullif(p_payload->>'delivery_max','')::int,
    nullif(p_payload->>'delivery_unit',''),
    nullif(trim(coalesce(p_payload->>'delivery_label','')), ''),
    v_status,
    coalesce(nullif(p_payload->>'sort_order','')::int, 0))
  on conflict (slug) do update set
    name = excluded.name, category_id = excluded.category_id,
    short_description = excluded.short_description, description = excluded.description,
    accent_color = excluded.accent_color, poster_path = excluded.poster_path,
    thumbnail_path = excluded.thumbnail_path, icon_path = excluded.icon_path,
    warranty_type = excluded.warranty_type, warranty_days = excluded.warranty_days,
    warranty_label = excluded.warranty_label,
    badge_type = excluded.badge_type, badge_label = excluded.badge_label,
    delivery_min = excluded.delivery_min, delivery_max = excluded.delivery_max,
    delivery_unit = excluded.delivery_unit, delivery_label = excluded.delivery_label,
    status = excluded.status, sort_order = excluded.sort_order
  returning id into v_id;

  i := 0;
  for v_plan in select * from jsonb_array_elements(coalesce(p_payload->'plans','[]'::jsonb)) loop
    i := i + 1;
    v_plan_id := nullif(v_plan->>'id','')::uuid;
    if v_plan_id is not null then
      update product_plans set
        name = trim(v_plan->>'name'),
        price = (v_plan->>'price')::numeric,
        old_price = nullif(v_plan->>'old_price','')::numeric,
        duration_value = nullif(v_plan->>'duration_value','')::int,
        duration_unit = nullif(v_plan->>'duration_unit',''),
        is_active = coalesce((v_plan->>'is_active')::boolean, true),
        sort_order = i
      where id = v_plan_id and product_id = v_id;
      if not found then raise exception 'PLAN_NOT_ON_THIS_PRODUCT'; end if;
    else
      insert into product_plans (product_id, name, price, old_price,
                                 duration_value, duration_unit, is_active, sort_order)
      values (v_id, trim(v_plan->>'name'), (v_plan->>'price')::numeric,
              nullif(v_plan->>'old_price','')::numeric,
              nullif(v_plan->>'duration_value','')::int,
              nullif(v_plan->>'duration_unit',''),
              coalesce((v_plan->>'is_active')::boolean, true), i)
      returning id into v_plan_id;
    end if;
    v_kept := v_kept || v_plan_id;
  end loop;

  update product_plans set is_active = false
   where product_id = v_id and not (id = any(v_kept));

  delete from product_features where product_id = v_id;
  i := 0;
  for v_feat in select * from jsonb_array_elements(coalesce(p_payload->'features','[]'::jsonb)) loop
    i := i + 1;
    if char_length(trim(v_feat #>> '{}')) > 0 then
      insert into product_features (product_id, label, sort_order)
      values (v_id, trim(v_feat #>> '{}'), i);
    end if;
  end loop;

  delete from product_requirements where product_id = v_id;
  i := 0;
  for v_req in select * from jsonb_array_elements(coalesce(p_payload->'requirements','[]'::jsonb)) loop
    i := i + 1;
    if char_length(trim(coalesce(v_req->>'label',''))) = 0 then continue; end if;
    insert into product_requirements
      (product_id, label, field_type, placeholder, is_required, sort_order)
    values (v_id, trim(v_req->>'label'),
            coalesce(nullif(v_req->>'field_type',''),'text')::requirement_field_type,
            nullif(trim(coalesce(v_req->>'placeholder','')), ''),
            coalesce((v_req->>'is_required')::boolean, true), i);
  end loop;

  return jsonb_build_object('id', v_id, 'slug', v_slug, 'status', v_status);
end $$;

revoke all on function admin_list_products()          from public, anon;
revoke all on function admin_upsert_product(jsonb)    from public, anon;
grant execute on function admin_list_products()       to authenticated;
grant execute on function admin_upsert_product(jsonb) to authenticated;

-- ── 014_activation_type.sql ──────────────────────────────────────
-- ============================================================
-- 014 — نوع التفعيل
--
-- A choice the customer makes on the product page and that travels
-- with the line into the order: "تفعيل مباشر" or "تفعيل عبر دعوة/رابط".
--
-- It is NOT another product_requirements row. Those are per-product
-- questions the owner writes ("بريد Gmail للتفعيل"), asked once the
-- payment is done; this is a property of the line itself, chosen
-- before the product reaches the cart. So it gets its own column on
-- order_items and is snapshotted there the way plan_name_snapshot is:
-- editing the list later must not rewrite what an old order said.
--
-- The list the customer picks from lives in ONE file,
-- frontend/activation-types.js, so the owner can change the wording
-- without a migration and without touching this function. The server
-- deliberately keeps no second copy of that list -- a copy would drift
-- and start rejecting the owner's own new wording. What the server
-- does enforce is that a choice was made and that it is short text.
-- That is the project's rule applied honestly: prices, totals and
-- order numbers are computed here and never trusted from the browser;
-- a label the customer picked from a list is none of those, and the
-- free-text activation fields beside it have always worked this way.
-- ============================================================

alter table order_items add column if not exists activation_type text;

do $$ begin
  if not exists (
    select 1 from pg_constraint where conname = 'order_items_activation_type_len'
  ) then
    alter table order_items add constraint order_items_activation_type_len
      check (activation_type is null or char_length(activation_type) between 1 and 60);
  end if;
end $$;

comment on column order_items.activation_type is
  'نوع التفعيل الذي اختاره العميل على صفحة المنتج، مخزّن كما كان وقت الطلب.';

-- ------------------------------------------------------------
-- CREATE ORDER — reissued from 009 so the line records the choice.
--
-- Identical to 009 apart from three added lines: read the choice,
-- refuse the order without one, and store it on the line.
-- ------------------------------------------------------------
create or replace function create_order(
  p_name             text,
  p_phone            text,
  p_wilaya           text,
  p_payment_method   uuid,
  p_items            jsonb,
  p_idempotency_key  text,
  p_client_ip        text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_phone     text;
  v_order_id  uuid;
  v_number    text;
  v_subtotal  numeric(12,2) := 0;
  v_currency  text;
  v_max_active int;
  v_item      jsonb;
  v_product   products%rowtype;
  v_plan      product_plans%rowtype;
  v_qty       int;
  v_unit      numeric(12,2);
  v_line      numeric(12,2);
  v_item_id   uuid;
  v_req       product_requirements%rowtype;
  v_act       jsonb;
  v_value     text;
  v_act_type  text;
  v_existing  orders%rowtype;
  v_warranty  text;
begin
  -- ---------- idempotency: same key -> same order ----------
  select * into v_existing from orders where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'order_id', v_existing.id,
      'order_number', v_existing.order_number,
      'subtotal', v_existing.subtotal,
      'total', v_existing.total,
      'currency', v_existing.currency,
      'status', v_existing.status,
      'idempotent_replay', true
    );
  end if;

  -- ---------- basic input validation ----------
  if p_name is null or char_length(trim(p_name)) < 2 then
    raise exception 'INVALID_NAME';
  end if;
  if char_length(p_name) > 80 then raise exception 'INVALID_NAME'; end if;

  v_phone := normalize_dz_phone(p_phone);
  if v_phone is null then raise exception 'INVALID_PHONE'; end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'EMPTY_CART';
  end if;
  if jsonb_array_length(p_items) > 20 then raise exception 'CART_TOO_LARGE'; end if;

  if p_payment_method is null
     or not exists (select 1 from payment_methods where id = p_payment_method and is_active) then
    raise exception 'INVALID_PAYMENT_METHOD';
  end if;

  -- ---------- rate limit ----------
  if not check_rate_limit(v_phone, 'create_order', 8, interval '10 minutes') then
    raise exception 'RATE_LIMITED';
  end if;

  -- ---------- serialize per customer, then check the cap ----------
  perform pg_advisory_xact_lock(hashtext('janeiro_orders_' || v_phone));

  select coalesce((select value::int from store_settings where key = 'max_active_orders'), 2)
    into v_max_active;

  if count_active_orders(v_phone) >= v_max_active then
    raise exception 'ACTIVE_ORDER_LIMIT';
  end if;

  select coalesce((select value from store_settings where key = 'currency'), 'دج')
    into v_currency;

  v_number := generate_order_number();

  begin
    insert into orders (
      order_number, customer_name, customer_phone, normalized_phone, customer_wilaya,
      payment_method_id, subtotal, total, currency, status, idempotency_key, client_ip
    ) values (
      v_number, trim(p_name), p_phone, v_phone, nullif(trim(coalesce(p_wilaya,'')), ''),
      p_payment_method, 0, 0, v_currency, 'awaiting_receipt', p_idempotency_key,
      safe_inet(p_client_ip)
    ) returning id into v_order_id;
  exception when unique_violation then
    select * into v_existing from orders where idempotency_key = p_idempotency_key;
    if not found then raise; end if;
    return jsonb_build_object(
      'order_id', v_existing.id,
      'order_number', v_existing.order_number,
      'subtotal', v_existing.subtotal,
      'total', v_existing.total,
      'currency', v_existing.currency,
      'status', v_existing.status,
      'idempotent_replay', true
    );
  end;

  -- ---------- items ----------
  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_product from products
      where id = (v_item->>'product_id')::uuid;
    if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;

    if v_product.status <> 'published' or v_product.archived_at is not null then
      raise exception 'PRODUCT_NOT_PURCHASABLE:%', v_product.name;
    end if;

    select * into v_plan from product_plans
      where id = (v_item->>'plan_id')::uuid;
    if not found then raise exception 'PLAN_NOT_FOUND'; end if;
    if v_plan.product_id <> v_product.id then raise exception 'PLAN_PRODUCT_MISMATCH'; end if;
    if not v_plan.is_active then raise exception 'PLAN_INACTIVE'; end if;

    v_qty := coalesce((v_item->>'quantity')::int, 1);
    if v_qty < 1 or v_qty > 10 then raise exception 'INVALID_QUANTITY'; end if;

    -- ---------- نوع التفعيل ----------
    v_act_type := nullif(trim(coalesce(v_item->>'activation_type', '')), '');
    if v_act_type is null then raise exception 'MISSING_ACTIVATION_TYPE'; end if;
    if char_length(v_act_type) > 60 then raise exception 'ACTIVATION_TYPE_TOO_LONG'; end if;

    -- price from the DB: a live deal if there is one, else the list price.
    -- Nothing price-like from the client is consulted, deal or not.
    v_unit := coalesce(active_deal_price(v_product.id, v_plan.id), v_plan.price);
    v_line := v_unit * v_qty;
    v_subtotal := v_subtotal + v_line;

    v_warranty := case v_product.warranty_type
      when 'subscription_duration' then 'ضمان طوال مدة الاشتراك'
      when 'days'      then 'ضمان ' || v_product.warranty_days || ' يوم'
      when 'activation'then 'ضمان التفعيل'
      when 'custom'    then v_product.warranty_label
      else null end;

    insert into order_items (
      order_id, product_id, plan_id, product_name_snapshot, plan_name_snapshot,
      unit_price, quantity, total_price, warranty_label_snapshot, activation_type
    ) values (
      v_order_id, v_product.id, v_plan.id, v_product.name, v_plan.name,
      v_unit, v_qty, v_line, v_warranty, v_act_type
    ) returning id into v_item_id;

    -- ---------- activation data ----------
    for v_req in
      select * from product_requirements where product_id = v_product.id order by sort_order
    loop
      v_value := null;
      for v_act in select * from jsonb_array_elements(coalesce(v_item->'activation','[]'::jsonb)) loop
        if v_act->>'label' = v_req.label then
          v_value := nullif(trim(v_act->>'value'), '');
        end if;
      end loop;

      if v_req.is_required and v_value is null then
        raise exception 'MISSING_ACTIVATION_FIELD:%', v_req.label;
      end if;

      if v_value is not null then
        if char_length(v_value) > 300 then raise exception 'ACTIVATION_VALUE_TOO_LONG'; end if;
        if v_req.field_type = 'email' and v_value !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
          raise exception 'INVALID_EMAIL_FIELD:%', v_req.label;
        end if;
        insert into order_activation_data (order_item_id, field_label, field_type, field_value)
        values (v_item_id, v_req.label, v_req.field_type, v_value);
      end if;
    end loop;
  end loop;

  update orders set subtotal = v_subtotal, total = v_subtotal where id = v_order_id;

  return jsonb_build_object(
    'order_id', v_order_id,
    'order_number', v_number,
    'subtotal', v_subtotal,
    'total', v_subtotal,
    'currency', v_currency,
    'status', 'awaiting_receipt',
    'idempotent_replay', false
  );
end $$;

revoke all on function create_order(text,text,text,uuid,jsonb,text,text) from public, anon, authenticated;

-- ── 015_activation_type_from_product.sql ──────────────────────────────────────
-- ============================================================
-- 015 — نوع التفعيل يحدّده صاحب المتجر، لا الزبون
--
-- 014 asked the customer to choose. That was wrong: how a product is
-- activated is something the store knows and the buyer is told, not
-- something the buyer picks. So the choice moves to where it belongs.
--
--   * products.activation_type is the source. The column has been in
--     the schema since 002 ("how the product is activated,
--     informational, drives copy") with nothing writing it; the
--     dashboard writes it now, and the storefront shows it read-only.
--   * create_order copies it from the product onto the order line and
--     IGNORES anything the browser sends under that name -- the same
--     treatment a price gets.
--   * order_items.activation_type stays a snapshot: renaming the
--     product's activation type later must not rewrite what an old
--     order said.
--
-- A product with none set is not an error. The row simply does not
-- appear on the product page, and the line stores null: refusing to
-- sell because the owner has not filled in an informational label
-- would be a worse bug than the missing label.
--
-- The list of values the owner picks from lives in one file,
-- dashboard/activation-types.js -- in the dashboard, because the
-- dashboard is the only place anyone picks from it; the storefront
-- reads whatever is stored on the product. The database keeps no copy
-- of the list: a copy would drift and start rejecting the owner's own
-- new wording. It enforces the shape only -- the column's own CHECK
-- caps it at 40 characters.
-- ============================================================

create or replace function create_order(
  p_name             text,
  p_phone            text,
  p_wilaya           text,
  p_payment_method   uuid,
  p_items            jsonb,
  p_idempotency_key  text,
  p_client_ip        text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_phone     text;
  v_order_id  uuid;
  v_number    text;
  v_subtotal  numeric(12,2) := 0;
  v_currency  text;
  v_max_active int;
  v_item      jsonb;
  v_product   products%rowtype;
  v_plan      product_plans%rowtype;
  v_qty       int;
  v_unit      numeric(12,2);
  v_line      numeric(12,2);
  v_item_id   uuid;
  v_req       product_requirements%rowtype;
  v_act       jsonb;
  v_value     text;
  v_act_type  text;
  v_existing  orders%rowtype;
  v_warranty  text;
begin
  -- ---------- idempotency: same key -> same order ----------
  select * into v_existing from orders where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'order_id', v_existing.id,
      'order_number', v_existing.order_number,
      'subtotal', v_existing.subtotal,
      'total', v_existing.total,
      'currency', v_existing.currency,
      'status', v_existing.status,
      'idempotent_replay', true
    );
  end if;

  -- ---------- basic input validation ----------
  if p_name is null or char_length(trim(p_name)) < 2 then
    raise exception 'INVALID_NAME';
  end if;
  if char_length(p_name) > 80 then raise exception 'INVALID_NAME'; end if;

  v_phone := normalize_dz_phone(p_phone);
  if v_phone is null then raise exception 'INVALID_PHONE'; end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'EMPTY_CART';
  end if;
  if jsonb_array_length(p_items) > 20 then raise exception 'CART_TOO_LARGE'; end if;

  if p_payment_method is null
     or not exists (select 1 from payment_methods where id = p_payment_method and is_active) then
    raise exception 'INVALID_PAYMENT_METHOD';
  end if;

  -- ---------- rate limit ----------
  if not check_rate_limit(v_phone, 'create_order', 8, interval '10 minutes') then
    raise exception 'RATE_LIMITED';
  end if;

  -- ---------- serialize per customer, then check the cap ----------
  perform pg_advisory_xact_lock(hashtext('janeiro_orders_' || v_phone));

  select coalesce((select value::int from store_settings where key = 'max_active_orders'), 2)
    into v_max_active;

  if count_active_orders(v_phone) >= v_max_active then
    raise exception 'ACTIVE_ORDER_LIMIT';
  end if;

  select coalesce((select value from store_settings where key = 'currency'), 'دج')
    into v_currency;

  v_number := generate_order_number();

  begin
    insert into orders (
      order_number, customer_name, customer_phone, normalized_phone, customer_wilaya,
      payment_method_id, subtotal, total, currency, status, idempotency_key, client_ip
    ) values (
      v_number, trim(p_name), p_phone, v_phone, nullif(trim(coalesce(p_wilaya,'')), ''),
      p_payment_method, 0, 0, v_currency, 'awaiting_receipt', p_idempotency_key,
      safe_inet(p_client_ip)
    ) returning id into v_order_id;
  exception when unique_violation then
    select * into v_existing from orders where idempotency_key = p_idempotency_key;
    if not found then raise; end if;
    return jsonb_build_object(
      'order_id', v_existing.id,
      'order_number', v_existing.order_number,
      'subtotal', v_existing.subtotal,
      'total', v_existing.total,
      'currency', v_existing.currency,
      'status', v_existing.status,
      'idempotent_replay', true
    );
  end;

  -- ---------- items ----------
  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_product from products
      where id = (v_item->>'product_id')::uuid;
    if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;

    if v_product.status <> 'published' or v_product.archived_at is not null then
      raise exception 'PRODUCT_NOT_PURCHASABLE:%', v_product.name;
    end if;

    select * into v_plan from product_plans
      where id = (v_item->>'plan_id')::uuid;
    if not found then raise exception 'PLAN_NOT_FOUND'; end if;
    if v_plan.product_id <> v_product.id then raise exception 'PLAN_PRODUCT_MISMATCH'; end if;
    if not v_plan.is_active then raise exception 'PLAN_INACTIVE'; end if;

    v_qty := coalesce((v_item->>'quantity')::int, 1);
    if v_qty < 1 or v_qty > 10 then raise exception 'INVALID_QUANTITY'; end if;

    -- ---------- نوع التفعيل ----------
    -- Read off the product, never off the payload: the store decides how
    -- each product is activated, so anything the browser sends about it
    -- is ignored exactly the way a price would be.
    v_act_type := nullif(trim(coalesce(v_product.activation_type, '')), '');

    -- price from the DB: a live deal if there is one, else the list price.
    -- Nothing price-like from the client is consulted, deal or not.
    v_unit := coalesce(active_deal_price(v_product.id, v_plan.id), v_plan.price);
    v_line := v_unit * v_qty;
    v_subtotal := v_subtotal + v_line;

    v_warranty := case v_product.warranty_type
      when 'subscription_duration' then 'ضمان طوال مدة الاشتراك'
      when 'days'      then 'ضمان ' || v_product.warranty_days || ' يوم'
      when 'activation'then 'ضمان التفعيل'
      when 'custom'    then v_product.warranty_label
      else null end;

    insert into order_items (
      order_id, product_id, plan_id, product_name_snapshot, plan_name_snapshot,
      unit_price, quantity, total_price, warranty_label_snapshot, activation_type
    ) values (
      v_order_id, v_product.id, v_plan.id, v_product.name, v_plan.name,
      v_unit, v_qty, v_line, v_warranty, v_act_type
    ) returning id into v_item_id;

    -- ---------- activation data ----------
    for v_req in
      select * from product_requirements where product_id = v_product.id order by sort_order
    loop
      v_value := null;
      for v_act in select * from jsonb_array_elements(coalesce(v_item->'activation','[]'::jsonb)) loop
        if v_act->>'label' = v_req.label then
          v_value := nullif(trim(v_act->>'value'), '');
        end if;
      end loop;

      if v_req.is_required and v_value is null then
        raise exception 'MISSING_ACTIVATION_FIELD:%', v_req.label;
      end if;

      if v_value is not null then
        if char_length(v_value) > 300 then raise exception 'ACTIVATION_VALUE_TOO_LONG'; end if;
        if v_req.field_type = 'email' and v_value !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
          raise exception 'INVALID_EMAIL_FIELD:%', v_req.label;
        end if;
        insert into order_activation_data (order_item_id, field_label, field_type, field_value)
        values (v_item_id, v_req.label, v_req.field_type, v_value);
      end if;
    end loop;
  end loop;

  update orders set subtotal = v_subtotal, total = v_subtotal where id = v_order_id;

  return jsonb_build_object(
    'order_id', v_order_id,
    'order_number', v_number,
    'subtotal', v_subtotal,
    'total', v_subtotal,
    'currency', v_currency,
    'status', 'awaiting_receipt',
    'idempotent_replay', false
  );
end $$;

revoke all on function create_order(text,text,text,uuid,jsonb,text,text) from public, anon, authenticated;

-- ------------------------------------------------------------
-- The catalogue editor: reissued from 013 so it reads and writes the
-- column. A function that does not know about a field blanks it on
-- every save, which is why both are recreated whole rather than
-- patched around.
-- ------------------------------------------------------------
create or replace function admin_list_products()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not is_admin() then raise exception 'NOT_AUTHORIZED'; end if;

  select coalesce(jsonb_agg(row order by row->>'sort_order', row->>'name'), '[]'::jsonb)
    into v
  from (
    select jsonb_build_object(
      'id', p.id, 'slug', p.slug, 'name', p.name, 'status', p.status,
      'sort_order', p.sort_order, 'poster_path', p.poster_path,
      'icon_path', p.icon_path,
      'activation_type', p.activation_type,
      'accent_color', p.accent_color, 'category_slug', c.slug,
      'short_description', p.short_description, 'description', p.description,
      'warranty_type', p.warranty_type, 'warranty_days', p.warranty_days,
      'warranty_label', p.warranty_label,
      'badge_type', p.badge_type, 'badge_label', p.badge_label,
      'delivery_min', p.delivery_min, 'delivery_max', p.delivery_max,
      'delivery_unit', p.delivery_unit, 'delivery_label', p.delivery_label,
      'plans', coalesce((select jsonb_agg(jsonb_build_object(
                  'id', pl.id, 'name', pl.name, 'price', pl.price,
                  'old_price', pl.old_price, 'duration_value', pl.duration_value,
                  'duration_unit', pl.duration_unit, 'is_active', pl.is_active,
                  'sort_order', pl.sort_order) order by pl.sort_order)
                from product_plans pl where pl.product_id = p.id), '[]'::jsonb),
      'features', coalesce((select jsonb_agg(f.label order by f.sort_order)
                from product_features f where f.product_id = p.id), '[]'::jsonb),
      'requirements', coalesce((select jsonb_agg(jsonb_build_object(
                  'label', r.label, 'field_type', r.field_type,
                  'placeholder', r.placeholder, 'is_required', r.is_required)
                  order by r.sort_order)
                from product_requirements r where r.product_id = p.id), '[]'::jsonb),
      'order_count', (select count(*) from order_items i where i.product_id = p.id)
    ) as row
    from products p
    left join categories c on c.id = p.category_id
    where p.archived_at is null
  ) s;
  return v;
end $$;

-- Only the product row changes in the upsert; plans, features and
-- requirements are untouched, so those blocks are carried over verbatim
-- from 012.

create or replace function admin_upsert_product(p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id        uuid;
  v_slug      text;
  v_cat       uuid;
  v_status    product_status;
  v_plan      jsonb;
  v_req       jsonb;
  v_feat      jsonb;
  v_plan_id   uuid;
  v_kept      uuid[] := '{}';
  v_active    int := 0;
  i           int := 0;
begin
  if not is_admin() then raise exception 'NOT_AUTHORIZED'; end if;

  v_slug := lower(trim(coalesce(p_payload->>'slug', '')));
  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
    raise exception 'INVALID_SLUG';
  end if;
  if char_length(trim(coalesce(p_payload->>'name',''))) < 1 then
    raise exception 'INVALID_NAME';
  end if;

  select id into v_cat from categories where slug = p_payload->>'category_slug';
  if v_cat is null then raise exception 'CATEGORY_NOT_FOUND'; end if;

  v_status := coalesce(nullif(p_payload->>'status',''), 'draft')::product_status;

  for v_plan in select * from jsonb_array_elements(coalesce(p_payload->'plans','[]'::jsonb)) loop
    if coalesce((v_plan->>'is_active')::boolean, true) then v_active := v_active + 1; end if;
  end loop;
  if v_status = 'published' and v_active = 0 then
    raise exception 'PUBLISHED_NEEDS_A_PLAN';
  end if;

  insert into products (
    slug, name, category_id, short_description, description, accent_color,
    poster_path, thumbnail_path, icon_path, activation_type,
    warranty_type, warranty_days, warranty_label,
    badge_type, badge_label,
    delivery_min, delivery_max, delivery_unit, delivery_label,
    status, sort_order)
  values (
    v_slug,
    trim(p_payload->>'name'),
    v_cat,
    nullif(trim(coalesce(p_payload->>'short_description','')), ''),
    nullif(trim(coalesce(p_payload->>'description','')), ''),
    nullif(p_payload->>'accent_color',''),
    nullif(p_payload->>'poster_path',''),
    nullif(p_payload->>'thumbnail_path',''),
    nullif(p_payload->>'icon_path',''),
    nullif(trim(coalesce(p_payload->>'activation_type','')), ''),
    coalesce(nullif(p_payload->>'warranty_type',''),'none')::warranty_type,
    nullif(p_payload->>'warranty_days','')::int,
    nullif(trim(coalesce(p_payload->>'warranty_label','')), ''),
    nullif(p_payload->>'badge_type',''),
    nullif(trim(coalesce(p_payload->>'badge_label','')), ''),
    nullif(p_payload->>'delivery_min','')::int,
    nullif(p_payload->>'delivery_max','')::int,
    nullif(p_payload->>'delivery_unit',''),
    nullif(trim(coalesce(p_payload->>'delivery_label','')), ''),
    v_status,
    coalesce(nullif(p_payload->>'sort_order','')::int, 0))
  on conflict (slug) do update set
    name = excluded.name, category_id = excluded.category_id,
    short_description = excluded.short_description, description = excluded.description,
    accent_color = excluded.accent_color, poster_path = excluded.poster_path,
    thumbnail_path = excluded.thumbnail_path, icon_path = excluded.icon_path,
    activation_type = excluded.activation_type,
    warranty_type = excluded.warranty_type, warranty_days = excluded.warranty_days,
    warranty_label = excluded.warranty_label,
    badge_type = excluded.badge_type, badge_label = excluded.badge_label,
    delivery_min = excluded.delivery_min, delivery_max = excluded.delivery_max,
    delivery_unit = excluded.delivery_unit, delivery_label = excluded.delivery_label,
    status = excluded.status, sort_order = excluded.sort_order
  returning id into v_id;

  i := 0;
  for v_plan in select * from jsonb_array_elements(coalesce(p_payload->'plans','[]'::jsonb)) loop
    i := i + 1;
    v_plan_id := nullif(v_plan->>'id','')::uuid;
    if v_plan_id is not null then
      update product_plans set
        name = trim(v_plan->>'name'),
        price = (v_plan->>'price')::numeric,
        old_price = nullif(v_plan->>'old_price','')::numeric,
        duration_value = nullif(v_plan->>'duration_value','')::int,
        duration_unit = nullif(v_plan->>'duration_unit',''),
        is_active = coalesce((v_plan->>'is_active')::boolean, true),
        sort_order = i
      where id = v_plan_id and product_id = v_id;
      if not found then raise exception 'PLAN_NOT_ON_THIS_PRODUCT'; end if;
    else
      insert into product_plans (product_id, name, price, old_price,
                                 duration_value, duration_unit, is_active, sort_order)
      values (v_id, trim(v_plan->>'name'), (v_plan->>'price')::numeric,
              nullif(v_plan->>'old_price','')::numeric,
              nullif(v_plan->>'duration_value','')::int,
              nullif(v_plan->>'duration_unit',''),
              coalesce((v_plan->>'is_active')::boolean, true), i)
      returning id into v_plan_id;
    end if;
    v_kept := v_kept || v_plan_id;
  end loop;

  update product_plans set is_active = false
   where product_id = v_id and not (id = any(v_kept));

  delete from product_features where product_id = v_id;
  i := 0;
  for v_feat in select * from jsonb_array_elements(coalesce(p_payload->'features','[]'::jsonb)) loop
    i := i + 1;
    if char_length(trim(v_feat #>> '{}')) > 0 then
      insert into product_features (product_id, label, sort_order)
      values (v_id, trim(v_feat #>> '{}'), i);
    end if;
  end loop;

  delete from product_requirements where product_id = v_id;
  i := 0;
  for v_req in select * from jsonb_array_elements(coalesce(p_payload->'requirements','[]'::jsonb)) loop
    i := i + 1;
    if char_length(trim(coalesce(v_req->>'label',''))) = 0 then continue; end if;
    insert into product_requirements
      (product_id, label, field_type, placeholder, is_required, sort_order)
    values (v_id, trim(v_req->>'label'),
            coalesce(nullif(v_req->>'field_type',''),'text')::requirement_field_type,
            nullif(trim(coalesce(v_req->>'placeholder','')), ''),
            coalesce((v_req->>'is_required')::boolean, true), i);
  end loop;

  return jsonb_build_object('id', v_id, 'slug', v_slug, 'status', v_status);
end $$;


revoke all on function admin_list_products()          from public, anon;
revoke all on function admin_upsert_product(jsonb)    from public, anon;
grant execute on function admin_list_products()       to authenticated;
grant execute on function admin_upsert_product(jsonb) to authenticated;

-- ── 016_bundles.sql ──────────────────────────────────────
-- ============================================================
-- Janeiro Store — 016 الباقات (bundles)
--
-- A bundle is several products sold together for ONE hand-entered
-- price, lower than the sum of the plans it contains.
--
-- It is a separate system from daily_deals and does not touch it. A
-- deal is a time-boxed price on ONE plan; a bundle is a permanent
-- grouping of SEVERAL, with no clock. They can coexist on the same
-- product, and where they do the bundle wins for the lines inside it:
-- the bundle price is a total for the group, so a per-line deal price
-- underneath it would be discounting a figure nobody is charged.
--
-- The price is entered by hand, never computed as a percentage. That
-- is the whole point of the feature: the owner decides what the group
-- costs. What the server refuses is a "bundle" that is not one --
-- fewer than two products, or a price at or above the list total.
--
-- Where the money is decided:
--   * bundle_price lives here, in the database, and create_order reads
--     it from here. A price in a file the browser loads would be a
--     price the browser could edit.
--   * The lines still record each product at its own list price, so
--     the fulfilment list stays true and the saving is visible; the
--     difference is recorded once, on the order, as discount_total.
--     orders.total = subtotal - discount_total.
-- ============================================================

-- ---------- the bundle ----------
create table if not exists bundles (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique
                 check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(slug) <= 60),
  name         text not null check (char_length(name) between 2 and 120),
  short_description text check (char_length(short_description) <= 300),

  -- the whole feature: a total the owner types, not a percentage
  bundle_price numeric(12,2) not null check (bundle_price >= 0),

  is_active    boolean not null default true,
  sort_order   integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- ---------- what is in it ----------
-- plan_id, not just product_id: a product costs different money on
-- different plans, so a bundle has to name which plan of each product
-- it contains or its list total is undefined.
create table if not exists bundle_items (
  id         uuid primary key default gen_random_uuid(),
  bundle_id  uuid not null references bundles(id)       on delete cascade,
  product_id uuid not null references products(id)      on delete cascade,
  plan_id    uuid not null references product_plans(id) on delete cascade,
  sort_order integer not null default 0,
  constraint bundle_item_unique unique (bundle_id, product_id)
);

create index if not exists idx_bundle_items_bundle on bundle_items(bundle_id, sort_order);
create index if not exists idx_bundles_live on bundles(is_active, sort_order);

drop trigger if exists trg_bundles_updated on bundles;
create trigger trg_bundles_updated before update on bundles
  for each row execute function set_updated_at();

-- ------------------------------------------------------------
-- The plan must belong to the product. Reads another table, so it is
-- a trigger rather than a CHECK -- the same shape validate_daily_deal
-- uses.
-- ------------------------------------------------------------
create or replace function validate_bundle_item()
returns trigger language plpgsql as $$
declare v_product uuid;
begin
  select product_id into v_product from product_plans where id = new.plan_id;
  if not found then raise exception 'BUNDLE_PLAN_NOT_FOUND'; end if;
  if v_product <> new.product_id then raise exception 'BUNDLE_PLAN_PRODUCT_MISMATCH'; end if;
  return new;
end $$;

drop trigger if exists trg_bundle_items_validate on bundle_items;
create trigger trg_bundle_items_validate before insert or update on bundle_items
  for each row execute function validate_bundle_item();

-- ------------------------------------------------------------
-- The list total of a bundle: what its plans cost bought separately.
-- NULL when the bundle has no items. Deals are deliberately not
-- consulted -- this is the "before" figure the saving is measured
-- against, and it has to be the shelf price.
-- ------------------------------------------------------------
create or replace function bundle_list_total(p_bundle uuid)
returns numeric
language sql stable security definer set search_path = public as $$
  select sum(pl.price)
    from bundle_items bi
    join product_plans pl on pl.id = bi.plan_id
   where bi.bundle_id = p_bundle;
$$;

-- ------------------------------------------------------------
-- Is this bundle sellable right now? Two products at least, every one
-- of them published and every plan active. A bundle that has lost a
-- product to archiving is not quietly sold as a smaller bundle at the
-- same price: it stops being offered until the owner fixes it.
-- ------------------------------------------------------------
create or replace function bundle_is_sellable(p_bundle uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select count(*) >= 2
     and count(*) filter (
           where p.status = 'published' and p.archived_at is null and pl.is_active
         ) = count(*)
    from bundle_items bi
    join products      p  on p.id  = bi.product_id
    join product_plans pl on pl.id = bi.plan_id
   where bi.bundle_id = p_bundle;
$$;

-- ------------------------------------------------------------
-- A bundle has to be a saving and has to be a group. Checked on the
-- bundle row and on every item change, because either side can break
-- it: raising the price, or removing the product that made it cheap.
--
-- Deferred by design in one direction only: a brand-new bundle is
-- allowed to exist with no items yet (you cannot insert items into a
-- bundle that does not exist), but it cannot be ACTIVE until it holds
-- two products and undercuts their list total.
-- ------------------------------------------------------------
create or replace function validate_bundle_shape()
returns trigger language plpgsql as $$
declare
  v_bundle uuid;
  v_count  int;
  v_list   numeric(12,2);
  v_price  numeric(12,2);
  v_active boolean;
begin
  /* An IF, not a CASE: a CASE expression is handed to SQL whole, so
     `new.bundle_id` is resolved even on the branch for the bundles
     table, where that field does not exist, and every insert died. */
  if tg_table_name = 'bundles' then
    v_bundle := new.id;
  else
    v_bundle := new.bundle_id;
  end if;

  select b.bundle_price, b.is_active into v_price, v_active from bundles b where b.id = v_bundle;
  if not found then return new; end if;      -- item of a bundle being deleted
  if not v_active then return new; end if;   -- an inactive draft may be anything

  select count(*), coalesce(sum(pl.price), 0) into v_count, v_list
    from bundle_items bi join product_plans pl on pl.id = bi.plan_id
   where bi.bundle_id = v_bundle;

  if v_count < 2 then raise exception 'BUNDLE_NEEDS_TWO_PRODUCTS'; end if;
  if v_price >= v_list then raise exception 'BUNDLE_PRICE_NOT_LOWER'; end if;
  return new;
end $$;

drop trigger if exists trg_bundles_shape on bundles;
create trigger trg_bundles_shape after insert or update on bundles
  for each row execute function validate_bundle_shape();

drop trigger if exists trg_bundle_items_shape on bundle_items;
create trigger trg_bundle_items_shape after insert or update on bundle_items
  for each row execute function validate_bundle_shape();

-- ------------------------------------------------------------
-- RLS: the public sees active bundles; everything else is the admin's.
-- ------------------------------------------------------------
alter table bundles      enable row level security;
alter table bundle_items enable row level security;

drop policy if exists "public read active bundles" on bundles;
drop policy if exists "admin manage bundles"       on bundles;
drop policy if exists "public read bundle items"   on bundle_items;
drop policy if exists "admin manage bundle items"  on bundle_items;

create policy "public read active bundles" on bundles
  for select using (is_active);
create policy "admin manage bundles" on bundles
  for all using (is_admin()) with check (is_admin());

create policy "public read bundle items" on bundle_items
  for select using (exists (select 1 from bundles b where b.id = bundle_id and b.is_active));
create policy "admin manage bundle items" on bundle_items
  for all using (is_admin()) with check (is_admin());

-- ------------------------------------------------------------
-- What the storefront reads: one row per sellable bundle, carrying
-- its products already joined, the list total, the price and the
-- saving. All three figures are computed here so the card, the
-- struck-through total and the percentage all come from the server
-- rather than from arithmetic in the browser.
-- ------------------------------------------------------------
-- The two helpers above are inlined here rather than called: a view is
-- read by anon, and EXECUTE on a function is checked against whoever is
-- reading no matter that the function is SECURITY DEFINER. Granting
-- anon execute on them would widen the surface for nothing -- one
-- lateral join computes both in a single pass instead.
drop view if exists public_bundles;
create view public_bundles as
select
  b.id,
  b.slug,
  b.name,
  b.short_description,
  b.bundle_price,
  agg.list_total,
  agg.list_total - b.bundle_price                                as saving,
  round((1 - b.bundle_price / nullif(agg.list_total, 0)) * 100)   as saving_pct,
  b.sort_order,
  agg.items
from bundles b
cross join lateral (
  select
    coalesce(sum(pl.price), 0)                                    as list_total,
    count(*)                                                      as n,
    count(*) filter (where p.status = 'published'
                       and p.archived_at is null
                       and pl.is_active)                          as n_sellable,
    jsonb_agg(jsonb_build_object(
      'product_id',   p.id,
      'plan_id',      pl.id,
      'name',         p.name,
      'slug',         p.slug,
      'plan_name',    pl.name,
      'price',        pl.price,
      'icon_path',    p.icon_path,
      'poster_path',  p.poster_path,
      'accent_color', p.accent_color)
      order by bi.sort_order, p.name)                             as items
  from bundle_items bi
  join products      p  on p.id  = bi.product_id
  join product_plans pl on pl.id = bi.plan_id
  where bi.bundle_id = b.id
) agg
where b.is_active
  and agg.n >= 2
  and agg.n_sellable = agg.n;

grant select on public_bundles to anon, authenticated;

revoke all on function bundle_list_total(uuid)  from public, anon, authenticated;
revoke all on function bundle_is_sellable(uuid) from public, anon, authenticated;

-- ------------------------------------------------------------
-- The order side.
--
-- Lines keep their own list price so the fulfilment list and the
-- money story are both true, and carry the bundle they came in.
-- The saving is recorded once, on the order.
-- ------------------------------------------------------------
alter table orders      add column if not exists discount_total numeric(12,2) not null default 0;
alter table order_items add column if not exists bundle_id uuid references bundles(id) on delete set null;
alter table order_items add column if not exists bundle_name_snapshot text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'orders_discount_total_ok') then
    alter table orders add constraint orders_discount_total_ok
      check (discount_total >= 0 and discount_total <= subtotal);
  end if;
end $$;

comment on column orders.discount_total is
  'مجموع ما وفّرته الباقات في هذا الطلب. total = subtotal - discount_total.';
comment on column order_items.bundle_id is
  'الباقة التي جاء منها هذا السطر، إن وُجدت. السعر في السطر هو سعر القائمة.';

-- ------------------------------------------------------------
-- CREATE ORDER — reissued from 015 so a cart can carry a bundle.
--
-- The only thing the payload may say about a bundle is its id, on the
-- lines that claim to belong to it. Everything else is read here.
-- ------------------------------------------------------------
create or replace function create_order(
  p_name             text,
  p_phone            text,
  p_wilaya           text,
  p_payment_method   uuid,
  p_items            jsonb,
  p_idempotency_key  text,
  p_client_ip        text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_phone     text;
  v_order_id  uuid;
  v_number    text;
  v_subtotal  numeric(12,2) := 0;
  v_currency  text;
  v_max_active int;
  v_item      jsonb;
  v_product   products%rowtype;
  v_plan      product_plans%rowtype;
  v_qty       int;
  v_unit      numeric(12,2);
  v_line      numeric(12,2);
  v_item_id   uuid;
  v_req       product_requirements%rowtype;
  v_act       jsonb;
  v_value     text;
  v_act_type  text;
  v_bundle    bundles%rowtype;
  v_bundle_id uuid;
  v_discount  numeric(12,2) := 0;
  v_grp       record;
  v_grp_qty   int;
  v_grp_list  numeric(12,2);
  v_grp_count int;
  v_existing  orders%rowtype;
  v_warranty  text;
begin
  -- ---------- idempotency: same key -> same order ----------
  select * into v_existing from orders where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'order_id', v_existing.id,
      'order_number', v_existing.order_number,
      'subtotal', v_existing.subtotal,
      'discount_total', v_existing.discount_total,
      'total', v_existing.total,
      'currency', v_existing.currency,
      'status', v_existing.status,
      'idempotent_replay', true
    );
  end if;

  -- ---------- basic input validation ----------
  if p_name is null or char_length(trim(p_name)) < 2 then
    raise exception 'INVALID_NAME';
  end if;
  if char_length(p_name) > 80 then raise exception 'INVALID_NAME'; end if;

  v_phone := normalize_dz_phone(p_phone);
  if v_phone is null then raise exception 'INVALID_PHONE'; end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'EMPTY_CART';
  end if;
  if jsonb_array_length(p_items) > 20 then raise exception 'CART_TOO_LARGE'; end if;

  if p_payment_method is null
     or not exists (select 1 from payment_methods where id = p_payment_method and is_active) then
    raise exception 'INVALID_PAYMENT_METHOD';
  end if;

  -- ---------- rate limit ----------
  if not check_rate_limit(v_phone, 'create_order', 8, interval '10 minutes') then
    raise exception 'RATE_LIMITED';
  end if;

  -- ---------- serialize per customer, then check the cap ----------
  perform pg_advisory_xact_lock(hashtext('janeiro_orders_' || v_phone));

  select coalesce((select value::int from store_settings where key = 'max_active_orders'), 2)
    into v_max_active;

  if count_active_orders(v_phone) >= v_max_active then
    raise exception 'ACTIVE_ORDER_LIMIT';
  end if;

  select coalesce((select value from store_settings where key = 'currency'), 'دج')
    into v_currency;

  v_number := generate_order_number();

  begin
    insert into orders (
      order_number, customer_name, customer_phone, normalized_phone, customer_wilaya,
      payment_method_id, subtotal, total, currency, status, idempotency_key, client_ip
    ) values (
      v_number, trim(p_name), p_phone, v_phone, nullif(trim(coalesce(p_wilaya,'')), ''),
      p_payment_method, 0, 0, v_currency, 'awaiting_receipt', p_idempotency_key,
      safe_inet(p_client_ip)
    ) returning id into v_order_id;
  exception when unique_violation then
    select * into v_existing from orders where idempotency_key = p_idempotency_key;
    if not found then raise; end if;
    return jsonb_build_object(
      'order_id', v_existing.id,
      'order_number', v_existing.order_number,
      'subtotal', v_existing.subtotal,
      'discount_total', v_existing.discount_total,
      'total', v_existing.total,
      'currency', v_existing.currency,
      'status', v_existing.status,
      'idempotent_replay', true
    );
  end;

  -- ---------- items ----------
  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_product from products
      where id = (v_item->>'product_id')::uuid;
    if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;

    if v_product.status <> 'published' or v_product.archived_at is not null then
      raise exception 'PRODUCT_NOT_PURCHASABLE:%', v_product.name;
    end if;

    select * into v_plan from product_plans
      where id = (v_item->>'plan_id')::uuid;
    if not found then raise exception 'PLAN_NOT_FOUND'; end if;
    if v_plan.product_id <> v_product.id then raise exception 'PLAN_PRODUCT_MISMATCH'; end if;
    if not v_plan.is_active then raise exception 'PLAN_INACTIVE'; end if;

    v_qty := coalesce((v_item->>'quantity')::int, 1);
    if v_qty < 1 or v_qty > 10 then raise exception 'INVALID_QUANTITY'; end if;

    -- ---------- نوع التفعيل ----------
    -- Read off the product, never off the payload: the store decides how
    -- each product is activated, so anything the browser sends about it
    -- is ignored exactly the way a price would be.
    v_act_type := nullif(trim(coalesce(v_product.activation_type, '')), '');

    -- ---------- the bundle this line claims to be part of ----------
    -- Only the id is taken from the payload; everything about the
    -- bundle -- that it exists, is active, is sellable, what it holds
    -- and what it costs -- is read here. The group is checked as a
    -- whole after every line is in.
    v_bundle_id := nullif(v_item->>'bundle_id','')::uuid;
    if v_bundle_id is not null then
      select * into v_bundle from bundles where id = v_bundle_id;
      if not found or not v_bundle.is_active then raise exception 'BUNDLE_NOT_FOUND'; end if;
      if not bundle_is_sellable(v_bundle.id) then raise exception 'BUNDLE_NOT_AVAILABLE'; end if;
    end if;

    -- price from the DB: a live deal if there is one, else the list
    -- price. Nothing price-like from the client is consulted, deal or
    -- not. A line inside a bundle is held at its LIST price: the
    -- bundle price is a total for the group, so discounting a line
    -- underneath it would be discounting a figure nobody is charged.
    v_unit := case when v_bundle_id is null
                   then coalesce(active_deal_price(v_product.id, v_plan.id), v_plan.price)
                   else v_plan.price end;
    v_line := v_unit * v_qty;
    v_subtotal := v_subtotal + v_line;

    v_warranty := case v_product.warranty_type
      when 'subscription_duration' then 'ضمان طوال مدة الاشتراك'
      when 'days'      then 'ضمان ' || v_product.warranty_days || ' يوم'
      when 'activation'then 'ضمان التفعيل'
      when 'custom'    then v_product.warranty_label
      else null end;

    insert into order_items (
      order_id, product_id, plan_id, product_name_snapshot, plan_name_snapshot,
      unit_price, quantity, total_price, warranty_label_snapshot, activation_type,
      bundle_id, bundle_name_snapshot
    ) values (
      v_order_id, v_product.id, v_plan.id, v_product.name, v_plan.name,
      v_unit, v_qty, v_line, v_warranty, v_act_type,
      v_bundle_id, case when v_bundle_id is null then null else v_bundle.name end
    ) returning id into v_item_id;

    -- ---------- activation data ----------
    for v_req in
      select * from product_requirements where product_id = v_product.id order by sort_order
    loop
      v_value := null;
      for v_act in select * from jsonb_array_elements(coalesce(v_item->'activation','[]'::jsonb)) loop
        if v_act->>'label' = v_req.label then
          v_value := nullif(trim(v_act->>'value'), '');
        end if;
      end loop;

      if v_req.is_required and v_value is null then
        raise exception 'MISSING_ACTIVATION_FIELD:%', v_req.label;
      end if;

      if v_value is not null then
        if char_length(v_value) > 300 then raise exception 'ACTIVATION_VALUE_TOO_LONG'; end if;
        if v_req.field_type = 'email' and v_value !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
          raise exception 'INVALID_EMAIL_FIELD:%', v_req.label;
        end if;
        insert into order_activation_data (order_item_id, field_label, field_type, field_value)
        values (v_item_id, v_req.label, v_req.field_type, v_value);
      end if;
    end loop;
  end loop;

  -- ---------- price each bundle as a group ----------
  -- Done after the lines are in, because a bundle is only a bundle if
  -- the WHOLE of it is there. A cart carrying three of a four-product
  -- bundle is not that bundle at a bundle price; the storefront drops
  -- the tag when a product is removed, and a payload that did not is
  -- refused rather than quietly charged the smaller list total.
  for v_grp in
    select bundle_id, min(quantity) as q_min, max(quantity) as q_max,
           count(*) as n, sum(total_price) as list_sum
      from order_items
     where order_id = v_order_id and bundle_id is not null
     group by bundle_id
  loop
    select * into v_bundle from bundles where id = v_grp.bundle_id;

    -- every product of the bundle present, and nothing else tagged with it
    select count(*) into v_grp_count from bundle_items where bundle_id = v_bundle.id;
    if v_grp.n <> v_grp_count then raise exception 'BUNDLE_INCOMPLETE:%', v_bundle.name; end if;
    if exists (
      select 1 from order_items oi
       where oi.order_id = v_order_id and oi.bundle_id = v_bundle.id
         and not exists (select 1 from bundle_items bi
                          where bi.bundle_id = v_bundle.id
                            and bi.product_id = oi.product_id
                            and bi.plan_id    = oi.plan_id)
    ) then raise exception 'BUNDLE_INCOMPLETE:%', v_bundle.name; end if;

    -- one bundle bought twice is two of everything in it, so the lines
    -- have to agree on how many
    if v_grp.q_min <> v_grp.q_max then raise exception 'BUNDLE_QUANTITY_MISMATCH:%', v_bundle.name; end if;
    v_grp_qty  := v_grp.q_min;
    v_grp_list := v_grp.list_sum;

    -- the saving: what the group lists for, minus what the owner
    -- decided the group costs
    v_discount := v_discount + (v_grp_list - v_bundle.bundle_price * v_grp_qty);
  end loop;

  if v_discount < 0 then v_discount := 0; end if;
  if v_discount > v_subtotal then v_discount := v_subtotal; end if;

  update orders
     set subtotal = v_subtotal,
         discount_total = v_discount,
         total = v_subtotal - v_discount
   where id = v_order_id;

  return jsonb_build_object(
    'order_id', v_order_id,
    'order_number', v_number,
    'subtotal', v_subtotal,
    'discount_total', v_discount,
    'total', v_subtotal - v_discount,
    'currency', v_currency,
    'status', 'awaiting_receipt',
    'idempotent_replay', false
  );
end $$;

revoke all on function create_order(text,text,text,uuid,jsonb,text,text) from public, anon, authenticated;

-- ── 017_admin_bundles.sql ──────────────────────────────────────
-- ============================================================
-- Janeiro Store — 017 إدارة الباقات من اللوحة
--
-- Three RPCs, admin-only, shaped like the product ones in 012/013.
--
-- The upsert deactivates the bundle before it touches the items and
-- reactivates it after. The shape triggers from 016 are immediate and
-- fire per row, so replacing a live bundle's items would trip
-- BUNDLE_NEEDS_TWO_PRODUCTS on the first insert -- a bundle is briefly
-- one product long in the middle of its own edit. Deferring the
-- triggers would have hidden the error until COMMIT, where a test
-- cannot catch it and a caller cannot say which statement was wrong;
-- stepping through inactive keeps the check immediate and honest, and
-- an inactive bundle is allowed to be any shape at all.
-- ============================================================

create or replace function admin_list_bundles()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not is_admin() then raise exception 'NOT_AUTHORIZED'; end if;

  select coalesce(jsonb_agg(row order by row->>'sort_order', row->>'name'), '[]'::jsonb)
    into v
  from (
    select jsonb_build_object(
      'id', b.id, 'slug', b.slug, 'name', b.name,
      'short_description', b.short_description,
      'bundle_price', b.bundle_price,
      'is_active', b.is_active,
      'sort_order', b.sort_order,
      'list_total', coalesce((
         select sum(pl.price) from bundle_items bi
           join product_plans pl on pl.id = bi.plan_id
          where bi.bundle_id = b.id), 0),
      -- why a bundle is not on the storefront, so the owner is not left
      -- guessing: it is off, too small, or one of its products is gone
      'sellable', coalesce((
         select count(*) >= 2 and count(*) filter (
                  where p.status = 'published' and p.archived_at is null and pl.is_active
                ) = count(*)
           from bundle_items bi
           join products p       on p.id  = bi.product_id
           join product_plans pl on pl.id = bi.plan_id
          where bi.bundle_id = b.id), false),
      'items', coalesce((
         select jsonb_agg(jsonb_build_object(
                  'product_id', p.id, 'plan_id', pl.id,
                  'product_name', p.name, 'product_slug', p.slug,
                  'plan_name', pl.name, 'price', pl.price,
                  'published', p.status = 'published' and p.archived_at is null and pl.is_active)
                order by bi.sort_order, p.name)
           from bundle_items bi
           join products p       on p.id  = bi.product_id
           join product_plans pl on pl.id = bi.plan_id
          where bi.bundle_id = b.id), '[]'::jsonb)
    ) as row
    from bundles b
  ) s;
  return v;
end $$;

-- ------------------------------------------------------------
-- Create or edit one bundle, items and all. Keyed by slug, like
-- admin_upsert_product, so a saved bundle keeps its id and the orders
-- that point at it stay pointing at it.
-- ------------------------------------------------------------
create or replace function admin_upsert_bundle(p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_slug   text;
  v_id     uuid;
  v_active boolean;
  v_item   jsonb;
  i        int := 0;
begin
  if not is_admin() then raise exception 'NOT_AUTHORIZED'; end if;

  v_slug := lower(trim(coalesce(p_payload->>'slug','')));
  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then raise exception 'INVALID_SLUG'; end if;
  if char_length(trim(coalesce(p_payload->>'name',''))) < 2 then raise exception 'INVALID_NAME'; end if;
  if nullif(p_payload->>'bundle_price','') is null then raise exception 'INVALID_BUNDLE_PRICE'; end if;

  v_active := coalesce((p_payload->>'is_active')::boolean, false);

  -- written inactive first: the row and its items have to be settled
  -- before the shape rules can fairly judge them
  insert into bundles (slug, name, short_description, bundle_price, is_active, sort_order)
  values (
    v_slug,
    trim(p_payload->>'name'),
    nullif(trim(coalesce(p_payload->>'short_description','')), ''),
    (p_payload->>'bundle_price')::numeric,
    false,
    coalesce(nullif(p_payload->>'sort_order','')::int, 0))
  on conflict (slug) do update set
    name = excluded.name,
    short_description = excluded.short_description,
    bundle_price = excluded.bundle_price,
    is_active = false,
    sort_order = excluded.sort_order
  returning id into v_id;

  delete from bundle_items where bundle_id = v_id;

  for v_item in select * from jsonb_array_elements(coalesce(p_payload->'items','[]'::jsonb)) loop
    i := i + 1;
    insert into bundle_items (bundle_id, product_id, plan_id, sort_order)
    values (v_id, (v_item->>'product_id')::uuid, (v_item->>'plan_id')::uuid, i);
  end loop;

  -- and only now judged: two products at least, and a real saving
  if v_active then
    update bundles set is_active = true where id = v_id;
  end if;

  return jsonb_build_object('id', v_id, 'slug', v_slug, 'is_active', v_active);
end $$;

-- ------------------------------------------------------------
-- Delete. Orders keep their lines: order_items.bundle_id is ON DELETE
-- SET NULL and bundle_name_snapshot is a snapshot, so a deleted bundle
-- leaves the history readable instead of erasing what was sold.
-- ------------------------------------------------------------
create or replace function admin_delete_bundle(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_slug text;
begin
  if not is_admin() then raise exception 'NOT_AUTHORIZED'; end if;
  select slug into v_slug from bundles where id = p_id;
  if not found then raise exception 'BUNDLE_NOT_FOUND'; end if;
  delete from bundles where id = p_id;
  return jsonb_build_object('deleted', v_slug);
end $$;

revoke all on function admin_list_bundles()        from public, anon;
revoke all on function admin_upsert_bundle(jsonb)  from public, anon;
revoke all on function admin_delete_bundle(uuid)   from public, anon;
grant execute on function admin_list_bundles()       to authenticated;
grant execute on function admin_upsert_bundle(jsonb) to authenticated;
grant execute on function admin_delete_bundle(uuid)  to authenticated;

-- ── 018_order_updates.sql ──────────────────────────────────────
-- ============================================================
-- Janeiro Store — 018 order number, customer note, full-phone tracking
--
-- Three changes:
--   1. generate_order_number(): shorter, digits-only (6 digits) —
--      easier for a customer to read back over WhatsApp or retype.
--   2. orders.customer_note: an optional free-text message the
--      customer can attach to the order.
--   3. track_order(): matched on the customer's full phone number
--      instead of the last 4 digits — one less thing to explain.
-- ============================================================

-- ---------- 1. shorter order number ----------
create or replace function generate_order_number()
returns text language plpgsql volatile as $$
declare
  candidate text;
begin
  for attempt in 1..20 loop
    candidate := lpad(floor(random() * 1000000)::text, 6, '0');
    if not exists (select 1 from orders where order_number = candidate) then
      return candidate;
    end if;
  end loop;
  raise exception 'ORDER_NUMBER_GENERATION_FAILED';
end $$;

-- ---------- 2. customer note ----------
alter table orders add column if not exists customer_note text
  check (char_length(customer_note) <= 500);

-- ---------- create_order: same as 016_bundles.sql, plus p_customer_note ----------
create or replace function create_order(
  p_name             text,
  p_phone            text,
  p_wilaya           text,
  p_payment_method   uuid,
  p_items            jsonb,
  p_idempotency_key  text,
  p_client_ip        text default null,
  p_customer_note    text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_phone     text;
  v_order_id  uuid;
  v_number    text;
  v_subtotal  numeric(12,2) := 0;
  v_currency  text;
  v_max_active int;
  v_item      jsonb;
  v_product   products%rowtype;
  v_plan      product_plans%rowtype;
  v_qty       int;
  v_unit      numeric(12,2);
  v_line      numeric(12,2);
  v_item_id   uuid;
  v_req       product_requirements%rowtype;
  v_act       jsonb;
  v_value     text;
  v_act_type  text;
  v_bundle    bundles%rowtype;
  v_bundle_id uuid;
  v_discount  numeric(12,2) := 0;
  v_grp       record;
  v_grp_qty   int;
  v_grp_list  numeric(12,2);
  v_grp_count int;
  v_existing  orders%rowtype;
  v_warranty  text;
  v_note      text;
begin
  -- ---------- idempotency: same key -> same order ----------
  select * into v_existing from orders where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'order_id', v_existing.id,
      'order_number', v_existing.order_number,
      'subtotal', v_existing.subtotal,
      'discount_total', v_existing.discount_total,
      'total', v_existing.total,
      'currency', v_existing.currency,
      'status', v_existing.status,
      'idempotent_replay', true
    );
  end if;

  -- ---------- basic input validation ----------
  if p_name is null or char_length(trim(p_name)) < 2 then
    raise exception 'INVALID_NAME';
  end if;
  if char_length(p_name) > 80 then raise exception 'INVALID_NAME'; end if;

  v_phone := normalize_dz_phone(p_phone);
  if v_phone is null then raise exception 'INVALID_PHONE'; end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'EMPTY_CART';
  end if;
  if jsonb_array_length(p_items) > 20 then raise exception 'CART_TOO_LARGE'; end if;

  if p_payment_method is null
     or not exists (select 1 from payment_methods where id = p_payment_method and is_active) then
    raise exception 'INVALID_PAYMENT_METHOD';
  end if;

  v_note := nullif(trim(coalesce(p_customer_note, '')), '');
  if v_note is not null and char_length(v_note) > 500 then
    raise exception 'CUSTOMER_NOTE_TOO_LONG';
  end if;

  -- ---------- rate limit ----------
  if not check_rate_limit(v_phone, 'create_order', 8, interval '10 minutes') then
    raise exception 'RATE_LIMITED';
  end if;

  -- ---------- serialize per customer, then check the cap ----------
  perform pg_advisory_xact_lock(hashtext('janeiro_orders_' || v_phone));

  select coalesce((select value::int from store_settings where key = 'max_active_orders'), 2)
    into v_max_active;

  if count_active_orders(v_phone) >= v_max_active then
    raise exception 'ACTIVE_ORDER_LIMIT';
  end if;

  select coalesce((select value from store_settings where key = 'currency'), 'دج')
    into v_currency;

  v_number := generate_order_number();

  begin
    insert into orders (
      order_number, customer_name, customer_phone, normalized_phone, customer_wilaya,
      payment_method_id, subtotal, total, currency, status, idempotency_key, client_ip,
      customer_note
    ) values (
      v_number, trim(p_name), p_phone, v_phone, nullif(trim(coalesce(p_wilaya,'')), ''),
      p_payment_method, 0, 0, v_currency, 'awaiting_receipt', p_idempotency_key,
      safe_inet(p_client_ip), v_note
    ) returning id into v_order_id;
  exception when unique_violation then
    select * into v_existing from orders where idempotency_key = p_idempotency_key;
    if not found then raise; end if;
    return jsonb_build_object(
      'order_id', v_existing.id,
      'order_number', v_existing.order_number,
      'subtotal', v_existing.subtotal,
      'discount_total', v_existing.discount_total,
      'total', v_existing.total,
      'currency', v_existing.currency,
      'status', v_existing.status,
      'idempotent_replay', true
    );
  end;

  -- ---------- items ----------
  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_product from products
      where id = (v_item->>'product_id')::uuid;
    if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;

    if v_product.status <> 'published' or v_product.archived_at is not null then
      raise exception 'PRODUCT_NOT_PURCHASABLE:%', v_product.name;
    end if;

    select * into v_plan from product_plans
      where id = (v_item->>'plan_id')::uuid;
    if not found then raise exception 'PLAN_NOT_FOUND'; end if;
    if v_plan.product_id <> v_product.id then raise exception 'PLAN_PRODUCT_MISMATCH'; end if;
    if not v_plan.is_active then raise exception 'PLAN_INACTIVE'; end if;

    v_qty := coalesce((v_item->>'quantity')::int, 1);
    if v_qty < 1 or v_qty > 10 then raise exception 'INVALID_QUANTITY'; end if;

    -- ---------- نوع التفعيل ----------
    -- Read off the product, never off the payload: the store decides how
    -- each product is activated, so anything the browser sends about it
    -- is ignored exactly the way a price would be.
    v_act_type := nullif(trim(coalesce(v_product.activation_type, '')), '');

    -- ---------- the bundle this line claims to be part of ----------
    -- Only the id is taken from the payload; everything about the
    -- bundle -- that it exists, is active, is sellable, what it holds
    -- and what it costs -- is read here. The group is checked as a
    -- whole after every line is in.
    v_bundle_id := nullif(v_item->>'bundle_id','')::uuid;
    if v_bundle_id is not null then
      select * into v_bundle from bundles where id = v_bundle_id;
      if not found or not v_bundle.is_active then raise exception 'BUNDLE_NOT_FOUND'; end if;
      if not bundle_is_sellable(v_bundle.id) then raise exception 'BUNDLE_NOT_AVAILABLE'; end if;
    end if;

    -- price from the DB: a live deal if there is one, else the list
    -- price. Nothing price-like from the client is consulted, deal or
    -- not. A line inside a bundle is held at its LIST price: the
    -- bundle price is a total for the group, so discounting a line
    -- underneath it would be discounting a figure nobody is charged.
    v_unit := case when v_bundle_id is null
                   then coalesce(active_deal_price(v_product.id, v_plan.id), v_plan.price)
                   else v_plan.price end;
    v_line := v_unit * v_qty;
    v_subtotal := v_subtotal + v_line;

    v_warranty := case v_product.warranty_type
      when 'subscription_duration' then 'ضمان طوال مدة الاشتراك'
      when 'days'      then 'ضمان ' || v_product.warranty_days || ' يوم'
      when 'activation'then 'ضمان التفعيل'
      when 'custom'    then v_product.warranty_label
      else null end;

    insert into order_items (
      order_id, product_id, plan_id, product_name_snapshot, plan_name_snapshot,
      unit_price, quantity, total_price, warranty_label_snapshot, activation_type,
      bundle_id, bundle_name_snapshot
    ) values (
      v_order_id, v_product.id, v_plan.id, v_product.name, v_plan.name,
      v_unit, v_qty, v_line, v_warranty, v_act_type,
      v_bundle_id, case when v_bundle_id is null then null else v_bundle.name end
    ) returning id into v_item_id;

    -- ---------- activation data ----------
    for v_req in
      select * from product_requirements where product_id = v_product.id order by sort_order
    loop
      v_value := null;
      for v_act in select * from jsonb_array_elements(coalesce(v_item->'activation','[]'::jsonb)) loop
        if v_act->>'label' = v_req.label then
          v_value := nullif(trim(v_act->>'value'), '');
        end if;
      end loop;

      if v_req.is_required and v_value is null then
        raise exception 'MISSING_ACTIVATION_FIELD:%', v_req.label;
      end if;

      if v_value is not null then
        if char_length(v_value) > 300 then raise exception 'ACTIVATION_VALUE_TOO_LONG'; end if;
        if v_req.field_type = 'email' and v_value !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
          raise exception 'INVALID_EMAIL_FIELD:%', v_req.label;
        end if;
        insert into order_activation_data (order_item_id, field_label, field_type, field_value)
        values (v_item_id, v_req.label, v_req.field_type, v_value);
      end if;
    end loop;
  end loop;

  -- ---------- price each bundle as a group ----------
  -- Done after the lines are in, because a bundle is only a bundle if
  -- the WHOLE of it is there. A cart carrying three of a four-product
  -- bundle is not that bundle at a bundle price; the storefront drops
  -- the tag when a product is removed, and a payload that did not is
  -- refused rather than quietly charged the smaller list total.
  for v_grp in
    select bundle_id, min(quantity) as q_min, max(quantity) as q_max,
           count(*) as n, sum(total_price) as list_sum
      from order_items
     where order_id = v_order_id and bundle_id is not null
     group by bundle_id
  loop
    select * into v_bundle from bundles where id = v_grp.bundle_id;

    -- every product of the bundle present, and nothing else tagged with it
    select count(*) into v_grp_count from bundle_items where bundle_id = v_bundle.id;
    if v_grp.n <> v_grp_count then raise exception 'BUNDLE_INCOMPLETE:%', v_bundle.name; end if;
    if exists (
      select 1 from order_items oi
       where oi.order_id = v_order_id and oi.bundle_id = v_bundle.id
         and not exists (select 1 from bundle_items bi
                          where bi.bundle_id = v_bundle.id
                            and bi.product_id = oi.product_id
                            and bi.plan_id    = oi.plan_id)
    ) then raise exception 'BUNDLE_INCOMPLETE:%', v_bundle.name; end if;

    -- one bundle bought twice is two of everything in it, so the lines
    -- have to agree on how many
    if v_grp.q_min <> v_grp.q_max then raise exception 'BUNDLE_QUANTITY_MISMATCH:%', v_bundle.name; end if;
    v_grp_qty  := v_grp.q_min;
    v_grp_list := v_grp.list_sum;

    -- the saving: what the group lists for, minus what the owner
    -- decided the group costs
    v_discount := v_discount + (v_grp_list - v_bundle.bundle_price * v_grp_qty);
  end loop;

  if v_discount < 0 then v_discount := 0; end if;
  if v_discount > v_subtotal then v_discount := v_subtotal; end if;

  update orders
     set subtotal = v_subtotal,
         discount_total = v_discount,
         total = v_subtotal - v_discount
   where id = v_order_id;

  return jsonb_build_object(
    'order_id', v_order_id,
    'order_number', v_number,
    'subtotal', v_subtotal,
    'discount_total', v_discount,
    'total', v_subtotal - v_discount,
    'currency', v_currency,
    'status', 'awaiting_receipt',
    'idempotent_replay', false
  );
end $$;

revoke all on function create_order(text,text,text,uuid,jsonb,text,text,text) from public, anon, authenticated;

-- the old 7-arg signature is gone now that the 8-arg version replaces
-- it under the same name; drop it explicitly since create or replace
-- cannot change a function's argument count
drop function if exists create_order(text,text,text,uuid,jsonb,text,text);

-- ---------- 3. track by full phone, not last 4 digits ----------
-- same (text,text) signature as before, but postgres refuses to
-- rename a parameter via create or replace -- drop first.
drop function if exists track_order(text, text);

create or replace function track_order(p_order_number text, p_phone text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_order orders%rowtype; v_items jsonb; v_phone text; begin
  v_phone := normalize_dz_phone(p_phone);
  if p_order_number is null or v_phone is null then
    raise exception 'INVALID_TRACKING_INPUT';
  end if;

  if not check_rate_limit(upper(trim(p_order_number)), 'track', 10, interval '10 minutes') then
    raise exception 'RATE_LIMITED';
  end if;

  select * into v_order from orders
   where order_number = upper(trim(p_order_number))
     and normalized_phone = v_phone
     and status <> 'awaiting_receipt';

  if not found then raise exception 'ORDER_NOT_FOUND'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'name', product_name_snapshot,
           'plan', plan_name_snapshot,
           'quantity', quantity)), '[]'::jsonb)
    into v_items from order_items where order_id = v_order.id;

  return jsonb_build_object(
    'order_number', v_order.order_number,
    'status', v_order.status,
    'status_label', case v_order.status
        when 'pending_payment_review' then 'مراجعة الدفع'
        when 'payment_confirmed'      then 'تم تأكيد الدفع'
        when 'activating'             then 'جاري التفعيل'
        when 'needs_info'             then 'نحتاج معلومات إضافية'
        when 'completed'              then 'مكتمل'
        when 'cancelled'              then 'ملغي'
        when 'refunded'               then 'تم الاسترجاع'
        else 'قيد المعالجة' end,
    'items', v_items,
    'created_at', v_order.created_at,
    'updated_at', v_order.updated_at
  );
end $$;

revoke all on function track_order(text,text) from public, anon, authenticated;
grant execute on function track_order(text,text) to anon, authenticated;

-- ── 019_content_translations.sql ──────────────────────────────────────
-- ============================================================
-- Janeiro Store — 019 content translations cache
--
-- Automatic machine translation for owner-authored catalogue text
-- (product names/descriptions, category names, bundle names) when a
-- customer picks French or English. Everything else on the
-- storefront is translated by hand in the frontend's own dictionary;
-- this table exists only for the text the store owner types in the
-- dashboard, which no dictionary can anticipate.
--
-- Keyed by (entity_type, entity_id, lang) rather than a hash of the
-- text: that lets a stale row be detected by comparing source_text to
-- the current value (the owner edited the product) rather than by
-- ever seeing the OLD text again to look it up.
--
-- Written only by the translate-content Edge Function, which holds
-- the DeepL key. No anon/authenticated access is needed or granted:
-- the function runs as the service role and returns translations
-- directly in its response, so the frontend never queries this table.
-- ============================================================

create table if not exists content_translations (
  id              uuid primary key default gen_random_uuid(),
  entity_type     text not null check (entity_type in
                    ('product_name','product_description','category_name',
                     'bundle_name','bundle_description')),
  entity_id       uuid not null,
  lang            text not null check (lang in ('fr','en')),
  source_text     text not null,
  translated_text text not null,
  updated_at      timestamptz not null default now(),
  unique (entity_type, entity_id, lang)
);
create index if not exists idx_translations_lookup
  on content_translations(entity_type, entity_id, lang);

alter table content_translations enable row level security;
-- no policies: service role bypasses RLS entirely; nobody else needs a row here.

-- ── 020_warranty_certificates.sql ──────────────────────────────────────
-- ============================================================
-- Janeiro Store — 020 warranty certificates
--
-- A printable warranty certificate, issued once per order item when
-- an order is marked completed (activation finished). It carries a
-- code that never repeats across customers, and that code alone is
-- what opens it — no login, so the customer can open, print or
-- forward the link themselves, and the admin can do the same from
-- the console.
--
-- Nothing here is a snapshot of its own: the certificate row only
-- keeps what cannot be derived later (its code, and the warranty
-- window computed once at issue time). Everything else — order
-- number, customer name, product/plan names, activation fields — is
-- read live from orders/order_items/order_activation_data through
-- get_certificate(), the same snapshot-at-order-time data the rest
-- of the store already relies on.
-- ============================================================

-- ---------- 1. the certificate itself ----------
create table if not exists warranty_certificates (
  id               uuid primary key default gen_random_uuid(),
  certificate_code text not null unique check (char_length(certificate_code) >= 12),
  order_item_id    uuid not null unique references order_items(id) on delete cascade,
  starts_at        timestamptz not null default now(),
  ends_at          timestamptz,
  created_at       timestamptz not null default now()
);
create index if not exists idx_cert_code on warranty_certificates(certificate_code);

alter table warranty_certificates enable row level security;
drop policy if exists "admin read certificates" on warranty_certificates;
create policy "admin read certificates" on warranty_certificates
  for select using (is_admin());
grant select on warranty_certificates to authenticated;
-- no anon policy: the public path is get_certificate() below, which
-- returns only what a certificate should show, never the raw row.

-- ---------- 2. a code that never repeats ----------
-- gen_random_uuid() rather than pgcrypto's gen_random_bytes(): it is
-- built into Postgres core (no extension needed), which is also why
-- every id column in this schema already uses it successfully.
-- gen_random_bytes() needs pgcrypto, and on a hosted Supabase project
-- that extension lives in the `extensions` schema -- invisible to a
-- SECURITY DEFINER function pinned to `search_path = public`, so it
-- failed there with "function gen_random_bytes(integer) does not
-- exist" even though the same call works in a plain local Postgres
-- where pgcrypto happened to install into public.
create or replace function generate_certificate_code()
returns text language plpgsql volatile as $$
declare candidate text;
begin
  for attempt in 1..20 loop
    candidate := 'JNR-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 14));
    if not exists (select 1 from warranty_certificates where certificate_code = candidate) then
      return candidate;
    end if;
  end loop;
  raise exception 'CERTIFICATE_CODE_GENERATION_FAILED';
end $$;

-- ---------- 3. issue certificates when an order completes ----------
-- Same function, same signature as 010_admin_orders.sql; the only
-- addition is the block after the status update. completed is only
-- ever entered once per order (the transition graph has no edge back
-- into it), so this naturally runs exactly once per order — the
-- "already has one" guard below is defence in depth, not the reason
-- it stays idempotent.
create or replace function admin_update_order_status(
  p_order_id   uuid,
  p_new_status order_status,
  p_note       text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_order orders%rowtype; v_old order_status;
  v_line  record; v_ends timestamptz;
begin
  if not is_admin() then
    raise exception 'NOT_AUTHORIZED';
  end if;
  if p_note is not null and char_length(p_note) > 400 then
    raise exception 'NOTE_TOO_LONG';
  end if;

  -- Lock the row: two staff opening the same order must not both move it.
  select * into v_order from orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;

  v_old := v_order.status;

  -- Re-applying the current status is a no-op, not an error: a double
  -- click on the same button should be harmless.
  if v_old = p_new_status then
    return jsonb_build_object(
      'order_id', v_order.id, 'order_number', v_order.order_number,
      'status', v_old, 'changed', false
    );
  end if;

  if not exists (
    select 1 from order_status_transitions
     where from_status = v_old and to_status = p_new_status
  ) then
    raise exception 'INVALID_STATUS_TRANSITION:% -> %', v_old, p_new_status;
  end if;

  perform set_config('janeiro.status_note', coalesce(p_note, ''), true);

  update orders set status = p_new_status where id = p_order_id
  returning * into v_order;

  if p_new_status = 'completed' then
    for v_line in
      select oi.id as item_id, p.warranty_type, p.warranty_days,
             pl.duration_value, pl.duration_unit
        from order_items oi
        left join products p on p.id = oi.product_id
        left join product_plans pl on pl.id = oi.plan_id
       where oi.order_id = p_order_id
    loop
      -- nothing to certify without a warranty, and never issue a
      -- second certificate for the same line
      continue when v_line.warranty_type is null or v_line.warranty_type = 'none';
      continue when exists (
        select 1 from warranty_certificates where order_item_id = v_line.item_id
      );

      v_ends := case v_line.warranty_type
        when 'days' then now() + make_interval(days => coalesce(v_line.warranty_days, 0))
        when 'subscription_duration' then case v_line.duration_unit
          when 'day'   then now() + make_interval(days   => coalesce(v_line.duration_value, 0))
          when 'week'  then now() + make_interval(weeks  => coalesce(v_line.duration_value, 0))
          when 'month' then now() + make_interval(months => coalesce(v_line.duration_value, 0))
          when 'year'  then now() + make_interval(years  => coalesce(v_line.duration_value, 0))
          else null end
        -- 'activation' and 'custom' have no computable end date; the
        -- certificate shows the product's own warranty label instead.
        else null end;

      insert into warranty_certificates (certificate_code, order_item_id, starts_at, ends_at)
      values (generate_certificate_code(), v_line.item_id, now(), v_ends);
    end loop;
  end if;

  return jsonb_build_object(
    'order_id', v_order.id, 'order_number', v_order.order_number,
    'previous_status', v_old, 'status', v_order.status, 'changed', true
  );
end $$;

revoke all on function admin_update_order_status(uuid,order_status,text) from public, anon;
grant execute on function admin_update_order_status(uuid,order_status,text) to authenticated;

-- ---------- 4. the public, code-only lookup ----------
-- Deliberately asymmetric with track_order: track_order never returns
-- activation data because it is reached with only an order number and
-- a phone number, both guessable in bulk. A certificate code is a
-- 56-bit random token that is itself the credential — knowing it is
-- exactly the "hand the link to this one customer" bar the store
-- needs, the same trust model as any invoice/receipt link.
create or replace function get_certificate(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cert   warranty_certificates%rowtype;
  v_item   order_items%rowtype;
  v_order  orders%rowtype;
  v_fields jsonb;
begin
  if p_code is null or char_length(trim(p_code)) < 8 then
    raise exception 'CERTIFICATE_NOT_FOUND';
  end if;

  if not check_rate_limit(upper(trim(p_code)), 'certificate', 30, interval '10 minutes') then
    raise exception 'RATE_LIMITED';
  end if;

  select * into v_cert from warranty_certificates
   where certificate_code = upper(trim(p_code));
  if not found then raise exception 'CERTIFICATE_NOT_FOUND'; end if;

  select * into v_item from order_items where id = v_cert.order_item_id;
  select * into v_order from orders where id = v_item.order_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'label', field_label, 'value', field_value) order by created_at), '[]'::jsonb)
    into v_fields
    from order_activation_data where order_item_id = v_item.id;

  return jsonb_build_object(
    'certificate_code', v_cert.certificate_code,
    'order_number', v_order.order_number,
    'customer_name', v_order.customer_name,
    'product_name', v_item.product_name_snapshot,
    'plan_name', v_item.plan_name_snapshot,
    'warranty_label', v_item.warranty_label_snapshot,
    'activation_fields', v_fields,
    'starts_at', v_cert.starts_at,
    'ends_at', v_cert.ends_at,
    'issued_at', v_cert.created_at
  );
end $$;

revoke all on function get_certificate(text) from public, anon, authenticated;
grant execute on function get_certificate(text) to anon, authenticated;

-- ---------- 5. surface it on the customer's own tracking page ----------
-- Same function and signature as 018_order_updates.sql, plus a
-- certificate_code/ends_at per item (null when that item has none).
-- Not "activation data" in the sense track_order's own comment
-- guards against -- an opaque code is not the account information the
-- customer typed in, it is a link to their own certificate.
create or replace function track_order(p_order_number text, p_phone text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_order orders%rowtype; v_items jsonb; v_phone text; begin
  v_phone := normalize_dz_phone(p_phone);
  if p_order_number is null or v_phone is null then
    raise exception 'INVALID_TRACKING_INPUT';
  end if;

  if not check_rate_limit(upper(trim(p_order_number)), 'track', 10, interval '10 minutes') then
    raise exception 'RATE_LIMITED';
  end if;

  select * into v_order from orders
   where order_number = upper(trim(p_order_number))
     and normalized_phone = v_phone
     and status <> 'awaiting_receipt';

  if not found then raise exception 'ORDER_NOT_FOUND'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'name', oi.product_name_snapshot,
           'plan', oi.plan_name_snapshot,
           'quantity', oi.quantity,
           'certificate_code', wc.certificate_code,
           'certificate_ends_at', wc.ends_at)), '[]'::jsonb)
    into v_items
    from order_items oi
    left join warranty_certificates wc on wc.order_item_id = oi.id
   where oi.order_id = v_order.id;

  return jsonb_build_object(
    'order_number', v_order.order_number,
    'status', v_order.status,
    'status_label', case v_order.status
        when 'pending_payment_review' then 'مراجعة الدفع'
        when 'payment_confirmed'      then 'تم تأكيد الدفع'
        when 'activating'             then 'جاري التفعيل'
        when 'needs_info'             then 'نحتاج معلومات إضافية'
        when 'completed'              then 'مكتمل'
        when 'cancelled'              then 'ملغي'
        when 'refunded'               then 'تم الاسترجاع'
        else 'قيد المعالجة' end,
    'items', v_items,
    'created_at', v_order.created_at,
    'updated_at', v_order.updated_at
  );
end $$;

revoke all on function track_order(text,text) from public, anon, authenticated;
grant execute on function track_order(text,text) to anon, authenticated;

-- ---------- 6. where the storefront lives ----------
-- Used only to build the certificate link shown in the admin console
-- (get_certificate itself has no notion of a site — the frontend page
-- reads the ?cert= code straight from its own URL). Change this if
-- the store moves to a custom domain.
insert into store_settings (key, value, is_public) values
  ('site_url', 'https://janeiro-theta.vercel.app', true)
on conflict (key) do nothing;

