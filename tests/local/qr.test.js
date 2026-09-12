/* ============================================================
   مُرمِّز QR في supabase/functions/telegram-bot/qr.ts مكتوب بيدٍ
   بلا اعتماديات. هنا يُبرهن لا يُفترض.

     node tests/local/qr.test.js

   ثلاث مقارنات، كلٌّ بمرجعها الصحيح:

   1. المصفوفة كاملة، بقناع المرجع نفسه — تُثبت الترميز وكلمات
      التصحيح والتشابك ومسار الوضع وبتات الصيغة.
   2. عقوبات الأنماط 1 و2 و3 — بمكتبة `qrcode` على npm.
   3. العقوبة 4 — بالمعيار نفسه، لا بالمكتبة: المكتبة تحسبها
      ceil(pct/5)-10 فتعاقب 50.1% كأنها 55%، بينما ISO/IEC 18004
      تأخذ أقرب مضاعف للخمسة. فاختيارنا للقناع قد يفارق اختيارها
      عن حقّ، ولهذا يُلزَم القناع في المقارنة الأولى.

   المكتبة أداة اختبار لا تُشحن: الدالة على Supabase لا تستوردها.
   بلا هذه المقارنة تبقى صحّة المُرمِّز ظنّاً — ورمز QR خاطئ لا
   يبدو خاطئاً، يبدو رمزاً.
   ============================================================ */
const { execFileSync } = require("child_process");
const path = require("path");
const ROOT = path.resolve(__dirname, "../..");
const QR_TS = path.join(ROOT, "supabase/functions/telegram-bot/qr.ts");

let QR, MP, BitMatrix;
for (const base of ["/tmp/qrref/node_modules/qrcode", "qrcode"]) {
  try {
    QR = require(base);
    MP = require(`${base}/lib/core/mask-pattern`);
    BitMatrix = require(`${base}/lib/core/bit-matrix`);
    break;
  } catch { /* التالي */ }
}
if (!QR) {
  console.log("SKIP  qr: مكتبة qrcode المرجعية غير مثبّتة.");
  console.log("      npm install qrcode --no-save   ثم أعد التشغيل.");
  process.exit(0);
}
try { execFileSync("deno", ["--version"], { stdio: "ignore" }); }
catch { console.log("SKIP  qr: deno غير مثبّت."); process.exit(0); }

const green = (s) => `\x1b[32m${s}\x1b[0m`;
const red   = (s) => `\x1b[31m${s}\x1b[0m`;
let passed = 0;
function assert(cond, msg) {
  if (cond) { passed++; console.log(green(`PASS  ${msg}`)); }
  else { console.log(red(`FAIL: ${msg}`)); process.exitCode = 1; process.exit(1); }
}

const deno = (expr) => JSON.parse(execFileSync("deno", ["eval", "--quiet",
  `import { qrMatrix, gridOf, penaltyParts, qrSvg } from "${QR_TS}";\nconsole.log(JSON.stringify(${expr}));`],
  { encoding: "utf8",
    env: { ...process.env, DENO_DIR: process.env.DENO_DIR || path.join(ROOT, ".deno-cache") } }));

const ours = (text, mask) => deno(`qrMatrix(${JSON.stringify(text)}, ${mask})`);
const ourPenalty = (text, mask) =>
  deno(`penaltyParts(gridOf(qrMatrix(${JSON.stringify(text)}, ${mask})))`);

/* وضع البايت مُلزَم: المكتبة تُحسّن تلقائياً فتقسّم النصّ إلى
   مقاطع (alphanumeric لجزء الرابط الكبير) فتنتج مصفوفة أخرى —
   صحيحة، لكنها ليست ما يفعله مُرمِّزنا، وهو وضع بايت عمداً:
   رمز أكبر قليلاً مقابل ثلث الكود ونصف مواضع الخطأ. */
