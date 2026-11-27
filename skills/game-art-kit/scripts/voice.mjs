#!/usr/bin/env node
// game-art-kit:角色語音(區網 ComfyUI 的 Qwen3-TTS 聲音設計;不用雲端 / 付費服務)。透過 comfy.mjs run 送 workflows/qwen3-tts-design.json,
// 再用 audio.mjs process --type voice 正規化成 .ogg + .m4a。
// voice.json(art/characters/<id>/voice.json):
//   { "id", "design"(英文聲音描述), "design_source"(使用者原話), "ref"(試聽句), "language"(check 的 defaults.tts_languages 其中之一),
//     "variants": {"design","base"}(VoiceDesign / Base 模型 variant,只用來算雜湊), "candidates": [{n, dseed, path}], "dseed"(選定),
//     "seed"(選填,全角色共用), "line_seeds": {key: seed}(重出換過的), "lines": {key: hash} }
// 用法:
//   node voice.mjs design --voice <voice.json> --out-dir <dir> --only <k> [--redesign] [--art <art>]
//        設計第 k 個候選(一次呼叫只合成一次,放得進 Bash 600 秒):dseed 由 design + k + 第幾次嘗試決定 → <dir>/candidate-<k>.{ogg,m4a}、原檔在 <dir>/raw/;
//        成功就寫回 candidates(每個候選完成就存,不會因中斷全部遺失);check 不過結束碼 1,再呼叫一次同一個 k 會換 dseed(每個 k 最多 3 次:第一次 + 重出 2 次)。
//        voice.json 已有選定的 dseed、沒加 --redesign → 結束碼 2(避免所有台詞雜湊一起變);--redesign 時第一個新候選成功後才取消舊選定(舊值留 prev_dseed)。
//        候選綁定 design + ref + language + variants(candidates_for):描述改了,舊候選與嘗試次數自動作廢
//   node voice.mjs pick --voice <voice.json> --n <n>                       選定候選 n:dseed 寫回 voice.json
//   node voice.mjs lines --voice <voice.json> --lines <lines.json> --out <art/voice/<id>> --raw-dir <過程目錄> [--all] [--max N]
//        (原檔與 workflows 寫 <過程目錄>/raw/,manifest 寫 <過程目錄>/manifest.json;每句完成就存 voice.json,中途被中止再跑一次即可)
//        lines.json = {"<key>": "<台詞>"};key 要符合 ^[a-z0-9][a-z0-9._-]*$(任何一個不合 → 結束碼 2,不做任何一句)。
//        依 key 排序,只做雜湊不同或缺檔的(--all 全做;--max N 最多做 N 句,其餘下次照雜湊補做)。[sweetly] 這類標記念之前去掉。
//        check 不過(含超過 15 秒、靜音)換 seed 重出,每句最多 2 次;換過的 seed 寫進 line_seeds。寫 <raw-dir>/manifest.json。
//   node voice.mjs status --voice <voice.json> --lines <lines.json> --out <art/voice/<id>>
//        每個 key:雜湊是否等於重算值、ogg / m4a 是否存在;全部一致結束碼 0,否則 1
// 雜湊 = sha256(原文(去標記前)、design、ref、dseed、language、variants、seed)。
// 每次呼叫 ComfyUI 印 generations(算進生成上限)。結束碼:0 成功;1 有句子 / 候選重出 2 次仍不合格、status 不一致;2 用法 / 設定錯誤;3 以上沿用 comfy.mjs。
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, existsSync, realpathSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve, relative } from 'node:path';

class Fail extends Error { constructor(m, c = 2) { super(m); this.code = c; } }
const die = (m, c = 2) => { throw new Fail(m, c); };
const KIT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const WF = join(KIT, 'workflows', 'qwen3-tts-design.json');
export const KEY_RE = /^[a-z0-9][a-z0-9._-]*$/;
const SEED_MAX = 4294967295, TRIES = 3; // 第一次 + 重出 2 次
const readJson = (f, what) => { try { return JSON.parse(readFileSync(f, 'utf8')); } catch (e) { die(`${what} ${f} 讀不到或不是 JSON:${e.message}`); } };
const writeJson = (f, o) => { mkdirSync(dirname(f), { recursive: true }); writeFileSync(f, JSON.stringify(o, null, 1) + '\n'); };
const h32 = (s) => parseInt(createHash('sha256').update(s).digest('hex').slice(0, 8), 16);
export const stripTags = (t) => t.replace(/\[[^\]]*\]/g, ' ').replace(/\s+/g, ' ').trim();

