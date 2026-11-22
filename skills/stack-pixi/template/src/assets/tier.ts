/**
 * 素材級別(PX-RES-01):看實際像素需求,不看裝置類型。cover = 設計座標到畫面的縮放(Fit.scale)。
 * cover × min(DPR, 2) > 0.6 → 1x,否則 0.5x(MahjongParty EX-01 的公式;專案可在 budgets「例外」另訂)。
 */
export type Tier = '1x' | '0.5x';
export const chooseTier = (cover: number, dpr: number): Tier => (cover * Math.min(dpr || 1, 2) > 0.6 ? '1x' : '0.5x');
