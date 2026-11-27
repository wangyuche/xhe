#!/usr/bin/env node
// game-art-kit:角色動作圖(立繪級的表情 / 姿勢集,不是動畫格)。純 Node;ComfyUI 一律透過 comfy.mjs(upload / run)。
// 設定檔 actions.json(放 art/characters/<id>/actions/,格式見 SKILL.md「角色動作」);路徑一律相對 art/(--art 預設 = 設定檔往上三層)。
// 用法:
//   node actions.mjs prompt --config <actions.json> --action <id>                 → 印這個動作各段的提示詞(edit / body / face / light)
//   node actions.mjs masks  --config <actions.json> --out <masks.png> [--image <png>]
//        遮罩預覽:底圖(或 --image,例如 edit 選定的 idle1)變暗;綠 = head 保留區、藍 = drop(從 head 扣掉)、紅框 = face(內切橢圓 = 實際重畫範圍)、黃十字 + 橘框 = anchor 與頭像範圍
//   node actions.mjs gen    --config <actions.json> --action <id> --seed <n> --out-dir <dir> [--method edit|inpaint] [--prefix <上傳檔名前綴>]
//        出一張候選 → <dir>/<動作>-<seed>.png(淺灰底,還沒去背)。edit:qwen-edit-1ref(1 次生成);
//        inpaint:第 1 段 head 保留、其他重畫成 pose(zimage-inpaint,body denoise)→ 第 2 段只重畫 face 換表情(2 次);light 動作整張輕改(1 次)
//   node actions.mjs extend --config <actions.json> --action <id> --input <clean 後的透明圖> --grey <同一張的灰底原圖> --seed <n> --out-dir <dir> [--pad 96] [--band 48]
//        clean 後碰到的邊(touches)往外補 pad px:補的地方 + 往內 band px 漸層重畫(zimage-inpaint-soft,1 次);沒碰到的邊不動。
//        → <dir>/<動作>-<seed>-x.png(灰底,之後再 cut),印 pad {left,top,right,bottom}(寫進 actions.json 的 extend_pad.<動作>)
//   node actions.mjs cut    --config <actions.json> --input <灰底 png> --out <透明 png> --work-dir <過程目錄> [--key-white] [--prefix …]
//        rmbg 骨架去背(不算生成次數;workflow 與下載檔放 --work-dir)→ sprite.mjs clean → 印 clean 的自我檢查;--key-white:不跑 rmbg,直接白底去背(白底立繪)
//   node actions.mjs sheet  --out <sheet.png> <底圖> <候選>... [--tile 360] [--cols N]   候選對照表(左上 = 底圖,其餘照參數順序)
// 每個會呼叫 ComfyUI 的指令都印 {"generations":n,…}(n = 這次算進生成上限的次數)。
// 結束碼:0 成功;1 檢查不通過(cut 的 clean 報告);2 用法 / 設定錯誤;3 以上沿用 comfy.mjs(3 執行失敗、4 逾時、5 連不上)。
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync, existsSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve, basename } from 'node:path';
import { tmpdir } from 'node:os';
import { decodePng, encodePng, blank, resample, blit, cleanAlpha, cleanReport, keyWhite } from './sprite.mjs';

class Fail extends Error { constructor(m, c = 2) { super(m); this.code = c; } }
const die = (m, c = 2) => { throw new Fail(m, c); };
const KIT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const COMFY = join(KIT, 'scripts', 'comfy.mjs');
const TEMPLATE = JSON.parse(readFileSync(join(KIT, 'templates', 'character-actions.json'), 'utf8'));
const load = (f) => { let b; try { b = readFileSync(f); } catch (e) { die(`讀不到 ${f}:${e.message}`); } return decodePng(b); };
const save = (f, img) => { mkdirSync(dirname(f), { recursive: true }); writeFileSync(f, encodePng(img)); };

