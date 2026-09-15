-- ============================================================
-- Janeiro Store — اختبارات /sold: البيعات المؤكَّدة (035)
--   psql "$DATABASE_URL" -f tests/confirmed.test.sql
-- كل تأكيد يرفع خطأ عند فشله. لا شيء يُحفظ: معاملة تُلغى.
-- ============================================================

begin;

do $$
declare
  v_owner constant bigint := 950000001;
  v_sell  constant bigint := 950000002;
  v_other constant bigint := 950000003;
  v_pid uuid; v_vid uuid; v_res jsonb; v_i1 uuid; v_i2 uuid;
begin
  -- المالك يرى الجميع؛ فتُفرَّغ القاعدة ليصير العدد عدداً لا تقريباً
  delete from bot_certificates;
  delete from bot_issues;

  perform bot_bootstrap_owner(v_owner, 'c35', 'المالك');
  perform bot_add_admin(v_owner, v_sell,  'بائع');
  perform bot_add_admin(v_owner, v_other, 'بائع آخر');

  perform bot_add_product(v_owner, 'c35p', 'منتج');
  perform bot_add_variant(v_owner, 'c35p', 'm1', 'شهر');
  select v.id, p.id into v_vid, v_pid from bot_variants v
    join bot_products p on p.id = v.product_id
   where p.code = 'c35p' and v.code = 'm1';
  perform bot_add_cards(v_owner, v_vid, array['C35-A','C35-B','C35-C']);
  -- المنصّة والمدّة تُلقَطان على البيعة لحظة إصدارها، فتُضبطان قبلها
  perform bot_set_product_platform(v_owner, v_pid, 'Netflix');
  perform bot_set_variant_duration(v_owner, v_vid, 1, 'month');

  -- ========== لا شيء بعد ==========
  assert bot_confirmed(v_owner) = '[]'::jsonb, 'بلا بيعات: مصفوفة فارغة لا خطأ';

  -- ========== بيعة مؤكَّدة تظهر بكودها ==========
  v_res := bot_request_card(v_sell, v_vid);
  v_i1  := (v_res->>'issue_id')::uuid;
  perform bot_confirm_issue(v_sell, v_i1);

  v_res := bot_confirmed(v_sell);
  assert jsonb_array_length(v_res) = 1, 'بيعة واحدة';
  assert v_res->0->>'card_code' = 'C35-A', 'وبكودها — وهو المقصود من الأمر كله';
  assert (v_res->0->>'mine')::boolean, 'ومنسوبة لصاحبها';
  assert v_res->0->'doc_code' = 'null'::jsonb, 'وبلا وثيقة بعد';
  raise notice 'PASS  المؤكَّدة تظهر بكودها';

  -- ========== المعلَّقة لا تظهر هنا ==========
  perform bot_request_card(v_sell, v_vid);
  assert jsonb_array_length(bot_confirmed(v_sell)) = 1,
         'المعلَّقة تبقى في /pending ولا تتسرّب إلى /sold';

  -- ========== والملغاة كذلك ==========
  v_res := bot_request_card(v_other, v_vid);
  perform bot_cancel_issue(v_other, (v_res->>'issue_id')::uuid);
  assert jsonb_array_length(bot_confirmed(v_owner)) = 1, 'والملغاة لا تظهر';
  raise notice 'PASS  المعلَّقة والملغاة لا تظهران';

  -- ========== النطاق: كلٌّ يرى بيعاته، والمالك الجميع ==========
  assert jsonb_array_length(bot_confirmed(v_other)) = 0,
         'بائع لا يرى بيعة بائعٍ آخر — الكود هو البضاعة';
  assert jsonb_array_length(bot_confirmed(v_owner)) = 1, 'والمالك يرى الجميع';
  assert (bot_confirmed(v_owner)->0->>'mine')::boolean = false,
         'ويُقال له إنها ليست بيعته';
  assert bot_confirmed(v_owner)->0->>'seller' = 'بائع', 'ومن باعها';
  raise notice 'PASS  النطاق: البائع بيعاته والمالك الجميع';

  -- ========== الوثيقة تُذكر إن صدرت، وتسقط إن أُبطلت ==========
  perform bot_engagement_from_issue(v_sell, v_i1, 0);
  v_res := bot_confirmed(v_sell);
  assert v_res->0->>'doc_code' like 'JW-%',
         'وثيقةُ البيعة تُذكر معها: أوّل سؤالٍ بعد «أيّ بطاقة؟» هو «وهل خرجت وثيقة؟»';
  perform bot_engagement_revoke(v_owner, v_res->0->>'doc_code');
  assert bot_confirmed(v_sell)->0->'doc_code' = 'null'::jsonb,
         'والمُبطَلة تسقط: لا تمنع تراجعاً ولا تَعِد زبوناً، فذكرها تشويش';
  raise notice 'PASS  الوثيقة تُذكر سارية وتسقط مُبطَلة';

  -- ========== الترتيب والحدّ ==========
  v_res := bot_request_card(v_sell, v_vid);
  v_i2  := (v_res->>'issue_id')::uuid;
  perform bot_confirm_issue(v_sell, v_i2);
  v_res := bot_confirmed(v_sell);
  assert jsonb_array_length(v_res) = 2, 'اثنتان الآن';
  assert (v_res->0->>'settled_at')::timestamptz >= (v_res->1->>'settled_at')::timestamptz,
         'والأحدث أولاً — من يبحث عن بيعةٍ للتوّ يجدها في الأعلى';
  assert jsonb_array_length(bot_confirmed(v_sell, 1)) = 1, 'والحدّ يُحترم';
  assert jsonb_array_length(bot_confirmed(v_sell, 999)) = 2, 'وحدٌّ خارج المدى يُقصّ لا يُرفض';
  raise notice 'PASS  الأحدث أولاً، والحدّ محكوم';

  -- ========== مجهول لا يصل ==========
  begin
    perform bot_confirmed(950000099);
    assert false, 'a stranger read the card codes';
  exception when others then
    assert sqlerrm like 'NOT_AUTHORIZED%', 'المجهول يُمنع، وجد: ' || sqlerrm;
  end;
  raise notice 'PASS  المجهول لا يقرأ الأكواد';

  raise notice '===== confirmed tests passed =====';
end $$;

rollback;
