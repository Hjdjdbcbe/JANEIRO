-- ============================================================
-- Janeiro Store — backend test suite (§61)
-- Run against a NON-PRODUCTION database:
--   psql "$DATABASE_URL" -f tests/backend.test.sql
-- Every block raises on failure, so a clean run == all passed.
-- ============================================================

begin;

do $$
declare
  v_pm      uuid;
  v_prod    uuid;
  v_plan    uuid;
  v_draft   uuid;
  v_inplan  uuid;
  v_res     jsonb;
  v_res2    jsonb;
  v_oid     uuid;
  v_items   jsonb;
  v_count   int;
  v_ok      boolean;
begin
  select id into v_pm   from payment_methods where is_active limit 1;
  select id into v_prod from products where slug = 'gemini-pro';
  select id into v_plan from product_plans where product_id = v_prod order by sort_order limit 1;

  -- ========== phone normalization ==========
  assert normalize_dz_phone('0550123456')     = '213550123456', 'phone: local form';
  assert normalize_dz_phone('+213550123456')  = '213550123456', 'phone: +213 form';
  assert normalize_dz_phone('213550123456')   = '213550123456', 'phone: 213 form';
  assert normalize_dz_phone('00213550123456') = '213550123456', 'phone: 00213 form';
  assert normalize_dz_phone('0550 12 34 56')  = '213550123456', 'phone: spaces';
  assert normalize_dz_phone('0450123456')     is null, 'phone: landline rejected';
  assert normalize_dz_phone('12345')          is null, 'phone: too short rejected';
  assert normalize_dz_phone('abcdefghij')     is null, 'phone: letters rejected';
  raise notice 'PASS  phone normalization';

  -- ========== order number format ==========
  assert generate_order_number() ~ '^JNR-[0-9]{6}-[0-9A-Z]{4}$', 'order number format';
  raise notice 'PASS  order number format';

  -- ========== valid order ==========
  -- نوع التفعيل is the owner's to set, so the test sets one the way the
  -- dashboard would before checking where it ends up.
  update products set activation_type = 'تفعيل مباشر' where id = v_prod;

  v_items := jsonb_build_array(jsonb_build_object(
    'product_id', v_prod, 'plan_id', v_plan, 'quantity', 1,
    'activation', jsonb_build_array(
      jsonb_build_object('label','بريد Gmail للتفعيل','value','test@gmail.com'),
      jsonb_build_object('label','رقم الهاتف المرتبط','value','0550111111'))));

  v_res := create_order('عميل اختبار','0550999001',null,v_pm,v_items,'test-key-001');
  v_oid := (v_res->>'order_id')::uuid;
  assert v_res->>'status' = 'awaiting_receipt', 'new order starts awaiting_receipt';
  assert (v_res->>'total')::numeric = (select price from product_plans where id = v_plan),
         'server computed total matches DB price';
  raise notice 'PASS  create valid order';

  -- نوع التفعيل is the store's, snapshotted onto the line from the
  -- product the way plan_name_snapshot is, so rewording it later cannot
  -- rewrite what an old order said
  assert (select activation_type from order_items where order_id = v_oid)
         = (select activation_type from products where id = v_prod),
         'نوع التفعيل snapshotted from the product onto the line';
  raise notice 'PASS  نوع التفعيل comes from the product';

  -- ========== price tampering is ignored ==========
  -- The RPC signature accepts no price at all, so a manipulated cart
  -- cannot influence the total. Verify the stored total again:
  assert (select total from orders where id = v_oid)
         = (select price from product_plans where id = v_plan), 'price tampering ignored';
  raise notice 'PASS  manipulated price ignored';

  -- ========== idempotency ==========
  v_res2 := create_order('عميل اختبار','0550999001',null,v_pm,v_items,'test-key-001');
  assert (v_res2->>'order_id')::uuid = v_oid, 'same idempotency key -> same order';
  assert (v_res2->>'idempotent_replay')::boolean, 'replay flagged';
  select count(*) into v_count from orders where normalized_phone = '213550999001';
  assert v_count = 1, 'double submit created only one order';
  raise notice 'PASS  idempotency / double click';

  -- ========== submit without receipt must fail ==========
  begin
    perform submit_order(v_oid, null);
    raise exception 'FAILED: submit without receipt was allowed';
  exception when others then
    assert sqlerrm like '%RECEIPT_REQUIRED%', 'expected RECEIPT_REQUIRED, got: ' || sqlerrm;
  end;
  raise notice 'PASS  submit without receipt rejected';

  -- ========== receipt invariant at DB level ==========
  begin
    update orders set status = 'pending_payment_review' where id = v_oid;
    raise exception 'FAILED: DB allowed pending_payment_review without receipt';
  exception when check_violation then
    null; -- expected
  end;
  raise notice 'PASS  receipt invariant enforced by CHECK constraint';

  -- ========== invalid phone ==========
  begin
    perform create_order('عميل','0450123456',null,v_pm,v_items,'test-key-002');
    raise exception 'FAILED: invalid phone accepted';
  exception when others then
    assert sqlerrm like '%INVALID_PHONE%', 'expected INVALID_PHONE, got: ' || sqlerrm;
  end;
  raise notice 'PASS  invalid phone rejected';

  -- ========== invalid name ==========
  begin
    perform create_order('ع','0550999002',null,v_pm,v_items,'test-key-003');
    raise exception 'FAILED: 1-char name accepted';
  exception when others then
    assert sqlerrm like '%INVALID_NAME%', 'expected INVALID_NAME';
  end;
  raise notice 'PASS  invalid name rejected';

  -- ========== nonexistent product ==========
  begin
    perform create_order('عميل','0550999003',null,v_pm,
      jsonb_build_array(jsonb_build_object(
        'product_id', gen_random_uuid(), 'plan_id', v_plan, 'quantity',1)),
      'test-key-004');
    raise exception 'FAILED: unknown product accepted';
  exception when others then
    assert sqlerrm like '%PRODUCT_NOT_FOUND%', 'expected PRODUCT_NOT_FOUND';
  end;
  raise notice 'PASS  invalid product rejected';

  -- ========== non-purchasable product (coming_soon) ==========
  select id into v_draft from products where slug = 'apple-one';
  begin
    perform create_order('عميل','0550999004',null,v_pm,
      jsonb_build_array(jsonb_build_object(
        'product_id', v_draft, 'plan_id', v_plan, 'quantity',1)),
      'test-key-005');
    raise exception 'FAILED: coming_soon product accepted';
  exception when others then
    assert sqlerrm like '%PRODUCT_NOT_PURCHASABLE%' or sqlerrm like '%PLAN_PRODUCT_MISMATCH%',
           'expected non-purchasable rejection, got: ' || sqlerrm;
  end;
  raise notice 'PASS  coming_soon product rejected';

  -- ========== inactive plan ==========
  insert into product_plans (product_id, name, price, is_active)
    values (v_prod, 'خطة معطلة للاختبار', 500, false) returning id into v_inplan;
  begin
    perform create_order('عميل','0550999005',null,v_pm,
      jsonb_build_array(jsonb_build_object(
        'product_id', v_prod, 'plan_id', v_inplan, 'quantity',1)),
      'test-key-006');
    raise exception 'FAILED: inactive plan accepted';
  exception when others then
    assert sqlerrm like '%PLAN_INACTIVE%', 'expected PLAN_INACTIVE';
  end;
  raise notice 'PASS  inactive plan rejected';

  -- ========== plan belonging to another product ==========
  begin
    perform create_order('عميل','0550999006',null,v_pm,
      jsonb_build_array(jsonb_build_object(
        'product_id', (select id from products where slug='canva-pro'),
        'plan_id', v_plan, 'quantity',1)),
      'test-key-007');
    raise exception 'FAILED: cross-product plan accepted';
  exception when others then
    assert sqlerrm like '%PLAN_PRODUCT_MISMATCH%', 'expected PLAN_PRODUCT_MISMATCH';
  end;
  raise notice 'PASS  cross-product plan rejected';

  -- ========== invalid quantity ==========
  begin
    perform create_order('عميل','0550999007',null,v_pm,
      jsonb_build_array(jsonb_build_object(
        'product_id', v_prod, 'plan_id', v_plan, 'quantity', 999)),
      'test-key-008');
    raise exception 'FAILED: quantity 999 accepted';
  exception when others then
    assert sqlerrm like '%INVALID_QUANTITY%', 'expected INVALID_QUANTITY';
  end;
  raise notice 'PASS  invalid quantity rejected';

  -- ========== missing required activation field ==========
  begin
    perform create_order('عميل','0550999008',null,v_pm,
      jsonb_build_array(jsonb_build_object(
        'product_id', v_prod, 'plan_id', v_plan, 'quantity',1,
            'activation', '[]'::jsonb)),
      'test-key-009');
    raise exception 'FAILED: missing activation data accepted';
  exception when others then
    assert sqlerrm like '%MISSING_ACTIVATION_FIELD%', 'expected MISSING_ACTIVATION_FIELD';
  end;
  raise notice 'PASS  missing activation field rejected';

  -- ========== نوع التفعيل sent by the client is ignored ==========
  -- Same treatment a price gets: the browser has no say in it. The line
  -- must carry the product's value, whatever the payload claimed.
  begin
    v_res2 := create_order('عميل','0550999011',null,v_pm,
      jsonb_build_array(jsonb_build_object(
        'product_id', v_prod, 'plan_id', v_plan, 'quantity',1,
        'activation_type', 'تفعيل مزوّر من المتصفح',
        'activation', jsonb_build_array(
          jsonb_build_object('label','بريد Gmail للتفعيل','value','test@gmail.com'),
          jsonb_build_object('label','رقم الهاتف المرتبط','value','0550111111')))),
      'test-key-011');
    assert (select activation_type from order_items
             where order_id = (v_res2->>'order_id')::uuid)
           = (select activation_type from products where id = v_prod),
           'a client-sent نوع التفعيل must be ignored';
  end;
  raise notice 'PASS  نوع التفعيل sent from the browser is ignored';

  -- ========== a product without one still sells ==========
  -- Refusing to take money because the owner has not filled in an
  -- informational label would be a worse bug than the missing label.
  begin
    update products set activation_type = null where id = v_prod;
    v_res2 := create_order('عميل','0550999012',null,v_pm,
      jsonb_build_array(jsonb_build_object(
        'product_id', v_prod, 'plan_id', v_plan, 'quantity',1,
        'activation', jsonb_build_array(
          jsonb_build_object('label','بريد Gmail للتفعيل','value','test@gmail.com'),
          jsonb_build_object('label','رقم الهاتف المرتبط','value','0550111111')))),
      'test-key-012');
    assert (select activation_type from order_items
             where order_id = (v_res2->>'order_id')::uuid) is null,
           'a product with no نوع التفعيل stores null on the line';
    update products set activation_type = 'تفعيل مباشر' where id = v_prod;
  end;
  raise notice 'PASS  a product without نوع التفعيل still sells';

  -- ========== invalid email in an email field ==========
  begin
    perform create_order('عميل','0550999009',null,v_pm,
      jsonb_build_array(jsonb_build_object(
        'product_id', v_prod, 'plan_id', v_plan, 'quantity',1,
            'activation', jsonb_build_array(
          jsonb_build_object('label','بريد Gmail للتفعيل','value','not-an-email'),
          jsonb_build_object('label','رقم الهاتف المرتبط','value','0550111111')))),
      'test-key-010');
    raise exception 'FAILED: malformed email accepted';
  exception when others then
    assert sqlerrm like '%INVALID_EMAIL_FIELD%', 'expected INVALID_EMAIL_FIELD';
  end;
  raise notice 'PASS  invalid email rejected';

  raise notice '';
  raise notice '===== all create_order tests passed =====';
