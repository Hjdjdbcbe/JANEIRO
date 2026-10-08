/* ============================================================
   طبقة الميساجات — WhatsApp Cloud API (قناة الكليان).

   نفس واجهة adapters/telegram.js، مع فروق واتساب:
     - الرقم مشترك مع مالك (Coexistence): sharedInbox = true، فالمنطق
       يسكت مع أي رقم ما عندوش طلب.
     - webhook واحد فيه بزاف ميساجات: parseUpdates يرجع قائمة.
     - smb_message_echoes = مالك كتب من تطبيق واتساب بزنس: kind 'echo'.
     - الأزرار: interactive reply buttons، 3 على الأكثر، 20 حرف للعنوان.
     - الميديا تتبعث بـ media_id (يرفعها uploadMedia). الفوكال
       audio + voice:true (ogg/opus) باش يبان فوكال عادي.
     - ما نقدروش نمسحو ميساج تاع الكليان.

   chatId = رقم الكليان، ولا "u:<BSUID>" إذا مخبي رقمو (usernames).
   ============================================================ */

const MEDIA_ERROR_CODES = new Set([131052, 131053, 100]);

function createWhatsAppAdapter({
  token, phoneNumberId, graphVersion = "v23.0", fetchImpl = fetch, onSent,
  apiBase = "https://graph.facebook.com",
}) {
  if (!token || !phoneNumberId) throw new Error("WHATSAPP_TOKEN / WHATSAPP_PHONE_NUMBER_ID missing");
  const graph = `${apiBase}/${graphVersion}`;
  const auth = { authorization: `Bearer ${token}` };

  async function call(path, body) {
    const res = await fetchImpl(`${graph}/${path}`, {
      method: "POST",
      headers: { ...auth, "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || data.error) {
      const e = data.error || {};
      const err = new Error(`whatsapp ${path}: ${e.message || res.status}`);
      err.whatsapp = e;
      throw err;
    }
    return data;
  }

  const recipient = (chatId) =>
    String(chatId).startsWith("u:") ? { recipient: String(chatId).slice(2) } : { to: String(chatId) };

  async function send(chatId, message) {
    const data = await call(`${phoneNumberId}/messages`, {
      messaging_product: "whatsapp", recipient_type: "individual", ...recipient(chatId), ...message,
    });
    const id = data.messages && data.messages[0] && data.messages[0].id;
    if (id && onSent) await onSent([id]).catch(() => {});
    return id;
  }

  /* ---------- الاستقبال ---------- */
  function parseUpdates(body) {
    const out = [];
    for (const entry of (body && body.entry) || []) {
      for (const change of entry.changes || []) {
        const v = change.value || {};
        if (change.field === "smb_message_echoes" || v.message_echoes) {
          for (const e of v.message_echoes || []) {
            const to = e.to || (e.to_user_id ? `u:${e.to_user_id}` : null);
            if (to) out.push({ updateId: `echo:${e.id}`, kind: "echo", chatId: to, userId: to, messageId: e.id, isPrivate: true });
          }
          continue;
        }
        for (const m of v.messages || []) {
          const inc = parseMessage(m);
          if (inc) out.push(inc);
        }
      }
    }
    return out;
  }

  function parseMessage(m) {
    const chatId = m.from || (m.from_user_id ? `u:${m.from_user_id}` : null);
    if (!chatId || m.group_id) return null;
    const base = {
      updateId: m.id, chatId, userId: chatId, messageId: m.id, isPrivate: true,
      replyTo: (m.context && m.context.id) || null,
    };
    switch (m.type) {
      case "text":
        return { ...base, kind: "text", text: (m.text && m.text.body) || "" };
      case "image":
        return { ...base, kind: "photo", text: m.image.caption || "", fileId: m.image.id, mime: m.image.mime_type };
      case "document":
        if (/^image\//.test(m.document.mime_type || "")) {
          return { ...base, kind: "photo", text: m.document.caption || "", fileId: m.document.id, mime: m.document.mime_type };
        }
        return { ...base, kind: "document", text: m.document.caption || "", fileId: m.document.id, mime: m.document.mime_type };
      case "audio":
        // واتساب ما يعطيش المدّة: تتقاس من الـAI (القسم 10.1)
        return { ...base, kind: "voice", text: "", fileId: m.audio.id, mime: m.audio.mime_type, duration: null };
      case "video":
        return { ...base, kind: "video", text: m.video.caption || "", fileId: m.video.id, mime: m.video.mime_type };
      case "interactive": {
        const r = m.interactive && (m.interactive.button_reply || m.interactive.list_reply);
        return r ? { ...base, kind: "callback", callbackId: m.id, callbackData: r.id, text: r.title } : null;
      }
      case "button": // زر template
        return { ...base, kind: "callback", callbackId: m.id, callbackData: (m.button && m.button.payload) || "", text: (m.button && m.button.text) || "" };
      default:
        return { ...base, kind: "other", text: "" };
    }
  }

  /* ---------- البعث ---------- */
  async function sendText(chatId, text, { buttons } = {}) {
    const flat = (buttons || []).flat().slice(0, 3);
    if (!flat.length) {
      return send(chatId, { type: "text", text: { body: text, preview_url: false } });
    }
    let body = text;
    if (body.length > 1024) { // حد الـinteractive: النص وحدو والأزرار تحتو
      await send(chatId, { type: "text", text: { body: text, preview_url: false } });
      body = "👇";
    }
    return send(chatId, {
      type: "interactive",
      interactive: {
        type: "button",
        body: { text: body },
        action: { buttons: flat.map((b) => ({ type: "reply", reply: { id: b.data, title: b.text.slice(0, 20) } })) },
      },
    });
  }

  async function sendMedia(chatId, kind, mediaId, { caption } = {}) {
    if (kind === "voice") return send(chatId, { type: "audio", audio: { id: mediaId, voice: true } });
    const type = kind === "photo" ? "image" : kind;
    if (!["image", "video"].includes(type)) throw new Error(`unknown media kind ${kind}`);
    return send(chatId, { type, [type]: caption ? { id: mediaId, caption } : { id: mediaId } });
  }

  async function uploadMedia(bytes, mime, filename = "file") {
    const form = new FormData();
    form.append("messaging_product", "whatsapp");
    form.append("type", mime);
    form.append("file", new Blob([bytes], { type: mime }), filename);
    const res = await fetchImpl(`${graph}/${phoneNumberId}/media`, { method: "POST", headers: auth, body: form });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || !data.id) throw new Error(`whatsapp upload: ${(data.error && data.error.message) || res.status}`);
    return data.id;
  }

  async function downloadFile(mediaId) {
    const meta = await fetchImpl(`${graph}/${mediaId}`, { headers: auth }).then((r) => r.json());
    if (!meta.url) throw new Error(`whatsapp media ${mediaId}: ${(meta.error && meta.error.message) || "no url"}`);
    const res = await fetchImpl(meta.url, { headers: auth });
    if (!res.ok) throw new Error(`whatsapp media download ${res.status}`);
    const mime = (meta.mime_type || res.headers.get("content-type") || "").split(";")[0] || null;
    const ext = { "audio/ogg": "ogg", "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp",
                  "video/mp4": "mp4", "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/aac": "aac" }[mime] || "bin";
    return { bytes: Buffer.from(await res.arrayBuffer()), mime, ext, size: meta.file_size || null };
  }

  const isMediaError = (err) => !!(err && err.whatsapp && MEDIA_ERROR_CODES.has(err.whatsapp.code));
  const noop = async () => {};

  return {
    platform: "whatsapp",
    sharedInbox: true,
    parseUpdates,
    parseUpdate: (b) => parseUpdates(b)[0] || null,
    sendText, sendMedia, uploadMedia, downloadFile, isMediaError,
    answerCallback: noop, clearButtons: noop,
    deleteMessage: async () => false,
  };
}

module.exports = { createWhatsAppAdapter };
