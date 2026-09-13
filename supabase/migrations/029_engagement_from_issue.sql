-- bundle: bot
-- ============================================================
-- Janeiro Store — 029 الوثيقة تُولَد من البيعة
--
-- المرحلة 2. حتى الآن كانت الوثيقة تُبنى بفلو مستقلّ يسأل الأدمن
-- عن المنصة والمدة من الصفر، ولا يعرف أنه جاء من بيعة. وكل ما
-- يسأل عنه صار معروفاً في البيعة نفسها بعد 026–028. فهنا تُربط:
-- دالة واحدة تأخذ رقم البيعة وأيام الهدية، وتقرأ الباقي.
--
-- ومعها تصحيحان في حساب التواريخ:
--
-- 1. البداية = يوم البيع، لا يوم تعبئة الزبون.
--    كان starts_at يُثبَّت لحظة يملأ الزبون الاستمارة. فزبون
--    يملأها بعد خمسة أيام كان يربح خمسة أيام مجاناً، والوثيقة
--    تقول إن اشتراكه بدأ يوم لم يبدأ فيه. الاشتراك يبدأ حين
--    يسلّمه البائع.
--    ولأن «بلا بداية» كان هو علامة «لم يُعبَّأ بعد»، حلّ محلّها
--    عمود صريح: filled_at.
--
-- 2. المدة بالأيام كانت تضيع.
--    026 زادت duration_days، لكن bot_engagement_claim بقيت
--    تنادي bot_engagement_expiry بثلاث وسائط، فوثيقة مدتها 45
--    يوماً كانت تنتهي يوم صدورها. لم تصدر وثيقة كهذه بعدُ،
--    فالخطأ كامن لا واقع — ويسقط هنا قبل أن تصدر أوّلُها.
-- ============================================================

-- ------------------------------------------------------------
-- 1. علامة التعبئة
-- ------------------------------------------------------------
-- الافتراضي now(): وثائق 023 تولد كاملة (البائع كتب بيانات
-- الزبون بنفسه)، فتأخذه بلا أن تُلمس دالتها. ووثائق الالتزام
-- تمرّر null صراحةً لأن زبونها لم يعبّئ بعد.
alter table bot_certificates
  add column if not exists filled_at timestamptz;

alter table bot_certificates
  alter column filled_at set default now();

-- اليوم: بداية موجودة ⟺ مكتملة. فالنقل دقيق لا تقريبي.
update bot_certificates set filled_at = starts_at
 where filled_at is null and starts_at is not null;

create index if not exists idx_bot_cert_filled on bot_certificates(filled_at);

-- القيد القديم كان يربط اكتمال البيانات بوجود بداية. صار الربط
-- بالتعبئة، والبداية تُعرف من أول لحظة.
alter table bot_certificates drop constraint if exists bot_cert_claim_ok;
alter table bot_certificates add constraint bot_cert_claim_ok check (
  filled_at is not null
  or (holder_name is null and whatsapp is null and instagram is null)
);

-- ------------------------------------------------------------
-- 2. الحالة تُقرأ من التعبئة
-- ------------------------------------------------------------
create or replace function bot_engagement_status(c bot_certificates)
returns text
language sql immutable set search_path = public as $$
  select case
    when c.revoked_at is not null then 'revoked'
    when c.filled_at  is null     then 'pending'
    when c.ends_at is not null and c.ends_at <= now() then 'expired'
    else 'active' end;
$$;

-- ------------------------------------------------------------
-- 3. الوثيقة من البيعة
-- ------------------------------------------------------------
-- كل ما كان يُسأل عنه يُقرأ هنا: المنصة من البيعة، المدة من
-- الصنف، البداية من لحظة إتمام البيعة. ولا يبقى للأدمن إلا أيام
-- الهدية — وهي وحدها التي لا يعرفها أحد غيره.
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
  -- وثيقة التزام لبيعة لم تتمّ وعدٌ بما قد يُلغى بعد دقيقة
  if v_issue.status <> 'confirmed' then
    raise exception 'ISSUE_NOT_CONFIRMED:%', v_issue.status;
  end if;
  if exists (select 1 from bot_certificates where issue_id = p_issue_id) then
    raise exception 'CERTIFICATE_EXISTS';
  end if;

  select * into v_variant from bot_variants where id = v_issue.variant_id;
  select * into v_product from bot_products where id = v_variant.product_id;

  -- المنصة: لقطة البيعة لا قائمة المنتج. الوثيقة تقول للزبون
  -- منصةً بعينها، فإن لم تُحدَّد بعدُ فالبوت يسأل ثم يعيد النداء.
  if v_issue.platform is null then raise exception 'PLATFORM_REQUIRED'; end if;

  v_dur := bot_duration_to_engagement(v_variant.duration_value, v_variant.duration_unit);
  v_months := nullif(v_dur->>'months', '')::int;
  v_days   := nullif(v_dur->>'days',   '')::int;
  if v_months is null and v_days is null then raise exception 'DURATION_MISSING'; end if;

  v_bonus := coalesce(p_bonus_days, 0);
  if v_bonus < 0 or v_bonus > 90 then raise exception 'INVALID_BONUS'; end if;

  -- يوم البيع، لا يوم التعبئة ولا يوم النداء: بائع يصدر الوثيقة
  -- بعد ساعة من البيعة لا يزيح بدايتها ساعة.
  v_start := coalesce(v_issue.settled_at, now());

  insert into bot_certificates
    (code, ref_code, issue_id, platform, months, duration_days, bonus_days,
     starts_at, ends_at, issued_by, customer, filled_at)
  values
    (bot_engagement_code(), bot_engagement_ref(), p_issue_id, v_issue.platform,
     v_months, v_days, v_bonus,
     v_start, bot_engagement_expiry(v_start, v_months, v_bonus, v_days),
     v_admin.id, '[]'::jsonb, null)
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

