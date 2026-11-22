#!/usr/bin/env node
// PX-LOAD-01:首屏(entry 的靜態 import 圖)只能帶 BOOT_GROUPS 的素材。
//   node check-early.mjs <專案目錄> --dist <建置輸出目錄> [--boot boot,shared] [--baseline <改動前的輸出.json>]
// 先 `vite build --outDir <暫存>/dist`(建置輸出不放專案內),再用 --dist 指向它;沒給 --dist 時讀 <專案目錄>/dist(相容舊用法)。
// BOOT_GROUPS 預設讀 src/assets/early.ts。素材(圖片 / 音訊)出現在 entry 靜態圖、而且不在 assets/<boot 群組>/ 下 → 違規(結束碼 1)。
// 結束碼:0 通過、1 違規、2 用法錯誤(含 --dist 目錄不存在 = 還沒建置、--boot 空值)、
//   3 "layout":"absent"(沒有 src/assets/early.ts 的既有專案:vite 沒開 build.manifest,或沒給 --boot)——不是違規,
//   改用專案自己的首屏檢查,沒有就列為規則落差。有 early.ts(骨架專案)時,缺 manifest 或讀不到 BOOT_GROUPS 是違規(1)。
// --baseline:違規素材去掉 Vite 的 hash 後比對,基準已有的移到 existing、不算失敗。
import { readFileSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { makeOpt, usageError, loadBaseline, splitByBaseline, EXIT, MEDIA_RE } from './_cli.mjs';

const USAGE = '用法:node check-early.mjs <專案目錄> --dist <dir> [--boot a,b] [--baseline <json>]';
const [dirArg, ...rest] = process.argv.slice(2);
if (!dirArg || dirArg.startsWith('--')) usageError('缺少 <專案目錄>', USAGE);
const dir = resolve(dirArg);
const opt = makeOpt(rest, USAGE);
const dist = resolve(dir, opt('--dist', 'dist'));
const bootOpt = opt('--boot');
const baselineFile = opt('--baseline');
const keyOf = (v) => (typeof v === 'string' ? v : v.key ?? String(v.asset).replace(/-[A-Za-z0-9_-]{8}(\.[a-z0-9]+)$/i, '$1'));
const baseline = baselineFile ? loadBaseline(baselineFile, keyOf, USAGE) : undefined;
const early = join(dir, 'src/assets/early.ts');
const skeleton = existsSync(early);
// 骨架專案缺結構 = 違規;既有專案 = layout absent
const absent = (reason) => {
  if (skeleton) { console.log(JSON.stringify({ ok: false, violations: [{ error: `${reason}(PX-LOAD-01)` }], existing: [] })); process.exit(EXIT.violation); }
  console.log(JSON.stringify({ ok: false, layout: 'absent', reason })); process.exit(EXIT.layoutAbsent);
};
if (bootOpt !== undefined && !bootOpt.split(',').some(Boolean)) usageError('--boot 不可為空', USAGE);

if (!existsSync(dist)) usageError(`找不到 ${dist}(先 vite build --outDir <暫存>/dist,再用 --dist 指定)`, USAGE);
const mf = join(dist, '.vite/manifest.json');
if (!existsSync(mf)) absent(`${mf} 不存在:vite.config 沒開 build.manifest`);
let boot = bootOpt?.split(',').filter(Boolean);
if (!boot) {
  const m = skeleton && /BOOT_GROUPS[^=]*=\s*\[([^\]]*)\]/.exec(readFileSync(early, 'utf8'));
  if (!m) absent('讀不到 src/assets/early.ts 的 BOOT_GROUPS(可用 --boot 指定)');
  boot = [...m[1].matchAll(/['"]([^'"]+)['"]/g)].map((x) => x[1]);
}
const manifest = JSON.parse(readFileSync(mf, 'utf8'));
const entries = Object.entries(manifest).filter(([, c]) => c.isEntry).map(([k]) => k);
const seen = new Set();
const assets = [];
const visit = (key) => {
  if (seen.has(key) || !manifest[key]) return;
  seen.add(key);
  const c = manifest[key];
  for (const a of c.assets ?? []) assets.push({ asset: a, via: key });
  if (MEDIA_RE.test(c.file)) assets.push({ asset: c.file, via: key });
  for (const i of c.imports ?? []) visit(i);
};
entries.forEach(visit);
const violations = assets
  .filter(({ asset }) => MEDIA_RE.test(asset) && !boot.some((g) => asset.startsWith(`assets/${g}/`)))
  .map((v) => ({ ...v, key: keyOf(v) }));
const { fresh, existing } = splitByBaseline(violations, keyOf, baseline);
console.log(JSON.stringify({ ok: fresh.length === 0, boot, entryChunks: [...seen], violations: fresh, existing, baseline: baselineFile ?? null }));
process.exit(fresh.length ? EXIT.violation : EXIT.ok);
