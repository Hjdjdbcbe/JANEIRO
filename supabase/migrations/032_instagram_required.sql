-- bundle: bot
-- ============================================================
-- Janeiro Store — 032 يوزر الإنستغرام مطلوب
--
-- كان اختيارياً. وهو الحقل الذي يُعرف به الحساب المفعَّل: بلاه
-- تقول الوثيقة «هذا الاشتراك لك» ولا تقول على أي حساب. والبائع
-- لا يملك إصلاح ذلك بعد أن يعبّئ الزبون ويُستهلك الرابط.
--
-- الوثائق الصادرة قبل هذا لا تتأثّر: الشرط على التعبئة الجديدة
-- وحدها، ولا قيد على العمود.
-- ============================================================

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

  -- مطلوب: به يُعرف الحساب المفعَّل، وبلاه لا تقول الوثيقة على
  -- أيّ حساب هذا الاشتراك.
  v_insta := nullif(regexp_replace(btrim(coalesce(p_instagram, '')), '^@+', ''), '');
  if v_insta is null then raise exception 'INVALID_INSTAGRAM'; end if;
  if char_length(v_insta) > 40 then raise exception 'INVALID_INSTAGRAM'; end if;
  if v_insta !~ '^[A-Za-z0-9._]+$' then raise exception 'INVALID_INSTAGRAM'; end if;

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
