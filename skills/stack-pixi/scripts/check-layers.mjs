#!/usr/bin/env node
// PX-ARCH-01:純邏輯層不 import pixi。
//   node check-layers.mjs <專案目錄> [--paths src/game,src/services] [--baseline <改動前的輸出.json>]
// 掃 .ts / .mts / .js / .tsx(含測試);印 {"ok":…,"violations":[{file,line,text,key}],"existing":[…]},有新增違反時結束碼 1。
// key = 檔案|正規化後的該行文字(不含行號);--baseline 用法同 check-i18n。
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, relative } from 'node:path';
import { stripComments } from './_strip.mjs';
import { makeOpt, usageError, loadBaseline, splitByBaseline, normText } from './_cli.mjs';

const USAGE = '用法:node check-layers.mjs <專案目錄> [--paths a,b] [--baseline <json>]';
const [dir, ...rest] = process.argv.slice(2);
if (!dir || dir.startsWith('--')) usageError('缺少 <專案目錄>', USAGE);
const opt = makeOpt(rest, USAGE);
const paths = opt('--paths', 'src/game,src/services').split(',').filter(Boolean);
const baselineFile = opt('--baseline');
const keyOf = (v) => (typeof v === 'string' ? v : v.key ?? `${v.file}|${normText(v.text)}`);
const baseline = baselineFile ? loadBaseline(baselineFile, keyOf, USAGE) : undefined;
// 行首的 side-effect import 用 [ \t]*(不用 \s*:\s 會吃掉前一行的換行,行號就算到上一行)
const RE = /(from\s+['"](pixi\.js(\/[^'"]*)?|@pixi\/[^'"]*)['"])|(import\s*\(\s*['"](pixi\.js|@pixi\/))|(require\(\s*['"](pixi\.js|@pixi\/))|(^[ \t]*import\s+['"](pixi\.js(\/[^'"]*)?|@pixi\/[^'"]*)['"])/;
const out = [];
const walk = (p) => {
  for (const f of readdirSync(p)) {
    const full = join(p, f);
    if (statSync(full).isDirectory()) { if (f !== 'node_modules') walk(full); continue; }
    if (!/\.(m?ts|m?js|tsx)$/.test(f)) continue;
    const text = readFileSync(full, 'utf8');
    const raw = text.split('\n');
    const code = stripComments(text);
    // 整個檔案一起比對(跨行的 import(\n 'pixi.js') 也抓得到);行號取比對結果第一個非空白字元的位置
    const seen = new Set();
    for (const m of code.matchAll(new RegExp(RE.source, 'gm'))) {
      const at = m.index + (m[0].length - m[0].trimStart().length);
      const line = code.slice(0, at).split('\n').length - 1;
      if (seen.has(line)) continue;
      seen.add(line);
      const file = relative(dir, full), t = raw[line].trim();
      out.push({ file, line: line + 1, text: t, key: `${file}|${normText(t)}` });
    }
  }
};
for (const p of paths) if (existsSync(join(dir, p))) walk(join(dir, p));
const { fresh, existing } = splitByBaseline(out, keyOf, baseline);
console.log(JSON.stringify({ ok: fresh.length === 0, paths, violations: fresh, existing, baseline: baselineFile ?? null }));
process.exit(fresh.length ? 1 : 0);
