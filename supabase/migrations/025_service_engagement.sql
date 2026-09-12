-- bundle: bot
-- ============================================================
-- Janeiro Store — 025 وثيقة التزام الخدمة
--
-- المرحلة أ: الداتا والحساب.
--
-- الفرق عن 023: تلك الوثيقة مشدودة إلى بيعة بطاقة من المخزون
-- (issue_id not null). وهذه تُصدر لعملية يحدّد فيها الأدمن المنصة
-- والمدة بيده — Snapchat Plus سنة + 7 أيام هدية — بلا بطاقة ولا
-- مخزون. فالمنصة والمدة وأيام الهدية تُحمل على الوثيقة نفسها.
--
-- أيام الهدية قيمة لكل عملية لا خاصية للباقة: المزوّد يعطي أسبوعاً
-- مجاناً مرة ولا يعطيه أخرى. تُخزَّن كما أُدخلت، ولا تُستنبط من
-- المدة أبداً.
--
-- كل تاريخ يُحسب هنا، في القاعدة، بتوقيت Africa/Algiers. لا
-- الفورم ولا المتصفّح يُقدّم تاريخاً ولا يُقبل منه.
-- ============================================================

-- ------------------------------------------------------------
-- 1. الوثيقة تتحرّر من المخزون
-- ------------------------------------------------------------
alter table bot_certificates
  alter column issue_id drop not null;

alter table bot_certificates
  add column if not exists platform    text,
  add column if not exists months      integer,
  add column if not exists bonus_days  integer not null default 0,
  add column if not exists ref_code    text,
  add column if not exists revoked_at  timestamptz,
  add column if not exists revoked_by  uuid references bot_admins(id) on delete set null,
  add column if not exists issued_by   uuid references bot_admins(id) on delete set null;

do $$ begin
  alter table bot_certificates add constraint bot_cert_months_ok
    check (months is null or months between 1 and 120);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table bot_certificates add constraint bot_cert_bonus_ok
    check (bonus_days between 0 and 90);
exception when duplicate_object then null; end $$;

-- وثيقة بلا بيعة مخزون يجب أن تحمل منصتها ومدتها، وإلا فهي بلا
-- موضوع. ووثيقة من بيعة تأخذهما من المنتج والمدة.
do $$ begin
  alter table bot_certificates add constraint bot_cert_subject_ok
    check (issue_id is not null or (platform is not null and months is not null));
exception when duplicate_object then null; end $$;

create unique index if not exists uq_bot_cert_ref on bot_certificates(ref_code)
  where ref_code is not null;
create index if not exists idx_bot_cert_platform on bot_certificates(platform);
create index if not exists idx_bot_cert_revoked  on bot_certificates(revoked_at);

-- ورابط التعبئة كذلك: قد يسبق وجود أي بيعة
alter table bot_fill_tokens
  alter column issue_id drop not null;
alter table bot_fill_tokens
  add column if not exists certificate_id uuid references bot_certificates(id) on delete cascade,
  add column if not exists created_by     uuid references bot_admins(id) on delete set null;
create unique index if not exists uq_bot_fill_cert on bot_fill_tokens(certificate_id)
  where certificate_id is not null;

