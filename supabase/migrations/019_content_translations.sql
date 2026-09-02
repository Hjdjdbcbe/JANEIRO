-- ============================================================
-- Janeiro Store — 019 content translations cache
--
-- Automatic machine translation for owner-authored catalogue text
-- (product names/descriptions, category names, bundle names) when a
-- customer picks French or English. Everything else on the
-- storefront is translated by hand in the frontend's own dictionary;
-- this table exists only for the text the store owner types in the
-- dashboard, which no dictionary can anticipate.
--
-- Keyed by (entity_type, entity_id, lang) rather than a hash of the
-- text: that lets a stale row be detected by comparing source_text to
-- the current value (the owner edited the product) rather than by
-- ever seeing the OLD text again to look it up.
--
-- Written only by the translate-content Edge Function, which holds
-- the DeepL key. No anon/authenticated access is needed or granted:
-- the function runs as the service role and returns translations
-- directly in its response, so the frontend never queries this table.
-- ============================================================

create table if not exists content_translations (
  id              uuid primary key default gen_random_uuid(),
  entity_type     text not null check (entity_type in
                    ('product_name','product_description','category_name',
                     'bundle_name','bundle_description')),
  entity_id       uuid not null,
  lang            text not null check (lang in ('fr','en')),
  source_text     text not null,
  translated_text text not null,
  updated_at      timestamptz not null default now(),
  unique (entity_type, entity_id, lang)
);
create index if not exists idx_translations_lookup
  on content_translations(entity_type, entity_id, lang);

alter table content_translations enable row level security;
-- no policies: service role bypasses RLS entirely; nobody else needs a row here.
