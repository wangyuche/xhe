/** 減少動態(PX-A11Y-06):動畫、轉場、閃爍效果都要先問這裡。純 DOM,不 import pixi。 */
export const prefersReducedMotion = (): boolean =>
  typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
