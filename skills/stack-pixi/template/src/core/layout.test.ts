import { describe, expect, it } from 'vitest';
import { DESIGN } from '../config/design';
import { computeFit } from './layout';

const none = { top: 0, right: 0, bottom: 0, left: 0 };

describe('computeFit', () => {
  it('scales the design to fit and centres it', () => {
    const f = computeFit(DESIGN.width / 2, DESIGN.height, none);
    expect(f.scale).toBeCloseTo(0.5);
    expect(f.x).toBeCloseTo(0);
    expect(f.y).toBeCloseTo(DESIGN.height / 4);
  });
  it('keeps content inside the safe area', () => {
    const f = computeFit(DESIGN.width, DESIGN.height, { top: 0, right: 40, bottom: 0, left: 40 });
    expect(f.x).toBeGreaterThanOrEqual(40);
    expect(f.x + DESIGN.width * f.scale).toBeLessThanOrEqual(DESIGN.width - 40 + 1e-6);
  });
});
