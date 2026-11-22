/** 設計座標(new-pixi.sh --design 寫入)。版面、素材顯示尺寸都以這個座標為準。 */
export const DESIGN: { readonly width: number; readonly height: number } = { width: __DESIGN_W__, height: __DESIGN_H__ };
/** 橫式遊戲:直式畫面顯示旋轉提示並暫停。 */
export const LANDSCAPE = DESIGN.width > DESIGN.height;
/** 正方形設計不限方向(不顯示旋轉提示)。 */
export const ANY_ORIENTATION = DESIGN.width === DESIGN.height;
