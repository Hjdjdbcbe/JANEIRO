-- ============================================================
-- Janeiro Store — اختبارات داشبورد المالك (034)
--   psql "$DATABASE_URL" -f tests/dashboard.test.sql
-- كل تأكيد يرفع خطأ عند فشله، فالتشغيل النظيف = نجاح الكل.
-- لا شيء يُحفظ: الملف كله داخل معاملة تُلغى في آخره.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. الفتح: المالك وحده
-- ------------------------------------------------------------
do $$
declare
  v_owner constant bigint := 970000001;
  v_sell  constant bigint := 970000002;
  v_res jsonb; v_tok text;
begin
  perform bot_bootstrap_owner(v_owner, 'o34', 'المالك');
  perform bot_add_admin(v_owner, v_sell, 'بائع');

  v_res := bot_dashboard_open(v_owner);
  v_tok := v_res->>'token';
  assert char_length(v_tok) = 64, 'الرمز 64 خانة، وجد ' || char_length(v_tok);
  assert v_tok ~ '^[0-9a-f]{64}$', 'وست عشرية كلها — لا يُخمَّن ولا يُكتب بيد';
  assert (v_res->>'expires_at')::timestamptz > now(), 'وله نهاية في المستقبل';
  assert (v_res->>'expires_at')::timestamptz < now() + interval '25 hours',
         'و24 ساعة لا أكثر افتراضياً';

  -- بائع نشط لا يفتحها: الصفحة تعرض زبائن الجميع، والدور هو الفرق
  begin
    perform bot_dashboard_open(v_sell);
    assert false, 'a seller opened the owner dashboard';
  exception when others then
    assert sqlerrm like 'OWNER_ONLY%', 'البائع يُمنع، وجد: ' || sqlerrm;
  end;

  -- ومجهول لا يصل أصلاً
  begin
    perform bot_dashboard_open(970000099);
    assert false, 'a stranger opened it';
  exception when others then
    assert sqlerrm like 'NOT_AUTHORIZED%', 'المجهول يُمنع، وجد: ' || sqlerrm;
  end;
  raise notice 'PASS  الفتح: للمالك وحده، برمز 64 خانة';
end $$;

-- ------------------------------------------------------------
-- 2. الرمز الواحد الحيّ
-- ------------------------------------------------------------
-- رابط منسيّ في محادثة قديمة يفتح كل شيء إلى أن ينتهي عمره.
-- ففتحٌ جديد يقتل ما قبله: واحد حيّ في كل لحظة.
do $$
declare
  v_owner constant bigint := 970000001;
  v_old text; v_new text;
begin
  v_old := bot_dashboard_open(v_owner)->>'token';
  v_new := bot_dashboard_open(v_owner)->>'token';
  assert v_old <> v_new, 'فتحٌ جديد يعطي رمزاً جديداً';

  begin
    perform bot_dashboard_list(v_old);
    assert false, 'the older link still worked';
  exception when others then
    assert sqlerrm like 'SESSION_REVOKED%', 'والقديم يموت، وجد: ' || sqlerrm;
  end;
  assert bot_dashboard_list(v_new) ? 'rows', 'والجديد يفتح';

  -- والإبطال اليدوي يقتل الحيّ
  assert (bot_dashboard_close(v_owner)->>'closed')::int = 1, 'الإبطال يقتل واحداً';
  begin
    perform bot_dashboard_list(v_new);
    assert false, 'the link survived an explicit close';
  exception when others then
    assert sqlerrm like 'SESSION_REVOKED%', 'وبعده لا يفتح، وجد: ' || sqlerrm;
  end;
  assert (bot_dashboard_close(v_owner)->>'closed')::int = 0, 'وإبطال ثانٍ لا يجد شيئاً';
  raise notice 'PASS  رابط واحد حيّ، والفتح والإبطال يقتلان ما قبلهما';
end $$;

-- ------------------------------------------------------------
-- 3. الرمز المنتهي، والمخترَع
-- ------------------------------------------------------------
do $$
declare
  v_owner constant bigint := 970000001;
  v_tok text;
begin
  v_tok := bot_dashboard_open(v_owner)->>'token';
  update bot_admin_sessions set expires_at = now() - interval '1 minute' where token = v_tok;
  begin
    perform bot_dashboard_list(v_tok);
    assert false, 'an expired link worked';
  exception when others then
    assert sqlerrm like 'SESSION_EXPIRED%', 'المنتهي يُرفض، وجد: ' || sqlerrm;
  end;

  begin
    perform bot_dashboard_list(repeat('a', 64));
    assert false, 'an invented token worked';
  exception when others then
    assert sqlerrm like 'SESSION_NOT_FOUND%', 'والمخترَع لا يوجد، وجد: ' || sqlerrm;
  end;
  raise notice 'PASS  المنتهي والمخترَع يُرفضان';
end $$;

