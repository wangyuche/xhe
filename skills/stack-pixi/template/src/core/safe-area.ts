export interface Insets { top: number; right: number; bottom: number; left: number }

let probe: HTMLDivElement | undefined;

/** 讀 env(safe-area-inset-*)(CSS px)。開發模式可用 `?inset=top,right,bottom,left` 注入,方便桌機與 E2E 驗證(PX-INPUT-03)。 */
export function readSafeArea(): Insets {
  if (import.meta.env.DEV) {
    const q = new URLSearchParams(location.search).get('inset');
    if (q) {
      const [top = 0, right = 0, bottom = 0, left = 0] = q.split(',').map((n) => parseFloat(n) || 0);
      return { top, right, bottom, left };
    }
  }
  if (!probe) {
    probe = document.createElement('div');
    probe.style.cssText = 'position:fixed;visibility:hidden;pointer-events:none;'
      + 'padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)';
    document.body.appendChild(probe);
  }
  const s = getComputedStyle(probe);
  return { top: parseFloat(s.paddingTop) || 0, right: parseFloat(s.paddingRight) || 0, bottom: parseFloat(s.paddingBottom) || 0, left: parseFloat(s.paddingLeft) || 0 };
}
