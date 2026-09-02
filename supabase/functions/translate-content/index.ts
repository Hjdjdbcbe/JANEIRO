// ============================================================
// POST /functions/v1/translate-content
// body: { lang: "fr"|"en", items: [{ type, id, text }] }
//
// Machine-translates owner-authored catalogue text (product names/
// descriptions, category names, bundle names) on demand, for
// whichever language a customer picked. Everything else on the
// storefront is translated by hand in the frontend's own dictionary;
// this exists only for text no dictionary can anticipate, because the
// store owner is still typing it in the dashboard.
//
// Cached in content_translations, keyed by (type, id, lang), and
// invalidated by comparing source_text to what the caller sends now
// -- if the owner edited the product, the cached row's source_text no
// longer matches and it is retranslated.
//
// Best-effort like the Telegram notification: DeepL is not
// configured, or the call fails, and the affected items are simply
// left out of the response. The frontend falls back to the original
// Arabic text for anything missing -- a translation hiccup never
// blocks a purchase.
// ============================================================
import { cors, json, serviceClient, clientIp, mapError, ipRateLimit } from "../_shared/util.ts";

const DEEPL_API_KEY = Deno.env.get("DEEPL_API_KEY") ?? "";
// A free-tier key ends in ":fx"; that is the one signal DeepL gives us
// to pick the matching host, since the free and paid APIs live on
// different subdomains and a request to the wrong one is rejected outright.
const DEEPL_URL = DEEPL_API_KEY.endsWith(":fx")
  ? "https://api-free.deepl.com/v2/translate"
  : "https://api.deepl.com/v2/translate";

const ENTITY_TYPES = new Set([
  "product_name", "product_description", "category_name",
  "bundle_name", "bundle_description",
]);

interface ItemIn { type: string; id: string; text: string }

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  const db = serviceClient();
  const ip = clientIp(req);

  try {
    if (!(await ipRateLimit(db, ip, "translate_content", 40, 10))) {
      return json({ ok: false, code: "RATE_LIMITED",
        message: "عدد المحاولات كبير. انتظر قليلاً ثم أعد المحاولة." }, 429);
    }

    const body = await req.json();
    const lang = body.lang === "fr" || body.lang === "en" ? body.lang : null;
    if (!lang) return json({ ok: false, code: "INVALID_REQUEST", message: "لغة غير صالحة." }, 400);

    const items: ItemIn[] = (Array.isArray(body.items) ? body.items : [])
      .slice(0, 80)
      .filter((i: ItemIn) =>
        i && ENTITY_TYPES.has(i.type) && typeof i.id === "string" &&
        typeof i.text === "string" && i.text.trim().length > 0 && i.text.length <= 2000)
      .map((i: ItemIn) => ({ type: i.type, id: i.id, text: i.text.trim() }));

    if (items.length === 0) return json({ ok: true, translations: {} });

    const ids = [...new Set(items.map((i) => i.id))];
    const { data: cached } = await db
      .from("content_translations")
      .select("entity_type, entity_id, source_text, translated_text")
      .eq("lang", lang)
      .in("entity_id", ids);

    const cacheKey = (type: string, id: string) => `${type}:${id}`;
    const cacheMap = new Map(
      (cached ?? []).map((r) => [cacheKey(r.entity_type, r.entity_id), r]),
    );

    const translations: Record<string, string> = {};
    const misses: ItemIn[] = [];
    for (const it of items) {
      const row = cacheMap.get(cacheKey(it.type, it.id));
      if (row && row.source_text === it.text) {
        translations[cacheKey(it.type, it.id)] = row.translated_text;
      } else {
        misses.push(it);
      }
    }

    if (misses.length > 0 && DEEPL_API_KEY) {
      try {
        const r = await fetch(DEEPL_URL, {
          method: "POST",
          headers: {
            "Authorization": `DeepL-Auth-Key ${DEEPL_API_KEY}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            text: misses.map((i) => i.text),
            source_lang: "AR",
            target_lang: lang === "fr" ? "FR" : "EN-US",
          }),
        });
        if (!r.ok) throw new Error(`deepl ${r.status}: ${await r.text()}`);
        const data = await r.json();
        const out: { text: string }[] = data.translations ?? [];

        const rows = misses.map((it, i) => ({
          entity_type: it.type,
          entity_id: it.id,
          lang,
          source_text: it.text,
          translated_text: out[i]?.text ?? it.text,
        })).filter((r) => r.translated_text);

        for (const r of rows) translations[cacheKey(r.entity_type, r.entity_id)] = r.translated_text;

        if (rows.length > 0) {
          await db.from("content_translations")
            .upsert(rows, { onConflict: "entity_type,entity_id,lang" });
        }
      } catch (err) {
        // Best-effort: log it, but a translation outage must never
        // fail the page. Items with no cached row simply stay absent
        // from the response, and the frontend falls back to Arabic.
        console.error("deepl translate failed", err);
      }
    }

    return json({ ok: true, translations });
  } catch (err) {
    const m = mapError(err);
    return json({ ok: false, ...m }, m.code === "UNKNOWN" ? 500 : 400);
  }
});
