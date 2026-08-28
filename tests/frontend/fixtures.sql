-- ============================================================
-- Fixtures for the browser tests.
--
-- Everything here is store configuration a real owner would enter,
-- not invented catalogue data: a WhatsApp number, payment account
-- details, two category icon paths and two live deals.
--
--   psql -d janeiro_test -f tests/frontend/fixtures.sql
-- ============================================================

update store_settings set value = '213555123456' where key = 'whatsapp_number';

update payment_methods
   set account_holder = 'محمد ب.',
       account_number = '0012345678 12',
       instructions   = 'حوّل المبلغ ثم ارفع صورة الوصل.'
 where type = 'ccp';
update payment_methods
   set account_holder = 'محمد ب.', account_number = '007999888777666'
 where type = 'baridimob';
update payment_methods set account_number = '0555112233' where type = 'flexy';

-- One category with an icon that resolves, one pointing at an asset
-- that does not exist, so the onerror fallback is exercised.
update categories set icon_path = 'categories/ai.png'      where slug = 'ai';
update categories set icon_path = 'categories/missing.png' where slug = 'design';

-- Two live deals: one ending inside a day, one beyond it, so the
-- countdown covers both the HH:MM:SS and the "N أيام" formats.
delete from daily_deals;
insert into daily_deals (product_id, plan_id, deal_price, starts_at, ends_at, sort_order)
select p.id, pl.id, round(pl.price * 0.70, 2), now() - interval '1 hour', now() + interval '8 hours', 1
  from products p join product_plans pl on pl.product_id = p.id
 where p.slug = 'spotify-premium' and pl.sort_order = 1;

insert into daily_deals (product_id, plan_id, deal_price, starts_at, ends_at, sort_order)
select p.id, pl.id, round(pl.price * 0.80, 2), now() - interval '2 hours', now() + interval '30 hours', 2
  from products p join product_plans pl on pl.product_id = p.id
 where p.slug = 'notion-plus' and pl.sort_order = 1;

delete from orders;
delete from rate_limits;

-- ============================================================
-- Two accounts for the admin-console tests: one admin, and one
-- ordinary signed-in user who must be refused everything.
-- ============================================================
insert into auth.users (id, email, password) values
  ('11111111-1111-4111-8111-111111111111', 'admin@janeiro.test',  'admin-pass-123'),
  ('22222222-2222-4222-8222-222222222222', 'nobody@janeiro.test', 'nobody-pass-123')
on conflict (id) do update set email = excluded.email, password = excluded.password;

insert into profiles (id, role, full_name)
  values ('11111111-1111-4111-8111-111111111111', 'admin', 'مالك المتجر')
on conflict (id) do update set role = 'admin';

-- the second account deliberately gets NO profiles row, so is_admin() is false
delete from profiles where id = '22222222-2222-4222-8222-222222222222';

-- ============================================================
-- A few orders spread across the lifecycle, created through the real
-- functions rather than inserted, so every constraint and trigger runs
-- exactly as it would for a customer.
-- ============================================================
do $$
declare
  v_pm uuid; v_prod uuid; v_plan uuid; v_items jsonb; v_id uuid;
  v_admin constant uuid := '11111111-1111-4111-8111-111111111111';
  phones text[] := array['0561000001','0561000002','0561000003','0561000004'];
  names  text[] := array['أمين بلقاسم','سارة ح.','ياسين م.','نور الدين ب.'];
  i int;
begin
  select id into v_pm   from payment_methods where is_active order by sort_order limit 1;
  select id into v_prod from products where slug = 'gemini-pro';
  select id into v_plan from product_plans where product_id = v_prod order by sort_order limit 1;

  for i in 1..4 loop
    v_items := jsonb_build_array(jsonb_build_object(
      'product_id', v_prod, 'plan_id', v_plan, 'quantity', 1,
      'activation', jsonb_build_array(
        jsonb_build_object('label','بريد Gmail للتفعيل','value','customer'||i||'@gmail.com'),
        jsonb_build_object('label','رقم الهاتف المرتبط','value', phones[i]))));

    v_id := (create_order(names[i], phones[i], 'الجزائر', v_pm, v_items,
                          'seed-order-'||i||'-'||md5(random()::text))->>'order_id')::uuid;
    update orders set receipt_path = 'orders/seed/'||i||'.jpg', receipt_uploaded_at = now()
     where id = v_id;
    perform submit_order(v_id, '48219'||i||'0');

    -- walk the later ones further down the lifecycle, as an admin would
    if i >= 2 then
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin, 'role','authenticated')::text, true);
      perform admin_update_order_status(v_id, 'payment_confirmed', 'الوصل مطابق للمبلغ');
      if i >= 3 then perform admin_update_order_status(v_id, 'activating', null); end if;
      if i >= 4 then perform admin_update_order_status(v_id, 'completed', 'أُرسلت بيانات الدخول'); end if;
      perform set_config('request.jwt.claims', '', true);
    end if;
  end loop;
end $$;
