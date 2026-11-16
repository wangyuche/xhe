import { defineConfig } from "@playwright/test";

// 伺服器由 web-dev-kit 的 serve.sh 管,這裡不設 webServer。
// 用本機 Google Chrome(channel: "chrome"),不執行 playwright install。
const listing = process.argv.includes("--list");
const baseURL = process.env.E2E_BASE_URL;
const outputDir = process.env.E2E_OUTPUT_DIR;
if (!listing && !baseURL) throw new Error("E2E_BASE_URL is required");
if (!listing && !outputDir) throw new Error("E2E_OUTPUT_DIR is required (use the web-dev-kit tmp dir)");

export default defineConfig({
  testDir: "./e2e",
  outputDir: outputDir ?? "/tmp/playwright-list-only",
  reporter: "list",
  fullyParallel: false,
  use: {
    baseURL,
    channel: "chrome",
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
  },
});
