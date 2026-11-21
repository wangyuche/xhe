#!/usr/bin/env node
// 用法:node render.mjs <卡片.json> <輸出目錄> [--asset-root <目錄>]
// 用內建版型把卡片渲染成 1080×1920 PNG(Chrome headless + CDP)。
//   版型:title、point、code、end(不透明全版)、subtitle、headline(透明疊圖)、cover(標題;有 image 時疊在圖片上)。
//   內容一律用 textContent 放入(不解析 HTML);圖片只接受 --asset-root 內的相對路徑,以 data URL 嵌入;
//   所有網路請求都會被擋掉並計數。
//   subtitle:最多 2 行,字級 64→44 px 自動縮小;文字框必須在 x∈[60,930]、y∈[1300,1620],
//   放不下結束碼 4。所有 subtitle 的框寫進 <輸出目錄>/boxes.json。
// stdout 一行 JSON:{"files":[…],"subtitles":N,"blockedRequests":[…]}
// 結束碼:0 成功、1 錯誤、2 參數錯誤、4 字幕放不下。
import { readFileSync, writeFileSync, mkdirSync, realpathSync, existsSync, statSync } from 'node:fs';
import { resolve, join, extname, isAbsolute, sep, basename } from 'node:path';
import { launchChrome, guardNetwork } from './_chrome.mjs';
import { checkTheme, THEMED_TYPES } from './_theme.mjs';

const W = 1080, H = 1920;
export const SAFE = { x0: 60, x1: 930, y0: 1300, y1: 1620 };

function usage(msg) {
  if (msg) console.error(`錯誤:${msg}`);
  console.error('用法:node render.mjs <卡片.json> <輸出目錄> [--asset-root <目錄>]');
  process.exit(2);
}

const args = process.argv.slice(2);
if (args.length < 2) usage();
const [specPath, outArg] = args;
let assetRoot = null;
for (let i = 2; i < args.length; i++) {
  if (args[i] === '--asset-root') assetRoot = args[++i] ?? usage('--asset-root 缺值');
  else usage(`未知參數:${args[i]}`);
}
const outDir = resolve(outArg);
mkdirSync(outDir, { recursive: true });

let spec;
try { spec = JSON.parse(readFileSync(specPath, 'utf8')); } catch (e) { usage(`讀不到卡片 JSON:${e.message}`); }
const cards = Array.isArray(spec) ? spec : spec.cards;
if (!Array.isArray(cards) || cards.length === 0) usage('卡片 JSON 要有 cards 陣列');
// 沒有預設配色:每支影片依來源(repo 的 logo / 網站 / 文件配色,或影片畫面)自己選 theme。
// 只有字幕卡、有 image 的封面不用 theme。
const themedTypes = [...new Set(cards.filter(Boolean).map(c => (c.type === 'cover' ? (c.image ? null : 'cover-plain') : c.type)).filter(t => THEMED_TYPES.includes(t)))];
const needsTheme = themedTypes.length > 0;
// 不需要 theme 時(只有字幕卡、有圖封面)忽略 theme,不檢查格式。
const theme = needsTheme ? ((Array.isArray(spec) ? undefined : spec.theme) ?? {}) : {};
if (needsTheme && Array.isArray(spec)) usage('有 title / point / code / end / headline 卡或漸層封面時,要用 {"theme":{…},"cards":[…]} 物件格式(陣列格式放不了 theme)');
let contrast = null;
if (needsTheme) {
  const t = checkTheme(theme, themedTypes);
  if (t.error) usage(t.error);
  contrast = t.contrast;
}

const TYPES = new Set(['title', 'point', 'code', 'end', 'subtitle', 'headline', 'cover']);
const MIME = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp', '.svg': 'image/svg+xml' };
const rootReal = assetRoot ? realpathSync(resolve(assetRoot)) : null;

function loadImage(rel, where) {
  if (!rootReal) throw new Error(`${where}:沒有 --asset-root,不接受圖片`);
  if (typeof rel !== 'string' || !rel || isAbsolute(rel) || /^[a-z][a-z0-9+.-]*:/i.test(rel)) {
    throw new Error(`${where}:圖片只能是 --asset-root 內的相對路徑:${rel}`);
  }
  const p = resolve(rootReal, rel);
  if (!existsSync(p)) throw new Error(`${where}:找不到圖片 ${rel}`);
  const real = realpathSync(p);
  if (real !== rootReal && !real.startsWith(rootReal + sep)) throw new Error(`${where}:圖片在 --asset-root 外:${rel}`);
  const mime = MIME[extname(real).toLowerCase()];
  if (!mime) throw new Error(`${where}:不支援的圖片格式 ${extname(real)}`);
  if (statSync(real).size > 15 * 1024 * 1024) throw new Error(`${where}:圖片超過 15 MB`);
  return `data:${mime};base64,${readFileSync(real).toString('base64')}`;
}

