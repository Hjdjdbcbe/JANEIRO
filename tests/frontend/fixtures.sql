-- ============================================================
-- Fixtures for the browser tests.
--
-- Everything here is store configuration a real owner would enter,
-- not invented catalogue data: a WhatsApp number, payment account
-- details, two category icon paths and two live deals.
--
--   psql -d janeiro_test -f tests/frontend/fixtures.sql
-- ============================================================

update store_settings set value = '213555123456' where key = 'whatsapp_number';

update payment_methods
   set account_holder = 'محمد ب.',
       account_number = '0012345678 12',
       instructions   = 'حوّل المبلغ ثم ارفع صورة الوصل.'
 where type = 'ccp';
update payment_methods
   set account_holder = 'محمد ب.', account_number = '007999888777666'
 where type = 'baridimob';
update payment_methods set account_number = '0555112233' where type = 'flexy';

-- One category with an icon that resolves, one pointing at an asset
-- that does not exist, so the onerror fallback is exercised.
update categories set icon_path = 'categories/ai.png'      where slug = 'ai';
update categories set icon_path = 'categories/missing.png' where slug = 'design';

-- Two live deals: one ending inside a day, one beyond it, so the
-- countdown covers both the HH:MM:SS and the "N أيام" formats.
delete from daily_deals;
insert into daily_deals (product_id, plan_id, deal_price, starts_at, ends_at, sort_order)
select p.id, pl.id, round(pl.price * 0.70, 2), now() - interval '1 hour', now() + interval '8 hours', 1
  from products p join product_plans pl on pl.product_id = p.id
 where p.slug = 'spotify-premium' and pl.sort_order = 1;

insert into daily_deals (product_id, plan_id, deal_price, starts_at, ends_at, sort_order)
select p.id, pl.id, round(pl.price * 0.80, 2), now() - interval '2 hours', now() + interval '30 hours', 2
  from products p join product_plans pl on pl.product_id = p.id
 where p.slug = 'notion-plus' and pl.sort_order = 1;

delete from orders;
delete from rate_limits;
