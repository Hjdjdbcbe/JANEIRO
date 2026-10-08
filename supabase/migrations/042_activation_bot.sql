-- bundle: bot
-- ============================================================
-- Janeiro Store — 042 بوت تفعيل Snapchat+ (activation bot)
--
-- بوت ثاني، للزبائن، منفصل عن بوت المخزون (021). البيع والدفع
-- يبقاو عند المالك؛ البوت يدير التفعيل برك:
--
--   المالك يولّد كود طلب (/new month)  ->  الزبون يبعثو للبوت
--     -> صورة Snap+  -> رابط رصيد Apple (كود واحد من المخزون)
--     -> خطوات التفعيل -> (شهرين/سنة: تبديل الخطة + صورة تأكيد)
--     -> الميساج الأخير
--
-- أكواد الرصيد هي نفسها بطاقات بوت المخزون (bot_cards). ما
-- نبنيوش مخزون ثاني: نزيدو المبلغ بالروبية على المدّة
-- (bot_variants.amount_inr)، وكل بطاقة تحت مدّة عندها مبلغ تولّي
-- صالحة للتفعيل. البطاقة لي تتعطى لطلب تولّي 'sold' وتتربط بيه.
--
-- كل الجداول RLS بلا policy: الدخول الوحيد هو الدوال أسفله بمفتاح
-- service_role من دالة Vercel (api/activation-bot.js).
-- ============================================================

-- ---------- المبلغ على المدّة ----------
alter table bot_variants add column if not exists amount_inr integer;
do $$ begin
  alter table bot_variants add constraint bot_variants_amount_inr_ok
    check (amount_inr is null or amount_inr between 1 and 100000);
exception when duplicate_object then null; end $$;

-- ---------- الطلبات ----------
create table if not exists activation_orders (
  id                 uuid primary key default gen_random_uuid(),
  code               text not null unique check (code ~ '^JN-[0-9]{4,6}$'),
  type               text not null check (type in ('month','two_months','year')),
  status             text not null default 'WAIT_CODE' check (status in (
                       'WAIT_CODE','WAIT_SNAP_SCREENSHOT','LINK_SENT','WAIT_ACTIVATION_DONE',
                       'WAIT_PLAN_CHANGE','WAIT_CONFIRM_SCREENSHOT','DONE','HUMAN')),
  -- الحالة لي يرجعلها الطلب بعد /release
  resume_status      text,
  customer_chat_id   text,
  platform           text check (platform in ('telegram','whatsapp')),
  gift_card_id       uuid unique references bot_cards(id) on delete restrict,
  gift_amount_inr    integer,
  no_balance_retries integer not null default 0,
  -- عدادات ومسارات المشاكل (صورة مش واضحة، شاشة الرصيد…) — يكتبها الكود
  ctx                jsonb not null default '{}'::jsonb,
  ui_language        text check (ui_language in ('fr','en','ar')),
  human_reason       text,
  created_by         text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  bound_at           timestamptz,
  -- كود ما تستعملش في 48 ساعة يموت
  expires_at         timestamptz not null default now() + interval '48 hours'
);
create index if not exists idx_activation_orders_chat on activation_orders(platform, customer_chat_id, updated_at desc);
create index if not exists idx_activation_orders_status on activation_orders(status, updated_at desc);
drop trigger if exists trg_activation_orders_updated on activation_orders;
create trigger trg_activation_orders_updated before update on activation_orders
  for each row execute function set_updated_at();

-- ---------- الكليان (محاولات غالطة، حدّ الميساجات، الطلب الحالي) ----------
create table if not exists activation_chats (
  platform        text not null,
  chat_id         text not null,
  current_order   uuid references activation_orders(id) on delete set null,
  bad_attempts    integer not null default 0,
  blocked_until   timestamptz,
  rl_window       timestamptz not null default now(),
  rl_count        integer not null default 0,
  rl_media        integer not null default 0,
  rl_warned       boolean not null default false,
  created_at      timestamptz not null default now(),
  primary key (platform, chat_id)
);

-- ---------- فيديوهات، صور وفوكالات المالك ----------
create table if not exists bot_media (
  slot       text not null check (slot ~ '^[a-z0-9_]{2,60}$'),
  platform   text not null default 'telegram',
  kind       text check (kind in ('video','photo','voice')),
  file_id    text,
  -- للفوكالات: text / voice / both. فارغ = الافتراضي (both إذا كاين فوكال)
  voice_mode text check (voice_mode in ('text','voice','both')),
  updated_at timestamptz not null default now(),
  primary key (slot, platform)
);

