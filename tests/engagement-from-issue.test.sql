-- ============================================================
-- Janeiro Store — اختبارات الوثيقة من البيعة (029)
--   psql "$DATABASE_URL" -f tests/engagement-from-issue.test.sql
-- كل تأكيد يرفع خطأ عند فشله، فالتشغيل النظيف = نجاح الكل.
-- لا شيء يُحفظ: الملف كله داخل معاملة تُلغى في آخره.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. الوثيقة تُولَد من البيعة بلا إعادة سؤال
-- ------------------------------------------------------------
do $$
declare
  v_owner_tg constant bigint := 960000001;
  v_prod uuid; v_year uuid; v_res jsonb; v_issue uuid; v_doc jsonb;
begin
  perform bot_bootstrap_owner(v_owner_tg, 'o29', 'المالك');
  v_prod := (bot_add_product(v_owner_tg, 'eng29', 'بطاقة')->>'product_id')::uuid;
  v_year := (bot_add_variant(v_owner_tg, 'eng29', 'y', 'سنة')->>'variant_id')::uuid;
  perform bot_set_product_platform(v_owner_tg, v_prod, 'Snapchat Plus');
  perform bot_set_variant_duration(v_owner_tg, v_year, 1, 'year');
  perform bot_add_cards(v_owner_tg, v_year, array['E29-1','E29-2','E29-3','E29-4','E29-5']);

  v_res  := bot_request_card(v_owner_tg, v_year, null, 'dz');
  v_issue := (v_res->>'issue_id')::uuid;

  -- قبل التأكيد لا وثيقة: وعدٌ بما قد يُلغى بعد دقيقة
  begin
    perform bot_engagement_from_issue(v_owner_tg, v_issue, 0);
    assert false, 'صدرت وثيقة لبيعة معلّقة';
  exception when others then
    assert sqlerrm like 'ISSUE_NOT_CONFIRMED%', 'المعلّقة لا وثيقة لها، وردّ: ' || sqlerrm;
  end;

  perform bot_confirm_issue(v_owner_tg, v_issue);
  v_doc := bot_engagement_from_issue(v_owner_tg, v_issue, 0);

  -- كل ما كان يُسأل عنه قُرئ من البيعة
  assert v_doc->>'platform' = 'Snapchat Plus', 'المنصة من البيعة';
  assert (v_doc->>'months')::int = 12, 'والمدة من الصنف';
  assert v_doc->'duration_days' = 'null'::jsonb, 'بالأشهر لا بالأيام';
  assert (v_doc->>'bonus_days')::int = 0, 'وبلا هدية';
  assert v_doc->>'code' like 'JW-%', 'ورمز تحقق JW-';
  assert v_doc->>'ref_code' like 'JS-%', 'ورمز مرجعي JS-';
  assert char_length(v_doc->>'token') >= 32, 'ورابط تعبئة طويل';

  -- والبداية يوم البيع لا يوم النداء
  assert (v_doc->>'starts_at')::timestamptz
         = (select settled_at from bot_issues where id = v_issue),
         'البداية = لحظة إتمام البيعة';
  assert (v_doc->>'ends_at')::timestamptz
         = bot_engagement_expiry((v_doc->>'starts_at')::timestamptz, 12, 0, null),
         'والنهاية محسوبة منها';

  -- ومربوطة بالبيعة
  assert (select issue_id from bot_certificates where code = v_doc->>'code') = v_issue,
         'الوثيقة مربوطة ببيعتها';

  -- ولا وثيقتان لبيعة
  begin
    perform bot_engagement_from_issue(v_owner_tg, v_issue, 0);
    assert false, 'بيعة أخذت وثيقتين';
  exception when others then
    assert sqlerrm like 'CERTIFICATE_EXISTS%', 'وثيقة لكل بيعة، وردّ: ' || sqlerrm;
  end;
  raise notice 'PASS  الوثيقة من البيعة بلا إعادة سؤال';
end $$;

-- ------------------------------------------------------------
-- 2. أيام الهدية — السؤال الوحيد الباقي
-- ------------------------------------------------------------
do $$
declare
  v_owner_tg constant bigint := 960000002;
  v_prod uuid; v_var uuid; v_issue uuid; v_doc jsonb; v_a jsonb; v_b jsonb;
