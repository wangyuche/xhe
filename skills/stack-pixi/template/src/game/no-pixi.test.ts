import { describe, expect, it } from 'vitest';

// 樣板字串的結尾(處理 ${ … } 內的巢狀字串與樣板字串);i 指向開頭的 `
function templateEnd(src: string, i: number): number {
  let j = i + 1;
  while (j < src.length) {
    const c = src[j];
    if (c === '\\') { j += 2; continue; }
    if (c === '`') return j;
    if (c === '$' && src[j + 1] === '{') {
      let depth = 1; j += 2;
      while (j < src.length && depth > 0) {
        const d = src[j];
        if (d === '`') { j = templateEnd(src, j) + 1; continue; }
        if (d === "'" || d === '"') { let k = j + 1; while (k < src.length && src[k] !== d && src[k] !== '\n') { if (src[k] === '\\') k++; k++; } j = k + 1; continue; }
        if (d === '{') depth++; else if (d === '}') depth--;
        j++;
      }
      continue;
    }
    j++;
  }
  return src.length;
}

// 與 stack-pixi scripts/_strip.mjs 相同的規則:註解換成空白,跳過字串、樣板字串與 regex 字面值
function stripComments(src: string): string {
  let out = '';
  let prev = '';
  for (let i = 0; i < src.length;) {
    const c = src[i]!, n = src[i + 1];
    if (c === '`') {
      const j = templateEnd(src, i);
      out += src.slice(i, j + 1); i = j + 1; prev = c;
    } else if (c === "'" || c === '"') {
      let j = i + 1;
      while (j < src.length && src[j] !== c) { if (src[j] === '\\') j++; else if (src[j] === '\n') break; j++; }
      out += src.slice(i, j + 1); i = j + 1; prev = c;
    } else if (c === '/' && n === '/') {
      let j = src.indexOf('\n', i); if (j < 0) j = src.length;
      out += ' '.repeat(j - i); i = j;
    } else if (c === '/' && n === '*') {
      let j = src.indexOf('*/', i + 2); j = j < 0 ? src.length : j + 2;
      out += src.slice(i, j).replace(/[^\n]/g, ' '); i = j;
    } else if (c === '/' && (prev === '' || /[(,=:[!&|?{};+\-*%<>~^]/.test(prev) || /\b(return|typeof|case|in|of)$/.test(out.trimEnd()))) {
      let j = i + 1, cls = false;
      while (j < src.length && src[j] !== '\n') {
        if (src[j] === '\\') { j += 2; continue; }
        if (src[j] === '[') cls = true; else if (src[j] === ']') cls = false; else if (src[j] === '/' && !cls) break;
        j++;
      }
      out += src.slice(i, j + 1); i = j + 1; prev = '/';
    } else { out += c; if (!/\s/.test(c)) prev = c; i++; }
  }
  return out;
}

// PX-ARCH-01:純邏輯層不 import pixi(stack-pixi check-layers 也會掃;這裡讓 vitest 一起擋)
const files = import.meta.glob<string>(['../game/**/*.ts', '../services/**/*.ts', '!**/*.test.ts'], { query: '?raw', import: 'default', eager: true });

describe('PX-ARCH-01', () => {
  for (const [path, src] of Object.entries(files)) {
    it(`${path} does not import pixi`, () => {
      const code = stripComments(src); // 註解裡的 import 不算(會跳過字串裡的 /* 與 //)
      expect(code).not.toMatch(/(from\s+|import\s+)['"](pixi\.js(\/[^'"]*)?|@pixi\/[^'"]+)['"]|import\(\s*['"](pixi\.js|@pixi\/)/);
    });
  }
});
