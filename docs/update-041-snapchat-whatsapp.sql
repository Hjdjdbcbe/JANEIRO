-- Janeiro Store — سناب شات + رقم واتساب الجديد (0798561763)
-- الصق كل هذا في SQL Editor واضغط Run مرة واحدة.

insert into store_settings (key, value, is_public) values ('snapchat_username', 'janeiro_store', true)
  on conflict (key) do nothing;

create or replace function admin_save_settings(p_values jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare k text; v text; v_n int := 0;
begin
  if not is_admin() then raise exception 'NOT_ADMIN'; end if;
  for k, v in select key, value from jsonb_each_text(coalesce(p_values, '{}'::jsonb)) loop
    v := btrim(coalesce(v, ''));
    if k not in ('store_name','whatsapp_number','instagram_username','telegram_username','snapchat_username',
                 'support_hours','support_message','site_url','max_active_orders') then
      raise exception 'UNKNOWN_SETTING:%', k;
    end if;
    if k = 'whatsapp_number' then
      v := regexp_replace(v, '[^0-9]', '', 'g');
      if v ~ '^0[567][0-9]{8}$' then v := '213' || substr(v, 2); end if;
      if v <> '' and v !~ '^[0-9]{10,15}$' then raise exception 'INVALID_WHATSAPP'; end if;
    elsif k in ('instagram_username','telegram_username','snapchat_username') then
      -- a pasted profile link is reduced to the name it ends with
      v := regexp_replace(v, '^https?://[^?#]*/', '');
      v := regexp_replace(v, '[?#].*$', '');
      v := regexp_replace(v, '^@', '');
      if v <> '' and v !~ '^[A-Za-z0-9._-]{1,40}$' then raise exception 'INVALID_USERNAME:%', k; end if;
    elsif k = 'site_url' then
      v := regexp_replace(v, '/+$', '');
      if v <> '' and v !~ '^https://[^\s/]+(/[^\s]*)?$' then raise exception 'INVALID_SITE_URL'; end if;
    elsif k = 'max_active_orders' then
      if v !~ '^[0-9]{1,2}$' or v::int < 1 then raise exception 'INVALID_MAX_ACTIVE_ORDERS'; end if;
    elsif k = 'store_name' and v = '' then
      raise exception 'INVALID_STORE_NAME';
    end if;
    if char_length(v) > 300 then raise exception 'SETTING_TOO_LONG:%', k; end if;
    insert into store_settings (key, value, is_public) values (k, v, true)
      on conflict (key) do update set value = excluded.value, updated_at = now();
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('saved', v_n);
end $$;

-- رقم واتساب الجديد: أزرار الموقع ورسائل الطلبات
update store_settings set value = '213798561763' where key = 'whatsapp_number';

-- أرقام واتساب في البوت (وثيقة الضمان وصفحة الزبون)
update bot_contacts
   set value = '0798561763', url = 'https://wa.me/213798561763'
 where url ilike '%wa.me%' or label ilike '%whats%' or label like '%واتس%';

-- النتيجة: يجب أن تقرأ 213798561763 و janeiro_store
select key, value from store_settings where key in ('whatsapp_number', 'snapchat_username');
