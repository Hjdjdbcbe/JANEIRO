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
  -- 043: احتياط القناة، الغلق، المصروف، المسودات
  o2 := act_new_order('month', 'admin');
  assert (act_claim_code('whatsapp', '213600', o2->>'code'))->>'result' = 'ok', 'bound on whatsapp';
  assert (act_claim_code('whatsapp', '213601', o2->>'code'))->>'result' = 'invalid', 'another number on the same channel refused';
  assert (act_claim_code('telegram', '77', o2->>'code'))->>'result' = 'moved', 'same code from another channel continues';
  assert (select platform from activation_orders where code = o2->>'code') = 'telegram', 'order follows the new channel';
  assert act_open_order_for('whatsapp', '213600') is null, 'the old chat no longer owns the order';
  raise notice 'PASS  a code follows the customer to another channel, never to another number';

  assert act_close_order(o2->>'code', 'test')->>'status' = 'CLOSED', '/stop closes';
  assert act_close_order(o2->>'code', 'test') is null, 'closing twice does nothing';
  assert (act_claim_code('telegram', '77', o2->>'code'))->>'result' = 'invalid', 'a closed code is dead';
  raise notice 'PASS  closed orders stay closed';

  o2 := act_new_order('year', 'admin');
  perform act_claim_code('whatsapp', '213602', o2->>'code');
  set local session_replication_role = replica;
  update activation_orders set updated_at = now() - interval '49 hours' where code = o2->>'code';
  set local session_replication_role = origin;
  delete from store_settings where key = 'activation_last_sweep';
  assert jsonb_array_length(act_sweep_stale()) >= 1, 'stale order closed';
  assert (select status from activation_orders where code = o2->>'code') = 'CLOSED', 'it is CLOSED';
  assert act_sweep_stale() = '[]'::jsonb, 'the sweep runs at most every 10 minutes';
  raise notice 'PASS  unfinished orders close after 48h';

  assert (act_new_order('month')->>'store_whatsapp') is not distinct from
         nullif((select value from store_settings where key = 'whatsapp_number'), ''), '/new carries the store number';

  delete from ai_spend where day = current_date;
  perform act_ai_spend_add(0.4); perform act_ai_spend_add(0.35);
  assert act_ai_spend_today() = 0.75, 'spend adds up per day';
  assert act_ai_budget_alert() and not act_ai_budget_alert(), 'budget alert fires once a day';
  raise notice 'PASS  AI spend and budget alert';

  i := act_draft_add('9001', 'voice', 'TG1', 'audio/ogg');
  assert act_draft_get(i, '9002') is null, 'another admin cannot see the draft';
  assert act_draft_set_slot(i, '9001', 'voice_link')->>'slot' = 'voice_link', 'slot chosen';
  assert act_draft_take(i, '9001') is not null and act_draft_take(i, '9001') is null, 'a draft is saved once';
  raise notice 'PASS  voice drafts';

  perform act_mark_sent('whatsapp', array['wamid.X']);
  assert act_is_sent('whatsapp', 'wamid.X') and not act_is_sent('whatsapp', 'wamid.Y'), 'bot messages are recognised in echoes';
  raise notice 'PASS  own messages are told apart from the owner''s';

  raise notice '===== activation bot SQL tests passed =====';
end $$;

rollback;
