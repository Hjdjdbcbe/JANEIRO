-- bundle: bot
-- ============================================================
-- Janeiro Store — 034 داشبورد الزبائن، للمالك وحده
--
-- bot_engagement_admin_list موجودة منذ 025، مكتوبة ومُختبَرة،
-- ولا ينادیها شيء: لا البوت ولا الموقع. تعليقها يقول «الداشبورد
-- محمي بـ Supabase Auth»، وذلك الداشبورد لم يُبنَ قط. فالمحرّك
-- جاهز والواجهة ناقصة.
--
-- والواجهة هنا صفحة على الموقع، لا تُفتح إلا برمز يمنحه البوت
-- للمالك. ولماذا رمزاً لا كلمة سر: كلمة السر حساب ثانٍ يُحفظ
-- ويُنسى ويُعاد ضبطه، والمالك معروف أصلاً في البوت بـchat id
-- في env — فلا داعي لهوية ثانية بجنب هوية قائمة.
--
-- والرمز حامل (bearer): من يملكه يفتح. فله ثلاثة قيود —
-- عمر قصير، وإبطال يدوي، وحدّ محاولات — وهي ما يجعل تسريبه
-- حادثةَ يوم لا حادثةَ دائمة.
--
-- والصفحة تقرأ ولا تكتب: لا إبطال ولا إعادة رابط منها. تلك
-- في البوت حيث الفاعل معروف بـchat id لا برمز في URL.
-- ============================================================

-- ------------------------------------------------------------
-- 1. جلسات الداشبورد
-- ------------------------------------------------------------
create table if not exists bot_admin_sessions (
  token        text primary key,
  admin_id     uuid not null references bot_admins(id) on delete cascade,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  revoked_at   timestamptz,
  last_seen_at timestamptz,
  last_ip      text
);

create index if not exists ix_bot_admin_sessions_admin
  on bot_admin_sessions(admin_id, created_at desc);

alter table bot_admin_sessions enable row level security;
revoke all on bot_admin_sessions from anon, authenticated;

-- ------------------------------------------------------------
-- 2. فتح جلسة — المالك وحده
-- ------------------------------------------------------------
-- بائع لا يفتحها ولو كان أدمن نشطاً: الصفحة تعرض زبائن الجميع،
-- والدور هو الفرق. والصلاحية تُقرأ من bot_admins لا من الرمز،
-- فلو رُقّي بائع أو خُفض بعد فتح جلسته تبع القراءةُ دورَه الآن.
create or replace function bot_dashboard_open(
  p_telegram_id bigint,
  p_hours       int default 24
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin bot_admins; v_token text; v_exp timestamptz;
begin
  v_admin := bot_actor(p_telegram_id);
  if v_admin.role <> 'owner' then raise exception 'OWNER_ONLY'; end if;

  -- جلسة جديدة تُبطل ما قبلها: رابطٌ واحد حيٌّ في كل لحظة، فلا
  -- تتراكم روابط منسية في محادثات قديمة كلٌّ منها يفتح كل شيء.
  update bot_admin_sessions set revoked_at = now()
   where admin_id = v_admin.id and revoked_at is null and expires_at > now();

  v_token := replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '');
  v_exp   := now() + make_interval(hours => greatest(1, least(coalesce(p_hours, 24), 168)));

  insert into bot_admin_sessions (token, admin_id, expires_at)
  values (v_token, v_admin.id, v_exp);

  return jsonb_build_object('token', v_token, 'expires_at', v_exp);
end $$;

