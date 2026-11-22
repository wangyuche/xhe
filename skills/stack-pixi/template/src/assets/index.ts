import { Assets, Rectangle, Texture } from 'pixi.js';
import { chooseTier, type Tier } from './tier';

/**
 * 素材載入(PX-LOAD-01 / 03、PX-RES-01、PX-LIFE-01):
 * - 每個群組 `src/assets/<group>/manifest.json` 由 scripts/build-assets.mjs 產生;檔案經 Vite 加 hash,輸出到 assets/<group>/。
 * - 全部用 lazy glob:群組素材只在 acquireGroup() 時下載,不進首屏。
 * - 參考計數:acquire / release 成對;計數歸零才 unload,而且只 unload 自己載過、cache 裡真的有的 alias。
 */
export interface ManifestEntry {
  type: 'sprite' | 'frames' | 'tile' | 'background' | 'ui' | 'sfx' | 'bgm';
  width?: number;
  height?: number;
  anchor?: [number, number];
  nineSlice?: [number, number, number, number];
  frames?: { count: number; fps: number; frameWidth: number; frameHeight: number; columns: number };
  files: Record<string, string>; // 例如 { "1x.avif": "hero@1x.avif", "1x.png": …, "0.5x.avif": …, "ogg": …, "m4a": … }
}
export type Manifest = { group: string; assets: Record<string, ManifestEntry> };

const manifests = import.meta.glob<Manifest>('./*/manifest.json', { import: 'default' });
const urls = import.meta.glob<string>(['./*/*.avif', './*/*.png', './*/*.jpg', './*/*.ogg', './*/*.m4a'], { query: '?url', import: 'default' });

let tier: Tier = '1x';
export function setTier(cover: number, dpr: number): void {
  tier = chooseTier(cover, dpr);
}

const loaded = new Map<string, { count: number; aliases: string[]; manifest: Manifest; audio: Map<string, { ogg: string; m4a: string }> }>();
/** 載入中的群組被 acquire / release 的淨次數(載入完成後併入 count;歸零就直接 release)。 */
const pendingCounts = new Map<string, number>();
/** 已經 Assets.add 過的 alias(unload 後 resolver 仍保留,不要重複 add)。 */
const added = new Set<string>();
/** 每個 alias 被幾個已載入群組使用(PX-LOAD-04:跨群組共用的貼圖,計數歸零才 unload)。 */
const aliasRefs = new Map<string, number>();
const pendingLoads = new Map<string, Promise<void>>();

async function url(group: string, file: string): Promise<string> {
  const load = urls[`./${group}/${file}`];
  if (!load) throw new Error(`asset file missing: ${group}/${file}`);
  return load();
}

export async function acquireGroup(group: string): Promise<void> {
  const cur = loaded.get(group);
  if (cur) {
    cur.count++;
    return;
  }
  pendingCounts.set(group, (pendingCounts.get(group) ?? 0) + 1);
  let p = pendingLoads.get(group);
  if (!p) {
    p = loadGroup(group).then(() => {
      pendingLoads.delete(group);
      const g = loaded.get(group)!;
      g.count += pendingCounts.get(group) ?? 0;
      pendingCounts.delete(group);
      if (g.count <= 0) { g.count = 1; releaseGroup(group); } // 載入期間已全部 release
    }, (e: unknown) => { pendingLoads.delete(group); pendingCounts.delete(group); throw e; });
    pendingLoads.set(group, p);
  }
  await p;
}

async function loadGroup(group: string): Promise<void> {
  const m = manifests[`./${group}/manifest.json`];
  const manifest: Manifest = m ? await m() : { group, assets: {} };
  const aliases: string[] = [];
  const audio = new Map<string, { ogg: string; m4a: string }>();
  // 所有網址平行解析(每個都是 lazy chunk;逐一 await 在 Slow 4G 下每個多一個 RTT)
  await Promise.all(Object.entries(manifest.assets).map(async ([id, a]) => {
    if (a.type === 'sfx' || a.type === 'bgm') {
      const [ogg, m4a] = await Promise.all([url(group, a.files.ogg!), url(group, a.files.m4a!)]);
      audio.set(id, { ogg, m4a });
      return;
    }
    const fallback = a.files[`${tier}.png`] ?? a.files[`${tier}.jpg`];
    const src = await Promise.all([url(group, a.files[`${tier}.avif`]!), url(group, fallback!)]); // PX-FMT-01:Pixi 依支援度選 avif / 備援
    if (!added.has(id) && !Assets.cache.has(id)) { Assets.add({ alias: id, src }); added.add(id); }
    aliases.push(id);
  }));
  if (aliases.length) await Assets.load(aliases.filter((id) => !Assets.cache.has(id)));
  for (const id of aliases) aliasRefs.set(id, (aliasRefs.get(id) ?? 0) + 1);
  loaded.set(group, { count: 0, aliases, manifest, audio });
}

export function releaseGroup(group: string): void {
  if (pendingLoads.has(group)) { pendingCounts.set(group, (pendingCounts.get(group) ?? 0) - 1); return; }
  const cur = loaded.get(group);
  if (!cur || --cur.count > 0) return;
  loaded.delete(group);
  for (const id of cur.aliases) {
    const n = (aliasRefs.get(id) ?? 1) - 1;
    if (n > 0) { aliasRefs.set(id, n); continue; }
    aliasRefs.delete(id);
    if (Assets.cache.has(id)) void Assets.unload(id).catch(() => {});
  }
}

/** 取素材資訊;沒有(缺素材)回 undefined,呼叫端畫 Graphics 佔位並把 id 列進 assets.needs.json。 */
export function entry(group: string, id: string): ManifestEntry | undefined {
  return loaded.get(group)?.manifest.assets[id];
}
export const texture = (id: string): Texture | undefined => (Assets.cache.has(id) ? Assets.get<Texture>(id) : undefined);
export const audioSrc = (group: string, id: string): { ogg: string; m4a: string } | undefined => loaded.get(group)?.audio.get(id);

/** frames:用 manifest 的格資訊切出各格(貼圖單位 = 1x px,與檔案級別無關)。 */
export function frameTextures(group: string, id: string): Texture[] | undefined {
  const e = entry(group, id);
  const base = texture(id);
  if (!e?.frames || !base) return undefined;
  const { count, frameWidth: fw, frameHeight: fh, columns } = e.frames;
  return Array.from({ length: count }, (_, i) => new Texture({ source: base.source, frame: new Rectangle((i % columns) * fw, Math.floor(i / columns) * fh, fw, fh) }));
}

/** 測試用:群組目前的參考計數(沒載入 = 0)。 */
export const __refCount = (group: string): number => loaded.get(group)?.count ?? 0;
