#!/usr/bin/env node
// game-art-kit:遊戲素材的 PNG 處理(純 Node,不需要任何套件)。尺寸一律是 1x 檔案像素(= 顯示尺寸 × density)。
// 用法:
//   node sprite.mjs info <png>                                           → {width,height,channels,coverage,bbox}
//   node sprite.mjs fit <in.png>... --out <out.png> --width W --height H [--align bottom|center] [--margin px]
//        裁掉透明邊 → 同一個縮放比例(以最大的那張為準,確保每張都放得下)→ 置中 / 底部對齊補到 W×H。
//        --margin 0(只限單張):裁邊後直接縮放到 W×H、不留透明邊(UI / 九宮格,切線才會對齊圖的邊緣)。
//        多張輸入 = 同一動作的各格:拼成 sheet(橫向排列,寬超過 2048 換行),印出 columns / rows。
//   node sprite.mjs cover <in.png> --out <out.png> --width W --height H
//        不透明素材(背景、地圖塊):等比縮放到蓋滿 W×H 再置中裁切(不留透明邊)。
//   node sprite.mjs check <png> --width W --height H [--frames N --columns C] [--opaque] [--tileable] [--character]
//        有 alpha(--opaque 除外)、尺寸 = 1x(frames 時 = W×columns by H×rows)、每格主體覆蓋率 10–90%、
//        外框 2 px 內 alpha>0 的像素 < 1%、各格腳底基線差 ≤ 2 px 與主體高度差 ≤ 10%(--character 且多格)、
//        --tileable:左右、上下邊緣像素平均差 ≤ 8(0–255)。--full-bleed(UI / 九宮格,fit --margin 0 的產出):不檢查外框與覆蓋率上限。印 {"ok":…,"errors":[…],"frames":[…]},不通過結束碼 1。
// 結束碼:0 成功;1 檢查不通過;2 用法或檔案錯誤。
import { readFileSync, writeFileSync, mkdirSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
import { inflateSync, deflateSync, crc32 } from 'node:zlib';

class Fail extends Error { constructor(m, c) { super(m); this.code = c; } }
const die = (m, c = 2) => { throw new Fail(m, c); };

// ---------- PNG 解碼(8 / 16 bit、灰階 / RGB / 調色盤 / alpha,不支援 interlace)→ RGBA8 ----------
export function decodePng(buf) {
  if (buf.length < 8 || buf.readUInt32BE(0) !== 0x89504e47) die('不是 PNG');
  let p = 8, ihdr, plte, trns; const idat = [];
  while (p < buf.length) {
    const len = buf.readUInt32BE(p), type = buf.toString('ascii', p + 4, p + 8), data = buf.subarray(p + 8, p + 8 + len);
    if (type === 'IHDR') ihdr = { w: data.readUInt32BE(0), h: data.readUInt32BE(4), depth: data[8], ct: data[9], interlace: data[12] };
    else if (type === 'PLTE') plte = data; else if (type === 'tRNS') trns = data; else if (type === 'IDAT') idat.push(data); else if (type === 'IEND') break;
    p += 12 + len;
  }
  if (!ihdr) die('PNG 沒有 IHDR');
  const { w, h, depth, ct, interlace } = ihdr;
  if (interlace) die('不支援 interlace PNG');
  if (![8, 16].includes(depth) && !(ct === 3 && depth <= 8)) die(`不支援的 bit depth ${depth}`);
  const ch = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[ct]; if (!ch) die(`不支援的色彩類型 ${ct}`);
  const bpp = Math.max(1, (ch * depth) / 8), stride = Math.ceil((w * ch * depth) / 8);
  const raw = inflateSync(Buffer.concat(idat)), px = Buffer.alloc(stride * h);
  let prev = Buffer.alloc(stride);
  for (let y = 0; y < h; y++) {
    const f = raw[y * (stride + 1)], row = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1)), out = px.subarray(y * stride, (y + 1) * stride);
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
    }
  }
  return { width: w, height: h, data: rgba, hasAlpha: ct === 4 || ct === 6 || (ct === 3 && !!trns) };
}

export function encodePng({ width: w, height: h, data }) {
  const chunk = (type, d) => { const b = Buffer.alloc(12 + d.length); b.writeUInt32BE(d.length, 0); b.write(type, 4); d.copy(b, 8); b.writeUInt32BE(crc32(Buffer.concat([Buffer.from(type), d])) >>> 0, 8 + d.length); return b; };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) { raw[y * (w * 4 + 1)] = 0; data.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4); }
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}

const blank = (w, h) => ({ width: w, height: h, data: Buffer.alloc(w * h * 4) });

