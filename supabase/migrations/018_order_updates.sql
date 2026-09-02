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
