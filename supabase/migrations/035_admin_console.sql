-- ============================================================
-- Janeiro Store — 035 لوحة التحكم الموحّدة
--
-- اللوحة (dashboard/) تدخل بحساب Supabase Auth ودور admin في
-- profiles. البوت يعرف أصحابه بـ telegram_id في bot_admins. فكانت
-- اللوحة لا ترى شيئاً من البوت: المخزون، المبيعات، البائعين،
-- وثائق الضمان — كلها خلف bot_actor(telegram_id).
--
-- الجسر هنا: أدمن اللوحة يتصرّف في البوت **بصفة مالك البوت**.
-- لا نكتب منطق البوت مرة ثانية؛ كل كتابة تمرّ بدوال البوت نفسها
-- (bot_add_cards، bot_set_price، bot_engagement_revoke...) بنفس
-- قواعدها ورسائل أخطائها، فلا يفترق ما تفعله اللوحة عمّا يفعله
-- البوت. والقراءات التي لا يعطيها البوت بالشكل الذي تحتاجه
-- شاشة (قائمة مبيعات بفلاتر، الأكواد، الملخص) مكتوبة هنا.
--
-- والأمان: كل دالة تبدأ بـ is_admin()، وتُمنح لـ authenticated
-- وحده. من سجّل الدخول بلا دور admin يُرفض في الخادم.
-- ============================================================

-- ------------------------------------------------------------
-- 1. من أنا في البوت؟ — مالك البوت النشط
-- ------------------------------------------------------------
create or replace function admin_bot_actor()
returns bigint
language plpgsql stable security definer set search_path = public as $$
declare v bigint;
begin
  if not is_admin() then raise exception 'NOT_ADMIN'; end if;
  select telegram_id into v
    from bot_admins
   where role = 'owner' and is_active
   order by created_at
   limit 1;
  if v is null then raise exception 'NO_BOT_OWNER'; end if;
  return v;
end $$;

