// 把註解換成等長空白(保留換行與位移);跳過字串、樣板字串與 regex 字面值裡的 // 與 /*
// 樣板字串的結尾(處理 ${ … } 內的巢狀字串與樣板字串);i 指向開頭的 `
function templateEnd(src, i) {
  let j = i + 1;
  while (j < src.length) {
    const c = src[j];
    if (c === '\\') { j += 2; continue; }
    if (c === '`') return j;
    if (c === '$' && src[j + 1] === '{') {
      let depth = 1; j += 2;
      while (j < src.length && depth > 0) {
        const d = src[j];
        if (d === '`') { j = templateEnd(src, j) + 1; continue; }
        if (d === "'" || d === '"') { let k = j + 1; while (k < src.length && src[k] !== d && src[k] !== '\n') { if (src[k] === '\\') k++; k++; } j = k + 1; continue; }
        if (d === '{') depth++; else if (d === '}') depth--;
        j++;
      }
      continue;
    }
    j++;
  }
  return src.length;
}

export function stripComments(src) {
  let out = '';
  let prev = ''; // 上一個非空白字元(判斷 / 是 regex 還是除號)
  for (let i = 0; i < src.length;) {
    const c = src[i], n = src[i + 1];
    if (c === '`') {
      const j = templateEnd(src, i);
      out += src.slice(i, j + 1); i = j + 1; prev = c;
    } else if (c === "'" || c === '"') {
      let j = i + 1;
      while (j < src.length && src[j] !== c) { if (src[j] === '\\') j++; else if (src[j] === '\n') break; j++; }
      out += src.slice(i, j + 1); i = j + 1; prev = c;
    } else if (c === '/' && n === '/') {
      let j = src.indexOf('\n', i); if (j < 0) j = src.length;
      out += ' '.repeat(j - i); i = j;
    } else if (c === '/' && n === '*') {
      let j = src.indexOf('*/', i + 2); j = j < 0 ? src.length : j + 2;
      out += src.slice(i, j).replace(/[^\n]/g, ' '); i = j;
    } else if (c === '/' && (prev === '' || /[(,=:[!&|?{};+\-*%<>~^]/.test(prev) || /\b(return|typeof|case|in|of)$/.test(out.trimEnd()))) {
      // regex 字面值:到同一行未跳脫、不在 [...] 內的 /
      let j = i + 1, cls = false;
      while (j < src.length && src[j] !== '\n') {
        if (src[j] === '\\') { j += 2; continue; }
        if (src[j] === '[') cls = true; else if (src[j] === ']') cls = false; else if (src[j] === '/' && !cls) break;
        j++;
      }
      out += src.slice(i, j + 1); i = j + 1; prev = '/';
    } else { out += c; if (!/\s/.test(c)) prev = c; i++; }
  }
  return out;
}
