#!/usr/bin/env node
// PX-LOAD-01:首屏(entry 的靜態 import 圖)只能帶 BOOT_GROUPS 的素材。
//   node check-early.mjs <專案目錄> [--dist dist] [--boot boot,shared]
// 需要先 vite build(vite.config 開 build.manifest)。BOOT_GROUPS 預設讀 src/assets/early.ts。
// 素材(圖片 / 音訊)出現在 entry 靜態圖、而且不在 assets/<boot 群組>/ 下 → 違規(結束碼 1)。
import { readFileSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';

const [dirArg, ...rest] = process.argv.slice(2);
if (!dirArg) { console.error('用法:node check-early.mjs <專案目錄> [--dist dist] [--boot a,b]'); process.exit(2); }
const dir = resolve(dirArg);
const opt = (n, d) => { const i = rest.indexOf(n); if (i < 0) return d; if (rest[i + 1] === undefined || rest[i + 1].startsWith('--')) { console.error(`${n} 需要值`); process.exit(2); } return rest[i + 1]; };
const dist = resolve(dir, opt('--dist', 'dist'));
const mf = join(dist, '.vite/manifest.json');
if (!existsSync(mf)) { console.error(`找不到 ${mf}(先 vite build,並在 vite.config 設 build.manifest: true)`); process.exit(2); }
let boot = opt('--boot')?.split(',');
if (!boot) {
  const early = join(dir, 'src/assets/early.ts');
  const m = existsSync(early) && /BOOT_GROUPS[^=]*=\s*\[([^\]]*)\]/.exec(readFileSync(early, 'utf8'));
  if (!m) { console.error('讀不到 src/assets/early.ts 的 BOOT_GROUPS(或用 --boot 指定)'); process.exit(2); }
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
  if (/\.(avif|png|jpg|jpeg|webp|ogg|m4a|mp3)$/.test(c.file)) assets.push({ asset: c.file, via: key });
  for (const i of c.imports ?? []) visit(i);
};
entries.forEach(visit);
const MEDIA = /\.(avif|png|jpg|jpeg|webp|ogg|m4a|mp3)$/;
const violations = assets.filter(({ asset }) => MEDIA.test(asset) && !boot.some((g) => asset.startsWith(`assets/${g}/`)));
console.log(JSON.stringify({ ok: violations.length === 0, boot, entryChunks: [...seen], violations }));
process.exit(violations.length ? 1 : 0);
