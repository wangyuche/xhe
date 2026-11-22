import { expect, type Browser, type BrowserContext, type Page } from '@playwright/test';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';

/**
 * stack-pixi E2E fixture(PX-TEST-*):
 * - 透過 Pixi 8 官方 devtools hook(globalThis.__PIXI_APP_INIT__)取得 Application,不改產品碼。
 * - 包 WebGL draw* / createBuffer / deleteBuffer 計數(暫停 0 draw call、資源釋放)。
 * - 收集 pageerror / console.error:每個測試結束 expectNoErrors()。
 * - 尺寸矩陣 SIZES(+ E2E_EXTRA_SIZES,例如 "667x375@2,1801x873@1")與直式 PORTRAIT。
 * - 截圖寫 SHOTS_DIR(預設 $TMPDIR/stack-pixi-shots),不進 git。
 */
export interface Size { name: string; width: number; height: number; dsf: number; mobile: boolean }

export const SIZES: Size[] = [
  { name: '1920x1080', width: 1920, height: 1080, dsf: 1, mobile: false },
  { name: '1024x768', width: 1024, height: 768, dsf: 2, mobile: false },
  { name: '844x390@3x', width: 844, height: 390, dsf: 3, mobile: true },
  ...(process.env.E2E_EXTRA_SIZES ?? '').split(',').filter(Boolean).map((s): Size => {
    const m = /^(\d+)x(\d+)(?:@(\d+(?:\.\d+)?))?$/.exec(s.trim());
    if (!m) throw new Error(`E2E_EXTRA_SIZES 格式錯誤:${s}`);
    const dsf = Number(m[3] ?? 1);
    return { name: s.trim(), width: Number(m[1]), height: Number(m[2]), dsf, mobile: dsf > 1 && Number(m[1]) < 1000 };
  }),
];
export const PORTRAIT: Size = { name: '390x844@3x', width: 390, height: 844, dsf: 3, mobile: true };
export const SHOTS_DIR = process.env.SHOTS_DIR || join(process.env.TMPDIR || '/tmp', 'stack-pixi-shots');

const INIT = () => {
  const w = window as any;
  w.__draws = 0;
  w.__buffers = 0;
  w.__PIXI_APP_INIT__ = (app: any) => { w.__app = app; };
  for (const C of [WebGLRenderingContext, WebGL2RenderingContext]) {
    const p = C.prototype as any;
    for (const fn of ['drawElements', 'drawArrays', 'drawElementsInstanced', 'drawArraysInstanced']) {
      const orig = p[fn];
      if (orig) p[fn] = function (this: unknown, ...a: unknown[]) { w.__draws++; return orig.apply(this, a); };
    }
    const cb = p.createBuffer, db = p.deleteBuffer;
    p.createBuffer = function (this: unknown) { w.__buffers++; return cb.call(this); };
    p.deleteBuffer = function (this: unknown, b: unknown) { if (b) w.__buffers--; return db.call(this, b); };
  }
  /** 依 accessibleTitle 找 Pixi 物件,回傳畫面上的 CSS px 中心與大小(觸控座標從 bounds 算,不寫死) */
  w.__bounds = (title: string) => {
    const all: any[] = [];
    const walk = (o: any) => { all.push(o); for (const c of o.children ?? []) walk(c); };
    if (w.__app) walk(w.__app.stage);
    const shown = (x: any) => { for (let p = x; p; p = p.parent) if (!p.visible || p.destroyed) return false; return true; };
    const o = all.find((x) => x.accessibleTitle === title && shown(x));
    if (!o) return null;
    const b = o.getBounds();
    return { x: b.x + b.width / 2, y: b.y + b.height / 2, width: b.width, height: b.height };
  };
  w.__stageCount = () => { let n = 0; const walk = (o: any) => { n++; for (const c of o.children ?? []) walk(c); }; if (w.__app) walk(w.__app.stage); return n; };
};

const errors = new WeakMap<Page, string[]>();

export async function openContext(browser: Browser, size: Size, opts: { reducedMotion?: boolean } = {}): Promise<{ context: BrowserContext; page: Page }> {
  const context = await browser.newContext({
    viewport: { width: size.width, height: size.height },
    deviceScaleFactor: size.dsf,
    isMobile: size.mobile,
    hasTouch: size.mobile,
    reducedMotion: opts.reducedMotion ? 'reduce' : 'no-preference',
  });
  const page = await context.newPage();
  const list: string[] = [];
  errors.set(page, list);
  await page.addInitScript(INIT);
  page.on('pageerror', (e) => list.push(`pageerror: ${e.message}`));
  page.on('console', (m) => { if (m.type() === 'error') list.push(`console.error: ${m.text()}`); });
  return { context, page };
}

export function expectNoErrors(page: Page): void {
  expect(errors.get(page) ?? [], 'pageerror / console.error').toEqual([]);
}

/** 開頁並等到可互動(#loading 隱藏、Pixi 已掛場景)。query 會加上 a11y=1(測試模式啟用 a11y 層)。 */
export async function gotoReady(page: Page, query = ''): Promise<void> {
  const q = new URLSearchParams(query);
  q.set('a11y', '1');
  await page.goto(`/?${q}`);
  await page.waitForFunction(() => (window as any).__app?.stage?.children?.length > 0 && document.getElementById('loading')!.hidden);
}

