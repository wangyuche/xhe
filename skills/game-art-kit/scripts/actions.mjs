#!/usr/bin/env node
// game-art-kit:角色動作圖(立繪級的表情 / 姿勢集,不是動畫格),用 Codex(使用者 ChatGPT 方案額度)出圖。純 Node。
// 設定檔 actions.json(放 art/characters/<id>/actions/,格式見 SKILL.md「角色動作」);路徑一律相對 art/(--art 預設 = 設定檔往上三層)。
// 用法:
//   node actions.mjs prompt --config <actions.json> --action <id>      → 印這個動作送給 Codex 的提示詞
//   node actions.mjs gen    --config <actions.json> --action <id> --out-dir <過程目錄> --budget <累計檔> --limit <M> --run <派工 id> [--timeout 540]
//        出一張候選 → <過程目錄>/<動作>-<n>.png(n 自動往上編號,不覆蓋);追加 <過程目錄>/manifest.json。
//        codex exec --skip-git-repo-check --ephemeral -s read-only -C <空暫存目錄> --json -o <回覆檔> - -i <底圖>(子程序環境拿掉 OPENAI_API_KEY / CODEX_API_KEY);
//        先確認 `codex login status` 是 ChatGPT 登入(否則結束碼 2,不送出);每張先在累計檔記 1 張(超過 --limit → 結束碼 6,不送出)。
//        --json 事件白名單:item 只允許 agent_message、reasoning;出現其他類型(指令執行、檔案讀寫、web_search、mcp_tool_call…)→ 不採用、結束碼 7(要停止剩下的動作)。
//        圖從 $CODEX_HOME/generated_images/<thread id>/(預設 ~/.codex)抄出,核對雜湊後刪掉該 thread 目錄(thread id 要是 UUID 樣式、realpath 在 generated_images 底下)。
//        manifest 不記本機絕對路徑($HOME、/Users/<名>、/home/<名> 換成 ~,generated_images 路徑換成 <codex>)。
//   node actions.mjs masks  --config <actions.json> --out <masks.png> [--image <png>]   anchor 預覽:黃十字 = 頭中心、橘框 = 頭像範圍(--image 預設底圖)
//   node actions.mjs sheet  --out <sheet.png> <底圖> <候選>... [--tile 360] [--cols N]   候選對照表(左上 = 底圖,其餘照參數順序)
// 結束碼:0 成功;2 用法 / 設定錯誤 / 不是 ChatGPT 登入;3 Codex 沒出圖(印 error 事件;"quota":true = 額度 / 用量上限,要停止);4 逾時(已殺整個程序群組);
//        6 超過張數上限(沒送出);7 Codex 用了白名單以外的工具(不採用,停止剩下的動作)。
import { spawn, spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync, existsSync, readdirSync, statSync, copyFileSync, realpathSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve, basename, sep } from 'node:path';
import { tmpdir, homedir } from 'node:os';
import { decodePng, encodePng, blank, resample } from './sprite.mjs';
import { openBudget, BudgetError } from './budget.mjs';