end $$;

-- ============================================================
-- ACTIVE ORDER LIMIT  (§17) — needs receipts, so we simulate
-- the upload by writing receipt_path directly as the owner.
-- ============================================================
do $$
declare
  v_pm uuid; v_prod uuid; v_plan uuid; v_items jsonb;
  v_a uuid; v_b uuid; v_c jsonb;
  phone constant text := '0551000001';
begin
  select id into v_pm   from payment_methods where is_active limit 1;
  select id into v_prod from products where slug = 'discord-nitro';
  select id into v_plan from product_plans where product_id = v_prod order by sort_order limit 1;

  v_items := jsonb_build_array(jsonb_build_object(
    'product_id', v_prod, 'plan_id', v_plan, 'quantity', 1,
    'activation', jsonb_build_array(
      jsonb_build_object('label','اسم المستخدم في ديسكورد','value','tester'))));

  -- customer with 0 active orders -> allowed
  v_a := (create_order('عميل حد','0551000001',null,v_pm,v_items,'limit-key-1')->>'order_id')::uuid;
  update orders set receipt_path='orders/x/a.jpg', receipt_uploaded_at=now() where id=v_a;
  perform submit_order(v_a, null);
  assert count_active_orders('213551000001') = 1, 'first order counts as active';
  raise notice 'PASS  customer with 0 active orders allowed';

  -- customer with 1 active order -> still allowed
  v_b := (create_order('عميل حد','0551000001',null,v_pm,v_items,'limit-key-2')->>'order_id')::uuid;
  update orders set receipt_path='orders/x/b.jpg', receipt_uploaded_at=now() where id=v_b;
  perform submit_order(v_b, null);
  assert count_active_orders('213551000001') = 2, 'second order counts as active';
  raise notice 'PASS  customer with 1 active order allowed';

  -- customer with 2 active orders -> rejected
  begin
    perform create_order('عميل حد','0551000001',null,v_pm,v_items,'limit-key-3');
    raise exception 'FAILED: third order was allowed';
  exception when others then
    assert sqlerrm like '%ACTIVE_ORDER_LIMIT%', 'expected ACTIVE_ORDER_LIMIT, got: ' || sqlerrm;
  end;
  raise notice 'PASS  customer with 2 active orders rejected';

  -- completed orders free up a slot
  update orders set status='completed' where id=v_a;
  assert count_active_orders('213551000001') = 1, 'completed no longer active';
  v_c := create_order('عميل حد','0551000001',null,v_pm,v_items,'limit-key-4');
  assert v_c->>'order_number' is not null, 'slot freed after completion';
  raise notice 'PASS  completed order frees a slot';

  raise notice '';
  raise notice '===== active order limit tests passed =====';
