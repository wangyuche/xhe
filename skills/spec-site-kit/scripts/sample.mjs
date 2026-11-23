#!/usr/bin/env node
// 用法:node sample.mjs <spec.json> [--round <n>](預設 1)
// 以「commit + 輪次」為種子(sha256),抽 5 條「已完成」與 3 條「未開始」(不足就全部);
// 第 n 輪排除前面各輪抽過的編號。結果可重現。stdout 一行 JSON;結束碼 0、用法錯誤 2、讀檔失敗 1。
import { createHash } from 'node:crypto';
import { readJson, isMain } from './lib.mjs';

const QUOTA = { '已完成': 5, '未開始': 3 };

function rank(seed, id) {
  return createHash('sha256').update(`${seed}\0${id}`).digest('hex');
}
function pickRound(spec, round, exclude) {
  const seed = `${spec.commit}:${round}`;
  const picks = [];
  for (const [status, n] of Object.entries(QUOTA)) {
    const pool = [];
    for (const m of spec.modules) for (const f of m.features) if (f.status === status && !exclude.has(f.id)) pool.push({ id: f.id, module: m.module.id, status, name: f.name, sources: f.sources, keywords: f.keywords });
    pool.sort((a, b) => rank(seed, a.id).localeCompare(rank(seed, b.id)));
    picks.push(...pool.slice(0, n));
  }
  return { seed, picks };
}
export function sample(spec, round) {
  const exclude = new Set();
  let r;
  for (let i = 1; i <= round; i++) {
    r = pickRound(spec, i, exclude);
    if (i < round) r.picks.forEach(p => exclude.add(p.id));
  }
  return { round, seed: r.seed, excluded: [...exclude], picks: r.picks };
}

if (isMain(import.meta.url)) {
  const a = process.argv.slice(2);
  const i = a.indexOf('--round');
  const round = i >= 0 ? Number(a[i + 1]) : 1;
  if (!a[0] || a[0].startsWith('--') || !Number.isInteger(round) || round < 1) { console.error('用法:sample.mjs <spec.json> [--round <n>]'); process.exit(2); }
  let spec;
  try { spec = readJson(a[0]); } catch (e) { console.log(JSON.stringify({ ok: false, errors: [e.message] })); process.exit(1); }
  console.log(JSON.stringify({ ok: true, ...sample(spec, round) }));
}
