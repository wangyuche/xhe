/** 設計座標(new-pixi.sh --design 寫入)。版面、素材顯示尺寸都以這個座標為準。 */
export const DESIGN = { width: __DESIGN_W__, height: __DESIGN_H__ } as const;
/** 橫式遊戲:直式畫面顯示旋轉提示並暫停。 */
export const LANDSCAPE = DESIGN.width >= DESIGN.height;
