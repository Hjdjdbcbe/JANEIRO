-- ============================================================
-- ربط صور المنتجات بعد رفعها
--
-- ارفع أولاً محتوى assets/product-media/ إلى bucket product-media
-- بنفس المسارات، ثم شغّل هذا.
--
-- الصور بصيغة WebP لا PNG: البطاقات صور لامعة فوتوغرافية، وPNG
-- يضغطها بسوء شديد. البوستر الواحد كان 1.8 ميغابايت وصار ~100 كيلوبايت
-- بنفس المقاس والجودة، والأيقونة 320 كيلوبايت صارت 11. هذا فرق حقيقي
-- على اتصال جوّال جزائري، خصوصاً أن الأيقونات في مسار الرسم الأول.
--
-- الأيقونة مقصوصة من البطاقة نفسها: المربّع اللامع في وسطها هو
-- الأيقونة. لا شفافية فيها عمداً — المربّع يملأ الإطار من حافة إلى
-- حافة، والمدار يطبّق استدارته الخاصة.
-- ============================================================

update products set poster_path = 'products/canva-pro.webp',
                    icon_path   = 'products/icons/canva-pro.webp',
                    accent_color = '#0BCAD5' where slug = 'canva-pro';

update products set poster_path = 'products/snapchat-plus.webp',
                    icon_path   = 'products/icons/snapchat-plus.webp',
                    accent_color = '#F8DE01' where slug = 'snapchat-plus';

update products set poster_path = 'products/notion-plus.webp',
                    icon_path   = 'products/icons/notion-plus.webp' where slug = 'notion-plus';

-- Claude Pro منتج جديد. اسمه وتصنيفه ولونه من البطاقة نفسها.
-- سعره غير معروف، فيدخل coming_soon بلا خطط — لا سعر مُخترع.
-- لتفعيله: أضف خططه في product_plans ثم status = 'published'.
insert into products (name, slug, category_id, short_description, accent_color,
                      warranty_type, status, sort_order)
select 'Claude Pro', 'claude-pro', c.id,
       'وصول موسّع لنماذج Claude بحدود استخدام أعلى.', '#F27F41',
       'subscription_duration', 'coming_soon', 11
  from categories c where c.slug = 'ai'
on conflict (slug) do update set
  short_description = excluded.short_description,
  accent_color      = excluded.accent_color;

update products set poster_path = 'products/claude-pro.webp',
                    icon_path   = 'products/icons/claude-pro.webp' where slug = 'claude-pro';

-- منتجان جديدان وصلت بطاقتاهما. نفس قاعدة Claude Pro بالضبط:
-- الاسم والتصنيف واللون من البطاقة، ولا سعر ولا خطة — لأن السعر لم
-- يُعطَ، واختراعه يجعل المتجر يعد بما لا يعرفه. يدخلان coming_soon
-- ويظهران في المتجر بلا زر شراء حتى تُضاف خططهما.
insert into products (name, slug, category_id, short_description, accent_color,
                      warranty_type, status, sort_order)
select 'PlayStation Gift Card', 'playstation-gift-card', c.id,
       'رصيد لمتجر PlayStation لشراء الألعاب والاشتراكات.', '#06479B',
       'none', 'coming_soon', 12
  from categories c where c.slug = 'fun'
on conflict (slug) do update set
  short_description = excluded.short_description,
  accent_color      = excluded.accent_color;

update products set poster_path = 'products/playstation-gift-card.webp',
                    icon_path   = 'products/icons/playstation-gift-card.webp'
 where slug = 'playstation-gift-card';

insert into products (name, slug, category_id, short_description, accent_color,
                      warranty_type, status, sort_order)
select 'n8n', 'n8n', c.id,
       'منصّة أتمتة سير العمل وربط التطبيقات ببعضها.', '#EA5666',
       'subscription_duration', 'coming_soon', 13
  from categories c where c.slug = 'dev'
on conflict (slug) do update set
  short_description = excluded.short_description,
  accent_color      = excluded.accent_color;

update products set poster_path = 'products/n8n.webp',
                    icon_path   = 'products/icons/n8n.webp' where slug = 'n8n';
