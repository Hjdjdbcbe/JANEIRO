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
