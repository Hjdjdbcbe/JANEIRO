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
