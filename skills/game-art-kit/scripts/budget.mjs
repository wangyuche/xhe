// game-art-kit:付費服務的用量累計(角色動作 Codex 張數 / 角色語音 ElevenLabs 字元)。
// 累計檔 = 本次派工專屬(agent 放在 $TMPDIR/game-art-kit/<name>/<派工 id>/budget.json);每次送出前 reserve 檢查「累計 + 本次 ≤ 上限」,
// 超過就丟 BudgetError(呼叫端以結束碼 6 結束,不送出)。讀 → 檢查 → 寫在檔案鎖(<累計檔>.lock,獨佔建立)裡做,平行的程序不會一起超額;
// 寫入用暫存檔 + 改名(原子);鎖超過 30 秒還在不自動刪(結束碼 6,請人確認後手動刪)。
// 服務端明確拒絕、不計費的嘗試(例如 429 限流)可以 refund 退回。
import { readFileSync, writeFileSync, mkdirSync, existsSync, rmSync, openSync, closeSync, statSync, renameSync, writeSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { dirname } from 'node:path';

export class BudgetError extends Error { constructor(m) { super(m); this.code = 6; } }
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

function withLock(file, fn) {
  const lock = `${file}.lock`, token = `${process.pid}-${randomUUID()}`;
  mkdirSync(dirname(file), { recursive: true });
  for (let i = 0; ; i++) {
    try { const fd = openSync(lock, 'wx'); writeSync(fd, token); closeSync(fd); break; }
    catch (e) {
      if (e.code !== 'EEXIST') throw e;
      // 鎖只在讀寫累計檔的幾毫秒內存在;超過 30 秒還在 = 之前的程序中斷留下的。不自動刪(刪除與別人新建的鎖之間有競爭,可能兩個程序一起超額),停下來請人確認後手動刪
      try { if (Date.now() - statSync(lock).mtimeMs > 30_000) throw new BudgetError(`累計檔的鎖 ${lock} 已存在超過 30 秒(之前的程序可能中斷):確認沒有其他程序在跑之後手動刪除它`); } catch (e2) { if (e2 instanceof BudgetError) throw e2; }
      if (i > 600) throw new BudgetError(`拿不到累計檔的鎖 ${lock}(60 秒)`);
      sleep(100);
    }
  }
  try { return fn(); }
  finally { try { if (readFileSync(lock, 'utf8') === token) rmSync(lock, { force: true }); } catch { /* 鎖已不是自己的,不動 */ } }
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
  // 先寫暫存檔再改名(原子):沒拿鎖的讀者不會讀到寫一半的檔
  const write = (b) => { const t = `${file}.${process.pid}.tmp`; writeFileSync(t, JSON.stringify({ ...b, limit }, null, 1) + '\n'); renameSync(t, file); };
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

// manifest 追加:同一把檔案鎖 + 暫存檔改名,平行的程序不會互相蓋掉;manifest 壞了就另存備份再重建,不讓已完成的工作失敗
export function appendJsonItem(file, item) {
  return withLock(file, () => {
    let m = { items: [] };
    if (existsSync(file)) { try { m = JSON.parse(readFileSync(file, 'utf8')); if (!Array.isArray(m.items)) throw new Error('no items'); } catch { renameSync(file, `${file}.broken-${Date.now()}`); m = { items: [] }; } }
    m.items.push(item);
    const t = `${file}.${process.pid}.tmp`; writeFileSync(t, JSON.stringify(m, null, 1) + '\n'); renameSync(t, file);
  });
}
