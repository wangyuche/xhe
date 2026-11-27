#!/usr/bin/env node
// game-art-kit:遊戲素材的 PNG 處理(純 Node,不需要任何套件)。尺寸一律是 1x 檔案像素(= 顯示尺寸 × density)。
// 用法:
//   node sprite.mjs info <png>                                           → {width,height,hasAlpha,coverage,bbox}
//   node sprite.mjs fit <in.png>... --out <out.png> --width W --height H [--align bottom|center] [--margin px] [--foot px]
//        裁掉透明邊 → 同一個縮放比例(以最大的那張為準,確保每張都放得下)→ 置中 / 底部對齊補到 W×H。
//        --foot px:底部對齊時主體離下緣的距離(預設 3,最小 2 = 外框檢查範圍外;要和既有素材對齊時例如 --foot 8);
//        範圍 2 ~ floor((H − margin) / 2)。只對 --align bottom 且 margin ≠ 0 有效,搭配 --align center 或 --margin 0 → 結束碼 2。
//        --margin 0(只限單張):裁邊後直接縮放到 W×H、不留透明邊(UI / 九宮格,切線才會對齊圖的邊緣)。
//        多張輸入 = 同一動作的各格:拼成 sheet(橫向排列,寬超過 2048 換行),印出 columns / rows。
//   node sprite.mjs density --width <顯示寬> --height <顯示高> [--frames N] [--density d]
//        算 1x 尺寸:density 預設 2,往下調到單格與整張 sheet 都不超過 2048;1x 取整數(無條件捨去),
//        印 {"density":<1x 寬 ÷ 顯示寬,4 位小數>,"width":1x 寬,"height":1x 高,"columns","rows"}(寫進 assets.json 的就是這組);
//        因 2048 上限把 density 調到低於要求(--density 或預設 2)時另加 "lowered":true(只是寬取整的差異不算)
//   node sprite.mjs cover <in.png> --out <out.png> --width W --height H
//        不透明素材(背景):等比縮放到蓋滿 W×H 再置中裁切(不留透明邊)。--exact(地圖塊):比例須相同,整張縮放不裁切。
//   node sprite.mjs check <png> --width W --height H [--frames N --columns C] [--opaque] [--tileable] [--character] [--allow-white-edge]
//        有 alpha(--opaque 除外)、尺寸 = 1x(frames 時 = W×columns by H×rows)、每格主體覆蓋率 10–90%(主體 = alpha ≥ 8)、
//        外框 2 px 內主體像素(alpha ≥ 8)< 1%、外緣白框:離透明區 1–3 px 內、alpha ≥ 128 的主體外圈,接近純白(RGB 皆 ≥ 238)像素 ≤ 30%(外緣 ≥ 20 px 才判斷;
//        主體本來就是白色的素材(白票、雲)加 --allow-white-edge 略過)、各格腳底基線差 ≤ 2 px 與主體高度差 ≤ 10%(--character 且多格)、
//        --tileable:左右、上下邊緣像素平均差 ≤ 8(0–255)。--full-bleed(UI / 九宮格,fit --margin 0 的產出):不檢查外框與覆蓋率上限。印 {"ok":…,"errors":[…],"frames":[…]},不通過結束碼 1。
//   node sprite.mjs clean <in.png> --out <out.png> [--key-white]
//        角色動作圖清理(rmbg 去背之後):alpha 依 16..250 拉開(人物調實、背景霧清掉)→ 只留跟中間直帶連在一起的塊 → 離實心處 > 4 px 的淡線透明。
//        --key-white:輸入是白底不透明圖(白底立繪)時先做白底去背。印 {ok,errors,coverage,border,touches}(touches = 主體碰到的邊:主體被切到,換候選或重出);不通過結束碼 1。
//   node sprite.mjs headshot <in.png> --anchor x,y,h --out <out.png> [--size 256] [--zoom 1.15] [--dx 0] [--pad l,t,r,b]
//        依頭中心 / 頭高(0–1,原圖比例)裁方形頭像;--pad 是圖各邊另外加的像素(有的話自動平移 anchor)。
// 結束碼:0 成功;1 檢查不通過;2 用法或檔案錯誤。
import { readFileSync, writeFileSync, mkdirSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
import { inflateSync, deflateSync } from 'node:zlib';

// CRC32(zlib.crc32 要 Node 22.2 以上,自己算以支援 22.0)
const CRC_T = new Uint32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
const crc32 = (buf) => { let c = 0xffffffff; for (const b of buf) c = CRC_T[(c ^ b) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };

class Fail extends Error { constructor(m, c) { super(m); this.code = c; } }
const die = (m, c = 2) => { throw new Fail(m, c); };

// ---------- PNG 解碼(8 / 16 bit、灰階 / RGB / 調色盤 / alpha,不支援 interlace)→ RGBA8 ----------
export function decodePng(buf) {
  if (buf.length < 8 || buf.readUInt32BE(0) !== 0x89504e47) die('不是 PNG');
  let p = 8, ihdr, plte, trns; const idat = [];
  while (p < buf.length) {
    if (p + 12 > buf.length) die('PNG 不完整(檔案被截斷)');
    const len = buf.readUInt32BE(p);
    if (p + 12 + len > buf.length) die('PNG 不完整(檔案被截斷)');
    const type = buf.toString('ascii', p + 4, p + 8), data = buf.subarray(p + 8, p + 8 + len);
    if (type === 'IHDR') ihdr = { w: data.readUInt32BE(0), h: data.readUInt32BE(4), depth: data[8], ct: data[9], interlace: data[12] };
    else if (type === 'PLTE') plte = data; else if (type === 'tRNS') trns = data; else if (type === 'IDAT') idat.push(data); else if (type === 'IEND') break;
    p += 12 + len;
  }
  if (!ihdr) die('PNG 沒有 IHDR');
  const { w, h, depth, ct, interlace } = ihdr;
  if (interlace) die('不支援 interlace PNG');
  if (ct === 3 && !plte) die('調色盤 PNG 缺 PLTE');
  if (!idat.length) die('PNG 沒有影像資料');
  if (![8, 16].includes(depth) && !(ct === 3 && depth <= 8)) die(`不支援的 bit depth ${depth}`);
  const ch = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[ct]; if (!ch) die(`不支援的色彩類型 ${ct}`);
  const bpp = Math.max(1, (ch * depth) / 8), stride = Math.ceil((w * ch * depth) / 8);
  let raw; try { raw = inflateSync(Buffer.concat(idat)); } catch { die('PNG 影像資料損壞'); }
  if (raw.length < (stride + 1) * h) die('PNG 影像資料不完整');
  const px = Buffer.alloc(stride * h);
  let prev = Buffer.alloc(stride);
  for (let y = 0; y < h; y++) {
    const f = raw[y * (stride + 1)]; if (f > 4) die(`PNG 濾波類型錯誤(${f})`);
    const row = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1)), out = px.subarray(y * stride, (y + 1) * stride);
    for (let i = 0; i < stride; i++) {
      const a = i >= bpp ? out[i - bpp] : 0, b = prev[i], c = i >= bpp ? prev[i - bpp] : 0;
      let v = row[i];
      if (f === 1) v += a; else if (f === 2) v += b; else if (f === 3) v += (a + b) >> 1;
      else if (f === 4) { const pp = a + b - c, pa = Math.abs(pp - a), pb = Math.abs(pp - b), pc = Math.abs(pp - c); v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c; }
      out[i] = v & 255;
    }
    prev = out;
  }
  const rgba = Buffer.alloc(w * h * 4);
  const sample = (y, i) => depth === 16 ? px[y * stride + i * 2] : depth === 8 ? px[y * stride + i]
    : (px[y * stride + ((i * depth) >> 3)] >> (8 - depth - ((i * depth) & 7))) & ((1 << depth) - 1);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const o = (y * w + x) * 4;
    if (ct === 3) {
      const k = sample(y, x); rgba[o] = plte[k * 3]; rgba[o + 1] = plte[k * 3 + 1]; rgba[o + 2] = plte[k * 3 + 2]; rgba[o + 3] = trns && k < trns.length ? trns[k] : 255;
    } else {
      const s = (j) => sample(y, x * ch + j);
      if (ch === 1 || ch === 2) { const g = s(0); rgba[o] = rgba[o + 1] = rgba[o + 2] = g; rgba[o + 3] = ch === 2 ? s(1) : 255; }
      else { rgba[o] = s(0); rgba[o + 1] = s(1); rgba[o + 2] = s(2); rgba[o + 3] = ch === 4 ? s(3) : 255; }
      // 灰階 / RGB 的 tRNS 色鍵:等於該色的像素透明
      if (trns && (ct === 0 || ct === 2)) {
        // 16 bit 要比完整的 16 bit 值,不能只比高位元組
        const raw = (j) => depth === 16 ? px.readUInt16BE(y * stride + (x * ch + j) * 2) : s(j);
        const key = (j) => trns.readUInt16BE(j * 2);
        if (ct === 0 ? raw(0) === key(0) : raw(0) === key(0) && raw(1) === key(1) && raw(2) === key(2)) rgba[o + 3] = 0;
      }
    }
  }
  return { width: w, height: h, data: rgba, hasAlpha: ct === 4 || ct === 6 || !!trns };
}

