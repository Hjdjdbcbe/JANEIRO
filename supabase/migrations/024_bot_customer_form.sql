-- ============================================================
-- Janeiro Store — 024 الزبون يعبّي بنفسه، ووثيقة يحفظها
--
--   البائع يؤكّد البيعة
--     -> يضغط «🔗 يعبّيها الزبون» فيأخذ رابطاً
--     -> يرسله للزبون في سناب أو واتساب أو أي مكان
--     -> الزبون يفتحه، يكتب رقمه ويوزره بنفسه
--     -> تظهر له الوثيقة فوراً: متى بدأ اشتراكه ومتى ينتهي،
--        وتحتها كل قنوات تواصلكم — يحفظها أو يطبعها PDF
--
-- الرابط يحمل رمزاً عشوائياً (256 بت) هو وحده مفتاحه، يُستعمل مرة
-- واحدة وينتهي بعد مدة. لا حساب ولا تسجيل دخول على الزبون.
-- ============================================================

-- ------------------------------------------------------------
-- 1. قنوات التواصل التي تظهر أسفل الوثيقة
-- ------------------------------------------------------------
create table if not exists bot_contacts (
  id         uuid primary key default gen_random_uuid(),
  label      text not null check (char_length(label) between 1 and 40),
  value      text not null check (char_length(value) between 1 and 120),
  url        text check (url is null or url ~ '^https?://'),
  icon       text check (char_length(icon) <= 8),
  is_active  boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (label)
);

