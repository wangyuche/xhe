#!/usr/bin/env node
// 用法:node concurrency.mjs <url> <方法> <路徑> [-n 10] [--data <json>] [--cookie-jar <檔>] [--expect 200,201]
// 同時送 N 個相同請求(--data 中的 {uniq} 每個請求各換成不同唯一值),統計狀態碼。
// 全部狀態碼都在 --expect 內才通過(預設:只要不是 5xx 且沒有連線錯誤)。
// stdout 一行 JSON:{"n":10,"statuses":{"200":10},"errors":0,"ok":true};不通過結束碼 1。
import { readCookieJar, cookieHeader } from './cookiejar.mjs';

function usage(msg) {
  if (msg) console.error(`錯誤:${msg}`);
  console.error('用法:node concurrency.mjs <url> <方法> <路徑> [-n 10] [--data <json>] [--cookie-jar <檔>] [--expect 200,201]');
  process.exit(2);
}

const args = process.argv.slice(2);
if (args.length < 3) usage();
const [base, method, path] = args;
let n = 10; let data; let jar; let expect;
for (let i = 3; i < args.length; i++) {
  const a = args[i];
  if (a === '-n') n = Number(args[++i]);
  else if (a === '--data') data = args[++i] ?? usage('--data 缺值');
  else if (a === '--cookie-jar') jar = args[++i] ?? usage('--cookie-jar 缺值');
  else if (a === '--expect') expect = (args[++i] ?? usage('--expect 缺值')).split(',').map(Number);
  else usage(`未知參數:${a}`);
}
if (!Number.isInteger(n) || n < 2 || n > 100) usage('-n 必須是 2–100 的整數');

const headers = { Accept: 'application/json' };
if (jar) { const c = readCookieJar(jar); if (c.length) headers.Cookie = cookieHeader(c); }

let seq = 0;
const uniq = () => `${Date.now()}${process.pid}${++seq}${Math.floor(Math.random() * 1e6)}`;

const one = async () => {
  const h = { ...headers };
  let body;
  if (data !== undefined) { body = data.replaceAll('{uniq}', uniq()); h['Content-Type'] = 'application/json'; }
  try {
    const r = await fetch(new URL(path, base), { method, headers: h, body, redirect: 'manual' });
    const text = await r.text();
    return { status: r.status, sample: r.status >= 500 ? text.slice(0, 200) : undefined };
  } catch (e) {
    return { status: 0, sample: e.message };
  }
};

const results = await Promise.all(Array.from({ length: n }, one));
const statuses = {};
for (const r of results) statuses[r.status] = (statuses[r.status] ?? 0) + 1;
const errors = results.filter(r => r.status === 0).length;
const bad = results.filter(r => r.status === 0 || (expect ? !expect.includes(r.status) : r.status >= 500));
const ok = bad.length === 0;
const out = { n, statuses, errors, expect: expect ?? 'non-5xx', ok };
if (!ok) out.samples = [...new Set(bad.map(r => r.sample).filter(Boolean))].slice(0, 3);
console.log(JSON.stringify(out));
process.exit(ok ? 0 : 1);
