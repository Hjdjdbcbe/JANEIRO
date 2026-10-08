-- bundle: bot
-- ============================================================
-- Janeiro Store — 043 بوت التفعيل على واتساب
--
-- الكليان يولي على WhatsApp Cloud API (نفس رقم المتجر، Coexistence)،
-- وتيليغرام يبقى للأدمين. الرقم مشترك مع مالك، فالبوت ساكت إلا
-- مع رقم بعث كود صحيح ولا عندو طلب مفتوح.
--
--   - حالة CLOSED: /stop، ولا طلب ما كملش في 48 ساعة
--   - window_expires_at: نافذة 24 ساعة تاع واتساب
--   - الكود يكمل في قناة أخرى (احتياط)، ماشي من رقم آخر في نفس القناة
--   - bot_media: النسخة الأصلية في Storage (bot-media) باش يتعاود
--     الرفع لواتساب كي يموت media_id
--   - مسودات الفوكالات (الحفظ بالأزرار في تيليغرام)
--   - مصروف الـAI اليومي
-- ============================================================

-- ---------- الحالات ----------
alter table activation_orders drop constraint if exists activation_orders_status_check;
alter table activation_orders add constraint activation_orders_status_check check (status in (
  'WAIT_CODE','WAIT_SNAP_SCREENSHOT','LINK_SENT','WAIT_ACTIVATION_DONE',
  'WAIT_PLAN_CHANGE','WAIT_CONFIRM_SCREENSHOT','DONE','HUMAN','CLOSED'));

alter table activation_orders add column if not exists window_expires_at timestamptz;
alter table activation_orders add column if not exists closed_reason text;

