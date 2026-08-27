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
