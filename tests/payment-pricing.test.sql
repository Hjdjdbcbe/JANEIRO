-- ============================================================
-- Janeiro Store — 039: السعر حسب طريقة الدفع
--   psql "$DATABASE_URL" -f tests/payment-pricing.test.sql
-- الملف كله داخل معاملة تُلغى في آخره.
-- ============================================================
begin;

do $$
declare
  v_flexy uuid; v_bmob uuid;
  v_p1 uuid; v_p2 uuid; v_pl1 uuid; v_pl2 uuid; v_b uuid;
  v jsonb; v_ok boolean;
  v_admin constant uuid := '39393939-3939-4939-8939-393939393939';
  one jsonb;
begin
  -- ---------- the rounding ----------
  assert pay_price(2300, 0)  = 2300, '0% leaves the price alone';
  assert pay_price(2300, 20) = 2760, '2300 +20% = 2760';
  assert pay_price(1150, 15) = 1330, '1150 +15% = 1322.5, rounded up to 1330';
  assert pay_price(1000, 20) = 1200, 'an exact ten stays put';
  raise notice 'PASS  pay_price adds the percentage and rounds up to 10 دج';

  -- ---------- the owner sets Flexy to +20% ----------
  insert into auth.users(id) values (v_admin) on conflict (id) do nothing;
  insert into profiles(id, role) values (v_admin, 'admin') on conflict (id) do update set role = 'admin';
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  insert into payment_methods (type, label, is_active) values ('flexy', 'Flexy', true)
    on conflict (type) do update set is_active = true returning id into v_flexy;
  insert into payment_methods (type, label, is_active) values ('baridimob', 'BaridiMob', true)
    on conflict (type) do update set is_active = true returning id into v_bmob;
  update payment_methods set surcharge_pct = 0 where id = v_bmob;

  perform admin_upsert_payment_method(jsonb_build_object('id', v_flexy, 'label', 'Flexy', 'surcharge_pct', 20));
  assert (select surcharge_pct from payment_methods where id = v_flexy) = 20, 'the dashboard saves the percentage';
  perform admin_upsert_payment_method(jsonb_build_object('id', v_flexy, 'label', 'Flexy'));
  assert (select surcharge_pct from payment_methods where id = v_flexy) = 20, 'a save without the field keeps it';
  v_ok := false;
  begin
    perform admin_upsert_payment_method(jsonb_build_object('id', v_flexy, 'label', 'Flexy', 'surcharge_pct', 150));
  exception when others then v_ok := sqlerrm like '%INVALID_SURCHARGE%';
  end;
  assert v_ok, 'more than 100% is refused';
  raise notice 'PASS  the dashboard sets a payment method''s percentage';

  -- ---------- two products: one plain, one with a Flexy offer ----------
  v := admin_upsert_product(jsonb_build_object(
    'slug', 't-pay-a', 'name', 'منتج أ', 'category_slug', 'ai', 'status', 'published',
    'plans', jsonb_build_array(jsonb_build_object('name', 'شهر', 'price', 2300))));
  v_p1 := (v->>'id')::uuid;
  v := admin_upsert_product(jsonb_build_object(
    'slug', 't-pay-b', 'name', 'منتج ب', 'category_slug', 'ai', 'status', 'published',
    'plans', jsonb_build_array(jsonb_build_object('name', 'شهر', 'price', 1000, 'flexy_price', 1100))));
  v_p2 := (v->>'id')::uuid;
  select id into v_pl1 from product_plans where product_id = v_p1;
  select id into v_pl2 from product_plans where product_id = v_p2;
  assert (select flexy_price from product_plans where id = v_pl2) = 1100, 'the editor saves the Flexy price';
  select p->'plans'->0 into one from jsonb_array_elements(admin_list_products()) p where p->>'slug' = 't-pay-b';
  assert (one->>'flexy_price')::numeric = 1100, 'and reads it back';
  raise notice 'PASS  the product editor saves and reads a plan''s Flexy price';

  -- ---------- what each method charges ----------
  v := create_order('زبون', '0550390001', null, v_bmob,
         jsonb_build_array(jsonb_build_object('product_id', v_p1, 'plan_id', v_pl1, 'quantity', 1)), 'pay-039-1');
  assert (v->>'total')::numeric = 2300, 'BaridiMob pays the list price: ' || (v->>'total');

  v := create_order('زبون', '0550390002', null, v_flexy,
         jsonb_build_array(jsonb_build_object('product_id', v_p1, 'plan_id', v_pl1, 'quantity', 2)), 'pay-039-2');
  assert (v->>'total')::numeric = 5520, 'Flexy pays +20% on each unit: ' || (v->>'total');
  assert (select unit_price from order_items where order_id = (v->>'order_id')::uuid) = 2760,
         'and the order line records the Flexy unit price';

  v := create_order('زبون', '0550390003', null, v_flexy,
         jsonb_build_array(jsonb_build_object('product_id', v_p2, 'plan_id', v_pl2, 'quantity', 1)), 'pay-039-3');
  assert (v->>'total')::numeric = 1100, 'a plan''s Flexy offer beats the percentage: ' || (v->>'total');

  v := create_order('زبون', '0550390004', null, v_bmob,
         jsonb_build_array(jsonb_build_object('product_id', v_p2, 'plan_id', v_pl2, 'quantity', 1)), 'pay-039-4');
  assert (v->>'total')::numeric = 1000, 'the Flexy offer does not touch BaridiMob: ' || (v->>'total');
  raise notice 'PASS  the server charges by payment method';

  -- ---------- a bundle pays the percentage on its bundle price ----------
  insert into bundles (slug, name, bundle_price, is_active) values ('t-pay-bundle', 'باقة', 3000, false)
    returning id into v_b;
  insert into bundle_items (bundle_id, product_id, plan_id, sort_order) values (v_b, v_p1, v_pl1, 1), (v_b, v_p2, v_pl2, 2);
  update bundles set is_active = true where id = v_b;

  v := create_order('زبون', '0550390005', null, v_flexy, jsonb_build_array(
         jsonb_build_object('product_id', v_p1, 'plan_id', v_pl1, 'quantity', 1, 'bundle_id', v_b),
         jsonb_build_object('product_id', v_p2, 'plan_id', v_pl2, 'quantity', 1, 'bundle_id', v_b)), 'pay-039-5');
  assert (v->>'total')::numeric = 3600, 'a bundle by Flexy = bundle price +20%: ' || (v->>'total');

  v := create_order('زبون', '0550390006', null, v_bmob, jsonb_build_array(
         jsonb_build_object('product_id', v_p1, 'plan_id', v_pl1, 'quantity', 1, 'bundle_id', v_b),
         jsonb_build_object('product_id', v_p2, 'plan_id', v_pl2, 'quantity', 1, 'bundle_id', v_b)), 'pay-039-6');
  assert (v->>'total')::numeric = 3000, 'the same bundle by BaridiMob: ' || (v->>'total');
  raise notice 'PASS  a bundle is priced by payment method too';

  -- ---------- the storefront can read both fields ----------
  set local role anon;
  assert (select surcharge_pct from payment_methods where id = v_flexy) = 20, 'anon reads the percentage';
  assert (select flexy_price from product_plans where id = v_pl2) = 1100, 'anon reads the Flexy price';
  reset role;
  raise notice 'PASS  the storefront can read the percentage and the Flexy price';

  raise notice '===== payment pricing tests passed =====';
end $$;

rollback;
