#!/usr/bin/env node
// 用法:node tts.mjs <storyboard.json> <輸出目錄> [--engine qwen3|say] [--design "<聲音描述>"] [--design-seed 11] [--ref "<參考句>"]
//                   [--preset Vivian [--instruct "<語氣>"]] [--voice <名稱>] [--seed 7] [--only 3,5]
//                   [--lexicon <念法對照表.json>] [--no-lexicon]
// 逐句(storyboard 所有 lines 依序,第 i 句 = 1 起算)產生旁白:念 say(有寫)或 text 的顯示文字。
//   qwen3(預設):game-art-kit comfy.mjs run
//     - 預設 workflows/qwen3-tts-design.json:VoiceDesign 1.7B 依 --design 設計聲音(台灣口音)→ Base 1.7B 複製該聲音念句子。
//       同一支片 --design / --ref / --design-seed 固定,聲音才一致。
//     - --preset <聲音>(Vivian、Serena…):workflows/qwen3-tts.json(CustomVoice 1.7B,偏大陸口音),可加 --instruct。
//     兩者 runtime_mode 都固定 ⚠️ Shared Runtime。ComfyUI 位址由 comfy.mjs 自己讀本機設定,本腳本不碰。
//   say:macOS say(--voice,預設 Meijia)。
// 念法對照表:先套 kit 的 pronunciation.json,再套 --lexicon(專案的,同 key 覆蓋);--no-lexicon 都不套。
//   念的文字裡出現 key 就換成 value(例如「網站」→「網 站」),字幕不變;實際念的文字記在 tts.json 的 spoken。
// 每檔去頭尾靜音(各留 0.05 / 0.1 秒)、轉 48 kHz 單聲道 WAV <輸出目錄>/NNN.wav。
// 檢查:長度 > 0.5 秒且 max_volume > −30 dB;不合就換 seed(seed + 101 × 次數,超過 4294967295 回繞到 1 起)重生,最多 2 次。
// 寫 <輸出目錄>/tts.json 並印同內容:[{i,text,say,spoken,file,duration,maxVolume,seed,retries,ok,engine,voice}]。
// --only 3,5:只重生這幾句(要有先前的 tts.json),其他句沿用。
// 結束碼:0 全部合格;1 有句子重生 2 次仍不合格(tts.json 照寫,ok:false);2 參數 / storyboard 不合法;3 缺工具;
//         4 ComfyUI 逾時、5 連不上(沿用 comfy.mjs;已完成的句子照寫 tts.json)。
import { readFileSync, writeFileSync, mkdirSync, existsSync, rmSync, mkdtempSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { resolve, join } from 'node:path';
import { GAK, KIT, main, fail, parseArgs, validateSchema, tokenize, lineText, lineSay, probeDuration, maxVolume, hasCmd, r3, loadLexicon, applyLexicon } from './_lib.mjs';

// 預設聲音描述與參考句:2026-11-24 實測 qwen3-tts-design 時用的台灣口音女聲(--design-seed 預設 11 同實測)
const DEFAULT_DESIGN = "一位二十多歲的台灣年輕女生，標準台灣國語口音，咬字輕柔清楚，語氣親切有活力，像台灣的科技 YouTuber 在介紹新工具，不要捲舌兒化音。A young Taiwanese woman speaking Taiwan Mandarin with a natural Taiwanese accent, friendly and energetic, like a Taiwanese tech YouTuber.";
const DEFAULT_REF = "大家好，今天要介紹一個很酷的開源專案，我們一起來看看它到底在做什麼。";
const USAGE = '用法:node tts.mjs <storyboard.json> <輸出目錄> [--engine qwen3|say] [--design "<聲音描述>"] [--design-seed 11] [--ref "<參考句>"] [--preset Vivian [--instruct "…"]] [--voice <名稱>] [--seed 7] [--only 3,5] [--lexicon <檔>] [--no-lexicon]';
const MAX_RETRIES = 2;

main(() => {
  const a = parseArgs(process.argv.slice(2), { '--engine': 'v', '--design': 'v', '--design-seed': 'v', '--ref': 'v', '--preset': 'v', '--instruct': 'v', '--voice': 'v', '--seed': 'v', '--only': 'v', '--lexicon': 'v', '--no-lexicon': 'flag' }, USAGE);
  if (a._.length !== 2) fail(USAGE, 2);
  const engine = a.engine ?? 'qwen3';
  if (!['qwen3', 'say'].includes(engine)) fail('--engine 只能是 qwen3 或 say', 2);
  const int = (v, name, def) => { if (v === undefined) return def; if (!/^\d+$/.test(v) || Number(v) > 4294967295 || Number(v) < 1) fail(`${name} 要是 1 ~ 4294967295 的整數`, 2); return Number(v); };
  const seed = int(a.seed, '--seed', 7), dseed = int(a['design-seed'], '--design-seed', 11);
  // qwen3:--voice 等同 --preset;say:--voice 是 say 的聲音
  const preset = engine === 'qwen3' ? (a.preset ?? a.voice) : undefined;
  if (engine === 'say' && (a.preset || a.design || a.instruct || a.ref || a['design-seed'])) fail('--preset / --design / --ref / --design-seed / --instruct 只給 --engine qwen3', 2);
  if (preset && (a.design || a.ref || a['design-seed'])) fail('--preset(預設聲音)和 --design / --ref / --design-seed(聲音設計)擇一', 2);
  if (a.instruct && !preset) fail('--instruct 只給 --preset(聲音設計模式的語氣寫在 --design 裡)', 2);
  const mode = engine === 'say' ? 'say' : preset ? 'preset' : 'design';
  const design = a.design ?? DEFAULT_DESIGN, ref = a.ref ?? DEFAULT_REF;
  const sayVoice = engine === 'say' ? (a.voice ?? 'Meijia') : null;

  // storyboard → 句子
  let board; try { board = JSON.parse(readFileSync(a._[0], 'utf8')); } catch (e) { fail(`讀不到 storyboard:${e.message}`, 2); }
  const errs = validateSchema(JSON.parse(readFileSync(join(KIT, 'storyboard.schema.json'), 'utf8')), board);
  if (errs.length) fail(`storyboard 不符合 schema:\n  ${errs.slice(0, 10).join('\n  ')}`, 2);
  const lines = board.scenes.flatMap(s => s.lines).map((l, k) => {
    const tok = tokenize(lineText(l)); if (tok.error) fail(`第 ${k + 1} 句:${tok.error}`, 2);
    return { i: k + 1, text: tok.display, say: lineSay(l) };
  });
  if (a['no-lexicon'] && a.lexicon) fail('--lexicon 與 --no-lexicon 擇一', 2);
  const lexicon = a['no-lexicon'] ? {} : loadLexicon([join(KIT, 'pronunciation.json'), ...(a.lexicon ? [resolve(a.lexicon)] : [])]);
  const outDir = resolve(a._[1]); mkdirSync(outDir, { recursive: true });
  const ttsJson = join(outDir, 'tts.json');
  let prev = null;
  let only = null;
  if (a.only) {
    only = new Set(a.only.split(',').map(x => Number(x.trim())));
    if ([...only].some(n => !(Number.isInteger(n) && n >= 1 && n <= lines.length))) fail(`--only 要是 1 ~ ${lines.length} 的句號(逗號分隔)`, 2);
    try { prev = JSON.parse(readFileSync(ttsJson, 'utf8')); } catch { fail(`--only 需要先前的 ${ttsJson}`, 2); }
    if (!Array.isArray(prev) || prev.length !== lines.length) fail(`先前的 tts.json 有 ${prev?.length} 句,storyboard 有 ${lines.length} 句:改了句數要整份重跑(不加 --only)`, 2);
  }

  if (!hasCmd('ffmpeg')) fail('缺 ffmpeg(brew install ffmpeg)', 3);
  const comfy = join(GAK, 'scripts', 'comfy.mjs');
  if (engine === 'qwen3' && !existsSync(comfy)) fail(`找不到 game-art-kit(${comfy})`, 3);
  if (engine === 'say' && !hasCmd('say')) fail('找不到 macOS say', 3);
  const tmp = mkdtempSync(join(outDir, '.tts-'));
  const results = prev ? prev.slice() : [];
  let code = 0;
  try {
    for (const ln of lines) {
      if (only && !only.has(ln.i)) continue;
      const spoken = applyLexicon(ln.say ?? ln.text, lexicon);
      const name = String(ln.i).padStart(3, '0');
      let r = null;
      for (let k = 0; k <= MAX_RETRIES; k++) {
        const s = ((seed - 1 + 101 * k) % 4294967295) + 1;   // 重試 seed 不超過骨架上限
        const raw = synth(spoken, s, `${name}-try${k}`);
        const file = join(outDir, `${name}.wav`);
        const p = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', raw, '-af',
          'silenceremove=start_periods=1:start_silence=0.05:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_silence=0.1:start_threshold=-50dB,areverse',
          '-ar', '48000', '-ac', '1', file], { encoding: 'utf8' });
        if (p.status !== 0) fail(`第 ${ln.i} 句轉檔失敗:${(p.stderr || '').slice(-300)}`);
        if (engine === 'qwen3') rmSync(raw, { force: true }); // 只留轉好的 WAV 與 raw/workflows/(實際參數,不含位址)
        const duration = r3(probeDuration(file)); const mv = maxVolume(file);
        const ok = duration > 0.5 && mv > -30;
        r = { i: ln.i, text: ln.text, say: ln.say, spoken, file: `${name}.wav`, duration, maxVolume: Number.isFinite(mv) ? mv : -91, seed: s, retries: k, ok, engine,
          voice: mode === 'say' ? sayVoice : mode === 'preset' ? preset : 'design', ...(mode === 'design' ? { designSeed: dseed } : {}) };
        process.stderr.write(`第 ${ln.i}/${lines.length} 句 seed ${s}:${duration} 秒、max ${r.maxVolume} dB${ok ? '' : '(不合格,重生)'}\n`);
        if (ok) break;
      }
      if (!r.ok) code = 1;
      results[ln.i - 1] = r;
      writeFileSync(ttsJson, JSON.stringify(results.filter(Boolean), null, 1));
    }
  } catch (e) {
    if (results.length) writeFileSync(ttsJson, JSON.stringify(results.filter(Boolean), null, 1));
    throw e;
  } finally { rmSync(tmp, { recursive: true, force: true }); }
  const meta = mode === 'design' ? { design, ref, designSeed: dseed } : mode === 'preset' ? { preset, instruct: a.instruct ?? '' } : { voice: sayVoice };
  writeFileSync(join(outDir, 'tts-voice.json'), JSON.stringify({ engine, mode, ...meta }, null, 1));
  console.log(JSON.stringify(results));
  if (code) { console.error('有句子重生 2 次仍不合格(ok:false):改寫該句念法(say)後用 --only 重跑'); process.exit(code); }

  // ---------- 單句合成 → 原始音檔路徑 ----------
  function synth(text, s, name) {
    if (engine === 'say') {
      const f = join(tmp, `${name}.aiff`);
      const p = spawnSync('say', ['-v', sayVoice, '-o', f, '--', text], { encoding: 'utf8' });
      if (p.status !== 0) fail(`say 失敗(聲音 ${sayVoice} 存在嗎?say -v '?'):${p.stderr}`, 3);
      return f;
    }
    const wf = join(GAK, 'workflows', mode === 'preset' ? 'qwen3-tts.json' : 'qwen3-tts-design.json');
    const sets = mode === 'preset'
      ? ['variant=local:Qwen3-TTS-12Hz-1.7B-CustomVoice', `voice=${preset}`, `instruct=${a.instruct ?? ''}`, `text=${text}`, `seed=${s}`]
      : [`design=${design}`, `ref=${ref}`, `text=${text}`, `seed=${s}`, `dseed=${dseed}`];
    const p = spawnSync('node', [comfy, 'run', wf, '--out', join(outDir, 'raw'), '--name', name, ...sets.flatMap(x => ['--set', x]), '--timeout', '200', '--queue-timeout', '60'],
      { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
    if (p.status !== 0) {
      const msg = (p.stderr || p.stdout || '').trim().split('\n').slice(-6).join('\n');
      const c = p.status === 4 ? 4 : p.status === 5 ? 5 : 1;
      fail(`第 ${name} 句 Qwen3-TTS 失敗(comfy.mjs 結束碼 ${p.status}):${msg}`, c);
    }
    let res; try { res = JSON.parse(p.stdout.trim().split('\n').pop()); } catch { fail(`comfy.mjs 輸出看不懂:${p.stdout.slice(-300)}`); }
    const audio = (res.files ?? []).find(f => f.kind === 'audio');
    if (!audio) fail(`第 ${name} 句沒有拿到音訊`);
    return audio.file;
  }
});
