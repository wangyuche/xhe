#!/usr/bin/env node
// game-art-kit:ComfyUI HTTP API 客戶端(只用 Node 內建模組)。
// 用法:
//   node comfy.mjs check                                   → 模型、模型家族、可用的一致性方法、建議的 workflow 預設值(JSON)
//   node comfy.mjs upload <圖檔> --prefix <專案-角色>       → 上傳到 ComfyUI 的 temp 區,印出 LoadImage 用的名稱
//   node comfy.mjs run <workflow 骨架.json> --out <目錄> --name <檔名> [--set key=value]... [--timeout 300]
//                                                           → 填參數、送出、輪詢、下載 PNG、刪除 history,印出結果 JSON
//   node comfy.mjs pngsize <圖檔>                           → {"width":…,"height":…}
//   node comfy.mjs scrub-check <目錄>                       → 產出不含 ComfyUI 位址 / 私有 IP;找到就結束碼 1
// 共同參數:--url <位址> 臨時覆寫。位址優先序:--url > 環境變數 COMFYUI_URL > ~/.config/game-art-kit/config 的 COMFYUI_URL=。
// 位址只印到 stderr / 終端機,不寫進任何產出檔案。
// 結束碼:0 成功;1 一般錯誤 / scrub 找到位址;2 用法或參數錯誤;3 ComfyUI 回報錯誤;4 逾時;5 連不上。
import { readFileSync, writeFileSync, mkdirSync, existsSync, statSync, readdirSync } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { homedir } from 'node:os';
import { basename, extname, join, resolve, dirname } from 'node:path';

// die 丟例外(不直接 exit),讓 run 的 finally 能清理伺服器上的工作;最外層統一印訊息與結束碼
class Fail extends Error { constructor(msg, code) { super(msg); this.code = code; } }
const die = (msg, code = 1) => { throw new Fail(msg, code); };
const report = (e) => { console.error(`錯誤:${e instanceof Fail ? e.message : e?.stack || e}`); process.exit(e instanceof Fail ? e.code : 1); };
process.on('uncaughtException', report);
process.on('unhandledRejection', report);
const argv = process.argv.slice(2);
const cmd = argv.shift();
const flags = { set: [] };
const pos = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--set') flags.set.push(argv[++i] ?? die('--set 缺值', 2));
  else if (a.startsWith('--')) flags[a.slice(2)] = argv[++i] ?? die(`${a} 缺值`, 2);
  else pos.push(a);
}

// 找不到位址時:required → 結束碼 2 附設定方式;否則回 null
function resolveUrl(required = true) {
  let u = flags.url || process.env.COMFYUI_URL;
  if (!u) {
    const f = join(homedir(), '.config', 'game-art-kit', 'config');
    if (existsSync(f)) {
      const m = readFileSync(f, 'utf8').match(/^\s*COMFYUI_URL\s*=\s*(\S+)\s*$/m);
      if (m) u = m[1];
    }
  }
  if (!u && !required) return null;
  if (!u) die('找不到 ComfyUI 位址。設定方式:mkdir -p ~/.config/game-art-kit && echo \'COMFYUI_URL=http://<主機>:8188\' > ~/.config/game-art-kit/config(或設環境變數 COMFYUI_URL)', 2);
  // 必須是 http(s)://主機[:埠];少了 scheme 時,fetch 會連不上、scrub-check 的位址比對會失效
  let parsed;
  try { parsed = new URL(u); } catch { parsed = null; }
  if (!parsed || !/^https?:$/.test(parsed.protocol) || !parsed.hostname) die(`ComfyUI 位址格式錯誤:要寫成 http://<主機>:<埠>(例如 http://comfy.local:8188),目前是「${u}」`, 2);
  return u.replace(/\/+$/, '');
}

async function api(path, opts = {}) {
  const base = resolveUrl();
  let r;
  try {
    r = await fetch(base + path, { ...opts, signal: AbortSignal.timeout(opts.timeoutMs ?? 30000) });
  } catch (e) {
    die(`連不上 ComfyUI(${e.cause?.code || e.name}):確認主機開著、ComfyUI 用 --listen 啟動;macOS 要允許終端機 app 的「本機網路」權限`, 5);
  }
  return r;
}
const json = async (path, opts) => {
  const r = await api(path, opts);
  const t = await r.text();
  if (!r.ok) return { __status: r.status, __body: t };
  try { return JSON.parse(t); } catch { return { __status: r.status, __body: t }; }
};

