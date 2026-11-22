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
      w.__longtasks = [] as Array<{ start: number; duration: number }>;
      new PerformanceObserver((l) => { for (const e of l.getEntries()) w.__longtasks.push({ start: e.startTime, duration: e.duration }); }).observe({ type: 'longtask', buffered: true });
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
    const pendingSizes: Promise<void>[] = [];
    await page.exposeFunction('__onInteractive', () => { interactive = true; }); // 可互動當下就停止計入,不等下一次輪詢
    // 可互動之前「開始」的請求都算(包括可互動時還在下載的),完成時才加大小
    const early = new Set<unknown>();
    page.on('request', (r) => { if (!interactive) early.add(r); });
    page.on('requestfinished', (r) => {
      if (!early.has(r)) return;
      pendingSizes.push(r.sizes().then((s) => { bytes += s.responseBodySize + s.responseHeadersSize; }, () => {}));
    });
    await page.goto('/');
    await page.waitForFunction(() => (window as any).__interactiveAt, null, { timeout: 90_000 });
    interactive = true;
    await page.waitForTimeout(100); // 讓可互動那個 long task 的 entry 送達
    await page.waitForLoadState('networkidle').catch(() => {}); // 等可互動前開始的下載完成
    await Promise.all(pendingSizes);
    const m = await page.evaluate(() => {
      const w = window as any;
      const at = w.__interactiveAt as number;
      // TBT:開始時間在可互動之前的 long task(含觸發可互動的那一個)
      const tbt = (w.__longtasks as Array<{ start: number; duration: number }>).filter((e) => e.start < at).reduce((s, e) => s + Math.max(0, e.duration - 50), 0);
      return { fcp: performance.getEntriesByName('first-contentful-paint')[0]?.startTime ?? NaN, interactive: at, tbt };
    });
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
