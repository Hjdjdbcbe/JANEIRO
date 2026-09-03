-- ============================================================
-- Janeiro Store — 020 warranty certificates
--
-- A printable warranty certificate, issued once per order item when
-- an order is marked completed (activation finished). It carries a
-- code that never repeats across customers, and that code alone is
-- what opens it — no login, so the customer can open, print or
-- forward the link themselves, and the admin can do the same from
-- the console.
--
-- Nothing here is a snapshot of its own: the certificate row only
-- keeps what cannot be derived later (its code, and the warranty
-- window computed once at issue time). Everything else — order
-- number, customer name, product/plan names, activation fields — is
-- read live from orders/order_items/order_activation_data through
-- get_certificate(), the same snapshot-at-order-time data the rest
-- of the store already relies on.
-- ============================================================

-- ---------- 1. the certificate itself ----------
create table if not exists warranty_certificates (
  id               uuid primary key default gen_random_uuid(),
  certificate_code text not null unique check (char_length(certificate_code) >= 12),
  order_item_id    uuid not null unique references order_items(id) on delete cascade,
  starts_at        timestamptz not null default now(),
  ends_at          timestamptz,
  created_at       timestamptz not null default now()
);
create index if not exists idx_cert_code on warranty_certificates(certificate_code);

alter table warranty_certificates enable row level security;
drop policy if exists "admin read certificates" on warranty_certificates;
create policy "admin read certificates" on warranty_certificates
  for select using (is_admin());
grant select on warranty_certificates to authenticated;
-- no anon policy: the public path is get_certificate() below, which
-- returns only what a certificate should show, never the raw row.

-- ---------- 2. a code that never repeats ----------
-- gen_random_uuid() rather than pgcrypto's gen_random_bytes(): it is
-- built into Postgres core (no extension needed), which is also why
-- every id column in this schema already uses it successfully.
-- gen_random_bytes() needs pgcrypto, and on a hosted Supabase project
-- that extension lives in the `extensions` schema -- invisible to a
-- SECURITY DEFINER function pinned to `search_path = public`, so it
-- failed there with "function gen_random_bytes(integer) does not
-- exist" even though the same call works in a plain local Postgres
-- where pgcrypto happened to install into public.
create or replace function generate_certificate_code()
returns text language plpgsql volatile as $$
declare candidate text;
begin
  for attempt in 1..20 loop
    candidate := 'JNR-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 14));
    if not exists (select 1 from warranty_certificates where certificate_code = candidate) then
      return candidate;
    end if;
  end loop;
  raise exception 'CERTIFICATE_CODE_GENERATION_FAILED';
end $$;

-- ---------- 3. issue certificates when an order completes ----------
-- Same function, same signature as 010_admin_orders.sql; the only
-- addition is the block after the status update. completed is only
-- ever entered once per order (the transition graph has no edge back
-- into it), so this naturally runs exactly once per order — the
-- "already has one" guard below is defence in depth, not the reason
-- it stays idempotent.
create or replace function admin_update_order_status(
  p_order_id   uuid,
  p_new_status order_status,
  p_note       text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_order orders%rowtype; v_old order_status;
  v_line  record; v_ends timestamptz;
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

  if p_new_status = 'completed' then
    for v_line in
      select oi.id as item_id, p.warranty_type, p.warranty_days,
             pl.duration_value, pl.duration_unit
        from order_items oi
        left join products p on p.id = oi.product_id
        left join product_plans pl on pl.id = oi.plan_id
       where oi.order_id = p_order_id
    loop
      -- nothing to certify without a warranty, and never issue a
      -- second certificate for the same line
      continue when v_line.warranty_type is null or v_line.warranty_type = 'none';
      continue when exists (
        select 1 from warranty_certificates where order_item_id = v_line.item_id
      );

      v_ends := case v_line.warranty_type
        when 'days' then now() + make_interval(days => coalesce(v_line.warranty_days, 0))
        when 'subscription_duration' then case v_line.duration_unit
          when 'day'   then now() + make_interval(days   => coalesce(v_line.duration_value, 0))
          when 'week'  then now() + make_interval(weeks  => coalesce(v_line.duration_value, 0))
          when 'month' then now() + make_interval(months => coalesce(v_line.duration_value, 0))
          when 'year'  then now() + make_interval(years  => coalesce(v_line.duration_value, 0))
          else null end
        -- 'activation' and 'custom' have no computable end date; the
        -- certificate shows the product's own warranty label instead.
        else null end;

      insert into warranty_certificates (certificate_code, order_item_id, starts_at, ends_at)
      values (generate_certificate_code(), v_line.item_id, now(), v_ends);
    end loop;
  end if;

  return jsonb_build_object(
    'order_id', v_order.id, 'order_number', v_order.order_number,
    'previous_status', v_old, 'status', v_order.status, 'changed', true
  );
end $$;

revoke all on function admin_update_order_status(uuid,order_status,text) from public, anon;
grant execute on function admin_update_order_status(uuid,order_status,text) to authenticated;

-- ---------- 4. the public, code-only lookup ----------
-- Deliberately asymmetric with track_order: track_order never returns
-- activation data because it is reached with only an order number and
-- a phone number, both guessable in bulk. A certificate code is a
-- 56-bit random token that is itself the credential — knowing it is
-- exactly the "hand the link to this one customer" bar the store
-- needs, the same trust model as any invoice/receipt link.
create or replace function get_certificate(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cert   warranty_certificates%rowtype;
  v_item   order_items%rowtype;
  v_order  orders%rowtype;
  v_fields jsonb;
begin
  if p_code is null or char_length(trim(p_code)) < 8 then
    raise exception 'CERTIFICATE_NOT_FOUND';
  end if;

  if not check_rate_limit(upper(trim(p_code)), 'certificate', 30, interval '10 minutes') then
    raise exception 'RATE_LIMITED';
  end if;

  select * into v_cert from warranty_certificates
   where certificate_code = upper(trim(p_code));
  if not found then raise exception 'CERTIFICATE_NOT_FOUND'; end if;

  select * into v_item from order_items where id = v_cert.order_item_id;
  select * into v_order from orders where id = v_item.order_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'label', field_label, 'value', field_value) order by created_at), '[]'::jsonb)
    into v_fields
    from order_activation_data where order_item_id = v_item.id;

  return jsonb_build_object(
    'certificate_code', v_cert.certificate_code,
    'order_number', v_order.order_number,
    'customer_name', v_order.customer_name,
    'product_name', v_item.product_name_snapshot,
    'plan_name', v_item.plan_name_snapshot,
    'warranty_label', v_item.warranty_label_snapshot,
    'activation_fields', v_fields,
    'starts_at', v_cert.starts_at,
    'ends_at', v_cert.ends_at,
    'issued_at', v_cert.created_at
  );
