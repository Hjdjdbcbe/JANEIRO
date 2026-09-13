-- ============================================================
-- Janeiro Store — اختبارات معطيات الطلب (026)
--   psql "$DATABASE_URL" -f tests/order-data.test.sql
-- كل تأكيد يرفع خطأ عند فشله، فالتشغيل النظيف = نجاح الكل.
-- لا شيء يُحفظ: الملف كله داخل معاملة تُلغى في آخره.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. الحساب بالأيام — الدالة رابعة الوسائط
-- ------------------------------------------------------------
do $$ begin
  -- المدة بالأيام والهدية تُجمعان، ولا يبتلع أحدهما الآخر
  assert bot_engagement_expiry('2026-09-12 12:00:00+01', null, 0, 30)
         = '2026-10-12 12:00:00+01'::timestamptz, '30 يوماً = 30 يوماً';
  assert bot_engagement_expiry('2026-09-12 12:00:00+01', null, 7, 30)
         = '2026-10-19 12:00:00+01'::timestamptz, '30 يوماً + 7 هدية = 37';

  -- ثلاثية الوسائط لم تتغيّر بعد أن صارت تفوّض
  assert bot_engagement_expiry('2026-09-12 12:00:00+01', 12, 7)
         = bot_engagement_expiry('2026-09-12 12:00:00+01', 12, 7, 0),
         'النسخة القديمة = الجديدة بصفر أيام';
  assert bot_engagement_expiry('2026-01-31 10:00:00+01', 1, 1)
         = '2026-03-01 10:00:00+01'::timestamptz, '31 يناير + شهر + يوم = 1 مارس';

  -- الحدّ الأعلى للمدة بالأيام لا يكسر الحساب
  assert bot_engagement_expiry('2026-09-12 12:00:00+01', null, 0, 999)
         = '2029-06-07 12:00:00+01'::timestamptz, '999 يوماً';

  -- والتوقيت المحلي محفوظ عبر تبديل التوقيت الصيفي إن وُجد
  assert to_char(bot_engagement_expiry('2026-09-12 23:30:00+01', null, 0, 100)
                 at time zone 'Africa/Algiers', 'YYYY-MM-DD HH24:MI')
         = '2026-12-21 23:30', 'الساعة المحلية تبقى كما هي';
  raise notice 'PASS  الحساب بالأيام';
end $$;

-- ------------------------------------------------------------
-- 2. ترجمة وحدات المخزون إلى وحدات الوثيقة
-- ------------------------------------------------------------
do $$
declare v jsonb;
begin
  v := bot_duration_to_engagement(1, 'year');
  assert (v->>'months')::int = 12 and v->'days' = 'null'::jsonb, 'سنة = 12 شهراً';
  v := bot_duration_to_engagement(3, 'month');
  assert (v->>'months')::int = 3 and v->'days' = 'null'::jsonb, '3 أشهر';
  v := bot_duration_to_engagement(2, 'week');
  assert (v->>'days')::int = 14 and v->'months' = 'null'::jsonb, 'أسبوعان = 14 يوماً';
  v := bot_duration_to_engagement(45, 'day');
  assert (v->>'days')::int = 45 and v->'months' = 'null'::jsonb, '45 يوماً';

  -- المدة الفارغة تبقى فارغة، لا تُخمَّن بصفر
  v := bot_duration_to_engagement(null, null);
  assert v->'months' = 'null'::jsonb and v->'days' = 'null'::jsonb, 'الفارغ يبقى فارغاً';
  v := bot_duration_to_engagement(5, null);
  assert v->'months' = 'null'::jsonb and v->'days' = 'null'::jsonb, 'قيمة بلا وحدة = فارغ';
  raise notice 'PASS  ترجمة الوحدات';
end $$;

-- ------------------------------------------------------------
-- 3. المنصة والمدة والسعر على الكتالوج
-- ------------------------------------------------------------
do $$
declare
  v_owner_tg constant bigint := 910000001;
  v_seller_tg constant bigint := 910000002;
  v_prod  uuid;
  v_year  uuid;
  v_mo    uuid;
  v_res   jsonb;
  v_issue uuid;
  v_n     int;