-- ------------------------------------------------------------
-- 2. كل أفعال البوت من نقطة واحدة
-- ------------------------------------------------------------
-- قائمة بيضاء: فعلٌ غير مذكور هنا يُرفض. والمعاملات بالأسماء في
-- jsonb حتى لا تتغيّر توقيعات الدالة كل ما زاد فعل.
create or replace function admin_bot(p_action text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  tg bigint;
  a  jsonb := coalesce(p_args, '{}'::jsonb);
  v_codes text[];
  v_lines text[];
begin
  tg := admin_bot_actor();

  case p_action
  -- قراءات
  when 'catalog'   then return bot_catalog(tg, false);
  when 'markets'   then return bot_markets_list(tg);
  when 'platforms' then return bot_platforms_list(tg);
  -- bot_stats بلا سوق البائع؛ والشاشة تعرضه وتبدّله، فيُضاف هنا
  when 'sellers'   then
    return coalesce((
      select jsonb_agg(x || jsonb_build_object('market', ad.market) order by ord)
        from jsonb_array_elements(bot_stats(tg, 'all')) with ordinality as e(x, ord)
        left join bot_admins ad on ad.telegram_id = (x->>'telegram_id')::bigint), '[]'::jsonb);
  when 'contacts'  then return bot_list_contacts(tg);
  when 'fields'    then return bot_fields_of(tg);
  when 'pending'   then return bot_pending(tg);
  when 'terms'     then return bot_terms_list(tg, a->>'platform');
  when 'expiring'  then return bot_expiring(tg, coalesce((a->>'days')::int, 7));
  when 'breakdown' then
    return bot_breakdown(tg, coalesce(a->>'scope', 'all'), nullif(a->>'telegram_id', '')::bigint);
  when 'product_platforms' then
    return bot_product_platforms_list(tg, (a->>'product_id')::uuid);
  when 'engagements' then
    return bot_engagement_admin_list(tg, a->>'query', a->>'status', a->>'platform',
             coalesce((a->>'limit')::int, 50), coalesce((a->>'offset')::int, 0), true);

  -- البائعين
  when 'add_admin' then
    return bot_add_admin(tg, (a->>'telegram_id')::bigint, a->>'name');
  when 'remove_admin' then
    return bot_remove_admin(tg, (a->>'telegram_id')::bigint);
  when 'set_admin_market' then
    return bot_set_admin_market(tg, (a->>'telegram_id')::bigint, a->>'market');

  -- الكتالوج
  when 'add_product' then return bot_add_product(tg, a->>'code', a->>'name');
  when 'add_variant' then return bot_add_variant(tg, a->>'product_code', a->>'code', a->>'name');
  when 'set_active'  then
    return bot_set_active(tg, a->>'kind', (a->>'id')::uuid, (a->>'active')::boolean);
  when 'set_price' then
    return bot_set_price(tg, (a->>'variant_id')::uuid, a->>'market', (a->>'price')::numeric);
  when 'set_duration' then
    return bot_set_variant_duration(tg, (a->>'variant_id')::uuid,
             nullif(a->>'value', '')::int, nullif(a->>'unit', ''));
  when 'set_market_active' then
    return bot_set_market_active(tg, a->>'market', (a->>'active')::boolean);
  when 'add_cards' then
    select array_agg(x) into v_codes from jsonb_array_elements_text(coalesce(a->'codes', '[]'::jsonb)) x;
    return bot_add_cards(tg, (a->>'variant_id')::uuid, coalesce(v_codes, array[]::text[]), a->>'note');

  -- المنصّات والحقول وروابط التواصل وشروط الوثيقة
  when 'add_platform'    then return bot_add_platform(tg, a->>'name');
  when 'remove_platform' then return bot_remove_platform(tg, a->>'name');
  when 'add_product_platform' then
    return bot_add_product_platform(tg, (a->>'product_id')::uuid, a->>'platform');
  when 'remove_product_platform' then
    return bot_remove_product_platform(tg, (a->>'product_id')::uuid, a->>'platform');
  when 'add_field' then
    return bot_add_field(tg, a->>'product_code', a->>'label', coalesce((a->>'required')::boolean, true));
  when 'remove_field' then return bot_remove_field(tg, a->>'product_code', a->>'label');
  when 'add_contact' then
    return bot_add_contact(tg, a->>'label', a->>'value', a->>'url', a->>'icon');
  when 'remove_contact' then return bot_remove_contact(tg, a->>'label');
  when 'set_terms' then
    select array_agg(x) into v_lines from jsonb_array_elements_text(coalesce(a->'lines', '[]'::jsonb)) x;
    return bot_set_terms(tg, a->>'platform', a->>'lang', coalesce(v_lines, array[]::text[]));

  -- المبيعات المعلّقة والوثائق
  when 'set_issue_platform' then
    return bot_issue_set_platform(tg, (a->>'issue_id')::uuid, a->>'platform');
  when 'set_issue_price' then
    return bot_issue_set_price(tg, (a->>'issue_id')::uuid, (a->>'price')::numeric);
  when 'confirm_issue' then return bot_confirm_issue(tg, (a->>'issue_id')::uuid);
  when 'cancel_issue'  then return bot_cancel_issue(tg, (a->>'issue_id')::uuid);
  when 'from_issue' then
    return bot_engagement_from_issue(tg, (a->>'issue_id')::uuid,
             coalesce((a->>'bonus_days')::int, 0), coalesce((a->>'hours')::int, 72));
  when 'revoke' then return bot_engagement_revoke(tg, a->>'code');
  when 'relink' then return bot_engagement_relink(tg, a->>'code', coalesce((a->>'hours')::int, 72));

  else raise exception 'UNKNOWN_ACTION';
  end case;
end $$;

-- ------------------------------------------------------------
-- 3. مبيعات البوت — قائمة بفلاتر
-- ------------------------------------------------------------
create or replace function admin_bot_sales(
  p_status      text    default null,   -- pending | confirmed | cancelled
  p_telegram_id bigint  default null,   -- بائع واحد
  p_query       text    default null,   -- الزبون، الكود، المنتج
  p_limit       int     default 50,
  p_offset      int     default 0
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_q text; v_out jsonb;
begin
  if not is_admin() then raise exception 'NOT_ADMIN'; end if;
  v_q := nullif(btrim(coalesce(p_query, '')), '');
  p_limit  := greatest(1, least(coalesce(p_limit, 50), 200));
  p_offset := greatest(0, coalesce(p_offset, 0));

  with m as (
    select i.*, pr.name as product_name, va.name as variant_name,
           coalesce(a.display_name, a.tg_name, a.username, a.telegram_id::text) as seller,
           a.telegram_id as seller_tg,
           c.code as certificate_code, c.revoked_at as certificate_revoked
      from bot_issues i
      join bot_variants va on va.id = i.variant_id
      join bot_products pr on pr.id = va.product_id
      join bot_admins   a  on a.id  = i.admin_id
      left join lateral (select code, revoked_at from bot_certificates
                          where issue_id = i.id order by created_at desc limit 1) c on true
     where (p_status is null or i.status::text = p_status)
       and (p_telegram_id is null or a.telegram_id = p_telegram_id)
       and (v_q is null
            or i.customer_ref ilike '%' || v_q || '%'
            or i.card_code    ilike '%' || v_q || '%'
            or pr.name        ilike '%' || v_q || '%'
            or c.code = upper(v_q))
  ), f as (select *, count(*) over () as total from m)
  select jsonb_build_object(
    'total', coalesce(max(total), 0),
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'issue_id', id, 'status', status, 'card_code', card_code,
      'customer_ref', customer_ref, 'product_name', product_name,
      'variant_name', variant_name, 'seller', seller, 'seller_tg', seller_tg,
      'price', price, 'currency', currency, 'market', market, 'platform', platform,
      'requested_at', requested_at, 'settled_at', settled_at,
      'certificate_code', certificate_code,
      'certificate_revoked', certificate_revoked is not null
    ) order by requested_at desc), '[]'::jsonb))
  into v_out
  from (select * from f order by requested_at desc limit p_limit offset p_offset) x;

  return v_out;
