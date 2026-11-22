import { expect, test } from '@playwright/test';
import { RUNS, budgets, median, newPage, pressTitle, save, throttle, view } from './lib';

// 場景切換(budgets「## 場景切換」):觸發切換到 `<scene>:ready` performance mark。
// 換成真正的遊戲時,改 TRIGGER(怎麼進場景)與 SCENE。
const SCENE = process.env.PERF_SCENE || 'play';
const TRIGGER = process.env.PERF_TRIGGER || 'Start';

test('perf scene switch', async ({ browser }) => {
  const v = view();
  const runs: number[] = [];
  for (let i = 0; i < RUNS; i++) {
    const page = await newPage(browser, v);
    await page.goto('/');
    await page.waitForFunction(() => document.getElementById('loading')!.hidden);
    await throttle(page); // 首屏後才限速:量的是切換本身
    // 第一個 pointerdown 的時間 = 起點;切換完成 = `<scene>:ready` mark
    await page.evaluate(() => window.addEventListener('pointerdown', () => { (window as any).__t0 ??= performance.now(); }, { capture: true }));
    await pressTitle(page, TRIGGER, v);
    await page.waitForFunction((scene) => performance.getEntriesByName(`${scene}:ready`).length > 0, SCENE, { timeout: 60_000 });
    const ms = await page.evaluate((scene) => performance.getEntriesByName(`${scene}:ready`)[0]!.startTime - (window as any).__t0, SCENE);
    runs.push(ms);
    await page.context().close();
  }
  const out = { view: v, scene: SCENE, scene_ready_ms: median(runs), runs };
  save('scene-switch', out);
  console.log(JSON.stringify(out));
  const lim = budgets().scene_ready_ms;
  if (lim === undefined) test.info().annotations.push({ type: 'budget', description: `scene_ready_ms 未設定門檻(實測 ${Math.round(out.scene_ready_ms)})` });
  else expect(out.scene_ready_ms, `scene_ready_ms ≤ ${lim}`).toBeLessThanOrEqual(lim);
});