-- ---------- ملف المشاكل ----------
create table if not exists bot_problems (
  id             serial primary key,
  -- مفتاح ثابت للحالات لي عندها منطق في الكود (no_balance…)، فارغ للي يزيدها المالك
  key            text unique,
  title          text not null check (char_length(title) between 1 and 200),
  symptoms       text not null default '',
  solution_text  text not null check (char_length(solution_text) between 1 and 2000),
  applies_to     text[] not null default '{}',
  escalate_after integer,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now()
);

-- ---------- السجل ----------
create table if not exists bot_events (
  id         bigserial primary key,
  order_id   uuid references activation_orders(id) on delete set null,
  chat_id    text,
  kind       text not null,
  data       jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists idx_bot_events_order on bot_events(order_id, id);

-- ---------- تيليغرام يعاود يبعث نفس الـupdate إذا ما جاوبناش ----------
create table if not exists activation_updates (
  platform   text not null,
  update_id  text not null,
  created_at timestamptz not null default now(),
  primary key (platform, update_id)
);

-- ---------- رسائل المالك: أي رسالة يرد عليها، لأي طلب ----------
create table if not exists activation_admin_msgs (
  admin_chat_id text not null,
  message_id    bigint not null,
  order_id      uuid not null references activation_orders(id) on delete cascade,
  created_at    timestamptz not null default now(),
  primary key (admin_chat_id, message_id)
);

alter table activation_orders     enable row level security;
alter table activation_chats      enable row level security;
alter table bot_media             enable row level security;
alter table bot_problems          enable row level security;
alter table bot_events            enable row level security;
alter table activation_updates    enable row level security;
alter table activation_admin_msgs enable row level security;
revoke all on activation_orders, activation_chats, bot_media, bot_problems, bot_events,
              activation_updates, activation_admin_msgs from anon, authenticated;

-- وضع المراجعة شاعل في البداية (القسم 8.3)
insert into store_settings (key, value, is_public) values ('activation_review_mode', 'on', false)
  on conflict (key) do nothing;

-- ---------- ملف المشاكل الأولي (القسم 9) ----------
insert into bot_problems (key, title, symptoms, solution_text, applies_to, escalate_after) values
 ('no_subscriptions', 'ما لقيتش Subscriptions',
  'الكليان ما لقاش Subscriptions في App Store',
  'كي تضغط على البروفيل في App Store، اضغط على اسمك الفوق، تتحل صفحة فيها Subscriptions.',
  '{WAIT_PLAN_CHANGE,WAIT_CONFIRM_SCREENSHOT,WAIT_ACTIVATION_DONE}', null),
 ('redeem_screen', 'شاشة سوداء فيها كود وتحتها Redeem',
  'بعد الضغط على الرابط طلعت شاشة سوداء فيها كود وزر Redeem',
  'عادي. اخرج منها برك وروح دير خطوات التفعيل.',
  '{WAIT_ACTIVATION_DONE}', null),
 ('continue_button', 'صورة فيها Continue بالأزرق',
  'بعد الرابط طلعت صفحة فيها زر Continue أزرق',
  'اضغط Continue، ومن بعد ارجع اضغط على الرابط من جديد، ابقى فيه 20 ثانية واخرج.',
  '{WAIT_ACTIVATION_DONE}', null),
 ('balance_shown', 'صورة يبان فيها الرصيد',
  'الكليان بعث صورة فيها الرصيد في App Store',
  'مليح، الرصيد تزاد، روح فعّل.',
  '{WAIT_ACTIVATION_DONE}', null),
 ('no_balance', 'ما كاينش رصيد',
  'وهو يفعل: ما كاينش رصيد، ولا يطلب طريقة دفع',
  'ارجع اضغط على الرابط، ابقى فيه 20 ثانية واخرج، وعاود التفعيل.',
  '{WAIT_ACTIVATION_DONE}', 2),
 ('wrong_store', 'راك في الستور الجزائري مش الهندي',
  'وهو يفعل: يقولو راك في الستور الجزائري، ولا السعر رجع بالدينار',
  'طفي التيليفون وعاود شعلو، ومن بعد عاود خطوات التفعيل.',
  '{WAIT_ACTIVATION_DONE}', 1),
 ('wrong_annual_plan', 'اختار 12-Month Plan بدل Annual Plan',
  'صورة التأكيد فيها ₹299 (12-Month Plan)',
  'ارجع لـ See All Plans واختار Annual Plan ₹199.',
  '{WAIT_PLAN_CHANGE,WAIT_CONFIRM_SCREENSHOT}', 1)
on conflict (key) do nothing;

-- ============================================================
-- الدوال
-- ============================================================

-- الحد الأدنى لي لازم يغطيه الرصيد (القسم 12)
create or replace function act_required_inr(p_type text)
returns integer language sql immutable as $$
  select case p_type when 'month' then 99 when 'two_months' then 98 when 'year' then 199 end;
$$;

-- update جديد ولا مكرر؟
create or replace function act_seen_update(p_platform text, p_update_id text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  insert into activation_updates(platform, update_id) values (p_platform, p_update_id);
  delete from activation_updates where created_at < now() - interval '3 days';
  return true;
exception when unique_violation then
  return false;
end $$;

-- كل ميساج من كليان يمر من هنا: حدّ الميساجات + الطلب الحالي + وضع المراجعة
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
    select * into o from activation_orders where id = c.current_order;
  end if;

  return jsonb_build_object(
    'allowed', v_allowed, 'warn', v_warn,
    'blocked', c.blocked_until is not null and c.blocked_until > now(),
    'order', case when o.id is null then null else to_jsonb(o) end,
    'review_mode', coalesce((select value from store_settings where key = 'activation_review_mode'), 'on'));
end $$;

-- الكليان بعث كود طلب
create or replace function act_claim_code(p_platform text, p_chat_id text, p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c activation_chats; o activation_orders; v_code text;
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

  if found and o.customer_chat_id = p_chat_id and o.platform = p_platform then
    update activation_chats set current_order = o.id, bad_attempts = 0, blocked_until = null
     where platform = p_platform and chat_id = p_chat_id;
    return jsonb_build_object('result', 'resumed', 'order', to_jsonb(o));
  end if;

  if found and o.customer_chat_id is null and o.status = 'WAIT_CODE' and o.expires_at > now() then
    update activation_orders
       set customer_chat_id = p_chat_id, platform = p_platform, bound_at = now(),
           status = 'WAIT_SNAP_SCREENSHOT'
     where id = o.id returning * into o;
    update activation_chats set current_order = o.id, bad_attempts = 0, blocked_until = null
     where platform = p_platform and chat_id = p_chat_id;
    insert into bot_events(order_id, chat_id, kind, data) values (o.id, p_chat_id, 'code_claimed', '{}');
    return jsonb_build_object('result', 'ok', 'order', to_jsonb(o));
  end if;

  -- غالط، مستعمل من واحد آخر، ولا مات
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

-- /new month — يولّد كود طلب فريد
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
  return to_jsonb(o);
end $$;

create or replace function act_get_order(p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare o activation_orders;
begin
  select * into o from activation_orders
   where code = regexp_replace(upper(regexp_replace(coalesce(p_code,''), '[^0-9A-Za-z]', '', 'g')), '^JN', 'JN-');
  if not found then return null; end if;
  return to_jsonb(o) || jsonb_build_object('gift_code', (select code from bot_cards where id = o.gift_card_id));
end $$;

create or replace function act_get_order_by_id(p_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(o) from activation_orders o where id = p_id;
$$;

-- الطلبات المفتوحة: لي تستنى مالك الأوّلين
create or replace function act_open_orders()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by (x->>'status') <> 'HUMAN', x->>'updated_at' desc), '[]'::jsonb)
  from (
    select to_jsonb(o) as x from activation_orders o
     where o.status not in ('DONE')
       and not (o.status = 'WAIT_CODE' and o.expires_at < now())
     order by o.updated_at desc limit 50
  ) s;
$$;

-- تحديث الطلب. p_from: إذا تعطى، ما يتبدلش إلا إذا الحالة مازالت هي هي
create or replace function act_update_order(p_id uuid, p_patch jsonb, p_from text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o activation_orders; k text;
begin
  for k in select jsonb_object_keys(coalesce(p_patch, '{}'::jsonb)) loop
    if k not in ('status','resume_status','ctx','ctx_merge','ui_language','human_reason','no_balance_retries') then
      raise exception 'UNKNOWN_FIELD:%', k;
    end if;
  end loop;
  select * into o from activation_orders where id = p_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  if p_from is not null and o.status <> p_from then
    return jsonb_build_object('updated', false, 'order', to_jsonb(o));
  end if;
  update activation_orders set
    status        = coalesce(p_patch->>'status', status),
    resume_status = case when p_patch ? 'resume_status' then p_patch->>'resume_status' else resume_status end,
    ctx           = case when p_patch ? 'ctx' then p_patch->'ctx'
                         when p_patch ? 'ctx_merge' then ctx || (p_patch->'ctx_merge')
                         else ctx end,
    ui_language   = coalesce(p_patch->>'ui_language', ui_language),
    human_reason  = case when p_patch ? 'human_reason' then p_patch->>'human_reason' else human_reason end,
    no_balance_retries = coalesce((p_patch->>'no_balance_retries')::int, no_balance_retries)
   where id = p_id returning * into o;
  return jsonb_build_object('updated', true, 'order', to_jsonb(o));
end $$;

-- قرار المراجعة يتاخذ مرة وحدة: زوج أدمين يضغطو في نفس الوقت، واحد برك يربح
create or replace function act_take_review(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o activation_orders; v jsonb;
begin
  select * into o from activation_orders where id = p_id for update;
  v := o.ctx -> 'review_pending';
  if v is null or v = 'null'::jsonb then return null; end if;
  update activation_orders set ctx = ctx || '{"review_pending": null}'::jsonb where id = p_id returning * into o;
  return jsonb_build_object('pending', v, 'order', to_jsonb(o));
end $$;

-- كود رصيد واحد لكل طلب: أصغر كود متوفر يغطي ثمن الاشتراك.
-- إذا الطلب عندو كود ديجا، يرجع نفسو — ما يتعطاش كود ثاني أبدا.
create or replace function act_assign_gift(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o activation_orders; c record; v_need integer;
begin
  select * into o from activation_orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;

  if o.gift_card_id is not null then
    return jsonb_build_object('code', (select code from bot_cards where id = o.gift_card_id),
                              'amount_inr', o.gift_amount_inr, 'reused', true);
  end if;

  v_need := act_required_inr(o.type);
  select bc.id, bc.code, v.amount_inr into c
    from bot_cards bc
    join bot_variants v on v.id = bc.variant_id
   where bc.status = 'available' and v.is_active and v.amount_inr is not null and v.amount_inr >= v_need
   order by v.amount_inr, bc.seq
   limit 1
   for update of bc skip locked;
  if not found then
    insert into bot_events(order_id, kind, data) values (o.id, 'no_stock', jsonb_build_object('need', v_need));
    return jsonb_build_object('error', 'NO_STOCK', 'need', v_need);
  end if;

  update bot_cards set status = 'sold', sold_at = now(),
         note = left('تفعيل ' || o.code, 300)
   where id = c.id;
  update activation_orders set gift_card_id = c.id, gift_amount_inr = c.amount_inr where id = o.id;
  insert into bot_events(order_id, kind, data)
    values (o.id, 'gift_assigned', jsonb_build_object('amount_inr', c.amount_inr));
  return jsonb_build_object('code', c.code, 'amount_inr', c.amount_inr, 'reused', false);
end $$;

-- المخزون الصالح للتفعيل، حسب المبلغ
create or replace function act_gift_stock()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('amount_inr', amount_inr, 'available', n) order by amount_inr), '[]'::jsonb)
  from (select v.amount_inr, count(*) filter (where bc.status = 'available') as n
          from bot_variants v left join bot_cards bc on bc.variant_id = v.id
         where v.amount_inr is not null and v.is_active
         group by v.amount_inr) s;
$$;

-- /giftamount <منتج> <مدّة> <مبلغ>: يعلّم مدّة من بوت المخزون كرصيد بالروبية
create or replace function act_set_gift_amount(p_product text, p_variant text, p_amount integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v bot_variants;
begin
  update bot_variants bv set amount_inr = p_amount
    from bot_products p
   where p.id = bv.product_id and p.code = lower(p_product) and bv.code = lower(p_variant)
  returning bv.* into v;
  if not found then raise exception 'VARIANT_NOT_FOUND'; end if;
  return jsonb_build_object('variant', v.name, 'amount_inr', v.amount_inr);
end $$;

-- ---------- الميديا ----------
create or replace function act_media_all(p_platform text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(slot, jsonb_build_object('kind', kind, 'file_id', file_id, 'voice_mode', voice_mode)), '{}'::jsonb)
  from bot_media where platform = p_platform;
$$;

create or replace function act_media_set(p_platform text, p_slot text, p_kind text, p_file_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  insert into bot_media(slot, platform, kind, file_id) values (p_slot, p_platform, p_kind, p_file_id)
    on conflict (slot, platform) do update set kind = excluded.kind, file_id = excluded.file_id, updated_at = now();
  return jsonb_build_object('slot', p_slot, 'kind', p_kind);
end $$;

create or replace function act_voice_mode_set(p_platform text, p_slot text, p_mode text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  insert into bot_media(slot, platform, voice_mode) values (p_slot, p_platform, p_mode)
    on conflict (slot, platform) do update set voice_mode = excluded.voice_mode, updated_at = now();
  return jsonb_build_object('slot', p_slot, 'voice_mode', p_mode);
end $$;

-- ---------- ملف المشاكل ----------
create or replace function act_problems()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(p) order by p.id), '[]'::jsonb) from bot_problems p where p.is_active;
$$;

create or replace function act_problem_add(p_title text, p_symptoms text, p_solution text,
                                           p_applies_to text[] default '{}', p_escalate_after integer default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p bot_problems;
begin
  insert into bot_problems(title, symptoms, solution_text, applies_to, escalate_after)
    values (btrim(p_title), coalesce(btrim(p_symptoms), ''), btrim(p_solution), coalesce(p_applies_to, '{}'), p_escalate_after)
    returning * into p;
  return to_jsonb(p);
end $$;

create or replace function act_problem_del(p_id integer)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  update bot_problems set is_active = false where id = p_id and key is null;
  return found;
end $$;

-- ---------- الإعدادات ----------
create or replace function act_set_review(p_on boolean)
returns text language plpgsql security definer set search_path = public as $$
begin
  insert into store_settings(key, value, is_public) values ('activation_review_mode', case when p_on then 'on' else 'off' end, false)
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return case when p_on then 'on' else 'off' end;
end $$;

-- ---------- السجل ----------
create or replace function act_log(p_order_id uuid, p_chat_id text, p_kind text, p_data jsonb default '{}')
returns void language sql security definer set search_path = public as $$
  insert into bot_events(order_id, chat_id, kind, data) values (p_order_id, p_chat_id, p_kind, coalesce(p_data, '{}'));
$$;

-- ---------- رسائل المالك ----------
create or replace function act_admin_msg_add(p_admin_chat_id text, p_message_id bigint, p_order_id uuid)
returns void language sql security definer set search_path = public as $$
  insert into activation_admin_msgs(admin_chat_id, message_id, order_id) values (p_admin_chat_id, p_message_id, p_order_id)
    on conflict do nothing;
$$;

create or replace function act_admin_msg_order(p_admin_chat_id text, p_message_id bigint)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(o) from activation_admin_msgs m join activation_orders o on o.id = m.order_id
   where m.admin_chat_id = p_admin_chat_id and m.message_id = p_message_id;
$$;

-- ---------- الصلاحيات: service_role برك ----------
do $$
declare f text;
begin
  foreach f in array array[
    'act_seen_update(text,text)', 'act_touch_chat(text,text,boolean,integer,integer)',
    'act_claim_code(text,text,text)', 'act_new_order(text,text)', 'act_get_order(text)',
    'act_get_order_by_id(uuid)', 'act_open_orders()', 'act_update_order(uuid,jsonb,text)', 'act_take_review(uuid)',
    'act_assign_gift(uuid)', 'act_gift_stock()', 'act_set_gift_amount(text,text,integer)',
    'act_media_all(text)', 'act_media_set(text,text,text,text)', 'act_voice_mode_set(text,text,text)',
    'act_problems()', 'act_problem_add(text,text,text,text[],integer)', 'act_problem_del(integer)',
    'act_set_review(boolean)', 'act_log(uuid,text,text,jsonb)',
    'act_admin_msg_add(text,bigint,uuid)', 'act_admin_msg_order(text,bigint)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
