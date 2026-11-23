#!/usr/bin/env node
// 用法:
//   node check.mjs --part <parts/模組.json> --root <專案根> [--no-spec-docs]   檢查一個模組(有 _project.json 時讀它的 no_spec_docs,沒有時用旗標)
//   node check.mjs <spec.json> --root <專案根>                檢查合併後的 spec.json
//   node check.mjs --html <index.html> [--spec <spec.json>]   檢查 render 產物(標記、雜湊、無外部資源)
//   node check.mjs --self-test [--shot <shot.mjs>]            檢查 kit 檔案、web-dev-kit shot.mjs、Chrome、node、git
// 來源內容核對:程式來源必附 keyword;有 keyword 的來源(或「引用編號」的測試,找功能編號)要出現在 line(有 end 時 line ~ end,最多 40 行)。
// stdout 一行 JSON {ok, errors[…], …};結束碼 0 通過、1 不通過、2 用法錯誤。
import { readFileSync, existsSync, statSync, realpathSync } from 'node:fs';
import { dirname, join, resolve, basename } from 'node:path';
import { execFileSync } from 'node:child_process';
import { KIT, KIT_DIR, STATUSES, SECTIONS, validateSchema, readJson, sha256File, git, gitRoot, head, relInside, tracked, lineCount, linesText, scanStrings, isMain } from './lib.mjs';

export const MAX_SPAN = 40; // end − line 上限(範圍太寬核對就沒意義)
export const ALL_SIDES = '跨端'; // 測試的 side 寫「跨端」(例如端對端測試)算涵蓋每一端

const CODE_KINDS = new Set(['程式', '測試']);

// ---- 來源 ----
function checkSource(ctx, s, where, fid) {
  const { root, errs } = ctx;
  if (!tracked(root).has(s.path)) { errs.push(`${where}: ${s.path} 不在 git 追蹤中(只認追蹤檔)`); return; }
  const abs = join(root, s.path);
  if (!existsSync(abs) || !statSync(abs).isFile()) { errs.push(`${where}: ${s.path} 在工作目錄不存在`); return; }
  const n = lineCount(abs);
  if (s.line > n) errs.push(`${where}: ${s.path}:${s.line} 超出檔案行數 ${n}`);
  let rangeOk = s.line <= n;
  if (s.end != null && (s.end < s.line || s.end > n)) { errs.push(`${where}: ${s.path} 行範圍 ${s.line}-${s.end} 不合法(檔案 ${n} 行)`); rangeOk = false; }
  else if (s.end != null && s.end - s.line + 1 > MAX_SPAN) { errs.push(`${where}: ${s.path} 行範圍 ${s.line}-${s.end} 超過 ${MAX_SPAN} 行,請指到更精準的位置`); rangeOk = false; }
  if (s.kind === '測試') {
    if (!s.match) errs.push(`${where}: 測試來源要有 match(引用編號 / 關鍵字)`);
    else if (s.match === '關鍵字' && !s.keyword) errs.push(`${where}: match 是關鍵字時要附 keyword`);
  }
  if (s.kind === '測試' && s.match === '引用編號' && !fid && !s.keyword) errs.push(`${where}: 不屬於單一功能的測試來源用「引用編號」時要附 keyword(要核對的編號)`);
  if (s.kind === '程式' && !s.keyword) errs.push(`${where}: 程式來源要附 keyword(那幾行裡的函式名、常數、路由或 UI 字串,check 會核對)`);
  if (!rangeOk) return;
  const to = s.end ?? s.line;
  const text = linesText(abs, s.line, to).toLowerCase();
  const byId = s.kind === '測試' && s.match === '引用編號' && !s.keyword;
  const want = byId ? fid : s.keyword;
  // 功能編號要前後有邊界(FR-091 不能被 FR-091A、FR-0910、FR-091-2 冒充,RPS-1 不能被 FR-RPS-1 冒充);keyword 用包含
  const hit = !want ? true : byId
    ? new RegExp(`(^|[^a-z0-9._-])${want.toLowerCase().replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?![a-z0-9]|[-_.][a-z0-9])`).test(text)
    : text.includes(want.toLowerCase());
  if (!hit) errs.push(`${where}: ${s.path}:${s.line}-${to} 找不到「${want}」(行號或 keyword 不對)`);
}
function checkSources(ctx, list, where, fid) {
  (list ?? []).forEach((s, i) => checkSource(ctx, s, `${where}.sources[${i}]`, fid));
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
  if (!part.code_paths.length) return [];
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
      else if (!(f.sides.includes(s.side) || (s.kind === '測試' && s.side === ALL_SIDES))) errs.push(`${where}.sources[${i}]: side「${s.side}」不在 sides ${JSON.stringify(f.sides)}(端對端測試可標「${ALL_SIDES}」)`);
    }
  }
  const sideHas = (side, k) => src.some(s => s.kind === k && (s.side === side || (k === '測試' && s.side === ALL_SIDES)));
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
      if (!noSpecDocs && !missing('測試').length && !limits.length) errs.push(`${where}: 每端都有程式與測試且沒有「限制」備註,應判「已完成」`);
      break;
    case '未開始': {
      if (!hasSpec) errs.push(`${where}: 未開始要有規格來源`);
      if (kinds('程式').length) errs.push(`${where}: 未開始不可有程式來源`);
      if (kinds('測試').length) errs.push(`${where}: 未開始不可有測試來源(有測試但找不到程式應判「無法判定」)`);
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
  checkSources(ctx, src, where, f.id);
  (f.notes ?? []).forEach((n, i) => checkSources(ctx, n.sources, `${where}.notes[${i}]`, f.id));
}