end $$;

-- ------------------------------------------------------------
-- 3ب. كتالوج البوت كاملاً لشاشة المخزون
-- ------------------------------------------------------------
-- bot_catalog يعطي العدّ وحده. الشاشة تحتاج معه الأسعار لكل سوق
-- والمدة والمنصّات وحقول الزبون — في قراءة واحدة.
create or replace function admin_bot_catalog()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'NOT_ADMIN'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'product_id', pr.id, 'code', pr.code, 'name', pr.name, 'is_active', pr.is_active,
      'platforms', (select coalesce(jsonb_agg(pp.platform order by pp.sort_order, pp.platform), '[]'::jsonb)
                      from bot_product_platforms pp where pp.product_id = pr.id),
      'fields', (select coalesce(jsonb_agg(jsonb_build_object('label', f.label, 'is_required', f.is_required)
                   order by f.sort_order, f.label), '[]'::jsonb)
                   from bot_fields f where f.product_id = pr.id),
      'variants', (select coalesce(jsonb_agg(jsonb_build_object(
          'variant_id', va.id, 'code', va.code, 'name', va.name, 'is_active', va.is_active,
          'duration_value', va.duration_value, 'duration_unit', va.duration_unit,
          'available', (select count(*) from bot_cards c where c.variant_id = va.id and c.status = 'available'),
          'reserved',  (select count(*) from bot_cards c where c.variant_id = va.id and c.status = 'reserved'),
          'sold',      (select count(*) from bot_cards c where c.variant_id = va.id and c.status = 'sold'),
          'disabled',  (select count(*) from bot_cards c where c.variant_id = va.id and c.status = 'disabled'),
          'prices', (select coalesce(jsonb_object_agg(bp.market, bp.price), '{}'::jsonb)
                       from bot_prices bp where bp.variant_id = va.id)
        ) order by va.sort_order, va.name), '[]'::jsonb)
        from bot_variants va where va.product_id = pr.id)
    ) order by pr.sort_order, pr.name)
    from bot_products pr
  ), '[]'::jsonb);