do $$ begin
  alter table bot_fill_tokens add constraint bot_fill_target_ok
    check (issue_id is not null or certificate_id is not null);
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------
-- 2. المنصات
-- ------------------------------------------------------------
-- طلبتَ array في ملف كونفيغ. جعلتها جدولاً لأن الملف داخل الدالة
-- يحتاج إعادة نشر عند كل تعديل، والهدف كان «نزيد ونحيّ بلا ما
-- نلمس الكود» — وهذا يحقّقه أكثر: تزيد منصة بأمر من البوت،
-- وتظهر في الأزرار فوراً. القائمة الثمانية مزروعة أدناه.
create table if not exists bot_platforms (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique check (char_length(name) between 1 and 60),
  is_active  boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

insert into bot_platforms (name, sort_order) values
  ('Snapchat Plus',    10),
  ('Gemini Pro',       20),
  ('Discord Nitro',    30),
  ('Spotify',          40),
  ('Netflix',          50),
  ('YouTube Premium',  60),
  ('Canva Pro',        70),
  ('ChatGPT Plus',     80)
on conflict (name) do nothing;

-- ------------------------------------------------------------
-- 3. حالة الفلو متعدّد الخطوات
-- ------------------------------------------------------------
-- الحيلة القديمة (الحالة داخل نصّ رسالة الردّ الإجباري) تكفي سؤالاً
-- واحداً. أربع خطوات مع «تعديل» ومعاينة لا تتحمّلها: صفّ واحد لكل
-- أدمن، يُستبدل عند بداية فلو جديد ويُمحى عند التأكيد.
create table if not exists bot_wizard_state (
  admin_id     uuid primary key references bot_admins(id) on delete cascade,
  platform     text,
  months       integer check (months is null or months between 1 and 120),
  bonus_days   integer check (bonus_days is null or bonus_days between 0 and 90),
  awaiting     text check (awaiting in ('platform','months','bonus','bonus_manual','platform_manual','preview')),
  message_id   bigint,
  updated_at   timestamptz not null default now()
);
drop trigger if exists trg_bot_wizard_updated on bot_wizard_state;
create trigger trg_bot_wizard_updated before update on bot_wizard_state
  for each row execute function set_updated_at();

alter table bot_platforms    enable row level security;
alter table bot_wizard_state enable row level security;
revoke all on bot_platforms, bot_wizard_state from anon, authenticated;

-- ------------------------------------------------------------
-- 4. الأكواد
-- ------------------------------------------------------------
-- JW- للتحقق (10 خانات hex = 40 بت)، JS- للمرجعية (8 = 32 بت).
-- كلاهما من gen_random_uuid() لا gen_random_bytes(): الثانية تحتاج
-- pgcrypto، وعلى Supabase المستضاف تسكن schema اسمه extensions لا
-- يراه search_path = public — وهو ما أوقع get_certificate سابقاً.
create or replace function bot_engagement_code()
returns text language plpgsql volatile set search_path = public as $$
declare candidate text;
begin
  for attempt in 1..20 loop
    candidate := 'JW-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    if not exists (select 1 from bot_certificates where code = candidate) then
      return candidate;
    end if;
  end loop;
  raise exception 'CERTIFICATE_CODE_GENERATION_FAILED';
end $$;

create or replace function bot_engagement_ref()
returns text language plpgsql volatile set search_path = public as $$
declare candidate text;
begin
  for attempt in 1..20 loop
    candidate := 'JS-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    if not exists (select 1 from bot_certificates where ref_code = candidate) then
      return candidate;
    end if;
  end loop;
  raise exception 'REF_CODE_GENERATION_FAILED';
end $$;

-- ------------------------------------------------------------
-- 5. الحساب — نقطة واحدة، بتوقيت الجزائر
-- ------------------------------------------------------------
-- expiryDate = addDays(addMonths(start, months), bonusDays)
--
-- الحساب يجري على الوقت المحلي ثم يُعاد إلى timestamptz، فيثبت
-- وقت اليوم بعد سنة كما كان (وتُحترم أي إزاحة صيفية لو استُحدثت؛
-- الجزائر UTC+1 طوال العام اليوم).
--
-- الأشهر قبل الأيام داخل interval واحد — وهذا سلوك PostgreSQL
-- المضمون: 31 يناير + '1 month 1 day' = 1 مارس، نفس ما يعطيه
-- التنفيذ على خطوتين. مفحوص لا مفترض.
create or replace function bot_engagement_expiry(
  p_start timestamptz, p_months int, p_bonus_days int
) returns timestamptz
language sql immutable set search_path = public as $$
  select (((p_start at time zone 'Africa/Algiers')
           + make_interval(months => coalesce(p_months, 0),
                           days   => coalesce(p_bonus_days, 0)))
          at time zone 'Africa/Algiers');
$$;

-- ------------------------------------------------------------
-- 6. صاحب الاشتراك — أعمدة لا JSON
-- ------------------------------------------------------------
-- الحقول الثلاثة مثبّتة في المواصفة (الاسم، واتساب، انستغرام)،
-- فأعمدة لا مصفوفة: الداشبورد يبحث ويفلتر ويصدّر CSV عليها،
-- و«لا تُكشف الواتساب» يصير عموداً لا نختاره — أضمن من ترشيح
-- عنصر داخل JSON في كل استعلام ونسيانه مرة واحدة.
alter table bot_certificates
  add column if not exists holder_name text,
  add column if not exists whatsapp    text,
  add column if not exists instagram   text;

-- وثيقة لم تُعمَّر بعد لا تملك تاريخ بداية: البداية هي لحظة التعبئة.
-- والـdefault يُسقط كذلك، وإلا وُلدت المعلّقة ببداية بلا تعبئة —
-- وهو ما أمسكه bot_cert_claim_ok أدناه عند أول إدخال حقيقي.
alter table bot_certificates alter column starts_at drop not null;
alter table bot_certificates alter column starts_at drop default;

-- المعلّقة = بلا تاريخ بداية. وهذا يصف الفيتشرين معاً: وثيقة 023
-- تولد مكتملة ببداية (لا مرحلة تعليق فيها)، ووثيقة الالتزام تولد
-- بلا بداية ثم تُثبَّت لحظة تعبئة الزبون.
--
-- كان هنا عمود claimed_at منفصل، وقيدٌ يشترط اقترانه ببداية —
-- فكسر bot_issue_certificate في 023 التي تُدرج بداية بلا claimed_at.
-- العمود كان زائداً عن starts_at، وحذفه أزال التناقض من أصله.
-- كشفته مجموعة اختبارات 023 عند دمج المجموعتين.
do $$ begin
  alter table bot_certificates add constraint bot_cert_claim_ok check (
    starts_at is not null
    or (ends_at is null and holder_name is null and whatsapp is null and instagram is null)
  );
exception when duplicate_object then null; end $$;

create index if not exists idx_bot_cert_holder on bot_certificates(holder_name);
create index if not exists idx_bot_cert_whatsapp on bot_certificates(whatsapp);
create index if not exists idx_bot_cert_starts on bot_certificates(starts_at);

-- ------------------------------------------------------------
-- 7. رقم جزائري — تطبيع سيرفر-سايد
-- ------------------------------------------------------------
-- قائمة بذاتها لا تعتمد على normalize_dz_phone في 006: من يركّب
-- البوت وحده لا يملك تلك الهجرة.
-- تقبل 0550…، +213550…، 213550…، 00213550… وبينها مسافات أو
-- شرطات. المحمول الجزائري 05/06/07 وحده؛ الثابت يُرفض.
create or replace function bot_dz_phone(p_raw text)
returns text
language plpgsql immutable set search_path = public as $$
declare v text;
begin
  v := regexp_replace(coalesce(p_raw, ''), '[^0-9+]', '', 'g');
  v := regexp_replace(v, '^\+', '', '');
  v := regexp_replace(v, '^00', '', '');
  if v ~ '^213[567][0-9]{8}$' then return v; end if;
  if v ~ '^0[567][0-9]{8}$'   then return '213' || substr(v, 2); end if;
  return null;
end $$;

-- ------------------------------------------------------------
-- 8. حدّ المحاولات — قائم بذاته كذلك
-- ------------------------------------------------------------
create table if not exists bot_rate_limits (
  bucket   text not null,
  action   text not null,
  hits     integer not null default 1,
  window_start timestamptz not null default now(),
  primary key (bucket, action)
);
alter table bot_rate_limits enable row level security;
revoke all on bot_rate_limits from anon, authenticated;

-- الحدّ يجب أن يُنادى في معاملة مستقلة، لا من داخل الدالة التي
-- يحرسها. السبب: إن رفعت تلك الدالة استثناءً (اسم قصير، رقم غير
-- صالح، رمز مجهول) رجعت معاملتها بالكامل — ومعها زيادة العدّاد.
-- فيصير الطَّرق بمدخلات خاطئة مجانياً، وهو بالضبط ما نريد حدّه.
-- لذلك تناديه الدالة الحدّية (Edge Function) أولاً، ثم تنادي العمل.
-- كشفه الاختبار؛ لم يكن ظاهراً في القراءة.
create or replace function bot_claim_guard(p_token text, p_ip text default null)
returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  if not bot_rate_limit('tok:' || coalesce(btrim(p_token), ''), 'claim', 10, interval '10 minutes')
  then return false; end if;
  if p_ip is not null and btrim(p_ip) <> ''
     and not bot_rate_limit('ip:' || btrim(p_ip), 'claim', 20, interval '10 minutes')
  then return false; end if;
  return true;
end $$;

create or replace function bot_read_guard(p_code text, p_ip text default null)
returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  if not bot_rate_limit('code:' || upper(btrim(coalesce(p_code, ''))), 'read', 60, interval '10 minutes')
  then return false; end if;
  if p_ip is not null and btrim(p_ip) <> ''
     and not bot_rate_limit('ip:' || btrim(p_ip), 'read', 240, interval '10 minutes')
  then return false; end if;
  return true;
end $$;

create or replace function bot_rate_limit(
  p_bucket text, p_action text, p_max int, p_window interval
) returns boolean
language plpgsql volatile set search_path = public as $$
declare v_hits int;
begin
  if coalesce(btrim(p_bucket), '') = '' then return true; end if;

  delete from bot_rate_limits
   where action = p_action and window_start < now() - p_window;

  insert into bot_rate_limits (bucket, action)
  values (btrim(p_bucket), p_action)
  on conflict (bucket, action) do update
    set hits = case when bot_rate_limits.window_start < now() - p_window
                    then 1 else bot_rate_limits.hits + 1 end,
        window_start = case when bot_rate_limits.window_start < now() - p_window
                    then now() else bot_rate_limits.window_start end
  returning hits into v_hits;

  return v_hits <= p_max;
end $$;

-- ============================================================
-- 9. الفلو: منصة -> مدة -> أيام هدية -> معاينة -> تأكيد
-- ============================================================

create or replace function bot_platforms_list(p_telegram_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  perform bot_actor(p_telegram_id);
  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'is_active', is_active)
         order by sort_order, name), '[]'::jsonb) into v_out
    from bot_platforms where is_active;
  return v_out;