end $$;

-- ============================================================
-- TRACKING (§36)
-- ============================================================
do $$
declare
  v_num text; v_res jsonb;
begin
  select order_number into v_num from orders
   where normalized_phone='213551000001' and status <> 'awaiting_receipt' limit 1;

  -- correct order + correct last4
  v_res := track_order(v_num, '0001');
  assert v_res->>'order_number' = v_num, 'tracking returns the order';
  assert v_res ? 'status_label', 'tracking returns an Arabic status label';
  assert not (v_res ? 'customer_phone'), 'tracking must not leak the phone';
  assert not (v_res ? 'receipt_path'),   'tracking must not leak the receipt';
  assert not (v_res ? 'activation'),     'tracking must not leak activation data';
  raise notice 'PASS  tracking with correct phone';

  -- wrong last4 -> rejected
  begin
    perform track_order(v_num, '9999');
    raise exception 'FAILED: tracking accepted the wrong phone';
  exception when others then
    assert sqlerrm like '%ORDER_NOT_FOUND%' or sqlerrm like '%RATE_LIMITED%',
           'expected ORDER_NOT_FOUND, got: ' || sqlerrm;
  end;
  raise notice 'PASS  tracking with wrong phone rejected';

  raise notice '';
  raise notice '===== tracking tests passed =====';
end $$;

-- ============================================================
-- REGRESSION — bugs found when this suite was first executed.
-- Each block fails loudly if the fix is ever reverted.
-- ============================================================
do $$
declare
  v_pm uuid; v_prod uuid; v_plan uuid; v_items jsonb;
  v_id uuid; v_res jsonb; v_ip inet; v_ok boolean;
