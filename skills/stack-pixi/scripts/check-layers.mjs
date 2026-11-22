#!/usr/bin/env node
// PX-ARCH-01:純邏輯層不 import pixi。
//   node check-layers.mjs <專案目錄> [--paths src/game,src/services]
// 掃 .ts / .mts / .js(含測試);印 {"ok":…,"violations":[{file,line,text}]},違反時結束碼 1。
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, relative } from 'node:path';
import { stripComments } from './_strip.mjs';

const [dir, ...rest] = process.argv.slice(2);
if (!dir) { console.error('用法:node check-layers.mjs <專案目錄> [--paths a,b]'); process.exit(2); }
const pi = rest.indexOf('--paths');
const paths = (pi >= 0 ? rest[pi + 1] : 'src/game,src/services').split(',').filter(Boolean);
const RE = /(from\s+['"](pixi\.js(\/[^'"]*)?|@pixi\/[^'"]*)['"])|(import\s*\(\s*['"](pixi\.js|@pixi\/))|(require\(\s*['"](pixi\.js|@pixi\/))|(^\s*import\s+['"](pixi\.js(\/[^'"]*)?|@pixi\/[^'"]*)['"])/;
const out = [];
const walk = (p) => {
  for (const f of readdirSync(p)) {
    const full = join(p, f);
    if (statSync(full).isDirectory()) { if (f !== 'node_modules') walk(full); continue; }
    if (!/\.(m?ts|m?js|tsx)$/.test(f)) continue;
    const text = readFileSync(full, 'utf8');
    const raw = text.split('\n');
    stripComments(text).split('\n').forEach((l, i) => { if (RE.test(l)) out.push({ file: relative(dir, full), line: i + 1, text: raw[i].trim() }); });
  }
};
for (const p of paths) if (existsSync(join(dir, p))) walk(join(dir, p));
console.log(JSON.stringify({ ok: out.length === 0, paths, violations: out }));
process.exit(out.length ? 1 : 0);
