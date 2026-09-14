-- ============================================================
-- Janeiro Store — اختبارات شروط التغطية (031)
--   psql "$DATABASE_URL" -f tests/terms.test.sql
-- كل تأكيد يرفع خطأ عند فشله، فالتشغيل النظيف = نجاح الكل.
-- لا شيء يُحفظ: الملف كله داخل معاملة تُلغى في آخره.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. السقوط: الخاصة ← العامة ← فارغ (أي: المدمج في الكود)
-- ------------------------------------------------------------
do $$
declare v_owner constant bigint := 980000001;
begin
  perform bot_bootstrap_owner(v_owner, 'o31', 'المالك');

  -- بلا شيء مكتوب: فارغ، والصفحة تستعمل المدمج
  assert bot_terms_for('Netflix', 'ar') is null, 'بلا شروط = فارغ لا مصفوفة فارغة';
  assert bot_terms_snapshot('Netflix') = '{}'::jsonb, 'واللقطة فارغة';

  -- شروط عامة
  perform bot_set_terms(v_owner, null, 'ar', array['عامة ١', 'عامة ٢']);
  assert bot_terms_for('Netflix', 'ar') = array['عامة ١','عامة ٢'],
         'خدمة بلا شروطها ترث العامة';
  assert bot_terms_for(null, 'ar') = array['عامة ١','عامة ٢'], 'والعامة نفسها';
  assert bot_terms_for('Netflix', 'fr') is null, 'ولغة بلا شروط تبقى فارغة';

  -- ثم شروط خاصة بخدمة: تحجب العامة عنها وحدها
  perform bot_set_terms(v_owner, 'Netflix', 'ar', array['نتفليكس ١','نتفليكس ٢','نتفليكس ٣']);
  assert bot_terms_for('Netflix', 'ar') = array['نتفليكس ١','نتفليكس ٢','نتفليكس ٣'],
         'الخاصة تحجب العامة';
  assert bot_terms_for('Spotify', 'ar') = array['عامة ١','عامة ٢'],
         'وخدمة أخرى تبقى على العامة';

  -- والاستبدال كامل لا إضافة
  perform bot_set_terms(v_owner, 'Netflix', 'ar', array['واحدة فقط']);
  assert bot_terms_for('Netflix', 'ar') = array['واحدة فقط'], 'الكتابة تستبدل لا تضيف';

  -- وقائمة فارغة تمحو، فتعود إلى العامة
  perform bot_set_terms(v_owner, 'Netflix', 'ar', array[]::text[]);
  assert bot_terms_for('Netflix', 'ar') = array['عامة ١','عامة ٢'],
         'المحو يُرجعها إلى العامة';
  raise notice 'PASS  السقوط: الخاصة ← العامة ← المدمج';
end $$;

-- ------------------------------------------------------------
-- 2. الحدود والصلاحية
-- ------------------------------------------------------------
do $$
declare
  v_owner constant bigint := 980000002;
  v_sell  constant bigint := 980000003;
begin
  perform bot_bootstrap_owner(v_owner, 'o31b', 'المالك');
  perform bot_add_admin(v_owner, v_sell, 'بائع');

  begin
    perform bot_set_terms(v_sell, null, 'ar', array['محاولة']);
    assert false, 'بائع بدّل الشروط';
  exception when others then
    assert sqlerrm like 'NOT_OWNER%', 'الشروط للمالك، وردّ: ' || sqlerrm;
  end;

  begin
    perform bot_set_terms(v_owner, null, 'de', array['x']);
    assert false, 'لغة غير مدعومة قُبلت';
  exception when others then
    assert sqlerrm like 'INVALID_LANG%', 'ثلاث لغات لا أكثر، وردّ: ' || sqlerrm;
  end;

  begin
    perform bot_set_terms(v_owner, 'خدمة مخترعة', 'ar', array['x']);
    assert false, 'خدمة غير موجودة قُبلت';
  exception when others then
    assert sqlerrm like 'PLATFORM_NOT_FOUND%', 'الخدمة تُتحقّق، وردّ: ' || sqlerrm;
  end;

  begin
    perform bot_set_terms(v_owner, null, 'ar', array[repeat('ط', 401)]);
    assert false, 'سطر 401 حرفاً قُبل';
  exception when others then
    assert sqlerrm like 'LINE_TOO_LONG%', 'الطول محدود، وردّ: ' || sqlerrm;
  end;

  begin
    perform bot_set_terms(v_owner, null, 'ar',
      array(select 'نقطة رقم ' || g from generate_series(1,13) g));
    assert false, '13 نقطة قُبلت';
  exception when others then
    assert sqlerrm like 'TOO_MANY_LINES%', 'العدد محدود، وردّ: ' || sqlerrm;
  end;

  -- السطور الفارغة تُتخطّى بهدوء، فلصق نصّ فيه فراغات لا يُفسد
  perform bot_set_terms(v_owner, null, 'ar', array['أولى', '', '   ', 'ثانية']);
  assert bot_terms_for(null, 'ar') = array['أولى','ثانية'], 'الفراغ يُتخطّى';
  raise notice 'PASS  الحدود والصلاحية';
end $$;

-- ------------------------------------------------------------
-- 3. اللقطة: ما وُعد به يبقى
-- ------------------------------------------------------------
do $$
declare
  v_owner constant bigint := 980000004;
  v_prod uuid; v_var uuid; v_issue uuid; v_doc jsonb;
  v_old text; v_new text;
