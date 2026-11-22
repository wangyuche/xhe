#!/usr/bin/env node
// game-art-kit:把暫存區(stage)裡已通過檢查的素材「全有或全無」地交付到 art/assets/,並同時換上新的 assets.json。
// 用法:
//   node deliver.mjs --stage <stage 根目錄> --assets <art/assets 目錄> --json <新的 assets.json> <相對路徑>...
//     <相對路徑> 是相對 art/assets/ 的檔案(例如 shop/shop.chest.png、sfx/sfx.jump.ogg),來源是 <stage 根目錄>/<相對路徑>。
//     --json 是這次要寫入的完整 assets.json(保留既有項目、只更新這次交付的項目)。
//   node deliver.mjs --recover --assets <art/assets 目錄>
//     依上次中斷留下的交付日誌自動收拾:還沒提交 → 把舊檔與舊 assets.json 全部換回;已提交 → 只刪備份。
// 規則:交付的每個檔都要列在 --json 某項目的 files;內容有變的項目,它的 files 要全部一起交付(例如音訊 .ogg 與 .m4a);
//       相對路徑(不分大小寫)不能重複;assets 目錄有交付日誌(上次中斷)時拒絕,請先 --recover。
// 步驟:複製到暫存名 → 寫日誌(placing)→ 舊檔改名成備份、暫存名改成正式名 → 驗證 → 換上 assets.json → 日誌改 committed
//       → 刪備份與日誌。提交前任何一步失敗都還原;提交後清理失敗只警告。
// 測試用:環境變數 DELIVER_FAIL_AT=copy|place|validate 會在該階段注入失敗(只給 tests/run.sh 用)。
// 結束碼:0 完成(印 {"ok":true,…});1 交付失敗且已還原;2 用法錯誤 / 需要先 --recover。
import { existsSync, copyFileSync, renameSync, rmSync, rmdirSync, mkdirSync, readFileSync, writeFileSync, realpathSync, readdirSync } from 'node:fs';
import { dirname, join, resolve, sep, isAbsolute, normalize, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validate } from '../schemas/validate.mjs';

class Fail extends Error { constructor(m, c) { super(m); this.code = c; } }
const die = (m, c = 2) => { throw new Fail(m, c); };
const JOURNAL = '.deliver-journal.json';
const norm = (f) => normalize(f).split(sep).join('/');
const key = (f) => norm(f).toLowerCase(); // macOS 預設不分大小寫
const canon = (v) => Array.isArray(v) ? `[${v.map(canon).join(',')}]` : v && typeof v === 'object' ? `{${Object.keys(v).sort().map(k => JSON.stringify(k) + ':' + canon(v[k])).join(',')}}` : JSON.stringify(v); // 不受鍵順序影響

function readJson(p, what) {
  let v; try { v = JSON.parse(readFileSync(p, 'utf8')); } catch (e) { die(`讀不到 ${what} ${p}:${e.message}`); }
  return v;
}

// 依日誌收拾上次中斷的交付
export function recover(assets) {
  const jp = join(assets, JOURNAL);
  if (!existsSync(jp)) return { ok: true, recovered: false };
  let j; try { j = JSON.parse(readFileSync(jp, 'utf8')); } catch (e) { die(`交付日誌 ${jp} 讀不出來(${e.message}):請人工檢查 art/assets 裡的 .deliver- 檔(.bak 結尾是交付前的舊檔),處理完刪掉日誌再重跑`, 1); }
  const errs = [], step = (fn) => { try { fn(); } catch (e) { errs.push(e.message); } };
  if (j.state === 'committed') {
    for (const e of j.entries) if (e.bak) step(() => rmSync(join(assets, e.bak), { force: true }));
    step(() => rmSync(join(assets, j.jsonBak), { force: true }));
  } else {
    for (const e of [...j.entries].reverse()) {
      const tmpLeft = existsSync(join(assets, e.tmp)); // 還在 = 沒換名
      step(() => rmSync(join(assets, e.tmp), { force: true }));
      if (e.bak && existsSync(join(assets, e.bak))) step(() => { rmSync(join(assets, e.dest), { force: true }); renameSync(join(assets, e.bak), join(assets, e.dest)); });
      // 原本沒有這個檔:已換上(placed),或換名途中被砍(placing 且 tmp 已不在)→ 新檔拿掉
      else if (!e.bak && (e.placed || (e.placing && !tmpLeft))) step(() => rmSync(join(assets, e.dest), { force: true }));
    }
    step(() => rmSync(join(assets, j.jsonTmp), { force: true }));
    if (existsSync(join(assets, j.jsonBak))) step(() => { rmSync(join(assets, 'assets.json'), { force: true }); renameSync(join(assets, j.jsonBak), join(assets, 'assets.json')); });
    else if (j.jsonExisted === false) step(() => rmSync(join(assets, 'assets.json'), { force: true })); // 第一次交付:原本沒有 assets.json
    for (const d of [...(j.createdDirs ?? [])].reverse()) step(() => { if (existsSync(join(assets, d)) && !readdirSync(join(assets, d)).length) rmdirSync(join(assets, d)); });
  }
  if (errs.length) die(`還原時有錯誤,日誌保留,請人工檢查:${errs.join(';')}`, 1);
  rmSync(jp, { force: true });
  return { ok: true, recovered: true, state: j.state ?? 'placing' };
}

