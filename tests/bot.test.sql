-- ============================================================
-- Janeiro Store — اختبارات بوت المخزون (021)
--   psql "$DATABASE_URL" -f tests/bot.test.sql
-- كل تأكيد يرفع خطأ عند فشله، فالتشغيل النظيف = نجاح الكل.
-- لا شيء يُحفظ: الملف كله داخل معاملة تُلغى في آخره.
-- ============================================================

begin;

do $$
declare
  v_owner_tg  constant bigint := 900000001;
  v_a_tg      constant bigint := 900000002;
  v_b_tg      constant bigint := 900000003;
  v_ghost_tg  constant bigint := 900000009;
  v_prod   uuid;
  v_year   uuid;
  v_three  uuid;
  v_res    jsonb;
  v_res2   jsonb;
  v_issue  uuid;
  v_issue2 uuid;
  v_code   text;
  v_n      int;
  v_ok     boolean;
begin
  -- ========== الإقلاع: المالك الأول ==========
  v_res := bot_bootstrap_owner(v_owner_tg, 'owner_user', 'المالك');
  assert v_res->>'role' = 'owner', 'bootstrap: first contact becomes owner';
  -- تشغيله مرتين لا ينشئ مالكين
  v_res := bot_bootstrap_owner(v_owner_tg, 'owner_user', 'المالك');
  select count(*) into v_n from bot_admins where telegram_id = v_owner_tg;
  assert v_n = 1, 'bootstrap: idempotent';
  raise notice 'PASS  bootstrap owner';

  -- ========== الهوية ==========
  assert (bot_identify(v_ghost_tg) ->> 'known')::boolean = false,
         'identify: stranger is unknown';
  assert (bot_identify(v_owner_tg, 'owner_user', 'المالك') ->> 'role') = 'owner',
         'identify: owner known as owner';
  begin
    perform bot_catalog(v_ghost_tg);
    assert false, 'stranger reached the catalogue';
  exception when others then
    assert sqlerrm like 'NOT_AUTHORIZED%', 'stranger rejected with NOT_AUTHORIZED, got: ' || sqlerrm;
  end;
  raise notice 'PASS  غير المسجَّل لا يرى شيئاً';

  -- ========== إضافة أدمن ==========
  perform bot_add_admin(v_owner_tg, v_a_tg, 'بائع أ');
  perform bot_add_admin(v_owner_tg, v_b_tg, 'بائع ب');
  assert (bot_identify(v_a_tg) ->> 'role') = 'admin', 'added admin has role admin';

  -- أدمن عادي لا يضيف أدمن
  begin
    perform bot_add_admin(v_a_tg, 900000099, 'دخيل');
    assert false, 'plain admin added an admin';
  exception when others then
    assert sqlerrm like 'NOT_OWNER%', 'plain admin blocked, got: ' || sqlerrm;
  end;
  raise notice 'PASS  إدارة الأدمن للمالك وحده';

  -- ========== البذرة: منتج واحد بمدّتين ==========
  select id into v_prod  from bot_products where code = 'giftcard';
  select id into v_year  from bot_variants where product_id = v_prod and code = 'year';
  select id into v_three from bot_variants where product_id = v_prod and code = '3months';
  assert v_year is not null and v_three is not null, 'seed: سنة و 3 أشهر موجودتان';
  raise notice 'PASS  البذرة: بطاقة بمدّتين';

  -- ========== شحن المخزون ==========
  v_res := bot_add_cards(v_owner_tg, v_year, array['Y-AAA','Y-BBB','Y-CCC']);
  assert (v_res->>'added')::int = 3,     'add_cards: 3 added';
  assert (v_res->>'available')::int = 3, 'add_cards: 3 available';

  -- نفس القائمة مرة ثانية: لا تتضاعف
  v_res := bot_add_cards(v_owner_tg, v_year, array['Y-AAA','Y-BBB','Y-DDD']);
  assert (v_res->>'added')::int = 1,      'add_cards: only the new code added';
  assert (v_res->>'duplicates')::int = 2, 'add_cards: duplicates counted, not inserted';
  assert (v_res->>'available')::int = 4,  'add_cards: 4 available now';

  -- المسافات تُقلَّم والسطور الفارغة تُتجاهَل
  v_res := bot_add_cards(v_owner_tg, v_three, array['  T-111  ', '', '   ', 'T-222']);
  assert (v_res->>'added')::int = 2, 'add_cards: blanks skipped';
  assert exists (select 1 from bot_cards where variant_id = v_three and code = 'T-111'),
         'add_cards: code trimmed before insert';

  -- بائع عادي لا يشحن المخزون
  begin
    perform bot_add_cards(v_a_tg, v_year, array['X-1']);
    assert false, 'plain admin added stock';
  exception when others then
    assert sqlerrm like 'NOT_OWNER%', 'stock is owner-only, got: ' || sqlerrm;
  end;
  raise notice 'PASS  شحن المخزون';

  -- ========== الطلب ==========
  v_res  := bot_request_card(v_a_tg, v_year, 'زبون 1');
  v_issue := (v_res->>'issue_id')::uuid;
  v_code  := v_res->>'card_code';
  assert v_code = 'Y-AAA', 'request: oldest card first (queue), got ' || v_code;
  assert (v_res->>'remaining')::int = 3, 'request: remaining dropped to 3';
  assert (select status from bot_cards where variant_id = v_year and code = v_code)
         = 'reserved', 'request: card is reserved, not sold';
  assert (select status from bot_issues where id = v_issue) = 'pending',
         'request: issue starts pending';
  assert (select customer_ref from bot_issues where id = v_issue) = 'زبون 1',
         'request: customer reference stored';
  raise notice 'PASS  طلب بطاقة يحجزها ولا يبيعها';

  -- طلب ثانٍ لا يعيد نفس البطاقة
  v_res2   := bot_request_card(v_b_tg, v_year);
  v_issue2 := (v_res2->>'issue_id')::uuid;
  assert v_res2->>'card_code' <> v_code, 'request: two admins never get the same card';
  assert (v_res2->>'remaining')::int = 2, 'request: remaining dropped to 2';
  raise notice 'PASS  طلبان لا يأخذان نفس البطاقة';

  -- ========== التأكيد = نجحت العملية ==========
  v_res := bot_confirm_issue(v_a_tg, v_issue);
  assert v_res->>'status' = 'confirmed', 'confirm: status confirmed';
  assert (v_res->>'seller_sales')::int = 1, 'confirm: seller now has 1 sale';
  assert (select status from bot_cards where variant_id = v_year and code = v_code)
         = 'sold', 'confirm: card sold';
  assert (select sold_at from bot_cards where variant_id = v_year and code = v_code)
         is not null, 'confirm: sold_at stamped';
  assert (v_res->>'remaining')::int = 2, 'confirm: does NOT put the card back';
  raise notice 'PASS  تأكيد = بيع نهائي';

  -- تأكيد ثانٍ لنفس العملية مرفوض
  begin
    perform bot_confirm_issue(v_a_tg, v_issue);
    assert false, 'confirmed the same issue twice';
  exception when others then
    assert sqlerrm like 'ISSUE_ALREADY_SETTLED%', 'double confirm blocked, got: ' || sqlerrm;
  end;
  raise notice 'PASS  لا تأكيد مرتين';

  -- ========== الإلغاء = فشلت، والبطاقة ترجع ==========
  v_code := v_res2->>'card_code';
  v_res  := bot_cancel_issue(v_b_tg, v_issue2);
  assert v_res->>'status' = 'cancelled', 'cancel: status cancelled';
  assert (select status from bot_cards where variant_id = v_year and code = v_code)
         = 'available', 'cancel: card back in stock';
  assert (v_res->>'remaining')::int = 3, 'cancel: remaining back up to 3';
  assert (select count(*) from bot_issues where admin_id =
            (select id from bot_admins where telegram_id = v_b_tg)
            and status = 'confirmed') = 0, 'cancel: nothing counted as a sale';
  -- السجل يبقى: الصف لا يُحذف
  assert (select count(*) from bot_issues where id = v_issue2) = 1,
         'cancel: the row stays in the log';
  raise notice 'PASS  إلغاء = رجوع البطاقة للمخزون';

  -- وترجع فعلاً للتداول: نفس الكود يُطلب من جديد
  v_res := bot_request_card(v_b_tg, v_year);
  assert v_res->>'card_code' = v_code, 'cancel: the returned card is issued again';
  perform bot_cancel_issue(v_b_tg, (v_res->>'issue_id')::uuid);
  raise notice 'PASS  البطاقة الملغاة تُباع مرة أخرى';

  -- ========== ملكية العملية ==========
  v_res   := bot_request_card(v_a_tg, v_year);
  v_issue := (v_res->>'issue_id')::uuid;
  begin
    perform bot_confirm_issue(v_b_tg, v_issue);
    assert false, 'an admin settled someone else''s issue';
  exception when others then
    assert sqlerrm like 'NOT_YOUR_ISSUE%', 'cross-admin settle blocked, got: ' || sqlerrm;
  end;
  -- المالك يستطيع، ليفكّ ما علق
  v_res := bot_cancel_issue(v_owner_tg, v_issue);
  assert v_res->>'status' = 'cancelled', 'owner can settle any issue';
  assert (select settled_by from bot_issues where id = v_issue)
         = (select id from bot_admins where telegram_id = v_owner_tg),
         'settled_by records who actually settled it';
  raise notice 'PASS  البائع لا يتصرّف في طلب غيره، والمالك يستطيع';

  -- ========== نفاد المخزون ==========
  -- 3 أشهر فيها بطاقتان: خذهما ثم اطلب ثالثة
  perform bot_request_card(v_a_tg, v_three);
  perform bot_request_card(v_a_tg, v_three);
  begin
    perform bot_request_card(v_a_tg, v_three);
    assert false, 'issued a card from an empty variant';
  exception when others then
    assert sqlerrm like 'OUT_OF_STOCK%', 'empty stock reported, got: ' || sqlerrm;
  end;
  raise notice 'PASS  نفاد المخزون يُبلَّغ ولا يُخترع كود';

  -- ========== سقف الطلبات المعلّقة ==========
  update store_settings set value = '2' where key = 'bot_pending_limit';
  -- للبائع أ الآن طلبان معلّقان (من 3 أشهر)
  select count(*) into v_n from bot_issues
   where admin_id = (select id from bot_admins where telegram_id = v_a_tg)
     and status = 'pending';
  assert v_n = 2, 'setup: two pending issues, got ' || v_n;
  begin
    perform bot_request_card(v_a_tg, v_year);
    assert false, 'pending limit not enforced';
  exception when others then
    assert sqlerrm like 'PENDING_LIMIT%', 'pending limit enforced, got: ' || sqlerrm;
  end;
  update store_settings set value = '5' where key = 'bot_pending_limit';
  raise notice 'PASS  سقف الطلبات المعلّقة';

  -- ========== المعلّقة ==========
  -- البائع يرى طلباته وحده، المالك يرى الكل
  assert jsonb_array_length(bot_pending(v_a_tg)) = 2, 'pending: admin sees only their own';
  assert jsonb_array_length(bot_pending(v_owner_tg)) >= 2, 'pending: owner sees everything';
  raise notice 'PASS  قائمة المعلّقة';

  -- ========== العدّاد ==========
  v_res := bot_stats(v_a_tg, 'me') -> 0;
  assert (v_res->>'confirmed')::int = 1, 'stats: seller أ has exactly 1 confirmed sale';
  assert (v_res->>'today')::int = 1,     'stats: and it counts as today';
  assert jsonb_array_length(bot_stats(v_a_tg, 'me')) = 1, 'stats: "me" is one row';

  -- كل الأرقام محسوبة من السجل: تغيير السجل يغيّر العدّاد
  assert (bot_stats(v_b_tg,'me') -> 0 ->> 'cancelled')::int = 2,
         'stats: cancellations counted separately from sales';

  -- نطاق "all" للمالك وحده
  begin
    perform bot_stats(v_a_tg, 'all');
    assert false, 'plain admin read everyone''s stats';
  exception when others then
    assert sqlerrm like 'NOT_OWNER%', 'all-scope is owner-only, got: ' || sqlerrm;
  end;
  -- المالك يرى صفوف غيره لا صفّه وحده
  assert exists (
    select 1 from jsonb_array_elements(bot_stats(v_owner_tg, 'all')) e
     where (e->>'telegram_id')::bigint = v_a_tg
  ), 'stats: owner sees other sellers'' rows';
  assert jsonb_array_length(bot_stats(v_owner_tg, 'all')) >= 3,
         'stats: owner sees at least the three accounts of this run';
  raise notice 'PASS  عدّاد المبيعات لكل أدمن';

  -- ========== التفصيل: ماذا بيع، لا كم بيع (022) ==========
  -- «3 أشهر» استُنفدت في فحص نفاد المخزون أعلاه؛ تُشحن من جديد
  -- لأن هذا القسم يحتاج مدّتين مختلفتين ليثبت أنه لا يخلط بينهما.
  perform bot_add_cards(v_owner_tg, v_three, array['T-901','T-902']);

  -- التأكيد يقول أي اشتراك أُغلق
  v_res := bot_request_card(v_b_tg, v_year);
  v_res := bot_confirm_issue(v_b_tg, (v_res->>'issue_id')::uuid);
  assert v_res->>'product_name' = 'بطاقة جيفت كارد',
         'confirm names the product, got: ' || coalesce(v_res->>'product_name','null');
  assert v_res->>'variant_name' = 'سنة',
         'confirm names the duration, got: ' || coalesce(v_res->>'variant_name','null');
  assert (v_res->>'seller_sales_of_variant')::int = 1,
         'confirm counts this seller''s sales OF THIS duration';
  assert (v_res->>'seller_sales')::int = 1, 'and their overall total';
  raise notice 'PASS  التأكيد يقول أي اشتراك بيع';

  -- الإلغاء كذلك
  v_res  := bot_request_card(v_b_tg, v_three);
  v_res  := bot_cancel_issue(v_b_tg, (v_res->>'issue_id')::uuid);
  assert v_res->>'variant_name' = '3 أشهر', 'cancel names the duration too';
  raise notice 'PASS  الإلغاء يقول أي اشتراك رجع';

  -- تفصيل البائع: سطر لكل مدة باع منها
  v_res := bot_breakdown(v_b_tg, 'me') -> 0;
  assert (v_res->>'confirmed')::int = 1, 'breakdown: overall total';
  assert jsonb_array_length(v_res->'items') = 1,
         'breakdown: only durations actually SOLD appear, got '
         || jsonb_array_length(v_res->'items');
  assert v_res->'items'->0->>'variant' = 'سنة', 'breakdown: the right duration';
  assert (v_res->'items'->0->>'confirmed')::int = 1, 'breakdown: the right count';
  -- 3 أشهر أُلغيت ولم تُبَع: لا تظهر كصفّ صفري
  assert not exists (
    select 1 from jsonb_array_elements(v_res->'items') e
     where e->>'variant' = '3 أشهر'
  ), 'breakdown: a cancelled-only duration is not listed as a sale';
  raise notice 'PASS  تفصيل «ماذا بعت» لكل مدة';

  -- بائعان مختلفان -> صفّان مختلفان، لا خلط
  v_res := bot_breakdown(v_owner_tg, 'all');
  assert jsonb_array_length(v_res) >= 3, 'breakdown all: every admin has a row';
  assert (select (e->>'confirmed')::int
            from jsonb_array_elements(v_res) e
           where (e->>'telegram_id')::bigint = v_b_tg) = 1,
         'breakdown all: seller ب credited with exactly their own sale';

  -- أدمن بعينه — للمالك وحده
  v_res := bot_breakdown(v_owner_tg, 'me', v_b_tg);
  assert (v_res->0->>'telegram_id')::bigint = v_b_tg, 'breakdown: targeted admin';
  begin
    perform bot_breakdown(v_b_tg, 'me', v_owner_tg);
    assert false, 'a plain admin read someone else''s breakdown';
  exception when others then
    assert sqlerrm like 'NOT_OWNER%', 'targeting is owner-only, got: ' || sqlerrm;
  end;
  begin
    perform bot_breakdown(v_owner_tg, 'me', 909090909);
    assert false, 'breakdown accepted an unknown admin';
  exception when others then
    assert sqlerrm like 'ADMIN_NOT_FOUND%', 'unknown target rejected, got: ' || sqlerrm;
  end;
  raise notice 'PASS  المالك يرى تفصيل كل أدمن، والبائع لا يرى غيره';

  -- ========== قابلية إضافة منتجات ==========
  v_res := bot_add_product(v_owner_tg, 'netflix', 'نتفليكس');
  perform bot_add_variant(v_owner_tg, 'netflix', '6months', '6 أشهر');
  perform bot_add_cards(v_owner_tg,
    (select id from bot_variants where code = '6months'), array['N-1','N-2']);
  v_res := bot_request_card(v_a_tg, (select id from bot_variants where code = '6months'));
  assert v_res->>'product_name' = 'نتفليكس', 'new product sells like the first one';
  assert v_res->>'variant_name' = '6 أشهر',  'new variant sells like the first one';
  perform bot_cancel_issue(v_a_tg, (v_res->>'issue_id')::uuid);

  begin
    perform bot_add_product(v_owner_tg, 'netflix', 'نتفليكس ثانية');
    assert false, 'duplicate product code accepted';
  exception when others then
    assert sqlerrm like 'PRODUCT_EXISTS%', 'duplicate product blocked, got: ' || sqlerrm;
  end;
  begin
    perform bot_add_product(v_owner_tg, 'Not A Code!', 'س');
    assert false, 'invalid product code accepted';
  exception when others then
    assert sqlerrm like 'INVALID_CODE%', 'invalid code blocked, got: ' || sqlerrm;
  end;
  raise notice 'PASS  منتجات جديدة بلا هجرة';

  -- ========== الإخفاء ==========
  perform bot_set_active(v_owner_tg, 'variant',
    (select id from bot_variants where code = '6months'), false);
  begin
    perform bot_request_card(v_a_tg, (select id from bot_variants where code = '6months'));
    assert false, 'sold from a hidden variant';
  exception when others then
    assert sqlerrm like 'VARIANT_NOT_FOUND%', 'hidden variant not sellable, got: ' || sqlerrm;
  end;
  -- ومخفي عن القائمة، وبطاقاته سليمة في مكانها
  assert (select count(*) from bot_cards
           where variant_id = (select id from bot_variants where code = '6months')) = 2,
         'hiding a variant keeps its stock';
  perform bot_set_active(v_owner_tg, 'variant',
    (select id from bot_variants where code = '6months'), true);
  raise notice 'PASS  الإخفاء بلا فقدان مخزون';

  -- ========== تعطيل بائع ==========
  -- للبائع أ طلبان معلّقان: تعطيله يرجع بطاقتيهما للمخزون
  -- الفرق هو المقصود لا الرقم المطلق: للبائع أ بطاقتان معلّقتان،
  -- فتعطيله يجب أن يزيد المتاح باثنتين مهما كان المخزون قبله.
  select count(*) into v_n from bot_cards where variant_id = v_three and status = 'available';
  assert (select count(*) from bot_issues i
           where i.variant_id = v_three and i.status = 'pending'
             and i.admin_id = (select id from bot_admins where telegram_id = v_a_tg)) = 2,
         'setup: seller أ is holding two 3-months cards';
  perform bot_remove_admin(v_owner_tg, v_a_tg);
  assert (select count(*) from bot_cards where variant_id = v_three and status = 'available')
         = v_n + 2,
         'removing an admin releases the cards they were holding';
  assert (select count(*) from bot_issues where status = 'pending'
           and admin_id = (select id from bot_admins where telegram_id = v_a_tg)) = 0,
         'their pending issues are cancelled, not left hanging';
  -- ومبيعاته السابقة تبقى منسوبة إليه
  assert (select count(*) from bot_issues where status = 'confirmed'
           and admin_id = (select id from bot_admins where telegram_id = v_a_tg)) = 1,
         'a removed admin keeps their sales history';
  begin
    perform bot_catalog(v_a_tg);
    assert false, 'a removed admin still reached the catalogue';
  exception when others then
    assert sqlerrm like 'NOT_AUTHORIZED%', 'removed admin locked out, got: ' || sqlerrm;
  end;

  begin
    perform bot_remove_admin(v_owner_tg, v_owner_tg);
    assert false, 'owner removed themselves';
  exception when others then
    assert sqlerrm like 'CANNOT_REMOVE_SELF%', 'self-removal blocked, got: ' || sqlerrm;
  end;
  raise notice 'PASS  تعطيل بائع يحرّر بطاقاته ويبقي سجله';

  -- ========== وثيقة الضمان (023) ==========
  -- منتج بحقول زبون: يوزر أنستا مطلوب، وهاتف اختياري
  perform bot_add_product(v_owner_tg, 'insta', 'متابعين انستا');
  perform bot_add_variant(v_owner_tg, 'insta', 'year', 'سنة');
  select id into v_prod from bot_products where code = 'insta';
  select id into v_year from bot_variants where product_id = v_prod and code = 'year';
  -- المدة تُملأ كما يملؤها المالك من اللوحة
  update bot_variants set duration_value = 1, duration_unit = 'year' where id = v_year;
  perform bot_add_field(v_owner_tg, 'insta', 'يوزر الأنستا');
  perform bot_add_field(v_owner_tg, 'insta', 'رقم الهاتف', false);
  perform bot_add_cards(v_owner_tg, v_year, array['INS-1','INS-2','INS-3']);

  -- ما الذي يسأل عنه البوت بعد التأكيد؟
  v_res  := bot_request_card(v_b_tg, v_year);
  v_issue := (v_res->>'issue_id')::uuid;
  v_res  := bot_issue_fields(v_b_tg, v_issue);
  assert jsonb_array_length(v_res->'fields') = 2, 'issue_fields: both fields listed';
  assert v_res->'fields'->0->>'label' = 'يوزر الأنستا', 'issue_fields: in order';
  assert (v_res->'fields'->1->>'is_required')::boolean = false,
         'issue_fields: optional flag carried';

  -- الوثيقة لا تصدر لبيعة لم تُؤكَّد
  begin
    perform bot_issue_certificate(v_b_tg, v_issue,
      '[{"label":"يوزر الأنستا","value":"@x"}]'::jsonb);
    assert false, 'issued a certificate for a pending sale';
  exception when others then
    assert sqlerrm like 'ISSUE_NOT_CONFIRMED%', 'pending sale blocked, got: ' || sqlerrm;
  end;

  perform bot_confirm_issue(v_b_tg, v_issue);

  -- حقل مطلوب ناقص يوقف الإصدار
  begin
    perform bot_issue_certificate(v_b_tg, v_issue,
      '[{"label":"رقم الهاتف","value":"0550111222"}]'::jsonb);
    assert false, 'issued a certificate without a required field';
  exception when others then
    assert sqlerrm like 'FIELD_REQUIRED:يوزر الأنستا%',
           'the missing field is named, got: ' || sqlerrm;
  end;

  v_res := bot_issue_certificate(v_b_tg, v_issue,
    '[{"label":"يوزر الأنستا","value":"@ahmed_dz"},
      {"label":"رقم الهاتف","value":"0550111222"}]'::jsonb);
  v_code := v_res->>'code';
  assert v_code like 'JNR-%', 'certificate code shape, got: ' || v_code;
  assert (v_res->>'starts_at')::timestamptz <= now(), 'starts now';
  -- سنة كاملة، محسوبة من المدة لا مكتوبة بيد
  assert (v_res->>'ends_at')::timestamptz
         between now() + interval '364 days' and now() + interval '367 days',
         'ends one year later, computed from the duration';
  assert (v_res->>'days_left')::int between 364 and 366, 'days_left ~ 365';
  assert jsonb_array_length(v_res->'customer') = 2, 'both customer values stored';
  raise notice 'PASS  الوثيقة تصدر بتاريخي البداية والنهاية';

  -- لا وثيقتان لبيعة واحدة
  begin
    perform bot_issue_certificate(v_b_tg, v_issue,
      '[{"label":"يوزر الأنستا","value":"@other"}]'::jsonb);
    assert false, 'issued two certificates for one sale';
  exception when others then
    assert sqlerrm like 'CERTIFICATE_EXISTS%', 'second issue blocked, got: ' || sqlerrm;
  end;
  raise notice 'PASS  وثيقة واحدة لكل بيعة';

  -- القراءة بالرمز
  v_res := bot_certificate(v_b_tg, v_code);
  assert v_res->>'product_name' = 'متابعين انستا', 'cert lookup: product';
  assert (v_res->>'expired')::boolean = false, 'cert lookup: not expired yet';
  -- الحروف الصغيرة والمسافات تُقبل: الزبون يعيد كتابة الرمز بيده
  assert bot_certificate(v_b_tg, '  ' || lower(v_code) || ' ')->>'code' = v_code,
         'cert lookup tolerates case and spaces';
  begin
    perform bot_certificate(v_b_tg, 'JNR-NOPENOPENOPE');
    assert false, 'unknown code accepted';
  exception when others then
    assert sqlerrm like 'CERTIFICATE_NOT_FOUND%', 'unknown code rejected, got: ' || sqlerrm;
  end;
  raise notice 'PASS  قراءة الوثيقة بالرمز';

  -- البحث عن الزبون بأي حقل
  assert jsonb_array_length(bot_find_customer(v_b_tg, 'ahmed')) = 1,
         'find: by instagram handle';
  assert jsonb_array_length(bot_find_customer(v_b_tg, '0550111222')) = 1,
         'find: by phone, same customer';
  assert jsonb_array_length(bot_find_customer(v_b_tg, 'nobody-here')) = 0,
         'find: no false positives';
  begin
    perform bot_find_customer(v_b_tg, 'a');
    assert false, 'one-letter search accepted';
  exception when others then
    assert sqlerrm like 'QUERY_TOO_SHORT%', 'one letter rejected, got: ' || sqlerrm;
  end;
  raise notice 'PASS  البحث عن زبون بأي حقل';

  -- الاشتراكات المنتهية قريباً
  assert jsonb_array_length(bot_expiring(v_b_tg, 7)) = 0,
         'expiring: a year away is not "soon"';
  update bot_certificates set ends_at = now() + interval '3 days' where code = v_code;
  assert jsonb_array_length(bot_expiring(v_b_tg, 7)) = 1,
         'expiring: three days away shows up';
  assert (bot_expiring(v_b_tg, 7) -> 0 ->> 'days_left')::int between 2 and 3,
         'expiring: days_left is right';
  -- اشتراك منتهٍ حقيقي: بدايته في الماضي كذلك. القيد
  -- bot_cert_window_ok يرفض نهايةً قبل بدايةٍ — وهو محق، فعدّلا معاً.
  update bot_certificates
     set starts_at = now() - interval '400 days', ends_at = now() - interval '1 day'
   where code = v_code;
  assert jsonb_array_length(bot_expiring(v_b_tg, 7)) = 0,
         'expiring: already expired is not "expiring"';
  assert (bot_certificate(v_b_tg, v_code)->>'expired')::boolean,
         'and it reads as expired';
  raise notice 'PASS  اشتراكات تنتهي قريباً';

  -- بائع لا يرى وثائق غيره
  begin
    perform bot_certificate(v_a_tg, v_code);
    assert false, 'an admin read another admin''s certificate';
  exception when others then
    assert sqlerrm like 'NOT_YOUR_ISSUE%' or sqlerrm like 'NOT_AUTHORIZED%',
           'cross-seller certificate blocked, got: ' || sqlerrm;
  end;
  -- والمالك يرى كل شيء
  assert bot_certificate(v_owner_tg, v_code)->>'code' = v_code, 'owner reads any certificate';
  raise notice 'PASS  كل بائع يرى وثائقه، والمالك يرى الكل';

  -- حذف حقل لا يمسّ وثيقة صادرة
  perform bot_remove_field(v_owner_tg, 'insta', 'رقم الهاتف');
  assert jsonb_array_length(bot_certificate(v_owner_tg, v_code)->'customer') = 2,
         'deleting a field leaves issued certificates untouched';
  raise notice 'PASS  حذف حقل لا يغيّر وثيقة صادرة';

  -- ولا نجمع كلمات سر، أبداً
  begin
    perform bot_add_field(v_owner_tg, 'insta', 'كلمة السر');
    assert false, 'a password field was accepted';
  exception when others then
    assert sqlerrm not like 'FIELD_EXISTS%', 'password field rejected by the check';
  end;
  raise notice 'PASS  لا حقل لكلمة سر';

  raise notice '===== bot tests passed =====';
