// ============================================================
// POST /functions/v1/upload-receipt   (multipart/form-data)
// fields: order_id, file
//
// Validates type/size, ignores the client-supplied filename,
// stores into the PRIVATE receipts bucket via service role.
// ============================================================
import { cors, json, serviceClient, clientIp, mapError, ipRateLimit } from "../_shared/util.ts";

const MAX_BYTES = 5 * 1024 * 1024;
const ALLOWED: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
};

/** Content-Type headers are trivially forged — verify the actual bytes. */
function sniff(bytes: Uint8Array): string | null {
  if (bytes.length < 12) return null;
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "image/jpeg";
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47)
    return "image/png";
  const riff = String.fromCharCode(...bytes.slice(0, 4));
  const webp = String.fromCharCode(...bytes.slice(8, 12));
  if (riff === "RIFF" && webp === "WEBP") return "image/webp";
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  const db = serviceClient();
  const ip = clientIp(req);

  try {
    if (!(await ipRateLimit(db, ip, "upload_receipt", 20, 10))) {
      return json({ ok: false, code: "RATE_LIMITED",
        message: "عدد المحاولات كبير. انتظر قليلاً ثم أعد المحاولة." }, 429);
    }

    const form = await req.formData();
    const orderId = String(form.get("order_id") ?? "");
    const file = form.get("file");

    if (!orderId || !(file instanceof File)) {
      return json({ ok: false, code: "INVALID_REQUEST", message: "طلب غير صالح." }, 400);
    }
    if (file.size > MAX_BYTES) {
      return json({ ok: false, code: "FILE_TOO_LARGE",
        message: "حجم الصورة يتجاوز 5 ميغابايت." }, 400);
    }

    const bytes = new Uint8Array(await file.arrayBuffer());
    const realType = sniff(bytes);
    if (!realType || !ALLOWED[realType]) {
      return json({ ok: false, code: "INVALID_FILE_TYPE",
        message: "الملف يجب أن يكون صورة JPG أو PNG أو WebP." }, 400);
    }

    // order must exist and still be awaiting its receipt
    const { data: order, error: oErr } = await db
      .from("orders")
      .select("id, order_number, status, receipt_path")
      .eq("id", orderId)
      .single();

    if (oErr || !order) {
      return json({ ok: false, code: "ORDER_NOT_FOUND", message: "لم نعثر على الطلب." }, 404);
    }
    if (order.status !== "awaiting_receipt") {
      return json({ ok: false, code: "ORDER_ALREADY_SUBMITTED",
        message: "تم إرسال هذا الطلب مسبقاً." }, 409);
    }

    // Server-generated filename. The client's name is never used.
    const ext = ALLOWED[realType];
    const path = `orders/${order.order_number}/${crypto.randomUUID()}.${ext}`;

    const { error: upErr } = await db.storage
      .from("receipts")
      .upload(path, bytes, { contentType: realType, upsert: false });

    if (upErr) {
      console.error("upload failed", upErr);
      return json({ ok: false, code: "UPLOAD_FAILED",
        message: "تعذر رفع الوصل. حاول مرة أخرى." }, 500);
    }

    // replace any previous receipt for this order
    if (order.receipt_path) {
      await db.storage.from("receipts").remove([order.receipt_path]);
    }

    const { error: updErr } = await db
      .from("orders")
      .update({ receipt_path: path, receipt_uploaded_at: new Date().toISOString() })
      .eq("id", orderId);

    if (updErr) {
      await db.storage.from("receipts").remove([path]); // don't orphan the file
      console.error("order update failed", updErr);
      return json({ ok: false, code: "UPLOAD_FAILED",
        message: "تعذر حفظ الوصل. حاول مرة أخرى." }, 500);
    }

    // Note: we return no URL. The receipt is private by design.
    return json({ ok: true, uploaded: true, size: file.size, type: realType });
  } catch (err) {
    const m = mapError(err);
    return json({ ok: false, ...m }, 500);
  }
});