// ---------- pngsize ----------
function pngSize(file) {
  const b = readFileSync(file);
  if (b.length < 24 || b.toString('ascii', 1, 4) !== 'PNG') die(`${file} 不是 PNG`, 2);
  return { width: b.readUInt32BE(16), height: b.readUInt32BE(20) };
}

// ---------- check ----------
const MODEL_DIRS = ['checkpoints', 'diffusion_models', 'text_encoders', 'vae', 'loras', 'controlnet', 'clip_vision', 'style_models', 'ipadapter'];
function family(name) {
  const n = name.toLowerCase();
  if (/qwen.?image.?edit/.test(n)) return 'qwen-image-edit';
  if (/qwen.?image.?layered/.test(n)) return 'qwen-image-layered';
  if (/qwen.?image/.test(n)) return 'qwen-image';
  if (/kontext/.test(n)) return 'flux-kontext';
  if (/flux.*fill/.test(n)) return 'flux-fill';
  if (/flux.*redux/.test(n)) return 'flux-redux';
  if (/flux/.test(n)) return 'flux';
  if (/z.?image/.test(n)) return 'z-image';
  if (/t5xxl|umt5/.test(n)) return 't5';
  if (/sdxl|(^|[_-])xl([_.-])|pony|illustrious/.test(n)) return 'sdxl';
  if (/sd.?1\.?5|v1-5/.test(n)) return 'sd15';
  return '未知';
}
const pick = (list, re) => list.find(x => re.test(x.toLowerCase())) ?? null;

async function check() {
  const stats = await json('/system_stats');
  if (stats.__status) die(`/system_stats 回 HTTP ${stats.__status}`, 5);
  const models = {};
  for (const d of MODEL_DIRS) {
    const m = await json(`/models/${d}`);
    models[d] = Array.isArray(m) ? m : [];
  }
  const oi = await json('/object_info', { timeoutMs: 60000 });
  if (oi.__status) die(`/object_info 回 HTTP ${oi.__status}`, 3);
  const has = (n) => Object.prototype.hasOwnProperty.call(oi, n);
  const dm = models.diffusion_models, te = models.text_encoders, vae = models.vae, lora = models.loras;
  const d = {
    qwen_unet: pick(dm, /qwen.?image(?!.?edit|.?layered)/), qwen_edit_unet: pick(dm, /qwen.?image.?edit/),
    qwen_clip: pick(te, /qwen.?2\.?5.?vl/), qwen_vae: pick(vae, /^qwen_image_vae/),
    qwen_lightning: pick(lora, /qwen.?image.?lightning/), qwen_edit_lightning: pick(lora, /qwen.?image.?edit.*lightning/),
    flux_unet: pick(dm, /^flux1-dev(?!.*(kontext|fill))/), flux_kontext_unet: pick(dm, /kontext/),
    clip_l: pick(te, /^clip_l/), t5: pick(te, /t5xxl/), flux_vae: pick(vae, /^ae\./),
    zimage_unet: pick(dm, /z.?image/), zimage_clip: pick(te, /qwen_?3_?4b/),
    qwen_controlnet_union: pick(models.controlnet, /qwen.*union/),
  };
  const methods = [];
  if (has('TextEncodeQwenImageEditPlus') && d.qwen_edit_unet && d.qwen_clip && d.qwen_vae)
    methods.push({ method: 'qwen-image-edit', maxRefs: 3, workflows: ['qwen-edit-1ref', 'qwen-edit-2ref', 'qwen-edit-3ref'] });
  if (has('ReferenceLatent') && d.flux_kontext_unet && d.clip_l && d.t5 && d.flux_vae)
    methods.push({ method: 'flux-kontext', maxRefs: 1, workflows: ['flux-kontext'] });
  const ipaNodes = Object.keys(oi).filter(n => /ipadapter/i.test(n));
  if (ipaNodes.length && models.ipadapter.length && models.clip_vision.length)
    methods.push({ method: 'ipadapter', maxRefs: 1, workflows: [], note: '本 kit 沒有 IP-Adapter 骨架,需自行組 workflow' });
  const workflows = {
    'qwen-t2i': !!(d.qwen_unet && d.qwen_clip && d.qwen_vae),
    'qwen-edit-1ref': !!methods.find(m => m.method === 'qwen-image-edit') && has('CFGNorm') && has('ImageScaleToTotalPixels') && has('EmptySD3LatentImage'),
    'qwen-edit-2ref': null, 'qwen-edit-3ref': null, // 同 qwen-edit-1ref,下面補
    'flux-t2i': !!(d.flux_unet && d.clip_l && d.t5 && d.flux_vae),
    'flux-kontext': !!methods.find(m => m.method === 'flux-kontext'),
    'zimage-t2i': !!(d.zimage_unet && d.zimage_clip && d.flux_vae && has('ModelSamplingAuraFlow')),
    'qwen-t2i-canny': !!(d.qwen_unet && d.qwen_clip && d.qwen_vae && d.qwen_controlnet_union && has('Canny') && has('SetUnionControlNetType')),
  };
  workflows['qwen-edit-2ref'] = workflows['qwen-edit-3ref'] = workflows['qwen-edit-1ref'];
  const out = {
    ok: true,
    comfyui_version: stats.system?.comfyui_version ?? null,
    os: stats.system?.os ?? null,
    devices: (stats.devices ?? []).map(x => ({ name: x.name, vram_gb: Math.round((x.vram_total ?? 0) / 2 ** 30) })),
    models: Object.fromEntries(Object.entries(models).map(([k, v]) => [k, v.map(n => ({ name: n, family: family(n) }))])),
    consistency_methods: methods,
    workflows_available: workflows,
    defaults: d,
  };
  console.log(JSON.stringify(out, null, 1));
}

