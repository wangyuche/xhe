import { createApp, showError } from './core/app';
import { startAudioUnlock } from './core/audio';
import { startInputModalityTracking } from './core/input-modality';
import { watchOrientation } from './core/orientation';
import { SceneManager } from './core/scene-manager';
import { registerA11yEnabler } from './components/a11y';
import { setTier } from './assets';
import { computeFit } from './core/layout';
import { readSafeArea } from './core/safe-area';
import { t } from './i18n';

async function boot(): Promise<void> {
  startInputModalityTracking();
  startAudioUnlock();
  const loading = document.getElementById('loading')!;
  document.getElementById('loading-text')!.textContent = t('common.loading');
  const app = await createApp(document.getElementById('app')!);
  registerA11yEnabler(() => app.renderer.accessibility.setAccessibilityEnabled(true));
  // 測試模式(`?a11y=1`):一開始就啟用 a11y 層,E2E 用 a11y 選擇器(PX-TEST-02)
  if (new URLSearchParams(location.search).has('a11y')) app.renderer.accessibility.setAccessibilityEnabled(true);
  watchOrientation();
  // 素材級別開機時選一次(PX-RES-01)
  setTier(computeFit(app.screen.width, app.screen.height, readSafeArea()).scale, window.devicePixelRatio);
  const scenes = new SceneManager(app);
  await scenes.go('title');
  loading.hidden = true;
  loading.removeAttribute('aria-busy');
}

boot().catch((e: unknown) => {
  console.error(e);
  showError(t('error.boot'));
});