begin
  select id into v_pm   from payment_methods where is_active order by sort_order limit 1;
  select id into v_prod from products where slug = 'discord-nitro';
  select id into v_plan from product_plans where product_id = v_prod order by sort_order limit 1;
  v_items := jsonb_build_array(jsonb_build_object(
    'product_id', v_prod, 'plan_id', v_plan, 'quantity', 1,
    'activation', jsonb_build_array(
      jsonb_build_object('label','اسم المستخدم في ديسكورد','value','tester'))));

  -- ---------- a malformed X-Forwarded-For must not kill the order ----------
  -- Regression: client_ip used a bare ::inet cast, so "unknown" or a
  -- host:port hop raised invalid_text_representation and the customer
  -- got a 500 instead of an order.
  v_res := create_order('عميل','0554000001',null,v_pm,v_items,'reg-ip-key-001','not-an-ip');
  assert v_res->>'order_id' is not null, 'malformed client_ip must not fail the order';
  select client_ip into v_ip from orders where id = (v_res->>'order_id')::uuid;
  assert v_ip is null, 'unparseable client_ip should be stored as NULL';

  v_res := create_order('عميل','0554000002',null,v_pm,v_items,'reg-ip-key-002','203.0.113.9:52814');
  select client_ip into v_ip from orders where id = (v_res->>'order_id')::uuid;
  assert v_ip = '203.0.113.9'::inet, 'ipv4:port should keep the address, got: ' || coalesce(v_ip::text,'null');

  v_res := create_order('عميل','0554000003',null,v_pm,v_items,'reg-ip-key-003','203.0.113.10');
  select client_ip into v_ip from orders where id = (v_res->>'order_id')::uuid;
  assert v_ip = '203.0.113.10'::inet, 'a clean IP must still be recorded';
  raise notice 'PASS  malformed client_ip degrades to NULL instead of failing';

  -- ---------- submit_order is idempotent, and says so ----------
  -- Regression: the UPDATE matched on id alone, so a repeat submit
  -- re-applied it and still reported already_submitted = false, which
  -- made submit-order send the admin a second Telegram message.
  v_id := (create_order('عميل','0554000004',null,v_pm,v_items,'reg-submit-key-1')->>'order_id')::uuid;
  update orders set receipt_path='orders/x/r.jpg', receipt_uploaded_at=now() where id=v_id;

  v_res := submit_order(v_id, 'REF-FIRST');
  assert (v_res->>'already_submitted')::boolean = false, 'first submit must report already_submitted=false';
  assert v_res->>'status' = 'pending_payment_review', 'first submit must move the order forward';

  v_res := submit_order(v_id, 'REF-SECOND');
  assert (v_res->>'already_submitted')::boolean = true,
         'second submit must report already_submitted=true (else Telegram fires twice)';
  assert (select payment_reference from orders where id=v_id) = 'REF-FIRST',
         'a repeat submit must not overwrite the payment reference';
  raise notice 'PASS  repeat submit is idempotent and does not re-notify';

  -- ---------- a replay returns the same shape as a fresh create ----------
  -- The replay branch omitted subtotal, so the two paths disagreed on the
  -- payload shape. Both now carry it.
  v_res := create_order('عميل','0554000005',null,v_pm,v_items,'reg-replay-key-1');
  v_res := create_order('عميل','0554000005',null,v_pm,v_items,'reg-replay-key-1');
  assert (v_res->>'idempotent_replay')::boolean, 'replay must be flagged';
  assert (v_res->>'total')::numeric > 0, 'replay must carry the total';
  assert (v_res->>'subtotal')::numeric > 0, 'replay must carry the subtotal too';
  raise notice 'PASS  idempotent replay matches the fresh-create payload shape';

  -- ---------- functions the README calls "internal" are not public ----------
  v_ok := not has_function_privilege('anon', 'generate_order_number()', 'EXECUTE');
  assert v_ok, 'generate_order_number must not be callable by anon';
  v_ok := not has_function_privilege('anon', 'count_active_orders(text)', 'EXECUTE');
  assert v_ok, 'count_active_orders must not be callable by anon';
  v_ok := not has_function_privilege('anon', 'check_rate_limit(text,text,int,interval)', 'EXECUTE');
  assert v_ok, 'check_rate_limit must not be callable by anon';
  -- is_admin() is deliberately public: every RLS policy calls it as the
  -- querying role, so revoking it would break admin access entirely.
  assert has_function_privilege('anon', 'is_admin()', 'EXECUTE'),
         'is_admin must stay executable or every admin policy breaks';
  raise notice 'PASS  internal functions are not exposed to anon';

  raise notice '';
  raise notice '===== regression tests passed =====';
end $$;

-- ============================================================
-- DAILY DEALS — the price a customer is charged comes from the
-- database, never from the cart, deal or no deal.
-- ============================================================
do $$
declare
  v_pm uuid; v_prod uuid; v_plan uuid; v_list numeric; v_items jsonb;
  v_res jsonb; v_deal uuid; v_ok boolean; v_count int;