end $$;

revoke all on function get_certificate(text) from public, anon, authenticated;
grant execute on function get_certificate(text) to anon, authenticated;

-- ---------- 5. surface it on the customer's own tracking page ----------
-- Same function and signature as 018_order_updates.sql, plus a
-- certificate_code/ends_at per item (null when that item has none).
-- Not "activation data" in the sense track_order's own comment
-- guards against -- an opaque code is not the account information the
-- customer typed in, it is a link to their own certificate.
create or replace function track_order(p_order_number text, p_phone text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_order orders%rowtype; v_items jsonb; v_phone text; begin
  v_phone := normalize_dz_phone(p_phone);
  if p_order_number is null or v_phone is null then
    raise exception 'INVALID_TRACKING_INPUT';
  end if;

  if not check_rate_limit(upper(trim(p_order_number)), 'track', 10, interval '10 minutes') then
    raise exception 'RATE_LIMITED';
  end if;

  select * into v_order from orders
   where order_number = upper(trim(p_order_number))
     and normalized_phone = v_phone
     and status <> 'awaiting_receipt';

  if not found then raise exception 'ORDER_NOT_FOUND'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'name', oi.product_name_snapshot,
           'plan', oi.plan_name_snapshot,
           'quantity', oi.quantity,
           'certificate_code', wc.certificate_code,
           'certificate_ends_at', wc.ends_at)), '[]'::jsonb)
    into v_items
    from order_items oi
    left join warranty_certificates wc on wc.order_item_id = oi.id
   where oi.order_id = v_order.id;

  return jsonb_build_object(
    'order_number', v_order.order_number,
    'status', v_order.status,
    'status_label', case v_order.status
        when 'pending_payment_review' then 'مراجعة الدفع'
        when 'payment_confirmed'      then 'تم تأكيد الدفع'
        when 'activating'             then 'جاري التفعيل'
        when 'needs_info'             then 'نحتاج معلومات إضافية'
        when 'completed'              then 'مكتمل'
        when 'cancelled'              then 'ملغي'
        when 'refunded'               then 'تم الاسترجاع'
        else 'قيد المعالجة' end,
    'items', v_items,
    'created_at', v_order.created_at,
    'updated_at', v_order.updated_at
  );
end $$;

revoke all on function track_order(text,text) from public, anon, authenticated;
grant execute on function track_order(text,text) to anon, authenticated;

-- ---------- 6. where the storefront lives ----------
-- Used only to build the certificate link shown in the admin console
-- (get_certificate itself has no notion of a site — the frontend page
-- reads the ?cert= code straight from its own URL). Change this if
-- the store moves to a custom domain.
insert into store_settings (key, value, is_public) values
  ('site_url', 'https://janeiro-theta.vercel.app', true)
on conflict (key) do nothing;