end $$;

create or replace function bot_add_platform(p_telegram_id bigint, p_name text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_next int;
begin
  perform bot_owner(p_telegram_id);
  p_name := btrim(coalesce(p_name, ''));
  if p_name = '' or char_length(p_name) > 60 then raise exception 'INVALID_PLATFORM'; end if;
  select coalesce(max(sort_order), 0) + 10 into v_next from bot_platforms;
  insert into bot_platforms (name, sort_order) values (p_name, v_next)
  on conflict (name) do update set is_active = true;
  return jsonb_build_object('name', p_name);
end $$;

create or replace function bot_remove_platform(p_telegram_id bigint, p_name text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  perform bot_owner(p_telegram_id);
  -- تعطيل لا حذف: الوثائق الصادرة تحمل اسم المنصة نصاً، فلا تتأثر،
  -- لكن إحصاءها حسب المنصة يبقى مفهوماً.
  update bot_platforms set is_active = false where name = btrim(coalesce(p_name, ''));
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'PLATFORM_NOT_FOUND'; end if;
  return jsonb_build_object('name', p_name, 'is_active', false);
end $$;

-- ---------- الحالة ----------
create or replace function bot_wizard_begin(p_telegram_id bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin bot_admins;
begin
  v_admin := bot_actor(p_telegram_id);
  insert into bot_wizard_state (admin_id, awaiting)
  values (v_admin.id, 'platform')
  on conflict (admin_id) do update
    set platform = null, months = null, bonus_days = null,
        awaiting = 'platform', message_id = null;
  return jsonb_build_object('awaiting', 'platform');
end $$;

-- خطوة واحدة تضبط قيمة واحدة وتقول ما بعدها. الوجهة محسوبة هنا لا
-- في الدالة، فترتيب الخطوات وقواعده في مكان واحد.
create or replace function bot_wizard_set(
  p_telegram_id bigint, p_step text, p_value text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin bot_admins; v_st bot_wizard_state; v_n int;
begin
  v_admin := bot_actor(p_telegram_id);
  select * into v_st from bot_wizard_state where admin_id = v_admin.id;
  if not found then raise exception 'WIZARD_NOT_STARTED'; end if;

  if p_step = 'platform' then
    p_value := btrim(coalesce(p_value, ''));
    if p_value = '' or char_length(p_value) > 60 then raise exception 'INVALID_PLATFORM'; end if;
    update bot_wizard_state set platform = p_value, awaiting = 'months'
     where admin_id = v_admin.id;

  elsif p_step = 'months' then
    v_n := nullif(btrim(coalesce(p_value, '')), '')::int;
    if v_n is null or v_n < 1 or v_n > 120 then raise exception 'INVALID_MONTHS'; end if;
    update bot_wizard_state set months = v_n, awaiting = 'bonus'
     where admin_id = v_admin.id;

  elsif p_step = 'bonus' then
    v_n := coalesce(nullif(btrim(coalesce(p_value, '')), '')::int, 0);
    if v_n < 0 or v_n > 90 then raise exception 'INVALID_BONUS'; end if;
    update bot_wizard_state set bonus_days = v_n, awaiting = 'preview'
     where admin_id = v_admin.id;

  -- انتظار إدخال يدوي: المنصة أو عدد الأيام
  elsif p_step in ('platform_manual', 'bonus_manual') then
    update bot_wizard_state set awaiting = p_step where admin_id = v_admin.id;

  -- «تعديل»: يعود لخطوة ويمحو ما بعدها، فلا تبقى قيمة معلّقة من
  -- مسار سابق تدخل المعاينة بلا أن يراها الأدمن.
  elsif p_step = 'back_platform' then
    update bot_wizard_state
       set awaiting = 'platform', platform = null, months = null, bonus_days = null
     where admin_id = v_admin.id;
  elsif p_step = 'back_months' then
    update bot_wizard_state
       set awaiting = 'months', months = null, bonus_days = null
     where admin_id = v_admin.id;
  elsif p_step = 'back_bonus' then
    update bot_wizard_state set awaiting = 'bonus', bonus_days = null
     where admin_id = v_admin.id;
  else
    raise exception 'INVALID_STEP:%', p_step;
  end if;

  return bot_wizard_preview(p_telegram_id);
end $$;

-- المعاينة: التواريخ المتوقّعة إن عُمِّرت الآن. البداية الحقيقية
-- تُثبَّت لحظة تعبئة الزبون، لا الآن — لذلك تُسمّى projected.
create or replace function bot_wizard_preview(p_telegram_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_admin bot_admins; v_st bot_wizard_state; v_start timestamptz;
begin
  v_admin := bot_actor(p_telegram_id);
  select * into v_st from bot_wizard_state where admin_id = v_admin.id;
  if not found then raise exception 'WIZARD_NOT_STARTED'; end if;

  v_start := now();
  return jsonb_build_object(
    'awaiting',   v_st.awaiting,
    'platform',   v_st.platform,
    'months',     v_st.months,
    'bonus_days', v_st.bonus_days,
    'ready',      v_st.platform is not null and v_st.months is not null
                  and v_st.bonus_days is not null,
    'projected_start', v_start,
    'projected_end',   case when v_st.months is null then null
                            else bot_engagement_expiry(v_start, v_st.months,
                                                       coalesce(v_st.bonus_days, 0)) end
  );
end $$;

create or replace function bot_wizard_cancel(p_telegram_id bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin bot_admins;
begin
  v_admin := bot_actor(p_telegram_id);
  delete from bot_wizard_state where admin_id = v_admin.id;
  return jsonb_build_object('cancelled', true);
end $$;

-- ============================================================
-- 10. التأكيد: وثيقة معلّقة + رابط واحد للزبون
-- ============================================================
-- الوثيقة تُنشأ الآن بلا صاحب ولا تواريخ — حالتها pending حتى
-- يعبّي الزبون. هكذا يراها الداشبورد من لحظة توليد الرابط، وهو
-- عين ما طُلب: pending = رابط مولّد وما عُمِّرش.
create or replace function bot_engagement_confirm(
  p_telegram_id bigint, p_hours int default 72
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin bot_admins; v_st bot_wizard_state;
  v_cert bot_certificates; v_token text;
begin
  v_admin := bot_actor(p_telegram_id);
  select * into v_st from bot_wizard_state where admin_id = v_admin.id;
  if not found then raise exception 'WIZARD_NOT_STARTED'; end if;
  if v_st.platform is null then raise exception 'PLATFORM_MISSING'; end if;
  if v_st.months   is null then raise exception 'MONTHS_MISSING';   end if;

  insert into bot_certificates
    (code, ref_code, platform, months, bonus_days, issued_by, customer)
  values
    (bot_engagement_code(), bot_engagement_ref(), v_st.platform, v_st.months,
     coalesce(v_st.bonus_days, 0), v_admin.id, '[]'::jsonb)
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
    'expires_at', now() + make_interval(hours => coalesce(p_hours, 72))
  );
end $$;

-- ---------- ما يراه الزبون قبل التعبئة ----------
-- الحقول الثلاثة مثبّتة، وتُعاد بمفاتيحها لا بتسمياتها: الترجمة
-- في ملفات i18n خارج القاعدة، فتبديل نصّ لا يمسّ هجرة.
create or replace function bot_engagement_claim_form(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_tok bot_fill_tokens; v_cert bot_certificates;
begin
  select * into v_tok from bot_fill_tokens where token = btrim(coalesce(p_token, ''));
  if not found then raise exception 'LINK_NOT_FOUND'; end if;
  if v_tok.certificate_id is null then raise exception 'LINK_NOT_FOUND'; end if;
  if v_tok.used_at is not null then raise exception 'LINK_USED'; end if;
  if v_tok.expires_at <= now() then raise exception 'LINK_EXPIRED'; end if;

  select * into v_cert from bot_certificates where id = v_tok.certificate_id;
  if v_cert.revoked_at is not null then raise exception 'CERTIFICATE_REVOKED'; end if;

  return jsonb_build_object(
    'platform',   v_cert.platform,
    'months',     v_cert.months,
    'bonus_days', v_cert.bonus_days,
    'fields',     jsonb_build_array('full_name', 'whatsapp', 'instagram')
  );
end $$;

-- ---------- التعبئة ----------
-- هنا تُثبَّت البداية والنهاية. لا تاريخ يُقبل من الفورم: الوسائط
-- ثلاثة نصوص فقط، والباقي يُحسب.
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
  if v_cert.starts_at is not null then raise exception 'ALREADY_CLAIMED'; end if;

  v_name := btrim(coalesce(p_name, ''));
  if char_length(v_name) < 3 or char_length(v_name) > 80 then raise exception 'INVALID_NAME'; end if;

  v_phone := bot_dz_phone(p_whatsapp);
  if v_phone is null then raise exception 'INVALID_PHONE'; end if;

  v_insta := nullif(regexp_replace(btrim(coalesce(p_instagram, '')), '^@+', ''), '');
  if v_insta is not null then
    if char_length(v_insta) > 40 then raise exception 'INVALID_INSTAGRAM'; end if;
    if v_insta !~ '^[A-Za-z0-9._]+$' then raise exception 'INVALID_INSTAGRAM'; end if;
  end if;

  v_start := now();

  update bot_certificates
     set holder_name = v_name,
         whatsapp    = v_phone,
         instagram   = v_insta,
         starts_at   = v_start,
         ends_at     = bot_engagement_expiry(v_start, v_cert.months, v_cert.bonus_days)
   where id = v_cert.id
  returning * into v_cert;

  update bot_fill_tokens set used_at = now() where token = v_tok.token;

  return jsonb_build_object(
    'code', v_cert.code, 'ref_code', v_cert.ref_code,
    'issued_by_telegram_id',
      (select telegram_id from bot_admins where id = v_cert.issued_by)
  );
end $$;

-- ============================================================
-- 11. القراءة العامة — الوثيقة وصفحة التحقق
-- ============================================================
-- دالة واحدة تحسب الحالة، فلا يعيد كل مستدعٍ حسابها بشكل مختلف.
create or replace function bot_engagement_status(c bot_certificates)
returns text
language sql immutable set search_path = public as $$
  select case
    when c.revoked_at is not null then 'revoked'
    when c.starts_at  is null     then 'pending'
    when c.ends_at is not null and c.ends_at <= now() then 'expired'
    else 'active' end;
$$;

-- الواتساب ليس هنا — بحكم قائمة الأعمدة لا بحكم ترشيح. ولا اسم
-- البائع، ولا كود البطاقة، ولا أي معطى داخلي.
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
  if v_cert.starts_at is null then raise exception 'CERTIFICATE_PENDING'; end if;

  return jsonb_build_object(
    'code',        v_cert.code,
    'ref_code',    v_cert.ref_code,
    'holder_name', v_cert.holder_name,
    'instagram',   v_cert.instagram,
    'platform',    v_cert.platform,
    'months',      v_cert.months,
    'bonus_days',  v_cert.bonus_days,
    'starts_at',   v_cert.starts_at,
    'ends_at',     v_cert.ends_at,
    'status',      bot_engagement_status(v_cert),
    'days_left',   case when v_cert.ends_at is null then null
                        else greatest(0, (date_part('day', v_cert.ends_at - now()))::int) end,
    'contacts', coalesce((
      select jsonb_agg(jsonb_build_object(
               'label', label, 'value', value, 'url', url, 'icon', icon)
             order by sort_order, label)
        from bot_contacts where is_active), '[]'::jsonb)
  );
end $$;

-- صفحة التحقق التي يقصدها الـQR: أقل ما يثبت الصحة. لا اسم كامل
-- ولا يوزر — من يمسح الرمز قد لا يكون صاحب الوثيقة.
create or replace function bot_engagement_verify(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_cert bot_certificates;
begin
  select * into v_cert from bot_certificates
   where code = upper(btrim(coalesce(p_code, '')));
  if not found or v_cert.starts_at is null then
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

-- ============================================================
-- 12. الإبطال وإعادة الرابط — للمُصدِر أو المالك
-- ============================================================
create or replace function bot_engagement_revoke(p_telegram_id bigint, p_code text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin bot_admins; v_cert bot_certificates;
begin
  v_admin := bot_actor(p_telegram_id);
  select * into v_cert from bot_certificates
   where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then raise exception 'CERTIFICATE_NOT_FOUND'; end if;
  if v_admin.role <> 'owner' and v_cert.issued_by is distinct from v_admin.id then
    raise exception 'NOT_YOUR_ISSUE';
  end if;
  if v_cert.revoked_at is not null then raise exception 'ALREADY_REVOKED'; end if;

  update bot_certificates set revoked_at = now(), revoked_by = v_admin.id
   where id = v_cert.id;
  -- ورابط تعبئة لم يُستعمل يسقط معها
  update bot_fill_tokens set used_at = now()
   where certificate_id = v_cert.id and used_at is null;

  return jsonb_build_object('code', v_cert.code, 'status', 'revoked');
end $$;

-- إعادة إرسال الرابط: رمز جديد يُبطل القديم، فلا رابطان لوثيقة.
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
  if v_cert.starts_at is not null then raise exception 'ALREADY_CLAIMED'; end if;

  delete from bot_fill_tokens where certificate_id = v_cert.id;
  v_token := replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '');
  insert into bot_fill_tokens (token, certificate_id, created_by, expires_at)
  values (v_token, v_cert.id, v_admin.id,
          now() + make_interval(hours => greatest(1, least(coalesce(p_hours, 72), 720))));

  return jsonb_build_object('code', v_cert.code, 'token', v_token);
end $$;

-- ============================================================
-- 13. الداشبورد — قراءة واحدة بكل الفلاتر
-- ============================================================
-- الواتساب يظهر هنا: هذه للأدمن لا للزبون، والداشبورد محمي
-- بـ Supabase Auth. p_with_phone صريح حتى لا يُسرَّب بالغفلة.
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
-- 14. الصلاحيات — service_role وحده، كما في 021.
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
