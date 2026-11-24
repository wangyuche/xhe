#!/usr/bin/env node
// 用法:node mix.mjs <silent.mp4> <tts.json> <timing.json> <輸出.mp4> [--music <檔>] [--music-volume 0.2] [--sfx <sfx.json>]
// 旁白依 timing.json 的句子 start 排程(tts.json 的 file 相對 tts.json 所在目錄)、配樂說話時自動壓低(sidechain)、結尾淡出、
// 音效(sfx.json = [{"path":相對 sfx.json,"at":秒,"volume":0~2}],最多 3 個)、loudnorm 兩階段(−14 LUFS、TP −1.5)。
// 影片串流直接複製(不重新編碼);AAC 48 kHz 192k、faststart;長度 = timing.duration。
// 混音實作是 short-video-kit 的 scripts/_mix.mjs(共用,不複製)。中間檔 mix.wav 寫在 silent.mp4 同目錄。
// stdout 一行 JSON;結束碼:0 成功、2 參數或輸入不合法、3 缺 ffmpeg、1 其他。
import { readFileSync, existsSync, mkdirSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { SVK, main, fail, parseArgs, run, probeDuration, hasCmd, r3 } from './_lib.mjs';

const USAGE = '用法:node mix.mjs <silent.mp4> <tts.json> <timing.json> <輸出.mp4> [--music <檔>] [--music-volume 0.2] [--sfx <sfx.json>]';
main(async () => {
  const a = parseArgs(process.argv.slice(2), { '--music': 'v', '--music-volume': 'v', '--sfx': 'v' }, USAGE);
  if (a._.length !== 4) fail(USAGE, 2);
  if (!hasCmd('ffmpeg')) fail('缺 ffmpeg(brew install ffmpeg)', 3);
  const [silent, ttsPath, timingPath, out] = a._.map(p => resolve(p));
  for (const f of [silent, ttsPath, timingPath]) if (!existsSync(f)) fail(`找不到 ${f}`, 2);
  const read = (f) => { try { return JSON.parse(readFileSync(f, 'utf8')); } catch (e) { fail(`讀不到 ${f}:${e.message}`, 2); } };
  const tts = read(ttsPath); const timing = read(timingPath);
  if (!Array.isArray(tts) || !Array.isArray(timing.sentences) || !(timing.duration > 0)) fail('tts.json 要是陣列、timing.json 要是 render.mjs 寫的格式', 2);
  if (tts.length !== timing.sentences.length) fail(`tts.json ${tts.length} 句,timing.json ${timing.sentences.length} 句(不是同一支?)`, 2);
  const total = timing.duration;
  const vd = probeDuration(silent);
  if (Math.abs(vd - total) > 0.1) fail(`silent.mp4 長 ${r3(vd)} 秒,timing.duration ${total} 秒(不是同一支?)`, 2);
  const tdir = dirname(ttsPath);
  const voices = tts.map((x, i) => {
    const p = resolve(tdir, String(x.file ?? ''));
    if (!x.file || !existsSync(p)) fail(`找不到旁白檔:tts.json[${i}].file = ${x.file}`, 2);
    return { path: p, at: timing.sentences[i].start };
  });
  let music = null;
  if (a.music) {
    const p = resolve(a.music); if (!existsSync(p)) fail(`找不到配樂:${a.music}`, 2);
    const v = a['music-volume'] === undefined ? 0.2 : Number(a['music-volume']);
    if (!(v >= 0 && v <= 1)) fail('--music-volume 要是 0~1', 2);
    music = { path: p, volume: v };
  }
  let sfx = [];
  if (a.sfx) {
    const sp = resolve(a.sfx); const list = read(sp);
    if (!Array.isArray(list) || list.length > 3) fail('sfx.json 要是陣列(最多 3 個)', 2);
    sfx = list.map((x, i) => {
      const p = resolve(dirname(sp), String(x?.path ?? ''));
      const v = x?.volume === undefined ? 0.8 : x.volume;
      if (!x?.path || !existsSync(p)) fail(`找不到音效:sfx[${i}].path = ${x?.path}`, 2);
      if (typeof v !== 'number' || !(v >= 0 && v <= 2)) fail(`sfx[${i}].volume 要是 0~2 的數字`, 2);
      if (typeof x.at !== 'number' || !(x.at >= 0 && x.at < total)) fail(`sfx[${i}].at 要是 0 ~ 片長的秒數`, 2);
      return { path: p, volume: v, at: x.at };
    }).filter(x => x.volume > 0);
  }
  const { narrationVoice, mixWav, measureLoudness, loudnormFilter } = await import(pathToFileURL(join(SVK, '_mix.mjs')).href);
  const mixFile = join(dirname(silent), 'mix.wav');
  mixWav({ voice: narrationVoice(voices, total), total, music, sfx, out: mixFile, run });
  const m = measureLoudness(mixFile, run);
  mkdirSync(dirname(out), { recursive: true });
  run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', silent, '-i', mixFile,
    '-filter_complex', loudnormFilter(m.ln, '[1:a]', '[aout]'), '-map', '0:v', '-map', '[aout]',
    '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-ar', '48000', '-ac', '2', '-movflags', '+faststart', '-t', String(total), out], '合成');
  console.log(JSON.stringify({ final: out, duration: r3(probeDuration(out)), loudnessIn: m.raw ? Number(m.raw.input_i) : null, music: !!music, sfx: sfx.map(x => ({ at: x.at, volume: x.volume })), mix: mixFile }));
});
