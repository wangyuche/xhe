// theme 檢查(render.mjs 與 compose.mjs 共用)。沒有預設配色。
// checkTheme(theme, types) → { error } 或 { contrast: { 'fg/bg': 7.21, … } }
// types:實際用到 theme 的卡片類型(title / point / code / end / headline / cover-plain)。
export const THEME_KEYS = ['bg', 'bg2', 'fg', 'accent', 'muted'];
export const THEMED_TYPES = ['title', 'point', 'code', 'end', 'headline', 'cover-plain'];

const lum = (h) => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16) / 255)
  .map(c => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4))
  .reduce((a, c, i) => a + c * [0.2126, 0.7152, 0.0722][i], 0);
export const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };

// 版型實際畫出來的「文字色 / 底色」組合與門檻(WCAG:一般文字 4.5,大字 3)
//   全版卡(title / point / code / end)與漸層封面:fg、muted、accent(tag、url)在 bg→bg2 漸層上;point 的編號徽章是 accent 底上的 bg 字
//   headline:accent 底上的 bg 字(大字)
function pairsFor(types) {
  const full = types.some(t => ['title', 'point', 'code', 'end', 'cover-plain'].includes(t));
  const pairs = [];
  if (full) pairs.push(['fg', 'bg', 4.5], ['fg', 'bg2', 4.5], ['muted', 'bg', 3], ['muted', 'bg2', 3], ['accent', 'bg', 3], ['accent', 'bg2', 3]);
  else if (types.includes('headline')) pairs.push(['accent', 'bg', 3]);
  return pairs;
}

export function checkTheme(theme, types) {
  if (!theme || typeof theme !== 'object' || Array.isArray(theme)) theme = {};
  const missing = THEME_KEYS.filter(k => theme[k] === undefined);
  if (missing.length) return { error: `theme 缺 ${missing.join('、')}:沒有預設配色,依這支影片的來源選(見 SKILL.md「## 配色」)` };
  for (const [k, v] of Object.entries(theme)) {
    if (!THEME_KEYS.includes(k)) return { error: `theme.${k} 不是可用欄位(${THEME_KEYS.join(', ')})` };
    if (!/^#[0-9a-fA-F]{6}$/.test(String(v))) return { error: `theme.${k} 必須是 #RRGGBB 色碼` };
  }
  const contrast = {};
  for (const [a, b, min] of pairsFor(types)) {
    const r = Math.round(ratio(theme[a], theme[b]) * 100) / 100;
    contrast[`${a}/${b}`] = r;
    if (r < min) return { error: `theme.${a} 對 theme.${b} 對比 ${r.toFixed(2)}:1 < ${min}:1(版型會把這兩色疊在一起),換更深或更淺的顏色` };
  }
  return { contrast };
}
