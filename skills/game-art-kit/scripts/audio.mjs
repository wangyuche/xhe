#!/usr/bin/env node
// game-art-kit:遊戲音效 / 配樂後處理與檢查(需要 ffmpeg、ffprobe,含 libopus 與 AAC 編碼器)。
// 用法:
//   node audio.mjs tools                                                 → 檢查 ffmpeg / ffprobe / libopus / aac
//   node audio.mjs process <輸入音訊> --type sfx|bgm --duration <秒> --out <目錄> --name <檔名> [--loop]
//        sfx:去頭尾靜音(−50 dB)→ 裁到 ≤ duration(結尾 20 ms 淡出)→ 響度 −16 LUFS、true peak ≤ −1.5 dBTP(留編碼餘量)
//        bgm:裁到 duration(--loop:輸入至少要 duration + 0.5 秒,頭尾 0.5 秒交叉淡化成可循環)→ −18 LUFS、≤ −1.5 dBTP
//        輸出 <name>.ogg(Opus)與 <name>.m4a(AAC),印 {"files":[…],"durationSec":…,"lufs":…,"truePeak":…,"loop":true|false|"approx"}
//   node audio.mjs check <name.ogg> <name.m4a> --type sfx|bgm --duration <秒> [--loop]
//        兩檔都在、長度(sfx ≤ duration + 0.05;bgm 與 duration 差 ≤ 0.5)、非靜音(RMS > −50 dBFS)、
//        無削波(true peak ≤ −1 dBTP)、響度(sfx −20 至 −12、bgm −20 至 −16 LUFS)、--loop 接縫(頭尾 50 ms RMS 差 ≤ 6 dB)。
//        印 {"ok":…,"errors":[…],"measure":{…}};不通過結束碼 1。
// 結束碼:0 成功;1 檢查不通過;2 用法 / 工具 / 檔案錯誤。
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, rmSync, renameSync, copyFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

class Fail extends Error { constructor(m, c) { super(m); this.code = c; } }
const die = (m, c = 2) => { throw new Fail(m, c); };
const TARGET = { sfx: { lufs: -16, range: [-20, -12] }, bgm: { lufs: -18, range: [-20, -16] } };
const TP_OUT = -1.5, TP_MAX = -1, XFADE = 0.5;

function sh(cmd, args, { allowFail = false } = {}) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 64 * 2 ** 20 });
  if (r.error) die(`找不到 ${cmd}(${r.error.code});brew install ffmpeg`);
  if (r.status !== 0 && !allowFail) die(`${cmd} 失敗:${(r.stderr || '').split('\n').slice(-5).join(' ')}`);
  return r;
}
const ff = (args) => sh('ffmpeg', ['-hide_banner', '-nostdin', '-y', '-v', 'error', ...args]);

export function tools() {
  const errs = [];
  for (const t of ['ffmpeg', 'ffprobe']) { const r = spawnSync(t, ['-version'], { encoding: 'utf8' }); if (r.error || r.status !== 0) errs.push(`缺 ${t}`); }
  if (!errs.length) {
    const enc = spawnSync('ffmpeg', ['-hide_banner', '-encoders'], { encoding: 'utf8' }).stdout;
    if (!/\blibopus\b/.test(enc)) errs.push('ffmpeg 沒有 libopus 編碼器');
    if (!/^\s*A\S*\s+aac\s/m.test(enc)) errs.push('ffmpeg 沒有 aac 編碼器');
  }
  return errs;
}

const duration = (f) => Number(sh('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', f]).stdout.trim());

// ebur128 量整體響度與 true peak;astats 量 RMS
export function measure(f, filter = '') {
  const r = sh('ffmpeg', ['-hide_banner', '-nostdin', '-nostats', '-i', f, '-af', `${filter ? filter + ',' : ''}ebur128=peak=true,astats=measure_perchannel=none:measure_overall=RMS_level+Peak_level`, '-f', 'null', '-'], { allowFail: true });
  const t = r.stderr;
  const sum = t.slice(t.lastIndexOf('Summary:'));
  const num = (re, s = sum) => { const m = re.exec(s); return m ? Number(m[1]) : null; };
  return {
    lufs: num(/I:\s+(-?[\d.]+|-inf) LUFS/),
    truePeak: num(/True peak:\s*\n\s*Peak:\s+(-?[\d.]+|-inf) dBFS/),
    rms: num(/RMS level dB:\s+(-?[\d.]+|-inf)/, t.slice(t.lastIndexOf('Overall'))),
  };
}