export function encodePng({ width: w, height: h, data }) {
  const chunk = (type, d) => { const b = Buffer.alloc(12 + d.length); b.writeUInt32BE(d.length, 0); b.write(type, 4); d.copy(b, 8); b.writeUInt32BE(crc32(Buffer.concat([Buffer.from(type), d])) >>> 0, 8 + d.length); return b; };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) { raw[y * (w * 4 + 1)] = 0; data.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4); }
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}

export const blank = (w, h) => ({ width: w, height: h, data: Buffer.alloc(w * h * 4) });

// 主體 = alpha ≥ ALPHA_MIN(去背遮罩邊緣常留下 alpha 1–7 的雜訊,不算主體)
export const ALPHA_MIN = 8;
// 主體的外接矩形(沒有就 null)
export function bbox(img, x0 = 0, y0 = 0, w = img.width, h = img.height) {
  let minX = Infinity, minY = Infinity, maxX = -1, maxY = -1;
  for (let y = y0; y < y0 + h; y++) for (let x = x0; x < x0 + w; x++) if (img.data[(y * img.width + x) * 4 + 3] >= ALPHA_MIN) {
    if (x < minX) minX = x; if (x > maxX) maxX = x; if (y < minY) minY = y; if (y > maxY) maxY = y;
  }
  return maxX < 0 ? null : { x: minX - x0, y: minY - y0, w: maxX - minX + 1, h: maxY - minY + 1 };
}

