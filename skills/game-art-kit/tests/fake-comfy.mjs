#!/usr/bin/env node
// 假的 ComfyUI(離線測試用)。用法:node fake-comfy.mjs <埠> <請求記錄檔> [ipadapter-only]
// ipadapter-only:只有 Flux dev + IP-Adapter 節點與模型(沒有 Qwen-Image-Edit、Kontext),測 check 不列沒有骨架的方法。
// 行為:/prompt 收到未知節點 → 400 node_errors;含 "FAIL" 提示詞 → 執行錯誤;含 "SLOW" → 永遠不完成(測逾時);
// 其他 → 0.3 秒後完成,輸出一張 width×height 的 PNG(取 EmptySD3LatentImage 的尺寸,沒有就 64×64)。
import { createServer } from 'node:http';
import { appendFileSync } from 'node:fs';
import { deflateSync, crc32 } from 'node:zlib';

const [port, logFile, profile] = process.argv.slice(2);
const log = (o) => appendFileSync(logFile, JSON.stringify(o) + '\n');
const NODES = ['UNETLoader', 'CLIPLoader', 'DualCLIPLoader', 'VAELoader', 'LoraLoaderModelOnly', 'ModelSamplingAuraFlow', 'CFGNorm', 'CLIPTextEncode',
  'EmptySD3LatentImage', 'KSampler', 'VAEDecode', 'PreviewImage', 'SaveImage', 'LoadImage', 'ImageScaleToTotalPixels', 'TextEncodeQwenImageEditPlus',
  'FluxGuidance', 'ConditioningZeroOut', 'FluxKontextImageScale', 'VAEEncode', 'ReferenceLatent', 'ImageScale', 'Canny', 'ControlNetLoader',
  'SetUnionControlNetType', 'ControlNetApplyAdvanced', 'RMBG', 'InvertMask', 'JoinImageWithAlpha', 'CheckpointLoaderSimple', 'ConditioningStableAudio',
  'EmptyLatentAudio', 'VAEDecodeAudio', 'PreviewAudio', 'SaveAudio', 'TextEncodeAceStepAudio1.5', 'EmptyAceStep1.5LatentAudio', 'ConditioningZeroOut', 'BriaRemoveImageBackground', 'FancyApiNode', 'CheckpointSave',
  // 影片(Wan 2.2 TI2V、LTX-2.3)
  'ModelSamplingSD3', 'Wan22ImageToVideoLatent', 'LTXAVTextEncoderLoader', 'LTXVConditioning', 'LTXVPreprocess', 'EmptyLTXVLatentVideo', 'LTXVImgToVideoInplace',
  'LTXVAudioVAELoader', 'LTXVEmptyLatentAudio', 'LTXVConcatAVLatent', 'CFGGuider', 'KSamplerSelect', 'ManualSigmas', 'RandomNoise', 'SamplerCustomAdvanced', 'LTXVSeparateAVLatent', 'VAEDecodeTiled',
  // 旁白(TTS Audio Suite 的 Qwen3-TTS)
  'Qwen3TTSEngineNode', 'UnifiedTTSTextNode', 'UnifiedVoiceDesignerNode'];
const OUTPUT_NODES = new Set(['PreviewImage', 'PreviewAudio', 'SaveImage', 'SaveAudio', 'CheckpointSave']);
// 雲端 API 節點(object_info 帶 api_node: true)
const API_NODES = new Set(['BriaRemoveImageBackground', 'FancyApiNode']);
// 環境變數 FAKE_NO_TTS=1:Qwen3-TTS 只有線上下載的選項(沒有 local: 模型);FAKE_TTS_MAIN_ONLY=1:沒有 Shared Runtime
// 旁白:文字含 SILENT → 回 1 秒靜音(測重生);其他回 1 秒 440 Hz
const NO_TTS = process.env.FAKE_NO_TTS === '1', TTS_MAIN_ONLY = process.env.FAKE_TTS_MAIN_ONLY === '1';
const QWEN3_INPUT = { required: { model_variant: [['TTS - Base 1.7B (Voice Clone)', 'TTS - CustomVoice 1.7B (Presets + Instruction)', ...(NO_TTS ? [] : ['local:Qwen3-TTS-12Hz-1.7B-Base', 'local:Qwen3-TTS-12Hz-1.7B-CustomVoice', 'local:Qwen3-TTS-12Hz-1.7B-VoiceDesign'])]] },
  optional: { runtime_mode: [['Main Environment', ...(TTS_MAIN_ONLY ? [] : ['⚠️ Shared Runtime'])]] } };
