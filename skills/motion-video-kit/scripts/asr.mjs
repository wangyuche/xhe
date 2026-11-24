#!/usr/bin/env node
// 用法:node asr.mjs <tts 目錄> [--model <ggml 模型檔>] [--only 3,5]
// 旁白念錯字檢查:把 tts.mjs 產生的每句 WAV 用 whisper-cli 轉回文字,和該句字幕 text 逐字比對。
//   比對只看字母與數字(去標點、空白、大小寫);臺/台、它/他 等辨識常見差異視為相同。
//   數字以 text 為準(say 念「兩百九十四」、text 寫「294」時,辨識通常輸出 294)。
// 寫 <tts 目錄>/asr.json 並印同內容:[{i,text,spoken,heard,similarity,diffs:[{expected,heard}]}];
//   stderr 逐句印有出入的片段。--only:只辨識這幾句,其他沿用先前的 asr.json。
// **辨識也會聽錯**(專有名詞、台灣口音):有出入 ≠ 念錯。用法:對有出入的詞改寫 say(把詞拆開加空格「網 站」、
//   換同音字)後 tts.mjs --only 重生、asr.mjs --only 重測;辨識變正確才採用,試過仍不對就保留原句並在回報列出請人聽。
//   確認有效的改寫加進 kit 的 pronunciation.json(走 xhe PR),之後每支片自動套用。
// 模型:--model,或環境變數 SHORT_VIDEO_WHISPER_MODEL,預設 ~/.cache/whisper/ggml-large-v3-turbo.bin(同 short-video-kit)。
// 結束碼:0 完成(不論有沒有出入);2 參數 / tts.json 不合法;3 缺 whisper-cli、ffmpeg 或模型檔。
import { readFileSync, writeFileSync, existsSync, mkdtempSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { resolve, join } from 'node:path';
import { homedir, tmpdir } from 'node:os';
import { main, fail, parseArgs, hasCmd, asrDiff } from './_lib.mjs';

const USAGE = '用法:node asr.mjs <tts 目錄> [--model <ggml 模型檔>] [--only 3,5]';

main(() => {
  const a = parseArgs(process.argv.slice(2), { '--model': 'v', '--only': 'v' }, USAGE);
  if (a._.length !== 1) fail(USAGE, 2);
  const dir = resolve(a._[0]);
  let tts; try { tts = JSON.parse(readFileSync(join(dir, 'tts.json'), 'utf8')); } catch (e) { fail(`讀不到 ${join(dir, 'tts.json')}:${e.message}`, 2); }
  if (!Array.isArray(tts) || !tts.length) fail('tts.json 要是非空陣列', 2);
  const model = resolve(a.model ?? process.env.SHORT_VIDEO_WHISPER_MODEL ?? join(homedir(), '.cache/whisper/ggml-large-v3-turbo.bin'));
  if (!hasCmd('whisper-cli')) fail('缺 whisper-cli(brew install whisper-cpp)', 3);
  if (!hasCmd('ffmpeg')) fail('缺 ffmpeg(brew install ffmpeg)', 3);
  if (!existsSync(model)) fail(`缺 whisper 模型檔 ${model}(--model 指定,或見 short-video-kit check.sh --video)`, 3);

  const outFile = join(dir, 'asr.json');
  let only = null, results = [];
  if (a.only) {
    only = new Set(a.only.split(',').map(x => Number(x.trim())));
    if ([...only].some(n => !tts.some(t => t.i === n))) fail(`--only 的句號要在 tts.json 裡(1 ~ ${tts.length})`, 2);
    try { results = JSON.parse(readFileSync(outFile, 'utf8')); } catch { fail(`--only 需要先前的 ${outFile}`, 2); }
  }
  const tmp = mkdtempSync(join(process.env.SHORT_VIDEO_KIT_TMP ?? tmpdir(), 'mvk-asr-'));
  try {
    for (const t of tts) {
      if (only && !only.has(t.i)) continue;
      const wav = join(dir, t.file), w16 = join(tmp, 'a.wav');
      if (!existsSync(wav)) fail(`第 ${t.i} 句音檔不存在:${wav}`, 2);
      const f = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', wav, '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', w16], { encoding: 'utf8' });
      if (f.status !== 0) fail(`第 ${t.i} 句轉 16 kHz 失敗:${(f.stderr || '').slice(-300)}`);
      const w = spawnSync('whisper-cli', ['-m', model, '-f', w16, '-l', 'zh', '-nt', '-np', '--prompt', '以下是繁體中文的逐字稿。'], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
      if (w.status !== 0) fail(`第 ${t.i} 句 whisper-cli 失敗(結束碼 ${w.status}):${(w.stderr || '').split('\n').slice(-5).join('\n')}`);
      const heard = w.stdout.replace(/\s+/g, ' ').trim();
      const { similarity, diffs } = asrDiff(t.text, heard);
      results[t.i - 1] = { i: t.i, text: t.text, spoken: t.spoken ?? t.say ?? t.text, heard, similarity, diffs };
      if (diffs.length) process.stderr.write(`第 ${t.i} 句 相似度 ${similarity}:${diffs.map(d => `「${d.expected}」→「${d.heard}」`).join('、')}\n`);
    }
  } finally { rmSync(tmp, { recursive: true, force: true }); }
  results = results.filter(Boolean);
  writeFileSync(outFile, JSON.stringify(results, null, 1));
  const flagged = results.filter(r => r.diffs.length).map(r => r.i);
  process.stderr.write(`共 ${results.length} 句,${flagged.length} 句有出入${flagged.length ? `:${flagged.join(',')}` : ''}(辨識也會聽錯,見檔頭用法)\n`);
  console.log(JSON.stringify(results));
});
