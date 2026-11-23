#!/usr/bin/env node
// 用法:node render.mjs <spec.json> [<輸出.html>](預設同目錄 index.html)
// 從 spec.json 產生單一自足 HTML:無外部資源、無 JavaScript、深淺色跟系統。段落與欄位固定,不含任何專案品牌樣式。
// 產物含 <meta name="generator"> 與 <meta name="spec-sha256">,check.mjs --html 用來確認和 spec.json 一致。
// 先跑 check.mjs 通過再 render。stdout 一行 JSON;結束碼 0、讀檔失敗 1、用法錯誤 2。
import { writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { KIT, STATUSES, readJson, sha256File, validateSchema, isMain } from './lib.mjs';

const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
const STATUS_CLASS = { '已完成': 'done', '已實作未測': 'untested', '未開始': 'todo', '不做': 'wont', '無法判定': 'unknown' };
const SEC_TITLE = { flows: '主要流程', rules: '規則與數值', pending: '待決事項', mismatches: '文件與程式不一致', out_of_scope: '範圍外', tech: '技術重點' };

const loc = (s) => `${s.path}:${s.line}${s.end ? `-${s.end}` : ''}`;
function srcList(list) {
  if (!list?.length) return '';
  return `<ul class="src">${list.map(s => `<li><span class="kind">${esc(s.kind)}${s.side ? `・${esc(s.side)}` : ''}</span> <code>${esc(loc(s))}</code>${s.match || s.keyword ? ` <span class="muted">(${[s.match, s.keyword].filter(Boolean).map(esc).join(':')})</span>` : ''}${s.note ? ` <span class="muted">${esc(s.note)}</span>` : ''}</li>`).join('')}</ul>`;
}
const srcDetails = (list, label = '來源') => list?.length ? `<details><summary>${label}(${list.length})</summary>${srcList(list)}</details>` : '';
const badge = (st) => `<span class="badge ${STATUS_CLASS[st]}">${esc(st)}</span>`;

function feature(f) {
  const notes = (f.notes ?? []).map(n => `<p class="note ${n.type === '限制' ? 'limit' : 'wip'}"><b>${esc(n.type)}</b>${n.branch ? `(${esc(n.branch)})` : ''}:${esc(n.text)}</p>${srcDetails(n.sources, '備註來源')}`).join('');
  return `<li class="feat" id="f-${esc(f.id)}">
<div class="fhead">${badge(f.status)} <code class="fid">${esc(f.id)}</code>${f.page_id ? '<span class="muted">(本頁編號)</span>' : ''} <b>${esc(f.name)}</b></div>
<p>${esc(f.summary)}</p>
<p class="muted">涉及:${f.sides.map(esc).join('、')}</p>
${f.reason ? `<p class="reason"><b>原因</b>:${esc(f.reason)}</p>` : ''}
${f.keywords?.length ? `<p class="muted">搜尋過的關鍵字:${f.keywords.map(k => `<code>${esc(k)}</code>`).join(' ')}</p>` : ''}
${notes}${srcDetails(f.sources)}</li>`;
}

function statsBar(st) {
  if (!st.total) return '';
  return `<div class="bar" role="img" aria-label="${STATUSES.map(s => `${s} ${st[s]}`).join(',')}">${STATUSES.filter(s => st[s]).map(s => `<span class="${STATUS_CLASS[s]}" style="width:${(st[s] / st.total * 100).toFixed(2)}%"></span>`).join('')}</div>`;
}
const countOf = (features) => { const c = { total: features.length }; for (const s of STATUSES) c[s] = features.filter(f => f.status === s).length; return c; };

function sectionItems(sec, items) {
  if (!items.length) return '<p class="muted">無</p>';
  if (sec === 'flows') return items.map(({ it, mod }) => `<div class="card"><h4>${esc(it.name)}${mod ? ` <span class="muted">— ${esc(mod)}</span>` : ''}</h4><ol>${it.steps.map(s => `<li>${esc(s)}</li>`).join('')}</ol>${srcDetails(it.sources)}</div>`).join('');
  if (sec === 'mismatches') return `<ul class="items">${items.map(({ it, mod }) => `<li><p>${esc(it.text)}${mod ? ` <span class="muted">— ${esc(mod)}</span>` : ''}${it.origin ? ` <span class="muted">(出處:${esc(it.origin)})</span>` : ''}</p>${srcDetails(it.doc, '文件那邊')}${it.code.length ? srcDetails(it.code, '程式那邊') : `<p class="muted">程式那邊:找不到(搜尋過 ${(it.keywords ?? []).map(k => `<code>${esc(k)}</code>`).join(' ')})</p>`}</li>`).join('')}</ul>`;
  if (sec === 'pending') {
    return ['使用者', '開發'].map(d => {
      const xs = items.filter(x => x.it.decider === d);
      return `<h4>由${d}決定(${xs.length})</h4>${xs.length ? `<ul class="items">${xs.map(({ it, mod }) => `<li><p>${esc(it.text)}${mod ? ` <span class="muted">— ${esc(mod)}</span>` : ''}</p>${srcDetails(it.sources)}</li>`).join('')}</ul>` : '<p class="muted">無</p>'}`;
    }).join('');
  }
  return `<ul class="items">${items.map(({ it, mod }) => `<li><p>${esc(it.text)}${mod ? ` <span class="muted">— ${esc(mod)}</span>` : ''}</p>${srcDetails(it.sources)}</li>`).join('')}</ul>`;
}

const CSS = `
:root{color-scheme:light dark;--bg:#fff;--fg:#1f2328;--muted:#656d76;--line:#d0d7de;--card:#f6f8fa;
--done:#1a7f37;--untested:#9a6700;--todo:#57606a;--wont:#8c959f;--unknown:#cf222e}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--muted:#9198a1;--line:#30363d;--card:#161b22;
--done:#3fb950;--untested:#d29922;--todo:#8b949e;--wont:#6e7681;--unknown:#f85149}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.6 -apple-system,BlinkMacSystemFont,"PingFang TC","Noto Sans TC","Microsoft JhengHei",sans-serif;overflow-wrap:anywhere}
main{max-width:1080px;margin:0 auto;padding:24px 16px 64px}
h1{font-size:1.7em;margin:0 0 4px}h2{font-size:1.3em;margin:40px 0 12px;padding-bottom:6px;border-bottom:1px solid var(--line)}
h3{font-size:1.1em;margin:28px 0 8px}h4{margin:16px 0 6px}
p{margin:4px 0}code{font:0.88em ui-monospace,SFMono-Regular,Menlo,monospace}
.muted{color:var(--muted)}.warn{border-left:4px solid var(--untested);padding:6px 10px;background:var(--card);margin:8px 0}
nav{display:flex;flex-wrap:wrap;gap:6px 14px;margin:16px 0;font-size:.95em}nav a{color:inherit}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:8px;margin:12px 0}
.tile{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px}
.tile b{display:block;font-size:1.5em}
.bar{display:flex;height:10px;border-radius:5px;overflow:hidden;background:var(--line);margin:6px 0}
.bar span{display:block;height:100%}
.bar .done,.badge.done{background:var(--done)}.bar .untested,.badge.untested{background:var(--untested)}
.bar .todo,.badge.todo{background:var(--todo)}.bar .wont,.badge.wont{background:var(--wont)}.bar .unknown,.badge.unknown{background:var(--unknown)}
.badge{color:#fff;border-radius:10px;padding:1px 8px;font-size:.8em;white-space:nowrap}
.modrow{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,2fr);gap:4px 12px;align-items:center;padding:4px 0;border-bottom:1px solid var(--line)}
@media (max-width:600px){.modrow{grid-template-columns:minmax(0,1fr)}}
ul.feats,ul.items{list-style:none;padding:0;margin:0}
.feat,ul.items>li,.card{border:1px solid var(--line);border-radius:8px;padding:10px 12px;margin:8px 0;background:var(--bg)}
.card{background:var(--card)}
.fhead{display:flex;flex-wrap:wrap;gap:6px;align-items:baseline}
.note{margin:6px 0;padding:4px 8px;border-radius:6px;background:var(--card)}
.note.limit{border-left:3px solid var(--untested)}.note.wip{border-left:3px solid var(--todo)}
.reason{color:var(--unknown)}
details{margin:4px 0}summary{cursor:pointer;color:var(--muted);font-size:.9em}
ul.src{margin:4px 0;padding-left:18px;font-size:.88em}
.kind{color:var(--muted)}
footer{margin-top:48px;font-size:.88em;color:var(--muted)}
`;

export function render(specFile, outFile) {
  const spec = readJson(specFile);
  const se = validateSchema('spec', spec);
  if (se.length) throw new Error(`spec.json 格式不對(先跑 check.mjs):${se.slice(0, 3).join(';')}`);
  const sha = sha256File(specFile);
  const p = spec.project.product;
  const st = spec.stats;
  const collect = (sec) => [
    ...(spec.project[sec] ?? []).map(it => ({ it, mod: null })),
    ...spec.modules.flatMap(m => (m[sec] ?? []).map(it => ({ it, mod: m.module.name }))),
  ];
  const secs = ['flows', 'rules', 'pending', 'mismatches', 'out_of_scope', 'tech'];
  const html = `<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="generator" content="${KIT}">
<meta name="spec-sha256" content="${sha}">
<title>${esc(p.name)} 產品規格</title>
<style>${CSS}</style>
</head>
<body><main>
<header>
<h1>${esc(p.name)} 產品規格</h1>
<p>${esc(p.summary)}</p>
<p class="muted">版本 <code>${esc(spec.commit.slice(0, 7))}</code>(${esc(spec.branch)})・產生於 ${esc(spec.generated_at.replace('T', ' ').replace('Z', ' UTC'))}・範圍:${esc(p.scope)}</p>
${spec.dirty ? '<p class="warn">含未 commit 修改:行號以產生當時的工作目錄為準。</p>' : ''}
${p.no_spec_docs ? '<p class="warn">這個專案沒有規格文件:功能從程式與 README 推得,狀態最多「已實作未測」。</p>' : ''}
</header>
<nav><a href="#progress">完成度</a><a href="#modules">模組與功能</a>${secs.map(s => `<a href="#${s}">${SEC_TITLE[s]}</a>`).join('')}<a href="#read">讀過的來源</a></nav>

<section id="progress"><h2>完成度</h2>
<div class="tiles"><div class="tile"><span class="muted">功能總數</span><b>${st.total}</b></div>${STATUSES.map(s => `<div class="tile"><span class="muted">${s}</span><b>${st[s]}</b></div>`).join('')}</div>
${statsBar(st)}
<h3>各模組</h3>
${spec.modules.map(m => { const c = countOf(m.features); return `<div class="modrow"><div><a href="#m-${esc(m.module.id)}">${esc(m.module.name)}</a> <span class="muted">${c.total} 項・已完成 ${c['已完成']}</span></div>${statsBar(c)}</div>`; }).join('')}
<p class="muted">狀態定義:已完成 = 規格、每個涉及端的程式與測試都找得到;已實作未測 = 有程式但缺測試,或文件說還是預覽 / 未上線;未開始 = 有規格、程式找不到;不做 = 規格寫不做、backlog、已作廢;無法判定 = 證據矛盾或對不上。</p>
</section>

<section id="modules"><h2>模組與功能</h2>
${spec.modules.map(m => `<section id="m-${esc(m.module.id)}"><h3>${esc(m.module.name)} <span class="muted">(${esc(m.module.id)})</span></h3>
<p>${esc(m.module.summary)}</p>${srcDetails(m.module.sources, '模組來源')}
<ul class="feats">${m.features.map(feature).join('')}</ul></section>`).join('')}
</section>

${secs.map(s => `<section id="${s}"><h2>${SEC_TITLE[s]}</h2>${sectionItems(s, collect(s))}</section>`).join('\n')}

<section id="read"><h2>讀過的來源</h2><ul class="src">${spec.project.sources_read.map(x => `<li><code>${esc(x)}</code></li>`).join('')}</ul></section>
<footer>由 ${KIT} 從 spec.json 產生;spec.json sha256 <code>${sha.slice(0, 12)}</code>。這一頁只整理現況,不代表產品決定。</footer>
</main></body>
</html>
`;
  writeFileSync(outFile, html);
  return { out: outFile, sha256: sha, bytes: Buffer.byteLength(html) };
}

if (isMain(import.meta.url)) {
  const [s, o] = process.argv.slice(2);
  if (!s) { console.error('用法:render.mjs <spec.json> [<輸出.html>]'); process.exit(2); }
  try {
    const r = render(resolve(s), resolve(o ?? join(dirname(resolve(s)), 'index.html')));
    console.log(JSON.stringify({ ok: true, ...r }));
  } catch (e) { console.log(JSON.stringify({ ok: false, errors: [e.message] })); process.exit(1); }
}