-- ---------- الميديا في Storage ----------
alter table bot_media add column if not exists storage_path text;
alter table bot_media add column if not exists mime text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('bot-media', 'bot-media', false, 16777216,
        array['video/mp4','image/jpeg','image/png','audio/ogg','audio/mpeg','audio/mp4'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ---------- مسودات: فوكال/فيديو بعثو مالك ومازال ما ختارش الخانة ----------
create table if not exists bot_media_drafts (
  id            serial primary key,
  admin_chat_id text not null,
  kind          text not null check (kind in ('video','photo','voice')),
  tg_file_id    text not null,
  mime          text,
  slot          text,
  created_at    timestamptz not null default now()
);

-- ---------- مصروف الـAI ----------
create table if not exists ai_spend (
  day     date primary key,
  usd     numeric(12,6) not null default 0,
  calls   integer not null default 0,
  alerted boolean not null default false
);

alter table bot_media_drafts enable row level security;
alter table ai_spend         enable row level security;
revoke all on bot_media_drafts, ai_spend from anon, authenticated;

-- ============================================================
-- الدوال
-- ============================================================

-- كل ميساج من كليان: حد الميساجات + الطلب الحالي + نافذة 24 ساعة
create or replace function act_touch_chat(p_platform text, p_chat_id text, p_is_media boolean default false,
                                          p_max_msgs integer default 20, p_max_media integer default 6)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c activation_chats; o activation_orders; v_allowed boolean := true; v_warn boolean := false;
begin
  insert into activation_chats(platform, chat_id) values (p_platform, p_chat_id)
    on conflict (platform, chat_id) do nothing;
  select * into c from activation_chats where platform = p_platform and chat_id = p_chat_id for update;

  if c.rl_window < now() - interval '1 minute' then
    c.rl_window := now(); c.rl_count := 0; c.rl_media := 0; c.rl_warned := false;
  end if;
  c.rl_count := c.rl_count + 1;
  if p_is_media then c.rl_media := c.rl_media + 1; end if;
  if c.rl_count > p_max_msgs or (p_is_media and c.rl_media > p_max_media) then
    v_allowed := false;
    if not c.rl_warned then v_warn := true; c.rl_warned := true; end if;
  end if;
  update activation_chats set rl_window = c.rl_window, rl_count = c.rl_count, rl_media = c.rl_media,
         rl_warned = c.rl_warned
   where platform = p_platform and chat_id = p_chat_id;

  if c.current_order is not null then
    -- الكليان كتب: نافذة واتساب تتجدد 24 ساعة
    update activation_orders set window_expires_at = now() + interval '24 hours'
     where id = c.current_order and customer_chat_id = p_chat_id and platform = p_platform
     returning * into o;
  end if;

  return jsonb_build_object(
    'allowed', v_allowed, 'warn', v_warn,
    'blocked', c.blocked_until is not null and c.blocked_until > now(),
    'order', case when o.id is null then null else to_jsonb(o) end,
    'review_mode', coalesce((select value from store_settings where key = 'activation_review_mode'), 'on'));
end $$;

-- الكليان بعث كود طلب
--   ok       كود جديد، يتربط بهذا الرقم
--   resumed  نفس الرقم يعاود
--   moved    نفس الكود من قناة أخرى (احتياط): يكمل من وين وقف
--   invalid  غالط، ميت، مغلوق، ولا مستعمل من رقم آخر في نفس القناة
--   blocked  5 غالطين: ساكت ساعة
create or replace function act_claim_code(p_platform text, p_chat_id text, p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c activation_chats; o activation_orders; v_code text; v_from text;
begin
  insert into activation_chats(platform, chat_id) values (p_platform, p_chat_id)
    on conflict (platform, chat_id) do nothing;
  select * into c from activation_chats where platform = p_platform and chat_id = p_chat_id for update;

  if c.blocked_until is not null and c.blocked_until > now() then
    return jsonb_build_object('result', 'blocked');
  end if;

  v_code := upper(regexp_replace(coalesce(p_code, ''), '[^0-9A-Za-z]', '', 'g'));
  v_code := regexp_replace(v_code, '^JN', 'JN-');
  select * into o from activation_orders where code = v_code for update;

  if found and o.status <> 'CLOSED' and o.customer_chat_id = p_chat_id and o.platform = p_platform then
    update activation_orders set window_expires_at = now() + interval '24 hours' where id = o.id returning * into o;
    update activation_chats set current_order = o.id, bad_attempts = 0, blocked_until = null
     where platform = p_platform and chat_id = p_chat_id;
    return jsonb_build_object('result', 'resumed', 'order', to_jsonb(o));
  end if;

  if found and o.customer_chat_id is null and o.status = 'WAIT_CODE' and o.expires_at > now() then
    update activation_orders
       set customer_chat_id = p_chat_id, platform = p_platform, bound_at = now(),
           status = 'WAIT_SNAP_SCREENSHOT', window_expires_at = now() + interval '24 hours'
     where id = o.id returning * into o;
    update activation_chats set current_order = o.id, bad_attempts = 0, blocked_until = null
     where platform = p_platform and chat_id = p_chat_id;
    insert into bot_events(order_id, chat_id, kind, data) values (o.id, p_chat_id, 'code_claimed', jsonb_build_object('platform', p_platform));
    return jsonb_build_object('result', 'ok', 'order', to_jsonb(o));
  end if;

  -- احتياط: نفس الكود من قناة أخرى -> يكمل في القناة الجديدة
  if found and o.customer_chat_id is not null and o.platform <> p_platform
     and o.status not in ('DONE','CLOSED') then
    v_from := o.platform;
    update activation_chats set current_order = null
     where platform = o.platform and chat_id = o.customer_chat_id and current_order = o.id;
    update activation_orders set customer_chat_id = p_chat_id, platform = p_platform,
           window_expires_at = now() + interval '24 hours'
     where id = o.id returning * into o;
    update activation_chats set current_order = o.id, bad_attempts = 0, blocked_until = null
     where platform = p_platform and chat_id = p_chat_id;
    insert into bot_events(order_id, chat_id, kind, data)
      values (o.id, p_chat_id, 'channel_moved', jsonb_build_object('from', v_from, 'to', p_platform));
    return jsonb_build_object('result', 'moved', 'from', v_from, 'order', to_jsonb(o));
  end if;

  c.bad_attempts := c.bad_attempts + 1;
  update activation_chats
     set bad_attempts = case when c.bad_attempts >= 5 then 0 else c.bad_attempts end,
         blocked_until = case when c.bad_attempts >= 5 then now() + interval '1 hour' else null end
   where platform = p_platform and chat_id = p_chat_id;
  insert into bot_events(chat_id, kind, data)
    values (p_chat_id, 'code_invalid', jsonb_build_object('attempt', c.bad_attempts));
  return jsonb_build_object('result', 'invalid', 'attempts', c.bad_attempts,
                            'blocked', c.bad_attempts >= 5);
end $$;

-- /new: الطلب + رقم واتساب المتجر (للرابط wa.me)
create or replace function act_new_order(p_type text, p_created_by text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_code text; o activation_orders; i integer := 0;
begin
  if p_type not in ('month','two_months','year') then raise exception 'INVALID_TYPE'; end if;
  loop
    i := i + 1;
    v_code := 'JN-' || case when i <= 30 then lpad((floor(random() * 9000) + 1000)::int::text, 4, '0')
                            else lpad((floor(random() * 900000) + 100000)::int::text, 6, '0') end;
    begin
      insert into activation_orders(code, type, created_by) values (v_code, p_type, p_created_by)
        returning * into o;
      exit;
    exception when unique_violation then
      if i > 60 then raise exception 'NO_FREE_CODE'; end if;
    end;
  end loop;
  insert into bot_events(order_id, kind, data) values (o.id, 'order_created', jsonb_build_object('by', p_created_by));
  return to_jsonb(o) || jsonb_build_object('store_whatsapp',
    nullif((select value from store_settings where key = 'whatsapp_number'), ''));
end $$;

-- /stop ولا [غلق الطلب]: البوت يسكت نهائيا في هذي المحادثة
create or replace function act_close_order(p_code text, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o activation_orders;
begin
  update activation_orders set status = 'CLOSED', closed_reason = left(p_reason, 200), resume_status = null
   where code = regexp_replace(upper(regexp_replace(coalesce(p_code,''), '[^0-9A-Za-z]', '', 'g')), '^JN', 'JN-')
     and status <> 'CLOSED'
  returning * into o;
  if not found then return null; end if;
  update activation_chats set current_order = null where current_order = o.id;
  insert into bot_events(order_id, kind, data) values (o.id, 'closed', jsonb_build_object('reason', p_reason));
  return to_jsonb(o);
end $$;

-- طلب ما كملش في 48 ساعة يتغلق. يخدم مرة كل 10 دقايق على الأكثر
-- (ينادى مع كل update، فما يلزمش cron).
create or replace function act_sweep_stale(p_hours integer default 48)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_last timestamptz; v_out jsonb;
begin
  select nullif(value, '')::timestamptz into v_last from store_settings where key = 'activation_last_sweep';
  if v_last is not null and v_last > now() - interval '10 minutes' then return '[]'::jsonb; end if;
  insert into store_settings(key, value, is_public) values ('activation_last_sweep', now()::text, false)
    on conflict (key) do update set value = excluded.value, updated_at = now();

  with closed as (
    update activation_orders
       set status = 'CLOSED', closed_reason = 'ما كملش في ' || p_hours || ' ساعة', resume_status = null
     where status not in ('WAIT_CODE','DONE','CLOSED')
       and updated_at < now() - make_interval(hours => p_hours)
    returning *
  )
  select coalesce(jsonb_agg(to_jsonb(closed)), '[]'::jsonb) into v_out from closed;
  update activation_chats set current_order = null
   where current_order in (select (x->>'id')::uuid from jsonb_array_elements(v_out) x);
  insert into bot_events(order_id, kind, data)
    select (x->>'id')::uuid, 'closed', '{"reason":"stale"}'::jsonb from jsonb_array_elements(v_out) x;
  return v_out;
end $$;

-- ---------- الميديا ----------
drop function if exists act_media_set(text, text, text, text);
create or replace function act_media_set(p_platform text, p_slot text, p_kind text, p_file_id text,
                                         p_storage_path text default null, p_mime text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  insert into bot_media(slot, platform, kind, file_id, storage_path, mime)
    values (p_slot, p_platform, p_kind, p_file_id, p_storage_path, p_mime)
    on conflict (slot, platform) do update
      set kind = excluded.kind, file_id = excluded.file_id,
          storage_path = coalesce(excluded.storage_path, bot_media.storage_path),
          mime = coalesce(excluded.mime, bot_media.mime), updated_at = now();
  return jsonb_build_object('slot', p_slot, 'kind', p_kind);
end $$;

-- مع storage_path و updated_at: منهم يتعرف media_id لي مات ويتعاود رفعو
create or replace function act_media_all(p_platform text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(slot, jsonb_build_object(
           'kind', kind, 'file_id', file_id, 'voice_mode', voice_mode,
           'storage_path', storage_path, 'mime', mime, 'updated_at', updated_at)), '{}'::jsonb)
  from bot_media where platform = p_platform;
$$;

create or replace function act_media_delete(p_slot text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  select coalesce(jsonb_agg(distinct storage_path) filter (where storage_path is not null), '[]'::jsonb)
    into v from bot_media where slot = p_slot;
  delete from bot_media where slot = p_slot;
  return v;
end $$;

create or replace function act_media_list()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(m) order by m.slot, m.platform), '[]'::jsonb) from bot_media m;
$$;

-- ---------- المسودات ----------
create or replace function act_draft_add(p_admin text, p_kind text, p_tg_file_id text, p_mime text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare v integer;
begin
  delete from bot_media_drafts where created_at < now() - interval '1 day';
  insert into bot_media_drafts(admin_chat_id, kind, tg_file_id, mime) values (p_admin, p_kind, p_tg_file_id, p_mime)
    returning id into v;
  return v;
end $$;

create or replace function act_draft_get(p_id integer, p_admin text)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(d) from bot_media_drafts d where id = p_id and admin_chat_id = p_admin;
$$;

create or replace function act_draft_set_slot(p_id integer, p_admin text, p_slot text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d bot_media_drafts;
begin
  update bot_media_drafts set slot = p_slot where id = p_id and admin_chat_id = p_admin returning * into d;
  return case when d.id is null then null else to_jsonb(d) end;
end $$;

-- ياخذ المسودة ويمسحها في نفس الوقت: زوج ضغطات ما يحفظوش زوج مرات
create or replace function act_draft_take(p_id integer, p_admin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d bot_media_drafts;
begin
  delete from bot_media_drafts where id = p_id and admin_chat_id = p_admin returning * into d;
  return case when d.id is null then null else to_jsonb(d) end;
end $$;

-- ---------- مصروف الـAI ----------
create or replace function act_ai_spend_today()
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce((select usd from ai_spend where day = current_date), 0);
$$;

create or replace function act_ai_spend_add(p_usd numeric)
returns numeric language plpgsql security definer set search_path = public as $$
declare v numeric;
begin
  insert into ai_spend(day, usd, calls) values (current_date, greatest(p_usd, 0), 1)
    on conflict (day) do update set usd = ai_spend.usd + greatest(p_usd, 0), calls = ai_spend.calls + 1
    returning usd into v;
  return v;
end $$;

-- true مرة وحدة في النهار: تنبيه "الميزانية وصلت" ما يتعاودش مع كل ميساج
create or replace function act_ai_budget_alert()
returns boolean language plpgsql security definer set search_path = public as $$
begin
  insert into ai_spend(day) values (current_date) on conflict (day) do nothing;
  update ai_spend set alerted = true where day = current_date and not alerted;
  return found;
end $$;

-- ---------- ميساجات البوت المبعوثة (باش echo تاعها ما يوقفش البوت) ----------
create or replace function act_mark_sent(p_platform text, p_ids text[])
returns void language sql security definer set search_path = public as $$
  insert into activation_updates(platform, update_id)
    select p_platform || ':sent', x from unnest(p_ids) x
  on conflict do nothing;
$$;

create or replace function act_is_sent(p_platform text, p_id text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from activation_updates where platform = p_platform || ':sent' and update_id = p_id);
$$;

-- الطلب المفتوح لرقم (للـecho: مالك كتب من التطبيق)
create or replace function act_open_order_for(p_platform text, p_chat_id text)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(o) from activation_chats c join activation_orders o on o.id = c.current_order
   where c.platform = p_platform and c.chat_id = p_chat_id
     and o.status not in ('DONE','CLOSED') and o.customer_chat_id = p_chat_id;
$$;

-- /orders: CLOSED ما يبانش
create or replace function act_open_orders()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by (x->>'status') <> 'HUMAN', x->>'updated_at' desc), '[]'::jsonb)
  from (
    select to_jsonb(o) as x from activation_orders o
     where o.status not in ('DONE','CLOSED')
       and not (o.status = 'WAIT_CODE' and o.expires_at < now())
     order by o.updated_at desc limit 50
  ) s;
$$;

-- ---------- الصلاحيات ----------
do $$
declare f text;
begin
  foreach f in array array[
    'act_touch_chat(text,text,boolean,integer,integer)', 'act_claim_code(text,text,text)',
    'act_new_order(text,text)', 'act_close_order(text,text)', 'act_sweep_stale(integer)',
    'act_media_set(text,text,text,text,text,text)', 'act_media_all(text)', 'act_media_delete(text)', 'act_media_list()',
    'act_draft_add(text,text,text,text)', 'act_draft_get(integer,text)', 'act_draft_set_slot(integer,text,text)',
    'act_draft_take(integer,text)', 'act_ai_spend_today()', 'act_ai_spend_add(numeric)', 'act_ai_budget_alert()',
    'act_mark_sent(text,text[])', 'act_is_sent(text,text)', 'act_open_order_for(text,text)', 'act_open_orders()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
