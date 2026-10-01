-- ============================================================
-- Janeiro Store — اختبارات لوحة التحكم الموحّدة (035)
--   psql "$DATABASE_URL" -f tests/admin-console.test.sql
-- كل تأكيد يرفع خطأ عند فشله، فالتشغيل النظيف = نجاح الكل.
-- الملف كله داخل معاملة تُلغى في آخره.
-- ============================================================

begin;

-- أدمن اللوحة وزائر مسجّل بلا دور
insert into auth.users (id, email, password) values
  ('35000000-0000-4000-8000-000000000001', 'admin35@janeiro.test', 'x'),
  ('35000000-0000-4000-8000-000000000002', 'user35@janeiro.test',  'x')
on conflict (id) do nothing;
insert into profiles (id, role, full_name)
  values ('35000000-0000-4000-8000-000000000001', 'admin', 'أدمن 35')
on conflict (id) do update set role = 'admin';

-- ------------------------------------------------------------
-- 1. بلا مالك بوت: رسالة واضحة، لا سقوط غامض
-- ------------------------------------------------------------
do $$
begin
  -- نعطّل أي مالك موجود من قبل حتى نختبر الغياب
  update bot_admins set is_active = false where role = 'owner';
  perform set_config('request.jwt.claims',
    '{"sub":"35000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  begin
    perform admin_bot('catalog');
    assert false, 'admin_bot worked with no bot owner';
  exception when others then
    assert sqlerrm like 'NO_BOT_OWNER%', 'بلا مالك: NO_BOT_OWNER، وجد ' || sqlerrm;
  end;
  -- والملخص يقول ذلك بدل أن يسقط
  assert (admin_bot_summary()->>'has_owner')::boolean = false, 'has_owner=false بلا مالك';
end $$;

-- ------------------------------------------------------------
-- 2. ليس أدمن: كل دالة ترفض
-- ------------------------------------------------------------
do $$
declare fn text;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"35000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  foreach fn in array array[
    'select admin_bot(''catalog'')',
    'select admin_bot_sales()',
    'select admin_bot_summary()',
    'select admin_site_certificates()',
    'select admin_customers()',
    'select admin_bot_cards(gen_random_uuid())'] loop
    begin
      execute fn;
      assert false, 'non-admin ran: ' || fn;
    exception when others then
      assert sqlerrm like 'NOT_ADMIN%', fn || ' → ' || sqlerrm;
    end;
  end loop;
end $$;

-- والدوال ممنوعة على anon من الأساس
do $$
begin
  assert not has_function_privilege('anon', 'admin_bot(text,jsonb)', 'execute'), 'anon لا ينفّذ admin_bot';
  assert not has_function_privilege('anon', 'admin_customers(text,int,int)', 'execute'), 'anon لا ينفّذ admin_customers';
  assert has_function_privilege('authenticated', 'admin_bot(text,jsonb)', 'execute'), 'authenticated ينفّذ (والفحص في الداخل)';
end $$;

-- ------------------------------------------------------------
-- 3. الأدمن يدير البوت بصفة المالك
-- ------------------------------------------------------------
do $$
declare
  v_owner constant bigint := 950000001;
  v_sell  constant bigint := 950000002;
  v jsonb; v_var uuid; v_prod uuid; v_iss uuid; v_card uuid; v_mkt text;