begin
  perform bot_bootstrap_owner(v_owner_tg, 'o29b', 'المالك');
  v_prod := (bot_add_product(v_owner_tg, 'bon29', 'بطاقة')->>'product_id')::uuid;
  v_var  := (bot_add_variant(v_owner_tg, 'bon29', 'm3', '3 أشهر')->>'variant_id')::uuid;
  perform bot_set_product_platform(v_owner_tg, v_prod, 'Netflix');
  perform bot_set_variant_duration(v_owner_tg, v_var, 3, 'month');
  perform bot_add_cards(v_owner_tg, v_var, array['B-1','B-2','B-3','B-4','B-5','B-6']);

  -- بلا هدية
  v_issue := (bot_request_card(v_owner_tg, v_var, null, 'dz')->>'issue_id')::uuid;
  perform bot_confirm_issue(v_owner_tg, v_issue);
  v_a := bot_engagement_from_issue(v_owner_tg, v_issue, 0);

  -- وبسبعة أيام
  v_issue := (bot_request_card(v_owner_tg, v_var, null, 'dz')->>'issue_id')::uuid;
  perform bot_confirm_issue(v_owner_tg, v_issue);
  v_b := bot_engagement_from_issue(v_owner_tg, v_issue, 7);

  assert (v_b->>'bonus_days')::int = 7, 'الهدية مسجَّلة كما أُدخلت';
  assert (v_b->>'ends_at')::timestamptz - (v_b->>'starts_at')::timestamptz
       - ((v_a->>'ends_at')::timestamptz - (v_a->>'starts_at')::timestamptz)
       = interval '7 days', 'سبعة أيام هدية = سبعة أيام أطول، لا أكثر';

  -- ولا تُستنبط من المدة ولا تتجاوز حدّها
  v_issue := (bot_request_card(v_owner_tg, v_var, null, 'dz')->>'issue_id')::uuid;
  perform bot_confirm_issue(v_owner_tg, v_issue);
  begin
    perform bot_engagement_from_issue(v_owner_tg, v_issue, 91);
    assert false, '91 يوم هدية قُبلت';
  exception when others then
    assert sqlerrm like 'INVALID_BONUS%', 'فوق 90 مرفوض، وردّ: ' || sqlerrm;
  end;
  begin
    perform bot_engagement_from_issue(v_owner_tg, v_issue, -1);
    assert false, 'هدية سالبة قُبلت';
  exception when others then
    assert sqlerrm like 'INVALID_BONUS%', 'السالب مرفوض، وردّ: ' || sqlerrm;
  end;
  -- والمحاولات الفاشلة لم تُصدر شيئاً
  assert not exists (select 1 from bot_certificates where issue_id = v_issue),
         'لا وثيقة بعد الرفض';
  raise notice 'PASS  أيام الهدية';
end $$;

-- ------------------------------------------------------------
-- 3. المدة بالأيام لا تضيع — الخطأ الكامن من 026
-- ------------------------------------------------------------
do $$
declare
  v_owner_tg constant bigint := 960000003;
  v_prod uuid; v_var uuid; v_issue uuid; v_doc jsonb;
begin
  perform bot_bootstrap_owner(v_owner_tg, 'o29c', 'المالك');
  v_prod := (bot_add_product(v_owner_tg, 'day29', 'بطاقة')->>'product_id')::uuid;
  v_var  := (bot_add_variant(v_owner_tg, 'day29', 'd45', '45 يوماً')->>'variant_id')::uuid;
  perform bot_set_product_platform(v_owner_tg, v_prod, 'Spotify');
  perform bot_set_variant_duration(v_owner_tg, v_var, 45, 'day');
  perform bot_add_cards(v_owner_tg, v_var, array['D-1','D-2']);

  v_issue := (bot_request_card(v_owner_tg, v_var, null, 'dz')->>'issue_id')::uuid;
  perform bot_confirm_issue(v_owner_tg, v_issue);
  v_doc := bot_engagement_from_issue(v_owner_tg, v_issue, 7);

  assert (v_doc->>'duration_days')::int = 45, 'المدة بالأيام محفوظة';
  assert v_doc->'months' = 'null'::jsonb, 'وليست أشهراً';
  -- 45 يوماً + 7 هدية = 52. وقبل 029 كانت تعطي 7 أيام وحدها.
  assert (v_doc->>'ends_at')::timestamptz - (v_doc->>'starts_at')::timestamptz
         = interval '52 days', '45 + 7 = 52 يوماً، لا 7';
  raise notice 'PASS  المدة بالأيام لا تضيع';
