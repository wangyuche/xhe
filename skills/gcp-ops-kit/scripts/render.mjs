#!/usr/bin/env node
// gcp-guardian 報告:run 目錄 → report.html(單一自足 HTML,無外部資源、無 JavaScript、深淺色跟系統)。
//   node render.mjs <run>            產生 report.html
//   node render.mjs --check <run>    檢查:整個 run 目錄無秘密樣式 / 未遮蔽秘密、HTML 無外部資源、統計一致、manual.json 格式
// 結束碼:0 成功、1 檢查失敗、2 用法錯誤
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const KIT = path.dirname(path.dirname(fs.realpathSync(fileURLToPath(import.meta.url))));
const SEV = ['嚴重', '高', '中', '低', '資訊'];
const COUNTED = ['嚴重', '高', '中', '低'];

const readJSON = (p, d = null) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return d; } };
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
// 與 Python shlex.join 相同的引號規則,讓還原指令可以直接複製執行
const shq = (a) => (/^[A-Za-z0-9@%+=:,./_-]+$/.test(a) ? a : `'${String(a).replace(/'/g, `'"'"'`)}'`);
const shjoin = (argv) => (argv || []).map(shq).join(' ');
const sha256 = (p) => crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');

function load(run) {
  const meta = readJSON(path.join(run, 'meta.json'), {});
  const findings = readJSON(path.join(run, 'findings.json'), []);
  const manual = readJSON(path.join(run, 'manual.json'), []);
  const planPath = path.join(run, 'plan.json');
  const plan = readJSON(planPath, { items: [] });
  const planSha = fs.existsSync(planPath) ? sha256(planPath) : null;
  const und = readJSON(path.join(run, 'inventory', 'undetermined.json'), []);
  const change = readJSON(path.join(run, 'change.json'), null);
  return { meta, findings, manual, plan, planSha, und, change };
}

function allFindings(d) {
  const m = (d.manual || []).map((x) => ({ ...x, source: 'manual' }));
  return [...d.findings, ...m].sort((a, b) => SEV.indexOf(a.severity) - SEV.indexOf(b.severity) || String(a.rule_id).localeCompare(String(b.rule_id)));
}

function stats(d) {
  const s = Object.fromEntries(SEV.map((k) => [k, 0]));
  for (const f of allFindings(d)) s[f.severity] = (s[f.severity] || 0) + 1;
  s['無法判定'] = d.und.length;
  return s;
}

function status(d, s) {
  if (d.meta.mode === 'change') return d.change?.status || 'BLOCKED';
  if (d.meta.mode === 'plan') {
    const items = d.plan.items || [];
    return items.some((i) => i.blocked_reason || i.loosens_security) || !items.length ? 'ISSUES' : 'PASS';
  }
  return COUNTED.slice(0, 3).some((k) => s[k] > 0) || s['無法判定'] > 0 ? 'ISSUES' : 'PASS';
}

function diffPrev(d, all) {
  let prev = d.meta.prev;
  if (!prev) return null;
  try {
    prev = fs.realpathSync(prev);
    if (!prev.startsWith(reportDir() + path.sep) || !fs.existsSync(path.join(prev, 'meta.json'))) return null;
  } catch { return null; }
  const pd = load(prev);
  const key = (f) => `${f.rule_id}|${f.resource}`;
  const now = new Set(all.map(key));
  const before = new Set(allFindings(pd).map(key));
  return {
    prev,
    added: all.filter((f) => !before.has(key(f))),
    fixed: allFindings(pd).filter((f) => !now.has(key(f))),
    still: all.filter((f) => before.has(key(f))),
  };
}

const CSS = `
:root{color-scheme:light dark;--bg:#fbfbfa;--fg:#1d1d1f;--muted:#6b6b70;--line:#e3e3e0;--card:#fff;
--crit:#b3261e;--high:#c25400;--med:#8a6d00;--low:#3d6e9e;--info:#6b6b70;--ok:#1e7a46;--warn:#a15c00}
@media (prefers-color-scheme:dark){:root{--bg:#141416;--fg:#ececee;--muted:#a0a0a8;--line:#2c2c31;--card:#1c1c20;
--crit:#ff8a80;--high:#ffab66;--med:#e6c84f;--low:#8fb8e8;--info:#a0a0a8;--ok:#6fd39b;--warn:#f0b35a}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.55 -apple-system,"PingFang TC","Noto Sans TC",system-ui,sans-serif}
main{max-width:1120px;margin:0 auto;padding:32px 20px 64px}
h1{font-size:24px;margin:0 0 4px}h2{font-size:18px;margin:36px 0 12px;padding-bottom:6px;border-bottom:1px solid var(--line)}
.sub{color:var(--muted);font-size:13px}.mono,code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12.5px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:10px;margin-top:18px}
.tile{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px}
.tile b{display:block;font-size:26px;line-height:1.1}.tile span{color:var(--muted);font-size:12px}
.status{display:inline-block;padding:2px 10px;border-radius:999px;font-weight:600;font-size:13px;border:1px solid currentColor}
.PASS{color:var(--ok)}.ISSUES{color:var(--warn)}.BLOCKED{color:var(--crit)}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:10px;overflow:hidden}
th,td{text-align:left;vertical-align:top;padding:8px 10px;border-bottom:1px solid var(--line)}th{font-size:12px;color:var(--muted);font-weight:600}
tr:last-child td{border-bottom:0}
.sev{font-weight:700;white-space:nowrap}.s-嚴重{color:var(--crit)}.s-高{color:var(--high)}.s-中{color:var(--med)}.s-低{color:var(--low)}.s-資訊{color:var(--info)}
details summary{cursor:pointer;color:var(--muted);font-size:13px}pre{white-space:pre-wrap;word-break:break-all;margin:6px 0}
.flag{display:inline-block;font-size:12px;font-weight:600;padding:1px 8px;border-radius:6px;margin:2px 4px 2px 0;border:1px solid currentColor}
.f-block{color:var(--crit)}.f-loose{color:var(--warn)}.f-ok{color:var(--ok)}
.note{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--warn);border-radius:8px;padding:10px 14px;margin:12px 0}
`;

function evidenceHTML(f) {
  const e = f.evidence || {};
  const loc = [e.file, e.line ? `:${e.line}` : '', e.index !== undefined ? ` [${e.index}]` : ''].join('');
  return `<div class="mono">${esc(loc)}</div><div class="mono">${esc(e.path || '')}</div>${e.value !== undefined ? `<div class="mono">值:${esc(e.value)}</div>` : ''}`;
}

function findingsTable(list) {
  if (!list.length) return '<p class="sub">沒有發現。</p>';
  const rows = list.map((f) => `<tr><td class="sev s-${esc(f.severity)}">${esc(f.severity)}</td>
<td><div class="mono">${esc(f.rule_id)}</div>${f.cis ? `<div class="sub">${esc(f.cis)}</div>` : ''}</td>
<td><b>${esc(f.title)}</b>${f.detail ? `<div class="sub">${esc(f.detail)}</div>` : ''}<div class="mono">${esc(f.resource)}</div>
${f.reason ? `<div class="sub">判定理由:${esc(f.reason)}</div>` : ''}</td>
<td>${evidenceHTML(f)}</td><td>${esc(f.fix)}${f.plan_id ? `<div class="mono">→ ${esc(f.plan_id)}</div>` : ''}</td></tr>`).join('\n');
  return `<table><thead><tr><th>嚴重度</th><th>規則</th><th>問題 / 資源</th><th>證據</th><th>修正方式</th></tr></thead><tbody>${rows}</tbody></table>`;
}

function planSection(d) {
  const items = d.plan.items || [];
  if (!items.length) return '<p class="sub">沒有變更計畫。</p>';
  const rows = items.map((i) => {
    const flags = [];
    if (i.blocked_reason) flags.push(`<span class="flag f-block">BLOCKED</span>`);
    if (i.loosens_security) flags.push(`<span class="flag f-loose">放寬安全</span>`);
    if (!i.blocked_reason && !i.loosens_security) flags.push(`<span class="flag f-ok">可執行</span>`);
    if (i.reversible === false) flags.push(`<span class="flag f-block">不可還原</span>`);
    return `<tr><td class="mono"><b>${esc(i.id)}</b></td><td>${flags.join('')}
${i.blocked_reason ? `<div class="sub">${esc(i.blocked_reason)}</div>` : ''}
${(i.loosens_reasons || []).map((r) => `<div class="sub">⚠ ${esc(r)}</div>`).join('')}</td>
<td><b>${esc(i.summary)}</b><div class="sub">${esc(i.kind || '-')}${i.finding ? ` · ${esc(i.finding)}` : ''} · 影響:${esc(i.impact || '-')}</div>
<pre class="mono">${esc(shjoin(i.command))}</pre>
${i.manifest ? `<details><summary>manifest</summary><pre class="mono">${esc(i.manifest)}</pre></details>` : ''}
${i.patch ? `<details><summary>patch</summary><pre class="mono">${esc(i.patch)}</pre></details>` : ''}</td>
<td><div class="sub">dry-run:${esc(i.dry_run || '無法 dry-run')}</div>
${(i.dry_run_log || []).map((l) => `<details><summary>${esc(l.step)}(rc=${esc(l.rc)})</summary><pre class="mono">${esc(l.out || '')}</pre></details>`).join('')}
<div class="sub">還原:</div><pre class="mono">${esc(i.rollback ? shjoin(i.rollback) : '（無)')}</pre>
<details><summary>precondition / expected</summary><pre class="mono">${esc(JSON.stringify({ precondition: i.precondition, auto: i.auto_pre, expected: i.expected }, null, 1))}</pre></details></td></tr>`;
  }).join('\n');
  return `<p class="sub">plan.json sha256:<span class="mono">${esc(d.planSha)}</span>。每條都要使用者逐條核准才會執行;標「放寬安全」的條目請特別確認。</p>
<table><thead><tr><th>編號</th><th>狀態</th><th>內容</th><th>dry-run / 還原</th></tr></thead><tbody>${rows}</tbody></table>`;
}

function changeSection(d) {
  const c = d.change;
  if (!c) return '';
  const rows = (c.results || []).map((r) => `<tr><td class="mono"><b>${esc(r.id)}</b></td><td>${esc(r.result)}</td><td>${esc(r.reason || '')}</td>
<td class="mono">${esc(r.rc ?? '-')}</td><td><pre class="mono">${esc(shjoin(r.rollback) || '-')}</pre></td></tr>`).join('\n');
  return `<h2>變更結果</h2><p class="sub">計畫 <span class="mono">${esc(c.plan)}</span>(sha256 ${esc(String(c.sha256).slice(0, 16))}…),核准 ${esc((c.approved || []).join(', '))}。不自動還原;需要時由使用者依還原指令執行。</p>
<table><thead><tr><th>編號</th><th>結果</th><th>原因 / 驗證</th><th>結束碼</th><th>還原指令</th></tr></thead><tbody>${rows}</tbody></table>`;
}

function reportDir() {
  const cfgPath = process.env.GG_CONFIG || path.join(process.env.HOME || '', '.config', 'gcp-guardian', 'config');
  let dir = path.join(process.env.HOME || '', 'gcp-guardian-reports');
  try {
    for (const line of fs.readFileSync(cfgPath, 'utf8').split('\n')) {
      const m = line.match(/^\s*GG_REPORT_DIR\s*=\s*(.*?)\s*$/);
      if (m) dir = m[1].replace(/^["']|["']$/g, '').replace(/^~(?=\/|$)/, process.env.HOME || '');
    }
  } catch { /* 沒有設定檔用預設 */ }
  return fs.realpathSync(dir);
}

function assertRun(run) {
  const real = fs.realpathSync(run);
  if (!real.startsWith(reportDir() + path.sep) || !fs.existsSync(path.join(real, 'meta.json'))) {
    console.error(`拒絕:${run} 不是 GG_REPORT_DIR 底下的 run 目錄`);
    process.exit(2);
  }
  return real;
}

export function render(run) {
  run = assertRun(run);
  const d = load(run);
  const all = allFindings(d);
  const s = stats(d);
  const st = status(d, s);
  const diff = diffPrev(d, all);
  const m = d.meta;
  const modeName = { review: '審查', yaml: 'YAML 審查', plan: '計畫', change: '變更' }[m.mode] || m.mode;
  const tiles = [...COUNTED, '無法判定'].map((k) => `<div class="tile"><b class="${k === '無法判定' ? '' : 's-' + k}">${s[k]}</b><span>${k}</span></div>`).join('');
  const und = d.und.length ? `<table><thead><tr><th>範圍</th><th>項目</th><th>原始錯誤</th></tr></thead><tbody>${d.und.map((u) => `<tr><td>${esc(u.area)}</td><td class="mono">${esc(u.item)}</td><td class="mono">${esc(u.error)}</td></tr>`).join('')}</tbody></table>` : '<p class="sub">無。</p>';
  const diffHTML = diff ? `<h2>與上次差異</h2><p class="sub">上次:<span class="mono">${esc(diff.prev)}</span></p>
<p>新增 ${diff.added.length} · 已修復 ${diff.fixed.length} · 仍存在 ${diff.still.length}</p>
<details><summary>新增</summary>${findingsTable(diff.added)}</details><details><summary>已修復</summary>${findingsTable(diff.fixed)}</details>` : '';
  const statsJSON = JSON.stringify(s);
  const html = `<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>gcp-guardian ${esc(modeName)} · ${esc(m.project || '')}</title><style>${CSS}</style></head><body><main>
<!-- gg-stats ${statsJSON} -->
<!-- gg-plan-sha256 ${d.planSha || "none"} -->
<h1>gcp-guardian ${esc(modeName)}報告</h1>
<div class="sub">${esc(m.project || '')} · ${esc(m.started || '')} · SA ${esc(m.sa || '（未使用)')}</div>
<p><span class="status ${st}">狀態:${st}</span></p>
${(m.sa_roles || []).some((r) => /^roles\/(owner|editor)$|admin$/i.test(r)) ? `<div class="note">這個 SA 有寫入權限(${esc(m.sa_roles.join(', '))})。審查、計畫模式只執行唯讀白名單內的指令;變更只執行使用者逐條核准的條目。</div>` : ''}
<div class="tiles">${tiles}</div>
${changeSection(d)}
<h2>變更計畫</h2>${planSection(d)}
<h2>問題(${all.length})</h2>${findingsTable(all)}
${diffHTML}
<h2>無法判定</h2>${und}
<h2>範圍</h2><pre class="mono">${esc(JSON.stringify({ mode: m.mode, areas: m.areas, clusters: m.clusters, inputs: m.inputs, kustomize: m.kustomize, documents: m.documents }, null, 1))}</pre>
<p class="sub">嚴重度:嚴重=外部可直接存取資料或取得控制權/秘密外洩;高=取得一個內部身分即可擴大到專案或叢集;中=違反最小權限或縱深防禦;低=衛生與可維運性;資訊不計入。報告含資安敏感內容,只存本機。</p>
</main></body></html>
`;
  const out = path.join(run, 'report.html');
  fs.writeFileSync(out, html, { mode: 0o600 });
  return { out, status: st, stats: s };
}

// ---------------------------------------------------------------- --check
const PATTERNS = readJSON(path.join(KIT, 'rules', 'secret_patterns.json')).patterns.map((p) => new RegExp(p));

function* walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) yield* walk(p);
    else if (e.isFile()) yield p;
  }
}