// 環境變數 FAKE_NO_RMBG=1:沒有去背模型檔;FAKE_NO_AUDIO=1:沒有音訊模型;FAKE_NO_VIDEO=1:沒有影片模型
const NO_RMBG = process.env.FAKE_NO_RMBG === '1', NO_AUDIO = process.env.FAKE_NO_AUDIO === '1', NO_VIDEO = process.env.FAKE_NO_VIDEO === '1', LTX_NOLORA = process.env.FAKE_LTX_NOLORA === '1', SEP = process.env.FAKE_WIN_PATHS === '1' ? '\\' : '/';
let MODELS = {
  diffusion_models: ['qwen_image_fp8_e4m3fn.safetensors', 'qwen_image_edit_2511_fp8mixed.safetensors', 'flux1-dev-fp8.safetensors', ...(NO_VIDEO ? [] : ['wan2.2_ti2v_5B_fp16.safetensors'])],
  text_encoders: ['qwen_2.5_vl_7b_fp8_scaled.safetensors', 'clip_l.safetensors', 't5xxl_fp8_e4m3fn.safetensors', 't5gemma_b_b_ul2.safetensors', ...(NO_VIDEO ? [] : ['umt5_xxl_fp8_e4m3fn_scaled.safetensors', 'gemma_3_12B_it_fp4_mixed.safetensors'])],
  vae: ['qwen_image_vae.safetensors', 'ae.safetensors', ...(NO_VIDEO ? [] : ['wan2.2_vae.safetensors'])], loras: ['Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors', ...(NO_VIDEO || LTX_NOLORA ? [] : ['ltx_2.3_22b_distilled_1.1_lora_dynamic_fro09_avg_rank_111_bf16.safetensors'])],
  checkpoints: [...(NO_AUDIO ? [] : ['stable_audio_3_small_sfx.safetensors', 'ace_step_1.5_turbo_aio.safetensors', 'ace_step_v1_3.5b.safetensors']), ...(NO_VIDEO ? [] : ['ltx-2.3-22b-distilled-fp8.safetensors', 'ltx-2.3-22b-dev-fp8.safetensors'])], controlnet: [], clip_vision: [], style_models: [],
  // RMBG-2.0 檔案齊全;BEN 少權重檔、BEN2 少 BEN2.py → 不應列出
  rmbg: NO_RMBG ? [] : ['RMBG-2.0/model.safetensors', 'RMBG-2.0/config.json', 'RMBG-2.0/birefnet.py', 'RMBG-2.0/BiRefNet_config.py', 'RMBG-2.0/.cache/x.metadata', 'BEN/model.py', 'BEN2/BEN2_Base.pth'].map(f => f.replace(/\//g, SEP)), background_removal: [],
};
if (profile === 'ipadapter-only') {
  NODES.push('IPAdapterAdvanced', 'IPAdapterModelLoader', 'CLIPVisionLoader');
  MODELS = { diffusion_models: ['flux1-dev-fp8.safetensors'], text_encoders: ['clip_l.safetensors', 't5xxl_fp8_e4m3fn.safetensors'], vae: ['ae.safetensors'],
    loras: [], checkpoints: [], controlnet: [], clip_vision: ['clip_vision_h.safetensors'], style_models: [], ipadapter: ['ip-adapter_plus.safetensors'] };
}

function png(w, h, alpha = false) {
  if (alpha) return pngRGBA(w, h);
  const chunk = (type, data) => { const b = Buffer.alloc(8 + data.length + 4); b.writeUInt32BE(data.length, 0); b.write(type, 4); data.copy(b, 8); b.writeUInt32BE(crc32(Buffer.concat([Buffer.from(type), data])) >>> 0, 8 + data.length); return b; };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  const raw = Buffer.alloc((w * 3 + 1) * h); for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) raw[y * (w * 3 + 1) + 1 + x * 3] = 200;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

// RGBA:中間一塊不透明的方塊,四周透明(模擬去背結果)
function pngRGBA(w, h) {
  const chunk = (type, data) => { const b = Buffer.alloc(8 + data.length + 4); b.writeUInt32BE(data.length, 0); b.write(type, 4); data.copy(b, 8); b.writeUInt32BE(crc32(Buffer.concat([Buffer.from(type), data])) >>> 0, 8 + data.length); return b; };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) { const o = y * (w * 4 + 1) + 1 + x * 4; raw[o] = 200; if (x > w / 4 && x < w * 3 / 4 && y > h / 8 && y < h * 7 / 8) raw[o + 3] = 255; }
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}
// 1 秒 440 Hz 的 WAV(模擬 PreviewAudio 輸出)
function wav(silent = false) {
  const sr = 8000, n = sr, b = Buffer.alloc(44 + n * 2);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n * 2, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(sr, 24); b.writeUInt32LE(sr * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) b.writeInt16LE(silent ? 0 : Math.round(Math.sin(2 * Math.PI * 440 * i / sr) * 8000), 44 + i * 2);
  return b;
}
const jobs = new Map(); // id → {graph, done, error, w, h}
let n = 0;
const body = (req) => new Promise(r => { const c = []; req.on('data', d => c.push(d)); req.on('end', () => r(Buffer.concat(c))); });
const send = (res, code, obj, type = 'application/json') => { res.writeHead(code, { 'content-type': type }); res.end(type === 'application/json' ? JSON.stringify(obj) : obj); };

createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  const b = await body(req);
  const entry = { method: req.method, path: u.pathname, query: Object.fromEntries(u.searchParams) };
  if (u.pathname === '/upload/image') {
    const s = b.toString('latin1');
    entry.type = (s.match(/name="type"\r\n\r\n([^\r]*)/) || [])[1];
    entry.filename = (s.match(/filename="([^"]+)"/) || [])[1];
  } else if (b.length) { try { entry.body = JSON.parse(b.toString()); } catch { entry.body = b.length; } }
  log(entry);
  const p = u.pathname;
  if (p === '/system_stats') return send(res, 200, { system: { os: 'linux', comfyui_version: '0.0.0-fake' }, devices: [{ name: 'fake', vram_total: 8 * 2 ** 30 }] });
  if (p.startsWith('/models/')) return send(res, 200, MODELS[p.slice(8)] ?? []);
  if (p === '/object_info') return send(res, 200, Object.fromEntries(NODES.map(k => [k, k === 'Qwen3TTSEngineNode' ? { input: QWEN3_INPUT, api_node: false, output_node: false } : k === 'RMBG' ? { input: { required: { image: ['IMAGE'], model: [['RMBG-2.0', 'INSPYRENET', 'BEN', 'BEN2']] } } } : { input: {}, api_node: API_NODES.has(k), output_node: OUTPUT_NODES.has(k) }])));
  if (p === '/upload/image') return send(res, 200, { name: entry.filename, subfolder: '', type: entry.type });
  if (p === '/prompt' && req.method === 'POST') {
    if (/SLOWSUBMIT/.test(JSON.stringify(entry.body ?? {}))) await new Promise(r => setTimeout(r, 1500)); // 送出很慢
    const g = entry.body?.prompt ?? {};
    const bad = Object.entries(g).filter(([, v]) => !NODES.includes(v.class_type));
    if (bad.length) return send(res, 400, { error: { type: 'invalid_prompt' }, node_errors: Object.fromEntries(bad.map(([k, v]) => [k, { class_type: v.class_type, errors: [{ message: 'unknown node' }] }])) });
    const id = `fake-${++n}`;
    const lat = Object.values(g).find(v => ['EmptySD3LatentImage', 'EmptyLTXVLatentVideo', 'Wan22ImageToVideoLatent'].includes(v.class_type))?.inputs ?? {};
    const frames = Object.values(g).some(v => ['EmptyLTXVLatentVideo', 'Wan22ImageToVideoLatent'].includes(v.class_type)) ? 3 : 1; // 影片:逐格輸出 3 張
    const text = JSON.stringify(g);
    const job = { frames, audio: Object.values(g).some(v => v.class_type === 'PreviewAudio'), alpha: Object.values(g).some(v => v.class_type === 'JoinImageWithAlpha'), w: lat.width ?? 64, h: lat.height ?? 64, done: false, error: /FAIL/.test(text), slow: /SLOW/.test(text), dropview: /DROPVIEW/.test(text), silent: /SILENT/.test(text), pending: /QUEUED/.test(text), queueErr: /QUEUEDOWN/.test(text) ? 1e9 : /QUEUEERR/.test(text) ? 3 : 0, histDrop: /FLAKYHIST/.test(text) ? 2 : 0 };
    jobs.set(id, job);
    // QUEUED:先排隊 2.5 秒(queue_pending),再執行 0.3 秒
    if (job.pending) setTimeout(() => { job.pending = false; setTimeout(() => { job.done = true; }, 300); }, 2500);
    else if (!job.slow) setTimeout(() => { job.done = true; }, 300);
    return send(res, 200, { prompt_id: id, number: n });
  }
  if (p.startsWith('/history/')) {
    const id = p.slice(9), j = jobs.get(id);
    if (j && j.histDrop > 0) { j.histDrop--; return req.socket.destroy(); }
    if (!j || !j.done) return send(res, 200, {});
    if (j.error) return send(res, 200, { [id]: { status: { status_str: 'error', completed: false, messages: [['execution_error', { exception_message: 'fake failure' }]] }, outputs: {} } });
    const outputs = j.audio ? { 8: { audio: [{ filename: `${id}.wav`, subfolder: '', type: 'temp' }] } } : { 11: { images: Array.from({ length: j.frames }, (_, k) => ({ filename: j.frames > 1 ? `${id}_${k}.png` : `${id}.png`, subfolder: '', type: 'temp' })) } };
    return send(res, 200, { [id]: { status: { status_str: 'success', completed: true }, outputs } });
  }
  if (p === '/history' && req.method === 'POST') { for (const id of entry.body?.delete ?? []) jobs.delete(id); return send(res, 200, {}); }
  if (p === '/view') {
    const id = u.searchParams.get('filename').replace(/(_\d+)?\.(png|wav)$/, ''), j = jobs.get(id);
    if (!j) return send(res, 404, {});
    if (j.dropview) return req.socket.destroy();
    if (j.audio) return send(res, 200, wav(j.silent), 'audio/wav');
    return send(res, 200, png(j.w, j.h, j.alpha), 'image/png');
  }
  if (p === '/queue' && req.method === 'GET' && [...jobs.values()].some(j => j.queueErr > 0 && !j.done)) { for (const j of jobs.values()) if (j.queueErr > 0) j.queueErr--; return send(res, 500, { error: 'busy' }); }
  if (p === '/queue' && req.method === 'GET') return send(res, 200, { queue_running: [...jobs].filter(([, j]) => j.slow).map(([id]) => [0, id]), queue_pending: [...jobs].filter(([, j]) => j.pending).map(([id]) => [0, id]) });
  if (p === '/interrupt') { const j = jobs.get(entry.body?.prompt_id); if (j) { j.slow = false; j.done = true; j.error = true; } return send(res, 200, {}); }
  if (p === '/queue') return send(res, 200, {});
  send(res, 404, {});
}).listen(Number(port), '127.0.0.1', () => console.log(`listening ${port}`));
