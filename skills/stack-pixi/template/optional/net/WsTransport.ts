/**
 * WebSocket 連線(PX-NET-01,`new-pixi.sh --net ws` 加入;放 src/services/net/,純邏輯不 import pixi):
 * - 第一則送 {t:'hello', launchToken};伺服器回 {t:'welcome', sessionToken} 後,重連改送 {t:'resume', sessionToken}。
 * - 一直連不上(還沒 open 就斷,例如握手被拒 401)連續 8 次 → 'fatal';resume 連續 3 次沒拿到 welcome → 'expired'。
 * - launch token 是一次性的:hello 已送出、還沒拿到 session token 就斷線 → 狀態 'expired' 並停止(呼叫端要取新的 launch token 重建)。
 * - 斷線重連:指數退避 min(10 s, 500 ms × 2^n),收到 welcome 歸零;FATAL 錯誤碼停止重連。
 * - 斷線期間 send() 丟棄(回 false),不排隊;重連後由伺服器送完整快照(onMessage 收到 snapshot 自行重建狀態)。
 * - token 不放 Web storage、不印 console(PX-SEC-01)。
 */
export interface WsLike {
  send(data: string): void;
  close(): void;
  onopen: ((ev: unknown) => void) | null;
  onclose: ((ev: { code: number }) => void) | null;
  onmessage: ((ev: { data: unknown }) => void) | null;
}
export type Msg = { t: string; [k: string]: unknown };

export interface WsOptions {
  url: string;
  launchToken: string;
  onMessage: (m: Msg) => void;
  onState?: (s: 'connecting' | 'open' | 'closed' | 'fatal' | 'expired') => void;
  /** 收到這些 close code 就不再重連(例如 token 無效)。 */
  fatalCodes?: number[];
  create?: (url: string) => WsLike;
  schedule?: (fn: () => void, ms: number) => unknown;
}

export const backoffMs = (attempt: number): number => Math.min(10_000, 500 * 2 ** attempt);

export class WsTransport {
  private ws?: WsLike;
  private sessionToken?: string;
  private attempt = 0;
  private open = false;
  private stopped = false;
  private helloSent = false;
  private resumeFails = 0;
  private preOpenFails = 0;
  private opened = false;

  constructor(private readonly o: WsOptions) {}

  start(): void {
    this.connect();
  }

  stop(): void {
    this.stopped = true;
    this.ws?.close();
  }

  send(m: Msg): boolean {
    if (!this.open || !this.ws) return false;
    this.ws.send(JSON.stringify(m));
    return true;
  }

  private connect(): void {
    if (this.stopped) return;
    this.o.onState?.('connecting');
    const ws = (this.o.create ?? ((u) => new WebSocket(u) as unknown as WsLike))(this.o.url);
    this.ws = ws;
    this.opened = false;
    ws.onopen = () => {
      this.opened = true;
      this.preOpenFails = 0;
      if (this.sessionToken) { ws.send(JSON.stringify({ t: 'resume', sessionToken: this.sessionToken })); this.resumeFails++; }
      else {
        ws.send(JSON.stringify({ t: 'hello', launchToken: this.o.launchToken }));
        this.helloSent = true;
      }
    };
    ws.onmessage = (ev) => {
      let m: Msg;
      try { m = JSON.parse(String(ev.data)) as Msg; } catch { return; }
      if (m.t === 'welcome') {
        if (typeof m.sessionToken === 'string') this.sessionToken = m.sessionToken;
        this.attempt = 0;
        this.resumeFails = 0;
        this.open = true;
        this.o.onState?.('open');
      }
      this.o.onMessage(m);
    };
    ws.onclose = (ev) => {
      this.open = false;
      if (this.stopped) return this.o.onState?.('closed');
      if (this.o.fatalCodes?.includes(ev.code)) {
        this.stopped = true;
        return this.o.onState?.('fatal');
      }
      // resume 連續 3 次都沒拿到 welcome(session 已失效)→ 同樣要新的 launch token
      if (!this.opened && ++this.preOpenFails >= 8) {
        this.stopped = true; // 握手一直被拒或伺服器不在:停止,交給 UI
        return this.o.onState?.('fatal');
      }
      if ((this.helloSent && !this.sessionToken) || this.resumeFails >= 3) {
        this.stopped = true; // launch token 已用掉,重送 hello 一定被拒
        return this.o.onState?.('expired');
      }
      this.o.onState?.('closed');
      (this.o.schedule ?? setTimeout)(() => this.connect(), backoffMs(this.attempt++));
    };
  }
}
