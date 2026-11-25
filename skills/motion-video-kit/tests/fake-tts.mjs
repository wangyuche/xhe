#!/usr/bin/env node
// 測試用假旁白:node fake-tts.mjs <storyboard.json> <輸出目錄> [--total <秒>]
// 每句 = 正弦波(長度依顯示字數 0.2 秒 / 字,最少 0.6 秒;--total 時等比例縮放到片長 ≈ total),輸出格式同 tts.mjs 的 tts.json。
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join, resolve } from 'node:path';
import { tokenize, lineText, r3 } from '../scripts/_lib.mjs';

const [sb, outArg, flag, val] = process.argv.slice(2);
const board = JSON.parse(readFileSync(sb, 'utf8'));
const out = resolve(outArg); mkdirSync(out, { recursive: true });
const lines = board.scenes.flatMap(s => s.lines).map(l => tokenize(lineText(l)).display);
let d = lines.map(t => Math.max(0.6, [...t].filter(c => c !== ' ').length * 0.2));
if (flag === '--total') {
  const fixed = 0.3 + 0.25 * (d.length - 1) + 0.6;
  const k = (Number(val) - fixed) / d.reduce((a, b) => a + b, 0);
  d = d.map(x => r3(x * k));
}
const res = lines.map((text, i) => {
  const file = `${String(i + 1).padStart(3, '0')}.wav`;
  const r = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', `sine=f=${260 + (i % 8) * 45}:d=${d[i]}`, '-af', 'volume=0.5', '-ar', '48000', '-ac', '1', join(out, file)]);
  if (r.status !== 0) process.exit(1);
  return { i: i + 1, text, say: null, file, duration: d[i], maxVolume: -9, seed: 0, retries: 0, ok: true, engine: 'sine' };
});
writeFileSync(join(out, 'tts.json'), JSON.stringify(res, null, 1));
console.log(JSON.stringify(res));
