-- ============================================================
-- Janeiro Store — 003 orders
-- ============================================================

create table if not exists orders (
  id                 uuid primary key default gen_random_uuid(),
  order_number       text not null unique,

  customer_name      text not null check (char_length(customer_name) between 2 and 80),
  customer_phone     text not null check (char_length(customer_phone) between 6 and 20),
  normalized_phone   text not null check (normalized_phone ~ '^213[5-7][0-9]{8}$'),
  customer_wilaya    text check (char_length(customer_wilaya) <= 60),

  payment_method_id  uuid references payment_methods(id) on delete restrict,
  payment_reference  text check (char_length(payment_reference) <= 60),

  receipt_path       text,
  receipt_uploaded_at timestamptz,

  subtotal           numeric(12,2) not null default 0 check (subtotal >= 0),
  total              numeric(12,2) not null default 0 check (total >= 0),
  currency           text not null default 'دج',

  status             order_status not null default 'awaiting_receipt',
  idempotency_key    text not null unique check (char_length(idempotency_key) between 8 and 100),

  client_ip          inet,
  submitted_at       timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  -- §27 invariant, enforced at database level:
  -- an order past awaiting_receipt MUST carry a receipt.
  constraint receipt_required_after_submit check (
    status = 'awaiting_receipt'
    or status in ('cancelled')
    or (receipt_path is not null and receipt_uploaded_at is not null)
  ),
  constraint submitted_at_set check (
    status = 'awaiting_receipt' or status = 'cancelled' or submitted_at is not null
  ),
  constraint receipt_pair check (
    (receipt_path is null) = (receipt_uploaded_at is null)
  )
);
create index if not exists idx_orders_phone_status on orders(normalized_phone, status);
create index if not exists idx_orders_status       on orders(status, created_at desc);
create index if not exists idx_orders_number       on orders(order_number);
drop trigger if exists trg_orders_updated on orders;
create trigger trg_orders_updated before update on orders
  for each row execute function set_updated_at();

-- ---------- order items (with snapshots) ----------
create table if not exists order_items (
  id                     uuid primary key default gen_random_uuid(),
  order_id               uuid not null references orders(id) on delete cascade,
  product_id             uuid references products(id) on delete set null,
  plan_id                uuid references product_plans(id) on delete set null,

  product_name_snapshot  text not null,
  plan_name_snapshot     text not null,
  unit_price             numeric(12,2) not null check (unit_price >= 0),
  quantity               integer not null check (quantity between 1 and 10),
  total_price            numeric(12,2) not null check (total_price >= 0),
  warranty_label_snapshot text,
  created_at             timestamptz not null default now()
);
create index if not exists idx_items_order on order_items(order_id);

-- ---------- activation data (private) ----------
create table if not exists order_activation_data (
  id            uuid primary key default gen_random_uuid(),
  order_item_id uuid not null references order_items(id) on delete cascade,
  field_label   text not null check (char_length(field_label) <= 120),
  field_type    requirement_field_type not null default 'text',
  field_value   text not null check (char_length(field_value) between 1 and 300),
  created_at    timestamptz not null default now()
);
create index if not exists idx_activation_item on order_activation_data(order_item_id);

-- ---------- status history ----------
create table if not exists order_status_history (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null references orders(id) on delete cascade,
  old_status order_status,
  new_status order_status not null,
  changed_by uuid references auth.users(id) on delete set null,
  note       text check (char_length(note) <= 400),
  created_at timestamptz not null default now()
);
create index if not exists idx_history_order on order_status_history(order_id, created_at desc);

create or replace function log_order_status()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into order_status_history(order_id, old_status, new_status, changed_by)
    values (new.id, null, new.status, auth.uid());
  elsif new.status is distinct from old.status then
    insert into order_status_history(order_id, old_status, new_status, changed_by)
    values (new.id, old.status, new.status, auth.uid());
  end if;
  return new;
end $$;

drop trigger if exists trg_order_status_ins on orders;
create trigger trg_order_status_ins after insert on orders
  for each row execute function log_order_status();
drop trigger if exists trg_order_status_upd on orders;
create trigger trg_order_status_upd after update of status on orders
  for each row execute function log_order_status();

-- ---------- notification logs ----------
create table if not exists order_notifications (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references orders(id) on delete cascade,
  channel       text not null check (channel in ('telegram')),
  status        text not null check (status in ('sent','failed','retrying')),
  error_message text check (char_length(error_message) <= 1000),
  created_at    timestamptz not null default now()
);
create index if not exists idx_notif_order on order_notifications(order_id, created_at desc);

-- ---------- rate limiting ----------
-- one row per (key, action) bucket; pruned by the check function itself.
create table if not exists rate_limits (
  id         bigserial primary key,
  bucket_key text not null,
  action     text not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_rate on rate_limits(bucket_key, action, created_at desc);