begin
  perform bot_bootstrap_owner(v_owner_tg, 'o26', 'المالك');
  perform bot_add_admin(v_owner_tg, v_seller_tg, 'بائع');

  v_res := bot_add_product(v_owner_tg, 'nflx26', 'نتفليكس');
  v_prod := (v_res->>'product_id')::uuid;
  v_year := (bot_add_variant(v_owner_tg, 'nflx26', 'y', 'سنة')->>'variant_id')::uuid;
  v_mo   := (bot_add_variant(v_owner_tg, 'nflx26', 'm', 'شهر')->>'variant_id')::uuid;

  -- منتج جديد يولد بلا منصة ولا مدة ولا سعر: هذا هو الثقب
  v_res := bot_variant_subject(v_year);
  assert (v_res->>'needs_platform')::boolean, 'منتج جديد بلا منصة';
  assert (v_res->>'needs_duration')::boolean, 'صنف جديد بلا مدة';
  assert v_res->'price' = 'null'::jsonb, 'صنف جديد بلا سعر';

  -- ========== المنصة ==========
  perform bot_set_product_platform(v_owner_tg, v_prod, 'Netflix');
  v_res := bot_variant_subject(v_year);
  assert v_res->>'platform' = 'Netflix', 'المنصة حُفظت على المنتج';
  assert not (v_res->>'needs_platform')::boolean, 'لم تعد ناقصة';

  -- وتُحفظ على المنتج لا على الصنف: الصنف الثاني ورثها بلا سؤال
  assert bot_variant_subject(v_mo)->>'platform' = 'Netflix',
         'الصنف الثاني ورث المنصة — لا يُسأل عنها مرتين';

  -- منصة غير موجودة في القائمة تُضاف بدل أن تُرفض
  perform bot_set_product_platform(v_owner_tg, v_prod, 'Shahid VIP');
  select count(*) into v_n from bot_platforms where name = 'Shahid VIP';
  assert v_n = 1, 'منصة جديدة تُضاف إلى القائمة';
  assert bot_variant_subject(v_year)->>'platform' = 'Shahid VIP', 'وتُسند للمنتج';

  -- ومنصة معطّلة تعود للعمل حين يُسند إليها منتج
  perform bot_remove_platform(v_owner_tg, 'Shahid VIP');
  assert not (select is_active from bot_platforms where name = 'Shahid VIP'),
         'التعطيل تمّ';
  perform bot_set_product_platform(v_owner_tg, v_prod, 'Shahid VIP');
  assert (select is_active from bot_platforms where name = 'Shahid VIP'),
         'الإسناد يُعيد التفعيل';
  perform bot_set_product_platform(v_owner_tg, v_prod, 'Netflix');

  -- الفراغ يمسح، ولا يُخزَّن كنصّ فارغ
  perform bot_set_product_platform(v_owner_tg, v_prod, '   ');
  assert (select platform from bot_products where id = v_prod) is null,
         'الفراغ يمسح المنصة';
  perform bot_set_product_platform(v_owner_tg, v_prod, 'Netflix');

  -- البائع لا يعدّل الكتالوج
  begin
    perform bot_set_product_platform(v_seller_tg, v_prod, 'Spotify');
    assert false, 'بائع عدّل المنصة';
  exception when others then
    assert sqlerrm like 'NOT_OWNER%', 'المنصة للمالك وحده، وردّ: ' || sqlerrm;
  end;

  -- ========== المدة ==========
  perform bot_set_variant_duration(v_owner_tg, v_year, 1, 'year');
  v_res := bot_variant_subject(v_year);
  assert (v_res->>'months')::int = 12, 'سنة = 12 شهراً في الوثيقة';
  assert v_res->'days' = 'null'::jsonb, 'بالأشهر لا بالأيام';
  assert not (v_res->>'needs_duration')::boolean, 'المدة لم تعد ناقصة';

  perform bot_set_variant_duration(v_owner_tg, v_mo, 45, 'day');
  assert (bot_variant_subject(v_mo)->>'days')::int = 45, '45 يوماً';

  -- الوحدة المجهولة والقيمة الصفرية والمدى الخارج عن الوثيقة
  begin
    perform bot_set_variant_duration(v_owner_tg, v_mo, 3, 'fortnight');
    assert false, 'وحدة مخترعة قُبلت';
  exception when others then
    assert sqlerrm like 'INVALID_UNIT%', 'وحدة مجهولة، وردّ: ' || sqlerrm;
  end;
  begin
    perform bot_set_variant_duration(v_owner_tg, v_mo, 0, 'month');
    assert false, 'مدة صفرية قُبلت';
  exception when others then
    assert sqlerrm like 'INVALID_DURATION%', 'صفر مرفوض، وردّ: ' || sqlerrm;
  end;
  begin
    -- 6 سنوات = 72 شهراً، فوق حدّ الوثيقة (60)
    perform bot_set_variant_duration(v_owner_tg, v_mo, 6, 'year');
    assert false, '72 شهراً قُبلت';
  exception when others then
    assert sqlerrm like 'DURATION_RANGE%', 'فوق 60 شهراً مرفوض، وردّ: ' || sqlerrm;
  end;
  begin
    -- 200 أسبوع = 1400 يوماً، فوق 999
    perform bot_set_variant_duration(v_owner_tg, v_mo, 200, 'week');
    assert false, '1400 يوم قُبلت';
  exception when others then
    assert sqlerrm like 'DURATION_RANGE%', 'فوق 999 يوماً مرفوض، وردّ: ' || sqlerrm;
  end;
  -- ولم يُكتب شيء من المحاولات الفاشلة
  assert (bot_variant_subject(v_mo)->>'days')::int = 45, 'المدة لم تتغيّر بعد الرفض';
  perform bot_set_variant_duration(v_owner_tg, v_mo, 1, 'month');

  -- ========== السعر ==========
  v_res := bot_set_price(v_owner_tg, v_year, 3500);
  assert (v_res->>'price')::numeric = 3500, 'السعر حُفظ';
  assert v_res->>'currency' = 'DZD', 'العملة دج ثابتة';
  perform bot_set_price(v_owner_tg, v_mo, 900);

  begin
    perform bot_set_price(v_owner_tg, v_year, -1);
    assert false, 'سعر سالب قُبل';
  exception when others then
    assert sqlerrm like 'INVALID_PRICE%', 'السالب مرفوض، وردّ: ' || sqlerrm;
  end;
  begin
    perform bot_set_price(v_seller_tg, v_year, 1);
    assert false, 'بائع غيّر السعر';
  exception when others then
    assert sqlerrm like 'NOT_OWNER%', 'التسعير للمالك، وردّ: ' || sqlerrm;
  end;
  assert (select price from bot_variants where id = v_year) = 3500,
         'السعر لم يتغيّر بعد الرفض';

  -- صفر ≠ فارغ: المجاني بيع، وغير المسعّر ليس بيعاً مجانياً
  perform bot_set_price(v_owner_tg, v_mo, 0);
  assert (select price from bot_variants where id = v_mo) = 0, 'صفر يُحفظ صفراً';
  perform bot_set_price(v_owner_tg, v_mo, null);
  assert (select price from bot_variants where id = v_mo) is null, 'الفارغ يمسح';
  perform bot_set_price(v_owner_tg, v_mo, 900);

  -- ========== اللقطة ==========
  perform bot_add_cards(v_owner_tg, v_year, array['P26-1','P26-2','P26-3']);
  v_res := bot_request_card(v_seller_tg, v_year);
  v_issue := (v_res->>'issue_id')::uuid;
  assert (v_res->>'price')::numeric = 3500, 'السعر يُعرض على البائع عند الحجز';
  assert (select price from bot_issues where id = v_issue) = 3500,
         'السعر نُسخ إلى العملية';

  -- تبديل سعر الصنف لا يمسّ عملية سابقة: هذا سبب وجود اللقطة
  perform bot_set_price(v_owner_tg, v_year, 4200);
  assert (select price from bot_issues where id = v_issue) = 3500,
         'اللقطة صامدة أمام تغيير السعر';
  v_res := bot_confirm_issue(v_seller_tg, v_issue);
  assert (v_res->>'price')::numeric = 3500, 'والتأكيد يرجّع اللقطة لا السعر الجديد';

  -- والعملية التالية تأخذ السعر الجديد
  v_res := bot_request_card(v_seller_tg, v_year);
  assert (v_res->>'price')::numeric = 4200, 'العملية التالية بالسعر الجديد';
  perform bot_cancel_issue(v_seller_tg, (v_res->>'issue_id')::uuid);

  -- ========== تعديل سعر عملية ==========
  v_res := bot_request_card(v_seller_tg, v_year);
  v_issue := (v_res->>'issue_id')::uuid;
  perform bot_issue_set_price(v_seller_tg, v_issue, 3000);
  assert (select price from bot_issues where id = v_issue) = 3000, 'تخفيض مسجَّل';

  -- البائع الآخر لا يمسّ عملية ليست له
  perform bot_add_admin(v_owner_tg, 910000003, 'بائع ثان');
  begin
    perform bot_issue_set_price(910000003, v_issue, 1);
    assert false, 'بائع عدّل سعر عملية غيره';
  exception when others then
    assert sqlerrm like 'NOT_YOUR_ISSUE%', 'عملية الغير محميّة، وردّ: ' || sqlerrm;
  end;
  -- والمالك يمسّ كل شيء
  perform bot_issue_set_price(v_owner_tg, v_issue, 3100);
  assert (select price from bot_issues where id = v_issue) = 3100, 'المالك يصحّح';

  perform bot_confirm_issue(v_seller_tg, v_issue);
  -- التصحيح بعد الإتمام مسموح: الخطأ المطبعي يُكتشف بعد الضغط عادةً
  perform bot_issue_set_price(v_seller_tg, v_issue, 3200);
  assert (select price from bot_issues where id = v_issue) = 3200, 'تصحيح بعد الإتمام';

  -- أما الملغاة فليست بيعاً ولا تُسعَّر
  v_res := bot_request_card(v_seller_tg, v_year);
  v_issue := (v_res->>'issue_id')::uuid;
  perform bot_cancel_issue(v_seller_tg, v_issue);
  begin
    perform bot_issue_set_price(v_seller_tg, v_issue, 500);
    assert false, 'عملية ملغاة سُعّرت';
  exception when others then
    assert sqlerrm like 'ISSUE_CANCELLED%', 'الملغاة لا تُسعَّر، وردّ: ' || sqlerrm;
  end;
  raise notice 'PASS  المنصة والمدة والسعر';