-- إبطال فوري: الرابط ضاع، أو انتهت الحاجة إليه
create or replace function bot_dashboard_close(p_telegram_id bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin bot_admins; v_n int;
begin
  v_admin := bot_actor(p_telegram_id);
  if v_admin.role <> 'owner' then raise exception 'OWNER_ONLY'; end if;
  update bot_admin_sessions set revoked_at = now()
   where admin_id = v_admin.id and revoked_at is null and expires_at > now();
  get diagnostics v_n = row_count;
  return jsonb_build_object('closed', v_n);
end $$;

-- ------------------------------------------------------------
-- 3. حدّ المحاولات على الرمز
-- ------------------------------------------------------------
-- رمزٌ في URL يُخمَّن بالتكرار لا بالذكاء: 64 خانة hex لا تُخمَّن
-- أصلاً، لكن الحدّ يمنع من يجرّب أن يستنزف القاعدة وهو يحاول.
create or replace function bot_dashboard_guard(p_token text, p_ip text default null)
returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  if not bot_rate_limit('dash:' || coalesce(btrim(p_token), ''), 'dash', 120, interval '10 minutes')
  then return false; end if;
  if p_ip is not null and btrim(p_ip) <> ''
     and not bot_rate_limit('daship:' || btrim(p_ip), 'dash', 240, interval '10 minutes')
  then return false; end if;
  return true;
end $$;

-- ------------------------------------------------------------
-- 4. القراءة بالرمز
-- ------------------------------------------------------------
-- الرمز يُترجَم إلى صاحبه، ثم تُنادى دالة 025 نفسها بـtelegram_id
-- صاحبه. فمنطق الترشيح واحد لا اثنان: ما يصلح في البوت يصلح هنا،
-- وأيّ تعديل عليه يصيب الاثنين معاً.
--
-- والرقم لا يخرج: p_with_phone تبقى false. الصفحة بحثٌ وفلاتر،
-- وما لم يُطلب صراحةً لا يُرسَل — لقطة شاشة عابرة لا تفضح أرقام
-- زبائنه.
create or replace function bot_dashboard_list(
  p_token    text,
  p_query    text default null,
  p_status   text default null,
  p_platform text default null,
  p_limit    int  default 50,
  p_offset   int  default 0
) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_sess bot_admin_sessions; v_admin bot_admins; v_res jsonb;
begin
  select * into v_sess from bot_admin_sessions
   where token = btrim(coalesce(p_token, ''));
  if not found                     then raise exception 'SESSION_NOT_FOUND'; end if;
  if v_sess.revoked_at is not null  then raise exception 'SESSION_REVOKED';   end if;
  if v_sess.expires_at <= now()     then raise exception 'SESSION_EXPIRED';   end if;

  select * into v_admin from bot_admins where id = v_sess.admin_id;
  -- الدور يُعاد فحصه عند كل قراءة، لا عند الفتح وحده
  if not found or not v_admin.is_active then raise exception 'NOT_AUTHORIZED'; end if;
  if v_admin.role <> 'owner'            then raise exception 'OWNER_ONLY';    end if;

  v_res := bot_engagement_admin_list(
             v_admin.telegram_id, p_query, p_status, p_platform,
             p_limit, p_offset, false);

  return v_res || jsonb_build_object(
    'expires_at', v_sess.expires_at,
    'owner', coalesce(v_admin.display_name, v_admin.tg_name,
                      v_admin.username, v_admin.telegram_id::text),
    -- أزرار الفلترة تُبنى ممّا في القاعدة فعلاً، لا من قائمة
    -- مكتوبة بيد تتخلّف عن المنصات الجديدة
    'platforms', (select coalesce(jsonb_agg(distinct platform order by platform), '[]'::jsonb)
                    from bot_certificates where platform is not null));
end $$;

-- آخر زيارة: ليقول البوت متى فُتحت الصفحة ومن أين، فيلاحظ
-- المالك فتحاً لم يفعله هو.
create or replace function bot_dashboard_seen(p_token text, p_ip text default null)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  update bot_admin_sessions
     set last_seen_at = now(),
         last_ip = nullif(btrim(coalesce(p_ip, '')), '')
   where token = btrim(coalesce(p_token, ''));
end $$;

-- ------------------------------------------------------------
-- 5. الصلاحيات — service_role وحده، كما في 021 و025
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
