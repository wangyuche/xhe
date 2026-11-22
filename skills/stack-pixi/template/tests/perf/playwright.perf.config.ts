import { defineConfig } from '@playwright/test';

// 效能量測:對 production build(scripts/serve-dist.mjs,gzip)。PERF_BASE_URL 由呼叫端帶(serve.sh 的 PORT)。
// 一次只跑一個尺寸(PERF_VIEW=desktop|phone),讓每次 Bash 呼叫在 600 秒內。
export default defineConfig({
  testDir: '.',
  testMatch: /.*\.perf\.spec\.ts/,
  outputDir: process.env.PERF_OUTPUT_DIR || './results/pw',
  workers: 1,
  retries: 0,
  timeout: 540_000,
  reporter: [['list']],
  use: { baseURL: process.env.PERF_BASE_URL || `http://127.0.0.1:${process.env.PORT || 4175}`, channel: 'chrome', headless: !process.env.HEADED },
});