// ---------- 設定 ----------
export function loadConfig(file, artDir) {
  let c; try { c = JSON.parse(readFileSync(file, 'utf8')); } catch (e) { die(`設定檔 ${file} 讀不到或不是 JSON:${e.message}`); }
  const art = artDir ? resolve(artDir) : resolve(dirname(file), '..', '..', '..');
  for (const k of ['name', 'pronoun', 'base', 'look', 'style', 'anchor']) if (c[k] == null) die(`actions.json 缺 ${k}`);
  if (!TEMPLATE.pronouns[c.pronoun]) die(`pronoun 只能是 ${Object.keys(TEMPLATE.pronouns).join(' / ')}`);
  if (/^\/|^[A-Za-z]:|\.\./.test(c.base)) die('base 要寫相對 art/ 的路徑(不寫本機絕對路徑、不用 ..)');
  const { x, y, h } = c.anchor; if (![x, y, h].every(v => typeof v === 'number' && v > 0 && v <= 1)) die('anchor 的 x、y、h 都要是 0–1 的數字');
  return { c, art, basePath: join(art, c.base) };
}
const actionOf = (c, id) => {
  const t = TEMPLATE.actions.find(a => a.id === id), o = c.actions?.[id] ?? {};
  if (!t && !(o.expr && o.pose)) die(`動作 ${id} 不在範本裡,actions.json 的 actions.${id} 要自己給 expr 與 pose`);
  return { id, light: o.light ?? t?.light ?? false, expr: o.expr ?? t.expr, pose: o.pose ?? t.pose, inpaintPose: o.inpaint_pose ?? o.pose ?? t?.inpaint_pose ?? t?.pose, allowed: o.allowed, prompt: o.prompt ?? {} };
};
const fill = (s, vars) => s.replace(/\{(\w+)\}/g, (m, k) => vars[k] ?? m);
export function prompts(c, id) {
  const a = actionOf(c, id), pr = TEMPLATE.pronouns[c.pronoun];
  const v0 = { ...pr };
  const vars = { name: c.name, look: c.look, style: c.style, features: c.features ?? c.look, face: c.features ?? c.look, outfit: c.outfit ?? c.look, hands: c.hands ?? TEMPLATE.hands, allowed: a.allowed ? ` except ${a.allowed}` : '' };
  const expr = fill(a.expr, v0), pose = fill(a.pose, v0), ipose = fill(a.inpaintPose, v0);
  return {
    edit: a.prompt.edit ?? fill(TEMPLATE.edit, { ...vars, expr, pose }),
    body: a.prompt.body ?? fill(TEMPLATE.body, { ...vars, pose: ipose }),
    face: a.prompt.face ?? fill(TEMPLATE.face, { ...vars, expr }),
    light: a.prompt.light ?? fill(TEMPLATE.light, { ...vars, expr, pose }),
    isLight: a.light,
  };
}

