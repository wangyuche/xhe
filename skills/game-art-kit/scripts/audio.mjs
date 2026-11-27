#!/usr/bin/env node
// game-art-kit:遊戲音效 / 配樂後處理與檢查(需要 ffmpeg、ffprobe,含 libopus 與 AAC 編碼器)。
// 用法:
//   node audio.mjs tools                                                 → 檢查 ffmpeg / ffprobe / libopus / aac
//   node audio.mjs process <輸入音訊> --type sfx|bgm|voice --duration <秒>(voice 可省略,預設 15)--out <目錄> --name <檔名> [--loop]
//        sfx:去頭尾靜音(−50 dB)→ 裁到 ≤ duration(結尾 20 ms 淡出)→ 響度 −16 LUFS、true peak ≤ −1.5 dBTP(留編碼餘量);
//        短於 0.4 秒(量不到整體響度)改以峰值正規化到 −3 dBTP,輸出 normalized: "peak"、lufs: null
//        bgm:裁到 duration(--loop:輸入至少要 duration + 0.5 秒,頭尾 0.5 秒交叉淡化成可循環)→ −18 LUFS、≤ −1.5 dBTP
//        輸出 <name>.ogg(Opus)與 <name>.m4a(AAC),印 {"files":[…],"durationSec":…,"lufs":…,"truePeak":…,"loop":true|false|"approx"}
//        voice(角色台詞):去頭尾靜音,不裁切;去靜音後長於 duration(預設 15 秒)→ 結束碼 1(請拆句);−16 LUFS、≤ −1.5 dBTP(短於 0.4 秒同 sfx 改峰值正規化)
//   node audio.mjs check <name.ogg> <name.m4a> --type sfx|bgm|voice --duration <秒>(voice 可省略,預設 15)[--loop [--approx]] [--peak]
//        --approx:process 輸出 loop: "approx" 的配樂,接縫只回報不判失敗
//        兩檔都在、長度(sfx ≤ duration + 0.05;bgm 與 duration 差 ≤ 0.5)、非靜音(RMS > −50 dBFS)、
//        無削波(true peak ≤ −1 dBTP)、響度(sfx / voice −20 至 −12、bgm −20 至 −16 LUFS;--peak(process 輸出 normalized: peak 的短音效)不檢查)、--loop 接縫(頭尾 50 ms RMS 差 ≤ 6 dB)。
//        印 {"ok":…,"errors":[…],"measure":{…}};不通過結束碼 1。
// 結束碼:0 成功;1 檢查不通過;2 用法 / 工具 / 檔案錯誤。
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, rmSync, renameSync, copyFileSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

