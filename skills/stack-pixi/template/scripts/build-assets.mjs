// 素材建置(stack-pixi):art/assets/assets.json(game-concept-artist 交件,1x 原圖)→ src/assets/<group>/ 的 1x / 0.5x、AVIF + PNG(不透明另出 JPG)、manifest.json。
//   node scripts/build-assets.mjs [--src <art/assets 目錄>] [--budgets docs/performance-budgets.md]
//   預設 --src ../art/assets(相對這個專案)。產出進 git。超過「## 素材預算」的 KB 就結束碼 1(PX-PERF-07)。
//   需要 sharp(devDependency)。驗證用 scripts/schemas/validate.mjs(new-pixi.sh 從 game-art-kit/schemas 複製)。
import { mkdirSync, readFileSync, rmSync, writeFileSync, copyFileSync, statSync, existsSync, readdirSync } from 'node:fs';
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
    if (c.length >= 5 && /^[a-z0-9][a-z0-9-]*$/.test(c[1])) {
      const n = (s) => (/^\d+(\.\d+)?/.test(s) ? parseFloat(s) : undefined);
      out[c[1]] = { '1x': n(c[2]), '0.5x': n(c[3]) };
    }
  }
  return out;
}
const BUDGET = budgets();

const groups = new Map();
for (const a of doc.assets) (groups.get(a.group) ?? groups.set(a.group, []).get(a.group)).push(a);

let over = false;
for (const [group, list] of groups) {
  const dir = join(OUT, group);
  // 只清掉 build-assets 產生的檔案(manifest 與素材),保留同目錄下手寫的程式
  if (existsSync(dir)) for (const f of readdirSync(dir)) if (/\.(avif|png|jpg|ogg|m4a)$/.test(f) || f === 'manifest.json') rmSync(join(dir, f));
  mkdirSync(dir, { recursive: true });
  const manifest = { group, assets: {} };
  const kb = { '1x': 0, '0.5x': 0 };
  for (const a of list) {
    const e = { type: a.type, files: {} };
    if (IMAGE.has(a.type)) {
      const src = join(SRC, a.files[0]);
      const meta = await sharp(src).metadata();
      const expectW = a.frames ? a.frames.frameWidth * a.frames.columns : Math.round(a.width * a.density);
      const expectH = a.frames ? a.frames.frameHeight * Math.ceil(a.frames.count / a.frames.columns) : Math.round(a.height * a.density);
      if (a.frames && (a.frames.frameWidth % 2 || a.frames.frameHeight % 2)) die(`${a.id}:frameWidth / frameHeight 要是偶數(0.5x 才能剛好一半、格子不偏移)`);
      if (meta.width !== expectW || meta.height !== expectH) die(`${a.id}:1x 應為 ${expectW}×${expectH}(顯示 × density),實際 ${meta.width}×${meta.height}`);
      for (const tier of ['1x', '0.5x']) {
        const w = tier === '1x' ? meta.width : half(meta.width);
        const h = tier === '1x' ? meta.height : half(meta.height);
        if (w > MAX[tier] || h > MAX[tier]) die(`${a.id}:${tier} ${w}×${h} 超過 ${MAX[tier]}²(PX-RES-01)`);
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
      Object.assign(e, { width: a.width, height: a.height, anchor: a.anchor });
      if (a.nineSlice) e.nineSlice = a.nineSlice;
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
}
if (over) die('素材超過預算(PX-PERF-07)');