end $$;

-- ------------------------------------------------------------
-- 4. التأكيد يحمل ما تحتاجه الوثيقة
-- ------------------------------------------------------------
do $$
declare
  v_owner_tg constant bigint := 920000001;
  v_prod uuid; v_var uuid; v_res jsonb; v_issue uuid;
begin
  perform bot_bootstrap_owner(v_owner_tg, 'o26b', 'المالك');
  v_prod := (bot_add_product(v_owner_tg, 'snap26', 'سناب')->>'product_id')::uuid;
  v_var  := (bot_add_variant(v_owner_tg, 'snap26', 'y', 'سنة')->>'variant_id')::uuid;
  perform bot_add_cards(v_owner_tg, v_var, array['S26-1','S26-2']);

  -- قبل التعمير: التأكيد يقول بصراحة ما ينقصه بدل أن يخمّن
  v_res := bot_request_card(v_owner_tg, v_var);
  v_issue := (v_res->>'issue_id')::uuid;
  v_res := bot_confirm_issue(v_owner_tg, v_issue);
  assert (v_res->>'needs_platform')::boolean, 'التأكيد يبلّغ أن المنصة ناقصة';
  assert (v_res->>'needs_duration')::boolean, 'ويبلّغ أن المدة ناقصة';
  assert v_res->'platform' = 'null'::jsonb, 'ولا يخترع منصة';
  assert v_res->'months' = 'null'::jsonb and v_res->'days' = 'null'::jsonb, 'ولا يخترع مدة';

  -- بعد التعمير: كل ما تحتاجه الوثيقة حاضر في مُرجَع التأكيد وحده
  perform bot_set_product_platform(v_owner_tg, v_prod, 'Snapchat Plus');
  perform bot_set_variant_duration(v_owner_tg, v_var, 1, 'year');
  perform bot_set_price(v_owner_tg, v_var, 2500);

  v_res := bot_request_card(v_owner_tg, v_var);
  v_res := bot_confirm_issue(v_owner_tg, (v_res->>'issue_id')::uuid);
  assert v_res->>'platform' = 'Snapchat Plus', 'المنصة في مُرجَع التأكيد';
  assert (v_res->>'months')::int = 12, 'والمدة';
  assert (v_res->>'price')::numeric = 2500, 'والسعر';
  assert not (v_res->>'needs_platform')::boolean
     and not (v_res->>'needs_duration')::boolean, 'ولا ينقص شيء';

  -- وما كان يُرجعه 022 لم يضع
  assert v_res->>'variant_name' = 'سنة' and v_res->>'product_name' = 'سناب',
         'الأسماء باقية';
  assert (v_res->>'seller_sales_of_variant')::int = 2, 'عدّاد الصنف باقٍ';
  assert (v_res->>'remaining')::int = 0, 'المتبقي باقٍ';
  raise notice 'PASS  مُرجَع التأكيد يكفي لتوليد الوثيقة';