end $$;

-- ------------------------------------------------------------
-- 4. أكواد البطاقات — المخزون بالتفصيل
-- ------------------------------------------------------------
-- الكود يظهر للأدمن وحده، وهو سبب وجود الشاشة: يرى ما شحنه.
create or replace function admin_bot_cards(
  p_variant_id uuid,
  p_status     text default null,      -- available | reserved | sold | disabled
  p_limit      int  default 200
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'NOT_ADMIN'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', c.id, 'seq', c.seq, 'code', c.code, 'status', c.status,
             'note', c.note, 'created_at', c.created_at, 'sold_at', c.sold_at
           ) order by c.seq desc)
      from (select * from bot_cards
             where variant_id = p_variant_id
               and (p_status is null or status::text = p_status)
             order by seq desc
             limit greatest(1, least(coalesce(p_limit, 200), 1000))) c
  ), '[]'::jsonb);
end $$;

-- إيقاف كود أو إرجاعه للبيع. المحجوز والمبيع لا يُلمسان: الأول
-- في يد بائع الآن، والثاني عند زبون.
create or replace function admin_bot_card_set(p_card_id uuid, p_disabled boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v bot_cards;
begin
  if not is_admin() then raise exception 'NOT_ADMIN'; end if;
  select * into v from bot_cards where id = p_card_id for update;
  if not found then raise exception 'CARD_NOT_FOUND'; end if;
  if v.status not in ('available', 'disabled') then raise exception 'CARD_IN_USE'; end if;
  update bot_cards
     set status = case when p_disabled then 'disabled' else 'available' end::bot_card_status
   where id = p_card_id;
  return jsonb_build_object('id', p_card_id,
           'status', case when p_disabled then 'disabled' else 'available' end);
end $$;

-- ------------------------------------------------------------
-- 5. ملخص البوت للنظرة العامة
-- ------------------------------------------------------------
create or replace function admin_bot_summary()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not is_admin() then raise exception 'NOT_ADMIN'; end if;
  select jsonb_build_object(
    'available', (select count(*) from bot_cards where status = 'available'),
    'reserved',  (select count(*) from bot_cards where status = 'reserved'),
    'pending',   (select count(*) from bot_issues where status = 'pending'),
    'sold_today', (select count(*) from bot_issues
                    where status = 'confirmed' and settled_at >= date_trunc('day', now())),
    'sold_month', (select count(*) from bot_issues
                    where status = 'confirmed' and settled_at >= date_trunc('month', now())),
    'revenue_month', (select coalesce(jsonb_object_agg(cur, total), '{}'::jsonb) from (
                        select coalesce(currency, '—') as cur, sum(price) as total
                          from bot_issues
                         where status = 'confirmed' and price is not null
                           and settled_at >= date_trunc('month', now())
                         group by 1) r),
    'certificates_active', (select count(*) from bot_certificates
                             where revoked_at is null and (ends_at is null or ends_at > now())),
    'expiring_7d', (select count(*) from bot_certificates
                     where revoked_at is null and ends_at > now()
                       and ends_at <= now() + interval '7 days'),
    'sellers', (select count(*) from bot_admins where is_active),
    'low_stock', (select coalesce(jsonb_agg(jsonb_build_object(
                    'product', pr.name, 'variant', va.name, 'available', n.available)
                    order by n.available, pr.name), '[]'::jsonb)
                    from (select variant_id, count(*) filter (where status = 'available') as available
                            from bot_cards group by variant_id) n
                    join bot_variants va on va.id = n.variant_id and va.is_active
                    join bot_products pr on pr.id = va.product_id and pr.is_active
                   where n.available <= 2),
    'has_owner', exists (select 1 from bot_admins where role = 'owner' and is_active)
  ) into v;
  return v;
end $$;

-- ------------------------------------------------------------
-- 6. وثائق ضمان الموقع
-- ------------------------------------------------------------
create or replace function admin_site_certificates(
  p_query  text default null,
  p_limit  int  default 50,
  p_offset int  default 0
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_q text; v_out jsonb;
begin
  if not is_admin() then raise exception 'NOT_ADMIN'; end if;
  v_q := nullif(btrim(coalesce(p_query, '')), '');
  p_limit  := greatest(1, least(coalesce(p_limit, 50), 200));
  p_offset := greatest(0, coalesce(p_offset, 0));

  with m as (
    select wc.*, o.order_number, o.customer_name, o.customer_phone, o.status as order_status,
           oi.product_name_snapshot as product_name, oi.plan_name_snapshot as plan_name,
           oi.warranty_label_snapshot as warranty_label
      from warranty_certificates wc
      join order_items oi on oi.id = wc.order_item_id
      join orders o on o.id = oi.order_id
     where v_q is null
        or wc.certificate_code = upper(v_q)
        or o.order_number = v_q
        or o.customer_name ilike '%' || v_q || '%'
        or (char_length(regexp_replace(v_q, '[^0-9]', '', 'g')) >= 4
            and coalesce(o.normalized_phone, o.customer_phone)
                like '%' || regexp_replace(regexp_replace(v_q, '[^0-9]', '', 'g'), '^0', '') || '%')
        or oi.product_name_snapshot ilike '%' || v_q || '%'
  ), f as (select *, count(*) over () as total from m)
  select jsonb_build_object(
    'total', coalesce(max(total), 0),
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'code', certificate_code, 'order_number', order_number,
      'customer_name', customer_name, 'customer_phone', customer_phone,
      'product_name', product_name, 'plan_name', plan_name, 'warranty_label', warranty_label,
      'starts_at', starts_at, 'ends_at', ends_at, 'created_at', created_at,
      'order_status', order_status,
      'active', ends_at is null or ends_at > now()
    ) order by created_at desc), '[]'::jsonb))
  into v_out
  from (select * from f order by created_at desc limit p_limit offset p_offset) x;
  return v_out;
