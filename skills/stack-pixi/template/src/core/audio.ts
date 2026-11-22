import { isPaused, onPauseChange } from './pause';

/**
 * 音訊(PX-FMT-07):ogg(Opus)優先,不支援就 m4a(AAC)。第一次使用者手勢後才建立 AudioContext 與下載 BGM(首屏不含 BGM)。
 * 暫停狀態(背景、旋轉)時 suspend。只用 Web Audio,不 import pixi。
 */
type Src = { ogg: string; m4a: string };
let ctx: AudioContext | undefined;
let unlocked = false;
const buffers = new Map<string, Promise<AudioBuffer>>();
const pending: Array<() => void> = [];

export const audioUnlocked = (): boolean => unlocked;

export function startAudioUnlock(): void {
  const unlock = (): void => {
    if (unlocked) return;
    unlocked = true;
    ctx = new AudioContext();
    if (!isPaused()) void ctx.resume();
    else void ctx.suspend(); // 暫停中(背景、旋轉提示)解鎖:等恢復時才出聲
    for (const fn of pending.splice(0)) fn();
  };
  for (const ev of ['pointerdown', 'keydown']) window.addEventListener(ev, unlock, { once: false, capture: true });
  onPauseChange((paused) => { if (ctx) void (paused ? ctx.suspend() : ctx.resume()); });
}

function pick(src: Src): string {
  return new Audio().canPlayType('audio/ogg; codecs=opus') ? src.ogg : src.m4a;
}

function load(src: Src): Promise<AudioBuffer> {
  const url = pick(src);
  let p = buffers.get(url);
  if (!p) {
    p = fetch(url)
      .then((r) => { if (!r.ok) throw new Error(`audio ${r.status}: ${url}`); return r.arrayBuffer(); })
      .then((b) => ctx!.decodeAudioData(b));
    buffers.set(url, p);
    p.catch(() => buffers.delete(url)); // 失敗不快取,下次再試
  }
  return p;
}

export function playSfx(src: Src | undefined, opts: { loop?: boolean } = {}): void {
  if (!src) return;
  const run = (): void => {
    void load(src).catch(() => undefined).then((buf) => {
      if (!buf) return;
      const node = ctx!.createBufferSource();
      node.buffer = buf;
      node.loop = !!opts.loop;
      node.connect(ctx!.destination);
      node.start();
    });
  };
  if (unlocked) run();
  else if (opts.loop) pending.push(run); // BGM 等手勢後再下載與播放
}
