-- ============================================================
-- Janeiro Store — 041: حساب السناب شات من اللوحة
-- الملف كله داخل معاملة تُلغى في آخره.
-- ============================================================
begin;

do $$
declare v_admin constant uuid := '41414141-4141-4141-8141-414141414141'; v_ok boolean;
begin
  insert into auth.users(id) values (v_admin) on conflict (id) do nothing;
  insert into profiles(id, role) values (v_admin, 'admin') on conflict (id) do update set role = 'admin';
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  assert (select value from store_settings where key = 'snapchat_username') is not null, 'the key exists';

  perform admin_save_settings(jsonb_build_object('snapchat_username', 'https://www.snapchat.com/add/janeiro_store?share_id=abc'));
  assert (select value from store_settings where key = 'snapchat_username') = 'janeiro_store', 'a pasted link keeps only the name';
  perform admin_save_settings(jsonb_build_object('snapchat_username', '@janeiro.store-1'));
  assert (select value from store_settings where key = 'snapchat_username') = 'janeiro.store-1', 'a name with @ is accepted';
  v_ok := false;
  begin perform admin_save_settings(jsonb_build_object('snapchat_username', 'bad name!'));
  exception when others then v_ok := sqlerrm like '%INVALID_USERNAME%'; end;
  assert v_ok, 'a malformed name is refused';
  raise notice 'PASS  the dashboard saves the Snapchat account';

  perform admin_save_settings(jsonb_build_object('whatsapp_number', '0798561763'));
  assert (select value from store_settings where key = 'whatsapp_number') = '213798561763', 'a local WhatsApp number is stored as 213…';
  raise notice 'PASS  the WhatsApp number is normalised';

  set local role anon;
  assert (select count(*) from store_settings where key = 'snapchat_username') = 1, 'anon reads it';
  reset role;
  raise notice '===== snapchat tests passed =====';
end $$;

rollback;
