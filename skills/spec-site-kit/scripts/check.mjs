#!/usr/bin/env node
// 用法:
//   node check.mjs --part <parts/模組.json> --root <專案根>     檢查一個模組(同目錄要先有 _project.json)
//   node check.mjs <spec.json> --root <專案根>                檢查合併後的 spec.json
//   node check.mjs --html <index.html> [--spec <spec.json>]   檢查 render 產物(標記、雜湊、無外部資源)
//   node check.mjs --self-test                                檢查 kit 檔案、web-dev-kit shot.mjs、Chrome、node、git
// stdout 一行 JSON {ok, errors[…], …};結束碼 0 通過、1 不通過、2 用法錯誤。
import { readFileSync, existsSync, statSync, realpathSync } from 'node:fs';
import { dirname, join, resolve, basename } from 'node:path';
import { execFileSync } from 'node:child_process';
import { KIT, KIT_DIR, STATUSES, SECTIONS, validateSchema, readJson, sha256File, git, gitRoot, head, relInside, tracked, lineCount, scanStrings, isMain } from './lib.mjs';

const CODE_KINDS = new Set(['程式', '測試']);

// ---- 來源 ----
function checkSource(ctx, s, where) {
  const { root, errs } = ctx;
  if (!tracked(root).has(s.path)) { errs.push(`${where}: ${s.path} 不在 git 追蹤中(只認追蹤檔)`); return; }
  const abs = join(root, s.path);
  if (!existsSync(abs) || !statSync(abs).isFile()) { errs.push(`${where}: ${s.path} 在工作目錄不存在`); return; }
  const n = lineCount(abs);
  if (s.line > n) errs.push(`${where}: ${s.path}:${s.line} 超出檔案行數 ${n}`);
  if (s.end != null && (s.end < s.line || s.end > n)) errs.push(`${where}: ${s.path} 行範圍 ${s.line}-${s.end} 不合法(檔案 ${n} 行)`);
  if (s.kind === '測試') {
    if (!s.match) errs.push(`${where}: 測試來源要有 match(引用編號 / 關鍵字)`);
    else if (s.match === '關鍵字' && !s.keyword) errs.push(`${where}: match 是關鍵字時要附 keyword`);
  }
}
function checkSources(ctx, list, where) {
  (list ?? []).forEach((s, i) => checkSource(ctx, s, `${where}.sources[${i}]`));
}

function pathExists(root, p) {
  const t = tracked(root);
  const pre = p.replace(/\/+$/, '');
  if (t.has(pre)) return true;
  for (const f of t) if (f.startsWith(pre + '/')) return true;
  return false;
}

