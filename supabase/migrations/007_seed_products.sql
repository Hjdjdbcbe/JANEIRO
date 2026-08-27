-- ============================================================
-- Janeiro Store — 007 seed
-- Migrates the CATEGORIES / PRODUCTS arrays that currently live in
-- janeiro-store-v4.html. Values are copied verbatim — nothing invented.
-- Idempotent: safe to re-run.
-- ============================================================

-- ---------- categories ----------
insert into categories (name, slug, accent_color, sort_order) values
  ('الذكاء الاصطناعي', 'ai',     '#7357FF', 1),
  ('التصميم والإبداع', 'design', '#EC4899', 2),
  ('الإنتاجية والعمل', 'work',   '#F59E0B', 3),
  ('التواصل',          'social', '#3478F6', 4),
  ('الترفيه',          'fun',    '#10B981', 5),
  ('التطوير',          'dev',    '#0EA5E9', 6)
on conflict (slug) do update
  set name = excluded.name,
      accent_color = excluded.accent_color,
      sort_order = excluded.sort_order;

-- ---------- payment methods ----------
-- Account details are intentionally blank: fill them from the
-- Supabase dashboard, they must never be committed to git.
-- Conflict target is the type: re-running must update, never duplicate.
-- account_holder / account_number / instructions are deliberately NOT
-- touched here, so a re-run never wipes details entered in the dashboard.
insert into payment_methods (type, label, sort_order, is_active) values
  ('ccp',       'CCP',        1, true),
  ('baridimob', 'BaridiMob',  2, true),
  ('flexy',     'Flexy',      3, true)
on conflict (type) do update
  set label = excluded.label,
      sort_order = excluded.sort_order;

-- ---------- products ----------
do $$
declare
  v_pid uuid;
  v_cat uuid;