end $$;

-- ------------------------------------------------------------
-- 7. زبائن الموقع
-- ------------------------------------------------------------
-- زبون = رقم هاتف. الاسم آخر اسم كتبه، والمصروف من الطلبات التي
-- تأكّد دفعها ولم تُسترجع — نفس تعريف الدخل في admin_dashboard_stats.
create or replace function admin_customers(
  p_query  text default null,
  p_limit  int  default 50,
  p_offset int  default 0
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_q text; v_d text; v_out jsonb;
begin
  if not is_admin() then raise exception 'NOT_ADMIN'; end if;
  v_q := nullif(btrim(coalesce(p_query, '')), '');
  -- الأرقام وحدها، وبلا الصفر الأول: الرقم يُخزَّن 213661...
  -- والناس تكتبه 0661... — فالجزء المشترك هو ما بعد الصفر.
  v_d := nullif(regexp_replace(regexp_replace(coalesce(v_q, ''), '[^0-9]', '', 'g'), '^0', ''), '');
  if v_d is not null and char_length(v_d) < 3 then v_d := null; end if;
  p_limit  := greatest(1, least(coalesce(p_limit, 50), 200));
  p_offset := greatest(0, coalesce(p_offset, 0));

  with c as (
    select coalesce(normalized_phone, customer_phone) as phone,
           (array_agg(customer_name order by created_at desc))[1] as name,
           (array_agg(customer_wilaya order by created_at desc) filter (where customer_wilaya is not null))[1] as wilaya,
           count(*) as orders,
           count(*) filter (where status = 'completed') as completed,
           coalesce(sum(total) filter (where status in ('payment_confirmed','activating','needs_info','completed')), 0) as spent,
           max(created_at) as last_order_at,
           (array_agg(order_number order by created_at desc))[1] as last_order
      from orders
     where status <> 'awaiting_receipt'
     group by 1
  ), m as (
    select * from c
     where v_q is null
        or name ilike '%' || v_q || '%'
        or (v_d is not null and phone like '%' || v_d || '%')
  ), f as (select *, count(*) over () as total from m)
  select jsonb_build_object(
    'total', coalesce(max(total), 0),
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'phone', phone, 'name', name, 'wilaya', wilaya, 'orders', orders,
      'completed', completed, 'spent', spent, 'last_order_at', last_order_at,
      'last_order', last_order
    ) order by last_order_at desc), '[]'::jsonb))
  into v_out
  from (select * from f order by last_order_at desc limit p_limit offset p_offset) x;
  return v_out;
