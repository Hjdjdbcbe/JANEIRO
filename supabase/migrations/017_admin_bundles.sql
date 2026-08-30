-- ============================================================
-- Janeiro Store — 017 إدارة الباقات من اللوحة
--
-- Three RPCs, admin-only, shaped like the product ones in 012/013.
--
-- The upsert deactivates the bundle before it touches the items and
-- reactivates it after. The shape triggers from 016 are immediate and
-- fire per row, so replacing a live bundle's items would trip
-- BUNDLE_NEEDS_TWO_PRODUCTS on the first insert -- a bundle is briefly
-- one product long in the middle of its own edit. Deferring the
-- triggers would have hidden the error until COMMIT, where a test
-- cannot catch it and a caller cannot say which statement was wrong;
-- stepping through inactive keeps the check immediate and honest, and
-- an inactive bundle is allowed to be any shape at all.
-- ============================================================

create or replace function admin_list_bundles()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not is_admin() then raise exception 'NOT_AUTHORIZED'; end if;

  select coalesce(jsonb_agg(row order by row->>'sort_order', row->>'name'), '[]'::jsonb)
    into v
  from (
    select jsonb_build_object(
      'id', b.id, 'slug', b.slug, 'name', b.name,
      'short_description', b.short_description,
      'bundle_price', b.bundle_price,
      'is_active', b.is_active,
      'sort_order', b.sort_order,
      'list_total', coalesce((
         select sum(pl.price) from bundle_items bi
           join product_plans pl on pl.id = bi.plan_id
          where bi.bundle_id = b.id), 0),
      -- why a bundle is not on the storefront, so the owner is not left
      -- guessing: it is off, too small, or one of its products is gone
      'sellable', coalesce((
         select count(*) >= 2 and count(*) filter (
                  where p.status = 'published' and p.archived_at is null and pl.is_active
                ) = count(*)
           from bundle_items bi
           join products p       on p.id  = bi.product_id
           join product_plans pl on pl.id = bi.plan_id
          where bi.bundle_id = b.id), false),
      'items', coalesce((
         select jsonb_agg(jsonb_build_object(
                  'product_id', p.id, 'plan_id', pl.id,
                  'product_name', p.name, 'product_slug', p.slug,
                  'plan_name', pl.name, 'price', pl.price,
                  'published', p.status = 'published' and p.archived_at is null and pl.is_active)
                order by bi.sort_order, p.name)
           from bundle_items bi
           join products p       on p.id  = bi.product_id
           join product_plans pl on pl.id = bi.plan_id
          where bi.bundle_id = b.id), '[]'::jsonb)
    ) as row
    from bundles b
  ) s;
  return v;
end $$;

-- ------------------------------------------------------------
-- Create or edit one bundle, items and all. Keyed by slug, like
-- admin_upsert_product, so a saved bundle keeps its id and the orders
-- that point at it stay pointing at it.
-- ------------------------------------------------------------
create or replace function admin_upsert_bundle(p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_slug   text;
  v_id     uuid;
  v_active boolean;
  v_item   jsonb;
  i        int := 0;
begin
  if not is_admin() then raise exception 'NOT_AUTHORIZED'; end if;

  v_slug := lower(trim(coalesce(p_payload->>'slug','')));
  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then raise exception 'INVALID_SLUG'; end if;
  if char_length(trim(coalesce(p_payload->>'name',''))) < 2 then raise exception 'INVALID_NAME'; end if;
  if nullif(p_payload->>'bundle_price','') is null then raise exception 'INVALID_BUNDLE_PRICE'; end if;

  v_active := coalesce((p_payload->>'is_active')::boolean, false);

  -- written inactive first: the row and its items have to be settled
  -- before the shape rules can fairly judge them
  insert into bundles (slug, name, short_description, bundle_price, is_active, sort_order)
  values (
    v_slug,
    trim(p_payload->>'name'),
    nullif(trim(coalesce(p_payload->>'short_description','')), ''),
    (p_payload->>'bundle_price')::numeric,
    false,
    coalesce(nullif(p_payload->>'sort_order','')::int, 0))
  on conflict (slug) do update set
    name = excluded.name,
    short_description = excluded.short_description,
    bundle_price = excluded.bundle_price,
    is_active = false,
    sort_order = excluded.sort_order
  returning id into v_id;

  delete from bundle_items where bundle_id = v_id;

  for v_item in select * from jsonb_array_elements(coalesce(p_payload->'items','[]'::jsonb)) loop
    i := i + 1;
    insert into bundle_items (bundle_id, product_id, plan_id, sort_order)
    values (v_id, (v_item->>'product_id')::uuid, (v_item->>'plan_id')::uuid, i);
  end loop;

  -- and only now judged: two products at least, and a real saving
  if v_active then
    update bundles set is_active = true where id = v_id;
  end if;

  return jsonb_build_object('id', v_id, 'slug', v_slug, 'is_active', v_active);
end $$;

-- ------------------------------------------------------------
-- Delete. Orders keep their lines: order_items.bundle_id is ON DELETE
-- SET NULL and bundle_name_snapshot is a snapshot, so a deleted bundle
-- leaves the history readable instead of erasing what was sold.
-- ------------------------------------------------------------
create or replace function admin_delete_bundle(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_slug text;
begin
  if not is_admin() then raise exception 'NOT_AUTHORIZED'; end if;
  select slug into v_slug from bundles where id = p_id;
  if not found then raise exception 'BUNDLE_NOT_FOUND'; end if;
  delete from bundles where id = p_id;
  return jsonb_build_object('deleted', v_slug);
end $$;

revoke all on function admin_list_bundles()        from public, anon;
revoke all on function admin_upsert_bundle(jsonb)  from public, anon;
revoke all on function admin_delete_bundle(uuid)   from public, anon;
grant execute on function admin_list_bundles()       to authenticated;
grant execute on function admin_upsert_bundle(jsonb) to authenticated;
grant execute on function admin_delete_bundle(uuid)  to authenticated;