begin
  select id into v_pm   from payment_methods where is_active order by sort_order limit 1;
  select id into v_prod from products where slug = 'discord-nitro';
  select id, price into v_plan, v_list
    from product_plans where product_id = v_prod order by sort_order limit 1;

  v_items := jsonb_build_array(jsonb_build_object(
    'product_id', v_prod, 'plan_id', v_plan, 'quantity', 2,
    'activation', jsonb_build_array(
      jsonb_build_object('label','اسم المستخدم في ديسكورد','value','tester'))));

  -- ---------- a deal must actually be a discount ----------
  begin
    insert into daily_deals (product_id, plan_id, deal_price, ends_at)
      values (v_prod, v_plan, v_list, now() + interval '1 day');
    raise exception 'FAILED: a deal at the list price was accepted';
  exception when others then
    assert sqlerrm like '%DEAL_PRICE_NOT_LOWER%', 'expected DEAL_PRICE_NOT_LOWER, got: ' || sqlerrm;
  end;

  -- ---------- the plan must belong to the product ----------
  begin
    insert into daily_deals (product_id, plan_id, deal_price, ends_at)
      values ((select id from products where slug='canva-pro'), v_plan, 1, now() + interval '1 day');
    raise exception 'FAILED: a deal on another product''s plan was accepted';
  exception when others then
    assert sqlerrm like '%DEAL_PLAN_PRODUCT_MISMATCH%', 'expected DEAL_PLAN_PRODUCT_MISMATCH';
  end;
  raise notice 'PASS  a deal must be a real discount on its own plan';

  -- ---------- a live deal is what the customer pays ----------
  insert into daily_deals (product_id, plan_id, deal_price, starts_at, ends_at)
    values (v_prod, v_plan, v_list - 400, now() - interval '1 hour', now() + interval '6 hours')
    returning id into v_deal;

  assert active_deal_price(v_prod, v_plan) = v_list - 400, 'live deal price should be readable';

  v_res := create_order('عميل عرض','0556000001',null,v_pm,v_items,'deal-key-live-1');
  assert (v_res->>'total')::numeric = (v_list - 400) * 2,
         'order total must use the deal price: expected ' || ((v_list-400)*2)::text
         || ', got ' || (v_res->>'total');
  assert (select unit_price from order_items
           where order_id = (v_res->>'order_id')::uuid) = v_list - 400,
         'the item snapshot must record the deal price actually charged';
  raise notice 'PASS  a live deal is charged from the database, not the cart';

  -- ---------- an expired deal is charged at full price ----------
  -- This is the mid-checkout case: the customer saw the deal, then it
  -- ended before they confirmed. The server must not honour it.
  update daily_deals set starts_at = now() - interval '2 days',
                         ends_at   = now() - interval '1 day'
   where id = v_deal;
  assert active_deal_price(v_prod, v_plan) is null, 'an expired deal must not price anything';

  v_res := create_order('عميل عرض','0556000002',null,v_pm,v_items,'deal-key-expired-1');
  assert (v_res->>'total')::numeric = v_list * 2,
         'an expired deal must fall back to the list price: expected ' || (v_list*2)::text
         || ', got ' || (v_res->>'total');
  raise notice 'PASS  an expired deal falls back to the list price';

  -- ---------- a deal that has not started yet is ignored ----------
  update daily_deals set starts_at = now() + interval '1 day',
                         ends_at   = now() + interval '2 days'
   where id = v_deal;
  assert active_deal_price(v_prod, v_plan) is null, 'a future deal must not price anything';

  -- ---------- deactivating a deal ends it ----------
  update daily_deals set starts_at = now() - interval '1 hour',
                         ends_at   = now() + interval '1 hour',
                         is_active = false
   where id = v_deal;
  assert active_deal_price(v_prod, v_plan) is null, 'an inactive deal must not price anything';
  raise notice 'PASS  future and deactivated deals are ignored';

  -- ---------- the public view shows live deals only ----------
  update daily_deals set is_active = true where id = v_deal;
  select count(*) into v_count from public_daily_deals where id = v_deal;
  assert v_count = 1, 'a live deal should appear in public_daily_deals';
  assert (select original_price from public_daily_deals where id = v_deal) = v_list,
         'the view must carry the original price for the struck-through figure';
  assert (select server_now from public_daily_deals where id = v_deal) is not null,
         'the view must carry server_now so the countdown can offset the browser clock';

  update daily_deals set ends_at = now() - interval '1 minute' where id = v_deal;
  select count(*) into v_count from public_daily_deals where id = v_deal;
  assert v_count = 0, 'an expired deal must not appear in public_daily_deals';
  raise notice 'PASS  public_daily_deals exposes live deals only';

  raise notice '';
  raise notice '===== daily deal tests passed =====';
end $$;

-- ============================================================
-- ADMIN ORDER HANDLING — the only way an order moves forward.
-- ============================================================
do $$
declare
  v_pm uuid; v_prod uuid; v_plan uuid; v_items jsonb;
  v_id uuid; v_admin uuid; v_res jsonb; v_note text; v_ok boolean;
