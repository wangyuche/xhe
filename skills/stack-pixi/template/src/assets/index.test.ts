import { describe, expect, it, vi } from 'vitest';

vi.mock('pixi.js', () => ({
  Assets: { cache: { has: () => false }, add: vi.fn(), load: vi.fn(async () => {}), unload: vi.fn(async () => {}), get: vi.fn() },
  Rectangle: class {},
  Texture: class {},
}));

const { __refCount, acquireGroup, releaseGroup } = await import('.');

describe('asset groups (PX-LOAD-04)', () => {
  it('counts acquire / release', async () => {
    await acquireGroup('title');
    await acquireGroup('title');
    expect(__refCount('title')).toBe(2);
    releaseGroup('title');
    expect(__refCount('title')).toBe(1);
    releaseGroup('title');
    expect(__refCount('title')).toBe(0);
  });
  it('honours a release that happens while the group is still loading', async () => {
    const p = acquireGroup('play');
    releaseGroup('play');
    await p;
    expect(__refCount('play')).toBe(0);
  });
});
