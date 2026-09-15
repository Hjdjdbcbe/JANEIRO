-- bundle: bot
-- ============================================================
-- Janeiro Store — 035 البيعات المؤكَّدة بأكوادها
--
-- /pending يعرض ما لم يُحسم بعد، و/stats يعدّ، و/breakdown يوزّع
-- على المنتجات. ولا شيء يعرض **البيعات المؤكَّدة نفسها**: البائع
-- يضغط «تأكيد» فيختفي الكود من المحادثة، ولا سبيل إليه بعدها.
--
-- فإن سأل زبونٌ عن كوده، أو أُكِّدت بيعةٌ بالخطأ ولزم معرفة أيّ
-- بطاقة ذهبت، لم يكن أمام المالك إلا SQL. هذا يفتح الباب.
--
-- والنطاق كنطاق bot_pending نفسه: البائع يرى بيعاته، والمالك
-- يرى الجميع. الكود هو البضاعة، فلا يُوسَّع مداه لأن العرض أسهل.
--
-- ويُعرض معه رمز وثيقة الالتزام إن صدرت — لأنّ أوّل سؤالٍ يلي
-- «أيّ بطاقة؟» هو «وهل خرجت لها وثيقة؟».
-- ============================================================

create or replace function bot_confirmed(
  p_telegram_id bigint,
  p_limit       int default 10
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_admin bot_admins; v_out jsonb;
begin
  v_admin := bot_actor(p_telegram_id);
  p_limit := greatest(1, least(coalesce(p_limit, 10), 50));

  select coalesce(jsonb_agg(x order by (x->>'settled_at') desc), '[]'::jsonb)
    into v_out
    from (
      select jsonb_build_object(
               'issue_id',     i.id,
               'card_code',    i.card_code,
               'product_name', pr.name,
               'variant_name', va.name,
               'customer_ref', i.customer_ref,
               'settled_at',   i.settled_at,
               'seller', coalesce(a.display_name, a.tg_name, a.username, a.telegram_id::text),
               'mine',   i.admin_id = v_admin.id,
               -- الوثيقة السارية وحدها: مُبطَلةٌ لا تمنع تراجعاً
               -- ولا تَعِد زبوناً بشيء، فذكرها تشويش.
               'doc_code', (select c.code from bot_certificates c
                             where c.issue_id = i.id and c.revoked_at is null)
             ) as x
        from bot_issues i
        join bot_variants va on va.id = i.variant_id
        join bot_products pr on pr.id = va.product_id
        join bot_admins   a  on a.id  = i.admin_id
       where i.status = 'confirmed'
         and (v_admin.role = 'owner' or i.admin_id = v_admin.id)
       order by i.settled_at desc
       limit p_limit
    ) s;

  return v_out;
end $$;

-- ------------------------------------------------------------
-- الصلاحيات — service_role وحده، كما في 021
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
