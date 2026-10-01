-- ============================================================
-- Janeiro Store — 036 نصوص الموقع من اللوحة
--
-- كل نص في واجهة المتجر (العناوين، الأزرار، الأسئلة، صفحة «شكون
-- حنا»، السياسات...) معرَّف بمفتاح في قاموس I18N داخل
-- frontend/index.html، بثلاث لغات: ar و fr و en. ذاك القاموس يبقى
-- هو الأصل؛ هذا الجدول يحمل **التعديلات فقط**: صف لكل نص بدّله
-- المالك في لغة معيّنة. الموقع يقرأ الجدول عند التحميل ويركّب
-- التعديلات فوق القاموس، وكل مفتاح ما تبدّلش يبقى كما في الكود.
--
-- فحذف الصف = الرجوع للنص الأصلي. ولا يلزم نسخ 270 نصاً هنا،
-- ولا يضيع نص جديد يُضاف للكود لاحقاً.
--
-- القراءة للجميع (هي نصوص منشورة على الموقع أصلاً)، والكتابة
-- لا تمرّ إلا بـ admin_set_site_texts التي تفحص is_admin().
-- ============================================================

-- ------------------------------------------------------------
-- 1. الجدول
-- ------------------------------------------------------------
create table if not exists site_texts (
  key        text not null check (key ~ '^[a-z][a-z0-9_]{0,63}$'),
  lang       text not null check (lang in ('ar', 'fr', 'en')),
  value      text not null check (length(value) between 1 and 4000),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  primary key (key, lang)
);

alter table site_texts enable row level security;

drop policy if exists "public read site texts" on site_texts;
create policy "public read site texts" on site_texts for select using (true);

revoke all on site_texts from anon, authenticated;
grant select (key, lang, value) on site_texts to anon, authenticated;

-- ------------------------------------------------------------
-- 2. الكتابة: دفعة من التعديلات في معاملة واحدة
--    p_items: [{ "key": "hero_title", "lang": "ar", "value": "..." }, ...]
--    قيمة فارغة أو null = حذف التعديل والرجوع للأصل.
-- ------------------------------------------------------------
create or replace function admin_set_site_texts(p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  it jsonb; k text; l text; v text;
  n_set int := 0; n_reset int := 0;
begin
  if not is_admin() then raise exception 'NOT_ADMIN'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' then raise exception 'INVALID_ITEMS'; end if;
  if jsonb_array_length(p_items) > 500 then raise exception 'TOO_MANY_ITEMS'; end if;

  for it in select * from jsonb_array_elements(p_items) loop
    k := it->>'key'; l := it->>'lang'; v := btrim(coalesce(it->>'value', ''));
    if k is null or k !~ '^[a-z][a-z0-9_]{0,63}$' then raise exception 'INVALID_KEY: %', coalesce(k, 'null'); end if;
    if l is null or l not in ('ar', 'fr', 'en') then raise exception 'INVALID_LANG: %', coalesce(l, 'null'); end if;
    if length(v) > 4000 then raise exception 'TEXT_TOO_LONG: %', k; end if;

    if v = '' then
      delete from site_texts where key = k and lang = l;
      if found then n_reset := n_reset + 1; end if;
    else
      insert into site_texts (key, lang, value, updated_at, updated_by)
      values (k, l, v, now(), auth.uid())
      on conflict (key, lang) do update
        set value = excluded.value, updated_at = now(), updated_by = auth.uid();
      n_set := n_set + 1;
    end if;
  end loop;

  return jsonb_build_object('saved', n_set, 'reset', n_reset,
                            'total', (select count(*) from site_texts));
end $$;

-- ------------------------------------------------------------
-- 3. الصلاحيات
-- ------------------------------------------------------------
revoke all on function admin_set_site_texts(jsonb) from public, anon;
grant execute on function admin_set_site_texts(jsonb) to authenticated;