-- ------------------------------------------------------------
-- 4. الفلو اليدوي يثبّت بدايته كذلك
-- ------------------------------------------------------------
-- /warranty للحالات الخاصة: بيعة قديمة، أو بيعة خارج البوت.
-- بدايتها لحظة إصدارها — وهي أقرب ما يُعرف عنها.
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
  if v_st.months   is null then raise exception 'MONTHS_MISSING';   end if;

  v_start := now();

  insert into bot_certificates
    (code, ref_code, platform, months, bonus_days, starts_at, ends_at,
     issued_by, customer, filled_at)
  values
    (bot_engagement_code(), bot_engagement_ref(), v_st.platform, v_st.months,
     coalesce(v_st.bonus_days, 0), v_start,
     bot_engagement_expiry(v_start, v_st.months, coalesce(v_st.bonus_days, 0), null),
     v_admin.id, '[]'::jsonb, null)
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
    'bonus_days', v_cert.bonus_days,
    'starts_at', v_cert.starts_at, 'ends_at', v_cert.ends_at,
    'expires_at', now() + make_interval(hours => coalesce(p_hours, 72))
  );
end $$;

-- ------------------------------------------------------------
-- 5. التعبئة: بيانات الزبون وحدها
-- ------------------------------------------------------------
-- لم تعد تحسب تواريخ. التواريخ ثُبّتت يوم البيع، ولا يملك الزبون
-- أن يزيحها بأن يتأخّر في التعبئة.
create or replace function bot_engagement_claim(
  p_token     text,
  p_name      text,
  p_whatsapp  text,
  p_instagram text default null,
  p_ip        text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tok bot_fill_tokens; v_cert bot_certificates;
  v_name text; v_phone text; v_insta text; v_start timestamptz;
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

  v_name := btrim(coalesce(p_name, ''));
  if char_length(v_name) < 3 or char_length(v_name) > 80 then raise exception 'INVALID_NAME'; end if;

  v_phone := bot_dz_phone(p_whatsapp);
  if v_phone is null then raise exception 'INVALID_PHONE'; end if;

  v_insta := nullif(regexp_replace(btrim(coalesce(p_instagram, '')), '^@+', ''), '');
  if v_insta is not null then
    if char_length(v_insta) > 40 then raise exception 'INVALID_INSTAGRAM'; end if;
    if v_insta !~ '^[A-Za-z0-9._]+$' then raise exception 'INVALID_INSTAGRAM'; end if;
  end if;

  -- وثيقة أُصدرت قبل 029 لا بداية لها؛ تُثبَّت الآن بالحساب
  -- الكامل (الأشهر والأيام والهدية) لا بالناقص الذي كان.
  v_start := coalesce(v_cert.starts_at, now());

  update bot_certificates
     set holder_name = v_name,
         whatsapp    = v_phone,
         instagram   = v_insta,
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

-- ------------------------------------------------------------
-- 6. القراءة والإبطال يتبعان علامة التعبئة
-- ------------------------------------------------------------
-- الوثيقة لا تُعرض قبل أن يعبّئ صاحبها: بلا اسم لا تُثبت شيئاً،
-- ولو صارت تواريخها معروفة.
create or replace function bot_engagement_public(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_cert bot_certificates;
begin
  if p_code is null or char_length(btrim(p_code)) < 8 then
    raise exception 'CERTIFICATE_NOT_FOUND';
  end if;
  -- الحدّ في bot_read_guard، لنفس سبب bot_claim_guard أعلاه
  select * into v_cert from bot_certificates where code = upper(btrim(p_code));
  if not found then raise exception 'CERTIFICATE_NOT_FOUND'; end if;
  if v_cert.filled_at is null then raise exception 'CERTIFICATE_PENDING'; end if;

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
    'days_left',   case when v_cert.ends_at is null then null
                        else greatest(0, (date_part('day', v_cert.ends_at - now()))::int) end
  );
end $$;

create or replace function bot_engagement_verify(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_cert bot_certificates;
begin
  select * into v_cert from bot_certificates
   where code = upper(btrim(coalesce(p_code, '')));
  if not found or v_cert.filled_at is null then
    return jsonb_build_object('found', false);
  end if;

  return jsonb_build_object(
    'found',      true,
    'code',       v_cert.code,
    'platform',   v_cert.platform,
    'ends_at',    v_cert.ends_at,
    'status',     bot_engagement_status(v_cert),
    -- الاسم مختصر: يكفي صاحبه ليتعرّف، ولا يكشفه لغيره
    'holder_hint', case when v_cert.holder_name is null then null
                        else left(v_cert.holder_name, 1) || '***' end
  );
end $$;

create or replace function bot_engagement_relink(
  p_telegram_id bigint, p_code text, p_hours int default 72
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin bot_admins; v_cert bot_certificates; v_token text;
begin
  v_admin := bot_actor(p_telegram_id);
  select * into v_cert from bot_certificates
   where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then raise exception 'CERTIFICATE_NOT_FOUND'; end if;
  if v_admin.role <> 'owner' and v_cert.issued_by is distinct from v_admin.id then
    raise exception 'NOT_YOUR_ISSUE';
  end if;
  if v_cert.revoked_at is not null then raise exception 'CERTIFICATE_REVOKED'; end if;
  if v_cert.filled_at is not null then raise exception 'ALREADY_CLAIMED'; end if;

  delete from bot_fill_tokens where certificate_id = v_cert.id;
  v_token := replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '');
  insert into bot_fill_tokens (token, certificate_id, created_by, expires_at)
  values (v_token, v_cert.id, v_admin.id,
          now() + make_interval(hours => greatest(1, least(coalesce(p_hours, 72), 720))));

  return jsonb_build_object(
    'code', v_cert.code, 'token', v_token,
    'expires_at', now() + make_interval(hours => coalesce(p_hours, 72))
  );
end $$;

-- ------------------------------------------------------------
-- 7. حالة البيعة بالنسبة للوثيقة
-- ------------------------------------------------------------
-- يسألها البوت بعد التأكيد ليعرف: أيسأل عن المنصة؟ عن المدة؟ أم
-- يكفيه أن يسأل عن الهدية ثم يولّد الرابط؟
create or replace function bot_issue_engagement(p_telegram_id bigint, p_issue_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_admin bot_admins; v_issue bot_issues;
  v_variant bot_variants; v_product bot_products;
  v_dur jsonb; v_cert bot_certificates;
begin
  v_admin := bot_actor(p_telegram_id);

  select * into v_issue from bot_issues where id = p_issue_id;
  if not found then raise exception 'ISSUE_NOT_FOUND'; end if;
  if v_issue.admin_id <> v_admin.id and v_admin.role <> 'owner' then
    raise exception 'NOT_YOUR_ISSUE';
  end if;

  select * into v_variant from bot_variants where id = v_issue.variant_id;
  select * into v_product from bot_products where id = v_variant.product_id;
  v_dur := bot_duration_to_engagement(v_variant.duration_value, v_variant.duration_unit);
  select * into v_cert from bot_certificates where issue_id = p_issue_id;

  return jsonb_build_object(
    'issue_id',     p_issue_id,
    'status',       v_issue.status,
    'product_name', v_product.name,
    'variant_name', v_variant.name,
    'platform',     v_issue.platform,
    'platforms',    bot_product_platforms_list(p_telegram_id, v_product.id),
    'months',       v_dur->'months',
    'days',         v_dur->'days',
    'needs_platform', v_issue.platform is null,
    'needs_duration', v_dur->'months' = 'null'::jsonb and v_dur->'days' = 'null'::jsonb,
    'has_certificate', v_cert.id is not null,
    'certificate_code', v_cert.code,
    -- ما ستكون عليه لو أُصدرت الآن بلا هدية: معاينة قبل السؤال
    'projected_start', coalesce(v_issue.settled_at, now()),
    'projected_end',   case
      when v_dur->'months' = 'null'::jsonb and v_dur->'days' = 'null'::jsonb then null
      else bot_engagement_expiry(
             coalesce(v_issue.settled_at, now()),
             nullif(v_dur->>'months','')::int, 0, nullif(v_dur->>'days','')::int)
      end
  );
end $$;

-- ============================================================
-- 8. الصلاحيات — service_role وحده، كما في 021.
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
