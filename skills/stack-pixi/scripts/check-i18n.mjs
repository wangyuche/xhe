#!/usr/bin/env node
// PX-I18N-01:玩家看得到的文字不寫死。只檢查「流向玩家可見文字」的位置(sink),值是含字母的字串常值或樣板字串就算違規。
//   node check-i18n.mjs <專案目錄> [--src src]
// 掃 src/**(.ts / .tsx),排除 src/i18n/** 與 *.test.ts。例外:同一行或上一行加 `// i18n-ignore: <理由>`。
// sink:new Text({ text: … }) / new BitmapText({ text: … }) / new HTMLText({ text: … })、`.text =`、`textContent =`、`innerText =`、
//   setAttribute('aria-label' | 'aria-description' | 'aria-roledescription' | 'aria-valuetext' | 'title' | 'placeholder', …)、
//   `.accessibleTitle =` / `.accessibleHint =`、accessibleTitle: / accessibleHint:(物件字面值)、alert(…) / confirm(…) / prompt(…)。
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, relative } from 'node:path';
import { stripComments } from './_strip.mjs';

const [dir, ...rest] = process.argv.slice(2);
if (!dir) { console.error('用法:node check-i18n.mjs <專案目錄> [--src src]'); process.exit(2); }
const si = rest.indexOf('--src');
const src = join(dir, si >= 0 ? rest[si + 1] : 'src');
if (!existsSync(src)) { console.error(`找不到 ${src}`); process.exit(2); }

// 值:'…' / "…" / `…`(樣板字串只看 ${} 以外的字面部分)
const LIT = String.raw`('(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"|\`(?:[^\`\\]|\\.)*\`)`;
const SINKS = [
  new RegExp(String.raw`\bnew\s+(?:Text|BitmapText|HTMLText)\s*\(\s*\{(?:[^{}]|\{(?:[^{}]|\{[^{}]*\})*\})*?\btext\s*:\s*` + LIT),
  new RegExp(String.raw`\bnew\s+(?:Text|BitmapText|HTMLText)\s*\(\s*` + LIT), // Pixi 8 舊的位置參數寫法
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
    const text = readFileSync(full, 'utf8');
    const lines = text.split('\n');
    // 整個檔案一起比對(多行的 new Text({ … text: … }) 也抓得到);整行註解換成等長空白,保留位移
    const code = stripComments(text);
    const starts = [0];
    for (let i = 0; i < text.length; i++) if (text[i] === '\n') starts.push(i + 1);
    const lineOf = (off) => { let lo = 0, hi = starts.length - 1; while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (starts[mid] <= off) lo = mid; else hi = mid - 1; } return lo; };
    const seen = new Set();
    for (const re of SINKS) {
      const g = new RegExp(re.source, 'g');
      for (const m of code.matchAll(g)) {
        if (!hasLetters(m[1])) continue;
        const li = lineOf(m.index + m[0].length - m[1].length); // 字串常值所在行
        const ignored = [li, li - 1].some((k) => /\/\/\s*i18n-ignore:\s*\S/.test(lines[k] ?? ''));
        if (ignored || seen.has(li)) continue;
        seen.add(li);
        out.push({ file: relative(dir, full), line: li + 1, text: lines[li].trim() });
      }
    }
  }
};
walk(src);
console.log(JSON.stringify({ ok: out.length === 0, violations: out }));
process.exit(out.length ? 1 : 0);