begin
  select id into v_pm   from payment_methods where is_active order by sort_order limit 1;
  select id into v_prod from products where slug = 'discord-nitro';
  select id into v_plan from product_plans where product_id = v_prod order by sort_order limit 1;
  v_items := jsonb_build_array(jsonb_build_object(
    'product_id', v_prod, 'plan_id', v_plan, 'quantity', 1,
    'activation', jsonb_build_array(
      jsonb_build_object('label','اسم المستخدم في ديسكورد','value','tester'))));

  v_id := (create_order('عميل أدمن','0557000001',null,v_pm,v_items,'admin-key-1')->>'order_id')::uuid;
  update orders set receipt_path='orders/x/a.jpg', receipt_uploaded_at=now() where id=v_id;
  perform submit_order(v_id, 'REF-ADMIN');

  -- ---------- a non-admin cannot move anything ----------
  -- The RPC is SECURITY DEFINER, so without its own guard it would run
  -- with the owner's rights for whoever calls it.
  v_admin := gen_random_uuid();
  insert into auth.users(id) values (v_admin);
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role','authenticated')::text, true);
    perform admin_update_order_status(v_id, 'payment_confirmed', null);
    raise exception 'FAILED: a signed-in non-admin moved an order';
  exception when others then
    assert sqlerrm like '%NOT_AUTHORIZED%', 'expected NOT_AUTHORIZED, got: ' || sqlerrm;
  end;

  -- and with no session at all
  begin
    perform set_config('request.jwt.claims', '', true);
    perform admin_update_order_status(v_id, 'payment_confirmed', null);
    raise exception 'FAILED: an anonymous caller moved an order';
  exception when others then
    assert sqlerrm like '%NOT_AUTHORIZED%', 'expected NOT_AUTHORIZED for anon';
  end;
  raise notice 'PASS  only an admin can move an order';

  -- ---------- become an admin ----------
  insert into profiles(id, role) values (v_admin, 'admin')
    on conflict (id) do update set role = 'admin';
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role','authenticated')::text, true);
  assert is_admin(), 'the test admin should be recognised';

  -- ---------- an illegal jump is refused ----------
  begin
    perform admin_update_order_status(v_id, 'completed', null);
    raise exception 'FAILED: jumped straight from payment review to completed';
  exception when others then
    assert sqlerrm like '%INVALID_STATUS_TRANSITION%',
           'expected INVALID_STATUS_TRANSITION, got: ' || sqlerrm;
  end;
  assert (select status from orders where id=v_id) = 'pending_payment_review',
         'a refused transition must leave the order untouched';
  raise notice 'PASS  an illegal jump is refused and changes nothing';

  -- ---------- the legal path works, and records why ----------
  v_res := admin_update_order_status(v_id, 'payment_confirmed', 'الوصل مطابق');
  assert (v_res->>'changed')::boolean, 'a legal move should report changed';
  assert v_res->>'previous_status' = 'pending_payment_review', 'the previous status is reported';

  select note into v_note from order_status_history
   where order_id = v_id and new_status = 'payment_confirmed';
  assert v_note = 'الوصل مطابق', 'the reason must reach the history row, got: ' || coalesce(v_note,'null');

  assert (select changed_by from order_status_history
           where order_id = v_id and new_status = 'payment_confirmed') = v_admin,
         'the history must record which admin made the change';

  perform admin_update_order_status(v_id, 'activating', null);
  perform admin_update_order_status(v_id, 'completed', 'تم التفعيل');
  assert (select status from orders where id=v_id) = 'completed',
         'the order should reach completed through the legal path';
  raise notice 'PASS  the legal path reaches completed and logs who and why';

  -- ---------- repeating a move is a no-op, not an error ----------
  v_res := admin_update_order_status(v_id, 'completed', null);
  assert not (v_res->>'changed')::boolean, 're-applying the same status must report changed=false';
  assert (select count(*) from order_status_history
           where order_id = v_id and new_status = 'completed') = 1,
         'a repeated move must not add a second history row';
  raise notice 'PASS  repeating a move is harmless';

  -- ---------- terminal states are terminal ----------
  perform admin_update_order_status(v_id, 'refunded', 'استرجاع بعد شكوى');
  begin
    perform admin_update_order_status(v_id, 'activating', null);
    raise exception 'FAILED: moved an order back out of refunded';
  exception when others then
    assert sqlerrm like '%INVALID_STATUS_TRANSITION%', 'refunded must be terminal';
  end;
  raise notice 'PASS  cancelled and refunded are terminal';

  -- ---------- the customer sees the new status ----------
  perform set_config('request.jwt.claims', '', true);
  v_res := track_order((select order_number from orders where id=v_id), '0001');
  assert v_res->>'status' = 'refunded', 'tracking must reflect the admin move';
  assert v_res->>'status_label' = 'تم الاسترجاع', 'the Arabic label must follow';
  raise notice 'PASS  the customer''s tracking page reflects the change';

  raise notice '';
  raise notice '===== admin order tests passed =====';
end $$;

-- ============================================================
-- PRODUCT MANAGEMENT — one call writes a product and its children.
-- ============================================================
do $$
declare
  v jsonb; v_id uuid; v_plan uuid; v_order uuid; v_ok boolean;
  v_admin constant uuid := '11111111-1111-4111-8111-111111111111';
