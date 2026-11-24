// motion-video-kit 共用:模板解析、template.json 檢查、storyboard schema 驗證、字幕分詞、時間軸、ffmpeg 小工具。只用 Node 內建模組。
import { readFileSync, existsSync, statSync, realpathSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { resolve, join, dirname, isAbsolute, sep, extname } from 'node:path';
import { fileURLToPath } from 'node:url';

export const KIT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const SVK = resolve(KIT, '../short-video-kit/scripts');   // short-video-kit(Chrome CDP、混音共用)
export const GAK = resolve(KIT, '../game-art-kit');              // game-art-kit(ComfyUI)
export const TEMPLATES = join(KIT, 'templates');
export const DEFAULT_TEMPLATE = 'github-hot-pastel';

// 結束碼通則:0 成功;2 輸入不合法;3 缺工具或模板;4 版面放不下;5 ComfyUI 連不上;1 其他
export class Fail extends Error { constructor(msg, code = 1) { super(msg); this.code = code; } }
export const fail = (msg, code = 1) => { throw new Fail(msg, code); };
export function main(fn) {
  Promise.resolve().then(fn).catch((e) => {
    console.error(`錯誤:${e instanceof Fail ? e.message : e?.stack || e}`);
    process.exit(e instanceof Fail ? e.code : 1);
  });
}
export const r3 = (x) => Math.round(x * 1000) / 1000;

// ---------- 參數 ----------
// spec:{ '--x': 'value' | 'flag' };回傳 { _: [位置參數], x: 值 }
export function parseArgs(argv, spec, usage) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      if (!(a in spec)) fail(`未知參數:${a}\n${usage}`, 2);
      const k = a.slice(2);
      if (spec[a] === 'flag') out[k] = true;
      else { if (i + 1 >= argv.length) fail(`${a} 缺值\n${usage}`, 2); out[k] = argv[++i]; }
    } else out._.push(a);
  }
  return out;
}

