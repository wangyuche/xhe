import { describe, expect, it } from 'vitest';
import { chooseTier } from './tier';

describe('chooseTier', () => {
  it('uses 1x on a full-size desktop', () => expect(chooseTier(1, 1)).toBe('1x'));
  it('uses 0.5x on a small low-DPR window', () => expect(chooseTier(0.4, 1)).toBe('0.5x'));
  it('caps DPR at 2', () => expect(chooseTier(0.25, 3)).toBe('0.5x'));
});