function process_(input, { type, dur, out, name, loop }) {
  if (!existsSync(input)) die(`找不到 ${input}`);
  const tmp = mkdtempSync(join(tmpdir(), 'gak-audio-'));
  try {
    const stage1 = join(tmp, 'a.wav');
    const inDur = duration(input);
    let loopState = false;
    if (type === 'sfx') {
      const trim = 'silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.01,areverse,silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.02,areverse';
      ff(['-i', input, '-af', `${trim},atrim=0:${dur},asetpts=PTS-STARTPTS,aformat=sample_rates=48000:channel_layouts=stereo`, stage1]);
      const d = duration(stage1);
      if (!(d > 0.02)) die('去掉靜音後沒有聲音(輸入是靜音?)', 1);
      const faded = join(tmp, 'b.wav');
      ff(['-i', stage1, '-af', `afade=t=out:st=${Math.max(0, d - 0.02).toFixed(3)}:d=0.02`, faded]);
      renameSync(faded, stage1);
    } else if (loop) {
      if (inDur < dur + XFADE - 0.01) die(`--loop 需要輸入至少 ${dur + XFADE} 秒(目前 ${inDur.toFixed(2)});生成時 seconds 設 duration + 1`);
      const fc = `[0]atrim=0:${dur},asetpts=PTS-STARTPTS,afade=t=in:d=${XFADE}:curve=qsin[a];` +
        `[0]atrim=${dur}:${dur + XFADE},asetpts=PTS-STARTPTS,afade=t=out:d=${XFADE}:curve=qsin[t];` +
        `[a][t]amix=inputs=2:duration=first:normalize=0,aformat=sample_rates=48000:channel_layouts=stereo`;
      ff(['-i', input, '-filter_complex', fc, stage1]);
      loopState = true;
    } else {
      if (inDur < dur - 0.5) die(`輸入只有 ${inDur.toFixed(2)} 秒,短於 duration ${dur}`);
      ff(['-i', input, '-af', `atrim=0:${dur},asetpts=PTS-STARTPTS,afade=t=out:st=${Math.max(0, dur - 1)}:d=1,aformat=sample_rates=48000:channel_layouts=stereo`, stage1]);
    }
    // 響度:先量,算增益;增益後 true peak 超過 −1.5 就降增益(響度可能因此低於目標,check 會判斷範圍)
    const m0 = measure(stage1);
    if (m0.lufs == null || m0.lufs < -69) die('量不到響度(太短或靜音)', 1);
    let gain = TARGET[type].lufs - m0.lufs;
    if (m0.truePeak != null && m0.truePeak + gain > TP_OUT) gain = TP_OUT - m0.truePeak;
    const norm = join(tmp, 'n.wav');
    ff(['-i', stage1, '-af', `volume=${gain.toFixed(2)}dB`, norm]);
    mkdirSync(out, { recursive: true });
    const ogg = join(tmp, `${name}.ogg`), m4a = join(tmp, `${name}.m4a`);
    ff(['-i', norm, '-c:a', 'libopus', '-b:a', type === 'bgm' ? '128k' : '96k', ogg]);
    ff(['-i', norm, '-c:a', 'aac', '-b:a', type === 'bgm' ? '160k' : '128k', '-movflags', '+faststart', m4a]);
    if (loopState) { const s = seam(norm); if (s > 6) loopState = 'approx'; }
    const files = [];
    for (const f of [ogg, m4a]) { const dst = join(out, f.split('/').pop()); try { renameSync(f, dst); } catch { copyFileSync(f, dst); } files.push(dst); }
    const m = measure(files[0]);
    return { files, durationSec: +duration(files[0]).toFixed(3), lufs: m.lufs, truePeak: m.truePeak, gainDb: +gain.toFixed(2), loop: type === 'bgm' ? loopState : undefined };
  } finally { rmSync(tmp, { recursive: true, force: true }); }
}

