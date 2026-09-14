-- bundle: bot
-- ============================================================
-- Janeiro Store — 031 شروط التغطية: للمالك، ولكل خدمة
--
-- كانت النقاط الخمس مكتوبة في i18n.ts: تبديلها يحتاج نشر
-- الدالة، وهي واحدة لكل الخدمات. وسناب ليس نتفليكس: ما يُغطّى
-- في هذه لا يُغطّى في تلك.
--
-- وفخُّ التخزين وحده: لو قُرئت الشروط من الجدول وقت العرض،
-- لتبدّلت الوثائق التي في أيدي الزبائن بأثر رجعي. زبون التُزم
-- له بشروط، ثم يفتح رابطه فيجد غيرها. وهذه وثيقة التزام — ما
-- وُعد به يبقى.
--
-- فالشروط تُلقَّط على الوثيقة يوم صدورها:
--   الوثيقة القديمة تبقى على وعدها.
--   والجديدة تأخذ الجديد.
--   وما صدر قبل هذه الهجرة (terms فارغ) يقرأ الحيّ ثم المدمج
--   في الكود — فلا وثيقة بلا شروط.
-- ============================================================

-- ------------------------------------------------------------
-- 1. الجدول
-- ------------------------------------------------------------
-- platform فارغ = الشروط العامة، تُستعمل لكل خدمة لم تُفرَد
-- بشروطها. ولغة بلا شروط تسقط إلى العامة ثم إلى المدمج، فلا
-- يُجبَر المالك على كتابة الثلاث دفعةً.
create table if not exists bot_terms (
  id         uuid primary key default gen_random_uuid(),
  platform   text references bot_platforms(name) on update cascade on delete cascade,
  lang       text not null check (lang in ('ar','fr','en')),
  sort_order integer not null,
  body       text not null check (char_length(btrim(body)) between 3 and 400),
  updated_at timestamptz not null default now(),
  unique (platform, lang, sort_order)
);
create index if not exists idx_bot_terms_lookup on bot_terms(platform, lang, sort_order);

alter table bot_terms enable row level security;
revoke all on bot_terms from anon, authenticated;

-- اللقطة على الوثيقة: {"ar":[...],"fr":[...],"en":[...]}
alter table bot_certificates
  add column if not exists terms jsonb;

-- ------------------------------------------------------------
-- 2. القراءة
-- ------------------------------------------------------------
-- الخاصة بالخدمة، وإلّا العامة، وإلّا فارغ — والفراغ يعني
-- «استعمل المدمج في الكود»، لا «بلا شروط».
create or replace function bot_terms_for(p_platform text, p_lang text)
returns text[]
language sql stable set search_path = public as $$
  select coalesce(
    (select array_agg(body order by sort_order) from bot_terms
      where platform = p_platform and lang = p_lang),
    (select array_agg(body order by sort_order) from bot_terms
      where platform is null and lang = p_lang)
  );
$$;

-- اللقطة كاملة باللغات الثلاث، كما تُكتب على الوثيقة.
create or replace function bot_terms_snapshot(p_platform text)
returns jsonb
language sql stable set search_path = public as $$
  select coalesce(jsonb_object_agg(l.lang, to_jsonb(t.lines))
                    filter (where t.lines is not null), '{}'::jsonb)
    from (values ('ar'),('fr'),('en')) as l(lang)
    cross join lateral (select bot_terms_for(p_platform, l.lang) as lines) t;
$$;

