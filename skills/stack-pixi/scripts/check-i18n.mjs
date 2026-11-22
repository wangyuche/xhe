#!/usr/bin/env node
// PX-I18N-01:玩家看得到的文字不寫死。只檢查「流向玩家可見文字」的位置(sink),值是含字母的字串常值或樣板字串就算違規。
//   node check-i18n.mjs <專案目錄> [--src src] [--baseline <改動前的輸出.json>]
// 掃 src/**(.ts / .tsx),排除 src/i18n/** 與 *.test.ts。例外:同一行或上一行加 `// i18n-ignore: <理由>`。
// 每筆違規帶 key = 檔案|正規化後的該行文字(不含行號,插入或刪除行不影響)。--baseline 給改動前同一支腳本的輸出:
//   基準已有的 key 移到 existing、不算失敗;只有新增的 key(或同 key 次數變多)才結束碼 1。
// sink:new Text({ text: … }) / new BitmapText({ text: … }) / new HTMLText({ text: … })、`.text =`、`textContent =`、`innerText =`、
//   setAttribute('aria-label' | 'aria-description' | 'aria-roledescription' | 'aria-valuetext' | 'title' | 'placeholder', …)、
//   `.accessibleTitle =` / `.accessibleHint =`、accessibleTitle: / accessibleHint:(物件字面值)、alert(…) / confirm(…) / prompt(…)。
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, relative } from 'node:path';
import { stripComments } from './_strip.mjs';
import { makeOpt, usageError, loadBaseline, splitByBaseline, normText } from './_cli.mjs';

const USAGE = '用法:node check-i18n.mjs <專案目錄> [--src src] [--baseline <json>]';
const [dir, ...rest] = process.argv.slice(2);
if (!dir || dir.startsWith('--')) usageError('缺少 <專案目錄>', USAGE);
const opt = makeOpt(rest, USAGE);
const src = join(dir, opt('--src', 'src'));
const baselineFile = opt('--baseline');
if (!existsSync(src)) usageError(`找不到 ${src}`, USAGE);
const keyOf = (v) => (typeof v === 'string' ? v : v.key ?? `${v.file}|${normText(v.text)}`);
const baseline = baselineFile ? loadBaseline(baselineFile, keyOf, USAGE) : undefined;

// 值:'…' / "…" / `…`(樣板字串只看 ${} 以外的字面部分)
const LIT = String.raw`('(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"|\`(?:[^\`\\]|\\.)*\`)`;
const SINKS = [
  new RegExp(String.raw`\bnew\s+(?:Text|BitmapText|HTMLText)\s*\(\s*\{(?:[^{}]|\{(?:[^{}]|\{[^{}]*\})*\})*?\btext\s*:\s*` + LIT),
  new RegExp(String.raw`\bnew\s+(?:Text|BitmapText|HTMLText)\s*\(\s*` + LIT), // Pixi 8 舊的位置參數寫法
  new RegExp(String.raw`\.(?:text|textContent|innerText|accessibleTitle|accessibleHint)\s*\+?=(?!=)\s*` + LIT),
  // 三元運算:x.text = cond ? 'A' : 'B'(抓 ? 或 : 後面的字串)
  new RegExp(String.raw`\.(?:text|textContent|innerText|accessibleTitle|accessibleHint)\s*\+?=(?!=)[^;\n(]*?[?:]\s*` + LIT), // 右邊有函式呼叫(例如 t(cond ? 'a.key' : 'b.key'))就不算
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
        const file = relative(dir, full), t = lines[li].trim();
        out.push({ file, line: li + 1, text: t, key: `${file}|${normText(t)}` });
      }
    }
  }
};
walk(src);
const { fresh, existing } = splitByBaseline(out, keyOf, baseline);
console.log(JSON.stringify({ ok: fresh.length === 0, violations: fresh, existing, baseline: baselineFile ?? null }));
process.exit(fresh.length ? 1 : 0);
