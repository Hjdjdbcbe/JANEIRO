-- ============================================================
-- Janeiro Store — 037: البريد وطريقة الدفع في استمارة الضمان
--   psql "$DATABASE_URL" -f tests/claim-email-payment.test.sql
-- الملف كله داخل معاملة تُلغى في آخره.
-- ============================================================
begin;

do $$
declare
  v_owner constant bigint := 937000001;
  v_prod uuid; v_var uuid; v_iss uuid; v jsonb; v_tok text; v_code text; i int;
  bad text[][] := array[
    array['x@y',             'baridimob', 'INVALID_EMAIL'],
    array['not-an-email',    'ccp',       'INVALID_EMAIL'],
    array['',                'paypal',    'INVALID_PAYMENT'],
    array['a@b.co',          'cash',      'INVALID_PAYMENT']];
begin
  perform bot_bootstrap_owner(v_owner, 'o37', 'مالك 37');
  update bot_admins set is_active = true where telegram_id = v_owner;
  v_prod := (bot_add_product(v_owner, 'gem37', 'Gemini 37')->>'product_id')::uuid;
  v_var  := (bot_add_variant(v_owner, 'gem37', 'm6', '6 أشهر')->>'variant_id')::uuid;
  perform bot_set_variant_duration(v_owner, v_var, 6, 'month');
  perform bot_add_cards(v_owner, v_var, array['G37-1','G37-2','G37-3','G37-4','G37-5','G37-6'], null);
  if not exists (select 1 from bot_platforms where name = 'Gemini') then perform bot_add_platform(v_owner, 'Gemini'); end if;
  perform bot_add_product_platform(v_owner, v_prod, 'Gemini');

  -- الإدخال الخاطئ يُرفض بسببه، والرابط يبقى صالحاً للمحاولة الصحيحة
  for i in 1..array_length(bad, 1) loop
    v_iss := (bot_request_card(v_owner, v_var, 'زبون 37-' || i, null, null)->>'issue_id')::uuid;
    perform bot_issue_set_platform(v_owner, v_iss, 'Gemini');
    perform bot_confirm_issue(v_owner, v_iss);
    v := bot_engagement_from_issue(v_owner, v_iss, 0, 72);
    begin
      perform bot_engagement_claim(v->>'token', 'زبون الاختبار', '', 'client.37', null,
                                   nullif(bad[i][1], ''), nullif(bad[i][2], ''));
      assert false, 'accepted bad input: ' || bad[i][1] || ' / ' || bad[i][2];
    exception when others then
      assert sqlerrm like bad[i][3] || '%', bad[i][3] || ' expected, got ' || sqlerrm;
    end;
    assert (select used_at from bot_fill_tokens where token = v->>'token') is null, 'الرابط لا يُستهلك بمحاولة فاشلة';
  end loop;

  -- الصحيح: يُحفظ البريد بحروف صغيرة وطريقة الدفع
  v_iss := (bot_request_card(v_owner, v_var, 'زبون 37 صحيح', null, null)->>'issue_id')::uuid;
  perform bot_issue_set_platform(v_owner, v_iss, 'Gemini');
  perform bot_confirm_issue(v_owner, v_iss);
  v := bot_engagement_from_issue(v_owner, v_iss, 0, 72);
  v := bot_engagement_claim(v->>'token', 'أمين بلقاسم', '0661234567', 'amine.dz', null, '  Amine.Dz@Gmail.com ', 'BaridiMob');
  v_code := v->>'code';
  assert (select email from bot_certificates where code = v_code) = 'amine.dz@gmail.com', 'البريد محفوظ';
  assert (select payment_method from bot_certificates where code = v_code) = 'baridimob', 'طريقة الدفع محفوظة';

  -- الوثيقة العامة تحملهما
  v := bot_engagement_public(v_code);
  assert v->>'email' = 'amine.dz@gmail.com' and v->>'payment_method' = 'baridimob', 'public: ' || v::text;

  -- والبريد اختياري
  v_iss := (bot_request_card(v_owner, v_var, 'زبون 37 بلا بريد', null, null)->>'issue_id')::uuid;
  perform bot_issue_set_platform(v_owner, v_iss, 'Gemini');
  perform bot_confirm_issue(v_owner, v_iss);
  v := bot_engagement_from_issue(v_owner, v_iss, 0, 72);
  v := bot_engagement_claim(v->>'token', 'ليلى ب.', '', 'leila.b', null, null, 'flexy');
  assert (select email is null and payment_method = 'flexy' from bot_certificates where code = v->>'code'), 'بلا بريد';

  -- القائمة في اللوحة: تُرجعهما ويُبحث بالبريد
  v := bot_engagement_admin_list(v_owner, 'amine.dz@gmail', null, null, 50, 0, true);
  assert (v->>'total')::int = 1 and v->'rows'->0->>'payment_method' = 'baridimob', 'admin list: ' || v::text;

  -- النداء القديم (بلا المعاملين) ما زال يُفهم
  begin
    perform bot_engagement_claim('nope', 'x', '', 'y');
  exception when others then
    assert sqlerrm like 'LINK_NOT_FOUND%', 'old call shape still resolves: ' || sqlerrm;
  end;
end $$;

\echo 'PASS claim-email-payment: all checks passed'
rollback;
