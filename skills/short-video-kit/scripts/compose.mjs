#!/usr/bin/env node
// 用法:node compose.mjs <timeline.json> [--dry-run]
// 依 timeline 合成一支 1080×1920 / 30 fps / H.264 + AAC 48 kHz / faststart 的短片,並產生字幕。
// 路徑都相對於 timeline.json 所在目錄。輸出:
//   <out>/final.mp4、<out>/subtitles.srt(out 預設為 timeline.json 所在目錄)
//   <work>/subtitles/*.png + boxes.json(呼叫 render.mjs)、<work>/first-frame.png、<work>/mix.wav
//
// 共同欄位:mode("narration" | "original")、work(必填)、out、fit("blur" 預設 | "crop")、
//          theme(傳給 render.mjs)、music({"path":…,"volume":0.25})
// narration:narration = tts.sh 的輸出陣列 [{text,file,duration}]
//            scenes = [{"image":"cards/001.png","sentences":[0,1]} | {"video":"rec.mp4","in":0,"region":[x,y,w,h],"sentences":[2]}]
//            影片鏡頭:region(選填,來源像素)先裁出要放大的區域。區域比 9:16 寬時一律「置頂」:
//            放大到寬 1080、放在字幕區上方(下緣 ≤ 1280),不受 fit 影響,所以不會被左右裁掉;
//            放大後高 > 1240 → 結束碼 6(縮小 region 的高,或拆成兩個鏡頭)。不比 9:16 寬的照 fit 處理。
//            AI 素材(2026-11-24):圖片鏡頭 fill:true = 等比蓋滿再置中裁切(預設是等比縮小 + 黑邊,給 1080×1920 卡片用);
//            motion:"in"|"out"|"left"|"right" = 緩慢推近 / 拉遠 / 往左 / 往右平移(自動 fill)。影片鏡頭 fit:"blur"|"crop" 覆寫整支的 fit。
//            任一鏡頭 sfx:{"path":…,"volume":0.8} = 鏡頭開始時播放的音效(不被背景音樂壓低,也不壓低背景音樂)。
//            摘要的影片鏡頭附 hold = 來源不夠長、停在最後一格的秒數。
//            字幕時間(固定規則):第 1 句 start=0.3;第 i 句 start=第 i−1 句 end+0.25;end=start+duration。
//            片長 = 最後一句 end + 0.6。鏡頭從它第一句的 start 開始(第一個鏡頭從 0),到下一個鏡頭開始為止。
// original:source = 來源影片;keep = [[s,e],…](精華)或 cut = [[s,e],…](精簡;每個剪掉區間前後各留 0.1 秒)
//            segments = [{start,end,text} | {start,end,texts:[…]}](來源時間;texts 依字數比例切分 start–end)
//            每段可加 text2 / texts2(譯文行);headline = 片頭 3 秒的標題疊字(選填)
// 另外寫 <work>/scenes.json(每個鏡頭的成品起訖,給 verify.sh --scenes 逐鏡頭擷圖)。
// stdout 一行 JSON 摘要;結束碼:0 成功、1 錯誤、2 timeline 格式錯、4 字幕放不下(要拆句)、5 片長超過 60 秒、
//   6 置頂鏡頭放大後會壓到字幕區(要設 region 或拆鏡頭)。
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { checkTheme } from './_theme.mjs';

const KIT = dirname(fileURLToPath(import.meta.url));
const MAX = 60, FPS = 30;
const r3 = (x) => Math.round(x * 1000) / 1000;

function fail(msg, code = 1) { console.error(`錯誤:${msg}`); process.exit(code); }
const args = process.argv.slice(2);
if (args.length < 1) fail('用法:node compose.mjs <timeline.json> [--dry-run]', 2);
const dry = args.includes('--dry-run');
const tlPath = resolve(args[0]);
let tl;
try { tl = JSON.parse(readFileSync(tlPath, 'utf8')); } catch (e) { fail(`讀不到 timeline:${e.message}`, 2); }
const base = dirname(tlPath);
const P = (p) => resolve(base, p);
if (!tl.work) fail('timeline 缺 work', 2);
const work = P(tl.work); const outDir = P(tl.out ?? '.');
const fit = tl.fit ?? 'blur';
if (!['blur', 'crop'].includes(fit)) fail('fit 只能是 blur 或 crop', 2);
const music = tl.music ? { path: P(tl.music.path), volume: Number(tl.music.volume ?? 0.25) } : null;
if (music && !existsSync(music.path)) fail(`找不到背景音樂:${music.path}`, 2);

