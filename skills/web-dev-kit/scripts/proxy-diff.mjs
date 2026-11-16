#!/usr/bin/env node
// 用法:node proxy-diff.mjs <前端url> <後端url> <方法> <路徑> [--data <json>] [--cookie-jar <檔>] [--ignore <欄位路徑>]... [--structure]
// 同一請求打「前端轉發」與「後端直連」,比對狀態碼與 body。
// --data 中的 {uniq} 兩邊各換成不同的唯一值;--structure 只比對狀態碼與 JSON 結構(非冪等端點用)。
// --ignore 欄位路徑:a.b、items[].id。stdout 一行 JSON;不一致時結束碼 1。
import { readCookieJar, cookieHeader } from './cookiejar.mjs';

function usage(msg) {
  if (msg) console.error(`錯誤:${msg}`);
  console.error('用法:node proxy-diff.mjs <前端url> <後端url> <方法> <路徑> [--data <json>] [--cookie-jar <檔>] [--ignore <欄位>]... [--structure]');
  process.exit(2);
}

const args = process.argv.slice(2);
if (args.length < 4) usage();
const [front, back, method, path] = args;
let data; let jar; const ignore = []; let structure = false;
for (let i = 4; i < args.length; i++) {
  const a = args[i];
  if (a === '--data') data = args[++i] ?? usage('--data 缺值');
  else if (a === '--cookie-jar') jar = args[++i] ?? usage('--cookie-jar 缺值');
  else if (a === '--ignore') ignore.push(args[++i] ?? usage('--ignore 缺值'));
  else if (a === '--structure') structure = true;
  else usage(`未知參數:${a}`);
}

const uniq = () => `${Date.now()}${Math.floor(Math.random() * 1e6)}`;
const headers = { Accept: 'application/json' };
if (jar) { const c = readCookieJar(jar); if (c.length) headers.Cookie = cookieHeader(c); }

async function call(base) {
  const h = { ...headers };
  let body;
  if (data !== undefined) { body = data.replaceAll('{uniq}', uniq()); h['Content-Type'] = 'application/json'; }
  const r = await fetch(new URL(path, base), { method, headers: h, body, redirect: 'manual' });
  const text = await r.text();
  let json; try { json = JSON.parse(text); } catch {}
  return { status: r.status, text, json };
}

function strip(obj, segs) {
  if (obj === null || typeof obj !== 'object' || segs.length === 0) return;
  const [s, ...rest] = segs;
  if (s.endsWith('[]')) {
    const arr = obj[s.slice(0, -2)];
    if (Array.isArray(arr)) arr.forEach(el => rest.length ? strip(el, rest) : null);
    if (rest.length === 0) delete obj[s.slice(0, -2)];
  } else if (rest.length === 0) delete obj[s];
  else strip(obj[s], rest);
}
function applyIgnore(v) {
  if (v === undefined) return v;
  const c = structuredClone(v);
  for (const p of ignore) {
    if (Array.isArray(c) && p.startsWith('[].')) c.forEach(el => strip(el, p.slice(3).split('.')));
    else strip(c, p.split('.'));
  }
  return c;
}
function shape(v) {
  if (v === null) return 'null';
  if (Array.isArray(v)) return v.length ? [shape(v[0])] : [];
  if (typeof v === 'object') return Object.fromEntries(Object.keys(v).sort().map(k => [k, shape(v[k])]));
  return typeof v;
}
function diffs(a, b, p = '$', out = []) {
  if (JSON.stringify(a) === JSON.stringify(b)) return out;
  if (a && b && typeof a === 'object' && typeof b === 'object' && !Array.isArray(a) && !Array.isArray(b)) {
    for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) diffs(a[k], b[k], `${p}.${k}`, out);
  } else out.push({ path: p, front: a, back: b });
  return out;
}

let f, b;
try { [f, b] = await Promise.all([call(front), call(back)]); }
catch (e) { console.log(JSON.stringify({ front: null, back: null, same: false, mode: structure ? 'structure' : 'body', diff: [], error: e.message })); process.exit(1); }

let d = [];
if (f.status !== b.status) d.push({ path: 'status', front: f.status, back: b.status });
if (f.json !== undefined && b.json !== undefined) {
  const fa = applyIgnore(f.json), ba = applyIgnore(b.json);
  d = d.concat(structure ? diffs(shape(fa), shape(ba)) : diffs(fa, ba));
} else if (!structure && f.text !== b.text) d.push({ path: 'body', front: f.text.slice(0, 200), back: b.text.slice(0, 200) });
else if (structure && (f.json === undefined) !== (b.json === undefined)) d.push({ path: 'body', front: f.json === undefined ? 'non-json' : 'json', back: b.json === undefined ? 'non-json' : 'json' });

const same = d.length === 0;
console.log(JSON.stringify({ front: f.status, back: b.status, same, mode: structure ? 'structure' : 'body', ignored: ignore, diff: d }));
process.exit(same ? 0 : 1);