class Fail extends Error { constructor(m, c = 2, extra) { super(m); this.code = c; this.extra = extra; } }
const die = (m, c = 2, extra) => { throw new Fail(m, c, extra); };
const KIT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const TEMPLATE = JSON.parse(readFileSync(join(KIT, 'templates', 'character-actions.json'), 'utf8'));
const load = (f) => { let b; try { b = readFileSync(f); } catch (e) { die(`讀不到 ${f}:${e.message}`); } return decodePng(b); };
const save = (f, img) => { mkdirSync(dirname(f), { recursive: true }); writeFileSync(f, encodePng(img)); };
export const ALLOWED_ITEMS = new Set(['agent_message', 'reasoning', 'todo_list', 'error']); // 不是工具的 item(規劃清單、錯誤訊息)
// 出圖工具本身(實測 codex 0.172 不會出現在事件裡;之後的版本若發出 image_generation 類 item 也算允許)
const allowedItem = (t) => ALLOWED_ITEMS.has(t) || /^image_gen/.test(String(t));
// 違規事件只記類型與指令,不記指令輸出(輸出可能含金鑰);再遮蔽常見金鑰樣式
export const redactSecrets = (s) => String(s ?? '').replace(/(sk[-_][A-Za-z0-9_-]{6})[A-Za-z0-9_-]+/g, '$1…').replace(/((?:xi-)?api[-_]?key|token|secret|password|authorization)(["']?\s*[=:]\s*["']?)[^\s"',]+/gi, '$1$2<redacted>').replace(/\b[0-9a-f]{32,}\b/gi, '<hex>');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CODEX_TASK = `Generate exactly one image with your built-in image generation tool. Do not draw it with code and do not edit the attached image with scripts.
Do not run any commands, do not read, save, copy or change any file, do not search the web: just generate the image, then reply with only the word "done".
The attached image is the reference (model sheet). Follow the instructions below exactly.

---

`;

// ---------- 設定 ----------
export function loadConfig(file, artDir) {
  let c; try { c = JSON.parse(readFileSync(file, 'utf8')); } catch (e) { die(`設定檔 ${file} 讀不到或不是 JSON:${e.message}`); }
  const art = artDir ? resolve(artDir) : resolve(dirname(file), '..', '..', '..');
  for (const k of ['name', 'pronoun', 'base', 'style', 'features', 'outfit']) if (c[k] == null) die(`actions.json 缺 ${k}`);
  if (!TEMPLATE.pronouns[c.pronoun]) die(`pronoun 只能是 ${Object.keys(TEMPLATE.pronouns).join(' / ')}`);
  if (/^\/|^[A-Za-z]:|\.\./.test(c.base)) die('base 要寫相對 art/ 的路徑(不寫本機絕對路徑、不用 ..)');
  return { c, art, basePath: join(art, c.base) };
}
const anchorOf = (c) => { const a = c.anchor ?? die('actions.json 缺 anchor({x,y,h},頭中心與頭高 0–1)'); if (![a.x, a.y, a.h].every(v => typeof v === 'number' && v > 0 && v <= 1)) die('anchor 的 x、y、h 都要是 0–1 的數字'); return a; };
const fill = (s, vars) => s.replace(/\{(\w+)\}/g, (m, k) => vars[k] ?? m);
export function prompt(c, id) {
  const t = TEMPLATE.actions.find(a => a.id === id), o = c.actions?.[id] ?? {};
  if (!t && !(o.expr && o.pose)) die(`動作 ${id} 不在範本裡,actions.json 的 actions.${id} 要自己給 expr 與 pose`);
  const pr = TEMPLATE.pronouns[c.pronoun];
  const expr = fill(o.expr ?? t.expr, pr), pose = fill(o.pose ?? t.pose, pr);
  return fill(TEMPLATE.codex, { name: c.name, features: c.features, outfit: c.outfit, style: c.style, hands: c.hands ?? TEMPLATE.hands, expr, pose, allowed: o.extra ? ` except ${o.extra}` : '' });
}

// ---------- 路徑遮蔽(manifest 不留本機絕對路徑)----------
export function scrubPaths(s, codexHome) {
  let out = String(s ?? '');
  if (codexHome) out = out.split(join(codexHome, 'generated_images')).join('<codex>');
  const home = homedir(); if (home && home.length > 1) out = out.split(home).join('~');
  return out.replace(/\/(Users|home)\/[^/\s"']+/g, '~');
}

// ---------- Codex ----------
const codexExe = () => process.env.CODEX_EXE || 'codex';
export function loginMode() {
  const r = spawnSync(codexExe(), ['login', 'status'], { encoding: 'utf8', env: cleanEnv() });
  if (r.error) die(`找不到 codex(${r.error.code}):安裝 Codex CLI 並用 ChatGPT 帳號登入(codex login)`);
  const out = `${r.stdout}\n${r.stderr}`;
  return /Logged in using ChatGPT/i.test(out) ? 'chatgpt' : /api key/i.test(out) ? 'apikey' : /not logged in/i.test(out) ? 'none' : 'unknown';
}
function cleanEnv() { const e = { ...process.env }; delete e.OPENAI_API_KEY; delete e.CODEX_API_KEY; return e; }

function runCodex(text, ref, timeoutSec) {
  const work = mkdtempSync(join(tmpdir(), 'gak-codex-')), last = join(work, 'last.txt'), cwd = join(work, 'cwd'); mkdirSync(cwd);
  return new Promise((done) => {
    const p = spawn(codexExe(), ['exec', '--skip-git-repo-check', '--ephemeral', '-s', 'read-only', '-C', cwd, '--json', '-o', last, '-', '-i', ref],
      { env: cleanEnv(), detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '', err = '', timedOut = false;
    p.stdout.on('data', d => out += d); p.stderr.on('data', d => err += d);
    const timer = setTimeout(() => { timedOut = true; try { process.kill(-p.pid, 'SIGTERM'); } catch { /* */ } setTimeout(() => { try { process.kill(-p.pid, 'SIGKILL'); } catch { /* */ } }, 5000); }, timeoutSec * 1000);
    p.on('error', (e) => { clearTimeout(timer); rmSync(work, { recursive: true, force: true }); done({ spawnError: e }); });
    p.on('close', (code) => {
      clearTimeout(timer);
      const reply = existsSync(last) ? readFileSync(last, 'utf8').trim() : '';
      rmSync(work, { recursive: true, force: true });
      done({ code, out, err, reply, timedOut });
    });
    p.stdin.end(CODEX_TASK + text);
  });
}
export function parseEvents(out) {
  const ev = out.replace(/^﻿/, '').split('\n').filter(l => l.trim().startsWith('{')).map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  const thread = ev.find(e => e.type === 'thread.started')?.thread_id ?? null;
  const usage = ev.find(e => e.type === 'turn.completed')?.usage ?? null;
  const violations = ev.filter(e => e.item && !allowedItem(e.item.type)).map(e => ({ type: e.item.type, detail: redactSecrets(String(e.item.command ?? e.item.query ?? e.item.tool ?? e.item.server ?? e.item.path ?? (Array.isArray(e.item.changes) ? e.item.changes.map(c => c.path).join(', ') : '')).slice(0, 200)) }));
  const errors = [...new Set(ev.filter(e => e.type === 'error' || e.type === 'turn.failed').map(e => redactSecrets(e.message ?? e.error?.message ?? JSON.stringify(e).slice(0, 300))))];
  return { thread, usage, violations, errors };
}
function threadDir(codexHome, thread) {
  if (!thread || !UUID.test(thread)) return null;
  const root = join(codexHome, 'generated_images'), dir = join(root, thread);
  if (!existsSync(dir)) return null;
  try { const r = realpathSync(dir), rr = realpathSync(root); return r.startsWith(rr + sep) ? r : null; } catch { return null; }
}
const sha = (f) => createHash('sha256').update(readFileSync(f)).digest('hex');
const nextN = (outDir, action) => { let n = 1; while (existsSync(join(outDir, `${action}-${n}.png`))) n++; return n; };
function appendManifest(outDir, entry) {
  const f = join(outDir, 'manifest.json');
  const m = existsSync(f) ? JSON.parse(readFileSync(f, 'utf8')) : { items: [] };
  m.items.push(entry); mkdirSync(outDir, { recursive: true }); writeFileSync(f, JSON.stringify(m, null, 1) + '\n');
}

export async function gen(cfgFile, { action, outDir, budget, limit, run, art, timeout = 540 }) {
  const { c, basePath } = loadConfig(cfgFile, art);
  if (!existsSync(basePath)) die(`底圖 ${c.base} 不存在`);
  if (!run) die('缺 --run <派工 id>');
  const mode = loginMode(); if (mode !== 'chatgpt') die(`codex 不是用 ChatGPT 登入(${mode}):為了只用 ChatGPT 方案額度、不走 API 計費,請改用 ChatGPT 帳號登入(codex login)`);
  const text = prompt(c, action);
  const b = openBudget(budget, limit, '張');
  const used = b.reserve(1, `codex ${action}`); // 送出前先記;超過上限丟 BudgetError(結束碼 6)
  const codexHome = process.env.CODEX_HOME || join(homedir(), '.codex');
  // 先佔好檔名(wx 獨佔建立),同一個動作平行出圖不會撞號;沒出圖就刪掉佔位檔
  mkdirSync(outDir, { recursive: true });
  let n = nextN(outDir, action);
  for (;; n++) { try { writeFileSync(join(outDir, `${action}-${n}.png`), '', { flag: 'wx' }); break; } catch (e) { if (e.code !== 'EEXIST') throw e; } }
  const r = await runCodex(text, basePath, timeout);
  if (r.spawnError) { rmSync(join(outDir, `${action}-${n}.png`), { force: true }); appendManifest(outDir, { run, action, status: `跑不了 codex:${r.spawnError.code ?? ''}`, budget_used: used, budget_limit: limit }); die(`跑不了 codex:${r.spawnError.message}`, 3); }
  const ev = parseEvents(r.out), file = `${action}-${n}.png`;
  const dir = threadDir(codexHome, ev.thread);
  const made = dir ? readdirSync(dir).filter(f => f.endsWith('.png')).map(f => join(dir, f)).sort((a, b2) => statSync(a).mtimeMs - statSync(b2).mtimeMs) : [];
  const entry = { run, action, n, file, prompt: text, thread: ev.thread, reply: redactSecrets(scrubPaths(r.reply, codexHome)).slice(0, 500), usage: ev.usage, violations: ev.violations.map(v => ({ type: v.type, detail: scrubPaths(v.detail, codexHome) })), budget_used: used, budget_limit: limit };
  let status, code = 0, cleaned = false;
  try {
    if (r.timedOut) { status = '逾時'; code = 4; }
    else if (ev.violations.length) { status = '不符合(Codex 用了白名單以外的工具)'; code = 7; }
    else if (!made.length) { status = '沒出圖'; code = 3; }
    else {
      mkdirSync(outDir, { recursive: true });
      const src = made[made.length - 1], dst = join(outDir, file);
      copyFileSync(src, dst);
      if (sha(src) !== sha(dst)) die('抄出的圖雜湊不符', 3);
      status = 'ok'; entry.images = made.length; entry.sha256 = sha(dst).slice(0, 16);
    }
  } finally {
    // 不論成敗,只要 thread id 合法就刪掉 Codex 留下的圖(不留副本)
    if (dir) { rmSync(dir, { recursive: true, force: true }); cleaned = true; }
    entry.status = status ?? '失敗'; entry.thread_cleaned = cleaned;
    if (status !== 'ok') rmSync(join(outDir, file), { force: true }); // 佔位檔
    if (code === 3) entry.errors = ev.errors.map(e => scrubPaths(e, codexHome).slice(0, 300));
    appendManifest(outDir, entry);
  }
  const quota = code === 3 && ev.errors.some(e => /quota|usage limit|rate limit|limit reached|credits/i.test(e));
  const res = { ok: code === 0, status: entry.status, file: code === 0 ? join(outDir, file) : null, action, n, thread: ev.thread, thread_cleaned: cleaned, violations: entry.violations, errors: entry.errors, quota, budget: { used, limit } };
  if (code) die(`${entry.status}${ev.errors.length ? ':' + entry.errors?.join(' / ') : ''}`, code, res);
  return res;
}

// ---------- 預覽 / 對照表 ----------
export function maskPreview(cfgFile, { image, out, art }) {
  const { c, basePath } = loadConfig(cfgFile, art);
  const src = load(image ?? basePath), W = src.width, H = src.height;
  const img = blank(W, H), d = img.data;
  for (let i = 0; i < W * H; i++) { const a = src.data[i * 4 + 3] / 255; for (let k = 0; k < 3; k++) d[i * 4 + k] = Math.round((src.data[i * 4 + k] * a + 128 * (1 - a)) * 0.6); d[i * 4 + 3] = 255; }
  const box = (x0, y0, x1, y1, rgb, t = 3) => { for (let y = Math.max(0, Math.floor(y0)); y < Math.min(H, Math.ceil(y1)); y++) for (let x = Math.max(0, Math.floor(x0)); x < Math.min(W, Math.ceil(x1)); x++) if (x - x0 < t || x1 - x <= t || y - y0 < t || y1 - y <= t) { const o = (y * W + x) * 4; d[o] = rgb[0]; d[o + 1] = rgb[1]; d[o + 2] = rgb[2]; } };
  const { x, y, h } = anchorOf(c), cx = x * W, cy = y * H, side = h * H * (c.avatar_zoom ?? 1.15);
  box(cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2, [255, 150, 30]);
  box(cx - 14, cy - 2, cx + 14, cy + 2, [255, 230, 0], 3); box(cx - 2, cy - 14, cx + 2, cy + 14, [255, 230, 0], 3);
  save(out, img);
  return { file: out, width: W, height: H, legend: '黃十字 = anchor 頭中心、橘框 = 頭像範圍' };
}

export function sheet(files, { out, tile = 360, cols }) {
  if (!files.length) die('sheet 至少要一張圖');
  const imgs = files.map(f => { const i = load(f); const w = Math.round(i.width * tile / i.height); return resample(i, 0, 0, i.width, i.height, w, tile); });
  const C = cols ?? Math.ceil(Math.sqrt(imgs.length)), R = Math.ceil(imgs.length / C), cw = Math.max(...imgs.map(i => i.width)), gap = 8;
  const s = blank(C * (cw + gap) + gap, R * (tile + gap) + gap); for (let i = 0; i < s.data.length; i += 4) { s.data[i] = s.data[i + 1] = s.data[i + 2] = 48; s.data[i + 3] = 255; }
  imgs.forEach((im, k) => { const ox = gap + (k % C) * (cw + gap) + Math.floor((cw - im.width) / 2), oy = gap + Math.floor(k / C) * (tile + gap);
    for (let y = 0; y < im.height; y++) for (let x = 0; x < im.width; x++) { const o = (y * im.width + x) * 4, a = im.data[o + 3] / 255, t = ((oy + y) * s.width + ox + x) * 4; for (let c = 0; c < 3; c++) s.data[t + c] = Math.round(im.data[o + c] * a + 140 * (1 - a)); } });
  save(out, s);
  return { file: out, columns: C, rows: R, order: files.map(f => basename(f)) };
}

// ---------- CLI ----------
const isMain = (() => { try { return !!process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } })();
if (isMain) {
  try {
    const [cmd, ...rest] = process.argv.slice(2);
    const f = {}, pos = [];
    for (let i = 0; i < rest.length; i++) { const a = rest[i]; if (a.startsWith('--')) f[a.slice(2)] = rest[++i] ?? die(`${a} 缺值`); else pos.push(a); }
    const cfg = () => f.config ?? die('缺 --config <actions.json>');
    const int = (k, def) => { const v = f[k] ?? def; if (v == null) die(`缺 --${k}`); if (!/^\d+$/.test(String(v)) || Number(v) < 1) die(`--${k} 要是正整數`); return Number(v); };
    let r;
    if (cmd === 'prompt') r = { prompt: prompt(loadConfig(cfg(), f.art).c, f.action ?? die('缺 --action')) };
    else if (cmd === 'gen') {
      if (f.engine && f.engine !== 'codex') die('--engine 目前只有 codex');
      r = await gen(cfg(), { action: f.action ?? die('缺 --action'), outDir: f['out-dir'] ?? die('缺 --out-dir'), budget: f.budget, limit: f.limit != null ? int('limit') : undefined, run: f.run, art: f.art, timeout: int('timeout', 540) });
    }
    else if (cmd === 'masks') r = maskPreview(cfg(), { image: f.image, out: f.out ?? die('缺 --out'), art: f.art });
    else if (cmd === 'sheet') r = sheet(pos, { out: f.out ?? die('缺 --out'), tile: int('tile', 360), cols: f.cols != null ? int('cols') : undefined });
    else die('用法:actions.mjs prompt | gen | masks | sheet(見檔頭)');
    console.log(JSON.stringify(r));
  } catch (e) {
    if (e instanceof Fail && e.extra) console.log(JSON.stringify(e.extra));
    console.error(`錯誤:${e instanceof Fail || e instanceof BudgetError ? e.message : e?.stack || e}`);
    process.exit(e instanceof Fail || e instanceof BudgetError ? e.code : 2);
  }
}
