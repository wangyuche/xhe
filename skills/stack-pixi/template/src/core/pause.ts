import type { Ticker } from 'pixi.js';

/** 單一暫停狀態(PX-PERF-05):多個原因各自 set / clear,全部清空才恢復 ticker。 */
export type PauseReason = 'hidden' | 'rotate';

const reasons = new Set<PauseReason>();
const listeners = new Set<(paused: boolean) => void>();
let ticker: Ticker | undefined;

function apply(): void {
  const paused = reasons.size > 0;
  if (ticker) {
    if (paused) ticker.stop();
    else ticker.start();
  }
  for (const cb of listeners) cb(paused);
}

export const isPaused = (): boolean => reasons.size > 0;

export function onPauseChange(cb: (paused: boolean) => void): () => void {
  listeners.add(cb);
  return () => listeners.delete(cb);
}

export function bindPauseTicker(t: Ticker): void {
  ticker = t;
  apply();
}

export function setPaused(reason: PauseReason, paused: boolean): void {
  if (paused) reasons.add(reason);
  else reasons.delete(reason);
  apply();
}
