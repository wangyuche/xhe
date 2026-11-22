import { Assets, NineSliceSprite, Rectangle, Texture } from 'pixi.js';
import { forgetAudio } from '../core/audio';
import { chooseTier, type Tier } from './tier';

/**
 * 素材載入(PX-LOAD-01 / 03 / 08、PX-RES-01 / 04 / 05、PX-LIFE-01):
 * - 每個群組 `src/assets/<group>/manifest.json` 由 scripts/build-assets.mjs 產生;檔案經 Vite 加 hash,輸出到 assets/<group>/。
 * - 全部用 lazy glob:群組素材只在 acquireGroup() 時下載,不進首屏。
 * - 參考計數:acquire / release 成對;計數歸零才 unload,而且只 unload 自己載過、cache 裡真的有的 alias。
 */
export interface ManifestEntry {
  type: 'sprite' | 'frames' | 'tile' | 'background' | 'ui' | 'sfx' | 'bgm';
  width?: number;
  height?: number;
  anchor?: [number, number];
  density?: number;
  nineSlice?: [number, number, number, number];
  nineSlice1x?: [number, number, number, number];
  frames?: { count: number; fps: number; frameWidth: number; frameHeight: number; columns: number };
  files: Record<string, string>; // 例如 { "1x.avif": "hero@1x.avif", "1x.png": …, "0.5x.avif": …, "ogg": …, "m4a": … }
}
export type Manifest = { group: string; assets: Record<string, ManifestEntry> };

const manifests = import.meta.glob<Manifest>('./*/manifest.json', { import: 'default' });
// 副檔名與 stack-pixi check-assets / check-early 認得的素材一致(avif png jpg jpeg webp ogg m4a mp3)
const urls = import.meta.glob<string>(['./*/*.avif', './*/*.png', './*/*.jpg', './*/*.jpeg', './*/*.webp', './*/*.ogg', './*/*.m4a', './*/*.mp3'], { query: '?url', import: 'default' });

let tier: Tier = '1x';
/** 選素材級別;之後載入的群組用新級別(已載入的群組不受影響,下次載入才換)。 */
export function setTier(cover: number, dpr: number): void {
  tier = chooseTier(cover, dpr);
}
/** Pixi 內部 alias = `<id>#<級別>`:換級別時是不同的貼圖,不會拿到舊級別的快取。 */
const aliasOf = (id: string, t: Tier): string => `${id}#${t}`;
/** 還在進行的 unload(重新載入同一個 alias 前要等它完成,避免拿到即將被 destroy 的貼圖)。 */
const unloading = new Map<string, Promise<void>>();