// ---------- upload ----------
async function upload() {
  const file = pos[0] ?? die('用法:upload <圖檔> --prefix <名稱>', 2);
  if (!existsSync(file)) die(`找不到 ${file}`, 2);
  const prefix = (flags.prefix ?? 'gak').replace(/[^A-Za-z0-9_-]/g, '-');
  const buf = readFileSync(file);
  const name = `${prefix}-${createHash('sha256').update(buf).digest('hex').slice(0, 8)}${extname(file).toLowerCase() || '.png'}`;
  const fd = new FormData();
  fd.append('image', new Blob([buf]), name);
  fd.append('type', 'temp');          // 放 temp:ComfyUI 重開就清掉,不會留在 input/
  fd.append('overwrite', 'true');      // 同名 = 同內容(檔名含雜湊)
  const r = await json('/upload/image', { method: 'POST', body: fd });
  if (r.__status) die(`上傳失敗 HTTP ${r.__status}:${String(r.__body).slice(0, 200)}`, 3);
  const rel = r.subfolder ? `${r.subfolder}/${r.name}` : r.name;
  console.log(JSON.stringify({ file: basename(file), loadImage: `${rel} [temp]`, sha8: name.slice(prefix.length + 1, prefix.length + 9) }));
}

// ---------- run ----------
function fill(skel, sets) {
  const vals = {};
  for (const s of sets) {
    const i = s.indexOf('=');
    if (i < 1) die(`--set 要 key=value:${s}`, 2);
    vals[s.slice(0, i)] = s.slice(i + 1);
  }
  const { _meta, ...graph } = skel;
  // 只有 _meta.numeric 列的參數轉數字;其他(提示詞、檔名)一律保留字串
  const numeric = new Set(_meta?.numeric ?? []);
  for (const k of numeric) if (k in vals) {
    const x = Number(vals[k]);
    if (!/^-?\d+(\.\d+)?$/.test(vals[k]) || !Number.isFinite(x)) die(`${k} 必須是數字:${vals[k]}`, 2);
    if (Number.isInteger(x) && !Number.isSafeInteger(x)) die(`${k} 超過 ${Number.MAX_SAFE_INTEGER},精度會跑掉;seed 請用較小的整數`, 2);
  }
  const missing = new Set(), used = new Set();
  const walk = (v) => {
    if (typeof v === 'string') {
      const whole = v.match(/^\{\{(\w+)\}\}$/);
      if (whole) {
        const k = whole[1];
        if (!(k in vals)) { missing.add(k); return v; }
        used.add(k);
        return numeric.has(k) ? Number(vals[k]) : vals[k];
      }
      return v.replace(/\{\{(\w+)\}\}/g, (m, k) => { if (!(k in vals)) { missing.add(k); return m; } used.add(k); return vals[k]; });
    }
    if (Array.isArray(v)) return v.map(walk);
    if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, walk(x)]));
    return v;
  };
  const filled = walk(graph);
  // lora=none:拿掉 LoraLoaderModelOnly,引用它的節點改接它的 model 輸入
  for (const [id, n] of Object.entries(filled)) {
    if (n?.class_type === 'LoraLoaderModelOnly' && String(n.inputs?.lora_name).toLowerCase() === 'none') {
      const src = n.inputs.model;
      delete filled[id];
      for (const m of Object.values(filled)) for (const [k, v] of Object.entries(m.inputs ?? {}))
        if (Array.isArray(v) && v[0] === id) m.inputs[k] = src;
    }
  }
  if (missing.size) die(`workflow 還有沒填的參數:${[...missing].join(', ')}(用 --set key=value)`, 2);
  const unused = Object.keys(vals).filter(k => !used.has(k));
  if (unused.length) die(`--set 的參數不在這個 workflow 裡:${unused.join(', ')}`, 2);
  return { meta: _meta ?? {}, graph: filled, vals };
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function run() {
  const skelPath = pos[0] ?? die('用法:run <workflow.json> --out <目錄> --name <檔名> [--set k=v]...', 2);
  const out = flags.out ?? die('缺 --out', 2);
  const name = flags.name ?? die('缺 --name', 2);
  if (!/^[A-Za-z0-9_.-]+$/.test(name)) die('--name 只能用英數、_ . -', 2);
  const timeout = Number(flags.timeout ?? 300);
  if (!Number.isFinite(timeout) || timeout <= 0) die(`--timeout 要是正數(秒):${flags.timeout}`, 2);
  let skel;
  try { skel = JSON.parse(readFileSync(skelPath, 'utf8')); } catch (e) { die(`讀不到 workflow:${e.message}`, 2); }
  const { meta, graph, vals } = fill(skel, flags.set);
  if (Object.values(graph).some(n => n?.class_type === 'SaveImage')) die('workflow 不可用 SaveImage(會寫進伺服器 output/);用 PreviewImage', 2);

  const t0 = Date.now();
  const client_id = randomUUID();
  const sub = await json('/prompt', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ prompt: graph, client_id }) });
  if (sub.__status || sub.error) {
    const body = sub.__body ? (() => { try { return JSON.parse(sub.__body); } catch { return sub.__body; } })() : sub;
    console.error(JSON.stringify(body, null, 1).slice(0, 3000));
    die('ComfyUI 拒絕這個 workflow(見上方 node_errors)', 3);
  }
  const id = sub.prompt_id;
  const post = (path, obj) => api(path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(obj), timeoutMs: 10000 });
  let finished = false;
  // 收尾:沒完成就只取消自己的工作(佇列中 → 移出;執行中 → 指定 prompt_id 中斷),等 history 出現再刪,不留紀錄
  const cleanup = async () => {
    try {
      if (!finished) {
        const q = await json('/queue', { timeoutMs: 10000 });
        if ((q.queue_pending ?? []).some(x => x[1] === id)) await post('/queue', { delete: [id] });
        else if ((q.queue_running ?? []).some(x => x[1] === id)) {
          await post('/interrupt', { prompt_id: id });
          for (let i = 0; i < 20; i++) { const h = await json(`/history/${id}`, { timeoutMs: 5000 }); if (h && h[id]) break; await sleep(500); }
        }
      }
      await post('/history', { delete: [id] });
    } catch { console.error(`警告:清理 ComfyUI 上的工作 ${id} 失敗(連線問題),history 可能殘留`); }
  };
  try {
    let hist = null;
    while (true) {
      const h = await json(`/history/${id}`);
      if (h && h[id]) { hist = h[id]; if (hist.status?.completed || hist.status?.status_str === 'error') break; }
      if ((Date.now() - t0) / 1000 > timeout) {
        await cleanup();
        console.log(JSON.stringify({ name, status: 'timeout', seconds: timeout, prompt_id: id }));
        process.exit(4);
      }
      await sleep(1000);
    }
    finished = true;
    if (hist.status?.status_str === 'error') {
      const msgs = (hist.status.messages ?? []).filter(m => m[0] === 'execution_error').map(m => m[1]);
      console.error(JSON.stringify(msgs, null, 1).slice(0, 3000));
      die('ComfyUI 執行失敗(見上方)', 3);
    }
    const imgs = [];
    for (const o of Object.values(hist.outputs ?? {})) for (const im of o.images ?? []) imgs.push(im);
    if (!imgs.length) die('workflow 沒有輸出圖片(要有 PreviewImage)', 3);
    mkdirSync(out, { recursive: true });
    const files = [];
    for (let i = 0; i < imgs.length; i++) {
      const im = imgs[i];
      const q = new URLSearchParams({ filename: im.filename, subfolder: im.subfolder ?? '', type: im.type ?? 'temp' });
      const r = await api(`/view?${q}`, { timeoutMs: 120000 });
      if (!r.ok) die(`下載圖片失敗 HTTP ${r.status}`, 3);
      const f = join(out, imgs.length === 1 ? `${name}.png` : `${name}-${i + 1}.png`);
      writeFileSync(f, Buffer.from(await r.arrayBuffer()));
      files.push({ file: f, ...pngSize(f) });
    }
    // 成功才存實際送出的 workflow(不含位址),避免留下沒有對應圖片的檔案
    mkdirSync(join(out, 'workflows'), { recursive: true });
    writeFileSync(join(out, 'workflows', `${name}.json`), JSON.stringify({ _meta: { ...meta, skeleton: basename(skelPath), params: vals }, ...graph }, null, 1));
    console.log(JSON.stringify({ name, status: 'ok', seconds: Math.round((Date.now() - t0) / 100) / 10, files, params: vals }));
  } finally {
    await cleanup();
  }
}