// 驗證卡片並準備資料(圖片轉 data URL)
const jobs = cards.map((c, i) => {
  const where = `cards[${i}]`;
  if (!c || !TYPES.has(c.type)) throw usage(`${where}.type 必須是 ${[...TYPES].join(' / ')}`);
  const file = c.file ?? `${String(i + 1).padStart(3, '0')}-${c.type}.png`;
  if (basename(file) !== file || !file.endsWith('.png')) usage(`${where}.file 只能是 .png 檔名(不含路徑):${file}`);
  const data = {};
  for (const k of ['title', 'subtitle', 'body', 'text', 'text2', 'path', 'code', 'url', 'tag', 'number', 'lang']) {
    if (c[k] !== undefined && c[k] !== null) data[k] = String(c[k]);
  }
  if (c.image !== undefined) {
    try { data.image = loadImage(c.image, where); } catch (e) { console.error(`錯誤:${e.message}`); process.exit(1); }
  }
  if (c.type === 'subtitle' && !data.text) usage(`${where}:subtitle 需要 text`);
  if (c.type === 'code' && !data.code) usage(`${where}:code 需要 code`);
  return { type: c.type, file, data };
});

const PAGE = `<!doctype html><html><head><meta charset="utf-8"><style>
:root{--bg:${theme.bg};--bg2:${theme.bg2};--fg:${theme.fg};--accent:${theme.accent};--muted:${theme.muted}}
*{box-sizing:border-box;margin:0;padding:0}
html,body{width:${W}px;height:${H}px;background:transparent;overflow:hidden}
body{font-family:"PingFang TC","Heiti TC","Hiragino Sans",sans-serif;color:var(--fg);-webkit-font-smoothing:antialiased}
#stage{position:absolute;inset:0}
.full{position:absolute;inset:0;background:linear-gradient(160deg,var(--bg) 0%,var(--bg2) 100%);padding:180px 170px 340px 72px;display:flex;flex-direction:column;justify-content:center;gap:40px}
.tag{font-size:36px;color:var(--accent);font-weight:600;letter-spacing:2px}
.t1{font-size:96px;font-weight:800;line-height:1.2;word-break:break-word}
.t2{font-size:48px;color:var(--muted);line-height:1.4;word-break:break-word}
.num{width:110px;height:110px;border-radius:28px;background:var(--accent);color:var(--bg);font-size:64px;font-weight:800;display:flex;align-items:center;justify-content:center}
.pt{font-size:76px;font-weight:800;line-height:1.25;word-break:break-word}
.body{font-size:46px;line-height:1.5;color:var(--fg);opacity:.92;word-break:break-word}
.img{max-width:100%;max-height:620px;object-fit:contain;border-radius:24px;align-self:flex-start;background:#fff1}
.codewrap{background:#0008;border:2px solid #fff2;border-radius:24px;overflow:hidden}
.codehead{font:600 30px Menlo,monospace;color:var(--muted);padding:22px 28px;border-bottom:2px solid #fff2;word-break:break-all}
pre{font:30px/1.45 Menlo,monospace;padding:24px 28px;white-space:pre-wrap;word-break:break-all;color:#e2e8f0}
.k{color:#c084fc}.s{color:#86efac}.c{color:#64748b;font-style:italic}.n{color:#fbbf24}
.url{font:600 40px Menlo,monospace;color:var(--accent);word-break:break-all}
.subwrap{position:absolute;left:${SAFE.x0}px;width:${SAFE.x1 - SAFE.x0}px;bottom:${H - SAFE.y1 + 20}px;text-align:center}
.sub{display:inline-block;text-wrap:balance;overflow:hidden;background:rgba(0,0,0,.62);border-radius:18px;padding:14px 26px;font-weight:700;line-height:1.3;color:#fff;word-break:break-word;text-shadow:0 2px 6px #000a;max-width:100%}
.sub2{display:block;font-weight:500;color:#fde68a;margin-top:6px}
.head{position:absolute;left:60px;right:170px;top:220px;text-align:left}
.head span{display:inline;background:var(--accent);color:var(--bg);font-size:68px;font-weight:800;line-height:1.5;padding:6px 18px;box-decoration-break:clone;-webkit-box-decoration-break:clone;border-radius:12px}
.cover{position:absolute;inset:0;background:#000}
.cover img{width:100%;height:100%;object-fit:cover}
.cover.plain{background:linear-gradient(160deg,var(--bg) 0%,var(--bg2) 60%,var(--accent) 140%)}
.cover .shade{position:absolute;inset:0;background:linear-gradient(180deg,#000c 0%,#0000 45%,#0000 70%,#000a 100%)}
.cover:not(.plain) .ct,.cover:not(.plain) .tag{color:#fff}
.cover .ct{position:absolute;left:72px;right:170px;top:260px;font-size:104px;font-weight:900;line-height:1.2;text-shadow:0 4px 18px #000;word-break:break-word}
</style></head><body><div id="stage"></div><script>
const KW=new Set('const let var function return if else for while do switch case break continue new class extends import from export default async await try catch finally throw typeof instanceof in of func package type struct interface go defer select chan map range def self lambda yield with as pass raise None True False null undefined true false public private static void int string bool fn pub mut impl use mod match enum'.split(' '));
function el(tag,cls,text){const e=document.createElement(tag);if(cls)e.className=cls;if(text!==undefined)e.textContent=text;return e}
function highlight(pre,code){
  const re=/(\\/\\/.*$|#.*$|\\/\\*.*?\\*\\/)|("(?:[^"\\\\]|\\\\.)*"|'(?:[^'\\\\]|\\\\.)*'|\`[^\`]*\`)|(\\b\\d+(?:\\.\\d+)?\\b)|([A-Za-z_][A-Za-z0-9_]*)/gm;
  let last=0,m;
  while((m=re.exec(code))){
    if(m.index>last)pre.appendChild(document.createTextNode(code.slice(last,m.index)));
    if(m[1])pre.appendChild(el('span','c',m[1]));else if(m[2])pre.appendChild(el('span','s',m[2]));
    else if(m[3])pre.appendChild(el('span','n',m[3]));else if(KW.has(m[4]))pre.appendChild(el('span','k',m[4]));
    else pre.appendChild(document.createTextNode(m[4]));
    last=re.lastIndex;
  }
  if(last<code.length)pre.appendChild(document.createTextNode(code.slice(last)));
}
async function waitImgs(root){await Promise.all([...root.querySelectorAll('img')].map(i=>i.complete?0:new Promise(r=>{i.onload=i.onerror=r})));await document.fonts.ready}
async function render(type,d,safe){
  const st=document.getElementById('stage');st.textContent='';
  const r={};
  if(type==='title'||type==='end'){
    const f=el('div','full');
    if(d.tag)f.appendChild(el('div','tag',d.tag));
    f.appendChild(el('div','t1',d.title??''));
    if(d.subtitle)f.appendChild(el('div','t2',d.subtitle));
    if(type==='end'&&d.url)f.appendChild(el('div','url',d.url));
    if(d.image){const i=el('img','img');i.src=d.image;f.appendChild(i)}
    st.appendChild(f);
  }else if(type==='point'){
    const f=el('div','full');
    if(d.number)f.appendChild(el('div','num',d.number));
    f.appendChild(el('div','pt',d.title??''));
    if(d.body)f.appendChild(el('div','body',d.body));
    if(d.image){const i=el('img','img');i.src=d.image;f.appendChild(i)}
    st.appendChild(f);
  }else if(type==='code'){
    const f=el('div','full');f.style.gap='32px';
    if(d.title)f.appendChild(el('div','pt',d.title));
    const w=el('div','codewrap');
    if(d.path)w.appendChild(el('div','codehead',d.path));
    const lines=d.code.replace(/\\t/g,'  ').split('\\n');
    let code=lines.slice(0,15).join('\\n');if(lines.length>15)code+='\\n…';
    r.codeLines=Math.min(lines.length,15);r.truncated=lines.length>15;
    const pre=el('pre');highlight(pre,code);w.appendChild(pre);f.appendChild(w);st.appendChild(f);
  }else if(type==='headline'){
    const h=el('div','head');h.appendChild(el('span','',d.text??d.title??''));st.appendChild(h);
  }else if(type==='cover'){
    const c=el('div',d.image?'cover':'cover plain');if(d.image){const i=el('img');i.src=d.image;c.appendChild(i);c.appendChild(el('div','shade'))}
    if(d.tag){const tg=el('div','tag',d.tag);tg.style.cssText='position:absolute;left:72px;top:190px';c.appendChild(tg)}
    c.appendChild(el('div','ct',d.title??''));st.appendChild(c);
  }else if(type==='subtitle'){
    const wrap=el('div','subwrap');const box=el('span','sub');const t=el('span','',d.text.replace(/(\w)-(?=\w)/g,'$1\u2011'));box.appendChild(t);
    let t2=null;if(d.text2){t2=el('span','sub2',d.text2);box.appendChild(t2)}
    wrap.appendChild(box);st.appendChild(wrap);
    await document.fonts.ready;
    let fit=null;
    // 依序嘗試:單行(64→48 px)→ 兩行且只在標點 / 空格斷(keep-all)→ 兩行一般斷行;都放不下就失敗
    const tries=[{max:1,wb:'normal',min:48},{max:2,wb:'keep-all',min:44},{max:2,wb:'normal',min:44}];
    outer: for(const tr of tries){
      box.style.wordBreak=tr.wb;
      for(let fs=64;fs>=tr.min;fs-=2){
        box.style.fontSize=fs+'px';if(t2)t2.style.fontSize=Math.round(fs*0.72)+'px';
        const lines=Math.max(1,t.getClientRects().length);
        const b=box.getBoundingClientRect();
        const overflow=box.scrollWidth>box.clientWidth+1;
        const m={fontSize:fs,lines,x:Math.round(b.left),y:Math.round(b.top),w:Math.round(b.width),h:Math.round(b.height)};
        if(!overflow&&lines<=tr.max&&b.left>=safe.x0-0.5&&b.right<=safe.x1+0.5&&b.top>=safe.y0-0.5&&b.bottom<=safe.y1+0.5){fit=m;break outer}
        r.last=m;
      }
    }
    r.fit=fit;
  }
  await waitImgs(st);
  return r;
}
</script></body></html>`;

