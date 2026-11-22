import { expect, test } from '@playwright/test';
import { RUNS, budgets, median, newPage, save, throttle, view } from './lib';

// 首屏(budgets「## 首屏」「## 傳輸量」):FCP、可互動(#loading 隱藏)、可互動前傳輸量(requestfinished 加總)、可互動前 TBT。
test('perf first screen', async ({ browser }) => {
  const v = view();
  const runs: Array<{ fcp: number; interactive: number; bytes: number; tbt: number }> = [];
  for (let i = 0; i < RUNS; i++) {
    const page = await newPage(browser, v);
    await page.addInitScript(() => {
      const w = window as any;
      w.__tbt = 0;
      new PerformanceObserver((l) => { for (const e of l.getEntries()) if (!w.__interactiveAt) w.__tbt += Math.max(0, e.duration - 50); }).observe({ type: 'longtask', buffered: true });
      const watch = () => {
        const el = document.getElementById('loading');
        if (!el) return requestAnimationFrame(watch);
        const check = () => { if (el.hidden && !w.__interactiveAt) { w.__interactiveAt = performance.now(); w.__onInteractive?.(); } };
        new MutationObserver(check).observe(el, { attributes: true, attributeFilter: ['hidden'] });
        check();
      };
      watch();
    });
    await throttle(page);
    let bytes = 0;
    let interactive = false;
    await page.exposeFunction('__onInteractive', () => { interactive = true; }); // 可互動當下就停止計入,不等下一次輪詢
    page.on('requestfinished', async (r) => {
      if (interactive) return;
      try { const s = await r.sizes(); bytes += s.responseBodySize + s.responseHeadersSize; } catch { /* 已關閉 */ }
    });
    await page.goto('/');
    await page.waitForFunction(() => (window as any).__interactiveAt, null, { timeout: 90_000 });
    interactive = true;
    const m = await page.evaluate(() => ({
      fcp: performance.getEntriesByName('first-contentful-paint')[0]?.startTime ?? NaN,
      interactive: (window as any).__interactiveAt as number,
      tbt: (window as any).__tbt as number,
    }));
    runs.push({ ...m, bytes });
    await page.context().close();
  }
  const out = { view: v, fcp_ms: median(runs.map((r) => r.fcp)), interactive_ms: median(runs.map((r) => r.interactive)),
    boot_kb: median(runs.map((r) => r.bytes)) / 1024, tbt_ms: median(runs.map((r) => r.tbt)), runs };
  save('first-screen', out);
  console.log(JSON.stringify(out));
  const b = budgets();
  for (const key of ['fcp_ms', 'interactive_ms', 'boot_kb', 'tbt_ms'] as const) {
    const lim = b[key];
    if (lim === undefined) test.info().annotations.push({ type: 'budget', description: `${key} 未設定門檻(實測 ${Math.round(out[key])})` });
    else expect(out[key], `${key} ≤ ${lim}`).toBeLessThanOrEqual(lim);
  }
});