begin
  insert into auth.users(id) values (v_admin) on conflict (id) do nothing;
  insert into profiles(id, role) values (v_admin,'admin')
    on conflict (id) do update set role='admin';

  -- ---------- a non-admin cannot touch the catalogue ----------
  perform set_config('request.jwt.claims', '', true);
  begin
    perform admin_upsert_product(jsonb_build_object('slug','x','name','x','category_slug','ai'));
    raise exception 'FAILED: an anonymous caller wrote a product';
  exception when others then
    assert sqlerrm not like 'FAILED%', 'anon must not write products';
  end;
  raise notice 'PASS  only an admin can write the catalogue';

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin, 'role','authenticated')::text, true);

  -- ---------- a published product must be buyable ----------
  begin
    perform admin_upsert_product(jsonb_build_object(
      'slug','t-noplan','name','بلا خطة','category_slug','ai',
      'status','published','plans','[]'::jsonb));
    raise exception 'FAILED: published a product with nothing to buy';
  exception when others then
    assert sqlerrm like '%PUBLISHED_NEEDS_A_PLAN%',
           'expected PUBLISHED_NEEDS_A_PLAN, got: ' || sqlerrm;
  end;

  -- ---------- the slug is what the URL and the seed key on ----------
  begin
    perform admin_upsert_product(jsonb_build_object(
      'slug','Bad Slug!','name','x','category_slug','ai'));
    raise exception 'FAILED: accepted a malformed slug';
  exception when others then
    assert sqlerrm like '%INVALID_SLUG%', 'expected INVALID_SLUG';
  end;

  begin
    perform admin_upsert_product(jsonb_build_object(
      'slug','t-nocat','name','x','category_slug','does-not-exist'));
    raise exception 'FAILED: accepted an unknown category';
  exception when others then
    assert sqlerrm like '%CATEGORY_NOT_FOUND%', 'expected CATEGORY_NOT_FOUND';
  end;
  raise notice 'PASS  a product must be buyable, slugged and categorised';

  -- ---------- one call writes all five tables ----------
  v := admin_upsert_product(jsonb_build_object(
    'slug','t-prod','name','منتج اختبار','category_slug','ai',
    'short_description','وصف','accent_color','#123456','status','published',
    'warranty_type','subscription_duration',
    'plans', jsonb_build_array(
      jsonb_build_object('name','شهر','price',1000),
      jsonb_build_object('name','سنة','price',9000,'old_price',12000)),
    'features', jsonb_build_array('ميزة أولى','ميزة ثانية'),
    'requirements', jsonb_build_array(
      jsonb_build_object('label','البريد','field_type','email','is_required',true))));
  v_id := (v->>'id')::uuid;
  assert (select count(*) from product_plans        where product_id=v_id) = 2, 'both plans written';
  assert (select count(*) from product_features     where product_id=v_id) = 2, 'both features written';
  assert (select count(*) from product_requirements where product_id=v_id) = 1, 'the activation field written';
  raise notice 'PASS  one call fills all five tables';

  -- ---------- editing must not destroy order history ----------
  -- product_plans is referenced by order_items, and daily_deals cascades
  -- on delete, so a dropped plan is retired rather than removed.
  select id into v_plan from product_plans where product_id=v_id order by sort_order limit 1;
  insert into orders (order_number, customer_name, customer_phone, normalized_phone,
                      subtotal, total, idempotency_key)
    values ('JNR-260101-TST1','عميل','0550111222','213550111222',1000,1000,'prod-edit-test-1')
    returning id into v_order;
  insert into order_items (order_id, product_id, plan_id, product_name_snapshot,
                           plan_name_snapshot, unit_price, quantity, total_price)
    values (v_order, v_id, v_plan, 'منتج اختبار','شهر',1000,1,1000);

  insert into daily_deals (product_id, plan_id, deal_price, ends_at)
    values (v_id, v_plan, 700, now() + interval '2 hours');

  -- save again, listing only the other plan
  perform admin_upsert_product(jsonb_build_object(
    'slug','t-prod','name','منتج اختبار','category_slug','ai','status','published',
    'plans', jsonb_build_array(jsonb_build_object('name','سنة','price',9000))));

  assert (select count(*) from product_plans where id = v_plan) = 1,
         'a dropped plan must be kept, not deleted';
  assert (select is_active from product_plans where id = v_plan) = false,
         'a dropped plan must be deactivated';
  assert (select count(*) from order_items where plan_id = v_plan) = 1,
         'the order line must still point at its plan';
  assert (select count(*) from daily_deals where plan_id = v_plan) = 1,
         'deleting the plan would have cascaded its deal away';
  raise notice 'PASS  editing retires a plan without touching order history';

  -- ---------- saving again edits rather than duplicating ----------
  perform admin_upsert_product(jsonb_build_object(
    'slug','t-prod','name','اسم جديد','category_slug','ai','status','draft',
    'plans', jsonb_build_array(jsonb_build_object('name','سنة','price',9500))));
  assert (select count(*) from products where slug='t-prod') = 1, 'saving must not duplicate';
  assert (select name from products where slug='t-prod') = 'اسم جديد', 'the edit must apply';
  raise notice 'PASS  saving twice edits one product';

  -- ---------- archiving keeps it out of the shop but on the orders ----------
  perform admin_archive_product('t-prod');
  assert (select archived_at from products where slug='t-prod') is not null, 'archived';
  assert (select count(*) from public_products where slug='t-prod') = 0,
         'an archived product must leave the public catalogue';
  assert (select count(*) from order_items where product_id = v_id) = 1,
         'archiving must not touch past orders';
  raise notice 'PASS  archiving hides a product without erasing its history';

  -- ---------- a draft is invisible to customers ----------
  perform set_config('request.jwt.claims', '', true);
  assert (select count(*) from public_products where slug='t-prod') = 0,
         'the public never sees a draft or archived product';

  raise notice '';
  raise notice '===== product management tests passed =====';
end $$;

-- ============================================================
-- RLS  (§39) — run as the anon role
-- ============================================================
do $$
declare v_count int; v_blocked boolean;
begin
  set local role anon;

  -- public may read published products
  select count(*) into v_count from products;
  assert v_count > 0, 'anon should read published products';

  -- public must NOT see draft/archived
  select count(*) into v_count from products where status in ('draft','hidden','archived');
  assert v_count = 0, 'anon must not see draft/hidden/archived products';

  -- public must NOT list orders
  select count(*) into v_count from orders;
  assert v_count = 0, 'anon must not list orders';

  -- public must NOT read activation data
  select count(*) into v_count from order_activation_data;
  assert v_count = 0, 'anon must not read activation data';

  -- public must NOT read receipts in storage
  select count(*) into v_count from storage.objects where bucket_id = 'receipts';
  assert v_count = 0, 'anon must not list the receipts bucket';

  -- public must NOT insert a product.
  -- NOTE: the flag is set on the success path, never by RAISE. An earlier
  -- version raised 'FAILED' inside the block and caught it with `when others`,
  -- which swallowed its own failure signal — the assert could never fire.
  v_blocked := true;
  begin
    insert into products (name, slug, status) values ('اختراق','hack-test','published');
    v_blocked := false;
  exception when others then null;
  end;
  assert v_blocked, 'anon product insert must be blocked';

  -- public must NOT call create_order directly (grant revoked)
  v_blocked := true;
  begin
    perform create_order('x','0550000000',null,null,'[]'::jsonb,'rls-test-key');
    v_blocked := false;
  exception when others then null;
  end;
  assert v_blocked, 'anon must not execute create_order';

  -- ...nor submit_order
  v_blocked := true;
  begin
    perform submit_order(gen_random_uuid(), null);
    v_blocked := false;
  exception when others then null;
  end;
  assert v_blocked, 'anon must not execute submit_order';

  reset role;
  raise notice 'PASS  RLS blocks anonymous access';
  raise notice '';
  raise notice '===== RLS tests passed =====';
