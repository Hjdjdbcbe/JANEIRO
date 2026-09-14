// ============================================================
// Janeiro Store — مُرمِّز QR صغير، بلا اعتماديات.
//
// وضع البايت، تصحيح خطأ M، النسخ 1–10 (حتى 213 بايتاً) — يكفي
// رابط تحقّق بمراحل.
//
// لماذا مكتوب هنا لا مستورَد: الدالة تعمل على Deno داخل Supabase،
// وكل استيراد خارجي نقطة فشل في وقت التشغيل لا يكشفها اختبار
// محلي. وهذا الملف يُقارَن بايتاً ببايت بمكتبة `qrcode` المرجعية
// في tests/local/qr.test.js، فصحّته مبرهنة لا مفترضة.
//
// المرجع: ISO/IEC 18004.
// ============================================================

// النسخة -> [كلمات التصحيح لكل كتلة, كتل المجموعة1, بيانات ك1, كتل م2, بيانات ك2]
const EC_M: Record<number, [number, number, number, number, number]> = {
  1: [10, 1, 16, 0, 0],   2: [16, 1, 28, 0, 0],   3: [26, 1, 44, 0, 0],
  4: [18, 2, 32, 0, 0],   5: [24, 2, 43, 0, 0],   6: [16, 4, 27, 0, 0],
  7: [18, 4, 31, 0, 0],   8: [22, 2, 38, 2, 39],  9: [22, 3, 36, 2, 37],
  10:[26, 4, 43, 1, 44],
};

// مراكز أنماط المحاذاة لكل نسخة
const ALIGN: Record<number, number[]> = {
  1: [], 2: [6,18], 3: [6,22], 4: [6,26], 5: [6,30],
  6: [6,34], 7: [6,22,38], 8: [6,24,42], 9: [6,26,46], 10:[6,28,50],
};

// ---------- حقل جالوا GF(256) ----------
const EXP = new Uint8Array(512);
const LOG = new Uint8Array(256);
(() => {
  let x = 1;
  for (let i = 0; i < 255; i++) {
    EXP[i] = x; LOG[x] = i;
    x <<= 1;
    if (x & 0x100) x ^= 0x11d;          // كثير الحدود البدائي
  }
  for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
})();

const mul = (a: number, b: number) =>
  a === 0 || b === 0 ? 0 : EXP[LOG[a] + LOG[b]];

/** كثير حدود المولّد لعدد كلمات تصحيح. */
function generator(n: number): Uint8Array {
  let g = new Uint8Array([1]);
  for (let i = 0; i < n; i++) {
    const next = new Uint8Array(g.length + 1);
    for (let j = 0; j < g.length; j++) {
      next[j] ^= g[j];
      next[j + 1] ^= mul(g[j], EXP[i]);
    }
    g = next;
  }
  return g;
}

/** كلمات تصحيح Reed-Solomon لكتلة بيانات. */
function ecBytes(data: Uint8Array, n: number): Uint8Array {
  const g = generator(n);
  const res = new Uint8Array(data.length + n);
  res.set(data);
  for (let i = 0; i < data.length; i++) {
    const factor = res[i];
    if (factor === 0) continue;
    for (let j = 0; j < g.length; j++) res[i + j] ^= mul(g[j], factor);
  }
  return res.slice(data.length);
}

// ---------- معلومات الصيغة والنسخة ----------
function formatBits(mask: number): number {
  // مستوى M = 00
  let v = (0b00 << 3) | mask;
  let d = v << 10;
  for (let i = 4; i >= 0; i--) {
    if (d & (1 << (i + 10))) d ^= 0b10100110111 << i;
  }
  return ((v << 10) | d) ^ 0b101010000010010;
}

function versionBits(version: number): number {
  let d = version << 12;
  for (let i = 5; i >= 0; i--) {
    if (d & (1 << (i + 12))) d ^= 0b1111100100101 << i;
  }
  return (version << 12) | d;
}

// ---------- البناء ----------
type Grid = { size: number; mod: Int8Array; fn: Uint8Array };

const at = (g: { size: number; mod: Int8Array }, r: number, c: number) =>
  g.mod[r * g.size + c];
