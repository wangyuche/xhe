import { describe, expect, it } from 'vitest';
import { format, t } from '.';
import { en } from './en';

describe('i18n', () => {
  it('replaces parameters', () => expect(format('Score {a} of {b}', { a: 2, b: 3 })).toBe('Score 2 of 3'));
  it('keeps unknown placeholders', () => expect(format('Score {a} of {b}', { a: 1 })).toBe('Score 1 of {b}'));
  it('every message is a non-empty string', () => {
    for (const [k, v] of Object.entries(en)) expect(v, k).toMatch(/\S/);
  });
  it('t returns the English text', () => expect(t('common.reload')).toBe(en['common.reload']));
});