// 區域平均縮放(premultiplied alpha,放大縮小都可),src 的 (sx,sy,sw,sh) → dw×dh
export function resample(src, sx, sy, sw, sh, dw, dh) {
  const out = blank(dw, dh), fx = sw / dw, fy = sh / dh;
  for (let y = 0; y < dh; y++) {
    const y0 = sy + y * fy, y1 = y0 + fy;
    for (let x = 0; x < dw; x++) {
      const x0 = sx + x * fx, x1 = x0 + fx;
      let r = 0, g = 0, b = 0, a = 0, wsum = 0;
      for (let yy = Math.floor(y0); yy < Math.ceil(y1); yy++) {
        const wy = Math.min(y1, yy + 1) - Math.max(y0, yy); if (wy <= 0 || yy < 0 || yy >= src.height) continue;
        for (let xx = Math.floor(x0); xx < Math.ceil(x1); xx++) {
          const wx = Math.min(x1, xx + 1) - Math.max(x0, xx); if (wx <= 0 || xx < 0 || xx >= src.width) continue;
          const o = (yy * src.width + xx) * 4, wgt = wx * wy, al = src.data[o + 3] / 255;
          r += src.data[o] * al * wgt; g += src.data[o + 1] * al * wgt; b += src.data[o + 2] * al * wgt; a += al * wgt; wsum += wgt;
        }
      }
      const o = (y * dw + x) * 4;
      if (wsum > 0 && a > 0) { out.data[o] = Math.round(r / a); out.data[o + 1] = Math.round(g / a); out.data[o + 2] = Math.round(b / a); out.data[o + 3] = Math.round((a / wsum) * 255); }
    }
  }
  return out;
}

export function blit(dst, src, dx, dy) {
  for (let y = 0; y < src.height; y++) for (let x = 0; x < src.width; x++) {
    const tx = dx + x, ty = dy + y; if (tx < 0 || ty < 0 || tx >= dst.width || ty >= dst.height) continue;
    src.data.copy(dst.data, (ty * dst.width + tx) * 4, (y * src.width + x) * 4, (y * src.width + x) * 4 + 4);
  }
}

const FOOT = 3;
export const sheetLayout = (count, w) => { const columns = Math.max(1, Math.min(count, Math.floor(2048 / w))); return { columns, rows: Math.ceil(count / columns) }; };

// 多張(同一動作)用同一縮放比例放進 W×H;回傳 sheet 影像
export function fit(imgs, W, H, { align = 'bottom', margin, foot } = {}) {
  const m = margin ?? Math.max(4, Math.round(Math.min(W, H) * 0.03));
  if (foot != null && (align !== 'bottom' || m === 0)) die('--foot 只用於 --align bottom 且 margin ≠ 0');
  if (foot != null && Math.floor((H - m) / 2) < 2) die(`格子太小(H ${H}、margin ${m}),放不下 --foot;不要用 --foot 或加大 1x 高度`);
  if (foot != null && (foot < 2 || foot > Math.floor((H - m) / 2))) die(`--foot 要在 2 到 ${Math.floor((H - m) / 2)} 之間(2 px 外框檢查之外;最多 (H − margin) / 2,主體才不會被縮得太小)`);
  foot ??= FOOT;
  if (W > 2048 || H > 2048) die(`1x 尺寸 ${W}×${H} 超過 2048(PX-RES-01);用 sprite.mjs density 算出的 1x 尺寸(單張與 frames 整張 sheet 都 ≤ 2048)`);
  if (m === 0 && imgs.length === 1) {
    const b = bbox(imgs[0]) ?? die('第 1 張是全透明', 1);
    // 不留邊時只能等比:裁切後的比例和 W×H 差超過 3% 就失敗(拉伸會讓邊框粗細不一、九宮格切線對不上),請用相同比例重出
    const ar = (b.w / b.h) / (W / H);
    if (Math.abs(ar - 1) > 0.03) die(`裁切後比例 ${b.w}×${b.h} 和目標 ${W}×${H} 差 ${Math.round(Math.abs(ar - 1) * 100)}%(> 3%),--margin 0 不能等比放滿;請用接近 ${W}:${H} 的比例重出`, 1);
    return { sheet: resample(imgs[0], b.x, b.y, b.w, b.h, W, H), columns: 1, rows: 1, scale: W / b.w, margin: 0 };
  }
  const boxes = imgs.map((im, i) => bbox(im) ?? die(`第 ${i + 1} 張是全透明`, 1));
  const maxW = Math.max(...boxes.map(b => b.w)), maxH = Math.max(...boxes.map(b => b.h));
  if (m === 0) die('--margin 0 只用於單張(UI / 九宮格:裁邊後直接縮放到 W×H)');
  if (W - 2 * m <= 0 || H - 2 * m <= 0) die('尺寸太小,扣掉邊界後沒有空間');
  const s = Math.min((W - 2 * m) / maxW, (H - (align === 'bottom' ? m + foot : 2 * m)) / maxH);
  const { columns, rows } = sheetLayout(imgs.length, W);
  if (rows * H > 2048) die(`sheet 高 ${rows * H} 超過 2048`);
  const sheet = blank(W * columns, H * rows);
  imgs.forEach((im, i) => {
    const b = boxes[i], dw = Math.max(1, Math.round(b.w * s)), dh = Math.max(1, Math.round(b.h * s));
    const cell = resample(im, b.x, b.y, b.w, b.h, dw, dh);
    const cx = (i % columns) * W, cy = Math.floor(i / columns) * H;
    // 水平:以主體的 alpha 加權重心置中(伸出手腳時身體不會左右跳),超出格子就貼齊邊界
    // 底部對齊:腳底離下緣 foot px(預設 3,在 2 px 外框檢查之外;anchor [0.5,1] 誤差 < 2 顯示 px)
    const gx = centroidX(im, b) * s;
    const lo = dw <= W - 2 * m ? m : 0, hi = dw <= W - 2 * m ? W - m - dw : W - dw;
    const dx = cx + Math.min(hi, Math.max(lo, Math.round(W / 2 - gx))), dy = cy + (align === 'bottom' ? H - foot - dh : Math.round((H - dh) / 2));
    blit(sheet, cell, dx, dy);
  });
  return { sheet, columns, rows, scale: s, margin: m };
}