// ---------- scrub-check ----------
function scrub() {
  const dir = pos[0] ?? die('用法:scrub-check <目錄>', 2);
  if (!existsSync(dir)) die(`找不到 ${dir}`, 2);
  // 位址:和 run 一樣的優先序(--url > 環境變數 > 設定檔);沒有設定時只查通用樣式
  let hostRe = null;
  const u = resolveUrl(false);
  if (u) {
    const { host, hostname, port } = new URL(u);
    const esc = (x) => x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    // 有埠號或是 IP → 比對 host;只有主機名稱(例如 comfy)→ 只比對 //主機名稱,避免誤中一般文字
    hostRe = port || /^[\d.]+$|:/.test(hostname) ? new RegExp(esc(host)) : new RegExp(`//${esc(hostname)}(?![\\w.-])`);
  }
  const pats = [/\b(?:10|127)\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/, /\b192\.168\.\d{1,3}\.\d{1,3}\b/, /\b172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b/, /:8188\b/];
  const hits = [];
  const walk = (p) => {
    for (const e of readdirSync(p, { withFileTypes: true })) {
      const f = join(p, e.name);
      if (e.isDirectory()) { walk(f); continue; }
      if (!/\.(md|json|txt|ya?ml|html|csv)$/i.test(e.name)) continue;
      const lines = readFileSync(f, 'utf8').split('\n');
      lines.forEach((l, i) => {
        if ((hostRe && hostRe.test(l)) || pats.some(re => re.test(l))) hits.push(`${f}:${i + 1}`);
      });
    }
  };
  walk(dir);
  for (const h of hits) console.log(`FOUND ${h}`);
  console.log(`hits=${hits.length}`);
  process.exit(hits.length ? 1 : 0);
}

const cmds = { check, upload, run, scrub: scrub, 'scrub-check': scrub, pngsize: () => console.log(JSON.stringify(pngSize(pos[0] ?? die('用法:pngsize <圖檔>', 2)))) };
if (!cmds[cmd]) die('用法:comfy.mjs check | upload | run | pngsize | scrub-check(見檔頭說明)', 2);
await cmds[cmd]();
