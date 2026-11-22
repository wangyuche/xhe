#!/usr/bin/env node
// game-art-kit:把暫存區(stage)裡已通過檢查的素材「全有或全無」地交付到 art/assets/,並同時換上新的 assets.json。
// 用法:
//   node deliver.mjs --stage <stage 根目錄> --assets <art/assets 目錄> --json <新的 assets.json> <相對路徑>...
//     <相對路徑> 是相對 art/assets/ 的檔案(例如 shop/shop.chest.png、sfx/sfx.jump.ogg),來源是 <stage 根目錄>/<相對路徑>。
//     --json 是這次要寫入的完整 assets.json(保留既有項目、只更新這次交付的項目)。
// 步驟:1. 檢查所有來源存在;2. 複製到目的地旁的暫存名;3. 既有目的地檔改名成備份;4. 暫存名改名成正式名;
//       5. 以 --root <art/assets> 驗證新的 assets.json;6. 通過才把它換上、刪備份。任何一步失敗都還原備份、刪掉新檔,結束碼 1。
//       交付的每個檔都必須出現在 --json 某個項目的 files;相對路徑不能重複;目錄裡有上次中斷留下的 .deliver- 檔時拒絕(附處理方式)。
//       測試用:環境變數 DELIVER_FAIL_AT=copy|place 會在該階段注入失敗(只給 tests/run.sh 用)。
// 結束碼:0 交付完成(印 {"ok":true,"files":[…]});1 交付失敗且已還原(印 {"ok":false,"error":…});2 用法錯誤。
import { existsSync, copyFileSync, renameSync, rmSync, mkdirSync, readFileSync, writeFileSync, realpathSync, readdirSync } from 'node:fs';
import { dirname, join, resolve, sep, isAbsolute, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validate } from '../schemas/validate.mjs';

class Fail extends Error { constructor(m, c) { super(m); this.code = c; } }
const die = (m, c = 2) => { throw new Fail(m, c); };

export function deliver({ stage, assets, json, files, failAt = process.env.DELIVER_FAIL_AT }) {
  if (!files.length) die('至少要給一個相對路徑');
  for (const f of files) if (isAbsolute(f) || normalize(f).split(sep).includes('..')) die(`相對路徑不能是絕對路徑或含 ..:${f}`);
  if (new Set(files.map(f => normalize(f))).size !== files.length) die('相對路徑重複');
  let next;
  try { next = JSON.parse(readFileSync(json, 'utf8')); } catch (e) { die(`讀不到 --json ${json}:${e.message}`); }
  const listed = new Set((next.assets ?? []).flatMap(a => (a.files ?? []).map(f => normalize(f))));
  for (const f of files) if (!listed.has(normalize(f))) die(`--json 的 assets 沒有任何項目的 files 列出 ${f}(交付的檔要和 assets.json 一起更新)`);
  for (const f of files) if (!existsSync(join(stage, f))) die(`stage 沒有 ${f}(先確認該項 check 通過且輸出在 stage)`, 1);
  // 上次中斷留下的暫存 / 備份檔:不覆蓋,請先人工處理
  const leftovers = [];
  for (const dir of new Set([assets, ...files.map(f => dirname(join(assets, f)))])) {
    if (!existsSync(dir)) continue;
    for (const n of readdirSync(dir)) if (n.includes('.deliver-')) leftovers.push(join(dir, n));
  }
  if (leftovers.length) die(`發現上次中斷留下的檔(含 .deliver-):${leftovers.join(', ')}。` +
    '`.bak` 結尾的是交付前的舊檔:正式檔不存在時把它改名回去,存在時刪掉;其他 .deliver- 檔是沒換上的新檔,刪掉即可。處理完再重跑。');
  const uniq = `.deliver-${process.pid}`;
  const done = []; // {dest, tmp, bak, placed}
  const target = join(assets, 'assets.json'), targetTmp = target + uniq, targetBak = target + uniq + '.bak';
  let jsonSwapped = false;
  const rollback = () => {
    const errs = [];
    const step = (fn) => { try { fn(); } catch (e) { errs.push(e.message); } };
    for (const d of [...done].reverse()) {
      if (d.placed) step(() => rmSync(d.dest, { force: true }));
      step(() => rmSync(d.tmp, { force: true }));
      if (d.bak && existsSync(d.bak)) step(() => renameSync(d.bak, d.dest));
    }
    step(() => rmSync(targetTmp, { force: true }));
    if (jsonSwapped && existsSync(targetBak)) step(() => { rmSync(target, { force: true }); renameSync(targetBak, target); });
    return errs;
  };
  try {
    for (const f of files) {
      const dest = join(assets, f), tmp = dest + uniq;
      mkdirSync(dirname(dest), { recursive: true });
      const d = { dest, tmp, bak: null, placed: false }; done.push(d);
      copyFileSync(join(stage, f), tmp);
      if (failAt === 'copy') throw new Error('測試注入:複製失敗');
    }
    for (const d of done) { if (existsSync(d.dest)) { d.bak = d.dest + uniq + '.bak'; renameSync(d.dest, d.bak); } renameSync(d.tmp, d.dest); d.placed = true; }
    if (failAt === 'place') throw new Error('測試注入:換檔後失敗');
    const errs = validate('assets', next, { root: assets });
    if (errs.length) throw new Error(`新的 assets.json 驗證不通過:${errs.slice(0, 5).join(';')}`);
    writeFileSync(targetTmp, JSON.stringify(next, null, 2) + '\n');
    if (existsSync(target)) { renameSync(target, targetBak); jsonSwapped = true; }
    renameSync(targetTmp, target);
  } catch (e) {
    const restoreErrs = rollback();
    if (e instanceof Fail) throw e;
    throw new Fail(`交付失敗,已還原:${e.message}` + (restoreErrs.length ? `;還原時另有錯誤(請人工檢查 .deliver- 檔):${restoreErrs.join(';')}` : ''), 1);
  }
  // 到這裡已經提交(新檔與新 assets.json 都換上了):清備份失敗只警告,不回滾
  const warnings = [];
  for (const p of [...done.map(d => d.bak).filter(Boolean), targetBak]) { try { rmSync(p, { force: true }); } catch (e) { warnings.push(`刪不掉備份 ${p}:${e.message}`); } }
  return { ok: true, files, ...(warnings.length ? { warnings } : {}) };
}

const isMain = (() => { try { return !!process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } })();
if (isMain) {
  try {
    const a = process.argv.slice(2), flags = {}, files = [];
    for (let i = 0; i < a.length; i++) {
      if (['--stage', '--assets', '--json'].includes(a[i])) flags[a[i].slice(2)] = a[++i] ?? die(`${a[i]} 缺值`);
      else if (a[i].startsWith('--')) die(`不認得的參數 ${a[i]}`);
      else files.push(a[i]);
    }
    for (const k of ['stage', 'assets', 'json']) if (!flags[k]) die(`缺 --${k}`);
    const r = deliver({ stage: resolve(flags.stage), assets: resolve(flags.assets), json: resolve(flags.json), files });
    console.log(JSON.stringify(r));
  } catch (e) {
    console.log(JSON.stringify({ ok: false, error: e.message }));
    process.exit(e instanceof Fail ? e.code : 1);
  }
}
