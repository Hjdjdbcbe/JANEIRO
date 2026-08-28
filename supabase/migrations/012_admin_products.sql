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
