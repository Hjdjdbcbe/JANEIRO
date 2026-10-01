-- ============================================================
-- Janeiro Store — اختبارات نصوص الموقع (036)
--   psql "$DATABASE_URL" -f tests/site-texts.test.sql
-- كل تأكيد يرفع خطأ عند فشله. الملف كله داخل معاملة تُلغى في آخره.
-- ============================================================

begin;

insert into auth.users (id, email, password) values
  ('36000000-0000-4000-8000-000000000001', 'admin36@janeiro.test', 'x'),
  ('36000000-0000-4000-8000-000000000002', 'user36@janeiro.test',  'x')
on conflict (id) do nothing;
insert into profiles (id, role, full_name)
  values ('36000000-0000-4000-8000-000000000001', 'admin', 'أدمن 36')
on conflict (id) do update set role = 'admin';

-- الصلاحيات: القراءة للجميع، والكتابة المباشرة لا لأحد
do $$
begin
  assert has_column_privilege('anon', 'site_texts', 'value', 'select'), 'anon يقرأ النصوص';
  assert not has_table_privilege('anon', 'site_texts', 'insert'), 'anon لا يكتب';
  assert not has_table_privilege('authenticated', 'site_texts', 'update'), 'authenticated لا يعدّل مباشرة';
  assert not has_table_privilege('authenticated', 'site_texts', 'delete'), 'authenticated لا يحذف مباشرة';
  assert not has_function_privilege('anon', 'admin_set_site_texts(jsonb)', 'execute'), 'anon لا ينفّذ';
end $$;

-- ليس أدمن: مرفوض
do $$
begin
  perform set_config('request.jwt.claims',
    '{"sub":"36000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  begin
    perform admin_set_site_texts('[{"key":"hero_title","lang":"ar","value":"x"}]');
    assert false, 'non-admin wrote a site text';
  exception when others then
    assert sqlerrm like 'NOT_ADMIN%', 'ليس أدمن: ' || sqlerrm;
  end;
end $$;

-- الأدمن: حفظ، تعديل، رجوع للأصل، ورفض المدخلات الفاسدة
do $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"36000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  delete from site_texts where key in ('nav_home', 'hero_title');

  v := admin_set_site_texts('[{"key":"nav_home","lang":"ar","value":"  البداية  "},
                              {"key":"nav_home","lang":"fr","value":"Début"},
                              {"key":"hero_title","lang":"en","value":"Hello"}]');
  assert (v->>'saved')::int = 3, 'تحفظ 3: ' || v::text;
  assert (select value from site_texts where key = 'nav_home' and lang = 'ar') = 'البداية', 'الفراغات تتنحّى';
  assert (select updated_by from site_texts where key = 'nav_home' and lang = 'ar')
         = '36000000-0000-4000-8000-000000000001', 'يتسجّل شكون بدّل';

  v := admin_set_site_texts('[{"key":"nav_home","lang":"ar","value":"الرئيسية الجديدة"}]');
  assert (select value from site_texts where key = 'nav_home' and lang = 'ar') = 'الرئيسية الجديدة', 'التعديل يكتب فوق';
  assert (select count(*) from site_texts where key = 'nav_home') = 2, 'بلا صفوف مكرّرة';

  v := admin_set_site_texts('[{"key":"nav_home","lang":"fr","value":""},{"key":"hero_title","lang":"en","value":null}]');
  assert (v->>'reset')::int = 2, 'الفارغ يرجع للأصل: ' || v::text;
  assert not exists (select 1 from site_texts where key = 'hero_title'), 'الصف يتحذف';

  foreach v in array array[
    '[{"key":"Bad-Key","lang":"ar","value":"x"}]'::jsonb,
    '[{"key":"nav_home","lang":"de","value":"x"}]'::jsonb,
    jsonb_build_array(jsonb_build_object('key','nav_home','lang','ar','value', repeat('x', 4001))),
    '{"key":"nav_home"}'::jsonb] loop
    begin
      perform admin_set_site_texts(v);
      assert false, 'bad input accepted: ' || left(v::text, 60);
    exception when others then
      assert sqlerrm ~ '^(INVALID_KEY|INVALID_LANG|TEXT_TOO_LONG|INVALID_ITEMS)', 'مرفوض بسبب واضح: ' || sqlerrm;
    end;
  end loop;
  -- والدفعة الفاسدة لا تكتب شيئاً منها
  begin
    perform admin_set_site_texts('[{"key":"nav_faq","lang":"ar","value":"ok"},{"key":"nav_faq","lang":"xx","value":"no"}]');
  exception when others then null;
  end;
  assert not exists (select 1 from site_texts where key = 'nav_faq'), 'الدفعة كلها أو لا شيء';
end $$;

-- وزائر الموقع يقرأ ما حُفظ
do $$
begin
  set local role anon;
  assert (select value from site_texts where key = 'nav_home' and lang = 'ar') = 'الرئيسية الجديدة', 'anon يقرأ التعديل';
  reset role;
end $$;

\echo 'PASS site-texts: all checks passed'
rollback;
