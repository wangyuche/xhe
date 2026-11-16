import { expect, test } from "@playwright/test";

// 骨架自帶的煙霧測試;驗收情境的測試另開檔案,名稱以情境編號開頭,例如 test("LOGIN-S1: …")。
test("smoke: home page loads", async ({ page }) => {
  const res = await page.goto("/");
  expect(res?.status()).toBe(200);
});