const set = (g: Grid, r: number, c: number, v: number, isFn = false) => {
  g.mod[r * g.size + c] = v;
  if (isFn) g.fn[r * g.size + c] = 1;
};

function placeFunctionPatterns(g: Grid, version: number) {
  const n = g.size;

  // أنماط البحث الثلاثة ومناطق فصلها
  for (const [br, bc] of [[0, 0], [0, n - 7], [n - 7, 0]] as const) {
    for (let r = -1; r <= 7; r++) {
      for (let c = -1; c <= 7; c++) {
        const rr = br + r, cc = bc + c;
        if (rr < 0 || rr >= n || cc < 0 || cc >= n) continue;
        const on = (r >= 0 && r <= 6 && (c === 0 || c === 6)) ||
                   (c >= 0 && c <= 6 && (r === 0 || r === 6)) ||
                   (r >= 2 && r <= 4 && c >= 2 && c <= 4);
        set(g, rr, cc, on ? 1 : 0, true);
      }
    }
  }

  // أنماط المحاذاة، عدا ما يصطدم بأنماط البحث
  const centers = ALIGN[version];
  for (const r of centers) {
    for (const c of centers) {
      if ((r === 6 && c === 6) || (r === 6 && c === n - 7) || (r === n - 7 && c === 6)) continue;
      for (let dr = -2; dr <= 2; dr++) {
        for (let dc = -2; dc <= 2; dc++) {
          const on = Math.max(Math.abs(dr), Math.abs(dc)) !== 1;
          set(g, r + dr, c + dc, on ? 1 : 0, true);
        }
      }
    }
  }

  // أنماط التوقيت
  for (let i = 8; i < n - 8; i++) {
    const v = i % 2 === 0 ? 1 : 0;
    set(g, 6, i, v, true);
    set(g, i, 6, v, true);
  }

  // الوحدة الداكنة، ومواضع الصيغة محجوزة
  set(g, n - 8, 8, 1, true);
  for (let i = 0; i < 9; i++) {
    if (i !== 6) { set(g, 8, i, 0, true); set(g, i, 8, 0, true); }
  }
  for (let i = 0; i < 8; i++) {
    set(g, 8, n - 1 - i, 0, true);
    if (n - 1 - i !== n - 8) set(g, n - 1 - i, 8, 0, true);
  }

  // معلومات النسخة (7 فأعلى)
  if (version >= 7) {
    const bits = versionBits(version);
    for (let i = 0; i < 18; i++) {
      const b = (bits >> i) & 1;
      const r = Math.floor(i / 3), c = i % 3;
      set(g, n - 11 + c, r, b, true);
      set(g, r, n - 11 + c, b, true);
    }
  }
}

function placeFormat(g: Grid, mask: number) {
  const n = g.size;
  const bits = formatBits(mask);
  for (let i = 0; i < 15; i++) {
    // الأعلى قيمةً أولاً. كان الترتيب معكوساً، فكانت الصيغة تُقرأ
    // مقلوبة — والرمز يبدو سليماً تماماً ولا يُقرأ. كشفته المقارنة
    // بالمرجع، لا النظر.
    const b = (bits >> (14 - i)) & 1;

    // النسخة الأولى، حول نمط البحث الأعلى-يسار
    if (i < 6)        set(g, 8, i, b, true);
    else if (i === 6) set(g, 8, 7, b, true);
    else if (i === 7) set(g, 8, 8, b, true);
    else if (i === 8) set(g, 7, 8, b, true);
    else              set(g, 14 - i, 8, b, true);

    // والنسخة الثانية: سبعة بتات صاعدة في العمود 8، ثم ثمانية في
    // الصفّ 8. الحدّ عند 7 لا 8: الموضع (n-8, 8) هو الوحدة الداكنة
    // الثابتة لا بت صيغة، وكتابته كانت تزيح كل ما بعده.
    if (i < 7) set(g, n - 1 - i, 8, b, true);
    else       set(g, 8, n - 15 + i, b, true);
  }
  // والوحدة الداكنة تبقى داكنة مهما جرى
  set(g, n - 8, 8, 1, true);
}

