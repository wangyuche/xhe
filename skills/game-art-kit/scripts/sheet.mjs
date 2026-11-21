#!/usr/bin/env node
// game-art-kit:拼分鏡表 / 標註表。用本機 Google Chrome headless 截一張 HTML 版面(中文字正確)。
// 用法:node sheet.mjs <spec.json> <輸出.png>
// spec.json:
//   {"title":"開場過場","cols":3,"cellWidth":480,
//    "items":[{"image":"01.png","label":"01","caption":"村莊遠景","note":"(選填,第二行小字)"}]}
// image 路徑相對 spec.json 所在目錄;只接受本機 PNG / JPG / WebP。頁面不載入任何網路資源。
// stdout 一行 JSON:{"out":…,"width":…,"height":…,"items":N}。結束碼:0 成功;1 失敗;2 用法錯誤。
import { readFileSync, writeFileSync, mkdtempSync, rmSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, resolve, dirname, extname } from 'node:path';
import { pathToFileURL } from 'node:url';

const die = (m, c = 1) => { console.error(`錯誤:${m}`); process.exit(c); };
const [specPath, outArg] = process.argv.slice(2);
if (!specPath || !outArg) die('用法:node sheet.mjs <spec.json> <輸出.png>', 2);
let spec;
try { spec = JSON.parse(readFileSync(specPath, 'utf8')); } catch (e) { die(`讀不到 spec:${e.message}`, 2); }
const items = spec.items ?? [];
if (!items.length) die('spec.items 不能是空的', 2);
const colsIn = Number(spec.cols ?? 3), cellW = Number(spec.cellWidth ?? 480);
if (!Number.isInteger(colsIn) || colsIn < 1) die(`cols 要是正整數:${spec.cols}`, 2);
if (!Number.isInteger(cellW) || cellW < 50 || cellW > 2000) die(`cellWidth 要是 50–2000 的整數:${spec.cellWidth}`, 2);
const cols = Math.min(colsIn, items.length);
const base = dirname(resolve(specPath));
const MIME = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp' };

// EXIF IFD0 的 Orientation(0x0112);t = TIFF 標頭位置
function exifOrientation(buf, t) {
  try {
    const le = buf.toString('ascii', t, t + 2) === 'II';
    const u16 = (o) => le ? buf.readUInt16LE(o) : buf.readUInt16BE(o);
    const u32 = (o) => le ? buf.readUInt32LE(o) : buf.readUInt32BE(o);
    const ifd = t + u32(t + 4), n = u16(ifd);
    for (let k = 0; k < n; k++) { const e = ifd + 2 + k * 12; if (u16(e) === 0x0112) return u16(e + 8); }
  } catch { /* 讀不到就當 1 */ }
  return null;
}
// 讀不出尺寸就報錯,不猜比例(猜錯會把圖壓扁);檔案被截斷時讀超出範圍也一樣結束碼 2
function imgSize(file, buf) {
  let r;
  try { r = imgSizeRaw(file, buf); } catch (e) { if (e instanceof RangeError) die(`讀不出 ${file} 的尺寸(檔案不完整)`, 2); throw e; }
  if (!(r.w > 0 && r.h > 0)) die(`${file} 的寬高不合理(${r.w}×${r.h})`, 2);
  return r;
}
function imgSizeRaw(file, buf) {
  const ext = extname(file).toLowerCase();
  if (ext === '.png' && buf.toString('ascii', 1, 4) === 'PNG') return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20) };
  if (/\.jpe?g$/.test(ext) && buf[0] === 0xff && buf[1] === 0xd8) {
    let orient = 1;
    for (let i = 2; i + 9 < buf.length;) {
      if (buf[i] !== 0xff) { i++; continue; }
      const m = buf[i + 1];
      if (m === 0xd8 || m === 0x01 || (m >= 0xd0 && m <= 0xd7)) { i += 2; continue; }
      if (m === 0xe1 && buf.toString('ascii', i + 4, i + 8) === 'Exif') orient = exifOrientation(buf, i + 10) ?? orient;
      if (m >= 0xc0 && m <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(m)) {
        const w = buf.readUInt16BE(i + 7), h = buf.readUInt16BE(i + 5);
        return orient >= 5 && orient <= 8 ? { w: h, h: w } : { w, h }; // Chrome 依 EXIF 旋轉顯示
      }
      i += 2 + buf.readUInt16BE(i + 2);
    }
  }
  if (ext === '.webp' && buf.toString('ascii', 0, 4) === 'RIFF' && buf.toString('ascii', 8, 12) === 'WEBP') {
    const fmt = buf.toString('ascii', 12, 16);
    if (fmt === 'VP8X') return { w: 1 + buf.readUIntLE(24, 3), h: 1 + buf.readUIntLE(27, 3) };
    if (fmt === 'VP8 ') return { w: buf.readUInt16LE(26) & 0x3fff, h: buf.readUInt16LE(28) & 0x3fff };
    if (fmt === 'VP8L') { const b = buf.readUInt32LE(21); return { w: 1 + (b & 0x3fff), h: 1 + ((b >> 14) & 0x3fff) }; }
  }
  die(`讀不出 ${file} 的尺寸(只接受正常的 PNG / JPG / WebP)`, 2);
}
const esc = (s) => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