class Fail extends Error { constructor(m, c) { super(m); this.code = c; } }
const die = (m, c = 2) => { throw new Fail(m, c); };
const TARGET = { sfx: { lufs: -16, range: [-20, -12] }, voice: { lufs: -16, range: [-20, -12] }, bgm: { lufs: -18, range: [-20, -16] } };
const TP_OUT = -1.5, TP_MAX = -1, XFADE = 0.5, SHORT = 0.4;

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
  if (r.status !== 0) die(`ffmpeg 讀不了 ${f}(檔案損壞或格式不支援):${(r.stderr || '').trim().split('\n').slice(-2).join(' ')}`);
  const t = r.stderr;
  const sum = t.slice(t.lastIndexOf('Summary:'));
  const num = (re, s = sum) => { const m = re.exec(s); return !m ? null : m[1] === '-inf' ? -Infinity : Number(m[1]); };
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
    if (type === 'sfx' || type === 'voice') {
      const trim = 'silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.01,areverse,silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.02,areverse';
      // 台詞不裁切(裁掉會斷句):去靜音後超過 duration 就失敗,請拆句
      ff(['-i', input, '-af', `${trim}${type === 'sfx' ? `,atrim=0:${dur}` : ''},asetpts=PTS-STARTPTS,aformat=sample_rates=48000:channel_layouts=stereo`, stage1]);
      const d = duration(stage1);
      if (!(d > 0.02)) die('去掉靜音後沒有聲音(輸入是靜音?)', 1);
      if (type === 'voice' && d > dur + 0.01) die(`台詞去靜音後 ${d.toFixed(2)} 秒,超過 ${dur} 秒(請拆句)`, 1);
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
      ff(['-i', input, '-af', `atrim=0:${dur},asetpts=PTS-STARTPTS,afade=t=out:st=${Math.max(0, Math.min(inDur, dur) - 1)}:d=1,aformat=sample_rates=48000:channel_layouts=stereo`, stage1]);
    }
    // 響度:先量,算增益;增益後 true peak 超過 −1.5 就降增益(響度可能因此低於目標,check 會判斷範圍)
    const m0 = measure(stage1);
    const short = duration(stage1) < SHORT;
    if (short && type === 'bgm') die('配樂短於 0.4 秒,不合理;請確認 duration', 2);
    if (!short && !(m0.lufs > -69)) die('量不到響度(靜音?)', 1);
    if (short && !(m0.truePeak > -60)) die('太短而且幾乎沒有聲音', 1);
    // 短於 0.4 秒量不到整體響度(ebur128 至少要一個 400 ms 區塊):改用峰值正規化到 −3 dBTP
    let gain = short ? -3 - m0.truePeak : TARGET[type].lufs - m0.lufs;
    // 長音訊:增益到目標響度後過限幅器(樣本峰值 −3 dBFS),衝擊感強(峰值因數大)的音效也能同時達到響度與峰值;
    // 仍超過 −1.5 dBTP(取樣間峰值)再補一次降增益
    const norm = join(tmp, 'n.wav');
    // 限幅會吃掉響度:量測後補增益再限幅,最多 4 次,直到響度在目標 ±0.5 LU 內
    let applied = gain; const firstGain = gain;
    for (let i = 0; i < 4; i++) {
      applied = gain;
      ff(['-i', stage1, '-af', short ? `volume=${gain.toFixed(2)}dB` : `volume=${gain.toFixed(2)}dB,alimiter=limit=0.708:attack=1:release=50:level=disabled:latency=1`, norm]);
      if (short) break;
      const mi = measure(norm);
      if (!(mi.lufs > -69) || Math.abs(mi.lufs - TARGET[type].lufs) <= 0.5) break;
      // 補償最多比第一次多 6 dB(避免把衝擊音效壓到失真);到上限就停,響度不足由 check 判斷
      const next = Math.min(gain + (TARGET[type].lufs - mi.lufs), firstGain + 6);
      if (next <= gain + 0.05) break;
      gain = next;
    }
    const m1 = measure(norm);
    if (m1.truePeak > TP_OUT) { const adj = TP_OUT - m1.truePeak - 0.1; const fix = join(tmp, 'f.wav'); ff(['-i', norm, '-af', `volume=${adj.toFixed(2)}dB`, fix]); renameSync(fix, norm); applied += adj; }
    mkdirSync(out, { recursive: true });
    const ogg = join(tmp, `${name}.ogg`), m4a = join(tmp, `${name}.m4a`);
    ff(['-i', norm, '-c:a', 'libopus', '-b:a', type === 'bgm' ? '128k' : '96k', ogg]);
    ff(['-i', norm, '-c:a', 'aac', '-b:a', type === 'bgm' ? '160k' : '128k', '-movflags', '+faststart', m4a]);
    if (loopState) { const s = Math.max(seam(norm), seam(ogg), seam(m4a)); if (s > 6) loopState = 'approx'; }
    // 編碼(Opus / AAC)可能讓取樣間峰值上升:量編碼後的檔案,超過 −1 dBTP 就降增益重編(最多 2 次)
    for (let i = 0; ; i++) {
      const over = Math.max(measure(ogg).truePeak ?? -99, measure(m4a).truePeak ?? -99) - (TP_MAX - 0.2);
      if (!(over > 0)) break;
      if (i === 2) die(`編碼後 true peak 仍超過 ${TP_MAX} dBTP(重編 2 次)`, 1);
      const fix = join(tmp, 'g.wav'); ff(['-i', norm, '-af', `volume=${(-over).toFixed(2)}dB`, fix]); renameSync(fix, norm); applied -= over;
      ff(['-i', norm, '-c:a', 'libopus', '-b:a', type === 'bgm' ? '128k' : '96k', ogg]);
      ff(['-i', norm, '-c:a', 'aac', '-b:a', type === 'bgm' ? '160k' : '128k', '-movflags', '+faststart', m4a]);
    }
    const files = [];
    for (const f of [ogg, m4a]) { const dst = join(out, f.split('/').pop()); try { renameSync(f, dst); } catch { copyFileSync(f, dst); } files.push(dst); }
    const m = measure(files[0]);
    return { files, durationSec: +duration(files[0]).toFixed(3), lufs: short || !isFinite(m.lufs) ? null : m.lufs, truePeak: m.truePeak, gainDb: +applied.toFixed(2), normalized: short ? 'peak' : 'lufs', loop: type === 'bgm' ? loopState : undefined };
  } finally { rmSync(tmp, { recursive: true, force: true }); }
}

