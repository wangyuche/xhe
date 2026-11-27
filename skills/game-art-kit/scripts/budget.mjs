// game-art-kit:付費服務的用量累計(角色動作 Codex 張數 / 角色語音 ElevenLabs 字元)。
// 累計檔 = 本次派工專屬(agent 放在 $TMPDIR/game-art-kit/<name>/<派工 id>/budget.json);每次送出前 reserve 檢查「累計 + 本次 ≤ 上限」,
// 超過就丟 BudgetError(呼叫端以結束碼 6 結束,不送出)。讀 → 檢查 → 寫在檔案鎖(<累計檔>.lock,獨佔建立)裡做,平行的程序不會一起超額。
// 服務端明確拒絕、不計費的嘗試(例如 429 限流)可以 refund 退回。
import { readFileSync, writeFileSync, mkdirSync, existsSync, rmSync, openSync, closeSync, statSync } from 'node:fs';
import { dirname } from 'node:path';

export class BudgetError extends Error { constructor(m) { super(m); this.code = 6; } }
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

function withLock(file, fn) {
  const lock = `${file}.lock`;
  mkdirSync(dirname(file), { recursive: true });
  for (let i = 0; ; i++) {
    try { closeSync(openSync(lock, 'wx')); break; }
    catch (e) {
      if (e.code !== 'EEXIST') throw e;
      // 持有者當掉留下的舊鎖(超過 30 秒)直接拿掉
      try { if (Date.now() - statSync(lock).mtimeMs > 30_000) rmSync(lock, { force: true }); } catch { /* */ }
      if (i > 600) throw new BudgetError(`拿不到累計檔的鎖 ${lock}(60 秒)`);
      sleep(100);
    }
  }
  try { return fn(); } finally { rmSync(lock, { force: true }); }
}

export function openBudget(file, limit, unit) {
  if (!file) throw new BudgetError('缺 --budget <累計檔>(付費服務一定要記用量)');
  if (!(Number.isInteger(limit) && limit > 0)) throw new BudgetError('缺 --limit <上限>(正整數,照簡報的同意旗標)');
  const read = () => {
    if (!existsSync(file)) return { unit, used: 0, limit, history: [] };
    let b; try { b = JSON.parse(readFileSync(file, 'utf8')); } catch { throw new BudgetError(`累計檔 ${file} 壞了(不是 JSON);不要猜,請檢查`); }
    if (b.unit !== unit) throw new BudgetError(`累計檔單位是 ${b.unit},這次是 ${unit}:不要混用同一個累計檔`);
    return b;
  };
  read(); // 先驗證格式與單位
  const write = (b) => writeFileSync(file, JSON.stringify({ ...b, limit }, null, 1) + '\n');
  return {
    get used() { return read().used; }, limit,
    // 送出前呼叫:超過上限就丟錯,不送;沒超過就先記上(送出失敗也算用掉,和服務端計費一致)
    reserve(amount, what) {
      return withLock(file, () => {
        const b = read();
        if (b.used + amount > limit) throw new BudgetError(`${what} 需要 ${amount} ${unit},已用 ${b.used} / 上限 ${limit}:不送出`);
        b.used += amount; b.history.push({ what, amount, at: new Date().toISOString() }); write(b);
        return b.used;
      });
    },
    // 服務端明確拒絕、不會計費的嘗試(429 限流)退回
    refund(amount, what) {
      return withLock(file, () => { const b = read(); b.used = Math.max(0, b.used - amount); b.history.push({ what: `退回:${what}`, amount: -amount, at: new Date().toISOString() }); write(b); return b.used; });
    },
  };
}