function unredacted(obj, where, errs, inInventory) {
  if (Array.isArray(obj)) { obj.forEach((x) => unredacted(x, where, errs, inInventory)); return; }
  if (!obj || typeof obj !== 'object') return;
  if (obj.kind === 'Secret') {
    for (const f of ['data', 'stringData']) {
      for (const [k, v] of Object.entries(obj[f] || {})) if (!String(v).startsWith('<redacted')) errs.push(`${where}: Secret ${f}.${k} 未遮蔽`);
    }
  }
  if (inInventory && obj.kind === 'ConfigMap') {
    for (const [k, v] of Object.entries(obj.data || {})) if (!String(v).startsWith('<redacted')) errs.push(`${where}: ConfigMap data.${k} 未遮蔽`);
  }
  if (inInventory && Array.isArray(obj.env)) {
    for (const e of obj.env) if (e && 'value' in e && !String(e.value).startsWith('<redacted')) errs.push(`${where}: env ${e.name} 未遮蔽`);
  }
  for (const v of Object.values(obj)) unredacted(v, where, errs, inInventory);
}

export function check(run) {
  const errs = [];
  const html = path.join(run, 'report.html');
  if (!fs.existsSync(html)) errs.push('缺 report.html');
  for (const f of ['meta.json']) if (!fs.existsSync(path.join(run, f))) errs.push(`缺 ${f}`);
  const meta = readJSON(path.join(run, 'meta.json'), {});
  if (['review', 'yaml', 'plan'].includes(meta.mode)) for (const f of ['findings.json', 'plan.json']) if (!fs.existsSync(path.join(run, f))) errs.push(`缺 ${f}`);
  for (const p of ['gcloud', 'kubeconfig']) if (fs.existsSync(path.join(run, p))) errs.push(`run 目錄仍留有 ${p}(憑證快取)`);
  for (const p of walk(run)) {
    const rel = path.relative(run, p);
    if (/^before\/C\d+\.rollback\.json$/.test(rel)) continue; // 還原用原始物件(權限 600,見 SKILL.md)
    const st = fs.statSync(p);
    if (st.size > 50 * 1024 * 1024) { errs.push(`${rel}: 檔案過大未掃描`); continue; }
    const text = fs.readFileSync(p, 'utf8');
    for (const re of PATTERNS) if (re.test(text)) errs.push(`${rel}: 命中秘密樣式 ${re.source}`);
    if (rel.startsWith('inventory/') && !rel.endsWith('.json') && !rel.endsWith('.log')) errs.push(`${rel}: inventory 只能有遮蔽後的 JSON`);
    if (rel.endsWith('.json')) {
      const obj = readJSON(p);
      if (obj !== null) unredacted(obj, rel, errs, rel.startsWith('inventory/'));
    }
    if (rel.startsWith('inventory/k8s/') && rel.endsWith('/secrets.json')) {
      for (const it of readJSON(p, {}).items || []) {
        const extra = Object.keys(it).filter((k) => !['namespace', 'name', 'type', 'keys'].includes(k));
        if (extra.length) errs.push(`${rel}: Secret metadata 含多餘欄位 ${extra}`);
      }
    }
  }
  if (fs.existsSync(html)) {
    const h = fs.readFileSync(html, 'utf8');
    if (/<script\b/i.test(h)) errs.push('HTML 含 <script>');
    if (/(src|href)\s*=\s*["']?\s*(https?:)?\/\//i.test(h) || /@import|url\(\s*["']?(https?:)?\/\//i.test(h)) errs.push('HTML 含外部資源');
    const m = h.match(/<!-- gg-stats (\{.*?\}) -->/);
    const d = load(run);
    if (!m) errs.push('HTML 缺 gg-stats');
    else if (JSON.stringify(JSON.parse(m[1])) !== JSON.stringify(stats(d))) errs.push(`統計不一致:HTML ${m[1]} vs 檔案 ${JSON.stringify(stats(d))}`);
    if (d.planSha && !h.includes(d.planSha)) errs.push('HTML 的 plan sha256 與 plan.json 不符(要重新 render)');
  }
  const manual = readJSON(path.join(run, 'manual.json'), null);
  if (manual !== null) {
    if (!Array.isArray(manual)) errs.push('manual.json 要是陣列');
    else manual.forEach((f, i) => {
      if (!/^MANUAL-\d+$/.test(f.rule_id || '')) errs.push(`manual.json[${i}] rule_id 要是 MANUAL-<n>`);
      if (!SEV.includes(f.severity)) errs.push(`manual.json[${i}] severity 不對`);
      for (const k of ['title', 'resource', 'evidence', 'fix', 'reason']) if (!f[k]) errs.push(`manual.json[${i}] 缺 ${k}`);
    });
  }
  return errs;
}

const args = process.argv.slice(2);
if (process.argv[1] && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url))) {
  if (args[0] === '--check' && args[1]) {
    const errs = check(assertRun(path.resolve(args[1])));
    if (errs.length) { console.error(errs.map((e) => 'CHECK FAIL ' + e).join('\n')); process.exit(1); }
    console.log('check ok');
  } else if (args[0] && !args[0].startsWith('-')) {
    const r = render(path.resolve(args[0]));
    console.log(`report=${r.out}`);
    console.log(`status=${r.status} stats=${JSON.stringify(r.stats)}`);
  } else {
    console.error('用法:node render.mjs <run> | --check <run>');
    process.exit(2);
  }
}
