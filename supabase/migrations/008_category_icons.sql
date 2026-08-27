-- ============================================================
-- Janeiro Store — 008 category icon assets
--
-- Mirrors products.poster_path: the column holds a path inside the
-- PUBLIC product-media bucket, not a URL. The frontend builds the URL,
-- so moving buckets or domains never touches the data.
--
-- Empty is the normal state. A category without an icon renders the
-- designed fallback, so this is additive and breaks nothing.
--
-- ASSET SPEC — what to upload:
--   size   : 128x128 px
--   format : PNG with a transparent background (or WebP)
--   why    : the icon renders at 28px in the category chips and 34px in
--            the side menu; 128px covers those at up to ~3.8x DPR with
--            room for larger placements later.
--   bucket : product-media  (public read, see migration 004)
--   path   : categories/<slug>.png   e.g. categories/ai.png
--
--   Keep the artwork inside a ~112px safe area so it does not collide
--   with the tile's rounded corners, and make it legible on a dark
--   ground -- the tile behind it is a low-opacity tint, not a solid.
-- ============================================================

alter table categories add column if not exists icon_path text;

comment on column categories.icon_path is
  'Path inside the public product-media bucket, e.g. categories/ai.png. '
  '128x128 transparent PNG. NULL renders the designed fallback icon.';