// ---------- 遮罩(Float32,0 = 保留、1 = 重畫)----------
function shapeMask(w, h, shapes = []) {
  const m = new Uint8Array(w * h);
  for (const s of shapes) {
    const [kind, box] = s.rect ? ['rect', s.rect] : s.ellipse ? ['ellipse', s.ellipse] : die(`形狀只能 {rect:[x0,y0,x1,y1]} 或 {ellipse:[x0,y0,x1,y1]}:${JSON.stringify(s)}`);
    if (!Array.isArray(box) || box.length !== 4 || box.some(v => !Number.isFinite(v))) die(`形狀座標要 4 個數字:${JSON.stringify(s)}`);
    const [x0, y0, x1, y1] = box, cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, rx = (x1 - x0) / 2, ry = (y1 - y0) / 2;
    for (let y = Math.max(0, Math.floor(y0)); y < Math.min(h, Math.ceil(y1)); y++) for (let x = Math.max(0, Math.floor(x0)); x < Math.min(w, Math.ceil(x1)); x++) {
      if (kind === 'ellipse' && ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy) / ry) ** 2 > 1) continue;
      m[y * w + x] = 1;
    }
  }
  return m;
}
export function headKeep(c, w, h) {
  if (!Array.isArray(c.head) || !c.head.length) die('inpaint 要有 head(頭、帽子、耳朵的矩形 / 橢圓;含一條從圖頂蓋到頭頂的橫條)');
  const keep = shapeMask(w, h, c.head), drop = shapeMask(w, h, c.drop ?? []);
  for (let i = 0; i < keep.length; i++) if (drop[i]) keep[i] = 0;
  return keep;
}
// 五官:face 框內切的橢圓,邊緣羽化(盒狀模糊 3 次 ≈ 高斯),接縫才不硬
const FEATHER = 12;
function blur(m, w, h, r) {
  let a = Float32Array.from(m), b = new Float32Array(a.length);
  for (let it = 0; it < 3; it++) {
    for (let y = 0; y < h; y++) { let acc = 0; for (let x = -r; x < w; x++) { if (x + r < w) acc += a[y * w + x + r]; if (x - r - 1 >= 0) acc -= a[y * w + x - r - 1]; if (x >= 0) b[y * w + x] = acc / (2 * r + 1); } }
    for (let x = 0; x < w; x++) { let acc = 0; for (let y = -r; y < h; y++) { if (y + r < h) acc += b[(y + r) * w + x]; if (y - r - 1 >= 0) acc -= b[(y - r - 1) * w + x]; if (y >= 0) a[y * w + x] = acc / (2 * r + 1); } }
  }
  return a;
}
const faceMask = (c, w, h) => { if (!Array.isArray(c.face) || c.face.length !== 4) die('inpaint 要有 face:[x0,y0,x1,y1](五官框)'); return blur(shapeMask(w, h, [{ ellipse: c.face }]), w, h, Math.round(FEATHER / 2)); };

// 初始圖:repaint 的地方 alpha = 0(ComfyUI LoadImage 的 mask = 1 − alpha),其他不透明;RGB 都保留
function initImage(img, repaint /* Float32Array 0..1 */) {
  const out = { width: img.width, height: img.height, hasAlpha: true, data: Buffer.from(img.data) };
  for (let i = 0; i < repaint.length; i++) out.data[i * 4 + 3] = Math.round((1 - repaint[i]) * 255);
  return out;
}
// 生成結果(可能是別的尺寸)縮回原圖大小,依 repaint 混合:repaint 1 用新圖、0 用原圖
function compose(orig, gen, repaint) {
  const g = gen.width === orig.width && gen.height === orig.height ? gen : resample(gen, 0, 0, gen.width, gen.height, orig.width, orig.height);
  const out = { width: orig.width, height: orig.height, hasAlpha: false, data: Buffer.alloc(orig.data.length) };
  for (let i = 0; i < repaint.length; i++) { const m = repaint[i]; for (let k = 0; k < 3; k++) out.data[i * 4 + k] = Math.round(g.data[i * 4 + k] * m + orig.data[i * 4 + k] * (1 - m)); out.data[i * 4 + 3] = 255; }
  return out;
}
const opaque = (img) => { const o = { ...img, hasAlpha: false, data: Buffer.from(img.data) }; for (let i = 3; i < o.data.length; i += 4) o.data[i] = 255; return o; };