end $$;

-- ------------------------------------------------------------
-- 4. ما ينقص يُقال، ولا يُخمَّن
-- ------------------------------------------------------------
do $$
declare
  v_owner_tg constant bigint := 960000004;
  v_prod uuid; v_var uuid; v_issue uuid; v_st jsonb;
begin
  perform bot_bootstrap_owner(v_owner_tg, 'o29d', 'المالك');
  v_prod := (bot_add_product(v_owner_tg, 'gap29', 'بطاقة')->>'product_id')::uuid;
  v_var  := (bot_add_variant(v_owner_tg, 'gap29', 'v', 'صنف')->>'variant_id')::uuid;
  perform bot_add_cards(v_owner_tg, v_var, array['G-1','G-2','G-3']);

  -- بلا منصة ولا مدة
  v_issue := (bot_request_card(v_owner_tg, v_var, null, 'dz')->>'issue_id')::uuid;
  perform bot_confirm_issue(v_owner_tg, v_issue);

  v_st := bot_issue_engagement(v_owner_tg, v_issue);
  assert (v_st->>'needs_platform')::boolean, 'الحالة تقول: المنصة ناقصة';
  assert (v_st->>'needs_duration')::boolean, 'والمدة ناقصة';
  assert not (v_st->>'has_certificate')::boolean, 'ولا وثيقة بعد';
  assert v_st->'projected_end' = 'null'::jsonb, 'ولا نهاية تُعرض بلا مدة';

  begin
    perform bot_engagement_from_issue(v_owner_tg, v_issue, 0);
    assert false, 'صدرت وثيقة بلا منصة';
  exception when others then
    assert sqlerrm like 'PLATFORM_REQUIRED%', 'المنصة تُطلب، وردّ: ' || sqlerrm;
  end;

  -- تُحدَّد المنصة للمنتج ثم للبيعة
  perform bot_add_product_platform(v_owner_tg, v_prod, 'Gemini Pro');
  perform bot_add_product_platform(v_owner_tg, v_prod, 'Canva Pro');
  perform bot_issue_set_platform(v_owner_tg, v_issue, 'Canva Pro');

  begin
    perform bot_engagement_from_issue(v_owner_tg, v_issue, 0);
    assert false, 'صدرت وثيقة بلا مدة';
  exception when others then
    assert sqlerrm like 'DURATION_MISSING%', 'والمدة تُطلب، وردّ: ' || sqlerrm;
  end;

  perform bot_set_variant_duration(v_owner_tg, v_var, 6, 'month');
  v_st := bot_issue_engagement(v_owner_tg, v_issue);
  assert not (v_st->>'needs_platform')::boolean
     and not (v_st->>'needs_duration')::boolean, 'لم يعد ينقص شيء';
  assert (v_st->>'platform') = 'Canva Pro', 'ومنصة البيعة هي المختارة';
  assert (v_st->>'projected_end')::timestamptz
         = bot_engagement_expiry((v_st->>'projected_start')::timestamptz, 6, 0, null),
         'والمعاينة تطابق ما سيُحسب';

  -- والآن تصدر، والمعاينة كانت صادقة
  declare v_doc jsonb;
  begin
    v_doc := bot_engagement_from_issue(v_owner_tg, v_issue, 0);
    assert (v_doc->>'ends_at')::timestamptz = (v_st->>'projected_end')::timestamptz,
           'ما عُرض هو ما صدر';
    assert v_doc->>'platform' = 'Canva Pro', 'بمنصة البيعة لا بأول منصات المنتج';
  end;

  v_st := bot_issue_engagement(v_owner_tg, v_issue);
  assert (v_st->>'has_certificate')::boolean, 'والحالة صارت تعرفها';
  assert v_st->>'certificate_code' like 'JW-%', 'وترجع رمزها';
  raise notice 'PASS  ما ينقص يُقال ولا يُخمَّن';
end $$;

-- ------------------------------------------------------------
-- 5. البداية لا تزيحها تعبئة متأخّرة
-- ------------------------------------------------------------
do $$
declare
  v_owner_tg constant bigint := 960000005;
  v_prod uuid; v_var uuid; v_issue uuid; v_doc jsonb;
  v_cert bot_certificates; v_before timestamptz; v_end_before timestamptz;