function centroidX(img, b) {
  let sum = 0, wsum = 0;
  for (let y = b.y; y < b.y + b.h; y++) for (let x = b.x; x < b.x + b.w; x++) { const a = img.data[(y * img.width + x) * 4 + 3]; if (a >= ALPHA_MIN) { sum += (x - b.x + 0.5) * a; wsum += a; } }
  return wsum ? sum / wsum : b.w / 2;
}

export function density1x(dw, dh, frames = 1, want = 2) {
  if (!Number.isFinite(want) || want <= 0) die(`--density 要是正數(收到 ${want})`);
  if (Math.floor(dw * want + 1e-9) < 1) die(`--density ${want} 太小:顯示寬 ${dw} × density 不到 1 px`);
  // 寬取整(無條件捨去)後,印出的 density = 寬 ÷ 顯示寬(4 位小數),高用同一個 density 四捨五入(validate 同樣算法)
  const size = (W) => { const dens = +(W / dw).toFixed(4); return { W, dens, H: Math.round(dh * dens) }; };
  const base = size(Math.floor(dw * want + 1e-9)).dens; // 沒受 2048 限制時的值,低於它才算 lowered
  // 從要求的寬(且單邊 ≤ 2048)往下逐 px 找第一個單張與整張 sheet 都 ≤ 2048 的寬:最大可行值,不會多降
  for (let W = Math.floor(Math.min(dw * want, dw * 2048 / Math.max(dw, dh)) + 1e-9); W >= 1; W--) {
    const { dens, H } = size(W);
    const { columns, rows } = sheetLayout(frames, W);
    // lowered:實際 density 低於要求(needs 指定或預設 2),agent 列在已知限制;< 1 時透明素材跳過、不透明素材允許(見 agent)
    if (H >= 1 && W * columns <= 2048 && H <= 2048 && H * rows <= 2048) return { density: dens, width: W, height: H, columns, rows, ...(dens < base - 1e-4 ? { lowered: true } : {}) };
  }
  die('找不到合適的 density(顯示尺寸太大)');
}

export function cover(img, W, H, exact = false) {
  // exact(地圖塊):比例要一致(±1%)、整張縮放不裁切,才不會切掉接得起來的邊
  if (exact) { if (Math.abs((img.width / img.height) / (W / H) - 1) > 0.01) die(`--exact:原圖 ${img.width}×${img.height} 和 ${W}×${H} 比例不同;用相同比例重出`, 1); return resample(img, 0, 0, img.width, img.height, W, H); }
  const s = Math.max(W / img.width, H / img.height), sw = W / s, sh = H / s;
  return resample(img, (img.width - sw) / 2, (img.height - sh) / 2, sw, sh, W, H);
}

// 白色貼紙外框:離透明區(alpha < 8,格子外也算)1–3 px 內、alpha ≥ 128 的主體外圈中,接近純白(RGB 皆 ≥ 238)像素的比例。
// 用距離找外圈,半透明過渡邊不會讓檢查跳過;門檻 238 不把淺灰去背殘留(約 220–235)當白。
// 校準(2026-11-22 MahjongParty,33 張):有白框的原圖 0.83–1.00,乾淨的 ≤ 0.017。
const HALO_MAX = 0.3, HALO_MIN_EDGE = 20, HALO_RING = 3, HALO_WHITE = 238;
export function whiteHalo(img, x0 = 0, y0 = 0, w = img.width, h = img.height) {
  const d = img.data, A = (x, y) => d[((y0 + y) * img.width + x0 + x) * 4 + 3];
  const dist = new Int16Array(w * h).fill(-1), q = [];
  // 兩段放入佇列:先放全部距離 0(透明),再放距離 1(貼格子邊的不透明;格子外當透明),BFS 才是依距離遞增
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) { const i = y * w + x; if (A(x, y) < ALPHA_MIN) { dist[i] = 0; q.push(i); } }
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) { const i = y * w + x; if (dist[i] < 0 && (x === 0 || y === 0 || x === w - 1 || y === h - 1)) { dist[i] = 1; q.push(i); } }
  for (let k = 0; k < q.length; k++) {
    const i = q[k], x = i % w, y = (i - x) / w;
    if (dist[i] >= HALO_RING) continue;
    for (const [nx, ny] of [[x + 1, y], [x - 1, y], [x, y + 1], [x, y - 1]]) {
      if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
      const j = ny * w + nx; if (dist[j] < 0) { dist[j] = dist[i] + 1; q.push(j); }
    }
  }
  let edge = 0, white = 0;
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const dd = dist[y * w + x]; if (dd < 1 || dd > HALO_RING || A(x, y) < 128) continue;
    const o = ((y0 + y) * img.width + x0 + x) * 4;
    edge++; if (Math.min(d[o], d[o + 1], d[o + 2]) >= HALO_WHITE) white++;
  }
  return { edge, ratio: edge ? +(white / edge).toFixed(3) : 0 };
}

