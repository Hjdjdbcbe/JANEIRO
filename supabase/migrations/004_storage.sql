-- ============================================================
-- Janeiro Store — 004 storage
-- product-media : PUBLIC read  (product posters/thumbnails)
-- receipts      : PRIVATE      (payment receipts, admin only)
-- ============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'product-media','product-media', true, 5242880,
  array['image/jpeg','image/png','image/webp','image/svg+xml']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'receipts','receipts', false, 5242880,
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ---------- product-media policies ----------
drop policy if exists "product media public read"   on storage.objects;
drop policy if exists "product media admin write"   on storage.objects;
drop policy if exists "product media admin update"  on storage.objects;
drop policy if exists "product media admin delete"  on storage.objects;

create policy "product media public read" on storage.objects
  for select using (bucket_id = 'product-media');

create policy "product media admin write" on storage.objects
  for insert with check (bucket_id = 'product-media' and is_admin());

create policy "product media admin update" on storage.objects
  for update using (bucket_id = 'product-media' and is_admin());

create policy "product media admin delete" on storage.objects
  for delete using (bucket_id = 'product-media' and is_admin());

-- ---------- receipts policies ----------
-- No public policy at all: anon/authenticated customers can neither
-- read nor list this bucket. Uploads go exclusively through the
-- upload-receipt Edge Function using the service role key.
drop policy if exists "receipts admin read"   on storage.objects;
drop policy if exists "receipts admin delete" on storage.objects;

create policy "receipts admin read" on storage.objects
  for select using (bucket_id = 'receipts' and is_admin());

create policy "receipts admin delete" on storage.objects
  for delete using (bucket_id = 'receipts' and is_admin());
