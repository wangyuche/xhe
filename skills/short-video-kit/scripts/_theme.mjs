// theme 檢查(render.mjs 與 compose.mjs 共用)。沒有預設配色。
// checkTheme(theme, cards) → { error } 或 { contrast: { 'fg/bg': 7.21, … } }
// 只檢查 cards 裡實際會畫出來的「文字色 / 底色」組合。程式碼卡的面板是固定深色底(#0d1117),不受 theme 影響。
export const THEME_KEYS = ['bg', 'bg2', 'fg', 'accent', 'muted'];
export const THEMED_TYPES = ['title', 'point', 'code', 'end', 'headline']; // 另外:沒有 image 的 cover

const lum = (h) => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16) / 255)
  .map(c => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4))
  .reduce((a, c, i) => a + c * [0.2126, 0.7152, 0.0722][i], 0);
export const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };

// 版型實際畫出來的組合與門檻(WCAG:一般文字 4.5,大字 3)。底色是漸層時,沿漸層取樣(sRGB 線性內插,跟瀏覽器一樣),取最低值:
//   標題 / 內文 / 程式碼卡標題:fg 在 bg→bg2 上 ≥ 4.5
//   漸層封面標題:fg 在 bg→bg2→accent 上 ≥ 4.5(160deg 漸層 bg 0%、bg2 60%、accent 140%,畫面內最多到 bg2→accent 的一半)
//   title / end 的副標(.t2):muted 在 bg→bg2 上 ≥ 3(48px 大字)
//   tag、end 的 url:accent 在 bg→bg2 上 ≥ 3(大字)
//   point 的編號徽章、headline:bg 字在 accent 底上 ≥ 3(大字)
const present = (v) => v !== undefined && v !== null && String(v) !== ''; // 和 render.mjs 一樣:非空就會畫
const mix = (a, b, t) => '#' + [1, 3, 5].map(i => Math.round(parseInt(a.slice(i, i + 2), 16) * (1 - t) + parseInt(b.slice(i, i + 2), 16) * t).toString(16).padStart(2, '0')).join('');
const SAMPLES = [0, 0.25, 0.5, 0.75, 1];
// 底色:{ name, colors(theme) → 取樣色陣列 }
const BG = { name: 'bg~bg2', colors: (t) => SAMPLES.map(x => mix(t.bg, t.bg2, x)) };
const COVER = { name: 'bg~bg2~accent', colors: (t) => [...SAMPLES.map(x => mix(t.bg, t.bg2, x)), ...SAMPLES.map(x => mix(t.bg2, t.accent, x * 0.5))] };
const ACCENT = { name: 'accent', colors: (t) => [t.accent] };
function pairsFor(cards) {
  const has = (f) => cards.some(c => c && f(c));
  const plainCover = (c) => c.type === 'cover' && !present(c.image);
  const pairs = [];
  if (has(c => ['title', 'point', 'code', 'end'].includes(c.type))) pairs.push(['fg', BG, 4.5]);
  if (has(plainCover)) pairs.push(['fg', COVER, 4.5]);
  if (has(c => ['title', 'end'].includes(c.type) && present(c.subtitle))) pairs.push(['muted', BG, 3]);
  if (has(c => (['title', 'end'].includes(c.type) || plainCover(c)) && present(c.tag)) || has(c => c.type === 'end' && present(c.url))) pairs.push(['accent', BG, 3]);
  if (has(c => (c.type === 'point' && present(c.number)) || c.type === 'headline')) pairs.push(['bg', ACCENT, 3]);
  return pairs;
}

export function checkTheme(theme, cards) {
  if (!theme || typeof theme !== 'object' || Array.isArray(theme)) theme = {};
  const missing = THEME_KEYS.filter(k => theme[k] === undefined);
  if (missing.length) return { error: `theme 缺 ${missing.join('、')}:沒有預設配色,依這支影片的來源選(見 SKILL.md「## 配色」)` };
  for (const [k, v] of Object.entries(theme)) {
    if (!THEME_KEYS.includes(k)) return { error: `theme.${k} 不是可用欄位(${THEME_KEYS.join(', ')})` };
    if (!/^#[0-9a-fA-F]{6}$/.test(String(v))) return { error: `theme.${k} 必須是 #RRGGBB 色碼` };
  }
  const contrast = {};
  for (const [fgk, bgDef, min] of pairsFor(cards)) {
    const r = Math.min(...bgDef.colors(theme).map(c => ratio(theme[fgk], c)));
    contrast[`${fgk}/${bgDef.name}`] = Math.floor(r * 100) / 100;
    if (r < min) return { error: `theme.${fgk} 對 ${bgDef.name} 的最低對比 ${r.toFixed(2)}:1 < ${min}:1(版型會把這些顏色疊在一起;漸層取樣含中段),換更深或更淺的顏色` };
  }
  return { contrast };
}
