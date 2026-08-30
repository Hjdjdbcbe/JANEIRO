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
