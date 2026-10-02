-- bundle: bot
-- ============================================================
-- Janeiro Store — 037 البريد وطريقة الدفع في استمارة الضمان
--
-- الزبون يعمّر وثيقته من رابط البوت. صار يضيف:
--   - بريده (Gmail): الحساب الذي فُعِّل عليه الاشتراك. اختياري،
--     لأن ليس كل اشتراك على بريد (Snapchat+ مثلاً)، وإن كُتب
--     يُتحقَّق منه.
--   - طريقة الدفع: BaridiMob أو CCP أو Flexy. الاستمارة تطلبها.
-- ويظهران في الوثيقة وفي لوحة التحكم، ويُبحث بالبريد.
--
-- الوثائق الصادرة قبل هذا تبقى كما هي: العمودان فارغان فيها.
-- ============================================================

alter table bot_certificates add column if not exists email text;
alter table bot_certificates add column if not exists payment_method text;
do $$ begin
  alter table bot_certificates add constraint bot_certificates_payment_method_check
    check (payment_method is null or payment_method in ('baridimob', 'ccp', 'flexy'));
exception when duplicate_object then null; end $$;

-- التوقيع يتغيّر (معاملان جديدان)، فالقديم يُنزع أولاً حتى لا
-- يبقى نسختان بنفس الاسم يحتار بينهما النداء.
drop function if exists bot_engagement_claim(text, text, text, text, text);

