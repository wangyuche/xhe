import { describe, expect, it } from 'vitest';
import { acceptMessage, post, resolveParentOrigin } from './bridge';

const ALLOWED = ['https://lobby.example.com'];

describe('iframe bridge', () => {
  it('uses ancestorOrigins first and requires the allowlist', () => {
    expect(resolveParentOrigin(ALLOWED, { ancestorOrigins: ['https://lobby.example.com'] }, '')).toBe('https://lobby.example.com');
    expect(resolveParentOrigin(ALLOWED, { ancestorOrigins: ['https://evil.example'] }, 'https://lobby.example.com/x')).toBeUndefined();
  });
  it('falls back to the referrer origin', () => {
    expect(resolveParentOrigin(ALLOWED, {}, 'https://lobby.example.com/play')).toBe('https://lobby.example.com');
    expect(resolveParentOrigin(ALLOWED, {}, 'not a url')).toBeUndefined();
  });
  it('accepts only messages from the parent with the exact origin', () => {
    const parent = {};
    expect(acceptMessage({ source: parent, origin: ALLOWED[0]!, data: { t: 'init' } }, parent, ALLOWED[0]!)).toEqual({ t: 'init' });
    expect(acceptMessage({ source: {}, origin: ALLOWED[0]!, data: { t: 'init' } }, parent, ALLOWED[0]!)).toBeUndefined();
    expect(acceptMessage({ source: parent, origin: 'https://evil.example', data: { t: 'init' } }, parent, ALLOWED[0]!)).toBeUndefined();
    expect(acceptMessage({ source: parent, origin: ALLOWED[0]!, data: 'x' }, parent, ALLOWED[0]!)).toBeUndefined();
  });
  it('posts with the exact origin, never *', () => {
    const calls: Array<[unknown, string]> = [];
    post({ postMessage: (m, o) => calls.push([m, o]) }, ALLOWED[0]!, { t: 'hello' });
    expect(calls).toEqual([[{ t: 'hello' }, ALLOWED[0]]]);
  });
});
