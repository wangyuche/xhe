import type { Rng } from './rng';

/**
 * 範例遊戲邏輯(純 TS,PX-ARCH-01 不 import pixi):點目標 goal 次結束一回合;目標位置用種子亂數決定(0–1 正規化座標)。
 * 換成真正的遊戲時改寫這個檔案,並保留「純邏輯 + 單元測試」的分層。
 */
export interface Round {
  readonly goal: number;
  readonly score: number;
  readonly target: { x: number; y: number };
  readonly done: boolean;
}

const place = (rng: Rng): { x: number; y: number } => ({ x: 0.15 + rng() * 0.7, y: 0.25 + rng() * 0.55 });

export function newRound(goal: number, rng: Rng): Round {
  if (!Number.isInteger(goal) || goal < 1) throw new Error('goal must be a positive integer');
  return { goal, score: 0, target: place(rng), done: false };
}

export function hit(r: Round, rng: Rng): Round {
  if (r.done) return r;
  const score = r.score + 1;
  return { goal: r.goal, score, target: place(rng), done: score >= r.goal };
}