// alpha > 0 的外接矩形(沒有就 null)
export function bbox(img, x0 = 0, y0 = 0, w = img.width, h = img.height) {
  let minX = Infinity, minY = Infinity, maxX = -1, maxY = -1;
  for (let y = y0; y < y0 + h; y++) for (let x = x0; x < x0 + w; x++) if (img.data[(y * img.width + x) * 4 + 3] > 0) {
    if (x < minX) minX = x; if (x > maxX) maxX = x; if (y < minY) minY = y; if (y > maxY) maxY = y;
  }
  return maxX < 0 ? null : { x: minX - x0, y: minY - y0, w: maxX - minX + 1, h: maxY - minY + 1 };
}

// 區域平均縮放(premultiplied alpha,放大縮小都可),src 的 (sx,sy,sw,sh) → dw×dh
function resample(src, sx, sy, sw, sh, dw, dh) {
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

function blit(dst, src, dx, dy) {
  for (let y = 0; y < src.height; y++) for (let x = 0; x < src.width; x++) {
    const tx = dx + x, ty = dy + y; if (tx < 0 || ty < 0 || tx >= dst.width || ty >= dst.height) continue;
    src.data.copy(dst.data, (ty * dst.width + tx) * 4, (y * src.width + x) * 4, (y * src.width + x) * 4 + 4);
  }
}

export const sheetLayout = (count, w) => { const columns = Math.max(1, Math.min(count, Math.floor(2048 / w))); return { columns, rows: Math.ceil(count / columns) }; };

// 多張(同一動作)用同一縮放比例放進 W×H;回傳 sheet 影像
export function fit(imgs, W, H, { align = 'bottom', margin } = {}) {
  const m = margin ?? Math.max(4, Math.round(Math.min(W, H) * 0.03));
  if (m === 0 && imgs.length === 1) { const b = bbox(imgs[0]) ?? die('第 1 張是全透明', 1); return { sheet: resample(imgs[0], b.x, b.y, b.w, b.h, W, H), columns: 1, rows: 1, scale: W / b.w, margin: 0 }; }
  const boxes = imgs.map((im, i) => bbox(im) ?? die(`第 ${i + 1} 張是全透明`, 1));
  const maxW = Math.max(...boxes.map(b => b.w)), maxH = Math.max(...boxes.map(b => b.h));
  if (m === 0) die('--margin 0 只用於單張(UI / 九宮格:裁邊後直接縮放到 W×H)');
  if (W - 2 * m <= 0 || H - 2 * m <= 0) die('尺寸太小,扣掉邊界後沒有空間');
  const s = Math.min((W - 2 * m) / maxW, (H - 2 * m) / maxH);
  const { columns, rows } = sheetLayout(imgs.length, W);
  if (rows * H > 2048) die(`sheet 高 ${rows * H} 超過 2048`);
  const sheet = blank(W * columns, H * rows);
  imgs.forEach((im, i) => {
    const b = boxes[i], dw = Math.max(1, Math.round(b.w * s)), dh = Math.max(1, Math.round(b.h * s));
    const cell = resample(im, b.x, b.y, b.w, b.h, dw, dh);
    const cx = (i % columns) * W, cy = Math.floor(i / columns) * H;
    const dx = cx + Math.round((W - dw) / 2), dy = cy + (align === 'bottom' ? H - m - dh : Math.round((H - dh) / 2));
    blit(sheet, cell, dx, dy);
  });
  return { sheet, columns, rows, scale: s, margin: m };
}

export function cover(img, W, H) {
  const s = Math.max(W / img.width, H / img.height), sw = W / s, sh = H / s;
  return resample(img, (img.width - sw) / 2, (img.height - sh) / 2, sw, sh, W, H);
}

export function checkImage(img, { width: W, height: H, frames = 1, columns, opaque = false, tileable = false, character = false, fullBleed = false }) {
  const errs = [], info = [];
  const cols = columns ?? (frames > 1 ? sheetLayout(frames, W).columns : 1), rows = Math.ceil(frames / cols);
  if (!opaque && !img.hasAlpha) errs.push('沒有 alpha 通道(應為透明 PNG)');
  if (img.width !== W * cols || img.height !== H * rows) errs.push(`尺寸 ${img.width}×${img.height},應為 ${W * cols}×${H * rows}`);
  if (img.width !== W * cols || img.height !== H * rows) return { errs, info };
  for (let i = 0; i < frames; i++) {
    const x0 = (i % cols) * W, y0 = Math.floor(i / cols) * H;
    let cover = 0, border = 0, borderN = 0;
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      const a = img.data[((y0 + y) * img.width + x0 + x) * 4 + 3];
      if (a > 0) cover++;
      if (x < 2 || y < 2 || x >= W - 2 || y >= H - 2) { borderN++; if (a > 0) border++; }
    }
    const b = bbox(img, x0, y0, W, H);
    const f = { frame: i + 1, coverage: +(cover / (W * H)).toFixed(3), border: +(border / borderN).toFixed(4), baseline: b ? b.y + b.h : null, height: b?.h ?? 0 };
    info.push(f);
    if (!opaque) {
      if (f.coverage < 0.1 || (!fullBleed && f.coverage > 0.9)) errs.push(`第 ${i + 1} 格主體覆蓋率 ${(f.coverage * 100).toFixed(1)}%(應 10–90%)`);
      if (!fullBleed && f.border >= 0.01) errs.push(`第 ${i + 1} 格外框 2 px 內有 ${(f.border * 100).toFixed(2)}% 不透明像素(應 < 1%;去背殘留或主體貼邊)`);
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

// ---------- CLI ----------
// skill 目錄常是連結:argv[1] 保留連結路徑、import.meta.url 是實際路徑,要比 realpath
const isMain = (() => { try { return !!process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } })();
if (isMain) {
  try {
    const [cmd, ...rest] = process.argv.slice(2);
    const flags = {}, pos = [];
    for (let i = 0; i < rest.length; i++) {
      const a = rest[i];
      if (['--opaque', '--tileable', '--character', '--full-bleed'].includes(a)) flags[a.slice(2)] = true;
      else if (a.startsWith('--')) flags[a.slice(2)] = rest[++i] ?? die(`${a} 缺值`);
      else pos.push(a);
    }
    const int = (k, req = true, min = 1) => { const v = flags[k]; if (v == null) return req ? die(`缺 --${k}`) : undefined; if (!/^\d+$/.test(v) || +v < min) die(`--${k} 要是 ≥ ${min} 的整數`); return +v; };
    const load = (f) => { let b; try { b = readFileSync(f); } catch (e) { die(`讀不到 ${f}:${e.message}`); } return decodePng(b); };
    if (cmd === 'info') {
      const img = load(pos[0] ?? die('用法:info <png>'));
      const b = bbox(img); let cover = 0; for (let i = 3; i < img.data.length; i += 4) if (img.data[i] > 0) cover++;
      console.log(JSON.stringify({ width: img.width, height: img.height, hasAlpha: img.hasAlpha, coverage: +(cover / (img.width * img.height)).toFixed(3), bbox: b }));
    } else if (cmd === 'fit') {
      if (!pos.length) die('用法:fit <in.png>... --out <out.png> --width W --height H');
      const out = flags.out ?? die('缺 --out');
      const align = flags.align ?? 'bottom'; if (!['bottom', 'center'].includes(align)) die('--align 只能 bottom 或 center');
      if (pos.length > 8) die('一個動作最多 8 格');
      const r = fit(pos.map(load), int('width'), int('height'), { align, margin: flags.margin != null ? int('margin', true, 0) : undefined });
      mkdirSync(dirname(out), { recursive: true });
      writeFileSync(out, encodePng(r.sheet));
      console.log(JSON.stringify({ file: out, width: r.sheet.width, height: r.sheet.height, frames: pos.length, columns: r.columns, rows: r.rows, scale: +r.scale.toFixed(4), margin: r.margin }));
    } else if (cmd === 'cover') {
      const out = flags.out ?? die('缺 --out');
      const r = cover(load(pos[0] ?? die('用法:cover <in.png> --out <out.png> --width W --height H')), int('width'), int('height'));
      mkdirSync(dirname(out), { recursive: true });
      writeFileSync(out, encodePng(r));
      console.log(JSON.stringify({ file: out, width: r.width, height: r.height }));
    } else if (cmd === 'check') {
      const img = load(pos[0] ?? die('用法:check <png> --width W --height H'));
      const frames = flags.frames != null ? int('frames') : 1;
      if (frames > 8) die('frames 最多 8');
      const { errs, info } = checkImage(img, { width: int('width'), height: int('height'), frames, columns: flags.columns != null ? int('columns') : undefined, opaque: !!flags.opaque, tileable: !!flags.tileable, character: !!flags.character, fullBleed: !!flags['full-bleed'] });
      console.log(JSON.stringify({ ok: errs.length === 0, errors: errs, frames: info }));
      process.exit(errs.length ? 1 : 0);
    } else die('用法:sprite.mjs info | fit | cover | check(見檔頭)');
  } catch (e) {
    console.error(`錯誤:${e instanceof Fail ? e.message : e?.stack || e}`);
    process.exit(e instanceof Fail ? e.code : 2);
  }
}
