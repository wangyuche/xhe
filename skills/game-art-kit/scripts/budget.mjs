// game-art-kit:付費服務的用量累計(角色動作 Codex 張數 / 角色語音 ElevenLabs 字元)。
// 累計檔 = 本次派工專屬(agent 放在 $TMPDIR/game-art-kit/<name>/<派工 id>/budget.json);每次送出前 reserve 檢查「累計 + 本次 ≤ 上限」,
// 超過就丟 BudgetError(呼叫端以結束碼 6 結束,不送出);送出後(不論成功失敗)用量已算進去。
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname } from 'node:path';

export class BudgetError extends Error { constructor(m) { super(m); this.code = 6; } }

export function openBudget(file, limit, unit) {
  if (!file) throw new BudgetError('缺 --budget <累計檔>(付費服務一定要記用量)');
  if (!(Number.isInteger(limit) && limit > 0)) throw new BudgetError('缺 --limit <上限>(正整數,照簡報的同意旗標)');
  let b = { unit, used: 0, limit, run: null, history: [] };
  if (existsSync(file)) {
    try { b = { ...b, ...JSON.parse(readFileSync(file, 'utf8')) }; } catch { throw new BudgetError(`累計檔 ${file} 壞了(不是 JSON);不要猜,請檢查`); }
    if (b.unit !== unit) throw new BudgetError(`累計檔單位是 ${b.unit},這次是 ${unit}:不要混用同一個累計檔`);
  }
  b.limit = limit;
  const save = () => { mkdirSync(dirname(file), { recursive: true }); writeFileSync(file, JSON.stringify(b, null, 1) + '\n'); };
  return {
    get used() { return b.used; }, limit,
    // 送出前呼叫:超過上限就丟錯,不送;沒超過就先記上(送出失敗也算用掉,和服務端計費一致)
    reserve(amount, what) {
      if (b.used + amount > limit) throw new BudgetError(`${what} 需要 ${amount} ${unit},已用 ${b.used} / 上限 ${limit}:不送出`);
      b.used += amount; b.history.push({ what, amount, at: new Date().toISOString() }); save();
      return b.used;
    },
  };
}
