import { expect, test, type Page } from '@playwright/test';
import { budgets, newPage, pixiGc, pressTitle, save, view } from './lib';

// 長時間遊玩(budgets「## 長時間遊玩」):soak_rounds 輪(前 warmup 輪暖機),比較暖機後與結束時的 heap、DOM 節點、事件監聽、stage 物件數。
// 一輪 = ROUND 做的事;換成真正的遊戲時改寫。超過 540 秒的 soak 由呼叫端用背景執行。
async function ROUND(page: Page): Promise<void> {
  await pressTitle(page, 'Start');
  for (let i = 0; i < 3; i++) await pressTitle(page, 'Hit the target');
  await page.waitForFunction(() => (document.getElementById('result-dialog') as HTMLDialogElement).open);
  await page.click('#result-close');
  await page.waitForFunction(() => (window as any).__bounds('Start'));
}

test('perf soak', async ({ browser }) => {
  const b = budgets();
  const rounds = b.soak_rounds ?? 30;
  const warmup = Math.min(10, Math.floor(rounds / 3));
  const page = await newPage(browser, view());
  await page.goto('/');
  await page.waitForFunction(() => document.getElementById('loading')!.hidden);
  const cdp = await page.context().newCDPSession(page);
  const sample = async () => {
    await pixiGc(page);
    await cdp.send('HeapProfiler.collectGarbage');
    const { metrics } = await cdp.send('Performance.getMetrics');
    const heap = metrics.find((m) => m.name === 'JSHeapUsedSize')!.value;
    const dom = await cdp.send('Memory.getDOMCounters');
    const objects = await page.evaluate(() => { let n = 0; const w = (o: any) => { n++; for (const c of o.children ?? []) w(c); }; w((window as any).__app.stage); return n; });
    return { heap, nodes: dom.nodes, listeners: dom.jsEventListeners, objects };
  };
  await cdp.send('Performance.enable');
  for (let i = 0; i < warmup; i++) await ROUND(page);
  const start = await sample();
  for (let i = warmup; i < rounds; i++) await ROUND(page);
  const end = await sample();
  const out = { view: view(), rounds, warmup, start, end, heap_pct: ((end.heap - start.heap) / start.heap) * 100 };
  save('soak', out);
  console.log(JSON.stringify(out));
  const check = (key: string, value: number) => {
    const lim = b[key];
    if (lim === undefined) test.info().annotations.push({ type: 'budget', description: `${key} 未設定門檻(實測 ${value.toFixed(1)})` });
    else expect(value, `${key} ≤ ${lim}`).toBeLessThanOrEqual(lim);
  };
  check('soak_heap_pct', out.heap_pct);
  check('soak_dom_nodes', end.nodes - start.nodes);
  check('soak_listeners', end.listeners - start.listeners);
  check('soak_objects', end.objects - start.objects);
  await page.context().close();
});