// ---------- ComfyUI(comfy.mjs)----------
function comfy(args, what) {
  const p = spawnSync('node', [COMFY, ...args], { encoding: 'utf8', maxBuffer: 64 * 2 ** 20 });
  if (p.error) die(`跑不了 comfy.mjs:${p.error.message}`);
  const last = (p.stdout || '').trim().split('\n').pop();
  if (p.status !== 0) die(`${what} 失敗(comfy.mjs 結束碼 ${p.status}):${((p.stderr || '') + (p.stdout || '')).trim().split('\n').slice(-4).join(' ')}`, p.status >= 3 ? p.status : 3);
  try { return JSON.parse(last); } catch { die(`${what}:comfy.mjs 輸出不是 JSON:${last}`, 3); }
}
function upload(img, prefix, tmp) {
  const f = join(tmp, `${prefix}-${Date.now().toString(36)}.png`); save(f, img);
  return comfy(['upload', f, '--prefix', prefix], '上傳').loadImage;
}
// 時限:一次 Bash 呼叫(600 秒)裡最多串兩次 run(inpaint 身體 + 五官),所以每次 run 用短時限:
// 執行 90 + 排隊 40 + 下載 20 + 抓 /object_info 30 + 偵測 50 + 收尾 40 = 270 秒,兩次 540 < 600(Z-Image 一張約 20 秒、Qwen-Edit 約 40 秒)
const RUN_LIMITS = ['--queue-timeout', '40', '--download-timeout', '20'];
function run(wf, sets, outDir, name, timeout = 90) {
  const args = ['run', join(KIT, 'workflows', `${wf}.json`), '--out', outDir, '--name', name, ...Object.entries(sets).flatMap(([k, v]) => ['--set', `${k}=${v}`]), '--timeout', String(timeout), ...RUN_LIMITS];
  const r = comfy(args, `${wf}`);
  const f = r.files?.find(x => /\.png$/.test(x.file)) ?? die(`${wf} 沒有輸出圖`, 3);
  return { file: f.file.startsWith('/') ? f.file : join(outDir, basename(f.file)), result: r };
}
const need = (o, keys, where) => { const miss = keys.filter(k => o?.[k] == null); if (miss.length) die(`actions.json 的 ${where} 缺 ${miss.join(', ')}(要的鍵:${keys.join(', ')};用 check 的 defaults 填)`); return o; };
const INP = ['unet', 'clip', 'vae', 'shift', 'steps', 'cfg', 'sampler', 'scheduler'];
const EDIT = ['unet', 'clip', 'vae', 'lora', 'lora_strength', 'shift', 'steps', 'cfg', 'sampler', 'scheduler'];
const editSize = (w, h) => { const ar = w / h, W = Math.round(Math.sqrt(1048576 * ar) / 16) * 16; return { width: W, height: Math.round(W / ar / 16) * 16 }; };
const pick = (o, keys) => Object.fromEntries(keys.map(k => [k, o[k]]));

export function gen(cfgFile, { action, seed, outDir, method, prefix, art, timeout }) {
  const { c, basePath } = loadConfig(cfgFile, art);
  const m = method ?? c.method ?? 'edit'; if (!['edit', 'inpaint'].includes(m)) die('method 只能 edit 或 inpaint');
  const p = prompts(c, action), base = opaque(load(basePath));
  const tmp = mkdtempSync(join(tmpdir(), 'gak-actions-')), work = join(outDir, 'work');
  mkdirSync(work, { recursive: true });
  const pre = prefix ?? `actions-${(c.id ?? 'char').replace(/[^a-z0-9-]/gi, '-').toLowerCase()}`;
  const steps = []; let gens = 0; const outFile = join(outDir, `${action}-${seed}.png`);
  try {
    if (m === 'edit') {
      const e = need(c.models?.edit, EDIT, 'models.edit');
      const ref = upload(base, pre, tmp);
      const r = run('qwen-edit-1ref', { ...pick(e, EDIT), prompt: p.edit, negative: c.negative || ' ', ...editSize(base.width, base.height), seed, ref1: ref }, work, `${action}-${seed}-edit`, timeout ?? 240);
      gens++; steps.push({ step: 'edit', workflow: 'qwen-edit-1ref', file: r.file });
      save(outFile, opaque(load(r.file)));
    } else {
      const z = need(c.models?.inpaint, INP, 'models.inpaint');
      const dn = { ...TEMPLATE.denoise, ...(c.denoise ?? {}) };
      const W = base.width, H = base.height;
      if (p.isLight) {
        const all = new Float32Array(W * H).fill(1);
        const r = run('zimage-inpaint', { ...pick(z, INP), image: upload(initImage(base, all), pre, tmp), prompt: p.light, seed, denoise: dn.light }, work, `${action}-${seed}-light`, timeout ?? 150);
        gens++; steps.push({ step: 'light', workflow: 'zimage-inpaint', denoise: dn.light, file: r.file });
        save(outFile, compose(base, load(r.file), all));
      } else {
        const keep = headKeep(c, W, H), body = new Float32Array(W * H); for (let i = 0; i < body.length; i++) body[i] = keep[i] ? 0 : 1;
        const r1 = run('zimage-inpaint', { ...pick(z, INP), image: upload(initImage(base, body), pre, tmp), prompt: p.body, seed, denoise: dn.body }, work, `${action}-${seed}-body`, timeout);
        gens++; const s1 = compose(base, load(r1.file), body); const s1f = join(work, `${action}-${seed}-stage1.png`); save(s1f, s1);
        steps.push({ step: 'body', workflow: 'zimage-inpaint', denoise: dn.body, file: s1f });
        const face = faceMask(c, W, H);
        const r2 = run('zimage-inpaint', { ...pick(z, INP), image: upload(initImage(s1, face), pre, tmp), prompt: p.face, seed, denoise: dn.face }, work, `${action}-${seed}-face`, timeout);
        gens++; steps.push({ step: 'face', workflow: 'zimage-inpaint', denoise: dn.face, file: r2.file });
        save(outFile, compose(s1, load(r2.file), face));
      }
    }
  } finally { rmSync(tmp, { recursive: true, force: true }); }
  return { file: outFile, action, seed, method: m, generations: gens, steps, prompts: m === 'edit' ? { edit: p.edit } : p.isLight ? { light: p.light } : { body: p.body, face: p.face } };
}

