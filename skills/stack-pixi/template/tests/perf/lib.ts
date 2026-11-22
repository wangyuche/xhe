import { appendFileSync, mkdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { Browser, CDPSession, Page } from '@playwright/test';

/**
 * 量測共用(PX-PERF-01 / 02):Slow 4G + 4× CPU(CDP)、冷快取、每次新 context、取中位數;門檻讀 docs/performance-budgets.md。
 * page 的 CDP session 設的網路條件也套用到 dedicated Worker 的 fetch(Chrome 實測;stack-pixi 自我測試有一項檢查,Chrome 改變行為時會失敗)。
 */
export const SLOW4G = { offline: false, latency: 562.5, downloadThroughput: (1.44 * 1024 * 1024) / 8, uploadThroughput: (675 * 1024) / 8 };
export const VIEWS = {
  desktop: { width: 1920, height: 1080, dsf: 1, mobile: false },
  phone: { width: 844, height: 390, dsf: 3, mobile: true },
} as const;
export type ViewName = keyof typeof VIEWS;
export const view = (): ViewName => (process.env.PERF_VIEW === 'phone' ? 'phone' : 'desktop');
export const RUNS = Number(process.env.PERF_RUNS) || 5;

const HERE = dirname(fileURLToPath(import.meta.url));

/** 讀 budgets:每節的 `| key | 數值 |` 表格列,數值後可接「(推定)」;`—` 或空白 = 未設定。 */
export function budgets(): Record<string, number | undefined> {
  const md = readFileSync(join(HERE, '../../docs/performance-budgets.md'), 'utf8');
  const out: Record<string, number | undefined> = {};
  for (const line of md.split('\n')) {
    const c = line.split('|').map((x) => x.trim());
    if (c.length >= 4 && /^[a-z][a-z0-9_]*$/.test(c[1]!)) {
      const m = /^-?\d+(\.\d+)?/.exec(c[2]!);
      out[c[1]!] = m ? parseFloat(m[0]) : undefined;
    }
  }
  return out;
}

export async function throttle(page: Page, cpu = 4): Promise<CDPSession> {
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Network.enable');
  await cdp.send('Network.setCacheDisabled', { cacheDisabled: true });
  await cdp.send('Network.emulateNetworkConditions', SLOW4G);
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: cpu });
  return cdp;
}

export async function newPage(browser: Browser, v: ViewName): Promise<Page> {
  const s = VIEWS[v];
  const ctx = await browser.newContext({ viewport: { width: s.width, height: s.height }, deviceScaleFactor: s.dsf, isMobile: s.mobile, hasTouch: s.mobile });
  const page = await ctx.newPage();
  await page.addInitScript(() => {
    const w = window as any;
    w.__PIXI_APP_INIT__ = (app: any) => { w.__app = app; };
    w.__bounds = (title: string) => {
      const all: any[] = [];
      const walk = (o: any) => { all.push(o); for (const c of o.children ?? []) walk(c); };
      if (w.__app) walk(w.__app.stage);
      const shown = (x: any) => { for (let p = x; p; p = p.parent) if (!p.visible || p.destroyed) return false; return true; };
      const o = all.find((x) => x.accessibleTitle === title && shown(x));
      if (!o) return null;
      const b = o.getBounds();
      return { x: b.x + b.width / 2, y: b.y + b.height / 2 };
    };
  });
  return page;
}

/** 依 Pixi 物件的 accessibleTitle 點擊(座標從 bounds 算;手機用觸控)。手機模擬下 Pixi 不建立 a11y div,所以量測不用 [title=] 選擇器。 */
export async function pressTitle(page: Page, title: string, v: ViewName = view()): Promise<void> {
  const b = await page.waitForFunction(async (t) => {
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    return (window as any).__bounds(t);
  }, title, { timeout: 60_000 }).then((h) => h.jsonValue()) as { x: number; y: number };
  if (VIEWS[v].mobile) await page.touchscreen.tap(b.x, b.y);
  else await page.mouse.click(b.x, b.y);
}

/** Pixi 8 的 GCSystem 延遲釋放 GPU 資源(預設閒置 60 s);量記憶體前強制跑一次。 */
export async function pixiGc(page: Page): Promise<void> {
  await page.evaluate(async () => {
    const gc = (window as any).__app?.renderer?.gc;
    if (!gc?.run) return;
    const keep = gc.maxUnusedTime;
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    gc.maxUnusedTime = 1;
    await new Promise((r) => setTimeout(r, 5));
    gc.run();
    gc.maxUnusedTime = keep;
  });
}

export const median = (xs: number[]): number => { const s = [...xs].sort((a, b) => a - b); return s[Math.floor(s.length / 2)]!; };

export function save(name: string, data: unknown): void {
  const dir = process.env.PERF_RESULTS_DIR || join(HERE, 'results');
  mkdirSync(dir, { recursive: true });
  appendFileSync(join(dir, 'perf.jsonl'), JSON.stringify({ name, at: new Date().toISOString(), ...(data as object) }) + '\n');
}

/** 有設定門檻才斷言;未設定時回傳 false(呼叫端加 annotation)。 */
export function limit(b: Record<string, number | undefined>, key: string): number | undefined {
  return b[key];
}
