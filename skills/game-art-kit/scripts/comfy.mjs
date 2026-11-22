#!/usr/bin/env node
// game-art-kit:ComfyUI HTTP API 客戶端(只用 Node 內建模組)。
// 用法(run 的 --timeout 只算開始執行後的時間,預設 240 秒;排隊等待另有 --queue-timeout,預設 180 秒;合計配 Bash 600 秒逾時):
//   node comfy.mjs check                                   → 模型、模型家族、可用的一致性方法、本機去背、音訊模型、建議的 workflow 預設值(JSON)
//   node comfy.mjs upload <圖檔> --prefix <專案-角色>       → 上傳到 ComfyUI 的 temp 區,印出 LoadImage 用的名稱
//   node comfy.mjs run <workflow 骨架.json> --out <目錄> --name <檔名> [--set key=value]... [--timeout 240] [--queue-timeout 180]
//                                                           → 填參數、送出、輪詢、下載 PNG / 音訊、刪除 history,印出結果 JSON;拒絕 Save* 與雲端 API 節點
//   node comfy.mjs pngsize <圖檔>                           → {"width":…,"height":…}
//   node comfy.mjs scrub-check <目錄>                       → 產出不含 ComfyUI 位址 / 私有 IP;找到就結束碼 1
// 共同參數:--url <位址> 臨時覆寫。位址優先序:--url > 環境變數 COMFYUI_URL > ~/.config/game-art-kit/config 的 COMFYUI_URL=。
// 位址只印到 stderr / 終端機,不寫進任何產出檔案。
// 結束碼:0 成功;1 一般錯誤 / scrub 找到位址;2 用法或參數錯誤;3 ComfyUI 回報錯誤;4 逾時;5 連不上。
import { readFileSync, writeFileSync, mkdirSync, existsSync, statSync, readdirSync, mkdtempSync, rmSync, renameSync, copyFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import { homedir } from 'node:os';
import { basename, extname, join, resolve, dirname } from 'node:path';

// die 丟例外(不直接 exit),讓 run 的 finally 能清理伺服器上的工作;最外層統一印訊息與結束碼
class Fail extends Error { constructor(msg, code) { super(msg); this.code = code; } }
const die = (msg, code = 1) => { throw new Fail(msg, code); };
// 收到中止訊號後(STOPPING)其他錯誤一律忽略,由訊號處理收尾並以 130 / 143 結束
let STOPPING = false;
const report = (e) => { if (STOPPING) return; console.error(`錯誤:${e instanceof Fail ? e.message : e?.stack || e}`); process.exit(e instanceof Fail ? e.code : 1); };
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
      // 允許 export、引號、行尾 # 註解
      const m = readFileSync(f, 'utf8').match(/^\s*(?:export\s+)?COMFYUI_URL\s*=\s*(["']?)([^"'\s#]+)\1\s*(?:#.*)?$/m);
      if (m) u = m[2];
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
  let t;
  try { t = await r.text(); } catch (e) { die(`讀取 ComfyUI 回應途中斷線或逾時(${e.cause?.code || e.name})`, 5); }
  if (!r.ok) return { __status: r.status, __body: t };
  try { return JSON.parse(t); } catch { return { __status: r.status, __body: t }; }
};

// ---------- pngsize ----------
function pngSize(file) {
  const b = readFileSync(file);
  if (b.length < 24 || b.toString('ascii', 1, 4) !== 'PNG') die(`${file} 不是 PNG`, 2);
  return { width: b.readUInt32BE(16), height: b.readUInt32BE(20) };
}

// PNG 色彩類型 → 通道數:RGBA 4、灰階 + alpha 2;任何帶 tRNS 的(調色盤 / 灰階 / RGB)也回 4,表示「有透明」
function pngChannels(file) {
  const b = readFileSync(file), t = b[25];
  // 調色盤 / 灰階 / RGB 帶 tRNS 也算有 alpha(回 4)
  let p = 8, trns = false;
  while (p + 8 <= b.length) { const len = b.readUInt32BE(p), type = b.toString('ascii', p + 4, p + 8); if (type === 'tRNS') { trns = true; break; } if (type === 'IDAT' || type === 'IEND') break; p += 12 + len; }
  if (trns) return 4;
  return { 0: 1, 2: 3, 3: 3, 4: 2, 6: 4 }[t] ?? null;
}

// 節點旗標快取(只存 api_node / output_node 與可用的 RMBG 模型,不含位址;檔名用位址雜湊):~/.cache/game-art-kit/nodeflags-<雜湊>.json
// 放使用者自己的快取目錄(不放共用的 /tmp,避免別的使用者塞假旗標);可用 GAK_CACHE_DIR 覆寫(測試用)
const flagsFile = () => { const d = process.env.GAK_CACHE_DIR || join(homedir(), '.cache', 'game-art-kit'); mkdirSync(d, { recursive: true, mode: 0o700 }); return join(d, `nodeflags-${createHash('sha256').update(resolveUrl()).digest('hex').slice(0, 12)}.json`); };
function writeNodeFlags(oi, rmbg, rmbgT) {
  const flags = Object.fromEntries(Object.entries(oi).map(([k, v]) => [k, { api_node: v?.api_node === true, output_node: v?.output_node === true }]));
  // rmbgT:RMBG 清單的時間只由 check 更新(run 重抓旗標時沿用舊時間,不會延長)
  try { writeFileSync(flagsFile(), JSON.stringify({ t: Date.now(), flags, rmbg: rmbg ?? null, rmbgT: rmbg ? (rmbgT ?? Date.now()) : null }), { mode: 0o600 }); } catch {}
  return flags;
}
function readCache() {
  try { const c = JSON.parse(readFileSync(flagsFile(), 'utf8')); return Date.now() - c.t < 3600000 ? c : null; } catch { return null; }
}
const readNodeFlags = () => readCache()?.flags ?? null;

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
  if (/stable.?audio/.test(n)) return 'stable-audio';
  if (/ace.?step.?(v)?1[._]5/.test(n)) return 'ace-step-1.5';
  if (/ace.?step/.test(n)) return 'ace-step';
  return '未知';
}
// /models 可能回子資料夾路徑(例如 flux/ae.safetensors):用檔名比對,回傳完整路徑
const pick = (list, re) => list.find(x => re.test(x.toLowerCase().split('/').pop())) ?? null;

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
    // Stable Audio 3 配 t5gemma;Stable Audio Open 配 t5-base(同家族才配對)
    sfx_ckpt: pick(models.checkpoints, /stable.?audio.?3.*sfx/) ?? pick(models.checkpoints, /stable.?audio.?3/) ?? pick(models.checkpoints, /stable.?audio.?open/),
    sfx_clip: null,
    bgm_ckpt: pick(models.checkpoints, /ace.?step.?(v)?1[._]5/),
  };
  // 本機去背:kit 的 sprite 骨架用 AILab 的 RMBG 節點(輸出 [1] 是 MASK);只列模型檔在主機上的選項。
  // RMBG 第一次用到沒下載的模型會自動下載 → 只列 models/rmbg 已經有檔案的選項,避免在主機上下載。
  d.sfx_clip = !d.sfx_ckpt ? null : /stable.?audio.?3/i.test(d.sfx_ckpt) ? pick(te, /t5.?gemma/) : pick(te, /t5.?base/);
  // Windows 主機回傳反斜線路徑,統一成 /
  const rmbgFiles = await json('/models/rmbg').then(x => Array.isArray(x) ? x.map(f => String(f).replace(/\\/g, '/')) : []);
  const opts = (node) => { const m = oi[node]?.input?.required?.model; return Array.isArray(m?.[0]) ? m[0] : []; };
  // 每個模型需要的完整檔案(缺任何一個,RMBG 第一次用到時會在主機上下載 → 不列);不認得的模型不列
  const RMBG_FILES = {
    'RMBG-2.0': ['model.safetensors', 'config.json', 'birefnet.py', 'BiRefNet_config.py'],
    INSPYRENET: ['inspyrenet.safetensors'],
    BEN: ['BEN_Base.pth', 'model.py'],
    BEN2: ['BEN2_Base.pth', 'BEN2.py'],
  };
  const fileSet = new Set(rmbgFiles.map(f => f.toLowerCase()));
  const bg = [];
  if (has('RMBG')) {
    const ms = opts('RMBG').filter(o => RMBG_FILES[o] && RMBG_FILES[o].every(f => fileSet.has(`${o}/${f}`.toLowerCase())));
    if (ms.length) bg.push({ node: 'RMBG', models: ms });
  }
  const bgOk = bg.length > 0 && has('InvertMask') && has('JoinImageWithAlpha');
  writeNodeFlags(oi, bgOk ? bg.flatMap(x => x.models) : []);
  const unsupportedBg = [];
  const coreBg = await json('/models/background_removal').then(x => Array.isArray(x) ? x : []);
  if (has('RemoveBackground') && coreBg.length) unsupportedBg.push({ node: 'RemoveBackground', note: '主機有核心去背模型,但本 kit 的 sprite 骨架用 RMBG,不能用' });
  const workflows = {
    'qwen-t2i': !!(d.qwen_unet && d.qwen_clip && d.qwen_vae),
    'qwen-edit-1ref': !!(has('TextEncodeQwenImageEditPlus') && d.qwen_edit_unet && d.qwen_clip && d.qwen_vae)
      && has('CFGNorm') && has('ModelSamplingAuraFlow') && has('ImageScaleToTotalPixels') && has('EmptySD3LatentImage'),
    'qwen-edit-2ref': null, 'qwen-edit-3ref': null, // 同 qwen-edit-1ref,下面補
    'flux-t2i': !!(d.flux_unet && d.clip_l && d.t5 && d.flux_vae),
    'flux-kontext': !!(has('ReferenceLatent') && has('ConditioningZeroOut') && has('FluxKontextImageScale') && has('FluxGuidance') && has('VAEEncode') && d.flux_kontext_unet && d.clip_l && d.t5 && d.flux_vae),
    'zimage-t2i': !!(d.zimage_unet && d.zimage_clip && d.flux_vae && has('ModelSamplingAuraFlow')),
    'qwen-t2i-canny': !!(d.qwen_unet && d.qwen_clip && d.qwen_vae && d.qwen_controlnet_union && has('Canny') && has('SetUnionControlNetType')),
  };
  workflows['qwen-edit-2ref'] = workflows['qwen-edit-3ref'] = workflows['qwen-edit-1ref'];
  workflows['qwen-t2i-sprite'] = workflows['qwen-t2i'] && bgOk;
  workflows['qwen-edit-1ref-sprite'] = workflows['qwen-edit-1ref'] && bgOk;
  workflows['stable-audio-sfx'] = !!(d.sfx_ckpt && d.sfx_clip && ['CheckpointLoaderSimple', 'CLIPLoader', 'ConditioningStableAudio', 'EmptyLatentAudio', 'VAEDecodeAudio', 'PreviewAudio'].every(has));
  workflows['ace-step-bgm'] = !!(d.bgm_ckpt && ['CheckpointLoaderSimple', 'ModelSamplingAuraFlow', 'TextEncodeAceStepAudio1.5', 'ConditioningZeroOut', 'EmptyAceStep1.5LatentAudio', 'VAEDecodeAudio', 'PreviewAudio'].every(has));
  // consistency_methods 只列 kit 有骨架、而且骨架可用的方法(agent 只能用這些)。
  // 主機上有、但 kit 沒有骨架的方法(IP-Adapter)放 unsupported_consistency,只供 BLOCKED 時說明。
  const methods = [];
  if (workflows['qwen-edit-1ref']) methods.push({ method: 'qwen-image-edit', maxRefs: 3, workflows: ['qwen-edit-1ref', 'qwen-edit-2ref', 'qwen-edit-3ref'] });
  if (workflows['flux-kontext']) methods.push({ method: 'flux-kontext', maxRefs: 1, workflows: ['flux-kontext'] });
  const unsupported = [];
  const ipaNodes = Object.keys(oi).filter(n => /ipadapter/i.test(n));
  if (ipaNodes.length && models.ipadapter.length && models.clip_vision.length)
    unsupported.push({ method: 'ipadapter', note: '主機有 IP-Adapter,但本 kit 沒有 IP-Adapter 骨架,不能用' });
  const out = {
    ok: true,
    comfyui_version: stats.system?.comfyui_version ?? null,
    os: stats.system?.os ?? null,
    devices: (stats.devices ?? []).map(x => ({ name: x.name, vram_gb: Math.round((x.vram_total ?? 0) / 2 ** 30) })),
    models: Object.fromEntries(Object.entries(models).map(([k, v]) => [k, v.map(n => ({ name: n, family: family(n) }))])),
    consistency_methods: methods,
    unsupported_consistency: unsupported,
    background_removal: bgOk ? bg : [],
    unsupported_background_removal: unsupportedBg,
    audio_models: {
      sfx: workflows['stable-audio-sfx'] ? [d.sfx_ckpt] : [],
      bgm: workflows['ace-step-bgm'] ? [d.bgm_ckpt] : [],
    },
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

// 暫存可能在不同磁碟(rename 會 EXDEV),失敗就改用複製
const renameOrCopy = (a, b) => { try { renameSync(a, b); } catch { copyFileSync(a, b); } };
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function run() {
  const skelPath = pos[0] ?? die('用法:run <workflow.json> --out <目錄> --name <檔名> [--set k=v]...', 2);
  const out = flags.out ?? die('缺 --out', 2);
  const name = flags.name ?? die('缺 --name', 2);
  if (!/^[A-Za-z0-9_.-]+$/.test(name)) die('--name 只能用英數、_ . -', 2);
  const timeout = Number(flags.timeout ?? 240);
  if (!Number.isFinite(timeout) || timeout <= 0) die(`--timeout 要是正數(秒):${flags.timeout}`, 2);
  const queueTimeout = Number(flags['queue-timeout'] ?? 180);
  if (!Number.isFinite(queueTimeout) || queueTimeout <= 0) die(`--queue-timeout 要是正數(秒):${flags['queue-timeout']}`, 2);
  let skel;
  try { skel = JSON.parse(readFileSync(skelPath, 'utf8')); } catch (e) { die(`讀不到 workflow:${e.message}`, 2); }
  const { meta, graph, vals } = fill(skel, flags.set);
  if (Object.values(graph).some(n => /^Save(Image|Audio|Video|Animated|WEBM|Latent)/.test(n?.class_type ?? ''))) die('workflow 不可用 Save* 節點(會寫進伺服器 output/);圖用 PreviewImage、音訊用 PreviewAudio', 2);
  // 雲端 API 節點(付費、把內容送到外部):名稱黑名單 + /object_info 的 api_node 旗標,一律拒絕
  const CLOUD = /^(Bria|Recraft|Stability|ElevenLabs|OpenAI|Gemini|Kling|Luma|Runway|Ideogram|Pika|Minimax|Tripo|Moonvalley|Vidu|Rodin|Pixverse|Veo|Flux(Pro|Kontext(Pro|Max)))/;
  const classes = [...new Set(Object.values(graph).map(n => n?.class_type).filter(Boolean))];
  const cloudByName = classes.filter(c => CLOUD.test(c));
  if (cloudByName.length) die(`workflow 含雲端 API 節點,不能用:${cloudByName.join(', ')}`, 2);
  {
    // 節點旗標:優先用 check 存下的快取(1 小時內、同一個位址),沒有才抓 /object_info(上限 30 秒,落在呼叫端 180 秒餘量內,見 SKILL.md)
    let oi = readNodeFlags();
    // 快取裡沒有的節點(check 之後才裝的)一律重抓,不當成安全
    if (!oi || classes.some(c => !(c in oi))) {
      let full;
      try { full = await json('/object_info', { timeoutMs: 30000 }); } catch (e) { if (e instanceof Fail && e.code === 5) die('抓 /object_info 超過 30 秒或連不上;先跑 comfy.mjs check(會存節點旗標快取)再 run', 5); throw e; }
      if (full.__status) die(`/object_info 回 HTTP ${full.__status}`, 3);
      const old = readCache();
      oi = writeNodeFlags(full, old?.rmbg, old?.rmbgT); // 保留 check 存的 RMBG 清單與它的時間
    }
    const api = classes.filter(c => oi[c]?.api_node === true);
    if (api.length) die(`workflow 含雲端 API 節點,不能用:${api.join(', ')}`, 2);
    // 其他會寫進伺服器 output/ 的輸出節點(CheckpointSave、SaveGLB、自訂 Image Save…):output_node 且不是 Preview*
    // RMBG 只能用 check 確認檔案齊全的模型(其他的會在主機上自動下載)
    const rmbgUsed = Object.values(graph).filter(n => n?.class_type === 'RMBG').map(n => n.inputs?.model);
    if (rmbgUsed.length) {
      const c = readCache();
      const ok = c && c.rmbg && Date.now() - (c.rmbgT ?? 0) < 3600000 ? c.rmbg : null;
      if (!ok) die('用到 RMBG 但沒有 check 的結果(或超過 1 小時);先跑 comfy.mjs check', 2);
      const bad = rmbgUsed.filter(m => !ok.includes(m));
      if (bad.length) die(`RMBG 模型 ${bad.join(', ')} 不在主機上檔案齊全的清單(${ok.join(', ') || '無'});用了會讓主機自動下載`, 2);
    }
    const writers = classes.filter(c => oi[c]?.output_node === true && !/^Preview/.test(c));
    if (writers.length) die(`workflow 含會寫進伺服器的輸出節點,不能用(只用 PreviewImage / PreviewAudio):${writers.join(', ')}`, 2);
  }

  const t0 = Date.now();
  const client_id = randomUUID();
  const post = (path, obj, ms = 10000) => api(path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(obj), timeoutMs: ms });
  let id = null;
  let finished = false;
  let submitting = null; // 送出中的 /prompt;中止時等它回來才知道要取消哪個工作
  const SUBMIT_MS = 15000; // 送出逾時;中止時等待送出的時間比它長,一定等得到結果
  // 收尾:沒完成就只取消自己的工作(佇列中 → 移出;確認在執行 → 指定 prompt_id 中斷),等 history 出現再刪。
  // 總時間上限 40 秒;/queue 查不到狀態時只做「移出佇列」(不盲目中斷,避免舊版 ComfyUI 中斷到別人的工作)。
  const CLEANUP_BUDGET = 40000;
  let cleaning = null; // 同一時間只跑一次收尾(逾時路徑與訊號處理共用)
  const cleanup = () => (cleaning ??= doCleanup());
  const doCleanup = async () => {
    if (!id) return;
    const end = Date.now() + CLEANUP_BUDGET;
    const left = () => Math.max(1000, end - Date.now());
    try {
      const safe = async (f) => { try { return await f(); } catch { return null; } }; // 單次網路錯誤不中斷收尾
      if (!finished) {
        // /queue 在預算內重試,確定狀態才決定要移出佇列還是中斷
        let q = null;
        for (let i = 0; i < 3 && Date.now() < end - 15000; i++) {
          q = await safe(() => json('/queue', { timeoutMs: Math.min(5000, left()) }));
          if (q && !q.__status && Array.isArray(q.queue_running)) break;
          q = null; await sleep(1000);
        }
        const running = !!q && q.queue_running.some(x => x[1] === id);
        if (!running) {
          await safe(() => post('/queue', { delete: [id] }, Math.min(5000, left())));
          if (!q) console.error(`警告:查不到 ComfyUI 佇列狀態,已嘗試移出佇列;若工作 ${id} 已在執行,可能仍會跑完並留下 history`);
        } else {
          await safe(() => post('/interrupt', { prompt_id: id }, Math.min(5000, left())));
          while (Date.now() < end - 6000) { const h = await safe(() => json(`/history/${id}`, { timeoutMs: 3000 })); if (h && h[id]) break; await sleep(500); }
        }
      }
      await post('/history', { delete: [id] }, Math.min(10000, left()));
    } catch { console.error(`警告:清理 ComfyUI 上的工作 ${id} 失敗(連線問題或超過 40 秒),history 可能殘留`); }
  };
  // 被外部中止(Ctrl-C、Bash 工具逾時送 SIGTERM、終端機關閉)時也收尾;送出前就註冊,重複的訊號會被忽略
  let stage = null; // 下載暫存目錄;中止時也要刪
  let printed = false; // 已印出 ok 結果、檔案已就位
  const onSignal = async (sig) => {
    if (STOPPING) process.exit({ SIGINT: 130, SIGHUP: 129 }[sig] ?? 143); // 第二次中止:立刻結束
    STOPPING = true;
    try {
      if (!printed) console.error(`收到 ${sig},取消 ComfyUI 上的工作後結束`);
      if (!id && submitting) {
        const r = await Promise.race([submitting.catch(() => null), sleep(SUBMIT_MS + 1000).then(() => null)]);
        if (r?.prompt_id) id = r.prompt_id;
        else if (!r) console.error('警告:送出中被中止且等不到 prompt_id,ComfyUI 上可能留下這個工作');
      }
      await cleanup();
      if (stage) rmSync(stage, { recursive: true, force: true });
    } catch (e) {
      console.error(`警告:中止時收尾失敗:${e?.message || e}`);
    } finally {
      // 結果已印出就算成功(只是收尾被打斷),否則 130 / 129 / 143
      process.exit(printed ? 0 : { SIGINT: 130, SIGHUP: 129 }[sig] ?? 143);
    }
  };
  const halt = () => new Promise(() => {}); // 中止中:停在這裡,等訊號處理結束程序
  for (const sg of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sg, onSignal);

  submitting = json('/prompt', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ prompt: graph, client_id }), timeoutMs: SUBMIT_MS });
  const sub = await submitting;
  if (sub.prompt_id) id = sub.prompt_id;
  if (STOPPING) await halt();
  if (sub.__status || sub.error) {
    const body = sub.__body ? (() => { try { return JSON.parse(sub.__body); } catch { return sub.__body; } })() : sub;
    console.error(JSON.stringify(body, null, 1).slice(0, 3000));
    die('ComfyUI 拒絕這個 workflow(見上方 node_errors)', 3);
  }
  try {
    let hist = null;
    // 時限:執行 --timeout(從離開排隊算)、排隊 --queue-timeout(只在 /queue 確認還在排隊時累計)、
    // 總時限 = 兩者相加(/queue 一直查不到狀態時兜底)。
    let startedAt = null, queuedMs = 0, lastPending = false, lastTick = Date.now();
    // 輪詢時的網路錯誤 / 逾時不放棄,下一輪再試;連續 5 次才當作連不上
    let fails = 0;
    const poll = async (path) => { try { const r = await json(path, { timeoutMs: 10000 }); fails = 0; return r; } catch (e) { if (!(e instanceof Fail) || e.code !== 5 || ++fails >= 5) throw e; return { __status: 'net' }; } };
    while (true) {
      if (STOPPING) await halt();
      const h = await poll(`/history/${id}`);
      if (STOPPING) await halt();
      const now = Date.now();
      if (lastPending) queuedMs += now - lastTick;
      lastTick = now;
      if (h && h[id]) {
        hist = h[id];
        if (hist.status?.completed || hist.status?.status_str === 'error') break;
        if (startedAt === null) startedAt = now; // 已有 history 代表開始執行
      }
      if (startedAt === null) {
        const q = await poll('/queue');
        if (STOPPING) await halt();
        if (!q.__status && Array.isArray(q.queue_pending)) {
          lastPending = q.queue_pending.some(x => x[1] === id);
          const running = Array.isArray(q.queue_running) && q.queue_running.some(x => x[1] === id);
          if (!lastPending || running) { startedAt = Date.now(); lastPending = false; }
        } else lastPending = false; // 狀態不明時不累計排隊時間,交給總時限兜底
      } else lastPending = false;
      const ran = startedAt === null ? 0 : (Date.now() - startedAt) / 1000;
      const waited = queuedMs / 1000, total = (Date.now() - t0) / 1000;
      const reason = ran > timeout ? 'run' : waited > queueTimeout ? 'queue' : total > timeout + queueTimeout ? 'total' : null;
      if (reason) {
        await cleanup();
        if (STOPPING) await halt(); // 收尾期間收到中止訊號:交給訊號處理
        const limit = reason === 'run' ? timeout : reason === 'queue' ? queueTimeout : timeout + queueTimeout;
        console.log(JSON.stringify({ name, status: 'timeout', reason, seconds: limit, elapsed: Math.round(reason === 'run' ? ran : reason === 'queue' ? waited : total), prompt_id: id }));
        process.exit(4);
      }
      await sleep(1000);
    }
    if (STOPPING) await halt();
    finished = true;
    if (hist.status?.status_str === 'error') {
      const all = hist.status.messages ?? [];
      const errs = all.filter(m => ['execution_error', 'execution_interrupted'].includes(m[0]));
      const msgs = (errs.length ? errs : all).map(m => ({ type: m[0], ...m[1] }));
      console.error(JSON.stringify(msgs, null, 1).slice(0, 3000));
      die('ComfyUI 執行失敗(見上方)', 3);
    }
    const imgs = [];
    for (const o of Object.values(hist.outputs ?? {})) {
      for (const im of o.images ?? []) imgs.push({ ...im, kind: 'image' });
      for (const au of o.audio ?? []) imgs.push({ ...au, kind: 'audio' });
    }
    if (!imgs.length) die('workflow 沒有輸出(圖要有 PreviewImage、音訊要有 PreviewAudio)', 3);
    // 先全部下載到暫存,都成功才搬進 --out(避免留下半套檔案)
    stage = mkdtempSync(join(tmpdir(), 'gak-run-'));
    const files = [];
    const dlEnd = Date.now() + 60000; // 下載總時間上限 60 秒
    try {
      for (let i = 0; i < imgs.length; i++) {
        if (STOPPING) await halt();
        const im = imgs[i];
        const q = new URLSearchParams({ filename: im.filename, subfolder: im.subfolder ?? '', type: im.type ?? 'temp' });
        if (Date.now() > dlEnd) die('下載輸出超過 60 秒', 5);
        const r = await api(`/view?${q}`, { timeoutMs: Math.max(1000, dlEnd - Date.now()) });
        if (!r.ok) die(`下載輸出失敗 HTTP ${r.status}`, 3);
        let buf;
        try { buf = Buffer.from(await r.arrayBuffer()); } catch (e) { die(`下載輸出途中斷線(${e.cause?.code || e.name})`, 5); }
        const ext = im.kind === 'image' ? '.png' : (extname(im.filename).toLowerCase().replace(/[^.a-z0-9]/g, '') || '.flac');
        const fname = imgs.length === 1 ? `${name}${ext}` : `${name}-${i + 1}${ext}`;
        writeFileSync(join(stage, fname), buf);
        files.push(im.kind === 'image' ? { fname, ...pngSize(join(stage, fname)), channels: pngChannels(join(stage, fname)) } : { fname, kind: 'audio', bytes: buf.length });
      }
      if (STOPPING) await halt();
      mkdirSync(join(out, 'workflows'), { recursive: true });
      for (const f of files) { renameOrCopy(join(stage, f.fname), join(out, f.fname)); f.file = join(out, f.fname); delete f.fname; }
    } finally {
      if (!STOPPING) { rmSync(stage, { recursive: true, force: true }); stage = null; }
    }
    // 成功才存實際送出的 workflow(不含位址),避免留下沒有對應圖片的檔案
    writeFileSync(join(out, 'workflows', `${name}.json`), JSON.stringify({ _meta: { ...meta, skeleton: basename(skelPath), params: vals }, ...graph }, null, 1));
    console.log(JSON.stringify({ name, status: 'ok', seconds: Math.round((Date.now() - t0) / 100) / 10, files, params: vals }));
    printed = true;
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
    // IP 或含點的主機名稱(comfy.local、x.ts.net)→ 不論有沒有埠號都比對主機名稱;
    // 單字主機名稱(例如 comfy)→ 只比對 //comfy 或 comfy:<埠>,避免誤中一般文字(comfy.mjs)
    const b = '(?<![\\w.-])', a = '(?![\\w-])';
    hostRe = /[.:]/.test(hostname)
      ? new RegExp(`${b}${esc(hostname)}${a}`)
      : new RegExp(`//${esc(hostname)}(?![\\w.-])|${b}${esc(hostname)}${port ? `:${port}` : ':\\d+'}\\b`);
  }
  const pats = [/\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b/, /\b169\.254\.\d{1,3}\.\d{1,3}\b/, /\b(?:10|127)\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/, /\b192\.168\.\d{1,3}\.\d{1,3}\b/, /\b172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b/, /:8188\b/];
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
