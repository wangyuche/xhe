import { Application } from 'pixi.js';
import { t } from '../i18n';
import { bindPauseTicker, setPaused } from './pause';

/** 全站唯一的 Application(PX-LIFE-02)。 */
export async function createApp(host: HTMLElement): Promise<Application> {
  const app = new Application();
  await app.init({
    resizeTo: window,
    background: 0x101418,
    resolution: Math.min(window.devicePixelRatio || 1, 2), // PX-RES-02
    autoDensity: true,
    antialias: true,
    preference: 'webgl', // 測試與量測結果一致(draw call 計數包的是 WebGL)
  });
  host.appendChild(app.canvas);

  // PX-PERF-05:分頁到背景就暫停
  document.addEventListener('visibilitychange', () => setPaused('hidden', document.visibilityState === 'hidden'));
  bindPauseTicker(app.ticker);

  // PX-LIFE-03:context lost 不能變白畫面
  app.canvas.addEventListener('webglcontextlost', (e) => {
    e.preventDefault();
    showError(t('error.contextLost'));
  });
  return app;
}

export function showError(message: string): void {
  document.getElementById('loading')!.hidden = true;
  document.getElementById('error-msg')!.textContent = message;
  const btn = document.getElementById('error-reload') as HTMLButtonElement;
  btn.textContent = t('common.reload');
  btn.onclick = () => location.reload();
  document.getElementById('error')!.hidden = false;
}