end $$;

-- ------------------------------------------------------------
-- 5. الجرد
-- ------------------------------------------------------------
do $$
declare
  v_owner_tg  constant bigint := 930000001;
  v_seller_tg constant bigint := 930000002;
  v_prod uuid; v_var uuid; v_res jsonb; v_before int;
begin
  perform bot_bootstrap_owner(v_owner_tg, 'o26c', 'المالك');
  perform bot_add_admin(v_owner_tg, v_seller_tg, 'بائع');

  v_res := bot_data_audit(v_owner_tg);
  v_before := (v_res->>'missing_platform')::int;

  v_prod := (bot_add_product(v_owner_tg, 'aud26', 'منتج الجرد')->>'product_id')::uuid;
  v_var  := (bot_add_variant(v_owner_tg, 'aud26', 'v', 'صنف')->>'variant_id')::uuid;

  v_res := bot_data_audit(v_owner_tg);
  assert (v_res->>'missing_platform')::int = v_before + 1, 'الجرد يعدّ الناقص الجديد';
  assert v_res->>'currency' = 'DZD', 'العملة معلنة في الجرد';

  -- الصفّ نفسه حاضر بتفاصيله، فيُراجَع بالعين قبل أي تعمير
  assert exists (
    select 1 from jsonb_array_elements(v_res->'products') p
     where p->>'code' = 'aud26' and p->'platform' = 'null'::jsonb
       and exists (select 1 from jsonb_array_elements(p->'variants') v
                    where v->>'code' = 'v' and v->'price' = 'null'::jsonb
                      and v->'months' = 'null'::jsonb and v->'days' = 'null'::jsonb)
  ), 'المنتج والصنف الناقصان ظاهران في الجرد';

  perform bot_set_product_platform(v_owner_tg, v_prod, 'Canva Pro');
  perform bot_set_variant_duration(v_owner_tg, v_var, 6, 'month');
  perform bot_set_price(v_owner_tg, v_var, 1800);

  v_res := bot_data_audit(v_owner_tg);
  assert (v_res->>'missing_platform')::int = v_before, 'العدّ نقص بعد التعمير';
  assert exists (
    select 1 from jsonb_array_elements(v_res->'products') p
     where p->>'code' = 'aud26' and p->>'platform' = 'Canva Pro'
       and exists (select 1 from jsonb_array_elements(p->'variants') v
                    where v->>'code' = 'v' and (v->>'price')::numeric = 1800
                      and (v->>'months')::int = 6)
  ), 'القيم الجديدة ظاهرة';

  -- الجرد للمالك وحده
  begin
    perform bot_data_audit(v_seller_tg);
    assert false, 'بائع قرأ الجرد';
  exception when others then
    assert sqlerrm like 'NOT_OWNER%', 'الجرد للمالك، وردّ: ' || sqlerrm;
  end;
  raise notice 'PASS  الجرد';