export function checkImage(img, { width: W, height: H, frames = 1, columns, opaque = false, tileable = false, character = false, fullBleed = false, allowWhiteEdge = false }) {
  const errs = [], info = [];
  const cols = columns ?? (frames > 1 ? sheetLayout(frames, W).columns : 1), rows = Math.ceil(frames / cols);
  // 要真的有透明像素(色彩類型是 RGBA 不夠:去背失敗時整張還是不透明)
  // --full-bleed 的 UI 可以剛好填滿(例如方形面板),只要求 RGBA
  if (!opaque && fullBleed && !img.hasAlpha) errs.push('沒有 alpha 通道(應為透明 PNG)');
  if (!opaque && !fullBleed) { let t = 0; for (let i = 3; i < img.data.length; i += 4) if (img.data[i] < ALPHA_MIN) { t++; break; } if (!img.hasAlpha || !t) errs.push('沒有透明像素(alpha 全不透明;去背失敗?應為透明 PNG)'); }
  if (img.width !== W * cols || img.height !== H * rows) errs.push(`尺寸 ${img.width}×${img.height},應為 ${W * cols}×${H * rows}`);
  if (img.width !== W * cols || img.height !== H * rows) return { errs, info };
  for (let i = 0; i < frames; i++) {
    const x0 = (i % cols) * W, y0 = Math.floor(i / cols) * H;
    let cover = 0, border = 0, borderN = 0;
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      const a = img.data[((y0 + y) * img.width + x0 + x) * 4 + 3];
      if (a >= ALPHA_MIN) cover++;
      if (x < 2 || y < 2 || x >= W - 2 || y >= H - 2) { borderN++; if (a >= ALPHA_MIN) border++; }
    }
    const b = bbox(img, x0, y0, W, H);
    const halo = opaque || fullBleed || allowWhiteEdge ? null : whiteHalo(img, x0, y0, W, H);
    const f = { frame: i + 1, coverage: +(cover / (W * H)).toFixed(3), border: +(border / borderN).toFixed(4), baseline: b ? b.y + b.h : null, height: b?.h ?? 0, ...(halo ? { halo: halo.ratio, halo_edge: halo.edge } : {}) };
    info.push(f);
    if (!opaque) {
      if (f.coverage < 0.1 || (!fullBleed && f.coverage > 0.9)) errs.push(`第 ${i + 1} 格主體覆蓋率 ${(f.coverage * 100).toFixed(1)}%(應 10–90%)`);
      if (!fullBleed && f.border >= 0.01) errs.push(`第 ${i + 1} 格外框 2 px 內有 ${(f.border * 100).toFixed(2)}% 不透明像素(應 < 1%;去背殘留或主體貼邊)`);
      if (halo && halo.edge >= HALO_MIN_EDGE && halo.ratio > HALO_MAX) errs.push(`第 ${i + 1} 格主體外緣 ${(halo.ratio * 100).toFixed(0)}% 是近白像素(應 ≤ ${HALO_MAX * 100}%;白色貼紙外框):重出時正向提示詞拿掉 sticker / sticker art,改寫 game item art, no white contour,負向加 sticker, white outline, white contour, white halo;主體本來就是白色的素材才加 --allow-white-edge`);
    }
  }
  if (character && frames > 1 && !opaque) {
    const bl = info.map(f => f.baseline).filter(x => x != null), hs = info.map(f => f.height);
    if (bl.length && Math.max(...bl) - Math.min(...bl) > 2) errs.push(`各格腳底基線差 ${Math.max(...bl) - Math.min(...bl)} px(應 ≤ 2)`);
    if (Math.max(...hs) > 0 && (Math.max(...hs) - Math.min(...hs)) / Math.max(...hs) > 0.1) errs.push(`各格主體高度差 ${Math.round((Math.max(...hs) - Math.min(...hs)) / Math.max(...hs) * 100)}%(應 ≤ 10%)`);
  }
  if (tileable) {
    let lr = 0, tb = 0;
    const px = (x, y, c) => img.data[(y * img.width + x) * 4 + c];
    for (let y = 0; y < img.height; y++) for (let c = 0; c < 3; c++) lr += Math.abs(px(0, y, c) - px(img.width - 1, y, c));
    for (let x = 0; x < img.width; x++) for (let c = 0; c < 3; c++) tb += Math.abs(px(x, 0, c) - px(x, img.height - 1, c));
    lr /= img.height * 3; tb /= img.width * 3;
    info.push({ tile: { leftRight: +lr.toFixed(2), topBottom: +tb.toFixed(2) } });
    if (lr > 8 || tb > 8) errs.push(`平鋪邊緣差 左右 ${lr.toFixed(1)}、上下 ${tb.toFixed(1)}(應 ≤ 8)`);
  }
  return { errs, info };
}


// ---------- 角色動作圖清理(clean)與頭像(headshot)----------
// 原則(實測):去背後人物 alpha 約 253(不是 255)、背景霧只有個位數到十幾 → alpha 依 HAZE..SOLID 線性拉開;
// 只留跟畫面中間那條直帶連在一起的塊(汗滴、眼淚在臉上,也連在主體裡);離實心處 > NEAR/2 px 的淡線一律透明。
export const SOLID = 250, HAZE = 16, NEAR = 9;
const WHITE = 238, GREY = 12, HOLE = 300, HOLE_WHITE = 249, HOLE_GREY = 3;