function refQr(text) {
  return QR.create([{ data: text, mode: "byte" }], { errorCorrectionLevel: "M" });
}
function refMatrix(qr) {
  const n = qr.modules.size, d = qr.modules.data, g = [];
  for (let r = 0; r < n; r++) g.push(Array.from({ length: n }, (_, c) => (d[r * n + c] ? 1 : 0)));
  return g;
}

/** العقوبة 4 كما يعرّفها المعيار: أقرب مضاعف للخمسة، لا الأعلى. */
function specN4(matrix) {
  const n = matrix.length, total = n * n;
  let dark = 0;
  for (const row of matrix) for (const v of row) dark += v;
  const pct = (dark * 100) / total;
  const prev = Math.floor(pct / 5) * 5, next = Math.ceil(pct / 5) * 5;
  return (Math.min(Math.abs(prev - 50), Math.abs(next - 50)) / 5) * 10;
}

const CASES = [
  "a",
  "Janeiro Store",
  "JW-0000000000",
  "https://janeiro-store.com/warranty/verify/JW-4E215725A2",
  "https://janeiro-store.com/warranty/verify/JW-FFFFFFFFFF?lang=fr",
  "x".repeat(60),
  "x".repeat(120),
  "https://a-very-long-domain-name-for-testing.example.com/warranty/verify/JW-ABCDEF0123",
];

// ---------- 1. المصفوفة كاملة ----------
for (const text of CASES) {
  const qr = refQr(text);
  const ref = refMatrix(qr);
  const got = ours(text, qr.maskPattern);
  const label = text.length > 40 ? text.slice(0, 37) + "…" : text;

  assert(got.length === ref.length,
    `v${qr.version} ${ref.length}×${ref.length} — «${label}»`);
  let diff = 0;
  for (let r = 0; r < ref.length; r++)
    for (let c = 0; c < ref.length; c++) if (got[r][c] !== ref[r][c]) diff++;
  assert(diff === 0,
    `  كل وحدة تطابق المرجع${diff ? ` (${diff} مختلفة)` : ""}`);
}

// ---------- 2 و3. العقوبات ----------
for (const text of [CASES[3], CASES[7], "x".repeat(60)]) {
  const label = text.length > 40 ? text.slice(0, 37) + "…" : text;
  for (let m = 0; m < 8; m++) {
    const matrix = ours(text, m);
    const mine = ourPenalty(text, m);
    const n = matrix.length;
    const bm = new BitMatrix(n);
    for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) bm.data[r * n + c] = matrix[r][c];
    const ref = [MP.getPenaltyN1(bm), MP.getPenaltyN2(bm), MP.getPenaltyN3(bm)];
    if (mine[0] !== ref[0] || mine[1] !== ref[1] || mine[2] !== ref[2]) {
      assert(false, `عقوبات 1/2/3 عند القناع ${m} — «${label}»: ` +
        `لي ${mine.slice(0,3).join("/")} مقابل ${ref.join("/")}`);
    }
    if (mine[3] !== specN4(matrix)) {
      assert(false, `العقوبة 4 عند القناع ${m} تخالف المعيار — «${label}»: ` +
        `لي ${mine[3]} والمعيار ${specN4(matrix)}`);
    }
  }
  assert(true, `العقوبات الأربع تطابق (8 أقنعة) — «${label}»`);
}

// ---------- 4. الحدود ----------
const svg = deno(`qrSvg("https://janeiro-store.com/warranty/verify/JW-4E215725A2", 74)`);
assert(typeof svg === "string" && svg.startsWith("<svg") && svg.includes("<path"),
  "qrSvg يخرج SVG مضمّناً بلا طلب شبكة");
const empty = deno(`qrSvg("x".repeat(400), 74)`);
assert(empty === "",
  "ونصّ أطول من النسخة 10 يُسقط الصورة بدل أن يكسر الصفحة");

console.log(`\n${green(`QR MATCHES THE STANDARD (${passed} فحصاً، ${CASES.length} حالة)`)}`);