begin
  ------------------------------------------------------------------
  -- ChatGPT Plus
  ------------------------------------------------------------------
  select id into v_cat from categories where slug = 'ai';
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, badge_type, badge_label, status, sort_order)
  values ('ChatGPT Plus','chatgpt-plus',v_cat,
    'وصول كامل لأحدث النماذج بسرعة استجابة أعلى.','#10A37F',
    'subscription_duration','hot','الأكثر طلباً','published',1)
  on conflict (slug) do update set short_description = excluded.short_description
  returning id into v_pid;

  delete from product_plans        where product_id = v_pid;
  delete from product_features     where product_id = v_pid;
  delete from product_requirements where product_id = v_pid;

  insert into product_plans (product_id, name, price, sort_order) values
    (v_pid,'شهر واحد',3200,1),(v_pid,'3 أشهر',9000,2);
  insert into product_features (product_id, label, sort_order) values
    (v_pid,'استخدام غير محدود للنماذج المتقدمة',1),
    (v_pid,'أولوية في أوقات الضغط',2),
    (v_pid,'تفعيل على حسابك الشخصي',3);
  insert into product_requirements (product_id, label, field_type, placeholder, sort_order) values
    (v_pid,'البريد الإلكتروني للحساب','email','name@example.com',1);

  ------------------------------------------------------------------
  -- Gemini Pro
  ------------------------------------------------------------------
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, badge_type, badge_label, status, sort_order)
  values ('Gemini Pro','gemini-pro',v_cat,
    'باقة Google المتقدمة للذكاء الاصطناعي مع مساحة تخزين.','#3478F6',
    'subscription_duration','hot','الأكثر طلباً','published',2)
  on conflict (slug) do update set short_description = excluded.short_description
  returning id into v_pid;

  delete from product_plans        where product_id = v_pid;
  delete from product_features     where product_id = v_pid;
  delete from product_requirements where product_id = v_pid;

  insert into product_plans (product_id, name, price, sort_order) values
    (v_pid,'شهر واحد',1900,1),(v_pid,'3 أشهر',4500,2),(v_pid,'12 شهراً',14000,3);
  insert into product_features (product_id, label, sort_order) values
    (v_pid,'نماذج Gemini المتقدمة',1),
    (v_pid,'تكامل مع تطبيقات Google',2),
    (v_pid,'مساحة تخزين إضافية',3);
  insert into product_requirements (product_id, label, field_type, placeholder, sort_order) values
    (v_pid,'بريد Gmail للتفعيل','email','name@gmail.com',1),
    (v_pid,'رقم الهاتف المرتبط','phone','0X XX XX XX XX',2);

  ------------------------------------------------------------------
  -- Canva Pro
  ------------------------------------------------------------------
  select id into v_cat from categories where slug = 'design';
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, status, sort_order)
  values ('Canva Pro','canva-pro',v_cat,
    'أدوات تصميم احترافية ومكتبة قوالب ضخمة.','#00C4CC',
    'subscription_duration','published',3)
  on conflict (slug) do update set short_description = excluded.short_description
  returning id into v_pid;

  delete from product_plans        where product_id = v_pid;
  delete from product_features     where product_id = v_pid;
  delete from product_requirements where product_id = v_pid;

  insert into product_plans (product_id, name, price, sort_order) values
    (v_pid,'شهر واحد',1200,1),(v_pid,'12 شهراً',9500,2);
  insert into product_features (product_id, label, sort_order) values
    (v_pid,'ملايين القوالب والعناصر',1),
    (v_pid,'إزالة الخلفية بنقرة',2),
    (v_pid,'مساحة تخزين للفرق',3);
  insert into product_requirements (product_id, label, field_type, placeholder, sort_order) values
    (v_pid,'البريد الإلكتروني للحساب','email','name@example.com',1);

  ------------------------------------------------------------------
  -- Adobe Creative Cloud
  ------------------------------------------------------------------
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, status, sort_order)
  values ('Adobe Creative Cloud','adobe-creative-cloud',v_cat,
    'حزمة أدوبي الكاملة للتصميم والمونتاج.','#DA1B2C',
    'subscription_duration','published',4)
  on conflict (slug) do update set short_description = excluded.short_description
  returning id into v_pid;

  delete from product_plans        where product_id = v_pid;
  delete from product_features     where product_id = v_pid;
  delete from product_requirements where product_id = v_pid;

  insert into product_plans (product_id, name, price, sort_order) values
    (v_pid,'شهر واحد',4800,1),(v_pid,'12 شهراً',38000,2);
  insert into product_features (product_id, label, sort_order) values
    (v_pid,'Photoshop وIllustrator وPremiere',1),
    (v_pid,'تحديثات مستمرة',2),
    (v_pid,'مساحة سحابية',3);
  insert into product_requirements (product_id, label, field_type, placeholder, sort_order) values
    (v_pid,'البريد الإلكتروني للحساب','email','name@example.com',1);

  ------------------------------------------------------------------
  -- Notion Plus
  ------------------------------------------------------------------
  select id into v_cat from categories where slug = 'work';
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, badge_type, badge_label, status, sort_order)
  values ('Notion Plus','notion-plus',v_cat,
    'مساحة عمل واحدة للملاحظات والمهام وقواعد البيانات.','#111318',
    'subscription_duration','new','جديد','published',5)
  on conflict (slug) do update set short_description = excluded.short_description
  returning id into v_pid;

  delete from product_plans        where product_id = v_pid;
  delete from product_features     where product_id = v_pid;
  delete from product_requirements where product_id = v_pid;

  insert into product_plans (product_id, name, price, sort_order) values
    (v_pid,'شهر واحد',1400,1),(v_pid,'12 شهراً',12000,2);
  insert into product_features (product_id, label, sort_order) values
    (v_pid,'رفع ملفات بلا حدود',1),
    (v_pid,'سجل نسخ أطول',2),
    (v_pid,'دعوة ضيوف',3);
  insert into product_requirements (product_id, label, field_type, placeholder, sort_order) values
    (v_pid,'البريد الإلكتروني للحساب','email','name@example.com',1);

  ------------------------------------------------------------------
  -- Discord Nitro
  ------------------------------------------------------------------
  select id into v_cat from categories where slug = 'social';
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, status, sort_order)
  values ('Discord Nitro','discord-nitro',v_cat,
    'مزايا إضافية للبث والرموز والملفات داخل ديسكورد.','#5865F2',
    'subscription_duration','published',6)
  on conflict (slug) do update set short_description = excluded.short_description
  returning id into v_pid;

  delete from product_plans        where product_id = v_pid;
  delete from product_features     where product_id = v_pid;
  delete from product_requirements where product_id = v_pid;

  insert into product_plans (product_id, name, price, sort_order) values
    (v_pid,'شهر واحد',1400,1),(v_pid,'12 شهراً',12000,2);
  insert into product_features (product_id, label, sort_order) values
    (v_pid,'بث بجودة أعلى',1),
    (v_pid,'رفع ملفات أكبر',2),
    (v_pid,'رموز مخصصة في كل السيرفرات',3);
  insert into product_requirements (product_id, label, field_type, placeholder, sort_order) values
    (v_pid,'اسم المستخدم في ديسكورد','username','username',1);

  ------------------------------------------------------------------
  -- Snapchat Plus  (the one product with a real discount)
  ------------------------------------------------------------------
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, badge_type, badge_label, status, sort_order)
  values ('Snapchat Plus','snapchat-plus',v_cat,
    'مزايا حصرية داخل سناب شات.','#F5A524',
    'subscription_duration','off','عرض','published',7)
  on conflict (slug) do update set short_description = excluded.short_description
  returning id into v_pid;

  delete from product_plans        where product_id = v_pid;
  delete from product_features     where product_id = v_pid;
  delete from product_requirements where product_id = v_pid;

  insert into product_plans (product_id, name, price, old_price, sort_order) values
    (v_pid,'شهر واحد',700,950,1),(v_pid,'12 شهراً',5500,null,2);
  insert into product_features (product_id, label, sort_order) values
    (v_pid,'مزايا حصرية للمشتركين',1),
    (v_pid,'تخصيص أيقونة التطبيق',2),
    (v_pid,'إحصاءات إضافية',3);
  insert into product_requirements (product_id, label, field_type, placeholder, sort_order) values
    (v_pid,'اسم المستخدم في سناب شات','username','@username',1);

  ------------------------------------------------------------------
  -- Spotify Premium
  ------------------------------------------------------------------
  select id into v_cat from categories where slug = 'fun';
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, status, sort_order)
  values ('Spotify Premium','spotify-premium',v_cat,
    'استماع بلا إعلانات وتحميل للاستماع دون اتصال.','#1DB954',
    'subscription_duration','published',8)
  on conflict (slug) do update set short_description = excluded.short_description
  returning id into v_pid;

  delete from product_plans        where product_id = v_pid;
  delete from product_features     where product_id = v_pid;
  delete from product_requirements where product_id = v_pid;

  insert into product_plans (product_id, name, price, sort_order) values
    (v_pid,'شهر واحد',1100,1),(v_pid,'3 أشهر',2900,2);
  insert into product_features (product_id, label, sort_order) values
    (v_pid,'بدون إعلانات',1),
    (v_pid,'تحميل للاستماع دون اتصال',2),
    (v_pid,'جودة صوت أعلى',3);
  insert into product_requirements (product_id, label, field_type, placeholder, sort_order) values
    (v_pid,'البريد الإلكتروني للحساب','email','name@example.com',1);

  ------------------------------------------------------------------
  -- Apple One  (coming soon — no plans, matches current frontend)
  ------------------------------------------------------------------
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, status, sort_order)
  values ('Apple One','apple-one',v_cat,
    'حزمة خدمات Apple في اشتراك واحد.','#3A3D46',
    'none','coming_soon',9)
  on conflict (slug) do update set status = excluded.status
  returning id into v_pid;

  ------------------------------------------------------------------
  -- GitHub Copilot
  ------------------------------------------------------------------
  select id into v_cat from categories where slug = 'dev';
  insert into products (name, slug, category_id, short_description, accent_color,
    warranty_type, status, sort_order)
  values ('GitHub Copilot','github-copilot',v_cat,
    'مساعد برمجي داخل محرر الأكواد.','#24292F',
    'subscription_duration','published',10)
  on conflict (slug) do update set short_description = excluded.short_description
  returning id into v_pid;

  delete from product_plans        where product_id = v_pid;
  delete from product_features     where product_id = v_pid;
  delete from product_requirements where product_id = v_pid;

  insert into product_plans (product_id, name, price, sort_order) values
    (v_pid,'شهر واحد',1600,1),(v_pid,'12 شهراً',14500,2);
  insert into product_features (product_id, label, sort_order) values
    (v_pid,'اقتراحات كود فورية',1),
    (v_pid,'دعم أغلب المحررات',2),
    (v_pid,'شرح وإصلاح الأخطاء',3);
  insert into product_requirements (product_id, label, field_type, placeholder, sort_order) values
    (v_pid,'اسم المستخدم في GitHub','username','username',1);
end $$;