// 二值遮罩(Uint8Array 0/1)的方形膨脹 / 侵蝕(半徑 r,分離成水平 + 垂直兩趟)
function morph(m, w, h, r, dilate) {
  const pass = (src, horiz) => {
    const out = new Uint8Array(src.length);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      let v = dilate ? 0 : 1;
      for (let k = -r; k <= r; k++) {
        const xx = horiz ? x + k : x, yy = horiz ? y : y + k;
        const s = xx < 0 || yy < 0 || xx >= w || yy >= h ? (dilate ? 0 : 1) : src[yy * w + xx];
        if (dilate ? s : !s) { v = dilate ? 1 : 0; break; }
      }
      out[y * w + x] = v;
    }
    return out;
  };
  return pass(pass(m, true), false);
}
export const dilate = (m, w, h, r) => morph(m, w, h, r, true);
export const erode = (m, w, h, r) => morph(m, w, h, r, false);

// 8 連通的塊標號:回傳 { label: Int32Array(0 = 背景), sizes: [_, n1, n2…] }
function components(m, w, h) {
  const label = new Int32Array(w * h), sizes = [0]; const stack = [];
  for (let i = 0; i < m.length; i++) {
    if (!m[i] || label[i]) continue;
    const id = sizes.length; let n = 0; label[i] = id; stack.push(i);
    while (stack.length) {
      const p = stack.pop(); n++; const x = p % w, y = (p - x) / w;
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
        const xx = x + dx, yy = y + dy; if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue;
        const q = yy * w + xx; if (m[q] && !label[q]) { label[q] = id; stack.push(q); }
      }
    }
    sizes.push(n);
  }
  return { label, sizes };
}

// 白底去背(只在底圖是白底、不是 RMBG 輸出時用):四邊灌進來的近白色 = 背景;被手臂圍起來、夠大夠白的塊也是背景;
// 背景旁 2 px 依「比附近最深描線亮多少」算透明度並扣掉混進去的白
export function keyWhite(img) {
  const { width: w, height: h, data } = img, N = w * h;
  const lo = new Uint8Array(N), hi = new Uint8Array(N);
  for (let i = 0; i < N; i++) { const r = data[i * 4], g = data[i * 4 + 1], b = data[i * 4 + 2]; lo[i] = Math.min(r, g, b); hi[i] = Math.max(r, g, b); }
  const cand = new Uint8Array(N); for (let i = 0; i < N; i++) cand[i] = lo[i] >= WHITE && hi[i] - lo[i] <= GREY ? 1 : 0;
  const { label, sizes } = components(cand, w, h);
  const bgIds = new Set();
  for (let x = 0; x < w; x++) { if (label[x]) bgIds.add(label[x]); if (label[(h - 1) * w + x]) bgIds.add(label[(h - 1) * w + x]); }
  for (let y = 0; y < h; y++) { if (label[y * w]) bgIds.add(label[y * w]); if (label[y * w + w - 1]) bgIds.add(label[y * w + w - 1]); }
  // 圍起來的白:夠大、夠白、完全沒顏色才算背景(眼白、反光比較小或帶一點顏色)
  const sumLo = new Float64Array(sizes.length), sumC = new Float64Array(sizes.length);
  for (let i = 0; i < N; i++) if (label[i]) { sumLo[label[i]] += lo[i]; sumC[label[i]] += hi[i] - lo[i]; }
  for (let id = 1; id < sizes.length; id++) if (!bgIds.has(id) && sizes[id] >= HOLE && sumLo[id] / sizes[id] >= HOLE_WHITE && sumC[id] / sizes[id] <= HOLE_GREY) bgIds.add(id);
  const bg = new Uint8Array(N); let pr = 0, pg = 0, pb = 0, pn = 0;
  for (let i = 0; i < N; i++) if (bgIds.has(label[i])) { bg[i] = 1; pr += data[i * 4]; pg += data[i * 4 + 1]; pb += data[i * 4 + 2]; pn++; }
  const paper = pn ? [pr / pn, pg / pn, pb / pn] : [255, 255, 255], white = Math.min(...paper);
  const edge = dilate(bg, w, h, 2);
  const out = { width: w, height: h, hasAlpha: true, data: Buffer.from(data) };
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const i = y * w + x, o = i * 4;
    if (bg[i]) { out.data[o + 3] = 0; continue; }
    if (!edge[i]) { out.data[o + 3] = 255; continue; }
    let ink = 255; for (let dy = -3; dy <= 3; dy++) for (let dx = -3; dx <= 3; dx++) { const xx = x + dx, yy = y + dy; if (xx >= 0 && yy >= 0 && xx < w && yy < h) ink = Math.min(ink, lo[yy * w + xx]); }
    const a = Math.min(1, Math.max(0, (white - lo[i]) / Math.max(white - ink, 40)));
    out.data[o + 3] = Math.round(a * 255);
    if (a > 1e-3) for (let c = 0; c < 3; c++) out.data[o + c] = Math.max(0, Math.min(255, Math.round((data[o + c] - (1 - a) * paper[c]) / a)));
  }
  return out;
}