function loadVoice(f) {
  const v = readJson(f, 'voice.json');
  for (const k of ['design', 'ref', 'language']) if (!v[k]) die(`voice.json 缺 ${k}`);
  return v;
}
export const lineSeed = (v, key) => v.line_seeds?.[key] ?? v.seed ?? h32(key) % SEED_MAX;
export function lineHash(v, key, text) {
  return createHash('sha256').update(JSON.stringify([text, v.design, v.ref, v.dseed, v.language, v.variants ?? null, lineSeed(v, key)])).digest('hex').slice(0, 16);
}

function sh(args, what) {
  const p = spawnSync('node', args, { encoding: 'utf8', maxBuffer: 64 * 2 ** 20 });
  if (p.error) die(`${what}:${p.error.message}`);
  const out = (p.stdout || '').trim().split('\n').pop();
  let j = null; try { j = JSON.parse(out); } catch { /* */ }
  return { status: p.status, json: j, err: ((p.stderr || '') + (p.stdout || '')).trim().split('\n').slice(-3).join(' ') };
}
// 念一句 → 原始音檔 → audio process(--type voice)。回傳 {ok, files, measure, error};ComfyUI 本身失敗(結束碼 ≥ 3)直接中止
function synth(v, { text, seed, dseed, rawDir, name, outDir }) {
  const r = sh([join(KIT, 'scripts', 'comfy.mjs'), 'run', WF, '--out', rawDir, '--name', name, '--set', `design=${v.design}`, '--set', `ref=${v.ref}`,
    '--set', `text=${text}`, '--set', `seed=${seed}`, '--set', `dseed=${dseed}`, '--set', `language=${v.language}`, '--timeout', '150', '--queue-timeout', '30', '--download-timeout', '20'], 'comfy.mjs');
  if (r.status !== 0) die(`qwen3-tts-design 失敗(comfy.mjs 結束碼 ${r.status}):${r.err}`, r.status >= 3 ? r.status : 3);
  const raw = r.json?.files?.find(f => f.kind === 'audio')?.file ?? die('qwen3-tts-design 沒有音訊輸出', 3);
  const a = sh([join(KIT, 'scripts', 'audio.mjs'), 'process', raw.startsWith('/') ? raw : join(rawDir, raw), '--type', 'voice', '--out', outDir, '--name', name], 'audio.mjs');
  if (a.status === 2) die(`audio.mjs process 失敗:${a.err}`);
  if (a.status !== 0) return { ok: false, error: a.err, raw };
  const c = sh([join(KIT, 'scripts', 'audio.mjs'), 'check', join(outDir, `${name}.ogg`), join(outDir, `${name}.m4a`), '--type', 'voice', ...(a.json?.normalized === 'peak' ? ['--peak'] : [])], 'audio.mjs');
  return { ok: c.status === 0, error: c.status === 0 ? null : (c.json?.errors ?? [c.err]).join(';'), files: a.json?.files, measure: c.json?.measure, raw };
}

