-- ============================================================
-- Janeiro Store — 013 product brand icons
--
-- The hero orbit shows a ring of product logos. Until now the only
-- sources for those were cdn.simpleicons.org -- a third party in the
-- critical path of the first paint, on the mobile connections this
-- store is for -- and a single-letter monogram fallback. A ring of
-- letters is not the feature; the logos are.
--
-- Mirrors categories.icon_path (migration 008) exactly: the column
-- holds a PATH inside the public product-media bucket, never a URL, so
-- moving buckets or domains never touches the data.
--
-- Empty is the normal state. A product without an icon falls back to
-- simpleicons and then to the monogram, so this is additive and breaks
-- nothing.
--
-- ASSET SPEC — what to upload:
--   size   : 256x256 px, square
--   format : PNG or WebP, transparent background
--   why    : the icon renders at 56px in the orbit and 24px in the cart
--            thumbnail. 256px covers 56px at up to 4.5x DPR, which is
--            more headroom than categories' 128px because the orbit
--            tile is twice the size of a category chip.
--   bucket : product-media  (public read, admin write -- migration 004)
--   path   : products/icons/<slug>.png   e.g. products/icons/canva-pro.png
--
--   Keep the mark inside a ~224px safe area: the orbit tile is rounded
--   and clips the corners. The tile behind it is a solid surface in
--   both themes, so a mark that is pure white will vanish in the light
--   theme -- upload the coloured or dark version, not the knockout.
--
-- WHY NOT SVG
--   Every image in this project is validated by magic bytes rather than
--   by Content-Type, on purpose. SVG is XML: it has no signature to
--   check, and an SVG served from a public bucket as image/svg+xml runs
--   any script it carries when its object URL is opened directly. That
--   trades the whole point of the magic-byte rule for sharper edges.
--   Raster only.
-- ============================================================

alter table products add column if not exists icon_path text;

comment on column products.icon_path is
  'Path inside the public product-media bucket, e.g. products/icons/canva-pro.png. '
  '256x256 transparent PNG or WebP. NULL falls back to the brand icon CDN, '
  'then to the designed monogram.';

-- The path is built by the dashboard, but a hand-written row or a future
-- import should not be able to smuggle a URL, a traversal or a bucket
-- name into a column the frontend concatenates into a public URL.
alter table products drop constraint if exists products_icon_path_shape;
alter table products add constraint products_icon_path_shape check (
  icon_path is null
  or icon_path ~ '^products/icons/[a-z0-9]+(-[a-z0-9]+)*\.(png|webp)$'
);

-- ---------- expose it to the public read view ----------
-- Same reason as 002: drop first so neither file cares which ran last.
drop view if exists public_products;
create view public_products as
select
  p.id, p.name, p.slug, p.short_description, p.description,
  p.poster_path, p.thumbnail_path, p.accent_color,
  p.activation_type, p.activation_label,
  p.delivery_min, p.delivery_max, p.delivery_unit, p.delivery_label,
  p.warranty_type, p.warranty_days, p.warranty_label, p.warranty_description,
  p.warranty_covers, p.warranty_exclusions,
  p.badge_type, p.badge_label, p.status, p.sort_order,
  c.slug as category_slug, c.name as category_name, c.accent_color as category_accent,
  -- appended rather than slotted next to poster_path: CREATE OR REPLACE VIEW
  -- can only add columns at the end, and dropping the view to reorder them
  -- would drop its grants with it.
  p.icon_path
from products p
left join categories c on c.id = p.category_id
where p.status in ('published','temporarily_unavailable','coming_soon')
  and p.archived_at is null;

grant select on public_products to anon, authenticated;

-- ---------- carry it through the admin RPCs ----------
-- Both are replaced wholesale rather than patched: 012 defines them with
-- an explicit column list, and a product saved through an editor that did
-- not know about icon_path would silently blank it on every save.

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
    poster_path, thumbnail_path, icon_path,
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