// 接縫:最後 50 ms 與最前 50 ms 的 RMS 差(dB)
export function seam(f) {
  const d = duration(f);
  const head = measure(f, 'atrim=0:0.05').rms, tail = measure(f, `atrim=${Math.max(0, d - 0.05)}`).rms;
  if (head == null || tail == null || !isFinite(head) || !isFinite(tail)) return Infinity;
  return Math.abs(head - tail);
}

export function check([ogg, m4a], { type, dur, loop, peak, approx }) {
  const errs = [], measureOut = {};
  for (const f of [ogg, m4a]) if (!f || !existsSync(f)) errs.push(`找不到 ${f}`);
  if (!/\.ogg$/.test(ogg ?? '') || !/\.m4a$/.test(m4a ?? '')) errs.push('要給 .ogg 與 .m4a 各一');
  if (errs.length) return { errs, measure: measureOut };
  for (const f of [ogg, m4a]) {
    const d = duration(f), m = measure(f), k = f.endsWith('.ogg') ? 'ogg' : 'm4a';
    measureOut[k] = { durationSec: +d.toFixed(3), ...m };
    if (type !== 'bgm' ? d > dur + 0.05 : Math.abs(d - dur) > 0.5) errs.push(`${k} 長度 ${d.toFixed(2)} 秒(${type !== 'bgm' ? `應 ≤ ${dur}` : `應約 ${dur}`})`);
    if (m.rms == null || !(m.rms > -50)) errs.push(`${k} RMS ${m.rms} dBFS(應 > −50;疑似靜音)`);
    if (m.truePeak == null || m.truePeak > TP_MAX) errs.push(`${k} true peak ${m.truePeak} dBTP(應 ≤ ${TP_MAX})`);
    const [lo, hi] = TARGET[type].range;
    if (peak) measureOut[k].note = '峰值正規化的短音效:不檢查整體響度';
    else if (m.lufs == null || !(m.lufs >= lo && m.lufs <= hi)) errs.push(`${k} 響度 ${m.lufs} LUFS(應 ${lo} 至 ${hi})`);
  }
  if (loop) {
    // 兩種格式都量(m4a 靠 MP4 edit list 去掉 AAC 前置靜音;Safari 播 m4a)
    const so = seam(ogg), sm = seam(m4a), s = Math.max(so, sm);
    measureOut.seamDb = { ogg: isFinite(so) ? +so.toFixed(2) : null, m4a: isFinite(sm) ? +sm.toFixed(2) : null };
    if (!(s <= 6)) { if (approx) measureOut.loop = 'approx'; else errs.push(`循環接縫 RMS 差 ${s.toFixed(2)} dB(ogg / m4a 取大者,應 ≤ 6;process 已標 approx 的加 --approx)`); }
  }
  return { errs, measure: measureOut };
}

// skill 目錄常是連結:argv[1] 保留連結路徑、import.meta.url 是實際路徑,要比 realpath
const isMain = (() => { try { return !!process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } })();
if (isMain) {
  try {
    const [cmd, ...rest] = process.argv.slice(2);
    const flags = {}, pos = [];
    for (let i = 0; i < rest.length; i++) { const a = rest[i]; if (['--loop', '--peak', '--approx'].includes(a)) flags[a.slice(2)] = true; else if (a.startsWith('--')) flags[a.slice(2)] = rest[++i] ?? die(`${a} 缺值`); else pos.push(a); }
    const opts = () => {
      const type = flags.type; if (!['sfx', 'bgm', 'voice'].includes(type)) die('--type 要 sfx、bgm 或 voice');
      const dur = Number(flags.duration ?? (type === 'voice' ? 15 : NaN)); if (!(dur > 0 && dur <= 600)) die('--duration 要是 0–600 的秒數');
      if (flags.loop && type !== 'bgm') die('--loop 只用於 bgm');
      if (flags.peak && type === 'bgm') die('--peak 只用於 sfx / voice');
      if (flags.approx && !flags.loop) die('--approx 要和 --loop 一起用');
      return { type, dur, loop: !!flags.loop, peak: !!flags.peak, approx: !!flags.approx };
    };
    if (cmd === 'tools') { const e = tools(); console.log(JSON.stringify({ ok: !e.length, errors: e })); process.exit(e.length ? 2 : 0); }
    const te = tools(); if (te.length) die(te.join(';'));
    if (cmd === 'process') {
      const o = opts(); const name = flags.name ?? die('缺 --name'); if (!/^[a-z0-9][a-z0-9._-]*$/.test(name)) die('--name 只能用小寫英數、. _ -');
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
