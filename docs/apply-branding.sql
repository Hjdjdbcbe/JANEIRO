-- ============================================================
-- ربط بوسترات المنتجات بعد رفعها
--
-- ارفع أولاً محتوى assets/product-media/ إلى bucket product-media
-- بنفس المسارات، ثم شغّل هذا.
-- ============================================================

update products set poster_path = 'products/canva-pro.png',     accent_color = '#0BCAD5' where slug = 'canva-pro';
update products set poster_path = 'products/snapchat-plus.png', accent_color = '#F9E002' where slug = 'snapchat-plus';

-- Claude Pro منتج جديد. اسمه وتصنيفه ولونه من البطاقة نفسها.
-- سعره غير معروف، فيدخل coming_soon بلا خطط — لا سعر مُخترع.
-- لتفعيله: أضف خططه في product_plans ثم status = 'published'.
insert into products (name, slug, category_id, short_description, accent_color,
                      warranty_type, status, sort_order)
select 'Claude Pro', 'claude-pro', c.id,
       'وصول موسّع لنماذج Claude بحدود استخدام أعلى.', '#F17E40',
       'subscription_duration', 'coming_soon', 11
  from categories c where c.slug = 'ai'
on conflict (slug) do update set
  short_description = excluded.short_description,
  accent_color      = excluded.accent_color;

update products set poster_path = 'products/claude-pro.png' where slug = 'claude-pro';
