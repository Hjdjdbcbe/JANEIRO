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
