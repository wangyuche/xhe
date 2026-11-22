/**
 * early-boot 白名單(PX-LOAD-01):首屏(entry 的靜態 import 圖)只能帶這些群組的素材。
 * 其他群組一律由場景動態載入;stack-pixi check-early 讀 dist/.vite/manifest.json 檢查,漏進首屏就失敗。
 * 純 TS、不 import pixi。
 */
export const BOOT_GROUPS: readonly string[] = ['boot'];
