/// <reference types="vitest/config" />
import { defineConfig } from 'vite';

// stack-pixi 骨架。素材輸出依群組分資料夾(assets/<group>/),pixi 單一 chunk,不內嵌 data URL(PX-LOAD-01 / 03 / 07)。
const port = Number(process.env.PORT) || 5173;

export default defineConfig({
  base: './',
  server: {
    port,
    strictPort: true,
    host: '127.0.0.1',
    // 測試產出不要觸發整頁重載
    watch: { ignored: ['**/tests/**'] },
  },
  preview: { port, strictPort: true, host: '127.0.0.1' },
  build: {
    manifest: true, // check-early 讀 dist/.vite/manifest.json 檢查首屏靜態 import 圖
    rollupOptions: {
      output: {
        assetFileNames: (info) => {
          const from = info.originalFileNames ?? [];
          const m = from.map((n) => /src\/assets\/([a-z0-9][a-z0-9-]*)\//.exec(n)).find(Boolean);
          return m ? `assets/${m[1]}/[name]-[hash][extname]` : 'assets/[name]-[hash][extname]';
        },
        manualChunks(id) {
          if (id.includes('node_modules/pixi.js') || id.includes('node_modules/@pixi')) return 'pixi';
        },
      },
    },
    assetsInlineLimit: 0,
    chunkSizeWarningLimit: 800, // pixi 單一 chunk 約 600 KB(PX-LOAD-07),gzip 後約 180 KB
    target: 'es2022',
  },
  test: {
    include: ['src/**/*.test.ts'],
    environment: 'node',
    testTimeout: 30_000,
  },
});