const loaded = new Map<string, { count: number; aliases: string[]; aliasById: Map<string, string>; manifest: Manifest; audio: Map<string, { ogg: string; m4a: string }> }>();
/** frames 切出的格貼圖(每個 alias 一份,unload 時 destroy)。 */
const frameCache = new Map<string, Texture[]>();
/** 載入中的群組被 acquire / release 的淨次數(載入完成後併入 count;歸零就直接 release)。 */
const pendingCounts = new Map<string, number>();
/** 已經 Assets.add 過的 alias(unload 後 resolver 仍保留,不要重複 add)。 */
const owner = new Map<string, string>(); // alias → `<group>/<檔名>`(同步登記,不同群組同 id 不同圖時改用帶群組的 alias)
const registered = new Set<string>(); // 已經 Assets.add 過的 alias
/** 每個 alias 被幾個已載入群組使用(PX-LOAD-08:跨群組共用的貼圖,計數歸零才 unload)。 */
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
    p = loadGroup(group, tier).then(() => {
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

async function loadGroup(group: string, t: Tier): Promise<void> {
  const m = manifests[`./${group}/manifest.json`];
  const manifest: Manifest = m ? await m() : { group, assets: {} };
  const aliases: string[] = [];
  const aliasById = new Map<string, string>();
  const audio = new Map<string, { ogg: string; m4a: string }>();
  // 級別在 acquire 當下就決定(t);manifest 載入後立刻佔住每個 alias 的參考計數,之後的 await 期間別的群組 release 也不會把它 unload
  for (const [id, a] of Object.entries(manifest.assets)) {
    if (a.type === 'sfx' || a.type === 'bgm') continue;
    let alias = aliasOf(id, t);
    const want = a.files[`${t}.avif`];
    // 同一個 id 已被別的群組用不同檔案註冊過:改用帶群組的 alias,避免拿到別人的圖
    if (owner.has(alias) && owner.get(alias) !== `${group}/${want}`) alias = `${group}:${alias}`;
    if (!owner.has(alias)) owner.set(alias, `${group}/${want}`); // await 之前登記,同時載入的群組也看得到
    aliasById.set(id, alias);
    aliases.push(alias);
    aliasRefs.set(alias, (aliasRefs.get(alias) ?? 0) + 1);
  }
  try {
    // 所有網址平行解析(每個都是 lazy chunk;逐一 await 在 Slow 4G 下每個多一個 RTT)
    await Promise.all(Object.entries(manifest.assets).map(async ([id, a]) => {
      if (a.type === 'sfx' || a.type === 'bgm') {
        const [ogg, m4a] = await Promise.all([url(group, a.files.ogg!), url(group, a.files.m4a!)]);
        audio.set(id, { ogg, m4a });
        return;
      }
      const alias = aliasById.get(id)!;
      const fallback = a.files[`${t}.png`] ?? a.files[`${t}.jpg`];
      const src = await Promise.all([url(group, a.files[`${t}.avif`]!), url(group, fallback!)]); // PX-FMT-01:Pixi 依支援度選 avif / 備援
      await unloading.get(alias);
      if (!registered.has(alias) && !Assets.cache.has(alias)) { Assets.add({ alias, src }); registered.add(alias); }
    }));
    if (aliases.length) await Assets.load(aliases.filter((al) => !Assets.cache.has(al)));
  } catch (e) {
    for (const al of aliases) { const n = (aliasRefs.get(al) ?? 1) - 1; if (n > 0) aliasRefs.set(al, n); else aliasRefs.delete(al); }
    throw e;
  }
  loaded.set(group, { count: 0, aliases, aliasById, manifest, audio });
}

export function releaseGroup(group: string): void {
  if (pendingLoads.has(group)) { pendingCounts.set(group, (pendingCounts.get(group) ?? 0) - 1); return; }
  const cur = loaded.get(group);
  if (!cur || --cur.count > 0) return;
  loaded.delete(group);
  for (const a of cur.audio.values()) { forgetAudio(a.ogg); forgetAudio(a.m4a); }
  for (const id of cur.aliases) {
    const n = (aliasRefs.get(id) ?? 1) - 1;
    if (n > 0) { aliasRefs.set(id, n); continue; }
    aliasRefs.delete(id);
    for (const t of frameCache.get(id) ?? []) t.destroy(false); // 只毀掉格貼圖,共用的 source 由 Assets 釋放
    frameCache.delete(id);
    if (Assets.cache.has(id)) {
      const p = Assets.unload(id).catch(() => {}).finally(() => unloading.delete(id));
      unloading.set(id, p);
    }
  }
}

/** 取素材資訊;沒有(缺素材)回 undefined,呼叫端畫 Graphics 佔位並把 id 列進 assets.needs.json。 */
export function entry(group: string, id: string): ManifestEntry | undefined {
  return loaded.get(group)?.manifest.assets[id];
}
/** 取貼圖:用這個群組載入時的級別(不同群組可能載入不同級別的同一個 id)。 */
export const texture = (group: string, id: string): Texture | undefined => {
  const alias = loaded.get(group)?.aliasById.get(id);
  return alias && Assets.cache.has(alias) ? Assets.get<Texture>(alias) : undefined;
};
export const audioSrc = (group: string, id: string): { ogg: string; m4a: string } | undefined => loaded.get(group)?.audio.get(id);

/**
 * 九宮格:NineSliceSprite 的邊界是貼圖單位(1x px),所以用 nineSlice1x 與 1x 尺寸建立,再縮放 1/density 回到顯示尺寸。
 * width / height 是要顯示的大小(設計座標);沒給用 manifest 的顯示尺寸。
 */
export function nineSlice(group: string, id: string, width?: number, height?: number): NineSliceSprite | undefined {
  const e = entry(group, id);
  const tex = texture(group, id);
  if (!e?.nineSlice1x || !tex) return undefined;
  const d = e.density ?? 1;
  const [top, right, bottom, left] = e.nineSlice1x;
  const s = new NineSliceSprite({ texture: tex, leftWidth: left, topHeight: top, rightWidth: right, bottomHeight: bottom,
    width: (width ?? e.width!) * d, height: (height ?? e.height!) * d });
  s.scale.set(1 / d);
  return s;
}

/** frames:用 manifest 的格資訊切出各格(貼圖單位 = 1x px,與檔案級別無關)。同一個 alias 只切一次,群組 unload 時 destroy;呼叫端不要自己 destroy。 */
export function frameTextures(group: string, id: string): Texture[] | undefined {
  const e = entry(group, id);
  const alias = loaded.get(group)?.aliasById.get(id);
  const base = texture(group, id);
  if (!e?.frames || !base || !alias) return undefined;
  let list = frameCache.get(alias);
  if (!list) {
    const { count, frameWidth: fw, frameHeight: fh, columns } = e.frames;
    list = Array.from({ length: count }, (_, i) => new Texture({ source: base.source, frame: new Rectangle((i % columns) * fw, Math.floor(i / columns) * fh, fw, fh) }));
    frameCache.set(alias, list);
  }
  return list;
}

/** 測試用:群組目前的參考計數(沒載入 = 0)。 */
export const __refCount = (group: string): number => loaded.get(group)?.count ?? 0;