end $$;

-- ------------------------------------------------------------
-- 6. قيود الوثيقة الجديدة
-- ------------------------------------------------------------
do $$
declare
  v_owner_tg constant bigint := 940000001;
  v_admin uuid; v_cert uuid;
begin
  perform bot_bootstrap_owner(v_owner_tg, 'o26d', 'المالك');
  select id into v_admin from bot_admins where telegram_id = v_owner_tg;

  -- وثيقة يدوية بالأيام: صارت مقبولة، وكانت مرفوضة قبل 026
  insert into bot_certificates (code, platform, duration_days, bonus_days, issued_by)
  values ('JW-TEST000001', 'Netflix', 45, 7, v_admin) returning id into v_cert;
  assert (select duration_days from bot_certificates where id = v_cert) = 45,
         'المدة بالأيام محفوظة';

  -- بالأشهر وبالأيام معاً: مدة لا تُقرأ في أي لغة
  begin
    insert into bot_certificates (code, platform, months, duration_days, issued_by)
    values ('JW-TEST000002', 'Netflix', 3, 40, v_admin);
    assert false, 'أشهر وأيام معاً قُبلت';
  exception when check_violation then null; end;

  -- بلا بيعة وبلا مدة: وثيقة بلا موضوع
  begin
    insert into bot_certificates (code, platform, issued_by)
    values ('JW-TEST000003', 'Netflix', v_admin);
    assert false, 'وثيقة بلا مدة قُبلت';
  exception when check_violation then null; end;

  -- بلا بيعة وبلا منصة
  begin
    insert into bot_certificates (code, months, issued_by)
    values ('JW-TEST000004', 12, v_admin);
    assert false, 'وثيقة بلا منصة قُبلت';
  exception when check_violation then null; end;

  -- وخارج المدى
  begin
    insert into bot_certificates (code, platform, duration_days, issued_by)
    values ('JW-TEST000005', 'Netflix', 1000, v_admin);
    assert false, '1000 يوم قُبلت';
  exception when check_violation then null; end;
  begin
    insert into bot_certificates (code, platform, duration_days, issued_by)
    values ('JW-TEST000006', 'Netflix', 0, v_admin);
    assert false, 'صفر يوم قُبل';
  exception when check_violation then null; end;
  raise notice 'PASS  قيود المدة على الوثيقة';
