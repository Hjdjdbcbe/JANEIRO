-- ============================================================
-- Local Supabase-compatible shim.
-- Recreates the parts of a hosted Supabase project that the
-- migrations depend on: the auth/storage schemas, the anon /
-- authenticated / service_role roles, and Supabase's default
-- privileges on the public schema.
-- NOT a production migration — test harness only.
-- ============================================================

create extension if not exists "pgcrypto";

-- ---------- roles ----------
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then
    create role anon nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then
    create role authenticated nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then
    create role service_role nologin noinherit bypassrls; end if;
end $$;

-- ---------- auth schema ----------
create schema if not exists auth;

create table if not exists auth.users (
  id    uuid primary key default gen_random_uuid(),
  email text
);

-- Supabase reads the request JWT out of a GUC. The shim mirrors that
-- so `set local request.jwt.claims` drives auth.uid() in tests.
create or replace function auth.jwt() returns jsonb
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), ''),
    '{}'
  )::jsonb;
$$;

create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid;
$$;

create or replace function auth.role() returns text
language sql stable as $$
  select coalesce(auth.jwt() ->> 'role', current_setting('role', true));
$$;

-- ---------- storage schema ----------
create schema if not exists storage;

create table if not exists storage.buckets (
  id                 text primary key,
  name               text not null unique,
  public             boolean not null default false,
  file_size_limit    bigint,
  allowed_mime_types text[],
  created_at         timestamptz not null default now()
);

create table if not exists storage.objects (
  id           uuid primary key default gen_random_uuid(),
  bucket_id    text references storage.buckets(id),
  name         text not null,
  owner        uuid,
  metadata     jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
alter table storage.objects enable row level security;

-- ---------- Supabase's standard grants ----------
grant usage on schema public  to anon, authenticated, service_role;
grant usage on schema auth    to anon, authenticated, service_role;
grant usage on schema storage to anon, authenticated, service_role;

grant all on all tables    in schema public to anon, authenticated, service_role;
grant all on all sequences in schema public to anon, authenticated, service_role;
grant all on all tables    in schema storage to anon, authenticated, service_role;
grant execute on all functions in schema auth to anon, authenticated, service_role;

-- Objects created by the migrations that follow inherit these.
alter default privileges in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public
  grant execute on functions to anon, authenticated, service_role;
