import { defineConfig } from '@playwright/test';

// E2E 對 dev server(serve.sh 啟動,PORT 傳進 BASE_URL)。系統 Chrome、headless、workers 1(visibility / 焦點測試不可並行)。
// 尺寸矩陣由 tests/e2e/fixtures/base.ts 的 SIZES 在各 spec 內逐一建立 context。
export default defineConfig({
  testDir: './tests/e2e/specs',
  outputDir: process.env.E2E_OUTPUT_DIR || './tests/e2e/test-results',
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 60_000,
  reporter: [['list']],
  use: {
    baseURL: process.env.BASE_URL || `http://127.0.0.1:${process.env.PORT || 5173}`,
    channel: 'chrome',
    headless: !process.env.HEADED,
    trace: 'retain-on-failure',
  },
  projects: [{ name: 'chrome' }],
});