function run(cmd, argv, label) {
  const r = spawnSync(cmd, argv, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0) { console.error((r.stderr || '').split('\n').slice(-25).join('\n')); fail(`${label} 失敗(結束碼 ${r.status})`); }
  return r;
}
const probeDur = (f) => Number(run('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', f], 'ffprobe').stdout.trim());
const hasAudio = (f) => run('ffprobe', ['-v', 'error', '-select_streams', 'a', '-show_entries', 'stream=index', '-of', 'csv=p=0', f], 'ffprobe').stdout.trim() !== '';

// 依來源比例縮放到 1080×1920:blur = 模糊背景置中,crop = 中央裁切
function fitChain(inLabel, outLabel, tag, f = fit) {
  if (f === 'crop') return `${inLabel}scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1${outLabel}`;
  return `${inLabel}split[${tag}a][${tag}b];[${tag}a]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,gblur=sigma=40,eq=brightness=-0.08[${tag}bg];` +
    `[${tag}b]scale=1080:1920:force_original_aspect_ratio=decrease[${tag}fg];[${tag}bg][${tag}fg]overlay=(W-w)/2:(H-h)/2,setsar=1${outLabel}`;
}
// 置頂:裁出 region、放大到寬 1080、放在字幕區(y ≥ 1300)上方,底色用 theme.bg
const TOP_MAX_H = 1240, TOP_BOTTOM = 1280;
const topBg = tl.theme?.bg; // 置頂鏡頭的底色;沒有預設,用到置頂時檢查
// 原聲模式的 headline 用完整 theme;在 dry-run 前就檢查(render.mjs 也會擋,但那時已開始產生中間檔)
let headlineContrast = null;
if (tl.mode === 'original' && tl.headline) {
  const t = checkTheme(tl.theme, [{ type: 'headline' }]);
  if (t.error) fail(`有 headline 時:${t.error}`, 2);
  headlineContrast = t.contrast;
}
const probeSize = (f) => run('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'csv=s=x:p=0', f], 'ffprobe').stdout.trim().split('x').map(Number);
function topLayout(j, [x, y, w, h]) {
  if (!/^#[0-9a-fA-F]{6}$/.test(String(topBg ?? ''))) fail(`scenes[${j}] 是置頂鏡頭,需要 theme.bg(#RRGGBB)當底色;沒有預設配色,依這支影片的來源選`, 2);
  const H = Math.round(h * 1080 / w / 2) * 2;
  if (H > TOP_MAX_H) fail(`scenes[${j}] 置頂放大後高 ${H} px > ${TOP_MAX_H},會壓到字幕區:把 region 的高縮到 ≤ ${Math.floor(w * TOP_MAX_H / 1080)},或拆成兩個鏡頭`, 6);
  const top = Math.max(40, Math.floor((TOP_BOTTOM - H) / 4) * 2);
  return { H, top, chain: (inLabel, outLabel, tag) => `${inLabel}crop=${w}:${h}:${x}:${y},scale=1080:${H}:flags=lanczos,setsar=1[${tag}fg];` +
    `color=c=${topBg}:s=1080x1920:r=${FPS}[${tag}bg];[${tag}bg][${tag}fg]overlay=0:${top}:shortest=1,setsar=1${outLabel}` };
}
const imageChain =(inLabel, outLabel) => `${inLabel}scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1${outLabel}`;
const fillChain = (inLabel, outLabel) => `${inLabel}scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1${outLabel}`;
// 緩慢運鏡:先放大到 2 倍再 zoompan(減少抖動),縮放幅度 12%
const MOTIONS = ['in', 'out', 'left', 'right'];
function motionChain(inLabel, outLabel, motion, frames) {
  const N = Math.max(1, frames - 1), Z = 0.12;
  const z = motion === 'in' ? `1+${Z}*on/${N}` : motion === 'out' ? `${1 + Z}-${Z}*on/${N}` : `${1 + Z}`;
  const cx = 'iw/2-(iw/zoom/2)', cy = 'ih/2-(ih/zoom/2)';
  const x = motion === 'left' ? `(iw-iw/zoom)*(1-on/${N})` : motion === 'right' ? `(iw-iw/zoom)*on/${N}` : cx;
  return `${inLabel}scale=2160:3840:force_original_aspect_ratio=increase,crop=2160:3840,` +
    `zoompan=z='${z}':x='${x}':y='${cy}':d=${frames}:s=1080x1920:fps=${FPS},setsar=1${outLabel}`;
}
const sfxList = []; // {path, volume, at}
function takeSfx(s, j, at) {
  if (s.sfx === undefined) return;
  const p = s.sfx?.path; const v = Number(s.sfx?.volume ?? 0.8);
  if (typeof p !== 'string' || !(v >= 0 && v <= 2)) fail(`scenes[${j}].sfx 要是 {"path":…,"volume":0~2}`, 2);
  if (!existsSync(P(p))) fail(`找不到音效:${p}`, 2);
  if (v === 0) return; // 0 = 靜音,保留欄位但不混
  sfxList.push({ path: P(p), volume: v, at });
}

const subs = []; // {start,end,text,text2}
let total = 0;
const summary = { mode: tl.mode, ...(headlineContrast ? { contrast: headlineContrast } : {}) };
const inputs = []; // ffmpeg 輸入參數(final 用)
const vfilters = [];
let firstFrameArgs;

if (tl.mode === 'narration') {
  const nar = tl.narration;
  if (!Array.isArray(nar) || !nar.length) fail('narration 必須是 tts.sh 的輸出陣列', 2);
  let t = 0.3;
  nar.forEach((n, i) => {
    const d = Number(n.duration);
    if (!(d > 0) || !n.file || typeof n.text !== 'string') fail(`narration[${i}] 需要 text、file、duration`, 2);
    if (!existsSync(P(n.file))) fail(`找不到旁白音檔:${n.file}`, 2);
    const start = i === 0 ? 0.3 : t + 0.25; const end = start + d;
    subs.push({ start: r3(start), end: r3(end), text: n.text.trim(), text2: n.text2 }); t = end;
  });
  total = r3(t + 0.6);
  const scenes = tl.scenes;
  if (!Array.isArray(scenes) || !scenes.length) fail('scenes 必須是非空陣列', 2);
  const flat = scenes.flatMap(s => s.sentences ?? []);
  if (flat.length !== nar.length || flat.some((v, i) => v !== i)) fail(`scenes 的 sentences 必須依序涵蓋 0..${nar.length - 1} 各一次(目前 ${JSON.stringify(flat)})`, 2);
  summary.scenes = [];
  scenes.forEach((s, j) => {
    if (!s.sentences?.length) fail(`scenes[${j}] 沒有 sentences`, 2);
    const st = j === 0 ? 0 : subs[s.sentences[0]].start;
    const en = j + 1 < scenes.length ? subs[scenes[j + 1].sentences[0]].start : total;
    const D = r3(en - st);
    const idx = inputs.length;
    takeSfx(s, j, st);
    if (s.image && s.fit !== undefined) fail(`scenes[${j}] 是圖片鏡頭,fit 只給影片鏡頭;AI 圖要蓋滿用 fill 或 motion`, 2);
    if (s.video && (s.motion !== undefined || s.fill !== undefined)) fail(`scenes[${j}] 是影片鏡頭,motion / fill 只給圖片鏡頭`, 2);
    if (s.image) {
      const f = P(s.image); if (!existsSync(f)) fail(`找不到圖片:${s.image}`, 2);
      if (s.motion !== undefined && !MOTIONS.includes(s.motion)) fail(`scenes[${j}].motion 只能是 ${MOTIONS.join(' / ')}`, 2);
      if (s.fill !== undefined && typeof s.fill !== 'boolean') fail(`scenes[${j}].fill 要是 true / false`, 2);
      if (s.motion) {
        const frames = Math.ceil(D * FPS) + 1;
        inputs.push(['-i', f]);
        vfilters.push(motionChain(`[${idx}:v]`, `[s${j}f]`, s.motion, frames) + `;[s${j}f]trim=duration=${D},setpts=PTS-STARTPTS,format=yuv420p[v${j}]`);
        if (j === 0) firstFrameArgs = ['-i', f, '-filter_complex', motionChain('[0:v]', '[o]', s.motion, frames), '-map', '[o]'];
      } else {
        const chain = s.fill ? fillChain : imageChain;
        inputs.push(['-loop', '1', '-framerate', String(FPS), '-t', String(D), '-i', f]);
        vfilters.push(chain(`[${idx}:v]`, `[s${j}f]`) + `;[s${j}f]fps=${FPS},trim=duration=${D},setpts=PTS-STARTPTS,format=yuv420p[v${j}]`);
        if (j === 0) firstFrameArgs = ['-loop', '1', '-i', f, '-filter_complex', chain('[0:v]', '[o]'), '-map', '[o]'];
      }
      summary.scenes.push({ start: r3(st), end: r3(en), image: s.image, ...(s.motion ? { motion: s.motion } : s.fill ? { fill: true } : {}) });
      return;
    } else if (s.video) {
      const f = P(s.video); if (!existsSync(f)) fail(`找不到影片:${s.video}`, 2);
      const inT = Number(s.in ?? 0);
      const sfit = s.fit ?? fit;
      if (!['blur', 'crop'].includes(sfit)) fail(`scenes[${j}].fit 只能是 blur 或 crop`, 2);
      const hold = r3(Math.max(0, D - Math.max(0, probeDur(f) - inT)));
      const [sw, sh] = probeSize(f);
      const region = s.region ?? [0, 0, sw, sh];
      if (!Array.isArray(region) || region.length !== 4 || region.some(v => !Number.isInteger(v) || v < 0) || !(region[2] > 0 && region[3] > 0)
        || region[0] + region[2] > sw || region[1] + region[3] > sh) fail(`scenes[${j}] region 必須是來源 ${sw}x${sh} 內的整數 [x,y,w,h]:${JSON.stringify(s.region)}`, 2);
      const wide = region[2] / region[3] > 9 / 16 + 0.01;
      let chain, info;
      if (wide) { const t = topLayout(j, region); chain = t.chain; info = { layout: 'top', region, uiBottom: t.top + t.H }; }
      else if (s.region) { const [x, y, w, h] = region; chain = (i, o, tag) => `${i}crop=${w}:${h}:${x}:${y}[${tag}c];` + fitChain(`[${tag}c]`, o, tag, sfit); info = { layout: sfit, region }; }
      else { chain = (i, o, tag) => fitChain(i, o, tag, sfit); info = { layout: sfit }; }
      info.hold = hold;
      inputs.push(['-ss', String(inT), '-i', f]);
      vfilters.push(chain(`[${idx}:v]`, `[s${j}f]`, `s${j}`) + `;[s${j}f]fps=${FPS},tpad=stop_mode=clone:stop_duration=${D},trim=duration=${D},setpts=PTS-STARTPTS,format=yuv420p[v${j}]`);
      if (j === 0) firstFrameArgs = ['-ss', String(inT), '-i', f, '-filter_complex', chain('[0:v]', '[o]', 'ff'), '-map', '[o]'];
      summary.scenes.push({ start: r3(st), end: r3(en), video: s.video, ...info });
      return;
    } else fail(`scenes[${j}] 需要 image 或 video`, 2);
  });
  vfilters.push(`${scenes.map((_, j) => `[v${j}]`).join('')}concat=n=${scenes.length}:v=1:a=0[base]`);
} else if (tl.mode === 'original') {
  const src = tl.source ? P(tl.source) : fail('original 需要 source', 2);
  if (!existsSync(src)) fail(`找不到來源影片:${tl.source}`, 2);
  const srcDur = probeDur(src);
  const norm = (arr, name) => {
    if (!Array.isArray(arr)) fail(`${name} 必須是 [[s,e],…] 或 [{start,end},…]`, 2);
    const out = arr.map((x, i) => {
      // 接受 [s,e] 或 silence.sh 輸出的 {start,end}
      const [s, e] = Array.isArray(x) ? x.map(Number) : [Number(x?.start), Number(x?.end)];
      if (!(s >= 0) || !(e > s)) fail(`${name}[${i}] 區間不合法:${JSON.stringify(x)}`, 2);
      return [s, Math.min(e, srcDur)];
    }).sort((a, b) => a[0] - b[0]);
    for (let i = 1; i < out.length; i++) if (out[i][0] < out[i - 1][1]) fail(`${name} 區間重疊:${JSON.stringify(out[i - 1])} ${JSON.stringify(out[i])}`, 2);
    return out;
  };
  let keep;
  if (tl.keep && tl.cut) fail('keep 與 cut 只能擇一', 2);
  if (tl.keep) keep = norm(tl.keep, 'keep');
  else if (tl.cut) {
    const cuts = norm(tl.cut, 'cut').map(([s, e]) => [s + 0.1, e - 0.1]).filter(([s, e]) => e - s >= 0.1);
    keep = []; let p = 0;
    for (const [s, e] of cuts) { if (s - p > 0.05) keep.push([p, s]); p = e; }
    if (srcDur - p > 0.05) keep.push([p, srcDur]);
    summary.cuts = cuts.map(([s, e]) => [r3(s), r3(e)]);
    summary.totalCut = r3(cuts.reduce((n, [s, e]) => n + (e - s), 0));
  } else keep = [[0, srcDur]];
  keep = keep.map(([s, e]) => [r3(s), r3(e)]);
  summary.keep = keep; summary.sourceDuration = r3(srcDur);
  total = r3(keep.reduce((n, [s, e]) => n + (e - s), 0));
  // 來源時間 → 成品時間
  const offs = []; let acc = 0; for (const [s, e] of keep) { offs.push(acc); acc += e - s; }
  summary.scenes = keep.map(([s, e], k) => ({ start: r3(offs[k]), end: r3(offs[k] + e - s), source: [s, e], layout: fit }));
  const mapPiece = (s, e, text, text2) => {
    keep.forEach(([ks, ke], k) => {
      const a = Math.max(s, ks), b = Math.min(e, ke);
      if (b - a >= 0.2) subs.push({ start: r3(offs[k] + a - ks), end: r3(offs[k] + b - ks), text, text2 });
    });
  };
  (tl.segments ?? []).forEach((g, i) => {
    const s = Number(g.start), e = Number(g.end);
    if (!(e > s)) fail(`segments[${i}] start/end 不合法`, 2);
    const texts = g.texts ?? [g.text];
    if (!texts.length || texts.some(x => typeof x !== 'string' || !x.trim())) fail(`segments[${i}] 需要 text 或 texts`, 2);
    const texts2 = g.texts2 ?? (g.text2 !== undefined ? (texts.length === 1 ? [g.text2] : fail(`segments[${i}] 拆句時譯文要用 texts2`, 2)) : []);
    const chars = texts.map(x => [...x.trim()].length); const sum = chars.reduce((a, b) => a + b, 0);
    let t = s;
    texts.forEach((x, k) => {
      const len = (e - s) * chars[k] / sum; const pe = k === texts.length - 1 ? e : t + len;
      mapPiece(t, pe, x.trim(), texts2[k]); t = pe;
    });
  });
  subs.sort((a, b) => a.start - b.start);
  const expr = keep.map(([s, e]) => `between(t,${s},${e})`).join('+');
  inputs.push(['-i', src]);
  vfilters.push(`[0:v]fps=${FPS},select='${expr}',setpts=N/${FPS}/TB[sel]`);
  vfilters.push(fitChain('[sel]', '[base0]', 'o') + `;[base0]format=yuv420p,trim=duration=${total}[base]`);
  firstFrameArgs = ['-ss', String(keep[0][0]), '-i', src, '-filter_complex', fitChain('[0:v]', '[o]', 'ff'), '-map', '[o]'];
  summary.audioSource = hasAudio(src);
  tl._src = src;
} else fail('mode 只能是 narration 或 original', 2);

if (sfxList.length) summary.sfx = sfxList.map(x => ({ at: r3(x.at), volume: x.volume }));
summary.duration = total;
if (total > MAX) { console.log(JSON.stringify(summary)); fail(`片長 ${total} 秒超過 ${MAX} 秒`, 5); }

// SRT
const ts = (x) => { const ms = Math.round(x * 1000); const h = Math.floor(ms / 3600000), m = Math.floor(ms / 60000) % 60, s = Math.floor(ms / 1000) % 60;
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')},${String(ms % 1000).padStart(3, '0')}`; };
const srt = subs.map((x, i) => `${i + 1}\n${ts(x.start)} --> ${ts(x.end)}\n${x.text}${x.text2 ? `\n${x.text2}` : ''}\n`).join('\n');
summary.subtitles = subs.length;

if (dry) { console.log(JSON.stringify({ ...summary, srt: subs })); process.exit(0); }

mkdirSync(outDir, { recursive: true });
const subDir = join(work, 'subtitles'); mkdirSync(subDir, { recursive: true });
writeFileSync(join(work, 'scenes.json'), JSON.stringify(summary.scenes, null, 1));

// 1. 字幕與標題 PNG(render.mjs 檢查安全區)
const cards = subs.map((x, i) => ({ type: 'subtitle', file: `sub-${String(i + 1).padStart(3, '0')}.png`, text: x.text, ...(x.text2 ? { text2: x.text2 } : {}) }));
const headline = tl.mode === 'original' && tl.headline ? String(tl.headline) : null;
if (headline) cards.push({ type: 'headline', file: 'headline.png', text: headline });
if (cards.length) {
  writeFileSync(join(subDir, 'cards.json'), JSON.stringify({ theme: tl.theme ?? {}, cards }, null, 1));
  const r = spawnSync('node', [join(KIT, 'render.mjs'), join(subDir, 'cards.json'), subDir], { encoding: 'utf8' });
  if (r.status === 4) { process.stderr.write(r.stderr); fail('字幕放不下,請在 timeline 拆句後重跑', 4); }
  if (r.status !== 0) { process.stderr.write(r.stderr); fail('render.mjs 失敗', r.status === 2 ? 2 : 1); }
}
if (!subs.length) writeFileSync(join(subDir, 'boxes.json'), '[]');

// 2. 混音 → mix.wav(48 kHz 立體聲,長度 = 片長)
const mix = join(work, 'mix.wav');
{
  const ai = []; const af = []; let voice;
  if (tl.mode === 'narration') {
    tl.narration.forEach((n, i) => { ai.push('-i', P(n.file)); af.push(`[${i}:a]aresample=48000,aformat=channel_layouts=stereo,adelay=${Math.round(subs[i].start * 1000)}:all=1[n${i}]`); });
    af.push(`${tl.narration.map((_, i) => `[n${i}]`).join('')}amix=inputs=${tl.narration.length}:normalize=0:duration=longest,apad,atrim=0:${total}[voice]`);
  } else if (summary.audioSource) {
    const expr = summary.keep.map(([s, e]) => `between(t,${s},${e})`).join('+');
    ai.push('-i', tl._src);
    af.push(`[0:a]aresample=48000,aformat=channel_layouts=stereo,aselect='${expr}',asetpts=N/SR/TB,apad,atrim=0:${total}[voice]`);
  } else {
    af.push(`anullsrc=r=48000:cl=stereo,atrim=0:${total}[voice]`);
  }
  if (music) {
    const mi = ai.filter(x => x === '-i').length;
    ai.push('-stream_loop', '-1', '-i', music.path);
    af.push(`[${mi}:a]aresample=48000,aformat=channel_layouts=stereo,volume=${music.volume},atrim=0:${total},afade=t=out:st=${Math.max(0, total - 1.5)}:d=1.5[mus]`);
    af.push(`[voice]asplit[v1][v2];[mus][v2]sidechaincompress=threshold=0.02:ratio=10:attack=20:release=500[duck];[v1][duck]amix=inputs=2:normalize=0:duration=first[mix]`);
    voice = '[mix]';
  } else voice = '[voice]';
  if (sfxList.length) {
    sfxList.forEach((x, k) => {
      const si = ai.filter(y => y === '-i').length;
      ai.push('-i', x.path);
      af.push(`[${si}:a]aresample=48000,aformat=channel_layouts=stereo,volume=${x.volume},adelay=${Math.round(x.at * 1000)}:all=1[fx${k}]`);
    });
    af.push(`${voice}${sfxList.map((_, k) => `[fx${k}]`).join('')}amix=inputs=${sfxList.length + 1}:normalize=0:duration=first[withfx]`);
    voice = '[withfx]';
  }
  run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...ai, '-filter_complex', af.join(';'), '-map', voice, '-ar', '48000', '-ac', '2', '-c:a', 'pcm_s16le', '-t', String(total), mix], '混音');
}

// 3. 響度量測(loudnorm 第一階段)
let ln = null;
{
  const r = run('ffmpeg', ['-hide_banner', '-nostats', '-i', mix, '-af', 'loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json', '-f', 'null', '-'], '響度量測');
  const m = r.stderr.match(/\{[\s\S]*?\}/g);
  const j = m ? JSON.parse(m[m.length - 1]) : null;
  if (j && Number.isFinite(Number(j.input_i)) && Number(j.input_i) > -70) ln = j;
  summary.loudnessIn = j ? Number(j.input_i) : null;
}

// 4. 最終合成
const finalOut = join(outDir, 'final.mp4');
{
  const fin = inputs.flat();
  let cur = '[base]'; let k = inputs.length;
  const ov = [];
  subs.forEach((x, i) => {
    fin.push('-loop', '1', '-framerate', String(FPS), '-t', String(total), '-i', join(subDir, `sub-${String(i + 1).padStart(3, '0')}.png`));
    ov.push(`${cur}[${k}:v]overlay=0:0:enable='between(t,${x.start},${x.end})'[ov${i}]`); cur = `[ov${i}]`; k++;
  });
  if (headline) {
    fin.push('-loop', '1', '-framerate', String(FPS), '-t', String(total), '-i', join(subDir, 'headline.png'));
    ov.push(`${cur}[${k}:v]overlay=0:0:enable='between(t,0,3)'[ovh]`); cur = '[ovh]'; k++;
  }
  fin.push('-i', mix); const mixIdx = k;
  const anorm = ln
    ? `[${mixIdx}:a]loudnorm=I=-14:TP=-1.5:LRA=11:measured_I=${ln.input_i}:measured_TP=${ln.input_tp}:measured_LRA=${ln.input_lra}:measured_thresh=${ln.input_thresh}:offset=${ln.target_offset}:linear=true,aresample=48000[aout]`
    : `[${mixIdx}:a]anull[aout]`;
  const graph = [...vfilters, ...ov, `${cur}scale=in_range=auto:out_range=tv,format=yuv420p[vout]`, anorm].join(';');
  run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...fin, '-filter_complex', graph, '-map', '[vout]', '-map', '[aout]',
    '-c:v', 'libx264', '-preset', 'medium', '-crf', '20', '-profile:v', 'high', '-pix_fmt', 'yuv420p', '-color_range', 'tv', '-r', String(FPS),
    '-c:a', 'aac', '-b:a', '192k', '-ar', '48000', '-ac', '2', '-movflags', '+faststart', '-t', String(total), finalOut], '最終合成');
}

// 5. 第一個鏡頭畫面(沒有字幕,封面用)
const ff = join(work, 'first-frame.png');
run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...firstFrameArgs, '-frames:v', '1', ff], '擷取第一個鏡頭');

writeFileSync(join(outDir, 'subtitles.srt'), srt);
console.log(JSON.stringify({ ...summary, final: finalOut, srt: join(outDir, 'subtitles.srt'), boxes: join(subDir, 'boxes.json'), scenesFile: join(work, 'scenes.json'), firstFrame: ff, actualDuration: r3(probeDur(finalOut)) }));
