import { DESIGN } from '../config/design';
import type { Insets } from './safe-area';

/** 設計座標 → 畫面(CSS px)的等比縮放與置中(扣掉安全區)。純函式,不 import pixi。 */
export interface Fit { scale: number; x: number; y: number; screenW: number; screenH: number }

export function computeFit(screenW: number, screenH: number, insets: Insets): Fit {
  const w = Math.max(1, screenW - insets.left - insets.right);
  const h = Math.max(1, screenH - insets.top - insets.bottom);
  const scale = Math.min(w / DESIGN.width, h / DESIGN.height);
  return {
    scale,
    x: insets.left + (w - DESIGN.width * scale) / 2,
    y: insets.top + (h - DESIGN.height * scale) / 2,
    screenW,
    screenH,
  };
}
