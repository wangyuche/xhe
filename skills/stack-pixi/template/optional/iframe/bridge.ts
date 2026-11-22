/**
 * 遊戲在大廳的 iframe 裡(PX-NET-02,`new-pixi.sh --iframe` 加入;放 src/services/iframe/,純邏輯):
 * - 父頁 origin:location.ancestorOrigins[0],沒有就用 document.referrer 的 origin;必須在允許清單內,否則拒絕。
 * - 收訊息:event.source 必須是 window.parent、event.origin 必須等於父頁 origin;送訊息用精確 origin,不用 '*'。
 * - 啟動:送 {t:'hello'},父頁回 {t:'init', launchToken, locale, muted};launchToken 一次性,交給 WsTransport。
 */
export type Envelope = { t: string; [k: string]: unknown };

export function resolveParentOrigin(allowed: readonly string[], loc: { ancestorOrigins?: ArrayLike<string> }, referrer: string): string | undefined {
  const fromAncestor = loc.ancestorOrigins && loc.ancestorOrigins.length > 0 ? loc.ancestorOrigins[0] : undefined;
  let origin = fromAncestor;
  if (!origin && referrer) {
    try { origin = new URL(referrer).origin; } catch { origin = undefined; }
  }
  return origin && allowed.includes(origin) ? origin : undefined;
}

export function acceptMessage(ev: { source: unknown; origin: string; data: unknown }, parent: unknown, parentOrigin: string): Envelope | undefined {
  if (ev.source !== parent || ev.origin !== parentOrigin) return undefined;
  const d = ev.data as Envelope | null;
  return d && typeof d === 'object' && typeof d.t === 'string' ? d : undefined;
}

export function post(parent: { postMessage(m: unknown, origin: string): void }, parentOrigin: string, m: Envelope): void {
  parent.postMessage(m, parentOrigin);
}