export function design(voiceFile, { outDir, only, redesign = false, art }) {
  let v = loadVoice(voiceFile);
  if (v.dseed != null && !redesign) die(`voice.json 已選定音色(dseed ${v.dseed});重新設計會讓所有台詞的雜湊改變、全部重錄,要明確加 --redesign`);
  // 候選屬於某一組 design + ref + language:描述改了(或 --redesign 後第一次成功前)舊候選與嘗試次數一律作廢,不會被 pick 到
  const dh = createHash('sha256').update(JSON.stringify([v.design, v.ref, v.language, v.variants ?? null])).digest('hex').slice(0, 12);
  if (v.candidates_for !== dh) { v = { ...v, candidates: [], design_tries: {} }; }
  const artDir = resolve(art ?? join(dirname(voiceFile), '..', '..'));
  const rawDir = join(outDir, 'raw'); mkdirSync(rawDir, { recursive: true });
  const k = only, tries = v.design_tries?.[k] ?? 0;
  if (tries >= TRIES) die(`候選 ${k} 已試 ${tries} 次(上限 ${TRIES}),不再重出`, 1);
  const dseed = (h32(`${v.design}|${k}`) + tries * 1000003) % SEED_MAX;
  const res = synth(v, { text: stripTags(v.ref), seed: v.seed ?? 1, dseed, rawDir, name: `candidate-${k}`, outDir });
  const mf = join(outDir, 'manifest.json'), manifest = existsSync(mf) ? readJson(mf, 'manifest') : { voice: relative(artDir, voiceFile), design: v.design, ref: v.ref, language: v.language, items: [] };
  manifest.items.push({ kind: 'candidate', n: k, dseed, try: tries + 1, ok: res.ok, error: res.error, raw: res.raw && relative(artDir, resolve(res.raw)) });
  writeJson(mf, manifest);
  // ComfyUI 本身失敗(結束碼 ≥ 3)時 synth 直接中止,voice.json 不會被改;到這裡才寫回
  v.design_tries = { ...(v.design_tries ?? {}), [k]: tries + 1 };
  v.candidates_for = dh;
  if (res.ok) {
    v.candidates = [...(v.candidates ?? []).filter(c => c.n !== k), { n: k, dseed, path: relative(artDir, join(outDir, `candidate-${k}.ogg`)) }].sort((a, b) => a.n - b.n);
    // 重新設計:新候選成功後才取消舊的選定(舊 dseed 留在 prev_dseed,需要時可手動還原)
    if (v.dseed != null) { v.prev_dseed = v.dseed; delete v.dseed; }
  }
  writeJson(voiceFile, v);
  return { ok: res.ok, generations: 1, n: k, dseed, try: tries + 1, error: res.error, listen: res.ok ? join(outDir, `candidate-${k}.ogg`) : null, candidates: v.candidates ?? [] };
}

export function pickVoice(voiceFile, n) {
  const v = loadVoice(voiceFile);
  const c = (v.candidates ?? []).find(x => x.n === n) ?? die(`voice.json 的 candidates 沒有 n = ${n}(先跑 design)`);
  v.dseed = c.dseed; writeJson(voiceFile, v);
  return { ok: true, dseed: c.dseed, n };
}

function loadLines(f) {
  const l = readJson(f, '台詞清單');
  if (!l || typeof l !== 'object' || Array.isArray(l)) die('台詞清單要是 {"<key>": "<台詞>"}');
  const bad = Object.keys(l).filter(k => !KEY_RE.test(k) || typeof l[k] !== 'string' || !stripTags(l[k]));
  if (bad.length) die(`台詞 key 不合規或台詞是空的(key 要符合 ${KEY_RE}):${bad.slice(0, 10).join(', ')}`);
  return l;
}