export function deliver({ stage, assets, json, files, failAt = process.env.DELIVER_FAIL_AT }) {
  if (!files.length) die('至少要給一個相對路徑');
  for (const f of files) if (isAbsolute(f) || normalize(f).split(sep).includes('..')) die(`相對路徑不能是絕對路徑或含 ..:${f}`);
  if (new Set(files.map(key)).size !== files.length) die('相對路徑重複(不分大小寫)');
  if (existsSync(join(assets, JOURNAL))) die(`${join(assets, JOURNAL)} 存在:上次交付中斷了。先跑 node deliver.mjs --recover --assets ${assets},再重跑這次交付`);
  const next = readJson(json, '--json');
  if (!next || typeof next !== 'object' || !Array.isArray(next.assets) || next.assets.some(a => !a || typeof a !== 'object' || !Array.isArray(a.files)))
    die('--json 格式不對:要是 {"assets":[{…,"files":[…]}]}');
  const delivered = new Set(files.map(key));
  const listed = new Set(next.assets.flatMap(a => a.files.map(key)));
  for (const f of files) if (!listed.has(key(f))) die(`--json 的 assets 沒有任何項目的 files 列出 ${f}(交付的檔要和 assets.json 一起更新)`);
  // 內容有變的項目(新增或和目前 assets.json 不同),它的 files 要全部一起交付
  const target = join(assets, 'assets.json');
  const cur = existsSync(target) ? readJson(target, '目前的 assets.json') : { assets: [] };
  const curById = new Map((cur.assets ?? []).map(a => [a.id, canon(a)]));
  for (const a of next.assets) {
    if (curById.get(a.id) === canon(a)) continue;
    const missing = a.files.filter(f => !delivered.has(key(f)));
    if (missing.length) die(`項目 ${a.id} 有變更,但這些檔沒有一起交付:${missing.join(', ')}`);
  }
  const nextIds = new Set(next.assets.map(a => a.id));
  const dropped = (cur.assets ?? []).map(a => a.id).filter(id => !nextIds.has(id));
  if (dropped.length) die(`新的 assets.json 少了既有項目:${dropped.join(', ')}(--json 要保留所有既有項目)`);
  for (const f of files) if (!existsSync(join(stage, f))) die(`stage 沒有 ${f}(先確認該項 check 通過且輸出在 stage)`, 1);
  // 驗證:schema 看整份;檔案存在只看這次有變更的項目(無關的舊項目缺檔只警告,不擋這次交付)
  const changedIds = new Set(next.assets.filter(a => curById.get(a.id) !== canon(a)).map(a => a.id));
  const schemaErrs = validate('assets', next);
  if (schemaErrs.length) die(`新的 assets.json 格式不通過:${schemaErrs.slice(0, 5).join(';')}`);
  const unrelatedMissing = next.assets.filter(a => !changedIds.has(a.id)).flatMap(a => a.files.filter(f => !delivered.has(key(f)) && !existsSync(join(assets, f))));

  const uniq = `.deliver-${process.pid}`;
  const entries = files.map(f => ({ dest: norm(f), tmp: norm(f) + uniq, bak: null, placed: false }));
  const journal = { state: 'copying', entries, jsonTmp: 'assets.json' + uniq, jsonBak: 'assets.json' + uniq + '.bak', jsonExisted: existsSync(target), createdDirs: [] };
  const saveJournal = () => { const t = join(assets, JOURNAL + uniq); writeFileSync(t, JSON.stringify(journal, null, 2)); renameSync(t, join(assets, JOURNAL)); };
  if (!existsSync(assets)) die(`--assets ${assets} 不存在(先 mkdir -p 它)`);
  saveJournal();
  try {
    for (const e of entries) {
      let d = dirname(join(assets, e.dest)); const toMake = [];
      while (!existsSync(d)) { toMake.unshift(d); d = dirname(d); }
      for (const m of toMake) { journal.createdDirs.push(norm(relative(assets, m))); saveJournal(); mkdirSync(m); }
      copyFileSync(join(stage, e.dest), join(assets, e.tmp));
      if (failAt === 'copy') throw new Error('測試注入:複製失敗');
    }
    journal.state = 'placing'; saveJournal();
    for (const e of entries) {
      if (existsSync(join(assets, e.dest))) { e.bak = e.dest + uniq + '.bak'; saveJournal(); renameSync(join(assets, e.dest), join(assets, e.bak)); }
      e.placing = true; saveJournal();
      renameSync(join(assets, e.tmp), join(assets, e.dest)); e.placed = true; saveJournal();
    }
    if (failAt === 'place') throw new Error('測試注入:換檔後失敗');
    const fileErrs = next.assets.filter(a => changedIds.has(a.id)).flatMap(a => a.files.filter(f => !existsSync(join(assets, f))).map(f => `${a.id}: 缺 ${f}`));
    if (fileErrs.length || failAt === 'validate') throw new Error(`交付後檢查不通過:${fileErrs.join(';') || '測試注入'}`);
    writeFileSync(join(assets, journal.jsonTmp), JSON.stringify(next, null, 2) + '\n');
    if (existsSync(target)) renameSync(target, join(assets, journal.jsonBak));
    renameSync(join(assets, journal.jsonTmp), target);
    journal.state = 'committed'; saveJournal();
  } catch (e) {
    let note = '';
    try { recover(assets); } catch (r) { note = `;還原時另有錯誤(日誌保留,請跑 --recover 或人工檢查):${r.message}`; }
    throw new Fail(`交付失敗,已還原:${e.message}${note}`, 1);
  }
  // 已提交:清備份與日誌;失敗只警告
  const warnings = [];
  try { recover(assets); } catch (e) { warnings.push(`清理備份失敗(交付已完成,可稍後跑 --recover):${e.message}`); }
  if (unrelatedMissing.length) warnings.push(`assets.json 裡其他項目的檔案不存在(這次沒擋):${unrelatedMissing.join(', ')}`);
  return { ok: true, files, ...(warnings.length ? { warnings } : {}) };
}

const isMain = (() => { try { return !!process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } })();
if (isMain) {
  try {
    const a = process.argv.slice(2), flags = {}, files = [];
    for (let i = 0; i < a.length; i++) {
      if (a[i] === '--recover') flags.recover = true;
      else if (['--stage', '--assets', '--json'].includes(a[i])) { const k = a[i]; flags[k.slice(2)] = a[++i] ?? die(`${k} 缺值`); }
      else if (a[i].startsWith('--')) die(`不認得的參數 ${a[i]}`);
      else files.push(a[i]);
    }
    if (!flags.assets) die('缺 --assets');
    let r;
    if (flags.recover) r = recover(resolve(flags.assets));
    else {
      for (const k of ['stage', 'json']) if (!flags[k]) die(`缺 --${k}`);
      r = deliver({ stage: resolve(flags.stage), assets: resolve(flags.assets), json: resolve(flags.json), files });
    }
    console.log(JSON.stringify(r));
  } catch (e) {
    console.log(JSON.stringify({ ok: false, error: e.message }));
    process.exit(e instanceof Fail ? e.code : 1);
  }
}
