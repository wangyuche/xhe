#!/usr/bin/env node
// game-art-kit:把暫存區(stage)裡已通過檢查的素材「全有或全無」地交付到 art/assets/,並同時換上新的 assets.json。
// 用法:
//   node deliver.mjs --stage <stage 根目錄> --assets <art/assets 目錄> --json <新的 assets.json> <相對路徑>...
//     <相對路徑> 是相對 art/assets/ 的檔案(例如 shop/shop.chest.png、sfx/sfx.jump.ogg),來源是 <stage 根目錄>/<相對路徑>。
//     --json 是這次要寫入的完整 assets.json(保留既有項目、只更新這次交付的項目)。
// 步驟:1. 檢查所有來源存在;2. 複製到目的地旁的暫存名;3. 既有目的地檔改名成備份;4. 暫存名改名成正式名;
//       5. 以 --root <art/assets> 驗證新的 assets.json;6. 通過才把它換上、刪備份。任何一步失敗都還原備份、刪掉新檔,結束碼 1。
// 結束碼:0 交付完成(印 {"ok":true,"files":[…]});1 交付失敗且已還原(印 {"ok":false,"error":…});2 用法錯誤。
import { existsSync, copyFileSync, renameSync, rmSync, mkdirSync, readFileSync, writeFileSync, realpathSync } from 'node:fs';
import { dirname, join, resolve, sep, isAbsolute, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validate } from '../schemas/validate.mjs';

class Fail extends Error { constructor(m, c) { super(m); this.code = c; } }
const die = (m, c = 2) => { throw new Fail(m, c); };

export function deliver({ stage, assets, json, files, failAt }) {
  if (!files.length) die('至少要給一個相對路徑');
  for (const f of files) if (isAbsolute(f) || normalize(f).split(sep).includes('..')) die(`相對路徑不能是絕對路徑或含 ..:${f}`);
  let next;
  try { next = JSON.parse(readFileSync(json, 'utf8')); } catch (e) { die(`讀不到 --json ${json}:${e.message}`); }
  for (const f of files) if (!existsSync(join(stage, f))) die(`stage 沒有 ${f}(先確認該項 check 通過且輸出在 stage)`, 1);
  const uniq = `.deliver-${process.pid}`;
  const done = []; // {dest, tmp, bak}
  const target = join(assets, 'assets.json'), targetTmp = target + uniq, targetBak = target + uniq + '.bak';
  let jsonSwapped = false;
  const rollback = () => {
    for (const d of done.reverse()) {
      if (d.placed) rmSync(d.dest, { force: true });
      rmSync(d.tmp, { force: true });
      if (d.bak && existsSync(d.bak)) renameSync(d.bak, d.dest);
    }
    rmSync(targetTmp, { force: true });
    if (jsonSwapped && existsSync(targetBak)) renameSync(targetBak, target);
  };
  try {
    for (const f of files) {
      const dest = join(assets, f), tmp = dest + uniq;
      mkdirSync(dirname(dest), { recursive: true });
      const d = { dest, tmp, bak: null, placed: false }; done.push(d);
      copyFileSync(join(stage, f), tmp);
      if (failAt === 'copy') throw new Error('測試注入:複製失敗');
    }
    for (const d of done) { if (existsSync(d.dest)) { d.bak = d.dest + '.bak'; renameSync(d.dest, d.bak); } renameSync(d.tmp, d.dest); d.placed = true; }
    if (failAt === 'place') throw new Error('測試注入:換檔後失敗');
    const errs = validate('assets', next, { root: assets });
    if (errs.length) throw new Error(`新的 assets.json 驗證不通過:${errs.slice(0, 5).join(';')}`);
    writeFileSync(targetTmp, JSON.stringify(next, null, 2) + '\n');
    if (existsSync(target)) { renameSync(target, targetBak); jsonSwapped = true; }
    renameSync(targetTmp, target);
    for (const d of done) if (d.bak) rmSync(d.bak, { force: true });
    rmSync(targetBak, { force: true });
    return { ok: true, files };
  } catch (e) {
    rollback();
    if (e instanceof Fail) throw e;
    throw new Fail(`交付失敗,已還原:${e.message}`, 1);
  }
}

const isMain = (() => { try { return !!process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } })();
if (isMain) {
  try {
    const a = process.argv.slice(2), flags = {}, files = [];
    for (let i = 0; i < a.length; i++) {
      if (['--stage', '--assets', '--json', '--fail-at'].includes(a[i])) flags[a[i].slice(2)] = a[++i] ?? die(`${a[i]} 缺值`);
      else if (a[i].startsWith('--')) die(`不認得的參數 ${a[i]}`);
      else files.push(a[i]);
    }
    for (const k of ['stage', 'assets', 'json']) if (!flags[k]) die(`缺 --${k}`);
    const r = deliver({ stage: resolve(flags.stage), assets: resolve(flags.assets), json: resolve(flags.json), files, failAt: flags['fail-at'] });
    console.log(JSON.stringify(r));
  } catch (e) {
    console.log(JSON.stringify({ ok: false, error: e.message }));
    process.exit(e instanceof Fail ? e.code : 1);
  }
}