// 接縫:最後 50 ms 與最前 50 ms 的 RMS 差(dB)
export function seam(f) {
  const d = duration(f);
  const head = measure(f, 'atrim=0:0.05').rms, tail = measure(f, `atrim=${Math.max(0, d - 0.05)}`).rms;
  if (head == null || tail == null || !isFinite(head) || !isFinite(tail)) return Infinity;
  return Math.abs(head - tail);
}

export function check([ogg, m4a], { type, dur, loop }) {
  const errs = [], measureOut = {};
  for (const f of [ogg, m4a]) if (!f || !existsSync(f)) errs.push(`找不到 ${f}`);
  if (!/\.ogg$/.test(ogg ?? '') || !/\.m4a$/.test(m4a ?? '')) errs.push('要給 .ogg 與 .m4a 各一');
  if (errs.length) return { errs, measure: measureOut };
  for (const f of [ogg, m4a]) {
    const d = duration(f), m = measure(f), k = f.endsWith('.ogg') ? 'ogg' : 'm4a';
    measureOut[k] = { durationSec: +d.toFixed(3), ...m };
    if (type === 'sfx' ? d > dur + 0.05 : Math.abs(d - dur) > 0.5) errs.push(`${k} 長度 ${d.toFixed(2)} 秒(${type === 'sfx' ? `應 ≤ ${dur}` : `應約 ${dur}`})`);
    if (m.rms == null || !(m.rms > -50)) errs.push(`${k} RMS ${m.rms} dBFS(應 > −50;疑似靜音)`);
    if (m.truePeak == null || m.truePeak > TP_MAX) errs.push(`${k} true peak ${m.truePeak} dBTP(應 ≤ ${TP_MAX})`);
    const [lo, hi] = TARGET[type].range;
    if (m.lufs == null || m.lufs < lo || m.lufs > hi) errs.push(`${k} 響度 ${m.lufs} LUFS(應 ${lo} 至 ${hi})`);
  }
  if (loop) {
    const s = seam(ogg); measureOut.seamDb = isFinite(s) ? +s.toFixed(2) : null;
    if (!(s <= 6)) errs.push(`循環接縫 RMS 差 ${measureOut.seamDb} dB(應 ≤ 6;assets.json 改標 loop: "approx")`);
  }
  return { errs, measure: measureOut };
}

const isMain = process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href;
if (isMain) {
  try {
    const [cmd, ...rest] = process.argv.slice(2);
    const flags = {}, pos = [];
    for (let i = 0; i < rest.length; i++) { const a = rest[i]; if (a === '--loop') flags.loop = true; else if (a.startsWith('--')) flags[a.slice(2)] = rest[++i] ?? die(`${a} 缺值`); else pos.push(a); }
    const opts = () => {
      const type = flags.type; if (!['sfx', 'bgm'].includes(type)) die('--type 要 sfx 或 bgm');
      const dur = Number(flags.duration); if (!(dur > 0 && dur <= 600)) die('--duration 要是 0–600 的秒數');
      if (flags.loop && type !== 'bgm') die('--loop 只用於 bgm');
      return { type, dur, loop: !!flags.loop };
    };
    if (cmd === 'tools') { const e = tools(); console.log(JSON.stringify({ ok: !e.length, errors: e })); process.exit(e.length ? 2 : 0); }
    const te = tools(); if (te.length) die(te.join(';'));
    if (cmd === 'process') {
      const o = opts(); const name = flags.name ?? die('缺 --name'); if (!/^[a-z0-9][a-z0-9.-]*$/.test(name)) die('--name 只能用小寫英數、. -');
      console.log(JSON.stringify(process_(pos[0] ?? die('用法:process <輸入> …'), { ...o, out: flags.out ?? die('缺 --out'), name })));
    } else if (cmd === 'check') {
      const { errs, measure: m } = check(pos, opts());
      console.log(JSON.stringify({ ok: !errs.length, errors: errs, measure: m }));
      process.exit(errs.length ? 1 : 0);
    } else die('用法:audio.mjs tools | process | check(見檔頭)');
  } catch (e) {
    console.error(`錯誤:${e instanceof Fail ? e.message : e?.stack || e}`);
    process.exit(e instanceof Fail ? e.code : 2);
  }
}
