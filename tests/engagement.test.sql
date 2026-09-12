-- ============================================================
-- Janeiro Store — اختبارات وثيقة التزام الخدمة (025)
--   psql "$DATABASE_URL" -f tests/engagement.test.sql
-- كل تأكيد يرفع خطأ عند فشله، فالتشغيل النظيف = نجاح الكل.
-- لا شيء يُحفظ: الملف كله داخل معاملة تُلغى في آخره.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- الحساب — قبل أي شيء آخر، فكل شيء يعتمد عليه
-- ------------------------------------------------------------
do $$
declare v_a timestamptz; v_b timestamptz;
begin
  -- expiryDate = addDays(addMonths(start, months), bonusDays)
  -- أيام الهدية تزيد أياماً، لا تعيد حساب الأشهر
  v_a := bot_engagement_expiry('2026-09-12 12:00:00+01', 12, 0);
  v_b := bot_engagement_expiry('2026-09-12 12:00:00+01', 12, 7);
  assert v_b - v_a = interval '7 days',
         '7 bonus days must add exactly 7 days, got ' || (v_b - v_a)::text;
  assert v_a = '2027-09-12 12:00:00+01'::timestamptz, 'a year later, same wall clock';

  -- الأشهر أولاً ثم الأيام: 31 يناير + شهر = 28 فبراير، + يوم = 1 مارس.
  -- العكس (يوم ثم شهر) يعطي 1 مارس كذلك هنا، لكن الترتيب يهمّ في
  -- حالات أخرى، وهذا يثبّت السلوك المعتمد.
  assert bot_engagement_expiry('2026-01-31 10:00:00+01', 1, 1)
         = '2026-03-01 10:00:00+01'::timestamptz,
         'Jan 31 + 1 month + 1 day = Mar 1';

  -- شهر واحد على 31 أغسطس ينزل إلى 30 سبتمبر لا يتخطّاه
  assert bot_engagement_expiry('2026-08-31 09:00:00+01', 1, 0)
         = '2026-09-30 09:00:00+01'::timestamptz, 'month-end clamps, never overflows';

  -- 29 فبراير في سنة كبيسة: +12 شهراً = 28 فبراير
  assert bot_engagement_expiry('2028-02-29 08:00:00+01', 12, 0)
         = '2029-02-28 08:00:00+01'::timestamptz, 'leap day + 12 months = Feb 28';

  -- الحساب بتوقيت الجزائر: نفس ساعة اليوم المحلية بعد 6 أشهر
  assert to_char(bot_engagement_expiry('2026-09-12 23:30:00+01', 6, 0)
                 at time zone 'Africa/Algiers', 'YYYY-MM-DD HH24:MI')
         = '2027-03-12 23:30', 'local wall clock is preserved across the interval';

  -- المدة صفر أشهر غير مسموحة في الفلو، لكن الدالة تبقى محضة:
  assert bot_engagement_expiry('2026-09-12 12:00:00+01', 0, 5)
         = '2026-09-17 12:00:00+01'::timestamptz, 'bonus days alone still add';
  raise notice 'PASS  الحساب: أشهر ثم أيام، بتوقيت الجزائر';
end $$;

-- ------------------------------------------------------------
-- تطبيع الرقم الجزائري
-- ------------------------------------------------------------
do $$ begin
  assert bot_dz_phone('0550123456')      = '213550123456', 'phone: local 05';
  assert bot_dz_phone('0661234567')      = '213661234567', 'phone: local 06';
  assert bot_dz_phone('0770998877')      = '213770998877', 'phone: local 07';
  assert bot_dz_phone('+213550123456')   = '213550123456', 'phone: +213';
  assert bot_dz_phone('00213550123456')  = '213550123456', 'phone: 00213';
  assert bot_dz_phone('0550 12 34 56')   = '213550123456', 'phone: spaces';
  assert bot_dz_phone('0550-12-34-56')   = '213550123456', 'phone: dashes';
  assert bot_dz_phone('0451234567')      is null, 'phone: landline rejected';
  assert bot_dz_phone('0550123')         is null, 'phone: too short rejected';
  assert bot_dz_phone('05501234567')     is null, 'phone: too long rejected';
  assert bot_dz_phone('abcdefghij')      is null, 'phone: letters rejected';
  assert bot_dz_phone('')                is null, 'phone: empty rejected';
  assert bot_dz_phone(null)              is null, 'phone: null rejected';
  raise notice 'PASS  تطبيع الرقم الجزائري';