// 未開始:關鍵字在程式搜尋範圍內必須找不到
function grepHits(ctx, part, kw) {
  const { root, outRel } = ctx;
  const specs = [...part.code_paths, `:(exclude)${outRel}`, ...part.exclude_paths.map(p => `:(exclude)${p}`)];
  try {
    const out = execFileSync('git', ['-C', root, 'grep', '-I', '-F', '-i', '-l', '-e', kw, '--', ...specs], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    return out.split('\n').filter(Boolean);
  } catch (e) {
    if (e.status === 1) return [];
    throw new Error(`git grep 失敗:${(e.stderr || e.message).toString().trim()}`);
  }
}

function checkFeature(ctx, part, f, where) {
  const { errs, noSpecDocs } = ctx;
  const src = f.sources ?? [];
  const kinds = (k) => src.filter(s => s.kind === k);
  const hasSpec = kinds('規格').length > 0;
  const limits = (f.notes ?? []).filter(n => n.type === '限制');
  for (const [i, s] of src.entries()) {
    if (CODE_KINDS.has(s.kind)) {
      if (!s.side) errs.push(`${where}.sources[${i}]: ${s.kind}來源要標 side`);
      else if (!f.sides.includes(s.side)) errs.push(`${where}.sources[${i}]: side「${s.side}」不在 sides ${JSON.stringify(f.sides)}`);
    }
  }
  const sideHas = (side, k) => src.some(s => s.kind === k && s.side === side);
  const missing = (k) => f.sides.filter(side => !sideHas(side, k));
  if (noSpecDocs && ['已完成', '未開始'].includes(f.status)) errs.push(`${where}: 專案無規格文件(no_spec_docs),狀態最多「已實作未測」或「無法判定」`);
  switch (f.status) {
    case '已完成':
      if (!hasSpec) errs.push(`${where}: 已完成要有規格來源`);
      if (missing('程式').length) errs.push(`${where}: 已完成但這些端缺程式來源:${missing('程式').join('、')}`);
      if (missing('測試').length) errs.push(`${where}: 已完成但這些端缺測試來源:${missing('測試').join('、')}`);
      if (limits.length) errs.push(`${where}: 有「限制」備註時狀態最多「已實作未測」`);
      break;
    case '已實作未測':
      if (!hasSpec && !noSpecDocs) errs.push(`${where}: 已實作未測要有規格來源`);
      if (missing('程式').length) errs.push(`${where}: 已實作未測但這些端缺程式來源:${missing('程式').join('、')}(只有部分端有程式應判「無法判定」)`);
      if (!missing('測試').length && !limits.length) errs.push(`${where}: 每端都有程式與測試且沒有「限制」備註,應判「已完成」`);
      break;
    case '未開始': {
      if (!hasSpec) errs.push(`${where}: 未開始要有規格來源`);
      if (kinds('程式').length) errs.push(`${where}: 未開始不可有程式來源`);
      const kws = f.keywords ?? [];
      if (!kws.length) errs.push(`${where}: 未開始要附搜尋過的 keywords`);
      for (const kw of kws) {
        const hits = grepHits(ctx, part, kw);
        if (hits.length) errs.push(`${where}: 關鍵字「${kw}」在程式搜尋範圍內找得到(${hits.slice(0, 3).join('、')}${hits.length > 3 ? ` 等 ${hits.length} 檔` : ''}),不能判未開始`);
      }
      break;
    }
    case '不做':
      if (!f.reason) errs.push(`${where}: 不做要寫 reason(例如「已作廢 → FR-031」「backlog」)`);
      if (!src.length) errs.push(`${where}: 不做要附來源`);
      break;
    case '無法判定':
      if (!f.reason) errs.push(`${where}: 無法判定要寫 reason`);
      break;
  }
  checkSources(ctx, src, where);
  (f.notes ?? []).forEach((n, i) => checkSources(ctx, n.sources, `${where}.notes[${i}]`));
}

function checkSections(ctx, obj, where) {
  for (const sec of SECTIONS) for (const [i, it] of (obj[sec] ?? []).entries()) {
    const w = `${where}.${sec}[${i}]`;
    if (sec === 'mismatches') {
      it.doc.forEach((s, j) => checkSource(ctx, s, `${w}.doc[${j}]`));
      it.code.forEach((s, j) => checkSource(ctx, s, `${w}.code[${j}]`));
      if (!it.code.length && !(it.keywords ?? []).length) ctx.errs.push(`${w}: 程式那一邊要附來源,或附搜尋過的 keywords`);
    } else checkSources(ctx, it.sources, w);
  }
}

function checkPart(ctx, part, where) {
  const { root, errs } = ctx;
  if (part.commit !== ctx.head) errs.push(`${where}: commit ${part.commit.slice(0, 7)} 不等於 HEAD ${ctx.head.slice(0, 7)},這個模組要重做`);
  for (const p of part.code_paths) if (!pathExists(root, p)) errs.push(`${where}.code_paths: ${p} 沒有任何追蹤檔`);
  for (const p of part.exclude_paths) if (!pathExists(root, p)) errs.push(`${where}.exclude_paths: ${p} 沒有任何追蹤檔`);
  checkSources(ctx, part.module.sources, `${where}.module`);
  part.features.forEach((f, i) => checkFeature(ctx, part, f, `${where}.features[${i}](${f.id})`));
  checkSections(ctx, part, where);
}

function checkProject(ctx, proj, where) {
  if (proj.commit !== ctx.head) ctx.errs.push(`${where}: commit 不等於 HEAD`);
  for (const p of proj.sources_read) if (!pathExists(ctx.root, p)) ctx.errs.push(`${where}.sources_read: ${p} 不是追蹤檔或含追蹤檔的目錄`);
  checkSections(ctx, proj, where);
}

function ctxFor(root, outAbs) {
  const outRel = relInside(root, outAbs);
  if (!outRel) throw new Error(`輸出目錄 ${outAbs} 不在專案根內`);
  return { root, outRel, head: head(root), errs: [], noSpecDocs: false };
}

export function checkPartFile(file, rootArg) {
  const root = gitRoot(rootArg);
  if (!root) return { errors: [`${rootArg} 不是 git 工作目錄`] };
  const abs = resolve(file);
  const partsDir = dirname(abs);
  const ctx = ctxFor(root, dirname(partsDir));
  let part;
  try { part = readJson(abs); } catch (e) { return { errors: [`讀不到或不是 JSON:${e.message}`] }; }
  const projFile = join(partsDir, '_project.json');
  if (basename(abs) === '_project.json') {
    const se = validateSchema('project', part);
    if (se.length) return { errors: se };
    checkProject(ctx, part, '_project');
    ctx.errs.push(...scanStrings(part));
    return { errors: ctx.errs };
  }
  if (!existsSync(projFile)) return { errors: [`同目錄缺 _project.json(先寫專案資訊,至少 product 與 sources_read)`] };
  try { ctx.noSpecDocs = !!readJson(projFile)?.product?.no_spec_docs; } catch { return { errors: ['_project.json 不是 JSON'] }; }
  const se = validateSchema('part', part);
  if (se.length) return { errors: se };
  checkPart(ctx, part, part.module.id);
  ctx.errs.push(...scanStrings(part));
  return { errors: ctx.errs, features: part.features.length };
}

export function countStats(modules) {
  const st = { total: 0 };
  for (const s of STATUSES) st[s] = 0;
  for (const m of modules) for (const f of m.features) { st.total++; st[f.status]++; }
  return st;
}

export function checkSpecFile(file, rootArg) {
  const root = gitRoot(rootArg);
  if (!root) return { errors: [`${rootArg} 不是 git 工作目錄`] };
  const abs = resolve(file);
  const ctx = ctxFor(root, dirname(abs));
  let spec;
  try { spec = readJson(abs); } catch (e) { return { errors: [`讀不到或不是 JSON:${e.message}`] }; }
  const se = validateSchema('spec', spec);
  if (se.length) return { errors: se };
  if (spec.commit !== ctx.head) ctx.errs.push(`commit ${spec.commit.slice(0, 7)} 不等於 HEAD ${ctx.head.slice(0, 7)}`);
  ctx.noSpecDocs = spec.project.product.no_spec_docs;
  checkProject(ctx, spec.project, 'project');
  const mids = new Set(); const fids = new Map();
  for (const m of spec.modules) {
    if (mids.has(m.module.id)) ctx.errs.push(`模組 id 重複:${m.module.id}`);
    mids.add(m.module.id);
    for (const f of m.features) {
      if (fids.has(f.id)) ctx.errs.push(`功能編號重複:${f.id}(${fids.get(f.id)}、${m.module.id})`);
      fids.set(f.id, m.module.id);
    }
    checkPart(ctx, m, m.module.id);
  }
  const st = countStats(spec.modules);
  for (const k of Object.keys(st)) if (spec.stats[k] !== st[k]) ctx.errs.push(`stats.${k} = ${spec.stats[k]},實際 ${st[k]}`);
  ctx.errs.push(...scanStrings(spec));
  return { errors: ctx.errs, stats: st };
}

export function checkHtmlFile(file, specArg) {
  const errs = [];
  const specFile = specArg ? resolve(specArg) : join(dirname(resolve(file)), 'spec.json');
  let html;
  try { html = readFileSync(file, 'utf8'); } catch (e) { return { errors: [`讀不到 ${file}:${e.message}`] }; }
  if (!html.includes(`<meta name="generator" content="${KIT}">`)) errs.push('缺產生標記 <meta name="generator">(不是 render.mjs 產生的)');
  const m = /<meta name="spec-sha256" content="([0-9a-f]{64})">/.exec(html);
  if (!m) errs.push('缺 spec-sha256 標記');
  else if (!existsSync(specFile)) errs.push(`找不到 ${specFile}`);
  else if (m[1] !== sha256File(specFile)) errs.push('spec-sha256 與目前 spec.json 不符(spec.json 改過後要重新 render)');
  if (/<script\b/i.test(html)) errs.push('不可含 <script>');
  if (/<(link|img|iframe|object|embed|source|video|audio)\b/i.test(html)) errs.push('不可含外部資源標籤(link / img / iframe …)');
  if (/@import|url\s*\(/i.test(html)) errs.push('CSS 不可用 @import / url()');
  if (/\b(src|href)\s*=\s*["']?(https?:|\/\/|file:)/i.test(html)) errs.push('不可引用外部網址');
  return { errors: errs };
}

export function selfTest() {
  const errs = [];
  for (const f of ['schemas/spec.schema.json', 'scripts/lib.mjs', 'scripts/check.mjs', 'scripts/merge.mjs', 'scripts/render.mjs', 'scripts/sample.mjs']) {
    if (!existsSync(join(KIT_DIR, f))) errs.push(`kit 缺檔:${join(KIT_DIR, f)}`);
  }
  const shot = join(realpathSync(KIT_DIR), '..', 'web-dev-kit', 'scripts', 'shot.mjs');
  if (!existsSync(shot)) errs.push(`找不到 web-dev-kit 的 shot.mjs:${shot}`);
  const chrome = process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  if (!existsSync(chrome)) errs.push(`找不到 Google Chrome:${chrome}(可用 CHROME_PATH 指定)`);
  const major = Number(process.versions.node.split('.')[0]);
  if (major < 22) errs.push(`node 需要 ≥ 22,目前 ${process.versions.node}`);
  try { execFileSync('git', ['--version'], { stdio: 'ignore' }); } catch { errs.push('找不到 git'); }
  return { errors: errs, shot, chrome };
}

if (isMain(import.meta.url)) {
  const a = process.argv.slice(2);
  const opt = (k) => { const i = a.indexOf(k); return i >= 0 ? a[i + 1] : undefined; };
  const usage = () => { console.error('用法:check.mjs --part <檔> --root <根> | <spec.json> --root <根> | --html <index.html> [--spec <spec.json>] | --self-test'); process.exit(2); };
  let r;
  try {
    if (a[0] === '--self-test') r = selfTest();
    else if (a[0] === '--html') { if (!a[1]) usage(); r = checkHtmlFile(a[1], opt('--spec')); }
    else if (a[0] === '--part') { if (!a[1] || !opt('--root')) usage(); r = checkPartFile(a[1], opt('--root')); }
    else if (a[0] && !a[0].startsWith('--')) { if (!opt('--root')) usage(); r = checkSpecFile(a[0], opt('--root')); }
    else usage();
  } catch (e) { r = { errors: [e.message] }; }
  console.log(JSON.stringify({ ok: r.errors.length === 0, ...r }));
  process.exit(r.errors.length ? 1 : 0);
}
