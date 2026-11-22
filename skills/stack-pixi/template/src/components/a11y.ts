import type { Container } from 'pixi.js';

/**
 * 全專案唯一可以碰 Pixi 內部 `_accessibleDiv` 的地方(PX-A11Y-02)。Pixi 8 沒有公開 API 改 a11y div 的 aria 屬性,
 * 而且 div 在第一次啟用後才建立、可見性切換時會重建:屬性先記在 WeakMap,div 存在就寫入,場景每幀 syncA11y() 重新套用。
 * `_accessibleDiv` 是內部欄位(pixi.js 8.23 驗證過),升級 Pixi 要回歸測試。
 */
const wanted = new WeakMap<Container, Map<string, string | null>>();
const divOf = (c: Container): HTMLElement | null | undefined => (c as unknown as { _accessibleDiv?: HTMLElement | null })._accessibleDiv;

export function setA11yAttr(c: Container, name: string, value: string | null): void {
  let m = wanted.get(c);
  if (!m) wanted.set(c, (m = new Map()));
  m.set(name, value);
  syncA11y(c);
}

export function syncA11y(c: Container): void {
  const div = divOf(c);
  const m = wanted.get(c);
  if (!div || !m) return;
  for (const [name, value] of m) {
    if (value === null) div.removeAttribute(name);
    else if (div.getAttribute(name) !== value) div.setAttribute(name, value);
  }
}

let enable: (() => void) | undefined;
export function registerA11yEnabler(fn: () => void): void {
  enable = fn;
}

/** 對話框關閉後把焦點還給 Pixi 按鈕;滑鼠移動會讓 Pixi 關掉 a11y 層,所以先重新啟用,再等 div 建好(最多 30 影格)。 */
export function focusA11y(c: Container): void {
  const now = divOf(c);
  if (now?.isConnected) return now.focus({ preventScroll: true });
  enable?.();
  let frames = 0;
  const retry = (): void => {
    const d = divOf(c);
    if (d?.isConnected) d.focus({ preventScroll: true });
    else if (++frames < 30) requestAnimationFrame(retry);
  };
  retry();
}