// clean:alpha 拉開(HAZE..SOLID)→ 只留跟中間直帶(x 在 1/4–3/4)連在一起的塊 → 離實心(alpha > 64)超過 NEAR/2 px 的透明
export function cleanAlpha(img) {
  const { width: w, height: h } = img, N = w * h, out = { width: w, height: h, hasAlpha: true, data: Buffer.from(img.data) };
  if (!img.hasAlpha) throw new Error('沒有 alpha(先用 rmbg 去背;白底立繪才加 --key-white)');
  const d = out.data;
  for (let i = 0; i < N; i++) d[i * 4 + 3] = Math.round(Math.min(1, Math.max(0, (d[i * 4 + 3] - HAZE) / (SOLID - HAZE))) * 255);
  const m = new Uint8Array(N); for (let i = 0; i < N; i++) m[i] = d[i * 4 + 3] > 0 ? 1 : 0;
  const { label } = components(m, w, h), keep = new Set();
  for (let y = 0; y < h; y++) for (let x = Math.floor(w / 4); x < Math.ceil(w * 3 / 4); x++) if (label[y * w + x]) keep.add(label[y * w + x]);
  for (let i = 0; i < N; i++) if (!keep.has(label[i])) d[i * 4 + 3] = 0;
  const solid = new Uint8Array(N); for (let i = 0; i < N; i++) solid[i] = d[i * 4 + 3] > 64 ? 1 : 0;
  const near = dilate(solid, w, h, (NEAR - 1) / 2);
  for (let i = 0; i < N; i++) if (!near[i]) d[i * 4 + 3] = 0;
  return out;
}

// clean 之後的自我檢查:有透明、覆蓋率 10–90%、外框 2 px 主體 < 1%;並列出碰到哪幾邊(extend 用)
export function cleanReport(img) {
  const { width: w, height: h, data } = img, errs = [];
  let cover = 0, border = 0, borderN = 0, transparent = 0; const touch = { left: 0, top: 0, right: 0, bottom: 0 };
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const a = data[(y * w + x) * 4 + 3];
    if (a >= ALPHA_MIN) cover++; else transparent++;
    const edge = x < 2 || y < 2 || x >= w - 2 || y >= h - 2;
    if (edge) { borderN++; if (a >= ALPHA_MIN) { border++; if (x < 2) touch.left++; if (y < 2) touch.top++; if (x >= w - 2) touch.right++; if (y >= h - 2) touch.bottom++; } }
  }
  const coverage = +(cover / (w * h)).toFixed(3), b = +(border / borderN).toFixed(4);
  const touches = Object.entries(touch).filter(([, n]) => n >= 4).map(([k]) => k);
  if (!transparent) errs.push('沒有透明像素');
  if (coverage < 0.1 || coverage > 0.9) errs.push(`主體覆蓋率 ${(coverage * 100).toFixed(1)}%(應 10–90%)`);
  if (touches.length && b < 0.01) errs.push(`主體碰到圖邊:${touches.join(', ')}(主體被切到:換候選或重出)`);
  if (b >= 0.01) errs.push(`外框 2 px 內有 ${(b * 100).toFixed(2)}% 主體像素(應 < 1%;碰邊:${touches.join(', ') || '—'};主體被切到:換候選或重出)`);
  return { ok: !errs.length, errors: errs, coverage, border: b, touches };
}

// 頭像:anchor = 頭中心 x、y 與頭高(0–1,對「補邊前」的原圖);pad = extend 各邊補的像素;side = 頭高 × zoom(預設 1.15)
export function headshot(img, { x, y, h }, { size = 256, zoom = 1.15, dx = 0, pad = { left: 0, top: 0, right: 0, bottom: 0 } } = {}) {
  const bw = img.width - pad.left - pad.right, bh = img.height - pad.top - pad.bottom;
  const side = h * bh * zoom, cx = (x + dx) * bw + pad.left, cy = y * bh + pad.top;
  return resample(img, cx - side / 2, cy - side / 2, side, side, size, size);
}