// ---------- 外部程式 ----------
export function run(cmd, args, label, opts = {}) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, ...opts });
  if (r.error) fail(`${label}:${r.error.message}`, r.error.code === 'ENOENT' ? 3 : 1);
  if (r.status !== 0) { console.error((r.stderr || '').split('\n').slice(-20).join('\n')); fail(`${label} 失敗(結束碼 ${r.status})`); }
  return r;
}
export const probeDuration = (f) => Number(run('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', f], 'ffprobe').stdout.trim());
export function probeSize(f) {
  const r = spawnSync('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'csv=s=x:p=0', f], { encoding: 'utf8' });
  const m = (r.stdout || '').trim().match(/^(\d+)x(\d+)/);
  return m ? [Number(m[1]), Number(m[2])] : null;
}
export function maxVolume(f) {
  const r = spawnSync('ffmpeg', ['-hide_banner', '-nostats', '-i', f, '-af', 'volumedetect', '-f', 'null', '-'], { encoding: 'utf8' });
  const m = (r.stderr || '').match(/max_volume:\s*(-?[\d.]+|-inf) dB/);
  return m ? (m[1] === '-inf' ? -Infinity : Number(m[1])) : -Infinity;
}
export const CHROME = process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
export const hasCmd = (c) => spawnSync('/bin/sh', ['-c', `command -v ${c}`], { encoding: 'utf8' }).status === 0;

// ---------- 模板 ----------
export const REQUIRED_TEMPLATE_KEYS = ['size', 'fps', 'palette', 'fonts', 'scenes', 'mascot', 'tag', 'safe', 'minFont', 'maxLineChars'];
export const SCENE_TYPES = ['title', 'image', 'compare', 'terminal', 'chips', 'checklist', 'grid', 'stat', 'cta'];

// 解析順序:路徑(含 / 或是存在的目錄)→ <out>/_templates/<名稱> → kit 預設 templates/<名稱>
export function resolveTemplate({ name, dir, out } = {}) {
  if (dir) {
    const p = resolve(dir);
    if (!existsSync(join(p, 'template.json'))) fail(`找不到模板:${p}(沒有 template.json)`, 3);
    return { dir: realpathSync(p), source: 'path' };
  }
  name = name || DEFAULT_TEMPLATE;
  if (name.includes('/') || name.startsWith('.')) return resolveTemplate({ dir: name });
  if (!/^[a-z0-9][a-z0-9-]*$/.test(name)) fail(`模板名稱只能是小寫英數與 -:${name}`, 2);
  if (out) {
    const p = join(resolve(out), '_templates', name);
    if (existsSync(join(p, 'template.json'))) return { dir: realpathSync(p), source: 'project' };
  }
  const p = join(TEMPLATES, name);
  if (existsSync(join(p, 'template.json'))) return { dir: realpathSync(p), source: 'kit' };
  fail(`找不到模板 ${name}(找過${out ? ` ${join(resolve(out), '_templates', name)}、` : ''} ${p})`, 3);
}

const isRect = (r) => Array.isArray(r) && r.length === 4 && r.every(Number.isFinite) && r[0] < r[2] && r[1] < r[3];
// 回傳 { tpl, problems:[…] };problems 非空表示模板不合格(結束碼 3)
export function loadTemplate(dir) {
  const problems = [];
  let tpl = null;
  try { tpl = JSON.parse(readFileSync(join(dir, 'template.json'), 'utf8')); } catch (e) { return { tpl: null, problems: [`template.json 讀不到或不是 JSON:${e.message}`] }; }
  for (const k of REQUIRED_TEMPLATE_KEYS) if (tpl[k] === undefined) problems.push(`template.json 缺 ${k}`);
  if (tpl.size !== undefined && !(Array.isArray(tpl.size) && tpl.size.length === 2 && tpl.size.every(n => Number.isInteger(n) && n > 0 && n % 2 === 0))) problems.push('size 要是 [寬,高](偶數整數)');
  if (tpl.fps !== undefined && !(Number.isInteger(tpl.fps) && tpl.fps >= 10 && tpl.fps <= 60)) problems.push('fps 要是 10–60 的整數');
  if (tpl.palette !== undefined) for (const [k, v] of Object.entries(tpl.palette)) {
    const vals = Array.isArray(v) ? v : [v];
    if (!vals.every(c => /^#[0-9a-fA-F]{6}$/.test(String(c)))) problems.push(`palette.${k} 要是 #RRGGBB(或其陣列)`);
  }
  if (tpl.fonts !== undefined && !(tpl.fonts && typeof tpl.fonts === 'object' && Object.values(tpl.fonts).every(f => typeof f === 'string' && /^[\w .-]+$/.test(f)))) problems.push('fonts 要是 {用途: 系統字型名稱}');
  if (tpl.scenes !== undefined && !(Array.isArray(tpl.scenes) && tpl.scenes.length && tpl.scenes.every(s => SCENE_TYPES.includes(s)))) problems.push(`scenes 只能列 ${SCENE_TYPES.join(' / ')}`);
  if (tpl.mascot !== undefined) {
    if (!(tpl.mascot && typeof tpl.mascot === 'object' && tpl.mascot.base)) problems.push('mascot 要是 {姿勢: 相對模板的檔案},且要有 base');
    else for (const [pose, f] of Object.entries(tpl.mascot)) {
      const p = resolve(dir, String(f));
      if (isAbsolute(String(f)) || !(p.startsWith(dir + sep)) || !existsSync(p)) problems.push(`mascot.${pose} 檔案不存在或不在模板內:${f}`);
    }
  }
  if (tpl.tag !== undefined && typeof tpl.tag !== 'string') problems.push('tag 要是字串');
  if (tpl.safe !== undefined && !(tpl.safe && isRect(tpl.safe.headline) && isRect(tpl.safe.subtitle))) problems.push('safe 要有 headline 與 subtitle 兩個 [x0,y0,x1,y1]');
  if (tpl.safe && tpl.size && [tpl.safe.headline, tpl.safe.subtitle].some(r => isRect(r) && (r[0] < 0 || r[1] < 0 || r[2] > tpl.size[0] || r[3] > tpl.size[1]))) problems.push('safe 的矩形超出 size');
  if (tpl.minFont !== undefined && !(Number.isFinite(tpl.minFont?.headline) && Number.isFinite(tpl.minFont?.subtitle))) problems.push('minFont 要是 {headline, subtitle}(px)');
  if (tpl.maxLineChars !== undefined && !(Number.isInteger(tpl.maxLineChars) && tpl.maxLineChars > 0)) problems.push('maxLineChars 要是正整數');
  if (tpl.cardInner !== undefined && !(Array.isArray(tpl.cardInner) && tpl.cardInner.length === 2 && tpl.cardInner.every(n => n > 0))) problems.push('cardInner 要是 [寬,高]');
  for (const f of ['template.html', 'README.md', 'sample.storyboard.json']) if (!existsSync(join(dir, f))) problems.push(`缺 ${f}`);
  return { tpl, problems };
}

// ---------- JSON Schema(只實作 storyboard.schema.json 用到的子集)----------
export function validateSchema(schema, data) {
  const errors = [];
  const deref = (s) => {
    while (s && s.$ref) {
      if (!s.$ref.startsWith('#/')) throw new Error(`不支援的 $ref:${s.$ref}`);
      s = s.$ref.slice(2).split('/').reduce((o, k) => o?.[k], schema);
    }
    return s;
  };
  const typeOf = (v) => Array.isArray(v) ? 'array' : v === null ? 'null' : Number.isInteger(v) ? 'integer' : typeof v;
  const typeOk = (v, t) => t === typeOf(v) || (t === 'number' && typeof v === 'number' && Number.isFinite(v));
  const walk = (s, v, path, errs) => {
    s = deref(s);
    if (!s || s === true) return;
    if (s.type && !(Array.isArray(s.type) ? s.type : [s.type]).some(t => typeOk(v, t))) { errs.push(`${path || '(根)'}:要是 ${s.type}`); return; }
    if (s.const !== undefined && v !== s.const) errs.push(`${path}:要是 ${JSON.stringify(s.const)}`);
    if (s.enum && !s.enum.includes(v)) errs.push(`${path}:只能是 ${s.enum.map(x => JSON.stringify(x)).join(' / ')}`);
    if (typeof v === 'string') {
      if (s.minLength !== undefined && [...v].length < s.minLength) errs.push(`${path}:至少 ${s.minLength} 個字`);
      if (s.maxLength !== undefined && [...v].length > s.maxLength) errs.push(`${path}:最多 ${s.maxLength} 個字`);
      if (s.pattern && !new RegExp(s.pattern, 'u').test(v)) errs.push(`${path}:格式不符(${s.pattern})`);
    }
    if (typeof v === 'number') {
      if (s.minimum !== undefined && v < s.minimum) errs.push(`${path}:要 ≥ ${s.minimum}`);
      if (s.maximum !== undefined && v > s.maximum) errs.push(`${path}:要 ≤ ${s.maximum}`);
      if (s.exclusiveMinimum !== undefined && v <= s.exclusiveMinimum) errs.push(`${path}:要 > ${s.exclusiveMinimum}`);
    }
    if (Array.isArray(v)) {
      if (s.minItems !== undefined && v.length < s.minItems) errs.push(`${path}:至少 ${s.minItems} 項`);
      if (s.maxItems !== undefined && v.length > s.maxItems) errs.push(`${path}:最多 ${s.maxItems} 項`);
      if (s.prefixItems) s.prefixItems.forEach((ps, i) => { if (i < v.length) walk(ps, v[i], `${path}[${i}]`, errs); });
      if (s.items) v.forEach((x, i) => { if (!s.prefixItems || i >= s.prefixItems.length) walk(s.items, x, `${path}[${i}]`, errs); });
    }
    if (v && typeof v === 'object' && !Array.isArray(v)) {
      for (const k of s.required ?? []) if (!(k in v)) errs.push(`${path ? path + '.' : ''}${k}:必填`);
      for (const [k, x] of Object.entries(v)) {
        const sub = `${path ? path + '.' : ''}${k}`;
        if (s.properties && k in s.properties) walk(s.properties[k], x, sub, errs);
        else if (s.additionalProperties === false) errs.push(`${sub}:不是可用欄位${s.properties ? `(可用:${Object.keys(s.properties).join(', ')})` : ''}`);
      }
    }
    for (const sub of s.allOf ?? []) walk(sub, v, path, errs);
    if (s.anyOf) {
      const tries = s.anyOf.map(sub => { const e = []; walk(sub, v, path, e); return e; });
      if (!tries.some(e => e.length === 0)) errs.push(...tries.reduce((a, b) => (b.length < a.length ? b : a)));
    }
    if (s.if) {
      const e = []; walk(s.if, v, path, e);
      if (e.length === 0 && s.then) walk(s.then, v, path, errs);
      else if (e.length && s.else) walk(s.else, v, path, errs);
    }
  };
  walk(schema, data, '', errors);
  return [...new Set(errors)];
}

// ---------- 字幕分詞 ----------
// text:半形空白 = 逐詞分段;*…* = 關鍵詞(橘色膠囊,可含空白)。
// 顯示時去掉 * 與分段空白;相鄰兩段交界都是英數字時保留一個空白。
const ALNUM = /[A-Za-z0-9]/;
export function tokenize(text) {
  if (typeof text !== 'string') fail('字幕要是字串', 2);
  const words = [];
  const parts = text.split('*');
  if (parts.length % 2 === 0) return { error: `「${text}」的 * 沒有成對` };
  parts.forEach((p, i) => {
    if (i % 2 === 1) { const w = p.trim().replace(/\s+/g, ' '); if (!w) return; words.push({ w, hl: true }); }
    else for (const w of p.split(/[ \t]+/)) if (w) words.push({ w, hl: false });
  });
  if (!words.length) return { error: `「${text}」沒有內容` };
  let display = '';
  words.forEach((x, i) => {
    if (i > 0 && ALNUM.test(display.slice(-1)) && ALNUM.test(x.w[0])) { display += ' '; x.space = true; }
    display += x.w;
  });
  for (const x of words) x.weight = weight(x.w);
  return { words, display };
}
// 念的時間比例:中日韓字 1、英數字詞 1、標點 0
export function weight(s) {
  const cjk = (s.match(/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/gu) || []).length;
  const latin = (s.match(/[A-Za-z0-9]+(?:[.'’-][A-Za-z0-9]+)*/g) || []).length;
  return cjk + latin;
}
export const lineText = (l) => (typeof l === 'string' ? l : l?.text);
export const lineSay = (l) => (typeof l === 'string' ? null : l?.say ?? null);

// ---------- 時間軸 ----------
// durations[i]:第 i 句(全片依序)的 TTS 長度。回傳 timing.json 物件與給頁面用的 scenes。
export function buildTimeline(board, durations) {
  const sentences = []; let t = 0;
  const sceneOf = [];
  board.scenes.forEach((sc, j) => sc.lines.forEach((l) => {
    const i = sentences.length; const d = durations[i];
    const start = i === 0 ? 0.3 : t + 0.25; const end = start + d; t = end;
    const tok = tokenize(lineText(l));
    const tw = tok.words.reduce((a, x) => a + x.weight, 0);
    let acc = 0;
    const words = tok.words.map((x) => {
      const ws = tw ? start + d * acc / tw : start; acc += x.weight;
      const we = tw ? start + d * acc / tw : end;
      return { w: x.w, start: r3(ws), end: r3(we), hl: x.hl, ...(x.space ? { space: true } : {}) };
    });
    sentences.push({ i: i + 1, start: r3(start), end: r3(end), text: tok.display, words });
    sceneOf.push(j);
  }));
  const duration = r3(t + 0.6);
  const firstIdx = []; sceneOf.forEach((j, i) => { if (firstIdx[j] === undefined) firstIdx[j] = i; });
  const scenes = board.scenes.map((sc, j) => {
    const start = j === 0 ? 0 : sentences[firstIdx[j]].start;
    const end = j + 1 < board.scenes.length ? sentences[firstIdx[j + 1]].start : duration;
    return { start: r3(start), end: r3(end), type: sc.card ? sc.card.type : 'title', mascot: sc.mascot ?? 'base' };
  });
  return { duration, sentences, scenes, sceneOf, firstIdx };
}

// at → 該場景句子裡第一個相符的分段詞(去掉 *)的開始時間;找不到回 null
export function findAt(timeline, j, at) {
  for (const s of timeline.sentences) {
    if (timeline.sceneOf[s.i - 1] !== j) continue;
    const w = s.words.find(x => x.w === at);
    if (w) return w.start;
  }
  return null;
}

// 節奏:changes、cardEmpty、rhythm(規格「時間軸」段)
export function rhythmOf(timeline, events) {
  // events:[{ scene, t, kind:'card'|'item', at:boolean }]
  const { sentences, scenes, duration } = timeline;
  const changes = [...new Set([...scenes.map(s => s.start), ...events.filter(e => e.at).map(e => e.t)].map(r3))].sort((a, b) => a - b);
  const cardEmpty = [];
  scenes.forEach((s, j) => {
    if (s.type === 'title') return;
    const first = Math.min(...events.filter(e => e.scene === j).map(e => e.t));
    if (Number.isFinite(first) && first - s.start > 0.001) cardEmpty.push({ start: r3(s.start), end: r3(Math.min(first, s.end)) });
  });
  const maxEmpty = r3(Math.max(0, ...cardEmpty.map(c => c.end - c.start)));
  const from = sentences[0].start, to = duration - 0.6;
  const c = changes.filter(x => x >= from - 0.001 && x <= to + 0.001);
  const gaps = c.slice(1).map((x, i) => r3(x - c[i]));
  const problems = [];
  if (maxEmpty > 2) problems.push(`卡片區空檔 ${maxEmpty} 秒 > 2`);
  gaps.forEach((g, i) => { if (g < 2 || g > 4) problems.push(`畫面變化 ${c[i]}→${c[i + 1]} 間隔 ${g} 秒(要 2–4)`); });
  for (const s of sentences) {
    if (s.end - s.start > 4 && !changes.some(x => x > s.start + 0.01 && x < s.end)) problems.push(`第 ${s.i} 句 ${r3(s.end - s.start)} 秒 > 4 秒,句內沒有 at 元素`);
  }
  const rhythm = { maxEmpty, minInterval: gaps.length ? Math.min(...gaps) : null, maxInterval: gaps.length ? Math.max(...gaps) : null, ok: problems.length === 0 };
  return { changes, cardEmpty, rhythm, problems };
}

// ---------- 圖片 ----------
export const IMG_EXT = new Set(['.png', '.jpg', '.jpeg', '.webp']);
// rel 相對 --asset-root(可多個,依序找第一個存在的;解析 symlink 後必須仍在該 root 內)
export function resolveAsset(rel, roots, where) {
  if (typeof rel !== 'string' || !rel || isAbsolute(rel) || /^[a-z][a-z0-9+.-]*:/i.test(rel)) fail(`${where}:圖片只能是 --asset-root 內的相對路徑:${rel}`, 2);
  if (!roots.length) fail(`${where}:沒有給 --asset-root,不接受圖片`, 2);
  for (const root of roots) {
    const p = resolve(root, rel);
    if (!existsSync(p)) continue;
    const real = realpathSync(p);
    if (real !== root && !real.startsWith(root + sep)) fail(`${where}:圖片在 --asset-root 外(symlink 解析後):${rel}`, 2);
    if (!statSync(real).isFile()) fail(`${where}:不是檔案:${rel}`, 2);
    if (!IMG_EXT.has(extname(real).toLowerCase())) fail(`${where}:只接受 png / jpg / webp:${rel}`, 2);
    if (statSync(real).size > 30 * 1024 * 1024) fail(`${where}:圖片超過 30 MB:${rel}`, 2);
    return real;
  }
  fail(`${where}:找不到圖片 ${rel}(找過 ${roots.join('、')})`, 2);
}

export const srtTime = (x) => {
  const ms = Math.round(x * 1000); const h = Math.floor(ms / 3600000), m = Math.floor(ms / 60000) % 60, s = Math.floor(ms / 1000) % 60;
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')},${String(ms % 1000).padStart(3, '0')}`;
};

// ---------- 念法對照表(pronunciation.json)----------
// {"words":{"網站":"網 站"}}:TTS 念的文字裡出現 key 就換成 value(字幕不變)。
// 一次掃過、長的 key 優先,替換結果不會再被替換。
export function loadLexicon(files) {
  const words = {};
  for (const f of files) {
    let j; try { j = JSON.parse(readFileSync(f, 'utf8')); } catch (e) { fail(`讀不到念法對照表 ${f}:${e.message}`, 2); }
    if (!j || typeof j.words !== 'object' || Array.isArray(j.words)) fail(`念法對照表 ${f} 要有 "words" 物件`, 2);
    for (const [k, v] of Object.entries(j.words)) {
      if (!k || typeof v !== 'string' || !v.trim()) fail(`念法對照表 ${f}:「${k}」的值要是非空字串`, 2);
      words[k] = v;   // 後面的檔案(專案)蓋過前面的(kit)
    }
  }
  return words;
}
export function applyLexicon(text, words) {
  const keys = Object.keys(words).sort((a, b) => b.length - a.length);
  if (!keys.length) return text;
  const re = new RegExp(keys.map(k => k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|'), 'g');
  return text.replace(re, m => words[m]);
}

// ---------- 語音辨識比對(asr.mjs)----------
// 只比字母與數字(去標點、空白、大小寫);繁簡 / 同音代名詞等辨識常見差異視為相同。
const ASR_SAME = { '臺': '台', '裏': '裡', '它': '他', '她': '他', '牠': '他', '妳': '你' };
export function normAsr(s) { return asrChars(s).map(x => x.c); }
// 每個保留的字附「詞編號」:英數字連在一起(中間沒有空白或標點)是同一個詞,其他字各自一個
function asrChars(s) {
  const out = []; let wid = 0, prevW = false;
  for (const ch of String(s).normalize('NFKC').toLowerCase()) {
    if (!/[\p{L}\p{N}]/u.test(ch)) { prevW = false; continue; }
    const c = ASR_SAME[ch] ?? ch, w = /[a-z0-9]/.test(c);
    if (!(w && prevW)) wid++;
    out.push({ c, wid }); prevW = w;
  }
  return out;
}
// 逐字最長共同子序列 → 不一致的片段 [{expected, heard}];similarity = 共同字數 / 原文字數
export function asrDiff(expected, heard) {
  const A = asrChars(expected), B = asrChars(heard), a = A.map(x => x.c), b = B.map(x => x.c);
  const n = a.length, m = b.length;
  const L = Array.from({ length: n + 1 }, () => new Int32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) L[i][j] = a[i] === b[j] ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1]);
  // 先找出不一致的區段(以位置記錄),碰到英數字時擴大到整個英數字詞(Rust → rest 列成一筆,不逐字母)
  const spans = []; let i = 0, j = 0, s0 = null;
  const close = () => { if (s0) { spans.push([s0[0], i, s0[1], j]); s0 = null; } };
  while (i < n || j < m) {
    if (i < n && j < m && a[i] === b[j]) { close(); i++; j++; }
    else { if (!s0) s0 = [i, j]; if (j < m && (i === n || L[i][j + 1] >= L[i + 1][j])) j++; else i++; }
  }
  close();
  // 區段碰到英數字詞時擴大到整個詞(依原文的空白 / 標點分詞)
  const grow = (W, x, y) => {
    const isW = k => k >= 0 && k < W.length && /[a-z0-9]/.test(W[k].c);
    if (x < y) { if (isW(x)) while (x > 0 && isW(x - 1) && W[x - 1].wid === W[x].wid) x--; if (isW(y - 1)) while (y < W.length && isW(y) && W[y].wid === W[y - 1].wid) y++; }
    else {   // 空區段(漏字):碰到哪邊的英數字詞就擴到那個詞
      const L0 = x, wl = isW(L0 - 1) ? W[L0 - 1].wid : null, wr = isW(y) ? W[y].wid : null;
      if (wl !== null) while (x > 0 && isW(x - 1) && W[x - 1].wid === wl) x--;
      if (wr !== null) while (y < W.length && isW(y) && W[y].wid === wr) y++;
    }
    return [x, y];
  };
  const merged = [];
  for (const [x0, x1, y0, y1] of spans) {
    const [p0, p1] = grow(A, x0, x1), [q0, q1] = grow(B, y0, y1);
    const last = merged[merged.length - 1];
    if (last && (p0 < last[1] || q0 < last[3])) { last[1] = Math.max(last[1], p1); last[3] = Math.max(last[3], q1); }
    else merged.push([p0, p1, q0, q1]);
  }
  const diffs = merged.map(([x0, x1, y0, y1]) => ({ expected: a.slice(x0, x1).join(''), heard: b.slice(y0, y1).join('') }));
  return { similarity: n ? r3(L[0][0] / n) : (m ? 0 : 1), diffs };
}
