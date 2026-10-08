/* ============================================================
   Supabase — كل شي يمر بدوال act_* (supabase/migrations/042) عبر
   PostgREST بمفتاح service_role. المفتاح في السيرفر برك.
   ============================================================ */

function createDb({ url, serviceKey, fetchImpl = fetch }) {
  if (!url || !serviceKey) throw new Error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY missing");
  const base = url.replace(/\/+$/, "");

  async function rpc(fn, args = {}) {
    const res = await fetchImpl(`${base}/rest/v1/rpc/${fn}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        apikey: serviceKey,
        authorization: `Bearer ${serviceKey}`,
      },
      body: JSON.stringify(args),
    });
    const text = await res.text();
    const data = text ? JSON.parse(text) : null;
    if (!res.ok) {
      const err = new Error(`db ${fn}: ${(data && data.message) || res.status}`);
      err.db = data;
      throw err;
    }
    return data;
  }

  return {
    rpc,
    seenUpdate: (platform, updateId) => rpc("act_seen_update", { p_platform: platform, p_update_id: updateId }),
    touchChat: (platform, chatId, isMedia) =>
      rpc("act_touch_chat", { p_platform: platform, p_chat_id: chatId, p_is_media: !!isMedia }),
    claimCode: (platform, chatId, code) =>
      rpc("act_claim_code", { p_platform: platform, p_chat_id: chatId, p_code: code }),
    newOrder: (type, by) => rpc("act_new_order", { p_type: type, p_created_by: by }),
    getOrder: (code) => rpc("act_get_order", { p_code: code }),
    getOrderById: (id) => rpc("act_get_order_by_id", { p_id: id }),
    openOrders: () => rpc("act_open_orders"),
    updateOrder: (id, patch, from = null) =>
      rpc("act_update_order", { p_id: id, p_patch: patch, p_from: from }),
    takeReview: (id) => rpc("act_take_review", { p_id: id }),
    assignGift: (orderId) => rpc("act_assign_gift", { p_order_id: orderId }),
    giftStock: () => rpc("act_gift_stock"),
    setGiftAmount: (product, variant, amount) =>
      rpc("act_set_gift_amount", { p_product: product, p_variant: variant, p_amount: amount }),
    mediaAll: (platform) => rpc("act_media_all", { p_platform: platform }),
    mediaSet: (platform, slot, kind, fileId, storagePath = null, mime = null) =>
      rpc("act_media_set", { p_platform: platform, p_slot: slot, p_kind: kind, p_file_id: fileId,
                             p_storage_path: storagePath, p_mime: mime }),
    mediaDelete: (slot) => rpc("act_media_delete", { p_slot: slot }),
    mediaList: () => rpc("act_media_list"),
    draftAdd: (admin, kind, tgFileId, mime) =>
      rpc("act_draft_add", { p_admin: String(admin), p_kind: kind, p_tg_file_id: tgFileId, p_mime: mime || null }),
    draftGet: (id, admin) => rpc("act_draft_get", { p_id: id, p_admin: String(admin) }),
    draftSetSlot: (id, admin, slot) => rpc("act_draft_set_slot", { p_id: id, p_admin: String(admin), p_slot: slot }),
    draftTake: (id, admin) => rpc("act_draft_take", { p_id: id, p_admin: String(admin) }),
    closeOrder: (code, reason) => rpc("act_close_order", { p_code: code, p_reason: reason }),
    sweepStale: () => rpc("act_sweep_stale"),
    aiSpendToday: () => rpc("act_ai_spend_today"),
    aiSpendAdd: (usd) => rpc("act_ai_spend_add", { p_usd: usd }),
    aiBudgetAlert: () => rpc("act_ai_budget_alert"),
    markSent: (platform, ids) => rpc("act_mark_sent", { p_platform: platform, p_ids: ids }),
    isSent: (platform, id) => rpc("act_is_sent", { p_platform: platform, p_id: id }),
    openOrderFor: (platform, chatId) => rpc("act_open_order_for", { p_platform: platform, p_chat_id: chatId }),
    voiceModeSet: (platform, slot, mode) =>
      rpc("act_voice_mode_set", { p_platform: platform, p_slot: slot, p_mode: mode }),
    problems: () => rpc("act_problems"),
    problemAdd: (title, symptoms, solution, appliesTo, escalateAfter) =>
      rpc("act_problem_add", {
        p_title: title, p_symptoms: symptoms, p_solution: solution,
        p_applies_to: appliesTo || [], p_escalate_after: escalateAfter ?? null,
      }),
    problemDel: (id) => rpc("act_problem_del", { p_id: id }),
    setReview: (on) => rpc("act_set_review", { p_on: on }),
    log: (orderId, chatId, kind, data) =>
      rpc("act_log", { p_order_id: orderId || null, p_chat_id: chatId || null, p_kind: kind, p_data: data || {} }),
    adminMsgAdd: (adminChatId, messageId, orderId) =>
      rpc("act_admin_msg_add", { p_admin_chat_id: String(adminChatId), p_message_id: messageId, p_order_id: orderId }),
    adminMsgOrder: (adminChatId, messageId) =>
      rpc("act_admin_msg_order", { p_admin_chat_id: String(adminChatId), p_message_id: messageId }),
  };
}

module.exports = { createDb };