// ---------- CLI ----------
// skill 目錄常是連結:argv[1] 保留連結路徑、import.meta.url 是實際路徑,要比 realpath
const isMain = (() => { try { return !!process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } })();
if (isMain) {
  try {
    const [cmd, ...rest] = process.argv.slice(2);
    const flags = {}, pos = [];
    for (let i = 0; i < rest.length; i++) {
      const a = rest[i];
      if (['--opaque', '--tileable', '--character', '--full-bleed', '--exact', '--allow-white-edge', '--key-white'].includes(a)) flags[a.slice(2)] = true;
      else if (a.startsWith('--')) flags[a.slice(2)] = rest[++i] ?? die(`${a} 缺值`);
      else pos.push(a);
    }
    const int = (k, req = true, min = 1) => { const v = flags[k]; if (v == null) return req ? die(`缺 --${k}`) : undefined; if (!/^\d+$/.test(v) || +v < min) die(`--${k} 要是 ≥ ${min} 的整數`); return +v; };
    const load = (f) => { let b; try { b = readFileSync(f); } catch (e) { die(`讀不到 ${f}:${e.message}`); } return decodePng(b); };
    if (cmd === 'info') {
      const img = load(pos[0] ?? die('用法:info <png>'));
      const b = bbox(img); let cover = 0; for (let i = 3; i < img.data.length; i += 4) if (img.data[i] >= ALPHA_MIN) cover++;
      console.log(JSON.stringify({ width: img.width, height: img.height, hasAlpha: img.hasAlpha, coverage: +(cover / (img.width * img.height)).toFixed(3), bbox: b }));
    } else if (cmd === 'fit') {
      if (!pos.length) die('用法:fit <in.png>... --out <out.png> --width W --height H');
      const out = flags.out ?? die('缺 --out');
      const align = flags.align ?? 'bottom'; if (!['bottom', 'center'].includes(align)) die('--align 只能 bottom 或 center');
      if (pos.length > 8) die('一個動作最多 8 格');
      const r = fit(pos.map(load), int('width'), int('height'), { align, margin: flags.margin != null ? int('margin', true, 0) : undefined, foot: flags.foot != null ? int('foot', true, 0) : undefined });
      mkdirSync(dirname(out), { recursive: true });
      writeFileSync(out, encodePng(r.sheet));
      console.log(JSON.stringify({ file: out, width: r.sheet.width, height: r.sheet.height, frames: pos.length, columns: r.columns, rows: r.rows, scale: +r.scale.toFixed(4), margin: r.margin }));
    } else if (cmd === 'density') {
      const frames = flags.frames != null ? int('frames') : 1; if (frames > 8) die('frames 最多 8');
      const want = flags.density != null ? Number(flags.density) : 2; if (!(want > 0 && want <= 2)) die('--density 要在 0–2');
      console.log(JSON.stringify(density1x(int('width'), int('height'), frames, want)));
    } else if (cmd === 'cover') {
      const out = flags.out ?? die('缺 --out');
      const r = cover(load(pos[0] ?? die('用法:cover <in.png> --out <out.png> --width W --height H [--exact]')), int('width'), int('height'), !!flags.exact);
      mkdirSync(dirname(out), { recursive: true });
      writeFileSync(out, encodePng(r));
      console.log(JSON.stringify({ file: out, width: r.width, height: r.height }));
    } else if (cmd === 'check') {
      const img = load(pos[0] ?? die('用法:check <png> --width W --height H'));
      const frames = flags.frames != null ? int('frames') : 1;
      if (frames > 8) die('frames 最多 8');
      const { errs, info } = checkImage(img, { width: int('width'), height: int('height'), frames, columns: flags.columns != null ? int('columns') : undefined, opaque: !!flags.opaque, tileable: !!flags.tileable, character: !!flags.character, fullBleed: !!flags['full-bleed'], allowWhiteEdge: !!flags['allow-white-edge'] });
      console.log(JSON.stringify({ ok: errs.length === 0, errors: errs, frames: info }));
      process.exit(errs.length ? 1 : 0);
    } else if (cmd === 'clean') {
      const out = flags.out ?? die('缺 --out');
      let img = load(pos[0] ?? die('用法:clean <in.png> --out <out.png> [--key-white]'));
      if (flags['key-white']) img = keyWhite(img);
      else { let t = false; if (img.hasAlpha) for (let i = 3; i < img.data.length; i += 4) if (img.data[i] < 255) { t = true; break; } if (!t) die('輸入沒有透明像素(還沒去背):圖還沒去背;白底不透明的圖加 --key-white'); }
      const r = cleanAlpha(img);
      mkdirSync(dirname(out), { recursive: true });
      writeFileSync(out, encodePng(r));
      const rep = cleanReport(r);
      console.log(JSON.stringify({ file: out, width: r.width, height: r.height, ...rep }));
      process.exit(rep.ok ? 0 : 1);
    } else if (cmd === 'headshot') {
      const out = flags.out ?? die('缺 --out');
      const img = load(pos[0] ?? die('用法:headshot <in.png> --anchor x,y,h --out <out.png> [--size 256] [--zoom 1.15] [--dx 0] [--pad l,t,r,b]'));
      const nums = (k, n) => { const v = String(flags[k] ?? die(`缺 --${k}`)).split(',').map(Number); if (v.length !== n || v.some(x => !Number.isFinite(x))) die(`--${k} 要 ${n} 個數字(逗號分隔)`); return v; };
      const [x, y, h] = nums('anchor', 3); if (![x, y, h].every(v => v > 0 && v <= 1)) die('--anchor 的 x、y、h 都要在 0–1');
      const [l, t, r, b] = flags.pad != null ? nums('pad', 4) : [0, 0, 0, 0];
      const zoom = flags.zoom != null ? Number(flags.zoom) : 1.15, dx = flags.dx != null ? Number(flags.dx) : 0;
      if (!(Number.isFinite(zoom) && zoom > 0)) die('--zoom 要是正數'); if (!Number.isFinite(dx)) die('--dx 要是數字');
      const res = headshot(img, { x, y, h }, { size: flags.size != null ? int('size') : 256, zoom, dx, pad: { left: l, top: t, right: r, bottom: b } });
      mkdirSync(dirname(out), { recursive: true });
      writeFileSync(out, encodePng(res));
      let cover = 0; for (let i = 3; i < res.data.length; i += 4) if (res.data[i] >= ALPHA_MIN) cover++;
      console.log(JSON.stringify({ file: out, width: res.width, height: res.height, coverage: +(cover / (res.width * res.height)).toFixed(3) }));
    } else die('用法:sprite.mjs info | density | fit | cover | check | clean | headshot(見檔頭)');
  } catch (e) {
    console.error(`錯誤:${e instanceof Fail ? e.message : e?.stack || e}`);
    process.exit(e instanceof Fail ? e.code : 2);
  }
}