end $$;

-- ------------------------------------------------------------
-- 8. إعدادات المتجر — قراءة واحدة وكتابات محدودة
-- ------------------------------------------------------------
-- كل ما يغيّره المالك في إعدادات المتجر يمرّ من هنا لا من REST
-- مباشرة: الدالة تفحص الشكل (رقم واتساب، slug، سعر عرض) وترفع
-- رمز خطأ واضحاً، فلا يُحفظ إعداد نصف صالح يكسر صفحة الزبون.
create or replace function admin_store_config()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'NOT_ADMIN'; end if;
  return jsonb_build_object(
    'settings', (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from store_settings),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'name', c.name, 'slug', c.slug, 'accent_color', c.accent_color,
        'description', c.description, 'is_active', c.is_active, 'sort_order', c.sort_order,
        'products', (select count(*) from products p where p.category_id = c.id and p.archived_at is null)
      ) order by c.sort_order, c.name), '[]'::jsonb) from categories c),
    'payment_methods', (select coalesce(jsonb_agg(to_jsonb(m) - 'created_at' - 'updated_at'
        order by m.sort_order), '[]'::jsonb) from payment_methods m),
    'deals', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', d.id, 'product_id', d.product_id, 'plan_id', d.plan_id,
        'product_name', p.name, 'plan_name', pl.name, 'list_price', pl.price,
        'deal_price', d.deal_price, 'starts_at', d.starts_at, 'ends_at', d.ends_at,
        'is_active', d.is_active, 'sort_order', d.sort_order,
        'live', d.is_active and d.starts_at <= now() and d.ends_at > now()
      ) order by d.ends_at desc), '[]'::jsonb)
      from daily_deals d join products p on p.id = d.product_id
      join product_plans pl on pl.id = d.plan_id)
  );
end $$;

