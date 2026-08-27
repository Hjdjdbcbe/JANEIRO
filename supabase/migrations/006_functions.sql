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

  insert into orders (
    order_number, customer_name, customer_phone, normalized_phone, customer_wilaya,
    payment_method_id, subtotal, total, currency, status, idempotency_key, client_ip
  ) values (
    v_number, trim(p_name), p_phone, v_phone, nullif(trim(coalesce(p_wilaya,'')), ''),
    p_payment_method, 0, 0, v_currency, 'awaiting_receipt', p_idempotency_key,
    nullif(p_client_ip,'')::inet
  ) returning id into v_order_id;

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

  update orders set
    status = 'pending_payment_review',
    submitted_at = now(),
    payment_reference = coalesce(nullif(trim(p_payment_reference),''), payment_reference)
  where id = p_order_id
  returning * into v_order;

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
-- ------------------------------------------------------------
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

grant execute on function track_order(text,text)          to anon, authenticated;
grant execute on function normalize_dz_phone(text)         to anon, authenticated;
