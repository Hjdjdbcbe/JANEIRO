/* ============================================================
   Supabase Storage — النسخة الأصلية تاع الفيديوهات والفوكالات
   (bucket خاص bot-media). منها يتعاود الرفع لواتساب كي يموت
   media_id. بمفتاح service_role من السيرفر برك.
   ============================================================ */

function createStorage({ url, serviceKey, bucket = "bot-media", fetchImpl = fetch }) {
  const base = `${url.replace(/\/+$/, "")}/storage/v1/object`;
  const auth = { apikey: serviceKey, authorization: `Bearer ${serviceKey}` };
  const enc = (p) => p.split("/").map(encodeURIComponent).join("/");

  async function upload(path, bytes, mime) {
    const res = await fetchImpl(`${base}/${bucket}/${enc(path)}`, {
      method: "POST",
      headers: { ...auth, "content-type": mime || "application/octet-stream", "x-upsert": "true" },
      body: bytes,
    });
    if (!res.ok) throw new Error(`storage upload ${res.status}: ${await res.text().catch(() => "")}`);
    return path;
  }

  async function download(path) {
    const res = await fetchImpl(`${base}/${bucket}/${enc(path)}`, { headers: auth });
    if (!res.ok) throw new Error(`storage download ${res.status}`);
    return { bytes: Buffer.from(await res.arrayBuffer()), mime: res.headers.get("content-type") };
  }

  async function remove(paths) {
    if (!paths || !paths.length) return;
    await fetchImpl(`${base}/${bucket}`, {
      method: "DELETE",
      headers: { ...auth, "content-type": "application/json" },
      body: JSON.stringify({ prefixes: paths }),
    }).catch(() => {});
  }

  return { upload, download, remove };
}

module.exports = { createStorage };
