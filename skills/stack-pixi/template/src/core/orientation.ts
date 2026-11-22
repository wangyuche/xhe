import { ANY_ORIENTATION, LANDSCAPE } from '../config/design';
import { t } from '../i18n';
import { setPaused } from './pause';

/** 橫式遊戲在直式畫面顯示 #rotate 並暫停(PX-INPUT-04)。 */
export function watchOrientation(): void {
  const el = document.getElementById('rotate')!;
  el.textContent = t(LANDSCAPE ? 'common.rotate' : 'common.rotatePortrait');
  const check = (): void => {
    const portrait = window.innerHeight > window.innerWidth;
    const wrong = ANY_ORIENTATION ? false : LANDSCAPE ? portrait : !portrait;
    el.hidden = !wrong;
    setPaused('rotate', wrong);
  };
  window.addEventListener('resize', check);
  check();
}