end $$;

-- ============================================================
-- الصلاحيات: لا anon ولا authenticated يمر من أي باب.
-- ============================================================
do $$
declare v_n int;
begin
  -- لا policy على أي جدول من جداول البوت
  select count(*) into v_n from pg_policies
   where schemaname = 'public'
     and tablename in ('bot_admins','bot_products','bot_variants','bot_cards','bot_issues');
  assert v_n = 0, 'bot tables must carry no RLS policy at all, found ' || v_n;

  -- وRLS مفعّل على كلها، وإلا كان الجدول مفتوحاً لمن مُنح select
  select count(*) into v_n from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname like 'bot\_%' and c.relkind = 'r'
     and not c.relrowsecurity;
  assert v_n = 0, 'every bot table must have RLS enabled, ' || v_n || ' do not';

  -- ولا صلاحية جدول لـanon/authenticated
  select count(*) into v_n from information_schema.role_table_grants
   where table_schema = 'public' and table_name like 'bot\_%'
     and grantee in ('anon','authenticated');
  assert v_n = 0, 'anon/authenticated must hold no grant on bot tables, found ' || v_n;

  -- ولا تنفيذ لأي دالة bot_*: هي SECURITY DEFINER، ومنحها لـanon
  -- يعني قراءة المخزون كله بتمرير أي telegram_id.
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname like 'bot\_%'
     and (has_function_privilege('anon',          p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute'));
  assert v_n = 0, v_n || ' bot_* functions are still callable by anon/authenticated';

  -- وservice_role يستطيع، وإلا لما عمل البوت أصلاً
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname like 'bot\_%'
     and not has_function_privilege('service_role', p.oid, 'execute');
  assert v_n = 0, v_n || ' bot_* functions are not callable by service_role';

  raise notice 'PASS  صلاحيات البوت مغلقة على service_role وحده';
end $$;

-- لا شيء يُحفظ: تجربة جافة.
rollback;