-- ------------------------------------------------------------
-- 4. الدور يُعاد فحصه عند كل قراءة لا عند الفتح وحده
-- ------------------------------------------------------------
-- رمزٌ فُتح وهو مالك، ثم خُفض أو عُطّل: القراءة تتبع دوره الآن،
-- لا دوره يوم فُتح. وإلا صار الرمز صلاحيةً مجمّدة لا تُنزع.
do $$
declare
  v_owner constant bigint := 970000001;
  v_tok text;
begin
  v_tok := bot_dashboard_open(v_owner)->>'token';
  assert bot_dashboard_list(v_tok) ? 'rows', 'يفتح وهو مالك';

  update bot_admins set role = 'admin' where telegram_id = v_owner;
  begin
    perform bot_dashboard_list(v_tok);
    assert false, 'a demoted owner kept reading';
  exception when others then
    assert sqlerrm like 'OWNER_ONLY%', 'وبعد التخفيض يُمنع، وجد: ' || sqlerrm;
  end;

  update bot_admins set role = 'owner', is_active = false where telegram_id = v_owner;
  begin
    perform bot_dashboard_list(v_tok);
    assert false, 'a deactivated owner kept reading';
  exception when others then
    assert sqlerrm like 'NOT_AUTHORIZED%', 'والمعطَّل يُمنع، وجد: ' || sqlerrm;
  end;

  update bot_admins set is_active = true where telegram_id = v_owner;
  assert bot_dashboard_list(v_tok) ? 'rows', 'ويعود بعودته';
  raise notice 'PASS  الدور يُقرأ عند كل قراءة لا يُجمَّد في الرمز';
end $$;

-- ------------------------------------------------------------
-- 5. البحث والفلاتر — والرقم لا يخرج
-- ------------------------------------------------------------
do $$
declare
  v_owner constant bigint := 970000001;
  v_sell  constant bigint := 970000002;
  v_tok text; v_res jsonb; v_code text;
begin
  /* المالك يرى كل وثيقة في القاعدة — وهذا هو المقصود. لكنّه
     يجعل العدّ هنا رهينةَ ما تركه اختبارٌ آخر قبله في نفس
     القاعدة. فتُفرَّغ أولاً: المعاملة تُلغى في آخر الملف،
     فلا يضيع شيء، ويصير العدد عدداً لا تقريباً. */
  delete from bot_certificates;

  perform bot_dashboard_close(v_owner);
  v_tok := bot_dashboard_open(v_owner)->>'token';

  -- وثيقتان لخدمتين مختلفتين، من بائعين مختلفين
  perform bot_wizard_begin(v_owner);
  perform bot_wizard_set(v_owner, 'platform', 'Netflix');
  perform bot_wizard_set(v_owner, 'months', '6');
  perform bot_wizard_set(v_owner, 'bonus', '0');
  v_res := bot_engagement_confirm(v_owner);
  perform bot_engagement_claim(v_res->>'token', 'كمال حداد', '0770334455', 'kamal.h');

  perform bot_wizard_begin(v_sell);
  perform bot_wizard_set(v_sell, 'platform', 'Spotify');
  perform bot_wizard_set(v_sell, 'months', '1');
  perform bot_wizard_set(v_sell, 'bonus', '0');
  v_res  := bot_engagement_confirm(v_sell);
  v_code := v_res->>'code';
  perform bot_engagement_claim(v_res->>'token', 'ليلى مرزوق', null, 'layla.m');

  -- المالك يرى الاثنتين ولو باع إحداهما غيره
  v_res := bot_dashboard_list(v_tok);
  assert (v_res->>'total')::int = 2, 'المالك يرى وثائق الجميع، وجد ' || (v_res->>'total');

  -- البحث
  assert (bot_dashboard_list(v_tok, 'كمال')->>'total')::int = 1, 'بحث بالاسم';
  assert (bot_dashboard_list(v_tok, 'layla.m')->>'total')::int = 1, 'بحث باليوزر';
  assert (bot_dashboard_list(v_tok, '0770334455')->>'total')::int = 1,
         'بحث بالرقم كما يكتبه الزبون محلياً';
  assert (bot_dashboard_list(v_tok, v_code)->>'total')::int = 1, 'بحث بالرمز';
  assert (bot_dashboard_list(v_tok, 'ماكانش')->>'total')::int = 0, 'وبلا نتائج كاذبة';

  -- الفلاتر
  assert (bot_dashboard_list(v_tok, null, null, 'Netflix')->>'total')::int = 1, 'فلتر الخدمة';
  assert (bot_dashboard_list(v_tok, null, 'active')->>'total')::int = 2, 'فلتر الحالة';
  assert (bot_dashboard_list(v_tok, null, 'revoked')->>'total')::int = 0, 'وحالة بلا صفوف';
  -- واجتماعهما ترشيحٌ واحد لا ترشيحان
  assert (bot_dashboard_list(v_tok, 'كمال', 'active', 'Spotify')->>'total')::int = 0,
         'الاسم مع خدمة أخرى لا يتقاطعان';

  -- الشرط الأصرح في هذا الملف: الرقم لا يخرج من الصفحة أبداً
  v_res := bot_dashboard_list(v_tok, 'كمال');
  assert v_res->'rows'->0->'whatsapp' = 'null'::jsonb,
         'الرقم محجوب في الداشبورد';
  assert not (v_res::text like '%213770334455%'), 'ولا في أيّ موضع من الردّ';
  assert v_res->'rows'->0->>'holder_name' = 'كمال حداد', 'والاسم يظهر — هو المقصود';

  -- ما تحتاجه الواجهة: قائمة الخدمات تُبنى مما في القاعدة
  v_res := bot_dashboard_list(v_tok);
  assert v_res->'platforms' @> '["Netflix","Spotify"]'::jsonb,
         'الخدمات من القاعدة لا من قائمة مكتوبة بيد';
  assert v_res ? 'expires_at' and v_res ? 'owner', 'ومتى ينتهي الرابط ولمن هو';
  raise notice 'PASS  البحث والفلاتر تعملان، والرقم لا يخرج';