-- الإعدادات العامة: مفاتيح معروفة فقط، وكل واحد بشكله
create or replace function admin_save_settings(p_values jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare k text; v text; v_n int := 0;
begin
  if not is_admin() then raise exception 'NOT_ADMIN'; end if;
  for k, v in select key, value from jsonb_each_text(coalesce(p_values, '{}'::jsonb)) loop
    v := btrim(coalesce(v, ''));
    if k not in ('store_name','whatsapp_number','instagram_username','telegram_username',
                 'support_hours','support_message','site_url','max_active_orders') then
      raise exception 'UNKNOWN_SETTING:%', k;
    end if;
    if k = 'whatsapp_number' then
      v := regexp_replace(v, '[^0-9]', '', 'g');
      if v ~ '^0[567][0-9]{8}$' then v := '213' || substr(v, 2); end if;
      if v <> '' and v !~ '^[0-9]{10,15}$' then raise exception 'INVALID_WHATSAPP'; end if;
    elsif k in ('instagram_username','telegram_username') then
      v := regexp_replace(v, '^@', '');
      if v <> '' and v !~ '^[A-Za-z0-9._]{1,40}$' then raise exception 'INVALID_USERNAME:%', k; end if;
    elsif k = 'site_url' then
      v := regexp_replace(v, '/+$', '');
      if v <> '' and v !~ '^https://[^\s/]+(/[^\s]*)?$' then raise exception 'INVALID_SITE_URL'; end if;
    elsif k = 'max_active_orders' then
      if v !~ '^[0-9]{1,2}$' or v::int < 1 then raise exception 'INVALID_MAX_ACTIVE_ORDERS'; end if;
    elsif k = 'store_name' and v = '' then
      raise exception 'INVALID_STORE_NAME';
    end if;
    if char_length(v) > 300 then raise exception 'SETTING_TOO_LONG:%', k; end if;
    insert into store_settings (key, value, is_public) values (k, v, true)
      on conflict (key) do update set value = excluded.value, updated_at = now();
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('saved', v_n);
end $$;

create or replace function admin_upsert_category(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_slug text; v_name text;
begin
  if not is_admin() then raise exception 'NOT_ADMIN'; end if;
  v_name := btrim(coalesce(p->>'name', ''));
  v_slug := lower(btrim(coalesce(p->>'slug', '')));
  if v_name = '' or char_length(v_name) > 60 then raise exception 'INVALID_NAME'; end if;
  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then raise exception 'INVALID_SLUG'; end if;
  if coalesce(p->>'accent_color', '') !~ '^(#[0-9A-Fa-f]{6})?$' then raise exception 'INVALID_COLOR'; end if;

  if nullif(p->>'id', '') is null then
    insert into categories (name, slug, accent_color, description, is_active, sort_order)
    values (v_name, v_slug, nullif(p->>'accent_color', ''), nullif(btrim(coalesce(p->>'description','')), ''),
            coalesce((p->>'is_active')::boolean, true), coalesce((p->>'sort_order')::int, 0))
    returning id into v_id;
  else
    -- المعرّف لا يتغيّر: روابط القسم والمنتجات تعتمد عليه
    update categories set name = v_name,
           accent_color = nullif(p->>'accent_color', ''),
           description  = nullif(btrim(coalesce(p->>'description','')), ''),
           is_active    = coalesce((p->>'is_active')::boolean, is_active),
           sort_order   = coalesce((p->>'sort_order')::int, sort_order)
     where id = (p->>'id')::uuid
    returning id into v_id;
    if v_id is null then raise exception 'CATEGORY_NOT_FOUND'; end if;
  end if;
  return jsonb_build_object('id', v_id);
exception when unique_violation then raise exception 'SLUG_TAKEN';
end $$;

create or replace function admin_upsert_payment_method(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not is_admin() then raise exception 'NOT_ADMIN'; end if;
  if btrim(coalesce(p->>'label', '')) = '' then raise exception 'INVALID_LABEL'; end if;
  if nullif(p->>'id', '') is null then
    insert into payment_methods (type, label, account_holder, account_number, extra_info,
                                 instructions, is_active, sort_order)
    values ((p->>'type')::payment_method_type, btrim(p->>'label'),
            nullif(btrim(coalesce(p->>'account_holder','')), ''),
            nullif(btrim(coalesce(p->>'account_number','')), ''),
            nullif(btrim(coalesce(p->>'extra_info','')), ''),
            nullif(btrim(coalesce(p->>'instructions','')), ''),
            coalesce((p->>'is_active')::boolean, true), coalesce((p->>'sort_order')::int, 0))
    returning id into v_id;
  else
    update payment_methods set
      label          = btrim(p->>'label'),
      account_holder = nullif(btrim(coalesce(p->>'account_holder','')), ''),
      account_number = nullif(btrim(coalesce(p->>'account_number','')), ''),
      extra_info     = nullif(btrim(coalesce(p->>'extra_info','')), ''),
      instructions   = nullif(btrim(coalesce(p->>'instructions','')), ''),
      is_active      = coalesce((p->>'is_active')::boolean, is_active),
      sort_order     = coalesce((p->>'sort_order')::int, sort_order)
     where id = (p->>'id')::uuid
    returning id into v_id;
    if v_id is null then raise exception 'PAYMENT_METHOD_NOT_FOUND'; end if;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function admin_upsert_deal(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_start timestamptz; v_end timestamptz;
begin
  if not is_admin() then raise exception 'NOT_ADMIN'; end if;
  v_start := coalesce(nullif(p->>'starts_at', '')::timestamptz, now());
  v_end   := nullif(p->>'ends_at', '')::timestamptz;
  if v_end is null or v_end <= v_start then raise exception 'DEAL_INVALID_WINDOW'; end if;
  if coalesce((p->>'deal_price')::numeric, 0) <= 0 then raise exception 'DEAL_INVALID_PRICE'; end if;

  if nullif(p->>'id', '') is null then
    insert into daily_deals (product_id, plan_id, deal_price, starts_at, ends_at, is_active, sort_order)
    values ((p->>'product_id')::uuid, (p->>'plan_id')::uuid, (p->>'deal_price')::numeric,
            v_start, v_end, coalesce((p->>'is_active')::boolean, true), coalesce((p->>'sort_order')::int, 0))
    returning id into v_id;
  else
    update daily_deals set
      product_id = (p->>'product_id')::uuid, plan_id = (p->>'plan_id')::uuid,
      deal_price = (p->>'deal_price')::numeric, starts_at = v_start, ends_at = v_end,
      is_active  = coalesce((p->>'is_active')::boolean, is_active),
      sort_order = coalesce((p->>'sort_order')::int, sort_order)
     where id = (p->>'id')::uuid
    returning id into v_id;
    if v_id is null then raise exception 'DEAL_NOT_FOUND'; end if;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function admin_delete_deal(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'NOT_ADMIN'; end if;
  delete from daily_deals where id = p_id;
  if not found then raise exception 'DEAL_NOT_FOUND'; end if;
  return jsonb_build_object('deleted', p_id);
end $$;

-- ------------------------------------------------------------
-- 9. الصلاحيات
-- ------------------------------------------------------------
revoke all on function admin_bot_actor()                                   from public, anon;
revoke all on function admin_bot(text, jsonb)                              from public, anon;
revoke all on function admin_bot_sales(text, bigint, text, int, int)       from public, anon;
revoke all on function admin_bot_cards(uuid, text, int)                    from public, anon;
revoke all on function admin_bot_catalog()                                 from public, anon;
revoke all on function admin_bot_card_set(uuid, boolean)                   from public, anon;
revoke all on function admin_bot_summary()                                 from public, anon;
revoke all on function admin_site_certificates(text, int, int)             from public, anon;
revoke all on function admin_customers(text, int, int)                     from public, anon;
revoke all on function admin_store_config()                                from public, anon;
revoke all on function admin_save_settings(jsonb)                          from public, anon;
revoke all on function admin_upsert_category(jsonb)                        from public, anon;
revoke all on function admin_upsert_payment_method(jsonb)                  from public, anon;
revoke all on function admin_upsert_deal(jsonb)                            from public, anon;
revoke all on function admin_delete_deal(uuid)                             from public, anon;

grant execute on function admin_bot_actor()                                to authenticated;
grant execute on function admin_bot(text, jsonb)                           to authenticated;
grant execute on function admin_bot_sales(text, bigint, text, int, int)    to authenticated;
grant execute on function admin_bot_cards(uuid, text, int)                 to authenticated;
grant execute on function admin_bot_catalog()                              to authenticated;
grant execute on function admin_bot_card_set(uuid, boolean)                to authenticated;
grant execute on function admin_bot_summary()                              to authenticated;
grant execute on function admin_site_certificates(text, int, int)          to authenticated;
grant execute on function admin_customers(text, int, int)                  to authenticated;
grant execute on function admin_store_config()                             to authenticated;
grant execute on function admin_save_settings(jsonb)                       to authenticated;
grant execute on function admin_upsert_category(jsonb)                     to authenticated;
grant execute on function admin_upsert_payment_method(jsonb)               to authenticated;
grant execute on function admin_upsert_deal(jsonb)                         to authenticated;
grant execute on function admin_delete_deal(uuid)                          to authenticated;