-- ------------------------------------------------------------
-- 2. رابط التعبئة
-- ------------------------------------------------------------
create table if not exists bot_fill_tokens (
  token      text primary key check (char_length(token) >= 32),
  issue_id   uuid not null unique references bot_issues(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at    timestamptz
);
create index if not exists idx_bot_fill_expires on bot_fill_tokens(expires_at);

alter table bot_contacts    enable row level security;
alter table bot_fill_tokens enable row level security;
revoke all on bot_contacts, bot_fill_tokens from anon, authenticated;

-- ------------------------------------------------------------
-- 3. توليد الرابط — للبائع صاحب البيعة
-- ------------------------------------------------------------
create or replace function bot_fill_link(
  p_telegram_id bigint, p_issue_id uuid, p_days int default 7
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin bot_admins; v_issue bot_issues; v_tok bot_fill_tokens;
begin
  v_admin := bot_actor(p_telegram_id);

  select * into v_issue from bot_issues where id = p_issue_id;
  if not found then raise exception 'ISSUE_NOT_FOUND'; end if;
  if v_issue.admin_id <> v_admin.id and v_admin.role <> 'owner' then
    raise exception 'NOT_YOUR_ISSUE';
  end if;
  if v_issue.status <> 'confirmed' then
    raise exception 'ISSUE_NOT_CONFIRMED:%', v_issue.status;
  end if;
  if exists (select 1 from bot_certificates where issue_id = p_issue_id) then
    raise exception 'CERTIFICATE_EXISTS:%',
      (select code from bot_certificates where issue_id = p_issue_id);
  end if;

  -- رابط واحد لكل بيعة: طلبه مرتين يعيد نفس الرابط ويمدّد صلاحيته،
  -- فلا ينتشر رابطان لبيعة واحدة.
  insert into bot_fill_tokens (token, issue_id, expires_at)
  values (
    replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
    p_issue_id,
    now() + make_interval(days => greatest(1, least(coalesce(p_days, 7), 60)))
  )
  on conflict (issue_id) do update
    set expires_at = excluded.expires_at
  returning * into v_tok;

  return jsonb_build_object(
    'token', v_tok.token, 'expires_at', v_tok.expires_at,
    'issue_id', p_issue_id
  );
end $$;

-- ------------------------------------------------------------
-- 4. ما يراه الزبون في الاستمارة
-- ------------------------------------------------------------
-- بلا هوية: الرمز نفسه هو المفتاح. ولا يعيد كود البطاقة أبداً —
-- الزبون أخذه من البائع، ولا شأن لهذه الصفحة به.
create or replace function bot_fill_form(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tok bot_fill_tokens; v_issue bot_issues;
  v_variant bot_variants; v_product bot_products;
begin
  select * into v_tok from bot_fill_tokens where token = btrim(coalesce(p_token, ''));
  if not found then raise exception 'LINK_NOT_FOUND'; end if;
  if v_tok.used_at is not null then raise exception 'LINK_USED'; end if;
  if v_tok.expires_at <= now() then raise exception 'LINK_EXPIRED'; end if;

  select * into v_issue   from bot_issues   where id = v_tok.issue_id;
  select * into v_variant from bot_variants where id = v_issue.variant_id;
  select * into v_product from bot_products where id = v_variant.product_id;

  return jsonb_build_object(
    'product_name', v_product.name,
    'variant_name', v_variant.name,
    'fields', coalesce((
      select jsonb_agg(jsonb_build_object(
               'label', f.label, 'is_required', f.is_required) order by f.sort_order, f.label)
        from bot_fields f where f.product_id = v_product.id
    ), '[]'::jsonb)
  );
end $$;

-- ------------------------------------------------------------
-- 5. الزبون يرسل بياناته -> تصدر الوثيقة
-- ------------------------------------------------------------
create or replace function bot_fill_submit(p_token text, p_values jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tok bot_fill_tokens; v_issue bot_issues; v_seller bot_admins;
  v_res jsonb;
begin
  -- القفل قبل القراءة: ضغطتان على «إرسال» لا تنتجان وثيقتين.
  select * into v_tok from bot_fill_tokens
   where token = btrim(coalesce(p_token, '')) for update;
  if not found then raise exception 'LINK_NOT_FOUND'; end if;
  if v_tok.used_at is not null then raise exception 'LINK_USED'; end if;
  if v_tok.expires_at <= now() then raise exception 'LINK_EXPIRED'; end if;

  select * into v_issue  from bot_issues where id = v_tok.issue_id;
  select * into v_seller from bot_admins where id = v_issue.admin_id;

  -- يُصدرها باسم البائع صاحب البيعة: هو من باع، والزبون مجرد من
  -- عبّأ البيانات. فتبقى كل الفحوص في bot_issue_certificate كما هي.
  v_res := bot_issue_certificate(v_seller.telegram_id, v_tok.issue_id, p_values);

  update bot_fill_tokens set used_at = now() where token = v_tok.token;

  return v_res || jsonb_build_object('seller_telegram_id', v_seller.telegram_id);
end $$;

-- ------------------------------------------------------------
-- 6. الوثيقة كما يراها الزبون — بالرمز وحده، بلا حساب
-- ------------------------------------------------------------
-- الرمز 56 بت عشوائية، وهو نفسه بطاقة الدخول: نفس نموذج الثقة
-- الذي يعتمده أي رابط فاتورة. لا يعيد كود البطاقة ولا اسم البائع.
create or replace function bot_public_certificate(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cert bot_certificates; v_issue bot_issues;
  v_variant bot_variants; v_product bot_products;
begin
  if p_code is null or char_length(btrim(p_code)) < 8 then
    raise exception 'CERTIFICATE_NOT_FOUND';
  end if;
  select * into v_cert from bot_certificates where code = upper(btrim(p_code));
  if not found then raise exception 'CERTIFICATE_NOT_FOUND'; end if;

  select * into v_issue   from bot_issues   where id = v_cert.issue_id;
  select * into v_variant from bot_variants where id = v_issue.variant_id;
  select * into v_product from bot_products where id = v_variant.product_id;

  return jsonb_build_object(
    'code', v_cert.code,
    'product_name', v_product.name,
    'variant_name', v_variant.name,
    'customer', v_cert.customer,
    'starts_at', v_cert.starts_at,
    'ends_at', v_cert.ends_at,
    'expired', v_cert.ends_at is not null and v_cert.ends_at <= now(),
    'days_left', case when v_cert.ends_at is null then null
                      else greatest(0, (date_part('day', v_cert.ends_at - now()))::int) end,
    'issued_at', v_cert.created_at,
    'contacts', coalesce((
      select jsonb_agg(jsonb_build_object(
               'label', label, 'value', value, 'url', url, 'icon', icon)
             order by sort_order, label)
        from bot_contacts where is_active), '[]'::jsonb)
  );
end $$;

-- ------------------------------------------------------------
-- 6-ب. «من ينتهي اشتراكه اليوم؟»
-- ------------------------------------------------------------
-- p_days = 0 تعني اليوم نفسه: كل ما ينتهي قبل منتصف الليل. كانت
-- الدالة تبدأ من يوم واحد، فلم يكن لهذا السؤال جواب مباشر.
create or replace function bot_expiring(p_telegram_id bigint, p_days int default 7)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_admin bot_admins; v_until timestamptz; v_out jsonb;
begin
  v_admin := bot_actor(p_telegram_id);
  p_days := greatest(0, least(coalesce(p_days, 7), 90));

  v_until := case when p_days = 0
                  then date_trunc('day', now()) + interval '1 day'
                  else now() + make_interval(days => p_days) end;

  select coalesce(jsonb_agg(r.row order by r.ends_at), '[]'::jsonb) into v_out
  from (
    select c.ends_at,
      jsonb_build_object(
        'code', c.code,
        'product_name', pr.name,
        'variant_name', va.name,
        'customer', c.customer,
        'ends_at', c.ends_at,
        'days_left', greatest(0, (date_part('day', c.ends_at - now()))::int),
        'seller', coalesce(a.display_name, a.tg_name, a.username, a.telegram_id::text)
      ) as row
      from bot_certificates c
      join bot_issues   i  on i.id = c.issue_id
      join bot_variants va on va.id = i.variant_id
      join bot_products pr on pr.id = va.product_id
      join bot_admins   a  on a.id = i.admin_id
     where c.ends_at is not null
       and c.ends_at > now()
       and c.ends_at <= v_until
       and (v_admin.role = 'owner' or i.admin_id = v_admin.id)
     order by c.ends_at
     limit 50
  ) r;

  return v_out;
end $$;

-- ------------------------------------------------------------
-- 7. إدارة قنوات التواصل — للمالك
-- ------------------------------------------------------------
create or replace function bot_add_contact(
  p_telegram_id bigint, p_label text, p_value text,
  p_url text default null, p_icon text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_next int; v_row bot_contacts;
begin
  perform bot_owner(p_telegram_id);
  p_label := btrim(coalesce(p_label, ''));
  p_value := btrim(coalesce(p_value, ''));
  p_url   := nullif(btrim(coalesce(p_url, '')), '');
  if p_label = '' or char_length(p_label) > 40 then raise exception 'INVALID_LABEL'; end if;
  if p_value = '' or char_length(p_value) > 120 then raise exception 'INVALID_VALUE'; end if;
  if p_url is not null and p_url !~ '^https?://' then raise exception 'INVALID_URL'; end if;

  select coalesce(max(sort_order), 0) + 10 into v_next from bot_contacts;

  -- نفس التسمية تُحدَّث لا تُكرَّر: تغيير رقم الهاتف لا يترك القديم.
  insert into bot_contacts (label, value, url, icon, sort_order)
  values (p_label, p_value, p_url, nullif(btrim(coalesce(p_icon, '')), ''), v_next)
  on conflict (label) do update
    set value = excluded.value, url = excluded.url,
        icon = coalesce(excluded.icon, bot_contacts.icon), is_active = true
  returning * into v_row;

  return jsonb_build_object('label', v_row.label, 'value', v_row.value, 'url', v_row.url);
end $$;

create or replace function bot_remove_contact(p_telegram_id bigint, p_label text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  perform bot_owner(p_telegram_id);
  delete from bot_contacts where label = btrim(coalesce(p_label, ''));
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'CONTACT_NOT_FOUND'; end if;
  return jsonb_build_object('removed', p_label);
end $$;

create or replace function bot_list_contacts(p_telegram_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  perform bot_actor(p_telegram_id);
  select coalesce(jsonb_agg(jsonb_build_object(
           'label', label, 'value', value, 'url', url, 'icon', icon, 'is_active', is_active)
         order by sort_order, label), '[]'::jsonb) into v_out from bot_contacts;
  return v_out;
end $$;

-- ------------------------------------------------------------
-- 8. الصلاحيات — service_role وحده، كما في 021.
-- ------------------------------------------------------------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like 'bot\_%'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
