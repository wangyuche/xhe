#!/usr/bin/env node
// 用法:node contact.mjs <影片> <輸出.png> [--every 1] [--cols 6] [--width 240]
// 每 --every 秒擷一格(從 --every/2 秒起),縮成寬 --width,拼成 --cols 欄的總表(看整體節奏與空白)。
// stdout {"file","frames","cols","rows"};結束碼:0 成功、2 參數不合法、3 缺 ffmpeg、1 其他。
import { mkdirSync, existsSync, mkdtempSync, rmSync, readdirSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { main, fail, parseArgs, run, probeDuration, hasCmd } from './_lib.mjs';

const USAGE = '用法:node contact.mjs <影片> <輸出.png> [--every 1] [--cols 6] [--width 240]';
main(() => {
  const a = parseArgs(process.argv.slice(2), { '--every': 'v', '--cols': 'v', '--width': 'v' }, USAGE);
  if (a._.length !== 2) fail(USAGE, 2);
  if (!hasCmd('ffmpeg')) fail('缺 ffmpeg(brew install ffmpeg)', 3);
  const [video, outArg] = a._; const out = resolve(outArg);
  const every = Number(a.every ?? 1), cols = Number(a.cols ?? 6), width = Number(a.width ?? 240);
  if (!(every >= 0.2 && every <= 30)) fail('--every 要是 0.2 ~ 30 秒', 2);
  if (!(Number.isInteger(cols) && cols >= 1 && cols <= 20)) fail('--cols 要是 1 ~ 20 的整數', 2);
  if (!(Number.isInteger(width) && width >= 60 && width <= 1080 && width % 2 === 0)) fail('--width 要是 60 ~ 1080 的偶數', 2);
  if (!existsSync(video)) fail(`找不到影片:${video}`, 2);
  if (!out.endsWith('.png')) fail('輸出要是 .png', 2);
  const d = probeDuration(video);
  mkdirSync(dirname(out), { recursive: true });
  const tmp = mkdtempSync(join(dirname(out), '.contact-'));
  try {
    // 先逐格輸出再拼(tile 濾鏡在最後一列沒填滿時不輸出,所以自己補足列數)
    run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-ss', String(every / 2), '-i', video, '-vf', `fps=1/${every},scale=${width}:-2`, join(tmp, '%04d.png')], '擷格');
    const n = readdirSync(tmp).filter(f => f.endsWith('.png')).length;
    if (!n) fail('影片太短,擷不到畫面', 2);
    const c = Math.min(cols, n), rows = Math.ceil(n / c);
    run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-framerate', '1', '-i', join(tmp, '%04d.png'),
      '-vf', `tpad=stop_mode=add:stop=${c * rows - n}:color=white,tile=${c}x${rows}:padding=6:margin=6:color=white`, '-frames:v', '1', '-update', '1', out], '拼總表');
    console.log(JSON.stringify({ file: out, frames: n, cols: c, rows, every, duration: d }));
  } finally { rmSync(tmp, { recursive: true, force: true }); }
});