const cells = items.map((it, i) => {
  const f = resolve(base, it.image ?? die(`items[${i}] 缺 image`, 2));
  if (!existsSync(f)) die(`找不到圖片 ${f}`, 2);
  const mime = MIME[extname(f).toLowerCase()] ?? die(`items[${i}] 只接受 png / jpg / webp`, 2);
  const buf = readFileSync(f);
  const { w, h } = imgSize(f, buf);
  return { ...it, src: `data:${mime};base64,${buf.toString('base64')}`, imgH: Math.round(cellW * h / w) };
});
const pad = 24, gap = 20, titleH = spec.title ? 64 : 0, capH = 64;
const rows = [];
for (let i = 0; i < cells.length; i += cols) rows.push(cells.slice(i, i + cols));
const rowH = rows.map(r => Math.max(...r.map(c => c.imgH)) + capH);
const W = pad * 2 + cols * cellW + (cols - 1) * gap;
const H = pad * 2 + titleH + rowH.reduce((a, b) => a + b, 0) + (rows.length - 1) * gap;

const html = `<!doctype html><html><head><meta charset="utf-8"><style>
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:${W}px;height:${H}px;background:#f4f4f2;font-family:"PingFang TC","Heiti TC","Hiragino Sans",sans-serif;color:#1d1d1f;overflow:hidden}
.wrap{padding:${pad}px}
h1{height:${titleH}px;font-size:30px;font-weight:700;line-height:${titleH - 16}px}
.row{display:flex;gap:${gap}px;margin-bottom:${gap}px}
.row:last-child{margin-bottom:0}
.cell{width:${cellW}px}
.cell img{width:${cellW}px;display:block;border-radius:6px;background:#ddd;object-fit:contain}
.cap{height:${capH}px;padding-top:8px;font-size:17px;line-height:1.35;overflow:hidden}
.lb{display:inline-block;min-width:34px;padding:1px 8px;margin-right:8px;border-radius:4px;background:#1d1d1f;color:#fff;font-weight:700;text-align:center}
.nt{display:block;font-size:14px;color:#555;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
</style></head><body><div class="wrap">${spec.title ? `<h1>${esc(spec.title)}</h1>` : ''}
${rows.map(r => `<div class="row">${r.map(c => `<div class="cell"><img src="${c.src}" style="height:${c.imgH}px"><div class="cap">${c.label != null ? `<span class="lb">${esc(c.label)}</span>` : ''}${esc(c.caption)}${c.note ? `<span class="nt">${esc(c.note)}</span>` : ''}</div></div>`).join('')}</div>`).join('')}
</div></body></html>`;

const CHROME = process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
if (!existsSync(CHROME)) die(`找不到 Google Chrome(${CHROME});設 CHROME_PATH`, 1);
const tmp = mkdtempSync(join(tmpdir(), 'gak-sheet-'));
try {
  const page = join(tmp, 'sheet.html');
  writeFileSync(page, html);
  const out = resolve(outArg);
  rmSync(out, { force: true });
  const r = spawnSync(CHROME, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', '--no-default-browser-check',
    `--user-data-dir=${join(tmp, 'profile')}`, '--force-device-scale-factor=1', `--window-size=${W},${H}`,
    '--proxy-server=127.0.0.1:9', '--proxy-bypass-list=<-loopback>', // 擋掉任何網路請求
    `--screenshot=${out}`, pathToFileURL(page).href], { encoding: 'utf8', timeout: 60000 });
  // Chrome 有時截完圖、關閉時看門狗逾時而回非 0;以截圖檔有產生為準
  if (!existsSync(out)) { rmSync(tmp, { recursive: true, force: true }); die(`Chrome 截圖失敗(結束碼 ${r.status}):${(r.stderr || '').split('\n').slice(-5).join(' ')}`, 1); }
  const b = readFileSync(out);
  console.log(JSON.stringify({ out, width: b.readUInt32BE(16), height: b.readUInt32BE(20), items: cells.length }));
} finally {
  rmSync(tmp, { recursive: true, force: true });
}