export function extend(cfgFile, { action, input, grey, seed, outDir, pad = 96, band = 48, prefix, art, timeout = 150 }) {
  const { c } = loadConfig(cfgFile, art);
  const z = need(c.models?.inpaint, INP, 'models.inpaint');
  const cut = load(input), g = opaque(load(grey));
  if (cut.width !== g.width || cut.height !== g.height) die('--input 與 --grey 尺寸要相同(同一張圖去背前後)');
  const { touches } = cleanReport(cut);
  const P = { left: 0, top: 0, right: 0, bottom: 0 }; for (const t of touches) P[t] = pad;
  if (!touches.length) return { file: null, pad: P, generations: 0, note: '主體沒有碰邊,不用補' };
  const W = g.width + P.left + P.right, H = g.height + P.top + P.bottom;
  // 底色 = 四角 8×8 的平均
  let s = [0, 0, 0], n = 0;
  for (const [cx, cy] of [[0, 0], [g.width - 8, 0], [0, g.height - 8], [g.width - 8, g.height - 8]]) for (let y = cy; y < cy + 8; y++) for (let x = cx; x < cx + 8; x++) { const o = (y * g.width + x) * 4; for (let k = 0; k < 3; k++) s[k] += g.data[o + k]; n++; }
  const canvas = blank(W, H); for (let i = 0; i < W * H; i++) { for (let k = 0; k < 3; k++) canvas.data[i * 4 + k] = Math.round(s[k] / n); canvas.data[i * 4 + 3] = 255; }
  blit(canvas, g, P.left, P.top);
  const rep = new Float32Array(W * H);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    let v = 0;
    const dl = x - P.left, dt = y - P.top, dr = P.left + g.width - 1 - x, db = P.top + g.height - 1 - y;
    for (const [side, d] of [['left', dl], ['top', dt], ['right', dr], ['bottom', db]]) if (P[side]) v = Math.max(v, d < 0 ? 1 : d < band ? 1 - d / band : 0);
    rep[y * W + x] = v;
  }
  const tmp = mkdtempSync(join(tmpdir(), 'gak-extend-')), work = join(outDir, 'work'); mkdirSync(work, { recursive: true });
  try {
    const pr = prompts(c, action);
    const dn = c.denoise?.extend ?? 0.9;
    const r = run('zimage-inpaint-soft', { ...pick(z, INP), image: upload(initImage(canvas, rep), prefix ?? 'actions-extend', tmp), prompt: `${pr.isLight ? pr.light : pr.body}, the body and clothes continue naturally to the new edges, nothing cut off`, seed, denoise: dn }, work, `${action}-${seed}-extend`, timeout);
    const out = join(outDir, `${basename(input).replace(/\.png$/, '')}-x.png`);
    save(out, compose(canvas, load(r.file), rep));
    return { file: out, pad: P, touches, generations: 1, workflow: 'zimage-inpaint-soft', denoise: dn };
  } finally { rmSync(tmp, { recursive: true, force: true }); }
}

