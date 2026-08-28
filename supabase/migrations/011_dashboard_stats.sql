-- ============================================================
-- Janeiro Store — 011 dashboard figures
--
-- One admin-only call for the overview screen, so the dashboard makes
-- a single round trip instead of a dozen.
--
-- What counts as revenue, stated once here rather than implied in the
-- UI: an order counts from the moment its payment is confirmed, and
-- stops counting if it is refunded. Orders still awaiting a receipt or
-- under payment review are NOT revenue -- they are not money yet, and
-- showing them as such would flatter the number.
-- ============================================================

create or replace function admin_dashboard_stats()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_earned constant order_status[] :=
    array['payment_confirmed','activating','needs_info','completed']::order_status[];
  v_actionable constant order_status[] :=
    array['pending_payment_review','payment_confirmed','activating','needs_info']::order_status[];
  v jsonb;
begin
  if not is_admin() then raise exception 'NOT_AUTHORIZED'; end if;

  select jsonb_build_object(

    -- ---------- today, and the same figure yesterday to compare ----------
    'today', (
      select jsonb_build_object(
        'orders',  count(*) filter (where submitted_at >= current_date),
        'revenue', coalesce(sum(total) filter (
                     where submitted_at >= current_date and status = any(v_earned)), 0),
        'completed', count(*) filter (
                     where submitted_at >= current_date and status = 'completed'))
        from orders),

    'yesterday', (
      select jsonb_build_object(
        'orders',  count(*) filter (
                     where submitted_at >= current_date - 1 and submitted_at < current_date),
        'revenue', coalesce(sum(total) filter (
                     where submitted_at >= current_date - 1 and submitted_at < current_date
                       and status = any(v_earned)), 0))
        from orders),

    'week', (
      select jsonb_build_object(
        'orders',  count(*) filter (where submitted_at >= current_date - 6),
        'revenue', coalesce(sum(total) filter (
                     where submitted_at >= current_date - 6 and status = any(v_earned)), 0))
        from orders),

    -- ---------- what is waiting on you right now ----------
    'needs_you', (
      select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
        from (select status::text as status, count(*) as n
                from orders where status = any(v_actionable)
               group by status) s),

    'oldest_waiting_hours', (
      select round(extract(epoch from (now() - min(submitted_at))) / 3600)
        from orders where status = 'pending_payment_review'),

    -- ---------- a seven-day sparkline, one row per day, zeros included ----------
    'daily', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'day', d::date, 'orders', o.n, 'revenue', o.rev) order by d), '[]'::jsonb)
        from generate_series(current_date - 6, current_date, interval '1 day') d
        left join lateral (
          select count(*) as n,
                 coalesce(sum(total) filter (where status = any(v_earned)), 0) as rev
            from orders
           where submitted_at >= d and submitted_at < d + interval '1 day') o on true),

    -- ---------- what actually sells, last 30 days ----------
    'top_products', (
      select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select i.product_name_snapshot as name,
               sum(i.quantity)::int    as sold,
               sum(i.total_price)      as revenue
          from order_items i
          join orders o on o.id = i.order_id
         where o.submitted_at >= current_date - 29
           and o.status = any(v_earned)
         group by i.product_name_snapshot
         order by sum(i.total_price) desc
         limit 5) t),

    -- ---------- lifetime, for context ----------
    'totals', (
      select jsonb_build_object(
        'orders',    count(*),
        'customers', count(distinct normalized_phone),
        'revenue',   coalesce(sum(total) filter (where status = any(v_earned)), 0),
        'refunded',  coalesce(sum(total) filter (where status = 'refunded'), 0))
        from orders where status <> 'awaiting_receipt')

  ) into v;
  return v;
end $$;

revoke all on function admin_dashboard_stats() from public, anon;
grant execute on function admin_dashboard_stats() to authenticated;