let cdp;
const result = { files: [], subtitles: 0, blockedRequests: [], ...(contrast ? { contrast } : {}) };
let exitCode = 0;
try {
  cdp = await launchChrome();
  const stats = await guardNetwork(cdp, (u) => u.startsWith('data:'));
  await cdp.send('Page.enable'); await cdp.send('Runtime.enable');
  await cdp.send('Emulation.setDeviceMetricsOverride', { width: W, height: H, deviceScaleFactor: 1, mobile: false });
  await cdp.send('Emulation.setDefaultBackgroundColorOverride', { color: { r: 0, g: 0, b: 0, a: 0 } });
  const { frameTree } = await cdp.send('Page.getFrameTree');
  await cdp.send('Page.setDocumentContent', { frameId: frameTree.frame.id, html: PAGE });
  await new Promise(r => setTimeout(r, 150));

  const boxes = [];
  for (const job of jobs) {
    const ev = await cdp.send('Runtime.evaluate', {
      expression: `render(${JSON.stringify(job.type)}, ${JSON.stringify(job.data)}, ${JSON.stringify(SAFE)}).then(r => JSON.stringify(r))`,
      awaitPromise: true, returnByValue: true,
    });
    if (ev.exceptionDetails) throw new Error(`版型 ${job.type} 執行失敗:${ev.exceptionDetails.exception?.description ?? ev.exceptionDetails.text}`);
    const info = JSON.parse(ev.result.value);
    if (job.type === 'subtitle') {
      result.subtitles++;
      if (!info.fit) {
        console.error(`錯誤:字幕放不下(最多 2 行、字級 44 px 仍超出安全區):${job.file}「${job.data.text}」最後量到 ${JSON.stringify(info.last)},請拆句`);
        exitCode = 4; continue;
      }
      boxes.push({ file: job.file, ...info.fit });
    }
    const shot = await cdp.send('Page.captureScreenshot', { format: 'png', clip: { x: 0, y: 0, width: W, height: H, scale: 1 } });
    writeFileSync(join(outDir, job.file), Buffer.from(shot.data, 'base64'));
    result.files.push(join(outDir, job.file));
    if (info.truncated) console.error(`注意:${job.file} 程式碼超過 15 行,已截斷`);
  }
  if (result.subtitles > 0) writeFileSync(join(outDir, 'boxes.json'), JSON.stringify(boxes, null, 1));
  result.blockedRequests = stats.blocked;
} catch (e) {
  console.error(`錯誤:${e.message}`); exitCode = 1;
} finally {
  cdp?.close();
}
console.log(JSON.stringify(result));
process.exit(exitCode);
