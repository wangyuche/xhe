import { describe, expect, it } from 'vitest';

function stripComments(src: string): string {
  let out = '';
  for (let i = 0; i < src.length;) {
    const c = src[i]!, n = src[i + 1];
    if (c === "'" || c === '"' || c === '`') {
      let j = i + 1;
      while (j < src.length && src[j] !== c) { if (src[j] === '\\') j++; j++; }
      out += src.slice(i, j + 1); i = j + 1;
    } else if (c === '/' && n === '/') { const j = src.indexOf('\n', i); i = j < 0 ? src.length : j; }
    else if (c === '/' && n === '*') { const j = src.indexOf('*/', i + 2); i = j < 0 ? src.length : j + 2; }
    else { out += c; i++; }
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