// scope:grep 用的 part 清單(各自的 code_paths / exclude_paths);_project 的段落逐模組各搜一次,沒有模組時(只檢查 _project)不 grep
function checkSections(ctx, obj, where, scope) {
  for (const sec of SECTIONS) for (const [i, it] of (obj[sec] ?? []).entries()) {
    const w = `${where}.${sec}[${i}]`;
    if (sec === 'mismatches') {
      it.doc.forEach((s, j) => checkSource(ctx, s, `${w}.doc[${j}]`));
      it.code.forEach((s, j) => checkSource(ctx, s, `${w}.code[${j}]`));
      if (!it.code.length) {
        const kws = it.keywords ?? [];
        if (!kws.length) ctx.errs.push(`${w}: 程式那一邊要附來源,或附搜尋過的 keywords`);
        for (const sc of scope ?? []) for (const kw of kws) {
          const hits = grepHits(ctx, sc, kw);
          if (hits.length) ctx.errs.push(`${w}: 說程式找不到,但關鍵字「${kw}」在程式搜尋範圍內找得到(${hits.slice(0, 3).join('、')});要嘛附程式來源,要嘛換關鍵字`);
        }
      }
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
  checkSections(ctx, part, where, [part]);
}

function checkProject(ctx, proj, where, scope) {
  if (proj.commit !== ctx.head) ctx.errs.push(`${where}: commit 不等於 HEAD`);
  for (const p of proj.sources_read) if (!pathExists(ctx.root, p)) ctx.errs.push(`${where}.sources_read: ${p} 不是追蹤檔或含追蹤檔的目錄`);
  checkSections(ctx, proj, where, scope);
}

function ctxFor(root, outAbs) {
  const outRel = relInside(root, outAbs);
  if (!outRel) throw new Error(`輸出目錄 ${outAbs} 不在專案根內`);
  return { root, outRel, head: head(root), errs: [], noSpecDocs: false };
}

export function checkPartFile(file, rootArg, opts = {}) {
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
  // _project.json 只由單批 / 最後一批寫;分批:只寫 parts 的批次可能還沒有它,這時以 --no-spec-docs 旗標為準
  if (existsSync(projFile)) {
    try { ctx.noSpecDocs = !!readJson(projFile)?.product?.no_spec_docs; } catch { return { errors: ['_project.json 不是 JSON'] }; }
  } else ctx.noSpecDocs = !!opts.noSpecDocs;
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
  checkProject(ctx, spec.project, 'project', spec.modules);
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
  // 正文經 render 跳脫(< → &lt;),所以只有真正的標籤會以 < 開頭;CSS 規則只看 <style> 區塊,src / href 只看標籤屬性
  if (/<script\b/i.test(html)) errs.push('不可含 <script>');
  if (/<[a-z][^>]*\son[a-z]+\s*=/i.test(html)) errs.push('不可含 on* 事件屬性(JavaScript)');
  if (/<[a-z][^>]*\s(src|href|action)\s*=\s*["']?\s*javascript:/i.test(html)) errs.push('不可含 javascript: 網址');
  if (/<(link|img|iframe|object|embed|source|video|audio)\b/i.test(html)) errs.push('不可含外部資源標籤(link / img / iframe …)');
  const css = [...html.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style>/gi)].map(m => m[1]).join('\n');
  if (/@import|url\s*\(/i.test(css)) errs.push('CSS 不可用 @import / url()');
  if (/<[a-z][^>]*\s(src|href)\s*=\s*["']?(https?:|\/\/|file:)/i.test(html)) errs.push('不可引用外部網址');
  if (/\sstyle\s*=\s*["'][^"']*url\s*\(/i.test(html)) errs.push('style 屬性不可用 url()');
  return { errors: errs };
}

export function selfTest(shotArg) {
  const errs = [];
  for (const f of ['schemas/spec.schema.json', 'scripts/lib.mjs', 'scripts/check.mjs', 'scripts/merge.mjs', 'scripts/render.mjs', 'scripts/sample.mjs']) {
    if (!existsSync(join(KIT_DIR, f))) errs.push(`kit 缺檔:${join(KIT_DIR, f)}`);
  }
  const shot = shotArg ? resolve(shotArg) : join(realpathSync(KIT_DIR), '..', 'web-dev-kit', 'scripts', 'shot.mjs');
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
  const usage = () => { console.error('用法:check.mjs --part <檔> --root <根> [--no-spec-docs] | <spec.json> --root <根> | --html <index.html> [--spec <spec.json>] | --self-test'); process.exit(2); };
  let r;
  try {
    if (a[0] === '--self-test') r = selfTest(opt('--shot'));
    else if (a[0] === '--html') { if (!a[1]) usage(); r = checkHtmlFile(a[1], opt('--spec')); }
    else if (a[0] === '--part') { if (!a[1] || !opt('--root')) usage(); r = checkPartFile(a[1], opt('--root'), { noSpecDocs: a.includes('--no-spec-docs') }); }
    else if (a[0] && !a[0].startsWith('--')) { if (!opt('--root')) usage(); r = checkSpecFile(a[0], opt('--root')); }
    else usage();
  } catch (e) { r = { errors: [e.message] }; }
  console.log(JSON.stringify({ ok: r.errors.length === 0, ...r }));
  process.exit(r.errors.length ? 1 : 0);
}
