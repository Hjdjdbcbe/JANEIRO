-- ============================================================
-- Janeiro Store — 042 بوت التفعيل: القاعدة
-- الملف كله داخل معاملة تُلغى في آخره.
-- ============================================================
begin;

do $$
declare o jsonb; o2 jsonb; g jsonb; g2 jsonb; v_ok boolean; v_upd text := 'sql-' || gen_random_uuid(); i int;
begin
  -- ستوك: ₹80 (ما يكفي حتى طلب)، ₹100، ₹250
  insert into bot_products(code, name) values ('acttest', 'Act test') on conflict (code) do nothing;
  insert into bot_variants(product_id, code, name, amount_inr)
    select id, x.c, x.c, x.a from bot_products, (values ('a80', 80), ('a100', 100), ('a250', 250)) x(c, a)
     where code = 'acttest';
  update bot_cards set status = 'disabled' where status = 'available';
  insert into bot_cards(variant_id, code)
    select v.id, 'ACT-' || v.code || '-' || n from bot_variants v, generate_series(1, 2) n
     where v.product_id = (select id from bot_products where code = 'acttest');

  -- /new + الربط بأول chat_id
  o := act_new_order('month', 'admin');
  assert o->>'code' ~ '^JN-[0-9]{4}$', 'order code shape';
  assert (act_claim_code('telegram', '1', lower(replace(o->>'code', '-', ' '))))->>'result' = 'ok', 'code accepted in any case/spacing';
  assert (act_claim_code('telegram', '1', o->>'code'))->>'result' = 'resumed', 'same customer resumes';
  assert (act_claim_code('telegram', '2', o->>'code'))->>'result' = 'invalid', 'another customer is refused';
  raise notice 'PASS  order codes bind to the first chat';

  -- 5 غالطين -> يتحبس ساعة
  for i in 1..4 loop perform act_claim_code('telegram', '2', 'JN-0000'); end loop;
  assert (act_claim_code('telegram', '2', o->>'code'))->>'result' = 'blocked', 'blocked after 5 wrong codes';
  raise notice 'PASS  5 wrong codes block the chat';

  -- كود مات بعد 48 ساعة
  o2 := act_new_order('year', 'admin');
  update activation_orders set expires_at = now() - interval '1 minute' where code = o2->>'code';
  assert (act_claim_code('telegram', '3', o2->>'code'))->>'result' = 'invalid', 'expired code refused';
  raise notice 'PASS  unused codes expire after 48h';

  -- أصغر كود يغطي، وواحد برك لكل طلب
  g := act_assign_gift((o->>'id')::uuid);
  assert (g->>'amount_inr')::int = 100, 'month gets ₹100, not ₹80 nor ₹250';
  g2 := act_assign_gift((o->>'id')::uuid);
  assert g2->>'code' = g->>'code' and (g2->>'reused')::boolean, 'second call returns the same code';
  assert (select count(*) from bot_cards where note like '%' || (o->>'code') || '%') = 1, 'one card per order';
  assert (select status from bot_cards where code = g->>'code') = 'sold', 'card marked sold in the stock bot';
  raise notice 'PASS  smallest covering code, one per order';

  o2 := act_new_order('year', 'admin');
  assert (act_assign_gift((o2->>'id')::uuid)->>'amount_inr')::int = 250, 'year gets ₹250';
  o2 := act_new_order('year', 'admin');
  assert (act_assign_gift((o2->>'id')::uuid)->>'amount_inr')::int = 250, 'year gets the second ₹250';
  o2 := act_new_order('year', 'admin');
  assert act_assign_gift((o2->>'id')::uuid)->>'error' = 'NO_STOCK', 'no code covers ₹199 → NO_STOCK (₹80/₹100 never used)';
  raise notice 'PASS  empty stock is reported, never a too-small code';

  -- قرار المراجعة يتاخذ مرة وحدة
  perform act_update_order((o->>'id')::uuid, '{"ctx_merge": {"review_pending": {"decision": {"action": "accept_snap"}}}}');
  assert act_take_review((o->>'id')::uuid) is not null, 'first review claim wins';
  assert act_take_review((o->>'id')::uuid) is null, 'second review claim gets nothing';
  raise notice 'PASS  review decisions are taken once';

  -- حد الميساجات
  for i in 1..6 loop perform act_touch_chat('telegram', '9', true); end loop;
  assert not (act_touch_chat('telegram', '9', true)->>'allowed')::boolean, '7th media in a minute refused';
  raise notice 'PASS  per-minute media limit';

  -- update مكرر
  assert act_seen_update('telegram', v_upd), 'first delivery';
  assert not act_seen_update('telegram', v_upd), 'duplicate delivery';
  raise notice 'PASS  duplicate updates are detected';

  -- ممنوع على المتصفح
  set local role anon;
  v_ok := false;
  begin perform act_new_order('month'); exception when insufficient_privilege then v_ok := true; end;
  assert v_ok, 'anon cannot create orders';
  v_ok := false;
  begin perform count(*) from activation_orders; exception when insufficient_privilege then v_ok := true; end;
  assert v_ok, 'anon cannot read orders';
  reset role;
  set local role authenticated;
  v_ok := false;
  begin perform act_assign_gift((o->>'id')::uuid); exception when insufficient_privilege then v_ok := true; end;
  assert v_ok, 'authenticated cannot take credit codes';
  reset role;
  raise notice 'PASS  only service_role reaches the activation bot';
  raise notice '===== activation bot SQL tests passed =====';
end $$;

rollback;
