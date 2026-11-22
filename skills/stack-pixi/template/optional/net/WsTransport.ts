/**
 * WebSocket 連線(PX-NET-01,`new-pixi.sh --net ws` 加入;放 src/services/net/,純邏輯不 import pixi):
 * - 第一則送 {t:'hello', launchToken};伺服器回 {t:'welcome', sessionToken} 後,重連改送 {t:'resume', sessionToken}。
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
  onState?: (s: 'connecting' | 'open' | 'closed' | 'fatal') => void;
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
    ws.onopen = () => {
      ws.send(JSON.stringify(this.sessionToken ? { t: 'resume', sessionToken: this.sessionToken } : { t: 'hello', launchToken: this.o.launchToken }));
    };
    ws.onmessage = (ev) => {
      let m: Msg;
      try { m = JSON.parse(String(ev.data)) as Msg; } catch { return; }
      if (m.t === 'welcome') {
        if (typeof m.sessionToken === 'string') this.sessionToken = m.sessionToken;
        this.attempt = 0;
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
      this.o.onState?.('closed');
      (this.o.schedule ?? setTimeout)(() => this.connect(), backoffMs(this.attempt++));
    };
  }
}
