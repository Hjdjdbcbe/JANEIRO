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