begin
  perform bot_bootstrap_owner(v_owner, 'o31c', 'المالك');
  v_prod := (bot_add_product(v_owner, 'trm31', 'بطاقة')->>'product_id')::uuid;
  v_var  := (bot_add_variant(v_owner, 'trm31', 'y', 'سنة')->>'variant_id')::uuid;
  perform bot_set_product_platform(v_owner, v_prod, 'Netflix');
  perform bot_set_variant_duration(v_owner, v_var, 1, 'year');
  perform bot_add_cards(v_owner, v_var, array['T31-1','T31-2']);

  perform bot_set_terms(v_owner, 'Netflix', 'ar', array['الشرط الأوّل','الشرط الثاني']);

  v_issue := (bot_request_card(v_owner, v_var, null, 'dz')->>'issue_id')::uuid;
  perform bot_confirm_issue(v_owner, v_issue);
  v_doc := bot_engagement_from_issue(v_owner, v_issue, 0);
  perform bot_engagement_claim(v_doc->>'token', 'زبون الشروط', '0661445566', 'terms_one');

  v_old := bot_engagement_public(v_doc->>'code')->'terms'->'ar'->>0;
  assert v_old = 'الشرط الأوّل', 'الوثيقة تحمل شروط يومها، وجد: ' || coalesce(v_old,'—');

  -- المالك يبدّل الشروط بعد الإصدار
  perform bot_set_terms(v_owner, 'Netflix', 'ar', array['شرط جديد تماماً']);

  v_new := bot_engagement_public(v_doc->>'code')->'terms'->'ar'->>0;
  assert v_new = 'الشرط الأوّل',
         'ووثيقة الزبون لا تتغيّر بأثر رجعي، وجد: ' || coalesce(v_new,'—');

  -- بينما البيعة التالية تأخذ الجديد
  v_issue := (bot_request_card(v_owner, v_var, null, 'dz')->>'issue_id')::uuid;
  perform bot_confirm_issue(v_owner, v_issue);
  v_doc := bot_engagement_from_issue(v_owner, v_issue, 0);
  perform bot_engagement_claim(v_doc->>'token', 'زبون ثانٍ', '0661445577', 'terms_two');
  assert bot_engagement_public(v_doc->>'code')->'terms'->'ar'->>0 = 'شرط جديد تماماً',
         'والوثيقة الجديدة تأخذ الجديد';
  raise notice 'PASS  اللقطة: ما وُعد به يبقى';
end $$;

-- ------------------------------------------------------------
-- 4. وثيقة صدرت قبل 031
-- ------------------------------------------------------------
do $$
declare
  v_owner constant bigint := 980000005;
  v_admin uuid; v_code text := 'JW-OLD0000001'; v_out jsonb;
begin
  perform bot_bootstrap_owner(v_owner, 'o31d', 'المالك');
  select id into v_admin from bot_admins where telegram_id = v_owner;
  perform bot_set_terms(v_owner, null, 'ar', array['العامة الحيّة']);

  -- terms فارغ، كما هي كل وثيقة أُصدرت قبل هذه الهجرة
  insert into bot_certificates
    (code, ref_code, platform, months, bonus_days, starts_at, ends_at,
     holder_name, whatsapp, filled_at, issued_by)
  values (v_code, 'JS-OLD00001', 'Spotify', 12, 0, now(),
          bot_engagement_expiry(now(), 12, 0, null),
          'زبون قديم', '213661000000', now(), v_admin);

  v_out := bot_engagement_public(v_code);
  assert v_out->'terms'->'ar'->>0 = 'العامة الحيّة',
         'الوثيقة القديمة تقرأ الحيّ بدل أن تخرج بلا شروط';

  -- وبلا شيء حيّ كذلك: فارغ، والصفحة تستعمل المدمج في الكود
  perform bot_set_terms(v_owner, null, 'ar', array[]::text[]);
  assert bot_engagement_public(v_code)->'terms' = '{}'::jsonb,
         'وبلا حيّ تخرج فارغة، والصفحة تملأها من الكود';
  raise notice 'PASS  وثيقة صدرت قبل 031';
end $$;

-- ------------------------------------------------------------
-- 5. العرض للمالك
-- ------------------------------------------------------------
do $$
declare
  v_owner constant bigint := 980000006;
  v_sell  constant bigint := 980000007;
  v_res jsonb;
begin
  perform bot_bootstrap_owner(v_owner, 'o31e', 'المالك');
  perform bot_add_admin(v_owner, v_sell, 'بائع');
  perform bot_set_terms(v_owner, null, 'ar', array['عامة']);
  perform bot_set_terms(v_owner, 'Netflix', 'ar', array['خاصة بنتفليكس']);

  v_res := bot_terms_list(v_owner, 'Netflix');
  assert v_res->'own'->'ar'->>0 = 'خاصة بنتفليكس', 'يرى ما كتبه للخدمة';
  assert v_res->'effective'->'ar'->>0 = 'خاصة بنتفليكس', 'وما سيُطبَّق';
  assert v_res->'overridden' @> '["Netflix"]'::jsonb, 'والخدمات المُفرَدة';

  v_res := bot_terms_list(v_owner, 'Spotify');
  assert v_res->'own' = '{}'::jsonb, 'وخدمة بلا شروطها: لا شيء خاص بها';
  assert v_res->'effective'->'ar'->>0 = 'عامة', 'وتُطبَّق عليها العامة';

  begin
    perform bot_terms_list(v_sell, null);
    assert false, 'بائع قرأ إدارة الشروط';
  exception when others then
    assert sqlerrm like 'NOT_OWNER%', 'العرض للمالك، وردّ: ' || sqlerrm;
  end;
  raise notice 'PASS  العرض للمالك';
end $$;

rollback;
