-- ============================================================
-- Janeiro Store — 010 admin order handling
--
-- Until now nothing could move an order forward. completed, cancelled
-- and refunded were reachable only by editing the table by hand, which
-- meant the customer's tracking page could never show them.
--
-- The rules live in a table rather than in a CASE block, so the legal
-- lifecycle is data you can read and change without touching code.
-- ============================================================

-- ------------------------------------------------------------
-- Which moves are legal. Absent pair = refused.
--
-- awaiting_receipt and pending_payment_review are customer-flow states
-- reached by create_order and submit_order; an admin can only cancel
-- out of the first, never assign either. cancelled and refunded are
-- terminal, so they appear as a source nowhere below.
-- ------------------------------------------------------------
create table if not exists order_status_transitions (
  from_status order_status not null,
  to_status   order_status not null,
  primary key (from_status, to_status)
);

insert into order_status_transitions (from_status, to_status) values
  -- the customer never paid: the only way out is to drop it
  ('awaiting_receipt',       'cancelled'),

  -- you have the receipt in hand and are judging it
  ('pending_payment_review', 'payment_confirmed'),
  ('pending_payment_review', 'needs_info'),
  ('pending_payment_review', 'cancelled'),

  -- money is good, now fulfil
  ('payment_confirmed',      'activating'),
  ('payment_confirmed',      'needs_info'),
  ('payment_confirmed',      'cancelled'),
  ('payment_confirmed',      'refunded'),

  ('activating',             'completed'),
  ('activating',             'needs_info'),
  ('activating',             'cancelled'),
  ('activating',             'refunded'),

  -- waiting on the customer; resumes wherever it left off
  ('needs_info',             'payment_confirmed'),
  ('needs_info',             'activating'),
  ('needs_info',             'cancelled'),
  ('needs_info',             'refunded'),

  -- a warranty case or a late dispute after delivery
  ('completed',              'refunded')
on conflict do nothing;

alter table order_status_transitions enable row level security;
drop policy if exists "admin read transitions" on order_status_transitions;
create policy "admin read transitions" on order_status_transitions
  for select using (is_admin());
grant select on order_status_transitions to authenticated;

-- ------------------------------------------------------------
-- Carry the admin's reason into the history row. The trigger writes
-- that row, so the note is handed over through a transaction-local
-- setting rather than by updating the row afterwards.
-- ------------------------------------------------------------
create or replace function log_order_status()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_note text;
begin
  v_note := nullif(current_setting('janeiro.status_note', true), '');
  if tg_op = 'INSERT' then
    insert into order_status_history(order_id, old_status, new_status, changed_by, note)
    values (new.id, null, new.status, auth.uid(), v_note);
  elsif new.status is distinct from old.status then
    insert into order_status_history(order_id, old_status, new_status, changed_by, note)
    values (new.id, old.status, new.status, auth.uid(), v_note);
  end if;
  return new;
end $$;

-- ------------------------------------------------------------
-- The one way an order moves. Admins only, one legal step at a time.
-- ------------------------------------------------------------
create or replace function admin_update_order_status(
  p_order_id   uuid,
  p_new_status order_status,
  p_note       text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_order orders%rowtype; v_old order_status;
begin
  if not is_admin() then
    raise exception 'NOT_AUTHORIZED';
  end if;
  if p_note is not null and char_length(p_note) > 400 then
    raise exception 'NOTE_TOO_LONG';
  end if;

  -- Lock the row: two staff opening the same order must not both move it.
  select * into v_order from orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;

  v_old := v_order.status;

  -- Re-applying the current status is a no-op, not an error: a double
  -- click on the same button should be harmless.
  if v_old = p_new_status then
    return jsonb_build_object(
      'order_id', v_order.id, 'order_number', v_order.order_number,
      'status', v_old, 'changed', false
    );
  end if;

  if not exists (
    select 1 from order_status_transitions
     where from_status = v_old and to_status = p_new_status
  ) then
    raise exception 'INVALID_STATUS_TRANSITION:% -> %', v_old, p_new_status;
  end if;

  perform set_config('janeiro.status_note', coalesce(p_note, ''), true);

  update orders set status = p_new_status where id = p_order_id
  returning * into v_order;

  return jsonb_build_object(
    'order_id', v_order.id, 'order_number', v_order.order_number,
    'previous_status', v_old, 'status', v_order.status, 'changed', true
  );
end $$;

-- ------------------------------------------------------------
-- Queue counts for the console header.
-- ------------------------------------------------------------
create or replace function admin_order_counts()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not is_admin() then raise exception 'NOT_AUTHORIZED'; end if;
  select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) into v
    from (select status::text as status, count(*) as n from orders group by status) s;
  return v;
end $$;

revoke all on function admin_update_order_status(uuid,order_status,text) from public, anon;
revoke all on function admin_order_counts()                              from public, anon;
grant execute on function admin_update_order_status(uuid,order_status,text) to authenticated;
grant execute on function admin_order_counts()                              to authenticated;