/** 依 Pixi a11y 名稱取 a11y 層的 DOM 元素(Pixi 8 把 accessibleTitle 寫進 div 的 title;accessibleHint 寫進 aria-label)。 */
export const a11y = (page: Page, title: string) => page.locator(`[title="${title}"]`);

/** 等兩個影格(讓 Pixi 更新 world transform)再取 bounds,避免點到上一個位置。 */
export async function boundsOf(page: Page, title: string): Promise<{ x: number; y: number; width: number; height: number } | null> {
  return page.evaluate(async (t) => {
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    return (window as any).__bounds(t);
  }, title);
}

/** 觸控點擊 Pixi 物件(座標從 bounds 計算);同時檢查觸控目標 ≥ 44 CSS px(PX-INPUT-02)。 */
export async function tap(page: Page, title: string): Promise<void> {
  const b = await boundsOf(page, title);
  if (!b) throw new Error(`找不到 ${title}`);
  expect(Math.min(b.width, b.height), `${title} 觸控目標`).toBeGreaterThanOrEqual(44);
  await page.touchscreen.tap(b.x, b.y);
}

/** 滑鼠點擊 Pixi 物件(座標從 bounds 計算)。 */
export async function click(page: Page, title: string): Promise<void> {
  const b = await boundsOf(page, title);
  if (!b) throw new Error(`找不到 ${title}`);
  await page.mouse.click(b.x, b.y);
}

/** 依尺寸選輸入方式:手機用觸控,其他用滑鼠。 */
export const press = (page: Page, size: Size, title: string): Promise<void> => (size.mobile ? tap(page, title) : click(page, title));

export async function shot(page: Page, name: string): Promise<string> {
  mkdirSync(SHOTS_DIR, { recursive: true });
  const path = join(SHOTS_DIR, `${name}.png`);
  await page.screenshot({ path });
  return path;
}

export const waitMark = (page: Page, mark: string): Promise<unknown> =>
  page.waitForFunction((m) => performance.getEntriesByName(m).length > 0, mark);

/**
 * 資源快照:非 null 的 managedTextures、GL buffer、stage 物件數(Pixi 8 不壓縮陣列,null 槽不算)。
 * Pixi 8 的 GCSystem 會延遲釋放已 destroy 物件的 GPU 資源(預設閒置 60 s、每 30 s 檢查一次),
 * 所以快照前先把閒置門檻暫時調成 1 ms、等兩個影格、跑一次 gc.run(),再恢復原值。
 */
export async function resources(page: Page): Promise<{ textures: number; buffers: number; objects: number }> {
  return page.evaluate(async () => {
    const w = window as any;
    const gc = w.__app.renderer.gc;
    if (gc?.run) {
      const keep = gc.maxUnusedTime;
      await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
      gc.maxUnusedTime = 1;
      await new Promise((r) => setTimeout(r, 5));
      gc.run();
      gc.maxUnusedTime = keep;
    }
    const textures = (w.__app.renderer.texture.managedTextures as unknown[]).filter(Boolean).length;
    return { textures, buffers: w.__buffers, objects: w.__stageCount() };
  });
}

/**
 * 資源釋放(PX-LIFE-01):enter / exit 循環 n 次(預設 4),以第 2 次之後為基準,之後每次都不可增加(容許值預設 0)。
 */
export async function cycleLeak(page: Page, enter: () => Promise<void>, exit: () => Promise<void>, n = 4, tolerance = 0) {
  const snaps: Array<{ textures: number; buffers: number; objects: number }> = [];
  for (let i = 0; i < n; i++) {
    await enter();
    await exit();
    await page.waitForTimeout(100);
    snaps.push(await resources(page));
  }
  const base = snaps[1]!;
  for (const s of snaps.slice(2)) {
    expect(s.textures, `managedTextures(${JSON.stringify(snaps)})`).toBeLessThanOrEqual(base.textures + tolerance);
    expect(s.buffers, `GL buffers(${JSON.stringify(snaps)})`).toBeLessThanOrEqual(base.buffers + tolerance);
    expect(s.objects, `stage objects(${JSON.stringify(snaps)})`).toBeLessThanOrEqual(base.objects + tolerance);
  }
  return snaps;
}

/** 暫停(PX-PERF-05):模擬分頁到背景 ms 毫秒,回傳期間的 draw call 數(應為 0),之後恢復。 */
export async function drawsDuring(page: Page, ms = 500): Promise<number> {
  return page.evaluate(async (wait) => {
    const w = window as any;
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'hidden' });
    document.dispatchEvent(new Event('visibilitychange'));
    await new Promise((r) => requestAnimationFrame(() => r(null)));
    const before = w.__draws;
    await new Promise((r) => setTimeout(r, wait));
    const n = w.__draws - before;
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'visible' });
    document.dispatchEvent(new Event('visibilitychange'));
    return n;
  }, ms);
}
