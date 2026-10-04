-- ============================================================
-- Janeiro Store — 038: ملاحظة لكل خطة
--   psql "$DATABASE_URL" -f tests/plan-note.test.sql
-- الملف كله داخل معاملة تُلغى في آخره.
-- ============================================================
begin;

do $$
declare
  v jsonb; v_id uuid; v_plans jsonb; v_long text := repeat('ن', 120);
  v_admin constant uuid := '38383838-3838-4838-8838-383838383838';
begin
  insert into auth.users(id) values (v_admin) on conflict (id) do nothing;
  insert into profiles(id, role) values (v_admin, 'admin')
    on conflict (id) do update set role = 'admin';
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  -- الكتابة: ملاحظة تُقصّ مسافاتها، والفارغة تبقى null، والطويلة تُقطع عند 80
  v := admin_upsert_product(jsonb_build_object(
    'slug', 't-note', 'name', 'منتج ملاحظة', 'category_slug', 'ai', 'status', 'published',
    'plans', jsonb_build_array(
      jsonb_build_object('name', 'شهر', 'price', 1000, 'note', '  التفعيل للآيفون  '),
      jsonb_build_object('name', 'سنة', 'price', 9000, 'note', '   '),
      jsonb_build_object('name', 'سنتان', 'price', 15000, 'note', v_long))));
  v_id := (v->>'id')::uuid;
  assert (select note from product_plans where product_id = v_id and name = 'شهر') = 'التفعيل للآيفون',
         'the note is saved, trimmed';
  assert (select note from product_plans where product_id = v_id and name = 'سنة') is null,
         'a blank note is stored as null';
  assert (select char_length(note) from product_plans where product_id = v_id and name = 'سنتان') = 80,
         'a long note is cut at 80';
  raise notice 'PASS  a plan note is written, trimmed and capped';

  -- القراءة: اللوحة تستلم الحقل، والحفظ بعدها لا يمسحه
  select p->'plans' into v_plans from jsonb_array_elements(admin_list_products()) p
   where p->>'slug' = 't-note';
  assert v_plans->0->>'note' = 'التفعيل للآيفون', 'admin_list_products returns the note';

  perform admin_upsert_product(jsonb_build_object(
    'slug', 't-note', 'name', 'منتج ملاحظة', 'category_slug', 'ai', 'status', 'published',
    'plans', v_plans));
  assert (select note from product_plans where product_id = v_id and name = 'شهر') = 'التفعيل للآيفون',
         'saving what the editor loaded keeps the note';

  v_plans := jsonb_set(v_plans, '{0,note}', '""');
  perform admin_upsert_product(jsonb_build_object(
    'slug', 't-note', 'name', 'منتج ملاحظة', 'category_slug', 'ai', 'status', 'published',
    'plans', v_plans));
  assert (select note from product_plans where product_id = v_id and name = 'شهر') is null,
         'clearing the field removes the note';
  raise notice 'PASS  the editor reads the note back and can clear it';

  -- الزبون يقرأ الحقل
  set local role anon;
  assert (select count(*) from product_plans where product_id = v_id and note is not null) = 1,
         'anon can read plan notes';
  reset role;
  raise notice 'PASS  the storefront can read plan notes';

  raise notice '===== plan note tests passed =====';
end $$;

rollback;