create or replace function bot_terms_list(
  p_telegram_id bigint, p_platform text default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_plat text;
begin
  perform bot_owner(p_telegram_id);
  v_plat := nullif(btrim(coalesce(p_platform, '')), '');

  return jsonb_build_object(
    'platform', v_plat,
    -- الخاصة بهذه الخدمة وحدها، بلا سقوط: ليرى المالك ما كتبه هو
    'own', (select coalesce(jsonb_object_agg(x.lang, x.lines), '{}'::jsonb)
              from (select lang, to_jsonb(array_agg(body order by sort_order)) as lines
                      from bot_terms
                     where platform is not distinct from v_plat
                     group by lang) x),
    -- وما سيُطبَّق فعلاً بعد السقوط
    'effective', bot_terms_snapshot(v_plat),
    -- والخدمات التي أُفردت بشروط
    'overridden', (select coalesce(jsonb_agg(distinct platform), '[]'::jsonb)
                     from bot_terms where platform is not null)
  );
end $$;

-- ------------------------------------------------------------
-- 3. الكتابة — للمالك وحده
-- ------------------------------------------------------------
-- استبدال كامل لا إضافة: الشروط تُقرأ كمجموعة، وتحرير سطر
-- بعينه من تليجرام أبواب أخطاء لا تُغلق.
create or replace function bot_set_terms(
  p_telegram_id bigint, p_platform text, p_lang text, p_lines text[]
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_plat text; v_line text; v_n int := 0;
begin
  perform bot_owner(p_telegram_id);

  if p_lang not in ('ar','fr','en') then raise exception 'INVALID_LANG'; end if;
  v_plat := nullif(btrim(coalesce(p_platform, '')), '');
  if v_plat is not null
     and not exists (select 1 from bot_platforms where name = v_plat) then
    raise exception 'PLATFORM_NOT_FOUND';
  end if;

  delete from bot_terms
   where platform is not distinct from v_plat and lang = p_lang;

  foreach v_line in array coalesce(p_lines, array[]::text[]) loop
    continue when btrim(v_line) = '';
    if char_length(btrim(v_line)) > 400 then raise exception 'LINE_TOO_LONG'; end if;
    v_n := v_n + 1;
    if v_n > 12 then raise exception 'TOO_MANY_LINES'; end if;
    insert into bot_terms (platform, lang, sort_order, body)
    values (v_plat, p_lang, v_n * 10, btrim(v_line));
  end loop;

  return jsonb_build_object(
    'platform', v_plat, 'lang', p_lang, 'count', v_n,
    'effective', bot_terms_snapshot(v_plat)
  );
end $$;

-- ------------------------------------------------------------
-- 4. اللقطة عند الإصدار
-- ------------------------------------------------------------
create or replace function bot_engagement_from_issue(
  p_telegram_id bigint,
  p_issue_id    uuid,
  p_bonus_days  int default 0,
  p_hours       int default 72
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin   bot_admins;
  v_issue   bot_issues;
  v_variant bot_variants;
  v_product bot_products;
  v_dur     jsonb;
  v_months  int;
  v_days    int;
  v_bonus   int;
  v_start   timestamptz;
  v_cert    bot_certificates;
  v_token   text;
begin
  v_admin := bot_actor(p_telegram_id);

  select * into v_issue from bot_issues where id = p_issue_id for update;
  if not found then raise exception 'ISSUE_NOT_FOUND'; end if;
  if v_issue.admin_id <> v_admin.id and v_admin.role <> 'owner' then
    raise exception 'NOT_YOUR_ISSUE';
  end if;
  if v_issue.status <> 'confirmed' then
    raise exception 'ISSUE_NOT_CONFIRMED:%', v_issue.status;
  end if;
  if exists (select 1 from bot_certificates where issue_id = p_issue_id) then
    raise exception 'CERTIFICATE_EXISTS';
  end if;

  select * into v_variant from bot_variants where id = v_issue.variant_id;
  select * into v_product from bot_products where id = v_variant.product_id;

  if v_issue.platform is null then raise exception 'PLATFORM_REQUIRED'; end if;

  v_dur := bot_duration_to_engagement(v_variant.duration_value, v_variant.duration_unit);
  v_months := nullif(v_dur->>'months', '')::int;
  v_days   := nullif(v_dur->>'days',   '')::int;
  if v_months is null and v_days is null then raise exception 'DURATION_MISSING'; end if;

  v_bonus := coalesce(p_bonus_days, 0);
  if v_bonus < 0 or v_bonus > 90 then raise exception 'INVALID_BONUS'; end if;

  v_start := coalesce(v_issue.settled_at, now());

  insert into bot_certificates
    (code, ref_code, issue_id, platform, months, duration_days, bonus_days,
     starts_at, ends_at, issued_by, customer, filled_at, terms)
  values
    (bot_engagement_code(), bot_engagement_ref(), p_issue_id, v_issue.platform,
     v_months, v_days, v_bonus,
     v_start, bot_engagement_expiry(v_start, v_months, v_bonus, v_days),
     v_admin.id, '[]'::jsonb, null,
     bot_terms_snapshot(v_issue.platform))
  returning * into v_cert;

  v_token := replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '');

  insert into bot_fill_tokens (token, certificate_id, created_by, expires_at)
  values (v_token, v_cert.id, v_admin.id,
          now() + make_interval(hours => greatest(1, least(coalesce(p_hours, 72), 720))));

  return jsonb_build_object(
    'code',        v_cert.code,
    'ref_code',    v_cert.ref_code,
    'token',       v_token,
    'issue_id',    p_issue_id,
    'platform',    v_cert.platform,
    'product_name', v_product.name,
    'variant_name', v_variant.name,
    'months',      v_cert.months,
    'duration_days', v_cert.duration_days,
    'bonus_days',  v_cert.bonus_days,
    'starts_at',   v_cert.starts_at,
    'ends_at',     v_cert.ends_at,
    'expires_at',  now() + make_interval(hours => coalesce(p_hours, 72))
  );
end $$;

create or replace function bot_engagement_confirm(
  p_telegram_id bigint, p_hours int default 72
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin bot_admins; v_st bot_wizard_state;
  v_cert bot_certificates; v_token text; v_start timestamptz;
begin
  v_admin := bot_actor(p_telegram_id);
  select * into v_st from bot_wizard_state where admin_id = v_admin.id;
  if not found then raise exception 'WIZARD_NOT_STARTED'; end if;
  if v_st.platform is null then raise exception 'PLATFORM_MISSING'; end if;
  if v_st.months is null and v_st.duration_days is null then
    raise exception 'MONTHS_MISSING';
  end if;

  v_start := now();

  insert into bot_certificates
    (code, ref_code, platform, months, duration_days, bonus_days,
     starts_at, ends_at, issued_by, customer, filled_at, terms)
  values
    (bot_engagement_code(), bot_engagement_ref(), v_st.platform,
     v_st.months, v_st.duration_days, coalesce(v_st.bonus_days, 0), v_start,
     bot_engagement_expiry(v_start, v_st.months,
                           coalesce(v_st.bonus_days, 0), v_st.duration_days),
     v_admin.id, '[]'::jsonb, null, bot_terms_snapshot(v_st.platform))
  returning * into v_cert;

  v_token := replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '');

  insert into bot_fill_tokens (token, certificate_id, created_by, expires_at)
  values (v_token, v_cert.id, v_admin.id,
          now() + make_interval(hours => greatest(1, least(coalesce(p_hours, 72), 720))));

  delete from bot_wizard_state where admin_id = v_admin.id;

  return jsonb_build_object(
    'code', v_cert.code, 'ref_code', v_cert.ref_code, 'token', v_token,
    'platform', v_cert.platform, 'months', v_cert.months,
    'duration_days', v_cert.duration_days, 'bonus_days', v_cert.bonus_days,
    'starts_at', v_cert.starts_at, 'ends_at', v_cert.ends_at,
    'expires_at', now() + make_interval(hours => coalesce(p_hours, 72))
  );
end $$;

-- ------------------------------------------------------------
-- 5. القراءة العامة تحمل شروطها
-- ------------------------------------------------------------
-- لقطة الوثيقة أولاً. وإن كانت فارغة (وثيقة صدرت قبل 031)
-- فالحيّ، وإن لم يكن فالمدمج في الكود — تقرّره الصفحة.
create or replace function bot_engagement_public(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_cert bot_certificates; v_terms jsonb;
begin
  if p_code is null or char_length(btrim(p_code)) < 8 then
    raise exception 'CERTIFICATE_NOT_FOUND';
  end if;
  select * into v_cert from bot_certificates where code = upper(btrim(p_code));
  if not found then raise exception 'CERTIFICATE_NOT_FOUND'; end if;
  if v_cert.filled_at is null then raise exception 'CERTIFICATE_PENDING'; end if;

  v_terms := case
    when v_cert.terms is not null and v_cert.terms <> '{}'::jsonb then v_cert.terms
    else bot_terms_snapshot(v_cert.platform) end;

  return jsonb_build_object(
    'code',        v_cert.code,
    'ref_code',    v_cert.ref_code,
    'holder_name', v_cert.holder_name,
    'instagram',   v_cert.instagram,
    'platform',    v_cert.platform,
    'months',      v_cert.months,
    'duration_days', v_cert.duration_days,
    'bonus_days',  v_cert.bonus_days,
    'starts_at',   v_cert.starts_at,
    'ends_at',     v_cert.ends_at,
    'status',      bot_engagement_status(v_cert),
    'terms',       v_terms,
    'days_left',   case when v_cert.ends_at is null then null
                        else greatest(0, (date_part('day', v_cert.ends_at - now()))::int) end
  );
end $$;

-- ------------------------------------------------------------
-- 6. أمر البوت بالرمز النصّي
-- ------------------------------------------------------------
create or replace function bot_cmd_terms(
  p_telegram_id bigint, p_platform text, p_lang text, p_lines text[]
) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform bot_owner(p_telegram_id);
  -- «-» تعني الشروط العامة: أسهل من خانة فارغة في سطر أمر
  return bot_set_terms(p_telegram_id,
    case when btrim(coalesce(p_platform, '')) in ('', '-') then null else p_platform end,
    p_lang, p_lines);
end $$;

-- ============================================================
-- 7. الصلاحيات — service_role وحده، كما في 021.
-- ============================================================
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