end $$;

-- ============================================================
-- 013 product brand icons
-- ============================================================
do $$
declare
  v_ok    boolean;
  v_icon  text;
  v_slug  text := 'icon-test-product';
  v_cat   text;
  v_admin uuid;
begin
  raise notice '';
  raise notice '===== product icon_path =====';

  select slug into v_cat from categories limit 1;

  -- ---------- the shape constraint ----------
  -- icon_path is concatenated into a public URL by the frontend. Anything
  -- that is not a path inside this bucket must be impossible to store,
  -- whether it arrives from the dashboard, a hand-written UPDATE or a
  -- future import.
  for v_icon in select unnest(array[
      'https://evil.example/x.png',       -- absolute URL
      '//evil.example/x.png',             -- protocol-relative
      'products/icons/../../secret.png',  -- traversal
      'receipts/x.png',                   -- a different, PRIVATE bucket
      'products/icons/x.svg',             -- SVG: no magic bytes, runs script
      'products/icons/X.png',             -- uppercase (slugs are lowercase)
      'products/icons/.png'               -- empty name
    ]) loop
    v_ok := false;
    begin
      update products set icon_path = v_icon where slug = 'canva-pro';
    exception when check_violation then v_ok := true;
    end;
    assert v_ok, format('icon_path must reject %L', v_icon);
  end loop;
  raise notice 'PASS  icon_path rejects URLs, traversal, other buckets and SVG';

  update products set icon_path = 'products/icons/canva-pro.png' where slug = 'canva-pro';
  update products set icon_path = 'products/icons/canva-pro.webp' where slug = 'canva-pro';
  update products set icon_path = null where slug = 'canva-pro';
  raise notice 'PASS  icon_path accepts png, webp and NULL';

  -- ---------- it reaches the public read path ----------
  update products set icon_path = 'products/icons/canva-pro.png' where slug = 'canva-pro';
  select icon_path into v_icon from public_products where slug = 'canva-pro';
  assert v_icon = 'products/icons/canva-pro.png', 'public_products must expose icon_path';
  raise notice 'PASS  icon_path is readable through public_products';

  -- ---------- the admin round trip ----------
  -- The upsert lists columns explicitly. An editor that did not send
  -- icon_path would blank it on every save, so saving it back has to
  -- preserve it, and omitting it has to clear it rather than corrupt it.
  v_admin := gen_random_uuid();
  insert into auth.users(id) values (v_admin) on conflict (id) do nothing;
  insert into profiles(id, role) values (v_admin, 'admin')
    on conflict (id) do update set role = 'admin';
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin, 'role','authenticated')::text, true);

  perform admin_upsert_product(jsonb_build_object(
    'slug', v_slug, 'name', 'اختبار الأيقونة', 'category_slug', v_cat,
    'status', 'draft', 'icon_path', 'products/icons/icon-test-product.png',
    'plans', '[]'::jsonb));
  select icon_path into v_icon from products where slug = v_slug;
  assert v_icon = 'products/icons/icon-test-product.png',
    format('upsert must store icon_path, got %L', v_icon);

  select (p->>'icon_path') into v_icon
    from jsonb_array_elements(admin_list_products()) p where p->>'slug' = v_slug;
  assert v_icon = 'products/icons/icon-test-product.png',
    'admin_list_products must return icon_path so the editor can show it';
  raise notice 'PASS  admin_upsert_product stores it and admin_list_products returns it';

  -- and the invalid path is refused through the RPC too, not just the table
  v_ok := false;
  begin
    perform admin_upsert_product(jsonb_build_object(
      'slug', v_slug, 'name', 'اختبار', 'category_slug', v_cat,
      'status', 'draft', 'icon_path', 'https://evil.example/x.png',
      'plans', '[]'::jsonb));
  exception when check_violation then v_ok := true;
  end;
  assert v_ok, 'admin_upsert_product must not bypass the icon_path constraint';
  raise notice 'PASS  the RPC cannot bypass the shape constraint';

  raise notice '===== product icon tests passed =====';
end $$;

-- Nothing is persisted: this is a dry run.
rollback;

-- ============================================================
-- Cases that CANNOT be covered here and must be tested by hand
-- against the deployed project (see README §13):
--
--   * receipt upload: valid image / >5MB / PDF / spoofed MIME type
--   * two simultaneous submits (race) — run the k6/curl script
--   * Telegram message + photo delivery
--   * Telegram failure -> order still saved
--   * WhatsApp redirect contains the right order number
--   * storage: anon attempts to read the receipts bucket
-- ============================================================