export function cutOut(cfgFile, { input, out, workDir, keyWhite: kw, prefix, art, timeout }) {
  let img;
  if (kw) img = keyWhite(opaque(load(input)));
  else {
    const { c } = loadConfig(cfgFile, art);
    const bg = c.models?.bg_model ?? die('actions.json 的 models.bg_model 缺(check 的 background_removal[].models,例如 RMBG-2.0)');
    const tmp = mkdtempSync(join(tmpdir(), 'gak-cut-')), work = workDir ?? die('cut 要 --work-dir(過程檔放 art/out/<日期>-actions-<id>/work,不放成品目錄)'); mkdirSync(work, { recursive: true });
    try { img = load(run('rmbg', { image: upload(opaque(load(input)), prefix ?? 'actions-cut', tmp), bg_model: bg }, work, `${basename(out).replace(/\.png$/, '')}-rmbg`, timeout).file); }
    finally { rmSync(tmp, { recursive: true, force: true }); }
    // RMBG 輸出可能被縮放:縮回輸入尺寸
    const src = load(input); if (img.width !== src.width || img.height !== src.height) img = resample(img, 0, 0, img.width, img.height, src.width, src.height);
    img.hasAlpha = true;
  }
  const r = cleanAlpha(img); save(out, r);
  return { file: out, generations: 0, ...cleanReport(r) };
}

// ---------- 預覽 / 對照表 ----------
export function maskPreview(cfgFile, { image, out, art }) {
  const { c, basePath } = loadConfig(cfgFile, art);
  const img = opaque(load(image ?? basePath)), W = img.width, H = img.height, d = img.data;
  for (let i = 0; i < d.length; i += 4) for (let k = 0; k < 3; k++) d[i + k] = Math.round(d[i + k] * 0.55);
  const tint = (m, rgb, a = 0.45) => { for (let i = 0; i < m.length; i++) if (m[i]) for (let k = 0; k < 3; k++) d[i * 4 + k] = Math.round(d[i * 4 + k] * (1 - a) + rgb[k] * a); };
  const box = (x0, y0, x1, y1, rgb, t = 3) => { for (let y = Math.max(0, Math.floor(y0)); y < Math.min(H, Math.ceil(y1)); y++) for (let x = Math.max(0, Math.floor(x0)); x < Math.min(W, Math.ceil(x1)); x++) if (x - x0 < t || x1 - x <= t || y - y0 < t || y1 - y <= t) { const o = (y * W + x) * 4; d[o] = rgb[0]; d[o + 1] = rgb[1]; d[o + 2] = rgb[2]; } };
  if (c.head) tint(shapeMask(W, H, c.head), [40, 220, 90]);
  if (c.drop) tint(shapeMask(W, H, c.drop), [60, 120, 255], 0.6);
  if (c.face) { box(...c.face, [255, 50, 50]); tint(shapeMask(W, H, [{ ellipse: c.face }]), [255, 60, 60], 0.25); }
  const { x, y, h } = c.anchor, cx = x * W, cy = y * H, side = h * H * (c.avatar_zoom ?? 1.15);
  box(cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2, [255, 150, 30]);
  box(cx - 14, cy - 2, cx + 14, cy + 2, [255, 230, 0], 3); box(cx - 2, cy - 14, cx + 2, cy + 14, [255, 230, 0], 3);
  save(out, img);
  return { file: out, width: W, height: H, legend: '綠 = head 保留、藍 = drop、紅框 = face、橘框 = 頭像範圍、黃十字 = anchor' };
}

