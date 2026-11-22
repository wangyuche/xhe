import { describe, expect, it } from 'vitest';
import { WsTransport, backoffMs, type WsLike } from './WsTransport';

class FakeWs implements WsLike {
  sent: string[] = [];
  onopen: ((ev: unknown) => void) | null = null;
  onclose: ((ev: { code: number }) => void) | null = null;
  onmessage: ((ev: { data: unknown }) => void) | null = null;
  send(d: string): void { this.sent.push(d); }
  close(): void { this.onclose?.({ code: 1000 }); }
}

function setup(fatalCodes: number[] = []) {
  const sockets: FakeWs[] = [];
  const timers: Array<{ fn: () => void; ms: number }> = [];
  const states: string[] = [];
  const t = new WsTransport({ url: 'ws://x', launchToken: 'L', onMessage: () => {}, onState: (s) => states.push(s), fatalCodes,
    create: () => { const s = new FakeWs(); sockets.push(s); return s; }, schedule: (fn, ms) => timers.push({ fn, ms }) });
  t.start();
  return { t, sockets, timers, states };
}

describe('WsTransport', () => {
  it('caps backoff at 10 s', () => {
    expect([0, 1, 2, 5, 10].map(backoffMs)).toEqual([500, 1000, 2000, 10_000, 10_000]);
  });
  it('sends hello first, then resume with the session token after a reconnect', () => {
    const { sockets, timers } = setup();
    sockets[0]!.onopen?.({});
    expect(JSON.parse(sockets[0]!.sent[0]!)).toEqual({ t: 'hello', launchToken: 'L' });
    sockets[0]!.onmessage?.({ data: JSON.stringify({ t: 'welcome', sessionToken: 'S' }) });
    sockets[0]!.onclose?.({ code: 1006 });
    expect(timers[0]!.ms).toBe(500);
    timers[0]!.fn();
    sockets[1]!.onopen?.({});
    expect(JSON.parse(sockets[1]!.sent[0]!)).toEqual({ t: 'resume', sessionToken: 'S' });
  });
  it('drops sends while disconnected', () => {
    const { t } = setup();
    expect(t.send({ t: 'move' })).toBe(false);
  });
  it('does not resend a used launch token when the socket drops before welcome', () => {
    const { sockets, timers, states } = setup();
    sockets[0]!.onopen?.({});
    sockets[0]!.onclose?.({ code: 1006 });
    expect(timers).toHaveLength(0);
    expect(states.at(-1)).toBe('expired');
  });
  it('reports expired after three rejected resumes', () => {
    const { sockets, timers, states } = setup();
    sockets[0]!.onopen?.({});
    sockets[0]!.onmessage?.({ data: JSON.stringify({ t: 'welcome', sessionToken: 'S' }) });
    for (let i = 0; i < 5; i++) {
      sockets.at(-1)!.onclose?.({ code: 1008 });
      if (states.at(-1) === 'expired') break;
      timers.at(-1)!.fn();
      sockets.at(-1)!.onopen?.({});
    }
    expect(states.at(-1)).toBe('expired');
    expect(sockets).toHaveLength(4); // 第一次連線 + 3 次 resume
  });
  it('gives up after 8 closes that never opened', () => {
    const { sockets, timers, states } = setup();
    for (let i = 0; i < 10 && states.at(-1) !== 'fatal'; i++) {
      sockets.at(-1)!.onclose?.({ code: 1006 });
      if (states.at(-1) !== 'fatal') timers.at(-1)!.fn();
    }
    expect(states.at(-1)).toBe('fatal');
    expect(sockets).toHaveLength(8);
  });
  it('stops reconnecting on a fatal close code', () => {
    const { sockets, timers, states } = setup([4001]);
    sockets[0]!.onclose?.({ code: 4001 });
    expect(timers).toHaveLength(0);
    expect(states.at(-1)).toBe('fatal');
  });
});