export function lines(voiceFile, { linesFile, out, rawDir: procDir, all = false, max }) {
  const artDir = resolve(dirname(voiceFile), '..', '..');
  const rawDir = join(procDir, 'raw'); // 下載的原檔與 workflows 放過程目錄的 raw/,manifest 放過程目錄
  const v = loadVoice(voiceFile);
  if (v.dseed == null) die('voice.json 還沒選定音色(dseed);先 design、請使用者試聽後 pick');
  const L = loadLines(linesFile), keys = Object.keys(L).sort();
  const has = (k) => existsSync(join(out, `${k}.ogg`)) && existsSync(join(out, `${k}.m4a`));
  const todo = keys.filter(k => all || v.lines?.[k] !== lineHash(v, k, L[k]) || !has(k));
  const now = max != null ? todo.slice(0, max) : todo;
  mkdirSync(rawDir, { recursive: true }); mkdirSync(out, { recursive: true });
  v.lines = v.lines ?? {}; v.line_seeds = v.line_seeds ?? {};
  const mf = join(procDir, 'manifest.json'), manifest = existsSync(mf) ? readJson(mf, 'manifest') : { items: [] };
  let gens = 0; const done = [], failed = [];
  for (const k of now) {
    let seed = lineSeed(v, k), res;
    for (let t = 0; t < TRIES; t++) {
      res = synth(v, { text: stripTags(L[k]), seed, dseed: v.dseed, rawDir, name: k, outDir: out }); gens++;
      manifest.items.push({ key: k, text: L[k], spoken: stripTags(L[k]), seed, dseed: v.dseed, try: t + 1, ok: res.ok, error: res.error, raw: res.raw && relative(artDir, resolve(res.raw)) });
      if (res.ok) break;
      seed = (seed + 1000003) % SEED_MAX;
    }
    if (seed !== lineSeed(v, k)) v.line_seeds[k] = seed;
    if (res.ok) { v.lines[k] = lineHash(v, k, L[k]); done.push(k); } else { delete v.lines[k]; failed.push({ key: k, error: res.error }); }
    writeJson(voiceFile, v); writeJson(mf, manifest); // 每句存一次:中途被中止(Bash 600 秒)時已完成的不用重做,再跑一次會依雜湊略過
  }
  return { ok: !failed.length, generations: gens, redone: done.length, skipped: keys.length - todo.length, deferred: todo.length - now.length, failed, tags_removed: keys.filter(k => stripTags(L[k]) !== L[k].trim()) };
}

export function status(voiceFile, { linesFile, out }) {
  const v = loadVoice(voiceFile), L = loadLines(linesFile);
  const rows = Object.keys(L).sort().map(k => {
    const want = lineHash(v, k, L[k]), ogg = existsSync(join(out, `${k}.ogg`)), m4a = existsSync(join(out, `${k}.m4a`));
    return { key: k, hash: v.lines?.[k] ?? null, current: v.lines?.[k] === want, ogg, m4a };
  });
  const bad = rows.filter(r => !r.current || !r.ogg || !r.m4a);
  return { ok: !bad.length, total: rows.length, outdated: bad.map(r => r.key), dseed: v.dseed ?? null, rows };
}

const isMain = (() => { try { return !!process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } })();
if (isMain) {
  try {
    const [cmd, ...rest] = process.argv.slice(2);
    const f = {};
    for (let i = 0; i < rest.length; i++) { const a = rest[i]; if (['--redesign', '--all'].includes(a)) f[a.slice(2)] = true; else if (a.startsWith('--')) f[a.slice(2)] = rest[++i] ?? die(`${a} 缺值`); else die(`多餘的參數 ${a}`); }
    const vf = f.voice ?? die('缺 --voice <voice.json>');
    const int = (k) => { if (!/^\d+$/.test(String(f[k]))) die(`--${k} 要是正整數`); const n = Number(f[k]); if (n < 1) die(`--${k} 要 ≥ 1`); return n; };
    let r;
    if (cmd === 'design') r = design(vf, { outDir: f['out-dir'] ?? die('缺 --out-dir'), only: int('only'), redesign: !!f.redesign, art: f.art });
    else if (cmd === 'pick') r = pickVoice(vf, int('n'));
    else if (cmd === 'lines') r = lines(vf, { linesFile: f.lines ?? die('缺 --lines'), out: f.out ?? die('缺 --out'), rawDir: f['raw-dir'] ?? die('缺 --raw-dir'), all: !!f.all, max: f.max != null ? int('max') : undefined });
    else if (cmd === 'status') r = status(vf, { linesFile: f.lines ?? die('缺 --lines'), out: f.out ?? die('缺 --out') });
    else die('用法:voice.mjs design | pick | lines | status(見檔頭)');
    console.log(JSON.stringify(r));
    process.exit(r.ok ? 0 : 1);
  } catch (e) {
    console.error(`錯誤:${e instanceof Fail ? e.message : e?.stack || e}`);
    process.exit(e instanceof Fail ? e.code : 2);
  }
}
