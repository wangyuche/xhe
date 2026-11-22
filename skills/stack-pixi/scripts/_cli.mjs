// 檢查腳本共用:參數解析(缺值 = 用法錯誤,結束碼 2)與基準比對(--baseline)。
import { readFileSync, existsSync } from 'node:fs';

export const EXIT = { ok: 0, violation: 1, usage: 2, layoutAbsent: 3 };
export const MEDIA_RE = /\.(avif|png|jpe?g|webp|ogg|m4a|mp3)$/i;

export function usageError(msg, usage) {
  console.error(msg);
  if (usage) console.error(usage);
  process.exit(EXIT.usage);
}

// opt('--src', 'src'):沒給 → 預設值;給了但沒有值(最後一個參數或下一個是 --xxx)→ 用法錯誤
export function makeOpt(rest, usage) {
  return (name, def) => {
    const i = rest.indexOf(name);
    if (i < 0) return def;
    const v = rest[i + 1];
    if (v === undefined || v.startsWith('--')) usageError(`${name} 需要值`, usage);
    return v;
  };
}

export const normText = (s) => String(s).replace(/\s+/g, ' ').trim();

// 基準檔 = 同一支腳本在改動前的輸出(JSON)。讀 violations / existing / errors 三個欄位,轉成 key 的多重集合。
export function loadBaseline(path, keyOf, usage) {
  if (!existsSync(path)) usageError(`找不到基準檔 ${path}`, usage);
  let j;
  try { j = JSON.parse(readFileSync(path, 'utf8')); } catch (e) { usageError(`基準檔不是 JSON:${path}(${e.message})`, usage); }
  const counts = new Map();
  for (const item of [...(j.violations ?? []), ...(j.existing ?? []), ...(j.errors ?? [])]) {
    const k = keyOf(item);
    counts.set(k, (counts.get(k) ?? 0) + 1);
  }
  return counts;
}

// 依基準分成 fresh(這次新增)與 existing(基準就有)。同一個 key 出現次數比基準多,多出來的算新增。
export function splitByBaseline(items, keyOf, counts) {
  if (!counts) return { fresh: items, existing: [] };
  const left = new Map(counts);
  const fresh = [], existing = [];
  for (const it of items) {
    const k = keyOf(it);
    const n = left.get(k) ?? 0;
    if (n > 0) { left.set(k, n - 1); existing.push(it); } else fresh.push(it);
  }
  return { fresh, existing };
}
