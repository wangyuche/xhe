#!/usr/bin/env node
// 假的 ComfyUI(離線測試用)。用法:node fake-comfy.mjs <埠> <請求記錄檔>
// 行為:/prompt 收到未知節點 → 400 node_errors;含 "FAIL" 提示詞 → 執行錯誤;含 "SLOW" → 永遠不完成(測逾時);
// 其他 → 0.3 秒後完成,輸出一張 width×height 的 PNG(取 EmptySD3LatentImage 的尺寸,沒有就 64×64)。
import { createServer } from 'node:http';
import { appendFileSync } from 'node:fs';
import { deflateSync, crc32 } from 'node:zlib';

const [port, logFile] = process.argv.slice(2);
const log = (o) => appendFileSync(logFile, JSON.stringify(o) + '\n');
const NODES = ['UNETLoader', 'CLIPLoader', 'DualCLIPLoader', 'VAELoader', 'LoraLoaderModelOnly', 'ModelSamplingAuraFlow', 'CFGNorm', 'CLIPTextEncode',
  'EmptySD3LatentImage', 'KSampler', 'VAEDecode', 'PreviewImage', 'SaveImage', 'LoadImage', 'ImageScaleToTotalPixels', 'TextEncodeQwenImageEditPlus',
  'FluxGuidance', 'ConditioningZeroOut', 'FluxKontextImageScale', 'VAEEncode', 'ReferenceLatent', 'ImageScale', 'Canny', 'ControlNetLoader',
  'SetUnionControlNetType', 'ControlNetApplyAdvanced'];
const MODELS = {
  diffusion_models: ['qwen_image_fp8_e4m3fn.safetensors', 'qwen_image_edit_2511_fp8mixed.safetensors', 'flux1-dev-fp8.safetensors'],
  text_encoders: ['qwen_2.5_vl_7b_fp8_scaled.safetensors', 'clip_l.safetensors', 't5xxl_fp8_e4m3fn.safetensors'],
  vae: ['qwen_image_vae.safetensors', 'ae.safetensors'], loras: ['Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors'],
  checkpoints: [], controlnet: [], clip_vision: [], style_models: [],
};

function png(w, h) {
  const chunk = (type, data) => { const b = Buffer.alloc(8 + data.length + 4); b.writeUInt32BE(data.length, 0); b.write(type, 4); data.copy(b, 8); b.writeUInt32BE(crc32(Buffer.concat([Buffer.from(type), data])) >>> 0, 8 + data.length); return b; };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  const raw = Buffer.alloc((w * 3 + 1) * h); for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) raw[y * (w * 3 + 1) + 1 + x * 3] = 200;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
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
  if (p === '/object_info') return send(res, 200, Object.fromEntries(NODES.map(k => [k, { input: {} }])));
  if (p === '/upload/image') return send(res, 200, { name: entry.filename, subfolder: '', type: entry.type });
  if (p === '/prompt' && req.method === 'POST') {
    const g = entry.body?.prompt ?? {};
    const bad = Object.entries(g).filter(([, v]) => !NODES.includes(v.class_type));
    if (bad.length) return send(res, 400, { error: { type: 'invalid_prompt' }, node_errors: Object.fromEntries(bad.map(([k, v]) => [k, { class_type: v.class_type, errors: [{ message: 'unknown node' }] }])) });
    const id = `fake-${++n}`;
    const lat = Object.values(g).find(v => v.class_type === 'EmptySD3LatentImage')?.inputs ?? {};
    const text = JSON.stringify(g);
    const job = { w: lat.width ?? 64, h: lat.height ?? 64, done: false, error: /FAIL/.test(text), slow: /SLOW/.test(text), dropview: /DROPVIEW/.test(text), pending: /QUEUED/.test(text), queueErr: /QUEUEERR/.test(text) ? 3 : 0, histDrop: /FLAKYHIST/.test(text) ? 2 : 0 };
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
    return send(res, 200, { [id]: { status: { status_str: 'success', completed: true }, outputs: { 11: { images: [{ filename: `${id}.png`, subfolder: '', type: 'temp' }] } } } });
  }
  if (p === '/history' && req.method === 'POST') { for (const id of entry.body?.delete ?? []) jobs.delete(id); return send(res, 200, {}); }
  if (p === '/view') {
    const id = u.searchParams.get('filename').replace(/\.png$/, ''), j = jobs.get(id);
    if (!j) return send(res, 404, {});
    if (j.dropview) return req.socket.destroy();
    return send(res, 200, png(j.w, j.h), 'image/png');
  }
  if (p === '/queue' && req.method === 'GET' && [...jobs.values()].some(j => j.queueErr > 0)) { for (const j of jobs.values()) if (j.queueErr > 0) j.queueErr--; return send(res, 500, { error: 'busy' }); }
  if (p === '/queue' && req.method === 'GET') return send(res, 200, { queue_running: [...jobs].filter(([, j]) => j.slow).map(([id]) => [0, id]), queue_pending: [...jobs].filter(([, j]) => j.pending).map(([id]) => [0, id]) });
  if (p === '/interrupt') { const j = jobs.get(entry.body?.prompt_id); if (j) { j.slow = false; j.done = true; j.error = true; } return send(res, 200, {}); }
  if (p === '/queue') return send(res, 200, {});
  send(res, 404, {});
}).listen(Number(port), '127.0.0.1', () => console.log(`listening ${port}`));