begin
  perform bot_bootstrap_owner(v_owner_tg, 'o29e', 'المالك');
  v_prod := (bot_add_product(v_owner_tg, 'late29', 'بطاقة')->>'product_id')::uuid;
  v_var  := (bot_add_variant(v_owner_tg, 'late29', 'y', 'سنة')->>'variant_id')::uuid;
  perform bot_set_product_platform(v_owner_tg, v_prod, 'Netflix');
  perform bot_set_variant_duration(v_owner_tg, v_var, 1, 'year');
  perform bot_add_cards(v_owner_tg, v_var, array['L-1','L-2']);

  v_issue := (bot_request_card(v_owner_tg, v_var, null, 'dz')->>'issue_id')::uuid;
  perform bot_confirm_issue(v_owner_tg, v_issue);
  v_doc := bot_engagement_from_issue(v_owner_tg, v_issue, 0);

  -- نُرجع البيعة والوثيقة خمسة أيام إلى الوراء: زبون يعبّئ متأخّراً
  update bot_certificates
     set starts_at = starts_at - interval '5 days',
         ends_at   = ends_at   - interval '5 days'
   where code = v_doc->>'code';
  select * into v_cert from bot_certificates where code = v_doc->>'code';
  v_before     := v_cert.starts_at;
  v_end_before := v_cert.ends_at;

  -- قبل التعبئة: معلّقة، ولا تُعرض للعموم
  assert bot_engagement_status(v_cert) = 'pending', 'بلا تعبئة فهي معلّقة';
  begin
    perform bot_engagement_public(v_cert.code);
    assert false, 'عُرضت وثيقة لم يعبّئها صاحبها';
  exception when others then
    assert sqlerrm like 'CERTIFICATE_PENDING%', 'لا تُعرض قبل التعبئة، وردّ: ' || sqlerrm;
  end;
  assert not (bot_engagement_verify(v_cert.code)->>'found')::boolean,
         'ولا يثبتها التحقق';

  perform bot_engagement_claim(v_doc->>'token', 'زبون متأخّر', '0661445566', 'late_user');
  select * into v_cert from bot_certificates where code = v_doc->>'code';

  assert v_cert.starts_at = v_before,   'التعبئة المتأخّرة لا تزيح البداية';
  assert v_cert.ends_at   = v_end_before, 'ولا تمدّ النهاية';
  assert v_cert.filled_at is not null,  'وتُسجَّل لحظة التعبئة';
  assert bot_engagement_status(v_cert) = 'active', 'والوثيقة صارت سارية';

  -- وصارت تُعرض
  assert bot_engagement_public(v_cert.code)->>'holder_name' = 'زبون متأخّر',
         'وتُعرض باسم صاحبها';
  assert (bot_engagement_verify(v_cert.code)->>'found')::boolean, 'ويثبتها التحقق';
  -- ولا رقم الواتساب في القراءة العامة، أبداً
  assert bot_engagement_public(v_cert.code)::text not like '%445566%',
         'ولا رقم في القراءة العامة';

  -- ولا تُعبَّأ مرتين
  begin
    perform bot_engagement_claim(v_doc->>'token', 'زبون آخر', '0661445577');
    assert false, 'عُبّئت مرتين';
  exception when others then
    assert sqlerrm like 'LINK_USED%' or sqlerrm like 'ALREADY_CLAIMED%',
           'الرابط يُستعمل مرة، وردّ: ' || sqlerrm;
  end;
  raise notice 'PASS  البداية لا تزيحها تعبئة متأخّرة';
end $$;

-- ------------------------------------------------------------
-- 6. الصلاحيات: بيعة غيرك ليست لك
-- ------------------------------------------------------------
do $$
declare
  v_owner_tg  constant bigint := 960000006;
  v_a_tg      constant bigint := 960000007;
  v_b_tg      constant bigint := 960000008;
  v_prod uuid; v_var uuid; v_issue uuid; v_doc jsonb;