end $$;

-- ------------------------------------------------------------
-- 6. الترقيم
-- ------------------------------------------------------------
do $$
declare
  v_owner constant bigint := 970000001;
  v_tok text; v_res jsonb;
begin
  v_tok := bot_dashboard_open(v_owner)->>'token';
  v_res := bot_dashboard_list(v_tok, null, null, null, 1, 0);
  assert (v_res->>'total')::int = 2, 'العدد الكلي لا يتأثر بحجم الصفحة';
  assert jsonb_array_length(v_res->'rows') = 1, 'والصفحة صفّ واحد';
  assert jsonb_array_length(bot_dashboard_list(v_tok, null, null, null, 1, 1)->'rows') = 1,
         'والصفحة الثانية صفّ آخر';
  assert bot_dashboard_list(v_tok, null, null, null, 1, 0)->'rows'->0->>'code'
      <> bot_dashboard_list(v_tok, null, null, null, 1, 1)->'rows'->0->>'code',
         'وليسا الصفّ نفسه';
  assert jsonb_array_length(bot_dashboard_list(v_tok, null, null, null, 50, 99)->'rows') = 0,
         'وما بعد الآخر فارغ لا خطأ';
  raise notice 'PASS  الترقيم: العدّ كليّ والصفحة جزئية';
end $$;

-- ------------------------------------------------------------
-- 7. آخر زيارة
-- ------------------------------------------------------------
-- ليلاحظ المالك فتحاً لم يفعله هو.
do $$
declare
  v_owner constant bigint := 970000001;
  v_tok text;
begin
  v_tok := bot_dashboard_open(v_owner)->>'token';
  assert (select last_seen_at is null from bot_admin_sessions where token = v_tok),
         'جلسة لم تُفتح بعد لا زيارة لها';
  perform bot_dashboard_seen(v_tok, '41.100.5.5');
  assert (select last_seen_at is not null and last_ip = '41.100.5.5'
            from bot_admin_sessions where token = v_tok),
         'والزيارة تُسجَّل بوقتها وعنوانها';
  -- ورمز لا وجود له لا يرفع خطأً: التسجيل ليس تحقّقاً
  perform bot_dashboard_seen(repeat('b', 64), '41.100.5.5');
  raise notice 'PASS  آخر زيارة تُسجَّل';
end $$;

-- ------------------------------------------------------------
-- 8. الحدّ، والصلاحيات
-- ------------------------------------------------------------
do $$
declare
  v_owner constant bigint := 970000001;
  v_tok text; v_n int;
begin
  v_tok := bot_dashboard_open(v_owner)->>'token';
  v_n := 0;
  for i in 1..120 loop
    if bot_dashboard_guard(v_tok, '41.100.7.7') then v_n := v_n + 1; end if;
  end loop;
  assert v_n = 120, 'مئة وعشرون قراءة مسموحة، وجد ' || v_n;
  assert bot_dashboard_guard(v_tok, '41.100.7.7') = false, 'والحادية والعشرون بعد المئة تُرفض';

  -- والجدول مقفول كبقية جداول البوت
  select count(*) into v_n from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'bot_admin_sessions' and not c.relrowsecurity;
  assert v_n = 0, 'RLS مفعّل على جدول الجلسات';

  select count(*) into v_n from pg_policies
   where schemaname = 'public' and tablename = 'bot_admin_sessions';
  assert v_n = 0, 'وبلا أيّ سياسة: service_role وحده';

  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname like 'bot\_dashboard\_%'
     and (has_function_privilege('anon',          p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute'));
  assert v_n = 0, v_n || ' من دوال الداشبورد ما زالت مفتوحة لـanon';

  select count(*) into v_n from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'bot_admin_sessions'
     and grantee in ('anon','authenticated');
  assert v_n = 0, 'ولا صلاحية لـanon على جدول الجلسات';
  raise notice 'PASS  الحدّ يعمل، والجداول والدوال مقفولة';
end $$;

do $$ begin raise notice '===== dashboard tests passed ====='; end $$;

rollback;