export function sheet(files, { out, tile = 360, cols }) {
  if (!files.length) die('sheet 至少要一張圖');
  const imgs = files.map(f => { const i = load(f); const w = Math.round(i.width * tile / i.height); return resample(i, 0, 0, i.width, i.height, w, tile); });
  const C = cols ?? Math.ceil(Math.sqrt(imgs.length)), R = Math.ceil(imgs.length / C), cw = Math.max(...imgs.map(i => i.width)), gap = 8;
  const s = blank(C * (cw + gap) + gap, R * (tile + gap) + gap); for (let i = 0; i < s.data.length; i += 4) { s.data[i] = s.data[i + 1] = s.data[i + 2] = 48; s.data[i + 3] = 255; }
  imgs.forEach((im, k) => { const ox = gap + (k % C) * (cw + gap) + Math.floor((cw - im.width) / 2), oy = gap + Math.floor(k / C) * (tile + gap);
    for (let y = 0; y < im.height; y++) for (let x = 0; x < im.width; x++) { const o = (y * im.width + x) * 4, a = im.data[o + 3] / 255, t = ((oy + y) * s.width + ox + x) * 4; for (let c = 0; c < 3; c++) s.data[t + c] = Math.round(im.data[o + c] * a + 140 * (1 - a)); } });
  save(out, s);
  return { file: out, columns: C, rows: R, order: files.map(f => basename(f)) };
}

// ---------- CLI ----------
const isMain = (() => { try { return !!process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } })();
if (isMain) {
  try {
    const [cmd, ...rest] = process.argv.slice(2);
    const f = {}, pos = [];
    for (let i = 0; i < rest.length; i++) { const a = rest[i]; if (a === '--key-white') f['key-white'] = true; else if (a.startsWith('--')) f[a.slice(2)] = rest[++i] ?? die(`${a} 缺值`); else pos.push(a); }
    const cfg = () => f.config ?? die('缺 --config <actions.json>');
    const int = (k, def) => { const v = f[k] ?? def; if (v == null) die(`缺 --${k}`); if (!/^\d+$/.test(String(v))) die(`--${k} 要是非負整數`); return Number(v); };
    const timeout = f.timeout != null ? int('timeout') : undefined;
    let r;
    if (cmd === 'prompt') r = prompts(loadConfig(cfg(), f.art).c, f.action ?? die('缺 --action'));
    else if (cmd === 'masks') r = maskPreview(cfg(), { image: f.image, out: f.out ?? die('缺 --out'), art: f.art });
    else if (cmd === 'gen') r = gen(cfg(), { action: f.action ?? die('缺 --action'), seed: int('seed'), outDir: f['out-dir'] ?? die('缺 --out-dir'), method: f.method, prefix: f.prefix, art: f.art, timeout });
    else if (cmd === 'extend') r = extend(cfg(), { action: f.action ?? die('缺 --action'), input: f.input ?? die('缺 --input'), grey: f.grey ?? die('缺 --grey'), seed: int('seed'), outDir: f['out-dir'] ?? die('缺 --out-dir'), pad: int('pad', 96), band: int('band', 48), prefix: f.prefix, art: f.art, timeout });
    else if (cmd === 'cut') { r = cutOut(f['key-white'] ? null : cfg(), { input: f.input ?? die('缺 --input'), out: f.out ?? die('缺 --out'), workDir: f['work-dir'], keyWhite: !!f['key-white'], prefix: f.prefix, art: f.art, timeout }); console.log(JSON.stringify(r)); process.exit(r.ok ? 0 : 1); }
    else if (cmd === 'sheet') r = sheet(pos, { out: f.out ?? die('缺 --out'), tile: int('tile', 360), cols: f.cols != null ? int('cols') : undefined });
    else die('用法:actions.mjs prompt | masks | gen | extend | cut | sheet(見檔頭)');
    console.log(JSON.stringify(r));
  } catch (e) {
    console.error(`錯誤:${e instanceof Fail ? e.message : e?.stack || e}`);
    process.exit(e instanceof Fail ? e.code : 2);
  }
}
