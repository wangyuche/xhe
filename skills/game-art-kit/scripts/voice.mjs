#!/usr/bin/env node
// game-art-kit:角色語音(ElevenLabs,付費)。Node ≥ 22 內建 fetch;音訊後處理用 audio.mjs(ffmpeg)。
// 金鑰:環境變數 ELEVENLABS_API_KEY → ~/.elevenlabs/.env(ELEVENLABS_API_KEY=...);只進記憶體,不印出、不寫檔。
// 測試:ELEVENLABS_API_URL 只接受 http://127.0.0.1:<埠>;有設時用假金鑰,不讀真的。
// voice.json(art/characters/<id>/voice.json):
//   { id, design(英文描述,送 API), design_notes, design_source(使用者原話), preview_text(100–1000 字元), voice_name,
//     models: {design: "eleven_ttv_v3", tts: "eleven_v4", output_format: "mp3_44100_128"}, stability(0.5),
//     candidates: [{n, generated_voice_id, path}], candidates_for, next_n, voice_id, prev_voice_id, seed?, line_seeds: {key: seed}, lines: {key: hash} }
// 用法(付費的指令都要 --budget <累計檔> --limit <N 字元> --run <派工 id>;字元 = 送出文字的長度,含 [sweetly] 這類標記):
//   node voice.mjs design --voice <voice.json> --out-dir <過程目錄> --budget … --limit … --run … [--redesign]
//        /v1/text-to-voice/design(一次 3 個 preview)→ <過程目錄>/candidate-<n>.{mp3,ogg,m4a}(n 接續編號);寫回 candidates
//   node voice.mjs pick   --voice <voice.json> --n <n> [--repick]  /v1/text-to-voice:把候選建成正式 voice,voice_id 寫回(不算字元;已選定要換選加 --repick)
//   node voice.mjs plan   --voice <voice.json> --lines <lines.json> [--all]      要錄的 key、首次字元、含重錄最多字元(不連網)
//   node voice.mjs lines  --voice <voice.json> --lines <lines.json> --out <art/voice/<id>> --raw-dir <過程目錄> --budget … --limit … --run … [--all] [--max K] [--max-seconds 480]
//        --max K:本次最多 K 句(依 key 排序的前 K 句,其餘 deferred,下次照雜湊補)
//        只錄雜湊不同或缺檔的;原檔 <過程目錄>/raw/<key>.mp3 → audio.mjs --type voice → <out>/<key>.{ogg,m4a};check 不過換 seed 重錄(每句最多 2 次);
//        每句完成就寫回 voice.json 與 <過程目錄>/manifest.json;超過 --max-seconds 就停,印 remaining(結束碼 0;remaining 不是空的就再呼叫一次)
//   node voice.mjs status --voice <voice.json> --lines <lines.json> --out <art/voice/<id>>
//   node voice.mjs scan   --art <art 目錄>                         用記憶體裡的金鑰完全比對 art/ 下的檔案,只印有 / 無與檔名
// 雜湊 = sha256(JSON.stringify([原文, voice_id, tts 模型, stability, output_format, seed]))。
// 結束碼:0 成功;1 有句子 / 候選不合格;2 用法 / 設定錯誤;3 HTTP 錯誤(重試用完或不可重試);4 額度用完(402 / 401 quota);
//        5 金鑰錯誤(401 / 403 非額度)或找不到金鑰;6 超過字元上限(沒送出);8 帳號 voice 名額已滿。
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync, statSync, realpathSync, renameSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve, relative } from 'node:path';
import { homedir } from 'node:os';
import { openBudget, BudgetError, appendJsonItem } from './budget.mjs';