const MASKS: ((r: number, c: number) => boolean)[] = [
  (r, c) => (r + c) % 2 === 0,
  (r) => r % 2 === 0,
  (_r, c) => c % 3 === 0,
  (r, c) => (r + c) % 3 === 0,
  (r, c) => (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0,
  (r, c) => ((r * c) % 2) + ((r * c) % 3) === 0,
  (r, c) => (((r * c) % 2) + ((r * c) % 3)) % 2 === 0,
  (r, c) => (((r + c) % 2) + ((r * c) % 3)) % 2 === 0,
];

/** عقوبات النمط الأربع — اختيار القناع يتبعها. */
function penalty(g: Grid): number {
  const [a, b, c, d] = penaltyParts(g);
  return a + b + c + d;
}

/** مفصّلة، ليقارنها الاختبار قاعدةً بقاعدة بالمرجع. */
export function penaltyParts(g: { size: number; mod: Int8Array }): number[] {
  const n = g.size;
  let p1 = 0, p2 = 0, p3 = 0, p4 = 0;

  // 1: خمسة متتالية فأكثر
  for (const byRow of [true, false]) {
    for (let a = 0; a < n; a++) {
      let run = 1, prev = -1;
      for (let b = 0; b < n; b++) {
        const v = byRow ? at(g, a, b) : at(g, b, a);
        if (v === prev) { run++; if (run === 5) p1 += 3; else if (run > 5) p1++; }
        else { prev = v; run = 1; }
      }
    }
  }
  // 2: مربعات 2×2
  for (let r = 0; r < n - 1; r++) {
    for (let c = 0; c < n - 1; c++) {
      const v = at(g, r, c);
      if (v === at(g, r, c + 1) && v === at(g, r + 1, c) && v === at(g, r + 1, c + 1)) p2 += 3;
    }
  }
  // 3: النمط 1011101 مع أربع فراغات
  const A = [1,0,1,1,1,0,1,0,0,0,0], B = [0,0,0,0,1,0,1,1,1,0,1];
  for (const byRow of [true, false]) {
    for (let a = 0; a < n; a++) {
      for (let b = 0; b + 10 < n; b++) {
        let mA = true, mB = true;
        for (let k = 0; k < 11; k++) {
          const v = byRow ? at(g, a, b + k) : at(g, b + k, a);
          if (v !== A[k]) mA = false;
          if (v !== B[k]) mB = false;
        }
        if (mA) p3 += 40;
        if (mB) p3 += 40;
      }
    }
  }
  // 4: انحراف نسبة الداكن عن النصف
  let dark = 0;
  for (let i = 0; i < n * n; i++) if (g.mod[i] === 1) dark++;
  p4 = Math.floor(Math.abs(dark * 20 - n * n * 10) / (n * n)) * 10;
  return [p1, p2, p3, p4];
}

/** النص -> مصفوفة وحدات. */
export function qrMatrix(text: string, forceMask?: number): number[][] {
  const bytes = new TextEncoder().encode(text);

  // أصغر نسخة تتّسع
  let version = 0;
  for (let v = 1; v <= 10; v++) {
    const [ec, b1, d1, b2, d2] = EC_M[v];
    const dataWords = b1 * d1 + b2 * d2;
    const countBits = v >= 10 ? 16 : 8;
    if (bytes.length <= Math.floor((dataWords * 8 - 4 - countBits) / 8)) { version = v; break; }
  }
  if (!version) throw new Error("QR_TOO_LONG");

  const [ecLen, b1, d1, b2, d2] = EC_M[version];
  const dataWords = b1 * d1 + b2 * d2;
  const countBits = version >= 10 ? 16 : 8;

  // ---- تيار البتات ----
  const bits: number[] = [];
  const push = (val: number, len: number) => {
    for (let i = len - 1; i >= 0; i--) bits.push((val >> i) & 1);
  };
  push(0b0100, 4);                 // وضع البايت
  push(bytes.length, countBits);
  for (const b of bytes) push(b, 8);

  const cap = dataWords * 8;
  push(0, Math.min(4, cap - bits.length));        // منهي
  while (bits.length % 8) bits.push(0);
  const pad = [0xec, 0x11];
  for (let i = 0; bits.length < cap; i++) push(pad[i % 2], 8);

  const words = new Uint8Array(dataWords);
  for (let i = 0; i < dataWords; i++) {
    for (let j = 0; j < 8; j++) words[i] = (words[i] << 1) | bits[i * 8 + j];
  }

  // ---- الكتل والتشابك ----
  const blocks: Uint8Array[] = [];
  const ecs: Uint8Array[] = [];
  let off = 0;
  for (let i = 0; i < b1 + b2; i++) {
    const len = i < b1 ? d1 : d2;
    const blk = words.slice(off, off + len);
    off += len;
    blocks.push(blk);
    ecs.push(ecBytes(blk, ecLen));
  }
  const total = EC_M[version] && (dataWords + ecLen * (b1 + b2));
  const out = new Uint8Array(total);
  let k = 0;
  for (let i = 0; i < Math.max(d1, d2); i++) {
    for (const blk of blocks) if (i < blk.length) out[k++] = blk[i];
  }
  for (let i = 0; i < ecLen; i++) {
    for (const e of ecs) out[k++] = e[i];
  }

  // ---- الشبكة ----
  const size = version * 4 + 17;
  const base: Grid = { size, mod: new Int8Array(size * size).fill(-1), fn: new Uint8Array(size * size) };
  placeFunctionPatterns(base, version);

  // ---- وضع البتات في مسار الثعبان ----
  const dataBits: number[] = [];
  for (const b of out) for (let i = 7; i >= 0; i--) dataBits.push((b >> i) & 1);

  let bi = 0, up = true;
  const place = (g: Grid) => {
    for (let col = size - 1; col > 0; col -= 2) {
      if (col === 6) col--;                       // عمود التوقيت يُتخطّى
      for (let i = 0; i < size; i++) {
        const row = up ? size - 1 - i : i;
        for (const c of [col, col - 1]) {
          if (g.fn[row * size + c]) continue;
          g.mod[row * size + c] = bi < dataBits.length ? dataBits[bi++] : 0;
        }
      }
      up = !up;
    }
  };
  place(base);

  // ---- اختيار القناع بأقل عقوبة ----
  let best: Grid | null = null, bestScore = Infinity;
  for (let m = 0; m < 8; m++) {
    if (forceMask !== undefined && m !== forceMask) continue;
    const g: Grid = { size, mod: base.mod.slice(), fn: base.fn.slice() };
    for (let r = 0; r < size; r++) {
      for (let c = 0; c < size; c++) {
        if (g.fn[r * size + c]) continue;
        if (MASKS[m](r, c)) g.mod[r * size + c] ^= 1;
      }
    }
    placeFormat(g, m);
    const sc = penalty(g);
    if (sc < bestScore) { bestScore = sc; best = g; }
  }

  const g = best!;
  const grid: number[][] = [];
  for (let r = 0; r < size; r++) {
    grid.push(Array.from(g.mod.slice(r * size, (r + 1) * size), (v) => (v === 1 ? 1 : 0)));
  }
  return grid;
}

/** SVG مضمّن — لا ملف ولا طلب شبكة. */
/** للاختبار: المصفوفة كـGrid لحساب العقوبات عليها. */
export function gridOf(matrix: number[][]): { size: number; mod: Int8Array } {
  const size = matrix.length;
  const mod = new Int8Array(size * size);
  for (let r = 0; r < size; r++) for (let c = 0; c < size; c++) mod[r * size + c] = matrix[r][c];
  return { size, mod };
}

export function qrSvg(text: string, px = 80): string {
  let grid: number[][];
  try { grid = qrMatrix(text); }
  catch { return ""; }               // رابط طويل جداً: تُحذف الصورة لا تُكسر الصفحة
  const n = grid.length;
  const quiet = 2;                   // الهامش الصامت يصغَّر إلى 2 لتوفير مساحة
  const dim = n + quiet * 2;
  let d = "";
  for (let r = 0; r < n; r++) {
    for (let c = 0; c < n; c++) {
      if (grid[r][c]) d += `M${c + quiet} ${r + quiet}h1v1h-1z`;
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${px}" ` +
    `viewBox="0 0 ${dim} ${dim}" shape-rendering="crispEdges" role="img" aria-hidden="true">` +
    `<rect width="${dim}" height="${dim}" fill="#fff"/>` +
    `<path d="${d}" fill="#000"/></svg>`;
}
