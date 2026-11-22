#!/usr/bin/env node
// PX-RES-01 / PX-PERF-07:src/assets/<group>/ 的 manifest 與檔案一致、尺寸上限、KB 預算。
//   node check-assets.mjs <專案目錄> [--budgets docs/performance-budgets.md] [--art <art/assets 目錄>]
// - manifest 列的檔案都存在;目錄裡的素材檔都被 manifest 列到(沒有孤兒)。
// - PNG / JPG 尺寸:@1x ≤ 2048²、@0.5x ≤ 1024²(AVIF 與同級 PNG / JPG 同尺寸,由 build-assets 產生)。
// - 每個群組 AVIF 合計 ≤「## 素材預算」的 1x_kb / 0.5x_kb(未設定只列出)。
// - --art:另外用 scripts/schemas/validate.mjs 驗 art/assets/assets.json(含檔案存在)。
import { readFileSync, readdirSync, statSync, existsSync, openSync, readSync, closeSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [dirArg, ...rest] = process.argv.slice(2);
if (!dirArg) { console.error('用法:node check-assets.mjs <專案目錄> [--budgets <md>] [--art <dir>]'); process.exit(2); }
const dir = resolve(dirArg);
const opt = (n, d) => { const i = rest.indexOf(n); return i >= 0 ? rest[i + 1] : d; };
const budgetsFile = resolve(dir, opt('--budgets', 'docs/performance-budgets.md'));
const art = opt('--art');
const errors = [];
const report = [];

function dims(file) {
  const fd = openSync(file, 'r');
  const b = Buffer.alloc(statSync(file).size);
  const n = readSync(fd, b, 0, b.length, 0);
  closeSync(fd);
  if (b.readUInt32BE(0) === 0x89504e47) return { w: b.readUInt32BE(16), h: b.readUInt32BE(20) };
  if (b[0] === 0xff && b[1] === 0xd8) {
    for (let i = 2; i < n - 9;) {
      if (b[i] !== 0xff) { i++; continue; }
      const m = b[i + 1];
      if (m >= 0xc0 && m <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(m)) return { w: b.readUInt16BE(i + 7), h: b.readUInt16BE(i + 5) };
      i += 2 + b.readUInt16BE(i + 2);
    }
  }
  return undefined;
}

function budgets() {
  if (!existsSync(budgetsFile)) return {};
  const sec = readFileSync(budgetsFile, 'utf8').split(/^## /m).find((s) => s.startsWith('素材預算')) ?? '';
  const out = {};
  for (const line of sec.split('\n')) {
    const c = line.split('|').map((x) => x.trim());
    const n = (s) => (/^\d+(\.\d+)?/.test(s ?? '') ? parseFloat(s) : undefined);
    if (c.length >= 5 && /^[a-z0-9][a-z0-9-]*$/.test(c[1]) && /^(\d|—|-|$)/.test(c[2])) out[c[1]] = { '1x': n(c[2]), '0.5x': n(c[3]) }; // 表頭(1x_kb)不算
  }
  return out;
}

const B = budgets();
const root = join(dir, 'src/assets');
const MAX = { '1x': 2048, '0.5x': 1024 };
for (const g of existsSync(root) ? readdirSync(root) : []) {
  const gdir = join(root, g);
  if (!statSync(gdir).isDirectory()) continue;
  const mf = join(gdir, 'manifest.json');
  const files = readdirSync(gdir).filter((f) => /\.(avif|png|jpg|webp|ogg|m4a|mp3)$/.test(f));
  if (!existsSync(mf)) { if (files.length) errors.push(`${g}: 有素材檔但沒有 manifest.json`); continue; }
  let m;
  try { m = JSON.parse(readFileSync(mf, 'utf8')); } catch (e) { errors.push(`${g}/manifest.json 不是 JSON:${e.message}`); continue; }
  const listed = new Set();
  const kb = { '1x': 0, '0.5x': 0 };
  for (const [id, a] of Object.entries(m.assets ?? {})) {
    for (const [key, name] of Object.entries(a.files ?? {})) {
      listed.add(name);
      const p = join(gdir, name);
      if (!existsSync(p)) { errors.push(`${g}/${id}: 缺檔案 ${name}`); continue; }
      const tier = key.startsWith('0.5x') ? '0.5x' : key.startsWith('1x') ? '1x' : undefined;
      if (!tier) continue;
      if (name.endsWith('.avif')) kb[tier] += statSync(p).size / 1024;
      if (/\.(png|jpg)$/.test(name)) {
        const d = dims(p);
        if (!d) errors.push(`${g}/${name}: 讀不到尺寸`);
        else if (d.w > MAX[tier] || d.h > MAX[tier]) errors.push(`${g}/${name}: ${d.w}×${d.h} 超過 ${MAX[tier]}²(PX-RES-01)`);
      }
    }
  }
  for (const f of files) if (!listed.has(f)) errors.push(`${g}/${f}: manifest 沒有列到(孤兒檔)`);
  for (const tier of ['1x', '0.5x']) {
    const lim = B[g]?.[tier];
    report.push({ group: g, tier, avif_kb: Math.round(kb[tier] * 10) / 10, budget_kb: lim ?? null });
    if (lim !== undefined && kb[tier] > lim) errors.push(`${g} ${tier}: AVIF ${kb[tier].toFixed(1)} KB 超過預算 ${lim} KB(PX-PERF-07)`);
  }
}
if (art) {
  const v = join(dir, 'scripts/schemas/validate.mjs');
  if (!existsSync(v)) errors.push('找不到 scripts/schemas/validate.mjs');
  else {
    const { validate } = await import(pathToFileURL(v).href);
    const af = join(resolve(art), 'assets.json');
    if (!existsSync(af)) errors.push(`找不到 ${af}`);
    else errors.push(...validate('assets', JSON.parse(readFileSync(af, 'utf8')), { root: resolve(art) }).map((e) => `assets.json ${e}`));
  }
}
console.log(JSON.stringify({ ok: errors.length === 0, groups: report, errors }));
process.exit(errors.length ? 1 : 0);
