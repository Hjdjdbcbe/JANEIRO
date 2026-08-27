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
create or replace view public_products as
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
