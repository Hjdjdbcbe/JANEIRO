-- bundle: bot
-- ============================================================
-- Janeiro Store — 022 تفصيل المبيعات في البوت
--
-- ثلاثة أشياء كان البوت يعرفها ولا يقولها:
--
--   1. رسالة التأكيد لم تكن تذكر ماذا بيع — كوداً بلا اسم منتج
--      ولا مدة. البائع يغلق عشر عمليات فلا يعرف أيّها كانت أيّاً.
--   2. «مبيعاتي» رقم واحد مجمّع. كم سنة وكم 3 أشهر؟ لا جواب.
--   3. المالك يرى ترتيب البائعين، لا ماذا باع كل واحد بالضبط.
--
-- كلها كانت في bot_issues أصلاً — مسألة عرض لا جمع بيانات.
-- ============================================================

-- ------------------------------------------------------------
-- 1. التأكيد والإلغاء يقولان ماذا بيع
-- ------------------------------------------------------------
create or replace function bot_confirm_issue(p_telegram_id bigint, p_issue_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin   bot_admins;
  v_issue   bot_issues;
  v_variant bot_variants;
  v_product bot_products;
  v_sales   int;
  v_of_kind int;
begin
  v_admin := bot_actor(p_telegram_id);

  select * into v_issue from bot_issues where id = p_issue_id for update;
  if not found then raise exception 'ISSUE_NOT_FOUND'; end if;
  if v_issue.admin_id <> v_admin.id and v_admin.role <> 'owner' then
    raise exception 'NOT_YOUR_ISSUE';
  end if;
  if v_issue.status <> 'pending' then
    raise exception 'ISSUE_ALREADY_SETTLED:%', v_issue.status;
  end if;

  update bot_issues
     set status = 'confirmed', settled_at = now(), settled_by = v_admin.id
   where id = p_issue_id;

  update bot_cards set status = 'sold', sold_at = now() where id = v_issue.card_id;

  select * into v_variant from bot_variants where id = v_issue.variant_id;
  select * into v_product from bot_products where id = v_variant.product_id;

  select count(*) into v_sales
    from bot_issues where admin_id = v_issue.admin_id and status = 'confirmed';
  -- وكم باع من هذه المدة تحديداً: الرقم الذي يسأل عنه البائع فعلاً
  select count(*) into v_of_kind
    from bot_issues
   where admin_id = v_issue.admin_id and status = 'confirmed'
     and variant_id = v_issue.variant_id;

  return jsonb_build_object(
    'issue_id', v_issue.id, 'status', 'confirmed',
    'card_code', v_issue.card_code,
    'product_name', v_product.name,
    'variant_name', v_variant.name,
    'customer_ref', v_issue.customer_ref,
    'seller_sales', v_sales,
    'seller_sales_of_variant', v_of_kind,
    'remaining', (select count(*) from bot_cards
                   where variant_id = v_issue.variant_id and status = 'available')
  );
end $$;

create or replace function bot_cancel_issue(p_telegram_id bigint, p_issue_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin   bot_admins;
  v_issue   bot_issues;
  v_variant bot_variants;
  v_product bot_products;
begin
  v_admin := bot_actor(p_telegram_id);

  select * into v_issue from bot_issues where id = p_issue_id for update;
  if not found then raise exception 'ISSUE_NOT_FOUND'; end if;
  if v_issue.admin_id <> v_admin.id and v_admin.role <> 'owner' then
    raise exception 'NOT_YOUR_ISSUE';
  end if;
  if v_issue.status <> 'pending' then
    raise exception 'ISSUE_ALREADY_SETTLED:%', v_issue.status;
  end if;

  update bot_issues
     set status = 'cancelled', settled_at = now(), settled_by = v_admin.id
   where id = p_issue_id;

  update bot_cards set status = 'available'
   where id = v_issue.card_id and status = 'reserved';

  select * into v_variant from bot_variants where id = v_issue.variant_id;
  select * into v_product from bot_products where id = v_variant.product_id;

  return jsonb_build_object(
    'issue_id', v_issue.id, 'status', 'cancelled',
    'card_code', v_issue.card_code,
    'product_name', v_product.name,
    'variant_name', v_variant.name,
    'remaining', (select count(*) from bot_cards
                   where variant_id = v_issue.variant_id and status = 'available')
  );
end $$;

-- ------------------------------------------------------------
-- 2. من باع ماذا وكم — لكل أدمن، مفصّلاً حسب المنتج والمدة
--
--   p_scope = 'me'  -> صفّ المتحدث وحده
--   p_scope = 'all' -> كل الأدمن (للمالك)
--   p_target        -> أدمن بعينه (للمالك)
--
-- كل رقم محسوب من bot_issues لحظة القراءة، لا من عدّاد مخزّن.
-- ------------------------------------------------------------
create or replace function bot_breakdown(
  p_telegram_id bigint,
  p_scope       text   default 'me',
  p_target      bigint default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_admin bot_admins; v_out jsonb;
begin
  v_admin := bot_actor(p_telegram_id);
  if (p_scope = 'all' or p_target is not null) and v_admin.role <> 'owner' then
    raise exception 'NOT_OWNER';
  end if;
  if p_target is not null
     and not exists (select 1 from bot_admins where telegram_id = p_target) then
    raise exception 'ADMIN_NOT_FOUND';
  end if;

  select coalesce(jsonb_agg(s.row order by s.confirmed desc, s.name), '[]'::jsonb)
    into v_out
  from (
    select
      coalesce(a.display_name, a.tg_name, a.username, a.telegram_id::text) as name,
      count(i.id) filter (where i.status = 'confirmed') as confirmed,
      jsonb_build_object(
        'telegram_id', a.telegram_id,
        'name',      coalesce(a.display_name, a.tg_name, a.username, a.telegram_id::text),
        'role',      a.role::text,
        'is_active', a.is_active,
        'confirmed', count(i.id) filter (where i.status = 'confirmed'),
        'cancelled', count(i.id) filter (where i.status = 'cancelled'),
        'pending',   count(i.id) filter (where i.status = 'pending'),
        'today',     count(i.id) filter (where i.status = 'confirmed'
                                           and i.settled_at >= date_trunc('day', now())),
        'this_month',count(i.id) filter (where i.status = 'confirmed'
                                           and i.settled_at >= date_trunc('month', now())),
        -- التفصيل: سطر لكل مدة باع منها فعلاً. المدد التي لم يبع
        -- منها شيئاً لا تظهر — قائمة أصفار ليست تقريراً.
        'items', coalesce((
          select jsonb_agg(d.row order by d.confirmed desc, d.pname, d.vname)
            from (
              select pr.name as pname, va.name as vname,
                     count(*) filter (where i2.status = 'confirmed') as confirmed,
                jsonb_build_object(
                  'product',   pr.name,
                  'variant',   va.name,
                  'confirmed', count(*) filter (where i2.status = 'confirmed'),
                  'cancelled', count(*) filter (where i2.status = 'cancelled')
                ) as row
                from bot_issues i2
                join bot_variants va on va.id = i2.variant_id
                join bot_products pr on pr.id = va.product_id
               where i2.admin_id = a.id
                 and i2.status in ('confirmed','cancelled')
               group by pr.id, pr.name, va.id, va.name
              having count(*) filter (where i2.status = 'confirmed') > 0
            ) d
        ), '[]'::jsonb)
      ) as row
    from bot_admins a
    left join bot_issues i on i.admin_id = a.id
   where case
           when p_target is not null then a.telegram_id = p_target
           when p_scope = 'all'      then true
           else a.id = v_admin.id
         end
   group by a.id
  ) s;

  return v_out;
end $$;

-- ------------------------------------------------------------
-- 3. الصلاحيات — كما في 021: service_role وحده.
--    (تُعاد هنا لأن create or replace على دالة جديدة يمنح
--     PUBLIC حق التنفيذ افتراضياً.)
-- ------------------------------------------------------------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like 'bot\_%'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
