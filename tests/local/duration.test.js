/* ============================================================
   صيغة المدة في اللغات الثلاث.

     node tests/local/duration.test.js

   العربية تعدّ على أربع صيغ لا اثنتين: مفرد، مثنّى، جمع قلّة
   إلى العشرة، ثم تمييز مفرد منصوب من أحد عشر فصاعداً. الشيفرة
   التي تكتفي بـ n===1 تُخرج «2 شهر» و«12 أشهر»، وكلاهما خطأ
   يقرأه الزبون في وثيقته.

   والوثيقة تُقرأ ولا تُختبر بالعين في كل إصدار، فهنا تُثبَّت.
   ============================================================ */
const { execFileSync } = require("child_process");
const path = require("path");
const ROOT = path.resolve(__dirname, "../..");
const I18N = path.join(ROOT, "supabase/functions/telegram-bot/i18n.ts");

try { execFileSync("deno", ["--version"], { stdio: "ignore" }); }
catch { console.log("SKIP  duration: deno غير مثبّت."); process.exit(0); }

let passed = 0;
const green = (s) => `\x1b[32m${s}\x1b[0m`;
const red   = (s) => `\x1b[31m${s}\x1b[0m`;
function assert(cond, msg) {
  if (cond) { passed++; console.log(green(`PASS  ${msg}`)); }
  else { console.log(red(`FAIL: ${msg}`)); process.exitCode = 1; process.exit(1); }
}

/* كل الحالات في نداء واحد: بدء Deno أبطأ من الحساب نفسه بكثير. */
const CASES = [
  // [lang, months, bonus, days]
  ["ar", 1, 0, null], ["ar", 2, 0, null], ["ar", 3, 0, null],
  ["ar", 10, 0, null], ["ar", 11, 0, null], ["ar", 12, 0, null],
  ["ar", null, 0, 1], ["ar", null, 0, 2], ["ar", null, 0, 7],
  ["ar", null, 0, 45], ["ar", 12, 1, null], ["ar", 12, 2, null],
  ["ar", 12, 7, null], ["ar", 12, 14, null], ["ar", null, 7, 45],
  ["fr", 1, 0, null], ["fr", 2, 0, null], ["fr", 12, 0, null],
  ["fr", null, 0, 1], ["fr", null, 0, 45], ["fr", 12, 1, null], ["fr", 12, 7, null],
  ["en", 1, 0, null], ["en", 2, 0, null], ["en", 12, 0, null],
  ["en", null, 0, 1], ["en", null, 0, 45], ["en", 12, 1, null], ["en", 12, 7, null],
];

const out = JSON.parse(execFileSync("deno", ["eval", "--quiet",
  `import { DOC } from "${I18N}";\n` +
  `const cs = ${JSON.stringify(CASES)};\n` +
  `console.log(JSON.stringify(cs.map(([l,m,b,d]) => DOC[l].duration(m,b,d))));`],
  { encoding: "utf8",
    env: { ...process.env, DENO_DIR: process.env.DENO_DIR || path.join(ROOT, ".deno-cache") } }));

const EXPECT = [
  "شهر", "شهران", "3 أشهر", "10 أشهر", "11 شهراً", "12 شهراً",
  "يوم", "يومان", "7 أيام", "45 يوماً",
  "12 شهراً + يوم هدية", "12 شهراً + يومان هدية",
  "12 شهراً + 7 أيام هدية", "12 شهراً + 14 يوماً هدية",
  "45 يوماً + 7 أيام هدية",
  "1 mois", "2 mois", "12 mois", "1 jour", "45 jours",
  "12 mois + 1 jour offert", "12 mois + 7 jours offerts",
  "1 month", "2 months", "12 months", "1 day", "45 days",
  "12 months + 1 day free", "12 months + 7 days free",
];

CASES.forEach(([l, m, b, d], i) => {
  const what = `${l}: ${m ?? "—"} شهر / ${d ?? "—"} يوم / ${b} هدية`;
  assert(out[i] === EXPECT[i],
         `${what} → «${EXPECT[i]}»` + (out[i] === EXPECT[i] ? "" : ` — وجد «${out[i]}»`));
});

// وما لا يُقبل أصلاً: لا «2 شهر» ولا «12 أشهر» في أي مخرَج عربي
const arAll = out.slice(0, 15).join(" | ");
assert(!/\b2 شهر\b/.test(arAll), "لا «2 شهر» في أي صيغة");
assert(!/\b(1[1-9]|[2-9]\d) أشهر\b/.test(arAll), "ولا «12 أشهر»");
assert(!/\b2 (يوم|أيام)\b/.test(arAll), "ولا «2 أيام»");

console.log(green(`\nDURATION PASSED (${passed} فحصاً)`));
