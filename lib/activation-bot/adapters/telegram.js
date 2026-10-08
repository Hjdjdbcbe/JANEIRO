/* ============================================================
   طبقة الميساجات — Telegram Bot API.

   المنطق (handler.js) ما يعرفش تيليغرام: يتعامل مع ميساج موحّد
   ويبعث بدوال هذي الطبقة برك. WhatsApp Cloud API يجي من بعد كطبقة
   ثانية بنفس الواجهة:

     platform                      'telegram'
     parseUpdate(raw)          ->  Incoming | null
     sendText(chat, text, {buttons})            -> message_id
     sendMedia(chat, kind, fileId, {caption})   -> message_id
     copyMessage(toChat, fromChat, messageId)   -> message_id
     sendFile(chat, kind, bytes, mime, {caption, buttons}) -> message_id
     downloadFile(fileId)      ->  { bytes: Buffer, mime }
     answerCallback(id, text?)
     deleteMessage(chat, messageId)
     clearButtons(chat, messageId)

   Incoming = { updateId, chatId, userId, messageId, kind, text,
                fileId, mime, duration, callbackId, callbackData,
                replyTo, isPrivate }
   kind: text | photo | voice | video | document | callback | other
   ============================================================ */

function createTelegramAdapter({ token, fetchImpl = fetch, apiBase = "https://api.telegram.org" }) {
  if (!token) throw new Error("ACTIVATION_BOT_TOKEN missing");
  const api = `${apiBase}/bot${token}`;

  async function call(method, body) {
    const res = await fetchImpl(`${api}/${method}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    const data = await res.json().catch(() => ({}));
    if (!data.ok) {
      const err = new Error(`telegram ${method}: ${data.description || res.status}`);
      err.telegram = data;
      throw err;
    }
    return data.result;
  }

  const keyboard = (buttons) =>
    buttons && buttons.length
      ? { inline_keyboard: buttons.map((row) => row.map((b) => ({ text: b.text, callback_data: b.data }))) }
      : undefined;

  function parseUpdate(u) {
    if (!u || typeof u !== "object") return null;
    const updateId = String(u.update_id);

    if (u.callback_query) {
      const q = u.callback_query;
      const m = q.message || {};
      return {
        updateId, kind: "callback",
        chatId: String(m.chat ? m.chat.id : q.from.id),
        userId: String(q.from.id),
        messageId: m.message_id || null,
        callbackId: q.id, callbackData: q.data || "",
        isPrivate: !m.chat || m.chat.type === "private",
      };
    }

    const m = u.message;
    if (!m || !m.chat) return null;
    const base = {
      updateId,
      chatId: String(m.chat.id),
      userId: String((m.from || {}).id || m.chat.id),
      messageId: m.message_id,
      replyTo: m.reply_to_message ? m.reply_to_message.message_id : null,
      replyToKind: m.reply_to_message ? kindOf(m.reply_to_message) : null,
      replyToFileId: m.reply_to_message ? fileOf(m.reply_to_message) : null,
      isPrivate: m.chat.type === "private",
    };
    const kind = kindOf(m);
    return {
      ...base, kind,
      text: m.text || m.caption || "",
      fileId: fileOf(m),
      mime: kind === "photo" ? "image/jpeg" : (m.document || m.voice || m.audio || m.video || {}).mime_type || null,
      duration: (m.voice || m.audio || m.video || {}).duration || null,
    };
  }

  function kindOf(m) {
    if (m.photo) return "photo";
    if (m.document && /^image\//.test(m.document.mime_type || "")) return "photo";
    if (m.voice || m.audio) return "voice";
    if (m.video) return "video";
    if (m.document) return "document";
    if (typeof m.text === "string") return "text";
    return "other";
  }

  function fileOf(m) {
    if (m.photo) return m.photo[m.photo.length - 1].file_id; // أكبر قياس
    const f = m.document || m.voice || m.audio || m.video;
    return f ? f.file_id : null;
  }

  async function sendText(chatId, text, { buttons } = {}) {
    const r = await call("sendMessage", {
      chat_id: chatId, text,
      reply_markup: keyboard(buttons),
      link_preview_options: { is_disabled: true },
    });
    return r.message_id;
  }

  const MEDIA = {
    video: ["sendVideo", "video"],
    photo: ["sendPhoto", "photo"],
    voice: ["sendVoice", "voice"],
  };
  async function sendMedia(chatId, kind, fileId, { caption, buttons } = {}) {
    const [method, field] = MEDIA[kind] || [];
    if (!method) throw new Error(`unknown media kind ${kind}`);
    const r = await call(method, { chat_id: chatId, [field]: fileId, caption, reply_markup: keyboard(buttons) });
    return r.message_id;
  }

  async function copyMessage(toChat, fromChat, messageId, { buttons } = {}) {
    const r = await call("copyMessage", {
      chat_id: toChat, from_chat_id: fromChat, message_id: messageId, reply_markup: keyboard(buttons),
    });
    return r.message_id;
  }

  async function downloadFile(fileId) {
    const f = await call("getFile", { file_id: fileId });
    const res = await fetchImpl(`${apiBase}/file/bot${token}/${f.file_path}`);
    if (!res.ok) throw new Error(`telegram file ${res.status}`);
    const bytes = Buffer.from(await res.arrayBuffer());
    const ext = (f.file_path.split(".").pop() || "").toLowerCase();
    const mime = { jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", webp: "image/webp",
                   gif: "image/gif", oga: "audio/ogg", ogg: "audio/ogg", mp3: "audio/mpeg",
                   m4a: "audio/mp4", wav: "audio/wav" }[ext] || null;
    return { bytes, mime, ext, size: f.file_size || bytes.length };
  }

  /** ملف من قناة أخرى (صورة/فوكال كليان واتساب) لمالك. */
  async function sendFile(chatId, kind, bytes, mime, { caption, buttons, filename } = {}) {
    const [method, field] = MEDIA[kind] || ["sendDocument", "document"];
    const form = new FormData();
    form.append("chat_id", String(chatId));
    if (caption) form.append("caption", caption);
    if (buttons) form.append("reply_markup", JSON.stringify(keyboard(buttons)));
    form.append(field, new Blob([bytes], { type: mime || "application/octet-stream" }),
                filename || { photo: "photo.jpg", voice: "voice.ogg", video: "video.mp4" }[kind] || "file");
    const res = await fetchImpl(`${api}/${method}`, { method: "POST", body: form });
    const data = await res.json().catch(() => ({}));
    if (!data.ok) throw new Error(`telegram ${method}: ${data.description || res.status}`);
    return data.result.message_id;
  }

  const answerCallback = (id, text) =>
    call("answerCallbackQuery", { callback_query_id: id, text }).catch(() => {});
  const deleteMessage = (chatId, messageId) =>
    call("deleteMessage", { chat_id: chatId, message_id: messageId }).catch(() => false);
  const clearButtons = (chatId, messageId) =>
    call("editMessageReplyMarkup", { chat_id: chatId, message_id: messageId, reply_markup: { inline_keyboard: [] } })
      .catch(() => {});

  return {
    platform: "telegram",
    sharedInbox: false,
    parseUpdate,
    parseUpdates: (u) => { const x = parseUpdate(u); return x ? [x] : []; },
    sendText, sendMedia, sendFile, copyMessage, downloadFile,
    answerCallback, deleteMessage, clearButtons,
  };
}

module.exports = { createTelegramAdapter };