end $$;

-- ------------------------------------------------------------
-- الفلو والوثيقة
-- ------------------------------------------------------------
do $$
declare
  v_owner constant bigint := 910000001;
  v_sell  constant bigint := 910000002;
  v_other constant bigint := 910000003;
  v_res   jsonb;
  v_tok   text;
  v_code  text;
  v_tok2  text;
  v_n     int;
begin
  perform bot_bootstrap_owner(v_owner, 'owner', 'المالك');
  perform bot_add_admin(v_owner, v_sell,  'بائع');
  perform bot_add_admin(v_owner, v_other, 'بائع آخر');

  -- ========== المنصات ==========
  assert jsonb_array_length(bot_platforms_list(v_sell)) = 8,
         'the eight seeded platforms are listed';
  assert (bot_platforms_list(v_sell) -> 0 ->> 'name') = 'Snapchat Plus',
         'in the order they were given';
  perform bot_add_platform(v_owner, 'Prime Video');
  assert jsonb_array_length(bot_platforms_list(v_sell)) = 9, 'owner adds a platform';
  perform bot_remove_platform(v_owner, 'Prime Video');
  assert jsonb_array_length(bot_platforms_list(v_sell)) = 8, 'and hides it again';
  begin
    perform bot_add_platform(v_sell, 'تسلل');
    assert false, 'a plain admin edited the platform list';
  exception when others then
    assert sqlerrm like 'NOT_OWNER%', 'platforms are owner-only, got: ' || sqlerrm;
  end;
  raise notice 'PASS  المنصات: مزروعة، وتُزاد وتُخفى من البوت';

  -- ========== الفلو ==========
  begin
    perform bot_wizard_preview(v_sell);
    assert false, 'preview worked with no wizard started';
  exception when others then
    assert sqlerrm like 'WIZARD_NOT_STARTED%', 'no state, no preview, got: ' || sqlerrm;
  end;

  perform bot_wizard_begin(v_sell);
  assert bot_wizard_preview(v_sell)->>'awaiting' = 'platform', 'starts at the platform';

  v_res := bot_wizard_set(v_sell, 'platform', 'Snapchat Plus');
  assert v_res->>'awaiting' = 'months', 'then asks the duration';
  v_res := bot_wizard_set(v_sell, 'months', '12');
  assert v_res->>'awaiting' = 'bonus', 'then the bonus days';
  assert (v_res->>'ready')::boolean = false, 'not ready before the bonus is answered';

  v_res := bot_wizard_set(v_sell, 'bonus', '7');
  assert v_res->>'awaiting' = 'preview', 'then the preview';
  assert (v_res->>'ready')::boolean, 'and it is ready';
  assert (v_res->>'projected_end')::timestamptz
         = bot_engagement_expiry((v_res->>'projected_start')::timestamptz, 12, 7),
         'the preview shows the same computation the certificate will use';

  -- «تعديل» يمحو ما بعد الخطوة، فلا تدخل قيمة قديمة المعاينة
  v_res := bot_wizard_set(v_sell, 'back_months', '');
  assert v_res->>'awaiting' = 'months', 'editing the duration returns to it';
  assert v_res->>'months' is null and v_res->>'bonus_days' is null,
         'and clears the duration AND the bonus after it';
  assert v_res->>'platform' = 'Snapchat Plus', 'but keeps what came before';

  v_res := bot_wizard_set(v_sell, 'back_platform', '');
  assert v_res->>'platform' is null, 'editing the platform clears everything';

  -- الحدود
  perform bot_wizard_set(v_sell, 'platform', 'Netflix');
  begin
    perform bot_wizard_set(v_sell, 'months', '0');
    assert false, 'zero months accepted';
  exception when others then
    assert sqlerrm like 'INVALID_MONTHS%', 'zero months rejected, got: ' || sqlerrm;
  end;
  begin
    perform bot_wizard_set(v_sell, 'months', '121');
    assert false, '121 months accepted';
  exception when others then
    assert sqlerrm like 'INVALID_MONTHS%', 'over the cap rejected';
  end;
  perform bot_wizard_set(v_sell, 'months', '12');
  begin
    perform bot_wizard_set(v_sell, 'bonus', '91');
    assert false, '91 bonus days accepted';
  exception when others then
    assert sqlerrm like 'INVALID_BONUS%', 'bonus over 90 rejected, got: ' || sqlerrm;
  end;
  begin
    perform bot_wizard_set(v_sell, 'bonus', '-1');
    assert false, 'negative bonus accepted';
  exception when others then
    assert sqlerrm like 'INVALID_BONUS%', 'negative bonus rejected';
  end;
  -- الديفولت صفر: قيمة فارغة تعني «لا»
  assert (bot_wizard_set(v_sell, 'bonus', '')->>'bonus_days')::int = 0,
         'an empty bonus answer means zero, the default';
  raise notice 'PASS  الفلو: الخطوات، التعديل، والحدود';

  -- ========== التأكيد ==========
  -- المنصة الآن Netflix: ضُبطت بعد فحوص «تعديل» أعلاه. يُثبَّت هنا
  -- صراحةً حتى لا يعتمد ما بعده على تتبّع سطور بعيدة.
  assert bot_wizard_preview(v_sell)->>'platform' = 'Netflix',
         'the platform carried through the edits is the one being confirmed';
  perform bot_wizard_set(v_sell, 'bonus', '7');
  v_res  := bot_engagement_confirm(v_sell);
  v_tok  := v_res->>'token';
  v_code := v_res->>'code';
  assert v_code ~ '^JW-[0-9A-F]{10}$', 'code is JW- + 10 hex, got: ' || v_code;
  assert v_res->>'ref_code' ~ '^JS-[0-9A-F]{8}$',
         'ref is JS- + 8 hex, got: ' || (v_res->>'ref_code');
  assert char_length(v_tok) = 64, 'token is 64 chars, got ' || char_length(v_tok);
  assert (v_res->>'bonus_days')::int = 7, 'the bonus travels onto the certificate';

  -- الحالة الآن pending: رابط مولّد وما عُمِّرش
  assert (select bot_engagement_status(c) from bot_certificates c where c.code = v_code)
         = 'pending', 'a generated link is a pending certificate';
  -- ولا تواريخ بعد: البداية هي لحظة التعبئة
  assert (select starts_at is null and ends_at is null and holder_name is null
            from bot_certificates where code = v_code),
         'a pending certificate carries no dates and no holder at all';
  -- والفلو انمحى، فلا تأكيد ثانٍ من نفس الحالة
  begin
    perform bot_engagement_confirm(v_sell);
    assert false, 'confirmed twice from one wizard run';
  exception when others then
    assert sqlerrm like 'WIZARD_NOT_STARTED%', 'the wizard is consumed, got: ' || sqlerrm;
  end;
  raise notice 'PASS  التأكيد: أكواد بصيغتها، ووثيقة معلّقة بلا تواريخ';

  -- ========== ما يراه الزبون قبل التعبئة ==========
  v_res := bot_engagement_claim_form(v_tok);
  assert v_res->>'platform' = 'Netflix', 'the form names the service';
  assert v_res->'fields' = '["full_name","whatsapp","instagram"]'::jsonb,
         'three fields, by key — the labels live in i18n outside the database';
  -- والوثيقة المعلّقة لا تُقرأ من الرابط العام
  begin
    perform bot_engagement_public(v_code);
    assert false, 'a pending certificate was readable';
  exception when others then
    assert sqlerrm like 'CERTIFICATE_PENDING%', 'pending is not public, got: ' || sqlerrm;
  end;

  -- ========== التعبئة ==========
  begin
    perform bot_engagement_claim(v_tok, 'أح', '0550111222', null, null);
    assert false, 'a two-letter name was accepted';
  exception when others then
    assert sqlerrm like 'INVALID_NAME%', 'short name rejected, got: ' || sqlerrm;
  end;
  begin
    perform bot_engagement_claim(v_tok, 'أحمد بن يوسف', '0451234567', null, null);
    assert false, 'a landline was accepted as WhatsApp';
  exception when others then
    assert sqlerrm like 'INVALID_PHONE%', 'landline rejected, got: ' || sqlerrm;
  end;
  begin
    perform bot_engagement_claim(v_tok, 'أحمد بن يوسف', '0550111222', 'bad user!', null);
    assert false, 'an invalid instagram handle was accepted';
  exception when others then
    assert sqlerrm like 'INVALID_INSTAGRAM%', 'bad handle rejected, got: ' || sqlerrm;
  end;

  v_res := bot_engagement_claim(v_tok, '  أحمد بن يوسف  ', '0550 99 88 77',
                                '@@ahmed.dz01', '41.100.1.1');
  assert v_res->>'code' = v_code, 'claiming returns the same certificate';
  assert (v_res->>'issued_by_telegram_id')::bigint = v_sell,
         'and it stays credited to the seller who issued it';

  -- ما خُزِّن: الاسم مقلَّم، الرقم مطبَّع، الـ@ محذوف
  assert (select holder_name from bot_certificates where code = v_code) = 'أحمد بن يوسف',
         'the name is trimmed';
  assert (select whatsapp from bot_certificates where code = v_code) = '213550998877',
         'the phone is normalised server-side, not stored as typed';
  assert (select instagram from bot_certificates where code = v_code) = 'ahmed.dz01',
         'leading @ is stripped';

  -- التواريخ: محسوبة، وليست مقبولة من أحد
  assert (select ends_at = bot_engagement_expiry(starts_at, months, bonus_days)
            from bot_certificates where code = v_code),
         'the end date is exactly the computed one';
  assert (select ends_at::date - starts_at::date from bot_certificates where code = v_code)
         between 370 and 374, '12 months + 7 days lands a year and a week out';
  assert (select bot_engagement_status(c) from bot_certificates c where c.code = v_code)
         = 'active', 'and the certificate is now active';
  raise notice 'PASS  التعبئة: تحقّق، تطبيع، وتواريخ محسوبة لا مُدخَلة';

  -- ========== الرابط مرة واحدة ==========
  begin
    perform bot_engagement_claim(v_tok, 'شخص آخر', '0660111222', null, null);
    assert false, 'the link worked a second time';
  exception when others then
    assert sqlerrm like 'LINK_USED%', 'second claim blocked, got: ' || sqlerrm;
  end;
  begin
    perform bot_engagement_claim_form(v_tok);
    assert false, 'a used link still opened the form';
  exception when others then
    assert sqlerrm like 'LINK_USED%', 'used link cannot reopen';
  end;
  raise notice 'PASS  الرابط يصلح مرة واحدة';

  -- ========== القراءة العامة: لا واتساب، أبداً ==========
  v_res := bot_engagement_public(v_code);
  assert v_res->>'holder_name' = 'أحمد بن يوسف', 'public: the holder';
  assert v_res->>'instagram'   = 'ahmed.dz01',   'public: the handle';
  assert v_res->>'platform'    = 'Netflix',      'public: the service';
  assert v_res->>'status'      = 'active',       'public: the status';
  -- الشرط الأمني الأصرح في هذا الملف
  assert not (v_res ? 'whatsapp'), 'the public document must NOT carry the phone number';
  assert not (v_res::text like '%213550998877%'), 'nor the number anywhere inside it';
  assert not (v_res ? 'seller') and not (v_res ? 'issued_by'),
         'nor who sold it';
  assert not (v_res::text like '%JS-%') or v_res->>'ref_code' is not null,
         'the reference is intentional, not a leak';
  assert bot_engagement_public('  ' || lower(v_code) || ' ')->>'code' = v_code,
         'public read tolerates case and spaces — the customer retypes it';
  raise notice 'PASS  الوثيقة العامة: بلا رقم الواتساب وبلا اسم البائع';

  -- ========== صفحة التحقق (هدف الـQR) ==========
  v_res := bot_engagement_verify(v_code);
  assert (v_res->>'found')::boolean, 'verify finds it';
  assert v_res->>'holder_hint' = 'أ***', 'verify hints at the name, never spells it';
  assert not (v_res ? 'holder_name') and not (v_res ? 'instagram'),
         'verify shows no identity to whoever scanned the code';
  assert not (v_res ? 'whatsapp'), 'and no phone';
  assert (bot_engagement_verify('JW-0000000000')->>'found')::boolean = false,
         'an invented code simply is not found — no error to probe with';
  raise notice 'PASS  التحقق يثبت الصحة بلا كشف الهوية';

  -- ========== الحالات ==========
  update bot_certificates set starts_at = now() - interval '400 days',
                              ends_at   = now() - interval '1 day'
   where code = v_code;
  assert (select bot_engagement_status(c) from bot_certificates c where c.code = v_code)
         = 'expired', 'past its end date it reads expired';
  assert bot_engagement_public(v_code)->>'status' = 'expired', 'publicly too';
  assert (bot_engagement_public(v_code)->>'days_left')::int = 0,
         'and days_left never goes negative';

  -- ========== الإبطال ==========
  begin
    perform bot_engagement_revoke(v_other, v_code);
    assert false, 'another seller revoked a certificate that was not theirs';
  exception when others then
    assert sqlerrm like 'NOT_YOUR_ISSUE%', 'revoke is scoped, got: ' || sqlerrm;
  end;
  perform bot_engagement_revoke(v_owner, v_code);
  assert (select bot_engagement_status(c) from bot_certificates c where c.code = v_code)
         = 'revoked', 'the owner can revoke any';
  begin
    perform bot_engagement_revoke(v_owner, v_code);
    assert false, 'revoked twice';
  exception when others then
    assert sqlerrm like 'ALREADY_REVOKED%', 'no double revoke';
  end;
  raise notice 'PASS  الإبطال، ومحصور على مُصدِرها أو المالك';

  -- ========== إعادة إرسال الرابط ==========
  perform bot_wizard_begin(v_sell);
  perform bot_wizard_set(v_sell, 'platform', 'Netflix');
  perform bot_wizard_set(v_sell, 'months', '3');
  perform bot_wizard_set(v_sell, 'bonus', '0');
  v_res  := bot_engagement_confirm(v_sell);
  v_code := v_res->>'code';
  v_tok  := v_res->>'token';

  v_tok2 := bot_engagement_relink(v_sell, v_code)->>'token';
  assert v_tok2 <> v_tok, 'relink mints a new token';
  begin
    perform bot_engagement_claim_form(v_tok);
    assert false, 'the old link still worked after a relink';
  exception when others then
    assert sqlerrm like 'LINK_NOT_FOUND%',
           'the old link dies so two links never exist, got: ' || sqlerrm;
  end;
  assert bot_engagement_claim_form(v_tok2)->>'platform' = 'Netflix', 'the new one works';

  perform bot_engagement_claim(v_tok2, 'سارة م', '0770112233', null, null);
  begin
    perform bot_engagement_relink(v_sell, v_code);
    assert false, 'relinked an already-claimed certificate';
  exception when others then
    assert sqlerrm like 'ALREADY_CLAIMED%', 'nothing to re-fill, got: ' || sqlerrm;
  end;
  raise notice 'PASS  إعادة الرابط تُبطل القديم، ولا تعمل بعد التعبئة';

  -- ========== بلا هدية: صفر يعني صفر ==========
  assert (select bonus_days from bot_certificates where code = v_code) = 0,
         'no bonus stored as zero, not null';
  assert (select ends_at::date - starts_at::date from bot_certificates where code = v_code)
         between 89 and 92, '3 months with no bonus is three months';
  raise notice 'PASS  أيام الهدية صفر تُخزَّن صفراً';

  -- ========== حدّ المحاولات ==========
  perform bot_wizard_begin(v_sell);
  perform bot_wizard_set(v_sell, 'platform', 'Spotify');
  perform bot_wizard_set(v_sell, 'months', '1');
  perform bot_wizard_set(v_sell, 'bonus', '0');
  v_tok := bot_engagement_confirm(v_sell)->>'token';
  -- الحارس يُنادى كما تناديه الدالة الحدّية: قبل العمل، وحده.
  -- محاولة فاشلة تُحتسب — هذا المهم، وهو ما كان يسقط حين كان
  -- الحدّ داخل bot_engagement_claim.
  v_n := 0;
  for i in 1..10 loop
    if bot_claim_guard(v_tok, '41.100.9.9') then v_n := v_n + 1; end if;
  end loop;
  assert v_n = 10, 'the first ten attempts on a link are allowed, got ' || v_n;
  assert bot_claim_guard(v_tok, '41.100.9.9') = false,
         'the eleventh is refused';
  -- ورمز آخر لا يتأثر بحدّ الأول
  assert bot_claim_guard('some-other-token-entirely-0000000000000000', '41.100.9.9'),
         'a different link has its own budget';
  raise notice 'PASS  حدّ المحاولات يحتسب الفاشلة كذلك';

  raise notice '===== engagement tests passed =====';
