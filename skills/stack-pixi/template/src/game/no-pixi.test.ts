import { describe, expect, it } from 'vitest';

// PX-ARCH-01:純邏輯層不 import pixi(stack-pixi check-layers 也會掃;這裡讓 vitest 一起擋)
const files = import.meta.glob<string>(['../game/**/*.ts', '../services/**/*.ts', '!**/*.test.ts'], { query: '?raw', import: 'default', eager: true });

describe('PX-ARCH-01', () => {
  for (const [path, src] of Object.entries(files)) {
    it(`${path} does not import pixi`, () => {
      expect(src).not.toMatch(/from\s+['"](pixi\.js|@pixi\/[^'"]+)['"]|import\(\s*['"](pixi\.js|@pixi\/)/);
    });
  }
});
