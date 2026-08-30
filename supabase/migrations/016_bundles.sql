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
drop view if exists public_bundles;
create view public_bundles as
select
  b.id,
  b.slug,
  b.name,
  b.short_description,
  b.bundle_price,
  bundle_list_total(b.id)                       as list_total,
  bundle_list_total(b.id) - b.bundle_price      as saving,
  round((1 - b.bundle_price / nullif(bundle_list_total(b.id), 0)) * 100) as saving_pct,
  b.sort_order,
  (select jsonb_agg(jsonb_build_object(
      'product_id', p.id,
      'plan_id',    pl.id,
      'name',       p.name,
      'slug',       p.slug,
      'plan_name',  pl.name,
      'price',      pl.price,
      'icon_path',  p.icon_path,
      'poster_path', p.poster_path,
      'accent_color', p.accent_color)
      order by bi.sort_order, p.name)
     from bundle_items bi
     join products      p  on p.id  = bi.product_id
     join product_plans pl on pl.id = bi.plan_id
    where bi.bundle_id = b.id)                  as items
from bundles b
where b.is_active
  and bundle_is_sellable(b.id);

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