end $$;

-- ------------------------------------------------------------
-- الداشبورد
-- ------------------------------------------------------------
do $$
declare
  v_owner constant bigint := 910000001;
  v_sell  constant bigint := 910000002;
  v_other constant bigint := 910000003;
  v_res jsonb; v_tok text; v_code text;
begin
  perform bot_wizard_begin(v_sell);
  perform bot_wizard_set(v_sell, 'platform', 'Canva Pro');
  perform bot_wizard_set(v_sell, 'months', '6');
  perform bot_wizard_set(v_sell, 'bonus', '14');
  v_res  := bot_engagement_confirm(v_sell);
  v_code := v_res->>'code';
  perform bot_engagement_claim(v_res->>'token', 'ياسين قدور', '0661445566', 'yacine_q', null);

  -- البحث
  assert (bot_engagement_admin_list(v_owner, 'ياسين')->>'total')::int = 1,
         'dashboard: search by name';
  assert (bot_engagement_admin_list(v_owner, '0661445566')->>'total')::int = 1,
         'dashboard: search by phone as typed locally';
  assert (bot_engagement_admin_list(v_owner, 'yacine_q')->>'total')::int = 1,
         'dashboard: search by instagram';
  assert (bot_engagement_admin_list(v_owner, v_code)->>'total')::int = 1,
         'dashboard: search by code';
  assert (bot_engagement_admin_list(v_owner, 'nobody')->>'total')::int = 0,
         'dashboard: no false positives';

  -- الفلاتر
  assert (bot_engagement_admin_list(v_owner, null, null, 'Canva Pro')->>'total')::int = 1,
         'dashboard: filter by platform';
  assert (bot_engagement_admin_list(v_owner, null, 'pending')->>'total')::int >= 0,
         'dashboard: filter by status runs';
  assert (bot_engagement_admin_list(v_owner, null, 'revoked')->>'total')::int = 1,
         'dashboard: the revoked one is findable by status';

  -- الواتساب محجوب افتراضياً
  v_res := bot_engagement_admin_list(v_owner, 'ياسين');
  assert v_res->'rows'->0->>'whatsapp' is null,
         'dashboard hides the phone unless it is asked for explicitly';
  v_res := bot_engagement_admin_list(v_owner, 'ياسين', null, null, 100, 0, true);
  assert v_res->'rows'->0->>'whatsapp' = '213661445566',
         'and shows it when it is';

  -- الشارة: أقل من 7 أيام وما زالت سارية
  assert (v_res->'rows'->0->>'ending_soon')::boolean = false,
         'six months out is not ending soon';
  update bot_certificates set ends_at = now() + interval '3 days' where code = v_code;
  v_res := bot_engagement_admin_list(v_owner, 'ياسين');
  assert (v_res->'rows'->0->>'ending_soon')::boolean,
         'three days out is ending soon — that is the resell cue';
  -- اشتراك منتهٍ حقيقي: بدايته في الماضي كذلك. bot_cert_window_ok
  -- يرفض نهايةً قبل بدايةٍ، وهو محق — فيُحرَّك الاثنان.
  update bot_certificates
     set starts_at = now() - interval '200 days', ends_at = now() - interval '1 day'
   where code = v_code;
  v_res := bot_engagement_admin_list(v_owner, 'ياسين');
  assert (v_res->'rows'->0->>'ending_soon')::boolean = false,
         'already expired is not "ending soon"';
  assert v_res->'rows'->0->>'status' = 'expired', 'and it reads expired';

  -- كل بائع يرى وثائقه، والمالك يرى الكل
  assert (bot_engagement_admin_list(v_other, 'ياسين')->>'total')::int = 0,
         'a seller does not see another seller''s certificates';
  assert (bot_engagement_admin_list(v_sell, 'ياسين')->>'total')::int = 1,
         'but does see their own';
  raise notice 'PASS  الداشبورد: بحث، فلاتر، شارة، وحجب الرقم';
end $$;

-- ------------------------------------------------------------
-- الصلاحيات
-- ------------------------------------------------------------
do $$
declare v_n int;
begin
  select count(*) into v_n from pg_policies
   where schemaname = 'public'
     and tablename in ('bot_platforms','bot_wizard_state','bot_rate_limits');
  assert v_n = 0, 'the new tables carry no RLS policy at all, found ' || v_n;

  select count(*) into v_n from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
     and c.relname in ('bot_platforms','bot_wizard_state','bot_rate_limits','bot_certificates');
  assert v_n = 0, v_n || ' of the new tables have RLS disabled';

  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname like 'bot\_%'
     and (has_function_privilege('anon',          p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute'));
  assert v_n = 0, v_n || ' bot_* functions are still callable by anon/authenticated';

  select count(*) into v_n from information_schema.role_table_grants
   where table_schema = 'public' and table_name like 'bot\_%'
     and grantee in ('anon','authenticated');
  assert v_n = 0, 'anon/authenticated hold no grant on any bot table, found ' || v_n;
  raise notice 'PASS  صلاحيات 025 مغلقة على service_role';
end $$;

rollback;