end $$;

-- ------------------------------------------------------------
-- 7. وثيقة واحدة لكل بيعة — والمسار اليدوي يبقى مفتوحاً
-- ------------------------------------------------------------
do $$
declare
  v_owner_tg constant bigint := 950000001;
  v_admin uuid; v_var uuid; v_issue uuid;
begin
  perform bot_bootstrap_owner(v_owner_tg, 'o26e', 'المالك');
  select id into v_admin from bot_admins where telegram_id = v_owner_tg;
  perform bot_add_product(v_owner_tg, 'uq26', 'منتج');
  v_var := (bot_add_variant(v_owner_tg, 'uq26', 'v', 'صنف')->>'variant_id')::uuid;
  perform bot_add_cards(v_owner_tg, v_var, array['U26-1']);
  v_issue := (bot_request_card(v_owner_tg, v_var)->>'issue_id')::uuid;
  perform bot_confirm_issue(v_owner_tg, v_issue);

  insert into bot_certificates (code, issue_id, issued_by)
  values ('JW-UNIQ000001', v_issue, v_admin);
  begin
    insert into bot_certificates (code, issue_id, issued_by)
    values ('JW-UNIQ000002', v_issue, v_admin);
    assert false, 'بيعة واحدة أخذت وثيقتين';
  exception when unique_violation then null; end;

  -- بينما الوثائق اليدوية (بلا بيعة) لا يحدّها شيء
  insert into bot_certificates (code, platform, months, issued_by)
  values ('JW-MAN0000001', 'Spotify', 3, v_admin);
  insert into bot_certificates (code, platform, months, issued_by)
  values ('JW-MAN0000002', 'Spotify', 3, v_admin);
  raise notice 'PASS  وثيقة لكل بيعة، والمسار اليدوي حرّ';
end $$;

-- ------------------------------------------------------------
-- 8. الصلاحيات
-- ------------------------------------------------------------
do $$
declare v_bad text;
begin
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('bot_set_price','bot_issue_set_price','bot_data_audit',
                       'bot_set_product_platform','bot_set_variant_duration',
                       'bot_variant_subject','bot_duration_to_engagement')
     and (has_function_privilege('anon', p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute'));
  assert v_bad is null, 'دوال مكشوفة لـ anon/authenticated: ' || coalesce(v_bad, '');
  raise notice 'PASS  الصلاحيات: service_role وحده';
end $$;

rollback;
