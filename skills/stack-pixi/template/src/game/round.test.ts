import { describe, expect, it } from 'vitest';
import { mulberry32 } from './rng';
import { hit, newRound } from './round';

describe('round', () => {
  it('DEMO-S2 finishes after the goal number of hits', () => {
    const rng = mulberry32(1);
    let r = newRound(3, rng);
    r = hit(hit(r, rng), rng);
    expect(r.done).toBe(false);
    r = hit(r, rng);
    expect(r).toMatchObject({ score: 3, done: true });
    expect(hit(r, rng)).toBe(r);
  });
  it('is reproducible for the same seed', () => {
    const a = newRound(3, mulberry32(7));
    const b = newRound(3, mulberry32(7));
    expect(a.target).toEqual(b.target);
  });
  it('keeps the target inside the play area', () => {
    const rng = mulberry32(42);
    for (let i = 0; i < 100; i++) {
      const { target } = newRound(1, rng);
      expect(target.x).toBeGreaterThanOrEqual(0.15);
      expect(target.x).toBeLessThanOrEqual(0.85);
    }
  });
  it('rejects an invalid goal', () => expect(() => newRound(0, mulberry32(1))).toThrow());
});
