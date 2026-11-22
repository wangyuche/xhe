// 素材建置(stack-pixi):art/assets/assets.json(game-concept-artist 交件,1x 原圖)→ src/assets/<group>/ 的 1x / 0.5x、AVIF + PNG(不透明另出 JPG)、manifest.json。
//   node scripts/build-assets.mjs [--src <art/assets 目錄>] [--budgets docs/performance-budgets.md]
//   預設 --src ../art/assets(相對這個專案)。產出進 git。超過「## 素材預算」的 KB 就結束碼 1(PX-PERF-07)。
//   需要 sharp(devDependency)。驗證用 scripts/schemas/validate.mjs(new-pixi.sh 從 game-art-kit/schemas 複製)。
import { mkdirSync, readFileSync, rmSync, writeFileSync, copyFileSync, statSync, existsSync, readdirSync, renameSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import { validate } from './schemas/validate.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const arg = (n, d) => { const i = process.argv.indexOf(n); return i > 0 ? process.argv[i + 1] : d; };
const SRC = resolve(ROOT, arg('--src', '../art/assets'));
const BUDGETS = resolve(ROOT, arg('--budgets', 'docs/performance-budgets.md'));
const OUT = join(ROOT, 'src/assets');
const MAX = { '1x': 2048, '0.5x': 1024 }; // PX-RES-01
const AVIF = { '1x': { quality: 60, effort: 6, chromaSubsampling: '4:4:4' }, '0.5x': { quality: 50, effort: 6, chromaSubsampling: '4:2:0' } };
const IMAGE = new Set(['sprite', 'frames', 'tile', 'background', 'ui']);
const half = (n) => Math.max(2, Math.ceil(n / 2 / 2) * 2); // 0.5x:一半,無條件進位成偶數(同 MahjongParty)

const die = (m) => { console.error(`build-assets: ${m}`); process.exit(1); };
const file = join(SRC, 'assets.json');
if (!existsSync(file)) die(`找不到 ${file}`);
const doc = JSON.parse(readFileSync(file, 'utf8'));
const errs = validate('assets', doc, { root: SRC });
if (errs.length) die(`assets.json 不合 schema:\n  ${errs.join('\n  ')}`);

// 預算表:「## 素材預算」下的 | group | 1x_kb | 0.5x_kb |
function budgets() {
  if (!existsSync(BUDGETS)) return {};
  const md = readFileSync(BUDGETS, 'utf8');
  const sec = md.split(/^## /m).find((s) => s.startsWith('素材預算'));
  const out = {};
  for (const line of (sec ?? '').split('\n')) {
    const c = line.split('|').map((x) => x.trim());
    if (c.length >= 5 && /^[a-z0-9][a-z0-9-]*$/.test(c[1]) && c[1] !== 'group' && /^(\d+(\.\d+)?(\s|\(|$)|—|-|$)/.test(c[2])) { // 表頭(1x_kb)不算
      const n = (s) => (/^\d+(\.\d+)?/.test(s) ? parseFloat(s) : undefined);
      out[c[1]] = { '1x': n(c[2]), '0.5x': n(c[3]) };
    }
  }
  return out;
}
const BUDGET = budgets();

const groups = new Map();
for (const a of doc.assets) (groups.get(a.group) ?? groups.set(a.group, []).get(a.group)).push(a);

// 先檢查全部素材(尺寸、frames、上限),任何一項不合格就在動到既有產出之前結束
const metas = new Map();
for (const a of doc.assets) {
  if (!IMAGE.has(a.type)) continue;
  const meta = await sharp(join(SRC, a.files[0])).metadata();
  if (a.frames) {
    const { frameWidth: fw, frameHeight: fh, columns, count } = a.frames;
    if (fw % 2 || fh % 2) die(`${a.id}:frameWidth / frameHeight 要是偶數(0.5x 才能剛好一半、格子不偏移)`);
    const W = fw * columns, H = fh * Math.ceil(count / columns);
    if (meta.width !== W || meta.height !== H) die(`${a.id}:frames sheet 應剛好 ${W}×${H}(frameWidth × columns、frameHeight × rows),實際 ${meta.width}×${meta.height}`);
  } else {
    const W = Math.round(a.width * a.density), H = Math.round(a.height * a.density);
    // 容許 ±1 px(sprite.mjs density 的 1x 寬無條件捨去、density 取 4 位小數;同 validate.mjs)
    if (Math.abs(meta.width - W) > 1 || Math.abs(meta.height - H) > 1) die(`${a.id}:1x 應為 ${W}×${H}(顯示 × density),實際 ${meta.width}×${meta.height}`);
  }
  for (const tier of ['1x', '0.5x']) {
    const w = tier === '1x' ? meta.width : a.frames ? meta.width / 2 : half(meta.width);
    const h = tier === '1x' ? meta.height : a.frames ? meta.height / 2 : half(meta.height);
    if (w > MAX[tier] || h > MAX[tier]) die(`${a.id}:${tier} ${w}×${h} 超過 ${MAX[tier]}²(PX-RES-01)`);
  }
  metas.set(a.id, meta);
}

// 既有 manifest:只有 build-assets 自己產生的(generatedBy)才會被覆寫或清理,而且只刪它列出的檔案;
// 手寫的 manifest(例如 boot 群組的 logo)有內容時拒絕覆寫,空的骨架 manifest 可以接手
const readManifest = (g) => { try { return JSON.parse(readFileSync(join(OUT, g, 'manifest.json'), 'utf8')); } catch { return undefined; } };
const ownedFiles = (m) => (m?.generatedBy === 'build-assets' ? Object.values(m.assets ?? {}).flatMap((e) => Object.values(e.files ?? {})) : []);
for (const g of groups.keys()) {
  const m = readManifest(g);
  if (m && m.generatedBy !== 'build-assets' && Object.keys(m.assets ?? {}).length) die(`src/assets/${g}/manifest.json 是手寫的而且有內容;assets.json 不能用同一個群組名(請改群組或把手寫素材移走)`);
}

// 1) 每個群組先產生到暫存資料夾(任何例外都清掉暫存)
const built = [];
process.on('exit', () => { for (const g of groups.keys()) rmSync(join(OUT, `.build-${g}`), { recursive: true, force: true }); });
let over = false;
for (const [group, list] of groups) {
  const dir = join(OUT, `.build-${group}`);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  const manifest = { group, generatedBy: 'build-assets', assets: {} };
  const kb = { '1x': 0, '0.5x': 0 };
  for (const a of list) {
    const e = { type: a.type, files: {} };
    if (IMAGE.has(a.type)) {
      const src = join(SRC, a.files[0]);
      const meta = metas.get(a.id);
      for (const tier of ['1x', '0.5x']) {
        // frames:0.5x 一定剛好一半(格寬高已要求偶數),格子才不偏移;其他圖一半後進位成偶數
        const w = tier === '1x' ? meta.width : a.frames ? meta.width / 2 : half(meta.width);
        const h = tier === '1x' ? meta.height : a.frames ? meta.height / 2 : half(meta.height);
        const img = sharp(src).resize(w, h, { fit: 'fill' });
        const base = `${a.id}@${tier}`;
        const outs = [[`${tier}.avif`, `${base}.avif`, img.clone().avif(AVIF[tier])]];
        if (a.opaque) outs.push([`${tier}.jpg`, `${base}.jpg`, img.clone().flatten().jpeg({ quality: 82, mozjpeg: true })]);
        else outs.push([`${tier}.png`, `${base}.png`, img.clone().png({ compressionLevel: 9 })]);
        for (const [key, name, pipe] of outs) {
          await pipe.toFile(join(dir, name));
          e.files[key] = name;
          if (name.endsWith('.avif')) kb[tier] += statSync(join(dir, name)).size / 1024;
        }
      }
      Object.assign(e, { width: a.width, height: a.height, density: a.density, anchor: a.anchor });
      if (a.nineSlice) { e.nineSlice = a.nineSlice; e.nineSlice1x = a.nineSlice1x; } // 顯示 px 與貼圖單位(1x px)
      if (a.frames) e.frames = a.frames; // 貼圖單位 = 1x px(0.5x 檔名 @0.5x,Pixi 依此換算)
    } else {
      for (const f of a.files) {
        const ext = f.split('.').pop();
        const name = `${a.id}.${ext}`;
        copyFileSync(join(SRC, f), join(dir, name));
        e.files[ext] = name;
      }
      Object.assign(e, { durationSec: a.durationSec, loop: a.loop ?? false });
    }
    manifest.assets[a.id] = e;
  }
  writeFileSync(join(dir, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  const b = BUDGET[group];
  for (const tier of ['1x', '0.5x']) {
    const lim = b?.[tier];
    const mark = lim === undefined ? '(預算未設定)' : kb[tier] > lim ? `✗ 超過 ${lim} KB` : `≤ ${lim} KB`;
    if (lim !== undefined && kb[tier] > lim) over = true;
    console.log(`${group} ${tier} AVIF ${kb[tier].toFixed(1)} KB ${mark}`);
  }
  built.push({ group, dir });
}
// 超過預算:不換上任何產出(既有檔案保持原樣)
if (over) {
  for (const { dir } of built) rmSync(dir, { recursive: true, force: true });
  die('素材超過預算(PX-PERF-07);既有產出未變更');
}

// 2) 全部成功才換上:只刪舊 manifest(build-assets 產生的)列出的檔案,保留手寫檔案
for (const { group, dir } of built) {
  const final = join(OUT, group);
  mkdirSync(final, { recursive: true });
  for (const f of ownedFiles(readManifest(group))) rmSync(join(final, f), { force: true });
  for (const f of readdirSync(dir)) renameSync(join(dir, f), join(final, f));
  rmSync(dir, { recursive: true, force: true });
}
// 3) assets.json 已經沒有的群組:只清 build-assets 產生過的
for (const g of existsSync(OUT) ? readdirSync(OUT) : []) {
  if (groups.has(g) || g.startsWith('.')) continue;
  const m = readManifest(g);
  if (m?.generatedBy !== 'build-assets') continue;
  for (const f of ownedFiles(m)) rmSync(join(OUT, g, f), { force: true });
  writeFileSync(join(OUT, g, 'manifest.json'), JSON.stringify({ group: g, generatedBy: 'build-assets', assets: {} }, null, 2) + '\n');
  console.log(`${g}:assets.json 已沒有這個群組,清空 build-assets 的產出`);
}
