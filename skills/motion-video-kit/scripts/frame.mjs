#!/usr/bin/env node
// 用法:node frame.mjs <影片> <秒> <輸出.png>
// 從影片(repo-record 錄影、派工給的本機影片)擷一格當 storyboard 的截圖。輸出只能在 <job>/work/<n>/ 底下(路徑要含 /work/<n>/)。
// stdout {"file","width","height","t"};結束碼:0 成功、2 參數不合法(秒數超出、輸出位置不對)、3 缺 ffmpeg、1 其他。
import { mkdirSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { main, fail, parseArgs, run, probeDuration, probeSize, hasCmd } from './_lib.mjs';

const USAGE = '用法:node frame.mjs <影片> <秒> <輸出.png>(輸出限 <job>/work/<n>/ 底下)';
main(() => {
  const a = parseArgs(process.argv.slice(2), {}, USAGE);
  if (a._.length !== 3) fail(USAGE, 2);
  if (!hasCmd('ffmpeg')) fail('缺 ffmpeg(brew install ffmpeg)', 3);
  const [video, sec, outArg] = a._;
  const out = resolve(outArg);
  if (!/\/work\/[^/]+\/.+\.png$/.test(out)) fail(`輸出只能是 <job>/work/<n>/ 底下的 .png:${out}`, 2);
  if (!existsSync(video)) fail(`找不到影片:${video}`, 2);
  const t = Number(sec); const d = probeDuration(video);
  if (!/^\d+(\.\d+)?$/.test(sec) || !(t <= d)) fail(`秒數要是 0 ~ ${d} 的數字:${sec}`, 2);
  mkdirSync(dirname(out), { recursive: true });
  run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-ss', String(Math.min(t, Math.max(0, d - 0.05))), '-i', video, '-frames:v', '1', '-update', '1', out], '擷格');
  if (!existsSync(out)) fail('擷不到畫面(秒數太接近片尾?)');
  const [width, height] = probeSize(out) ?? [null, null];
  console.log(JSON.stringify({ file: out, width, height, t }));
});