create or replace function bot_engagement_claim(
  p_token     text,
  p_name      text,
  p_whatsapp  text,
  p_instagram text default null,
  p_ip        text default null,
  p_email     text default null,
  p_payment   text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tok bot_fill_tokens; v_cert bot_certificates;
  v_name text; v_phone text; v_insta text; v_start timestamptz;
  v_email text; v_pay text;
begin
  -- لا حدّ هنا: bot_claim_guard تُنادى قبلها في معاملة مستقلة،
  -- وإلا محا فشلُ هذه الدالة عدّادَ محاولاتها.
  select * into v_tok from bot_fill_tokens
   where token = btrim(coalesce(p_token, '')) for update;
  if not found or v_tok.certificate_id is null then raise exception 'LINK_NOT_FOUND'; end if;
  if v_tok.used_at is not null then raise exception 'LINK_USED'; end if;
  if v_tok.expires_at <= now() then raise exception 'LINK_EXPIRED'; end if;

  select * into v_cert from bot_certificates where id = v_tok.certificate_id for update;
  if v_cert.revoked_at is not null then raise exception 'CERTIFICATE_REVOKED'; end if;
  if v_cert.filled_at is not null then raise exception 'ALREADY_CLAIMED'; end if;

  -- مطلوب: وثيقة بلا صاحب لا تُثبت شيئاً
  v_name := btrim(coalesce(p_name, ''));
  if char_length(v_name) < 3 or char_length(v_name) > 80 then raise exception 'INVALID_NAME'; end if;

  -- مطلوب: به يُعرف الحساب المفعَّل
  v_insta := nullif(regexp_replace(btrim(coalesce(p_instagram, '')), '^@+', ''), '');
  if v_insta is null then raise exception 'INVALID_INSTAGRAM'; end if;
  if char_length(v_insta) > 40 then raise exception 'INVALID_INSTAGRAM'; end if;
  if v_insta !~ '^[A-Za-z0-9._]+$' then raise exception 'INVALID_INSTAGRAM'; end if;

  -- اختياري. وإن أُعطي فبصورة صحيحة: اختياريٌّ لا يعني مقبولاً
  -- على أيّ صورة، ورقمٌ مكسور أسوأ من لا رقم.
  if nullif(btrim(coalesce(p_whatsapp, '')), '') is null then
    v_phone := null;
  else
    v_phone := bot_dz_phone(p_whatsapp);
    if v_phone is null then raise exception 'INVALID_PHONE'; end if;
  end if;

  -- البريد: اختياري (ليس كل اشتراك على Gmail)، وإن أُعطي فصحيح
  v_email := nullif(lower(btrim(coalesce(p_email, ''))), '');
  if v_email is not null and (char_length(v_email) > 120
      or v_email !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$') then
    raise exception 'INVALID_EMAIL';
  end if;

  -- طريقة الدفع: الاستمارة تطلبها (required)، والقاعدة تقبل
  -- غيابها لأجل استمارة فُتحت قبل هذا التحديث — لكن ما يُرسل
  -- يجب أن يكون واحداً من الثلاث.
  v_pay := nullif(lower(btrim(coalesce(p_payment, ''))), '');
  if v_pay is not null and v_pay not in ('baridimob', 'ccp', 'flexy') then
    raise exception 'INVALID_PAYMENT';
  end if;

  -- وثيقة أُصدرت قبل 029 لا بداية لها؛ تُثبَّت الآن بالحساب
  -- الكامل (الأشهر والأيام والهدية) لا بالناقص الذي كان.
  v_start := coalesce(v_cert.starts_at, now());

  update bot_certificates
     set holder_name = v_name,
         whatsapp    = v_phone,
         instagram   = v_insta,
         email       = v_email,
         payment_method = v_pay,
         filled_at   = now(),
         starts_at   = v_start,
         ends_at     = coalesce(
                         v_cert.ends_at,
                         bot_engagement_expiry(v_start, v_cert.months,
                                               v_cert.bonus_days, v_cert.duration_days))
   where id = v_cert.id
  returning * into v_cert;

  update bot_fill_tokens set used_at = now() where token = v_tok.token;

  return jsonb_build_object(
    'code', v_cert.code, 'ref_code', v_cert.ref_code,
    'issued_by_telegram_id',
      (select telegram_id from bot_admins where id = v_cert.issued_by)
  );
end $$;

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
    'email',       v_cert.email,
    'payment_method', v_cert.payment_method,
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

create or replace function bot_engagement_admin_list(
  p_telegram_id bigint,
  p_query       text default null,
  p_status      text default null,
  p_platform    text default null,
  p_limit       int  default 100,
  p_offset      int  default 0,
  p_with_phone  boolean default false
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_admin  bot_admins;
  v_q      text;
  v_digits text;
  v_out    jsonb;
  v_total  int;
begin
  v_admin := bot_actor(p_telegram_id);
  v_q := nullif(btrim(coalesce(p_query, '')), '');
  p_limit  := greatest(1, least(coalesce(p_limit, 100), 500));
  p_offset := greatest(0, coalesce(p_offset, 0));

  -- أرقام البحث وحدها، وبثلاث خانات على الأقل. بلا هذا الشرط كان
  -- البحث بنصّ عربي يجرّد الحروف فيبقى '' فيصير شرط الهاتف
  -- like '%%' — فيُطابق كل زبون له رقم. كشفه الاختبار حين صار في
  -- القاعدة أكثر من صفّ واحد؛ بصفّ واحد كان يبدو سليماً.
  -- ويُطبَّع أولاً: الرقم يُخزَّن 213661445566، والناس تكتبه
  -- 0661445566. بلا التطبيع كان البحث بالشكل المحلي لا يجد صاحبه
  -- أبداً — وهو الشكل الوحيد الذي يقوله الزبون.
  v_digits := coalesce(
    bot_dz_phone(v_q),
    nullif(regexp_replace(coalesce(v_q, ''), '[^0-9]', '', 'g'), ''));
  if v_digits is not null and char_length(v_digits) < 3 then v_digits := null; end if;

  -- استعلام واحد: العدّ الكلي بنافذة، فلا يُكتب الترشيح مرتين
  -- ولا يتفرّق فرعاه عند أول تعديل.
  with matched as (
    select c.*, bot_engagement_status(c) as st,
           coalesce(a.display_name, a.tg_name, a.username, a.telegram_id::text) as seller
      from bot_certificates c
      left join bot_admins a on a.id = c.issued_by
     where (v_admin.role = 'owner' or c.issued_by = v_admin.id)
       and (p_platform is null or c.platform = p_platform)
       and (v_q is null
            or c.code     = upper(v_q)
            or c.ref_code = upper(v_q)
            or c.holder_name ilike '%' || v_q || '%'
            or c.instagram   ilike '%' || v_q || '%'
            or c.email       ilike '%' || v_q || '%'
            or (v_digits is not null and c.whatsapp like '%' || v_digits || '%'))
  ), filtered as (
    select *, count(*) over () as total
      from matched
     where p_status is null or st = p_status
  ), page as (
    select * from filtered order by created_at desc limit p_limit offset p_offset
  )
  select coalesce(max(total), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'code', code, 'ref_code', ref_code,
           'created_at', created_at,
           'holder_name', holder_name,
           -- الرقم بطلب صريح فقط: عمود لا نختاره أضمن من ترشيح نُنساه
           'whatsapp', case when p_with_phone then whatsapp else null end,
           'instagram', instagram, 'platform', platform,
           'email', email, 'payment_method', payment_method,
           'months', months, 'bonus_days', bonus_days,
           'starts_at', starts_at, 'ends_at', ends_at,
           'status', st, 'seller', seller,
           'days_left', case when ends_at is null then null
                             else (date_part('day', ends_at - now()))::int end,
           -- الشارة المطلوبة: أقل من 7 أيام وما زالت سارية
           'ending_soon', st = 'active' and ends_at is not null
                          and ends_at <= now() + interval '7 days'
         ) order by created_at desc), '[]'::jsonb)
    into v_total, v_out
    from page;

  return jsonb_build_object('total', v_total, 'rows', v_out);
end $$;

-- ============================================================
-- الصلاحيات — service_role وحده، كما في 021.
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
