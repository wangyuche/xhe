import { describe, expect, it } from 'vitest';

// 與 stack-pixi scripts/_strip.mjs 相同的規則:註解換成空白,跳過字串、樣板字串與 regex 字面值
function stripComments(src: string): string {
  let out = '';
  let prev = '';
  for (let i = 0; i < src.length;) {
    const c = src[i]!, n = src[i + 1];
    if (c === "'" || c === '"' || c === '`') {
      let j = i + 1;
      while (j < src.length && src[j] !== c) { if (src[j] === '\\') j++; else if (c !== '`' && src[j] === '\n') break; j++; }
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
