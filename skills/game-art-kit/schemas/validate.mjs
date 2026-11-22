#!/usr/bin/env node
// 無依賴的最小 JSON Schema 驗證器(只支援本目錄兩份 schema 用到的關鍵字),外加素材介面的語意檢查。
// 用法:node validate.mjs needs|assets <檔案.json> [--root <art/assets 目錄>]
//   結束碼 0 通過;1 不通過(stdout 印 {"ok":false,"errors":[…]});2 用法錯誤。
// 也可 import:import { validate } from './validate.mjs';validate('needs', obj, { root }) → 錯誤字串陣列。
// 支援的關鍵字:type、const、enum、pattern、minLength、minimum、maximum、exclusiveMinimum、minItems、maxItems、items、
//   properties、required、additionalProperties:false、$ref(#/$defs/…)、allOf、if / then / else;
//   自訂:forbidden(列出的鍵不得出現)、uniqueBy(陣列元素該欄位不得重複)。
import { readFileSync, existsSync, statSync, realpathSync } from 'node:fs';
import { dirname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const KNOWN = new Set(['$comment', 'type', 'const', 'enum', 'pattern', 'minLength', 'minimum', 'maximum', 'exclusiveMinimum', 'minItems', 'maxItems',
  'items', 'properties', 'required', 'additionalProperties', '$ref', 'allOf', 'if', 'then', 'else', 'forbidden', 'uniqueBy', '$defs']);

const typeOk = (t, v) => t === 'object' ? v !== null && typeof v === 'object' && !Array.isArray(v)
  : t === 'array' ? Array.isArray(v) : t === 'integer' ? Number.isInteger(v) : t === 'number' ? typeof v === 'number' && Number.isFinite(v)
  : typeof v === t;

function check(schema, v, path, root, errs) {
  for (const k of Object.keys(schema)) if (!KNOWN.has(k)) throw new Error(`schema 用了不支援的關鍵字 ${k}(${path})`);
  if (schema.$ref) {
    const m = /^#\/\$defs\/(.+)$/.exec(schema.$ref);
    if (!m || !root.$defs?.[m[1]]) throw new Error(`無法解析 $ref ${schema.$ref}`);
    check(root.$defs[m[1]], v, path, root, errs);
  }
  const err = (msg) => errs.push(`${path || '(根)'}: ${msg}`);
  if (schema.type && !typeOk(schema.type, v)) return err(`應為 ${schema.type}`);
  if ('const' in schema && v !== schema.const) err(`應為 ${JSON.stringify(schema.const)}`);
  if (schema.enum && !schema.enum.includes(v)) err(`應為 ${schema.enum.map(x => JSON.stringify(x)).join(' / ')} 之一`);
  if (typeof v === 'string') {
    if (schema.pattern && !new RegExp(schema.pattern).test(v)) err(`不符合 ${schema.pattern}`);
    if (schema.minLength != null && v.length < schema.minLength) err(`長度至少 ${schema.minLength}`);
  }
  if (typeof v === 'number') {
    if (schema.minimum != null && v < schema.minimum) err(`應 ≥ ${schema.minimum}`);
    if (schema.maximum != null && v > schema.maximum) err(`應 ≤ ${schema.maximum}`);
    if (schema.exclusiveMinimum != null && v <= schema.exclusiveMinimum) err(`應 > ${schema.exclusiveMinimum}`);
  }
  if (Array.isArray(v)) {
    if (schema.minItems != null && v.length < schema.minItems) err(`至少 ${schema.minItems} 項`);
    if (schema.maxItems != null && v.length > schema.maxItems) err(`最多 ${schema.maxItems} 項`);
    if (schema.items) v.forEach((x, i) => check(schema.items, x, `${path}[${i}]`, root, errs));
    if (schema.uniqueBy) {
      const seen = new Set();
      for (const x of v) { const key = x?.[schema.uniqueBy]; if (seen.has(key)) err(`${schema.uniqueBy} 重複:${key}`); seen.add(key); }
    }
  }
  if (typeOk('object', v)) {
    for (const r of schema.required ?? []) if (!(r in v)) err(`缺少 ${r}`);
    for (const f of schema.forbidden ?? []) if (f in v) err(`不可有 ${f}`);
    for (const [k, s] of Object.entries(schema.properties ?? {})) if (k in v) check(s, v[k], path ? `${path}.${k}` : k, root, errs);
    if (schema.additionalProperties === false) for (const k of Object.keys(v)) if (!(k in (schema.properties ?? {}))) err(`未知欄位 ${k}`);
  }
  for (const s of schema.allOf ?? []) check(s, v, path, root, errs);
  if (schema.if) {
    const sub = []; check(schema.if, v, path, root, sub);
    if (sub.length === 0) { if (schema.then) check(schema.then, v, path, root, errs); }
    else if (schema.else) check(schema.else, v, path, root, errs);
  }
}

const IMAGE = new Set(['sprite', 'frames', 'tile', 'background', 'ui']);

// 語意檢查(schema 表達不了的)
function semantic(kind, obj, root, errs) {
  const list = kind === 'needs' ? obj.needs : obj.assets;
  if (!Array.isArray(list)) return;
  list.forEach((a, i) => {
    const p = `${kind}[${i}](${a?.id})`;
    if (!a || typeof a !== 'object') return;
    if (a.nineSlice && a.width && a.height) {
      const [t, r, b, l] = a.nineSlice;
      if (t + b >= a.height || l + r >= a.width) errs.push(`${p}: nineSlice 切線超出尺寸`);
    }
    if (kind !== 'assets') return;
    const files = a.files ?? [];
    if (IMAGE.has(a.type)) {
      if (files.length !== 1 || !files[0].endsWith('.png')) errs.push(`${p}: 圖類素材應恰好一個 .png`);
    } else if (['sfx', 'bgm'].includes(a.type)) {
      const exts = files.map(f => f.split('.').pop()).sort().join(',');
      if (exts !== 'm4a,ogg') errs.push(`${p}: 音訊應恰好有 .ogg 與 .m4a 各一`);
    }
    for (const f of files) if (!f.startsWith(`${a.group}/`)) errs.push(`${p}: 檔案 ${f} 應放在 ${a.group}/ 下`);
    if (a.frames) {
      const { count, columns, frameWidth, frameHeight } = a.frames;
      if (columns > count) errs.push(`${p}: frames.columns 不可大於 count`);
      if (frameWidth * columns > 2048) errs.push(`${p}: sheet 寬 ${frameWidth * columns} 超過 2048,應換行(減少 columns)`);
      if (frameHeight * Math.ceil(count / columns) > 2048) errs.push(`${p}: sheet 高超過 2048`);
    }
    if (a.nineSlice && a.nineSlice1x && a.density) {
      const want = a.nineSlice.map(x => Math.round(x * a.density));
      if (want.join() !== a.nineSlice1x.join()) errs.push(`${p}: nineSlice1x 應為 ${JSON.stringify(want)}(nineSlice × density 四捨五入)`);
    }
    if (root) for (const f of files) {
      const abs = resolve(root, f);
      if (!abs.startsWith(resolve(root) + sep)) errs.push(`${p}: 檔案路徑 ${f} 跑出 root`);
      else if (!existsSync(abs) || !statSync(abs).isFile()) errs.push(`${p}: 檔案不存在 ${f}`);
    }
  });
}

export function validate(kind, obj, { root } = {}) {
  if (!['needs', 'assets'].includes(kind)) throw new Error(`kind 應為 needs 或 assets`);
  const schema = JSON.parse(readFileSync(join(HERE, `${kind}.schema.json`), 'utf8'));
  const errs = [];
  check(schema, obj, '', schema, errs);
  semantic(kind, obj, root, errs);
  return errs;
}

// skill 目錄常是連結:比 realpath
const isMain = (() => { try { return !!process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } })();
if (isMain) {
  const [kind, file, ...rest] = process.argv.slice(2);
  const ri = rest.indexOf('--root'); const root = ri >= 0 ? rest[ri + 1] : undefined;
  if (!['needs', 'assets'].includes(kind) || !file || (ri >= 0 && !root)) {
    console.error('用法:node validate.mjs needs|assets <檔案.json> [--root <art/assets 目錄>]'); process.exit(2);
  }
  let obj;
  try { obj = JSON.parse(readFileSync(file, 'utf8')); } catch (e) { console.log(JSON.stringify({ ok: false, errors: [`讀不到或不是 JSON:${e.message}`] })); process.exit(1); }
  const errors = validate(kind, obj, { root });
  console.log(JSON.stringify({ ok: errors.length === 0, errors }));
  process.exit(errors.length ? 1 : 0);
}
