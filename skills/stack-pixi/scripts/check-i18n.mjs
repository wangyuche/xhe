#!/usr/bin/env node
// PX-I18N-01:玩家看得到的文字不寫死。只檢查「流向玩家可見文字」的位置(sink),值是含字母的字串常值或樣板字串就算違規。
//   node check-i18n.mjs <專案目錄> [--src src]
// 掃 src/**(.ts / .tsx),排除 src/i18n/** 與 *.test.ts。例外:同一行或上一行加 `// i18n-ignore: <理由>`。
// sink:new Text({ text: … }) / new BitmapText({ text: … }) / new HTMLText({ text: … })、`.text =`、`textContent =`、`innerText =`、
//   setAttribute('aria-label' | 'aria-description' | 'aria-roledescription' | 'aria-valuetext' | 'title' | 'placeholder', …)、
//   `.accessibleTitle =` / `.accessibleHint =`、accessibleTitle: / accessibleHint:(物件字面值)、alert(…) / confirm(…) / prompt(…)。
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, relative } from 'node:path';

const [dir, ...rest] = process.argv.slice(2);
if (!dir) { console.error('用法:node check-i18n.mjs <專案目錄> [--src src]'); process.exit(2); }
const si = rest.indexOf('--src');
const src = join(dir, si >= 0 ? rest[si + 1] : 'src');
if (!existsSync(src)) { console.error(`找不到 ${src}`); process.exit(2); }

// 值:'…' / "…" / `…`(樣板字串只看 ${} 以外的字面部分)
const LIT = String.raw`('(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"|\`(?:[^\`\\]|\\.)*\`)`;
const SINKS = [
  new RegExp(String.raw`\bnew\s+(?:Text|BitmapText|HTMLText)\s*\(\s*\{(?:[^{}]|\{[^{}]*\})*?\btext\s*:\s*` + LIT),
  new RegExp(String.raw`\.(?:text|textContent|innerText|accessibleTitle|accessibleHint)\s*=(?!=)\s*` + LIT),
  new RegExp(String.raw`\b(?:accessibleTitle|accessibleHint)\s*:\s*` + LIT),
  new RegExp(String.raw`\bsetAttribute\(\s*['"](?:aria-label|aria-description|aria-roledescription|aria-valuetext|title|placeholder)['"]\s*,\s*` + LIT),
  new RegExp(String.raw`(?<![\w.])(?:alert|confirm|prompt)\(\s*` + LIT),
];
const hasLetters = (lit) => /\p{L}/u.test(lit.slice(1, -1).replace(/\$\{[^}]*\}/g, ''));

const out = [];
const walk = (p) => {
  for (const f of readdirSync(p)) {
    const full = join(p, f);
    const rel = relative(src, full);
    if (statSync(full).isDirectory()) { if (f !== 'node_modules' && !(rel === 'i18n')) walk(full); continue; }
    if (!/\.tsx?$/.test(f) || /\.test\.tsx?$/.test(f)) continue;
    const lines = readFileSync(full, 'utf8').split('\n');
    lines.forEach((l, i) => {
      if (/\/\/\s*i18n-ignore:\s*\S/.test(l) || /\/\/\s*i18n-ignore:\s*\S/.test(lines[i - 1] ?? '')) return;
      const code = l.replace(/^\s*\/\/.*$/, '');
      for (const re of SINKS) {
        const m = re.exec(code);
        if (m && hasLetters(m[1])) { out.push({ file: relative(dir, full), line: i + 1, text: l.trim() }); break; }
      }
    });
  }
};
walk(src);
console.log(JSON.stringify({ ok: out.length === 0, violations: out }));
process.exit(out.length ? 1 : 0);