begin
  perform bot_bootstrap_owner(v_owner, 'o35', 'مالك 35');
  update bot_admins set is_active = true where telegram_id = v_owner;
  perform set_config('request.jwt.claims',
    '{"sub":"35000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

  assert admin_bot_actor() is not null, 'المالك محدَّد';

  -- بائع جديد من اللوحة
  v := admin_bot('add_admin', jsonb_build_object('telegram_id', v_sell, 'name', 'بائع 35'));
  assert (v->>'telegram_id')::bigint = v_sell, 'add_admin: ' || v::text;

  -- منتج ومدة وأكواد وسعر
  v := admin_bot('add_product', '{"code":"spot35","name":"سبوتيفاي 35"}');
  v_prod := (v->>'product_id')::uuid;
  v := admin_bot('add_variant', '{"product_code":"spot35","code":"y1","name":"سنة"}');
  v_var := (v->>'variant_id')::uuid;
  v := admin_bot('add_cards', jsonb_build_object('variant_id', v_var,
         'codes', jsonb_build_array('C35-1','C35-2','C35-3','C35-1')));
  assert (v->>'added')::int = 3, 'تُضاف 3، والمكرّر يُرفض: ' || v::text;
  assert (v->>'duplicates')::int = 1, 'والمكرّر يُعدّ';

  select code into v_mkt from bot_markets where is_active order by sort_order limit 1;
  v := admin_bot('set_price', jsonb_build_object('variant_id', v_var, 'market', v_mkt, 'price', 3900));
  assert (v->>'price')::numeric = 3900, 'set_price: ' || v::text;

  -- الكتالوج الكامل: السعر لكل سوق والعدّ
  v := admin_bot_catalog();
  assert exists (select 1 from jsonb_array_elements(v) p, jsonb_array_elements(p->'variants') x
                  where p->>'code' = 'spot35' and (x->'prices'->>v_mkt)::numeric = 3900
                    and (x->>'available')::int = 3),
         'admin_bot_catalog: السعر والعدد';

  -- الكتالوج من اللوحة يرى ما أُضيف
  v := admin_bot('catalog');
  assert exists (select 1 from jsonb_array_elements(v) p, jsonb_array_elements(p->'variants') x
                  where p->>'code' = 'spot35' and (x->>'available')::int = 3),
         'catalog: 3 متاحة';

  -- إيقاف كود ثم إرجاعه
  select id into v_card from bot_cards where variant_id = v_var order by seq limit 1;
  v := admin_bot_card_set(v_card, true);
  assert (select status from bot_cards where id = v_card) = 'disabled', 'الكود يتوقّف';
  v := admin_bot_card_set(v_card, false);
  assert (select status from bot_cards where id = v_card) = 'available', 'ويرجع';
  assert jsonb_array_length(admin_bot_cards(v_var)) = 3, 'admin_bot_cards: 3 أكواد';
  assert jsonb_array_length(admin_bot_cards(v_var, 'available')) = 3, 'كلها متاحة';

  -- بيع من البائع (من البوت)، ثم يظهر في اللوحة
  v := bot_request_card(v_sell, v_var, 'زبون 35', null, null);
  v_iss := (v->>'issue_id')::uuid;
  -- كود محجوز لا يُوقف
  begin
    perform admin_bot_card_set((select card_id from bot_issues where id = v_iss), true);
    assert false, 'a reserved card was disabled';
  exception when others then
    assert sqlerrm like 'CARD_IN_USE%', 'المحجوز محميّ: ' || sqlerrm;
  end;

  assert jsonb_array_length(admin_bot('pending')) >= 1, 'المعلّقة تظهر للمالك';
  v := admin_bot_sales('pending');
  assert (v->>'total')::int >= 1, 'admin_bot_sales pending: ' || v::text;

  -- المالك يؤكّد من اللوحة
  v := admin_bot('confirm_issue', jsonb_build_object('issue_id', v_iss));
  v := admin_bot_sales('confirmed', v_sell);
  assert (v->>'total')::int = 1, 'بيعة واحدة مؤكّدة للبائع';
  assert v->'rows'->0->>'customer_ref' = 'زبون 35', 'بالزبون';
  assert v->'rows'->0->>'seller' = 'بائع 35', 'وباسم البائع';
  v := admin_bot_sales(null, null, 'زبون 35');
  assert (v->>'total')::int = 1, 'والبحث بالزبون يجدها';

  -- الملخص
  v := admin_bot_summary();
  assert (v->>'has_owner')::boolean, 'has_owner';
  assert (v->>'sold_today')::int >= 1, 'بيعة اليوم محسوبة: ' || v::text;
  assert exists (select 1 from jsonb_array_elements(v->'low_stock') x where x->>'product' = 'سبوتيفاي 35'),
         'بقي كودان: مخزون منخفض';

  -- البائعين
  v := admin_bot('sellers');
  assert exists (select 1 from jsonb_array_elements(v) x
                  where (x->>'telegram_id')::bigint = v_sell and (x->>'confirmed')::int = 1),
         'البائع ببيعته: ' || v::text;

  -- إيقاف المنتج وإرجاعه
  v := admin_bot('set_active', jsonb_build_object('kind', 'product', 'id', v_prod, 'active', false));
  assert not (select is_active from bot_products where id = v_prod), 'المنتج يتوقّف';
  v := admin_bot('set_active', jsonb_build_object('kind', 'product', 'id', v_prod, 'active', true));

  -- فعل غير معروف يُرفض
  begin
    perform admin_bot('drop_everything');
    assert false, 'unknown action ran';
  exception when others then
    assert sqlerrm like 'UNKNOWN_ACTION%', 'فعل مجهول: ' || sqlerrm;
  end;

  -- حذف البائع
  v := admin_bot('remove_admin', jsonb_build_object('telegram_id', v_sell));
  assert not exists (select 1 from bot_admins where telegram_id = v_sell and is_active),
         'البائع يتنحّى';
end $$;

-- ------------------------------------------------------------
-- 4. زبائن الموقع ووثائقه
-- ------------------------------------------------------------
do $$
declare v jsonb; v_prod uuid; v_plan uuid; v_pm uuid; v_o uuid; v_i uuid;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"35000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  select id into v_pm from payment_methods order by sort_order limit 1;
  select p.id, pl.id into v_prod, v_plan
    from products p join product_plans pl on pl.product_id = p.id limit 1;

  insert into orders (order_number, customer_name, customer_phone, normalized_phone,
                      payment_method_id, subtotal, total, currency, status, idempotency_key,
                      receipt_path, receipt_uploaded_at, submitted_at)
  values ('935001', 'زبونة الاختبار', '0661350001', '213661350001',
          v_pm, 1500, 1500, 'DZD', 'completed', gen_random_uuid()::text,
          'receipts/test35.jpg', now(), now())
  returning id into v_o;
  insert into order_items (order_id, product_id, plan_id, product_name_snapshot, plan_name_snapshot,
                           unit_price, quantity, total_price, warranty_label_snapshot)
  values (v_o, v_prod, v_plan, 'منتج 35', 'شهر', 1500, 1, 1500, 'ضمان التفعيل')
  returning id into v_i;
  insert into warranty_certificates (certificate_code, order_item_id, starts_at, ends_at)
  values ('JW-35TESTCODE01', v_i, now(), now() + interval '30 days');

  v := admin_customers('0661350001');
  assert (v->>'total')::int = 1, 'الزبون بالرقم المحلي: ' || v::text;
  assert v->'rows'->0->>'name' = 'زبونة الاختبار', 'بالاسم';
  assert (v->'rows'->0->>'spent')::numeric = 1500, 'والمصروف';
  v := admin_customers('زبونة');
  assert (v->>'total')::int >= 1, 'وبالاسم';

  v := admin_site_certificates('JW-35TESTCODE01');
  assert (v->>'total')::int = 1, 'الوثيقة بالكود: ' || v::text;
  assert v->'rows'->0->>'order_number' = '935001', 'برقم الطلب';
  assert (v->'rows'->0->>'active')::boolean, 'وسارية';
  v := admin_site_certificates('935001');
  assert (v->>'total')::int = 1, 'وبرقم الطلب';
end $$;

-- ------------------------------------------------------------
-- 5. إعدادات المتجر
-- ------------------------------------------------------------
do $$
declare v jsonb; v_cat uuid; v_pm uuid; v_prod uuid; v_plan uuid; v_price numeric; v_deal uuid;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"35000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

  v := admin_store_config();
  assert jsonb_typeof(v->'categories') = 'array' and jsonb_typeof(v->'payment_methods') = 'array',
         'config: الأقسام وطرق الدفع';

  -- الإعدادات: الرقم المحلي يُحفظ دولياً، والمفتاح المجهول يُرفض
  v := admin_save_settings('{"whatsapp_number":"0661 35 00 01","instagram_username":"@jan_35"}');
  assert (select value from store_settings where key = 'whatsapp_number') = '213661350001', 'واتساب دولي';
  assert (select value from store_settings where key = 'instagram_username') = 'jan_35', 'بلا @';
  begin
    perform admin_save_settings('{"service_role_key":"x"}');
    assert false, 'unknown setting saved';
  exception when others then assert sqlerrm like 'UNKNOWN_SETTING%', sqlerrm; end;
  begin
    perform admin_save_settings('{"whatsapp_number":"12"}');
    assert false, 'bad whatsapp saved';
  exception when others then assert sqlerrm like 'INVALID_WHATSAPP%', sqlerrm; end;
  begin
    perform admin_save_settings('{"site_url":"javascript:alert(1)"}');
    assert false, 'bad site_url saved';
  exception when others then assert sqlerrm like 'INVALID_SITE_URL%', sqlerrm; end;

  -- قسم جديد ثم تعديله، والمعرّف المكرّر يُرفض
  v := admin_upsert_category('{"name":"قسم 35","slug":"cat-35","accent_color":"#7C3AED"}');
  v_cat := (v->>'id')::uuid;
  v := admin_upsert_category(jsonb_build_object('id', v_cat, 'name', 'قسم 35 معدّل', 'slug', 'cat-35', 'is_active', false));
  assert (select name from categories where id = v_cat) = 'قسم 35 معدّل', 'القسم يتعدّل';
  begin
    perform admin_upsert_category('{"name":"آخر","slug":"cat-35"}');
    assert false, 'duplicate slug';
  exception when others then assert sqlerrm like 'SLUG_TAKEN%', sqlerrm; end;

  -- طريقة دفع
  select id into v_pm from payment_methods order by sort_order limit 1;
  v := admin_upsert_payment_method(jsonb_build_object('id', v_pm, 'label', 'CCP', 'account_number', '0099 35'));
  assert (select account_number from payment_methods where id = v_pm) = '0099 35', 'رقم الحساب يتعدّل';

  -- عرض: سعره لازم أقل، ونافذته صحيحة
  select p.id, pl.id, pl.price into v_prod, v_plan, v_price
    from products p join product_plans pl on pl.product_id = p.id
   where p.status = 'published' and pl.is_active limit 1;
  begin
    perform admin_upsert_deal(jsonb_build_object('product_id', v_prod, 'plan_id', v_plan,
              'deal_price', v_price + 1, 'ends_at', now() + interval '1 day'));
    assert false, 'deal above list price';
  exception when others then assert sqlerrm like 'DEAL_PRICE_NOT_LOWER%', sqlerrm; end;
  v := admin_upsert_deal(jsonb_build_object('product_id', v_prod, 'plan_id', v_plan,
         'deal_price', v_price - 1, 'ends_at', now() + interval '1 day'));
  v_deal := (v->>'id')::uuid;
  assert exists (select 1 from jsonb_array_elements(admin_store_config()->'deals') d
                  where (d->>'id')::uuid = v_deal and (d->>'live')::boolean), 'العرض حيّ';
  v := admin_delete_deal(v_deal);
  assert not exists (select 1 from daily_deals where id = v_deal), 'والعرض يتحذف';
end $$;

rollback;
\echo 'PASS admin-console: all checks passed'