class Fail extends Error { constructor(m, c = 2, http) { super(m); this.code = c; this.http = http; } }
const die = (m, c = 2, http) => { throw new Fail(m, c, http); };
const KIT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const KEY_RE = /^[a-z0-9][a-z0-9._-]*$/;
const SEED_MAX = 4294967295, TRIES = 3, MAX_ATTEMPTS = 5, REQ_TIMEOUT = 60_000;
const DEFAULT_MODELS = { design: 'eleven_ttv_v3', tts: 'eleven_v4', output_format: 'mp3_44100_128' };
const readJson = (f, what) => { try { return JSON.parse(readFileSync(f, 'utf8')); } catch (e) { die(`${what} ${f} 讀不到或不是 JSON:${e.message}`); } };
const writeJson = (f, o) => { mkdirSync(dirname(f), { recursive: true }); writeFileSync(f, JSON.stringify(o, null, 1) + '\n'); };
const h32 = (s) => parseInt(createHash('sha256').update(s).digest('hex').slice(0, 8), 16);
const NAME_RE = /\b(voice of|sounds? like|like (?:the )?(?:famous|actor|actress|singer))\b/i;

// ---------- 金鑰與 API ----------
function api() {
  const fake = process.env.ELEVENLABS_API_URL;
  if (fake) {
    if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(fake)) die('ELEVENLABS_API_URL 只接受 http://127.0.0.1:<埠>(測試用)');
    return { base: fake, key: 'test-key-not-real' };
  }
  let key = process.env.ELEVENLABS_API_KEY?.trim();
  const f = join(homedir(), '.elevenlabs', '.env');
  if (!key && existsSync(f)) for (const line of readFileSync(f, 'utf8').split('\n')) { const m = /^\s*(?:export\s+)?ELEVENLABS_API_KEY\s*=\s*['"]?([^'"\s#]+)/.exec(line); if (m) key = m[1]; }
  if (!key) die('找不到 ElevenLabs 金鑰:請使用者自己在終端機建立 ~/.elevenlabs/.env(內容 ELEVENLABS_API_KEY=...,chmod 600),不要貼進對話', 5);
  return { base: 'https://api.elevenlabs.io', key };
}
const scrubKey = (s, key) => String(s ?? '').split(key).join('<key>');
class Deadline extends Error {}
async function post(A, path, body, { binary = false, before, rejected, deadline, idempotent = true, timeoutMs = REQ_TIMEOUT } = {}) {
  for (let attempt = 1; ; attempt++) {
    // 每次 HTTP 嘗試前檢查時限(最壞一次 60 秒 + 退避):到時間就不送,交給呼叫端停下來
    if (deadline && Date.now() + 75_000 > deadline) throw new Deadline();
    before?.(attempt); // 每次 HTTP 嘗試都先記用量(逾時的請求服務端可能已計費)
    const ac = new AbortController(), t = setTimeout(() => ac.abort(), timeoutMs);
    let res;
    try { res = await fetch(A.base + path, { method: 'POST', headers: { 'xi-api-key': A.key, 'content-type': 'application/json' }, body: JSON.stringify(body), signal: ac.signal }); }
    catch (e) { clearTimeout(t); if (attempt >= MAX_ATTEMPTS || !idempotent) die(`ElevenLabs 連線失敗:${e.name === 'AbortError' ? '逾時 60 秒' : e.message}`, 3); await new Promise(r => setTimeout(r, 1000 * 2 ** (attempt - 1))); continue; }
    // 計時器要等內容讀完才清掉(伺服器送了標頭、內容卻卡住時也會逾時)
    let bodyBuf, text;
    try { if (res.ok) bodyBuf = Buffer.from(await res.arrayBuffer()); else text = scrubKey(await res.text(), A.key).slice(0, 400); }
    catch (e) { clearTimeout(t); if (attempt >= MAX_ATTEMPTS || !idempotent) die(`ElevenLabs 讀取回應失敗${idempotent ? '' : '(建立 voice 的回應沒收完:帳號裡可能已經多了一個 voice,請到 ElevenLabs 確認)'}:${e.name === 'AbortError' ? '逾時 60 秒' : e.message}`, 3); await new Promise(r => setTimeout(r, 1000 * 2 ** (attempt - 1))); continue; }
    clearTimeout(t);
    if (res.ok) { if (binary) return bodyBuf; try { return JSON.parse(bodyBuf.toString('utf8')); } catch { die(`ElevenLabs 回傳的不是 JSON(HTTP ${res.status},可能是代理伺服器的頁面)`, 3); } }
    if (res.status === 429) rejected?.(attempt); // 限流:服務端沒處理,不計費 → 退回這次的用量(放在任何放棄判斷之前)
    if (res.status === 402 || (res.status === 401 && /quota|insufficient_credits|credits/i.test(text))) die(`ElevenLabs 額度用完(HTTP ${res.status}):${text}`, 4);
    if (res.status === 401 || res.status === 403) die(`ElevenLabs 金鑰錯誤(HTTP ${res.status}):${text}`, 5);
    if (/voice_limit|voice limit|maximum number of voices/i.test(text)) die(`ElevenLabs 帳號 voice 名額已滿:請使用者自己到 ElevenLabs 刪舊 voice(HTTP ${res.status})`, 8);
    // 建立 voice 不是冪等的:只在 429(服務端沒處理)重試,逾時 / 409 / 5xx 不重送,避免重複建立付費 voice
    const retryable = res.status === 429 || (idempotent && (res.status === 409 || res.status >= 500));
    if (!retryable || attempt >= MAX_ATTEMPTS) die(`ElevenLabs HTTP ${res.status}:${text}`, 3, res.status);
    const after = Number(res.headers.get('retry-after'));
    const wait = Math.min(after > 0 ? after * 1000 : 1000 * 2 ** (attempt - 1), 30_000); // 最多等 30 秒
    if (deadline && Date.now() + wait + 75_000 > deadline) throw new Deadline(); // 等完就超過時限:這句留到下次
    await new Promise(r => setTimeout(r, wait));
  }
}

// ---------- 設定 ----------
function loadVoice(f) {
  const v = readJson(f, 'voice.json');
  for (const k of ['design', 'preview_text']) if (!v[k]) die(`voice.json 缺 ${k}`);
  v.models = { ...DEFAULT_MODELS, ...(v.models ?? {}) }; v.stability = v.stability ?? 0.5;
  return v;
}
export const lineSeed = (v, key) => v.line_seeds?.[key] ?? v.seed ?? h32(key) % SEED_MAX;
export const lineHash = (v, key, text) => createHash('sha256').update(JSON.stringify([text, v.voice_id, v.models.tts, v.stability, v.models.output_format, lineSeed(v, key)])).digest('hex').slice(0, 16);
function loadLines(f) {
  const l = readJson(f, '台詞清單');
  if (!l || typeof l !== 'object' || Array.isArray(l)) die('台詞清單要是 {"<key>": "<台詞>"}');
  const bad = Object.keys(l).filter(k => !KEY_RE.test(k) || typeof l[k] !== 'string' || !l[k].trim());
  if (bad.length) die(`台詞 key 不合規或台詞是空的(key 要符合 ${KEY_RE}):${bad.slice(0, 10).join(', ')}`);
  return l;
}
const artOf = (voiceFile) => resolve(dirname(voiceFile), '..', '..');
function audio(input, outDir, name, dur = 15) {
  const a = spawnSync(process.execPath, [join(KIT, 'scripts', 'audio.mjs'), 'process', input, '--type', 'voice', '--duration', String(dur), '--out', outDir, '--name', name], { encoding: 'utf8' });
  if (a.status === 2) { const err = (a.stderr || '').trim().split('\n').pop(); if (/找不到 ffmpeg|找不到 ffprobe|缺 ff|libopus|aac 編碼器/.test(err)) die(`audio.mjs:${err}`); return { ok: false, error: `音訊讀不了:${err}` }; } // 這句的音訊壞了:記失敗 / 換 seed,不中止整批
  if (a.status !== 0) { const err = (a.stderr || '').trim().split('\n').pop(); return { ok: false, error: err, noRetry: /超過 \d+ 秒|請拆句/.test(err) }; }
  let j = {}; try { j = JSON.parse(a.stdout.trim().split('\n').pop()); } catch { /* */ }
  const c = spawnSync(process.execPath, [join(KIT, 'scripts', 'audio.mjs'), 'check', join(outDir, `${name}.ogg`), join(outDir, `${name}.m4a`), '--type', 'voice', '--duration', String(dur), ...(j.normalized === 'peak' ? ['--peak'] : [])], { encoding: 'utf8' });
  let cj = {}; try { cj = JSON.parse(c.stdout.trim().split('\n').pop()); } catch { /* */ }
  return { ok: c.status === 0, error: c.status === 0 ? null : (cj.errors ?? [c.stderr]).join(';'), durationSec: j.durationSec };
}
// 送出失敗(結束碼 3 / 4 / 5 / 8)也追加一筆,讓 manifest 的累計值等於實際送出
async function postLogged(A, path, body, opts, log) {
  try { return await post(A, path, body, opts); }
  catch (e) { if (e instanceof Fail && log) log(`HTTP 失敗(結束碼 ${e.code}):${e.message.slice(0, 200)}`); throw e; }
}
// manifest 寫不進去(殘留的鎖、磁碟錯誤)只記警告,不能讓已付費的結果沒存回 voice.json
const manifestWarnings = [];
function appendManifest(dir, entry, used, run) { try { mkdirSync(dir, { recursive: true }); appendJsonItem(join(dir, 'manifest.json'), { run, ...entry, budget_used: used }); } catch (e) { manifestWarnings.push(`manifest 沒寫進去:${e.message}`); } }

// ---------- 指令 ----------
export async function design(voiceFile, { outDir, budget, limit, run, redesign = false }) {
  const v = loadVoice(voiceFile);
  if (v.voice_id && !redesign) die(`voice.json 已選定音色(voice_id 已建立);重新設計會讓所有台詞重錄,要明確加 --redesign`);
  const len = [...v.preview_text].length;
  if (len < 100 || len > 1000) die(`preview_text 要 100–1000 字元(ElevenLabs Voice Design 的限制),目前 ${len}`);
  if (NAME_RE.test(v.design)) die('design 疑似要求模仿特定人物的聲音(voice of / sounds like …):只描述一般特徵');
  if (!run) die('缺 --run <派工 id>');
  const A = api(), b = openBudget(budget, limit, '字元'), art = artOf(voiceFile);
  let used = b.used;
  const res = await postLogged(A, `/v1/text-to-voice/design?output_format=${encodeURIComponent(v.models.output_format)}`, { voice_description: v.design, text: v.preview_text, model_id: v.models.design, ...(v.seed != null ? { seed: v.seed } : {}) }, { idempotent: false, timeoutMs: 180_000, before: (n) => { used = b.reserve(len, `voice design(第 ${n} 次嘗試)`); }, rejected: (n) => { used = b.refund(len, `voice design 第 ${n} 次 429`); } }, (st) => appendManifest(outDir, { kind: 'design', chars: len, status: st }, used, run));
  const dh = createHash('sha256').update(JSON.stringify([v.design, v.preview_text, v.models.design])).digest('hex').slice(0, 12);
  if (v.candidates_for !== dh) v.candidates = [];
  let n = v.next_n ?? 1; const made = [];
  mkdirSync(outDir, { recursive: true });
  // 每個候選存好就寫回 voice.json(已付費的候選不會因為後面一筆壞資料全部遺失);試聽句可能比一句台詞長,上限放寬到 60 秒
  for (const p of res.previews ?? []) {
    if (!p || typeof p.generated_voice_id !== 'string' || typeof p.audio_base_64 !== 'string' || !p.audio_base_64) {
      appendManifest(outDir, { kind: 'candidate', n: null, chars: len, status: 'ElevenLabs 回傳的 preview 缺欄位,略過' }, used, run); continue;
    }
    const name = `candidate-${n}`, mp3 = join(outDir, `${name}.mp3`);
    writeFileSync(mp3, Buffer.from(p.audio_base_64, 'base64'));
    let a; try { a = audio(mp3, outDir, name, 60); } catch (e) { a = { ok: false, error: e.message }; }
    const c = { n, generated_voice_id: p.generated_voice_id, path: relative(art, mp3), check: a.ok ? 'ok' : a.error };
    v.candidates.push(c); made.push(c);
    appendManifest(outDir, { kind: 'candidate', n, chars: len, status: a.ok ? 'ok' : `check 不過:${a.error}` }, used, run);
    n++;
    v.next_n = n; v.candidates_for = dh;
    if (v.voice_id) { v.prev_voice_id = v.voice_id; delete v.voice_id; } // 重新設計:新候選有了才取消舊選定
    writeJson(voiceFile, v);
  }
  if (!made.length) die('ElevenLabs 沒有回傳任何可用的 preview', 3);
  const anyOk = made.some(c => c.check === 'ok');
  return { ok: anyOk, manifest_warnings: manifestWarnings.length ? manifestWarnings : undefined, chars: len, budget: { used, limit }, candidates: made.map(c => ({ n: c.n, check: c.check, listen: join(art, c.path) })), prev_voice_id: v.prev_voice_id ?? null, key_scan: scan(art, A.key) };
}

export async function pick(voiceFile, n, { repick = false, force = false } = {}) {
  const v = loadVoice(voiceFile);
  if (v.voice_id && !repick) die('voice.json 已選定音色(voice_id 已建立);換選會建立新的付費 voice、所有台詞重錄,要明確加 --repick');
  const c = (v.candidates ?? []).find(x => x.n === n) ?? die(`voice.json 的 candidates 沒有 n = ${n}(先跑 design;描述改過的話舊候選已作廢)`);
  const dhNow = createHash('sha256').update(JSON.stringify([v.design, v.preview_text, v.models.design])).digest('hex').slice(0, 12);
  if (v.candidates_for && v.candidates_for !== dhNow) die('voice.json 的 design / preview_text 改過了,候選是舊描述做的:先重新 design 再選');
  if (c.check && c.check !== 'ok' && !force) die(`候選 ${n} 的音訊檢查沒過(${String(c.check).slice(0, 100)});確定要用加 --force(會建立付費 voice)`);
  const A = api();
  const r = await post(A, '/v1/text-to-voice', { voice_name: v.voice_name ?? v.id ?? 'character', voice_description: v.design, generated_voice_id: c.generated_voice_id, labels: { character: v.id ?? '' } }, { idempotent: false });
  if (v.voice_id) v.prev_voice_id = v.voice_id;
  v.voice_id = r.voice_id ?? die('ElevenLabs 沒有回傳 voice_id', 3);
  writeJson(voiceFile, v);
  return { ok: true, n, voice_id_set: true, key_scan: scan(artOf(voiceFile), A.key) };
}

export function plan(voiceFile, { linesFile, all = false, out, max }) {
  const v = loadVoice(voiceFile), L = loadLines(linesFile), keys = Object.keys(L).sort();
  const has = (k) => out && existsSync(join(out, `${k}.ogg`)) && existsSync(join(out, `${k}.m4a`));
  const pending = v.voice_id ? keys.filter(k => all || v.lines?.[k] !== lineHash(v, k, L[k]) || (out && !has(k))) : keys;
  const todo = max != null ? pending.slice(0, max) : pending; // 「本次最多 K 句」:依 key 排序的前 K 句,其餘下次照雜湊補
  const first = todo.reduce((s, k) => s + [...L[k]].length, 0);
  return { ok: true, total: keys.length, todo, deferred: pending.length - todo.length, first_chars: first, max_chars: first * TRIES, max_chars_note: '含每句重錄 2 次;不含網路逾時 / 5xx 重試(那些可能計費,會照實累計;429 限流會退回)', note: v.voice_id ? null : '還沒選定音色:全部都要錄' };
}

export async function lines(voiceFile, { linesFile, out, procDir, budget, limit, run, all = false, maxSeconds = 480, max }) {
  const v = loadVoice(voiceFile);
  if (!v.voice_id) die('voice.json 還沒選定音色(voice_id);先 design、請使用者試聽後 pick');
  if (!run) die('缺 --run <派工 id>');
  const L = loadLines(linesFile), A = api(), b = openBudget(budget, limit, '字元'), art = artOf(voiceFile);
  const { todo, deferred } = plan(voiceFile, { linesFile, all, out, max });
  const raw = join(procDir, 'raw'), stage = join(procDir, 'stage'); mkdirSync(raw, { recursive: true }); mkdirSync(stage, { recursive: true }); mkdirSync(out, { recursive: true });
  v.lines = v.lines ?? {}; v.line_seeds = v.line_seeds ?? {};
  const t0 = Date.now(), done = [], failed = []; let used = b.used, stoppedAt = null;
  for (const k of todo) {
    if ((Date.now() - t0) / 1000 > maxSeconds) { stoppedAt = k; break; }
    const text = L[k], len = [...text].length; let seed = lineSeed(v, k), res = null, tries = 0, lastSeed = seed;
    // 重錄前這句已是有效成品(雜湊相同、檔案都在,例如 --all):全部失敗時保留原本的雜湊與 seed,不讓好的錄音變成過期
    const prevGood = v.lines?.[k] === lineHash(v, k, text) && existsSync(join(out, `${k}.ogg`)) && existsSync(join(out, `${k}.m4a`));
    let hitDeadline = false;
    for (; tries < TRIES; tries++) {
      lastSeed = seed;
      // 每次 HTTP 嘗試都先記用量;超過上限 → BudgetError(結束碼 6),已完成的都已寫回
      let buf;
      try { buf = await postLogged(A, `/v1/text-to-speech/${encodeURIComponent(v.voice_id)}?output_format=${encodeURIComponent(v.models.output_format)}`, { text, model_id: v.models.tts, voice_settings: { stability: v.stability }, seed }, { binary: true, deadline: t0 + maxSeconds * 1000, before: (n) => { used = b.reserve(len, `line ${k}(第 ${n} 次嘗試)`); }, rejected: (n) => { used = b.refund(len, `line ${k} 第 ${n} 次 429`); } }, (st) => appendManifest(procDir, { kind: 'line', key: k, text, chars: len, seed, try: tries + 1, status: st }, used, run)); }
      catch (e) {
        if (e instanceof Deadline) { hitDeadline = true; if (tries > 0 && !prevGood) v.line_seeds[k] = seed; break; } // 已失敗過:下次從新 seed 開始(原本是好錄音就不動,免得變成過期)
        if (e instanceof Fail && e.http >= 400 && e.http < 500) { res = { ok: false, error: e.message, noRetry: true }; break; } // 這句被拒(400 等):記失敗,繼續下一句
        throw e;
      }
      const mp3 = join(raw, `${k}.mp3`); writeFileSync(mp3, buf);
      res = audio(mp3, stage, k); // 先放過程目錄,check 通過才換掉成品(失敗不會蓋掉原本好的錄音)
      if (res.ok) for (const ext of ['ogg', 'm4a']) renameSync(join(stage, `${k}.${ext}`), join(out, `${k}.${ext}`));
      appendManifest(procDir, { kind: 'line', key: k, text, chars: len, seed, try: tries + 1, status: res.ok ? 'ok' : `check 不過:${res.error}` }, used, run);
      if (res.ok || res.noRetry) break; // 超過 15 秒換 seed 也不會變短:不重錄,請拆句
      seed = (seed + 1000003) % SEED_MAX;
    }
    if (hitDeadline) { stoppedAt = k; writeJson(voiceFile, v); break; } // 到時間:這句留到下次(不算失敗,不動它的雜湊)
    if (res && res.ok) { if (lastSeed !== lineSeed(v, k)) v.line_seeds[k] = lastSeed; v.lines[k] = lineHash(v, k, text); done.push(k); }
    else { if (!prevGood) { v.line_seeds[k] = (lastSeed + 1000003) % SEED_MAX; delete v.lines[k]; } failed.push({ key: k, error: res.error, kept_previous: prevGood }); }
    writeJson(voiceFile, v); // 每句存一次:中途停下來,再跑會略過已完成的
  }
  const remaining = stoppedAt ? todo.slice(todo.indexOf(stoppedAt)) : [];
  // 只是到時間停下(remaining)不算失敗:結束碼 0,呼叫端看 remaining 再跑一次
  return { ok: !failed.length, manifest_warnings: manifestWarnings.length ? manifestWarnings : undefined, recorded: done.length, skipped: Object.keys(L).length - todo.length - deferred, deferred, failed, remaining, budget: { used, limit }, key_scan: scan(art, A.key) };
}

export function status(voiceFile, { linesFile, out }) {
  const v = loadVoice(voiceFile), L = loadLines(linesFile);
  const rows = Object.keys(L).sort().map(k => ({ key: k, current: !!v.voice_id && v.lines?.[k] === lineHash(v, k, L[k]), ogg: existsSync(join(out, `${k}.ogg`)), m4a: existsSync(join(out, `${k}.m4a`)) }));
  const bad = rows.filter(r => !r.current || !r.ogg || !r.m4a);
  return { ok: !bad.length, total: rows.length, outdated: bad.map(r => r.key), voice_selected: !!v.voice_id };
}

// 用記憶體裡的金鑰完全比對 art/ 下所有檔案(只印有 / 無與檔名,不印金鑰)
export function scan(artDir, key) {
  if (!key || key.length < 8) return { found: false, files: [] };
  const hits = [], needle = Buffer.from(key);
  const walk = (d) => { for (const e of readdirSync(d, { withFileTypes: true })) { const p = join(d, e.name); if (e.isDirectory()) walk(p); else if (e.isFile() && statSync(p).size < 64 * 2 ** 20 && readFileSync(p).includes(needle)) hits.push(relative(artDir, p)); } };
  if (existsSync(artDir)) walk(artDir);
  return { found: hits.length > 0, files: hits };
}

const isMain = (() => { try { return !!process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } })();
if (isMain) {
  try {
    const [cmd, ...rest] = process.argv.slice(2);
    const f = {};
    for (let i = 0; i < rest.length; i++) { const a = rest[i]; if (['--redesign', '--all', '--repick', '--force'].includes(a)) f[a.slice(2)] = true; else if (a.startsWith('--')) f[a.slice(2)] = rest[++i] ?? die(`${a} 缺值`); else die(`多餘的參數 ${a}`); }
    const int = (k) => { if (!/^\d+$/.test(String(f[k]))) die(`--${k} 要是正整數`); const n = Number(f[k]); if (n < 1) die(`--${k} 要 ≥ 1`); return n; };
    const vf = () => f.voice ?? die('缺 --voice <voice.json>');
    let r;
    if (cmd === 'design') r = await design(vf(), { outDir: f['out-dir'] ?? die('缺 --out-dir'), budget: f.budget, limit: f.limit != null ? int('limit') : undefined, run: f.run, redesign: !!f.redesign });
    else if (cmd === 'pick') r = await pick(vf(), int('n'), { repick: !!f.repick, force: !!f.force });
    else if (cmd === 'plan') r = plan(vf(), { linesFile: f.lines ?? die('缺 --lines'), all: !!f.all, out: f.out, max: f.max != null ? int('max') : undefined });
    else if (cmd === 'lines') r = await lines(vf(), { linesFile: f.lines ?? die('缺 --lines'), out: f.out ?? die('缺 --out'), procDir: f['raw-dir'] ?? die('缺 --raw-dir'), budget: f.budget, limit: f.limit != null ? int('limit') : undefined, run: f.run, all: !!f.all, maxSeconds: f['max-seconds'] != null ? (int('max-seconds') >= 120 ? int('max-seconds') : die('--max-seconds 至少 120(一次請求最壞約 75 秒)')) : 480, max: f.max != null ? int('max') : undefined });
    else if (cmd === 'status') r = status(vf(), { linesFile: f.lines ?? die('缺 --lines'), out: f.out ?? die('缺 --out') });
    else if (cmd === 'scan') { let key = null; try { key = api().key; } catch (e) { if (!(e instanceof Fail && e.code === 5)) throw e; } r = key ? scan(resolve(f.art ?? die('缺 --art')), key) : { found: false, files: [], note: '這台沒有 ElevenLabs 金鑰,不用掃' }; }
    else die('用法:voice.mjs design | pick | plan | lines | status | scan(見檔頭)');
    console.log(JSON.stringify(r));
    process.exit(r.ok === false || r.found || r.key_scan?.found ? 1 : 0);
  } catch (e) {
    console.error(`錯誤:${e instanceof Fail || e instanceof BudgetError || e?.usage ? e.message : e?.stack || e}`);
    process.exit(e instanceof Fail || e instanceof BudgetError ? e.code : e?.usage ? 2 : 2);
  }
}
