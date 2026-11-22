/** 最近一次輸入是鍵盤還是指標(PX-A11Y-05):焦點框只給鍵盤使用者看。開機就要開始追蹤。 */
let keyboard = false;
const MODIFIERS = new Set(['Shift', 'Control', 'Alt', 'Meta', 'CapsLock']);

export function startInputModalityTracking(target: Pick<Window, 'addEventListener'> = window): void {
  target.addEventListener('keydown', (e) => { if (!MODIFIERS.has((e as KeyboardEvent).key)) keyboard = true; }, true);
  target.addEventListener('pointerdown', () => { keyboard = false; }, true);
}

export const lastInputWasKeyboard = (): boolean => keyboard;
