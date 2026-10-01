-- Telegram-bot data for the dashboard browser suite (admin.test.js).
--   psql -d janeiro_test -f tests/frontend/bot-fixtures.sql
-- Idempotent: a second run leaves everything as the first one did.
-- Everything goes through admin_bot() as the seeded console admin, the
-- same path the dashboard takes.

do $$
declare
  v_admin uuid := (select id from auth.users where email = 'admin@janeiro.test');
  v_owner constant bigint := 900000001;
  v_sell  constant bigint := 900000002;
  v jsonb; v_prod uuid; v_m1 uuid; v_m3 uuid; v_iss uuid; v_mkt text; i int;
begin
  if v_admin is null then raise exception 'apply fixtures.sql first (no admin@janeiro.test)'; end if;
  if exists (select 1 from bot_products where code = 'netflix') then return; end if;

  perform bot_bootstrap_owner(v_owner, 'janeiro_owner', 'مالك جانيرو');
  update bot_admins set is_active = true where telegram_id = v_owner;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  perform admin_bot('add_admin', jsonb_build_object('telegram_id', v_sell, 'name', 'ياسين'));

  v := admin_bot('add_product', '{"code":"netflix","name":"Netflix Premium"}');
  v_prod := (v->>'product_id')::uuid;
  v_m1 := (admin_bot('add_variant', '{"product_code":"netflix","code":"m1","name":"شهر"}')->>'variant_id')::uuid;
  v_m3 := (admin_bot('add_variant', '{"product_code":"netflix","code":"m3","name":"3 أشهر"}')->>'variant_id')::uuid;
  perform admin_bot('set_duration', jsonb_build_object('variant_id', v_m1, 'value', 1, 'unit', 'month'));
  perform admin_bot('set_duration', jsonb_build_object('variant_id', v_m3, 'value', 3, 'unit', 'month'));
  perform admin_bot('add_cards', jsonb_build_object('variant_id', v_m1,
    'codes', (select jsonb_agg('NFX1-' || lpad(g::text, 4, '0')) from generate_series(1, 8) g)));
  perform admin_bot('add_cards', jsonb_build_object('variant_id', v_m3,
    'codes', jsonb_build_array('NFX3-0001', 'NFX3-0002')));

  select code into v_mkt from bot_markets where is_active order by sort_order limit 1;
  perform admin_bot('set_price', jsonb_build_object('variant_id', v_m1, 'market', v_mkt, 'price', 1200));
  perform admin_bot('set_price', jsonb_build_object('variant_id', v_m3, 'market', v_mkt, 'price', 3300));

  if not exists (select 1 from bot_platforms where name = 'Netflix') then
    perform admin_bot('add_platform', '{"name":"Netflix"}');
  end if;
  perform admin_bot('add_product_platform', jsonb_build_object('product_id', v_prod, 'platform', 'Netflix'));

  -- two settled sales with a warranty each, and one left pending
  for i in 1..2 loop
    v_iss := (bot_request_card(v_sell, v_m1, 'زبون ' || i, null, null)->>'issue_id')::uuid;
    perform admin_bot('set_issue_platform', jsonb_build_object('issue_id', v_iss, 'platform', 'Netflix'));
    perform admin_bot('confirm_issue', jsonb_build_object('issue_id', v_iss));
    perform admin_bot('from_issue', jsonb_build_object('issue_id', v_iss));
  end loop;
  perform bot_request_card(v_sell, v_m3, 'زبون معلّق', null, null);
end $$;
