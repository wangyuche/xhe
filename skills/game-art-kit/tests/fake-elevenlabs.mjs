#!/usr/bin/env node
// 假的 ElevenLabs API(離線測試用)。用法:node fake-elevenlabs.mjs <埠> <請求記錄檔>
// 行為:design → 3 個 preview(1 秒 440 Hz WAV);text-to-voice → voice_id(voice_name 含 LIMIT → 400 voice_limit_reached);
// text-to-speech:text 含 SILENT → 靜音;QUOTA → 402;AUTH → 401;BUSY → 第一次 429(retry-after 0)之後成功。
import { createServer } from 'node:http';
import { appendFileSync } from 'node:fs';
const [port, logFile] = process.argv.slice(2);
const wav = (silent, secs = 1) => { const sr = 8000, n = Math.round(sr * secs), b = Buffer.alloc(44 + n * 2); b.write('RIFF', 0); b.writeUInt32LE(36 + n * 2, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(sr, 24); b.writeUInt32LE(sr * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(n * 2, 40); for (let i = 0; i < n; i++) b.writeInt16LE(silent ? 0 : Math.round(Math.sin(2 * Math.PI * 440 * i / sr) * 8000), 44 + i * 2); return b; };
let busy = 0;
createServer((req, res) => {
  const c = []; req.on('data', d => c.push(d)); req.on('end', () => {
    let body = {}; try { body = JSON.parse(Buffer.concat(c).toString()); } catch { /* */ }
    appendFileSync(logFile, JSON.stringify({ path: req.url, key: req.headers['xi-api-key'], body }) + '\n');
    const send = (code, obj, type = 'application/json', h = {}) => { res.writeHead(code, { 'content-type': type, ...h }); res.end(type === 'application/json' ? JSON.stringify(obj) : obj); };
    const p = req.url.split('?')[0];
    if (p === '/v1/text-to-voice/design') return send(200, { previews: [1, 2, 3].map(i => ({ audio_base_64: wav(false).toString('base64'), generated_voice_id: `gen-${i}`, duration_secs: 1 })) });
    if (p === '/v1/text-to-voice') return /LIMIT/.test(body.voice_name ?? '') ? send(400, { detail: { status: 'voice_limit_reached', message: 'maximum number of voices' } }) : send(200, { voice_id: `voice-${body.generated_voice_id}` });
    if (p.startsWith('/v1/text-to-speech/')) {
      const t = body.text ?? '';
      if (/QUOTA/.test(t)) return send(402, { detail: { status: 'insufficient_credits' } });
      if (/AUTH/.test(t)) return send(401, { detail: { status: 'invalid_api_key' } });
      if (/BUSY/.test(t) && busy++ === 0) return send(429, { detail: 'busy' }, 'application/json', { 'retry-after': '1' });
      return send(200, wav(/SILENT/.test(t), /SHORT/.test(t) ? 0.25 : /LONG/.test(t) ? 16 : 1), 'audio/wav');
    }
    send(404, {});
  });
}).listen(Number(port), '127.0.0.1', () => console.log(`listening ${port}`));