begin
  perform bot_bootstrap_owner(v_owner_tg, 'o29f', 'المالك');
  perform bot_add_admin(v_owner_tg, v_a_tg, 'بائع أ');
  perform bot_add_admin(v_owner_tg, v_b_tg, 'بائع ب');
  v_prod := (bot_add_product(v_owner_tg, 'acl29', 'بطاقة')->>'product_id')::uuid;
  v_var  := (bot_add_variant(v_owner_tg, 'acl29', 'y', 'سنة')->>'variant_id')::uuid;
  perform bot_set_product_platform(v_owner_tg, v_prod, 'Netflix');
  perform bot_set_variant_duration(v_owner_tg, v_var, 1, 'year');
  perform bot_add_cards(v_owner_tg, v_var, array['A-1','A-2']);

  v_issue := (bot_request_card(v_a_tg, v_var, null, 'dz')->>'issue_id')::uuid;
  perform bot_confirm_issue(v_a_tg, v_issue);

  begin
    perform bot_engagement_from_issue(v_b_tg, v_issue, 0);
    assert false, 'بائع أصدر وثيقة لبيعة غيره';
  exception when others then
    assert sqlerrm like 'NOT_YOUR_ISSUE%', 'بيعة الغير محميّة، وردّ: ' || sqlerrm;
  end;
  begin
    perform bot_issue_engagement(v_b_tg, v_issue);
    assert false, 'بائع قرأ حالة بيعة غيره';
  exception when others then
    assert sqlerrm like 'NOT_YOUR_ISSUE%', 'والقراءة كذلك، وردّ: ' || sqlerrm;
  end;

  -- والمالك يصل لكل شيء
  v_doc := bot_engagement_from_issue(v_owner_tg, v_issue, 0);
  assert v_doc->>'code' like 'JW-%', 'المالك يصدر';
  raise notice 'PASS  بيعة غيرك ليست لك';
end $$;

-- ------------------------------------------------------------
-- 7. الفلو اليدوي: /warranty يبقى للحالات الخاصة
-- ------------------------------------------------------------
do $$
declare
  v_owner_tg constant bigint := 960000009;
  v_doc jsonb; v_cert bot_certificates;
begin
  perform bot_bootstrap_owner(v_owner_tg, 'o29g', 'المالك');
  perform bot_wizard_begin(v_owner_tg);
  perform bot_wizard_set(v_owner_tg, 'platform', 'Spotify');
  perform bot_wizard_set(v_owner_tg, 'months', '6');
  perform bot_wizard_set(v_owner_tg, 'bonus', '14');
  v_doc := bot_engagement_confirm(v_owner_tg);

  select * into v_cert from bot_certificates where code = v_doc->>'code';
  assert v_cert.issue_id is null, 'وثيقة يدوية بلا بيعة';
  assert v_cert.platform = 'Spotify' and v_cert.months = 6, 'بمنصتها ومدتها';
  -- وبدايتها لحظة إصدارها، كوثيقة البيعة
  assert v_cert.starts_at is not null, 'ولها بداية من أول لحظة';
  assert v_cert.ends_at = bot_engagement_expiry(v_cert.starts_at, 6, 14, null),
         'ونهاية محسوبة بهديتها';
  assert bot_engagement_status(v_cert) = 'pending', 'ومعلّقة حتى يعبّئ الزبون';
  raise notice 'PASS  الفلو اليدوي يبقى';
end $$;

-- ------------------------------------------------------------
-- 8. وثيقة 023 تولد كاملة، لا معلّقة
-- ------------------------------------------------------------
do $$
declare
  v_owner_tg constant bigint := 960000010;
  v_prod uuid; v_var uuid; v_issue uuid; v_res jsonb; v_cert bot_certificates;
begin
  perform bot_bootstrap_owner(v_owner_tg, 'o29h', 'المالك');
  v_prod := (bot_add_product(v_owner_tg, 'old29', 'بطاقة')->>'product_id')::uuid;
  v_var  := (bot_add_variant(v_owner_tg, 'old29', 'y', 'سنة')->>'variant_id')::uuid;
  perform bot_set_variant_duration(v_owner_tg, v_var, 1, 'year');
  perform bot_add_cards(v_owner_tg, v_var, array['O-1']);
  v_issue := (bot_request_card(v_owner_tg, v_var, null, 'dz')->>'issue_id')::uuid;
  perform bot_confirm_issue(v_owner_tg, v_issue);

  -- البائع كتب بيانات الزبون بنفسه: الوثيقة مكتملة منذ ولادتها
  v_res := bot_issue_certificate(v_owner_tg, v_issue, '[]'::jsonb);
  select * into v_cert from bot_certificates where code = v_res->>'code';
  assert v_cert.filled_at is not null, 'وثيقة 023 مكتملة بلا تعبئة زبون';
  assert bot_engagement_status(v_cert) <> 'pending', 'فلا تُعدّ معلّقة';
  raise notice 'PASS  وثيقة 023 تولد كاملة';
end $$;

rollback;
