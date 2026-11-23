#!/usr/bin/env node
// 用法:node merge.mjs <輸出目錄>
// 讀 <輸出目錄>/parts/_project.json 與 parts/*.json,合成 <輸出目錄>/spec.json(含 branch、dirty、generated_at、stats)。
// 任何 part 的 commit 不等於 HEAD、schema 不合、模組 id 重複 → 不寫檔,結束碼 1 並列出要重做的模組。
// stdout 一行 JSON;結束碼 0 成功、1 失敗、2 用法錯誤。合併後要再跑 check.mjs。
import { readdirSync, writeFileSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { KIT, validateSchema, readJson, git, gitRoot, head, relInside, isMain } from './lib.mjs';
import { countStats } from './check.mjs';

export function merge(outArg) {
  const out = resolve(outArg);
  const root = gitRoot(out);
  if (!root) return { errors: [`${out} 不在 git 工作目錄內`] };
  const outRel = relInside(root, out);
  if (!outRel) return { errors: [`${out} 不在專案根內`] };
  const partsDir = join(out, 'parts');
  if (!existsSync(join(partsDir, '_project.json'))) return { errors: ['缺 parts/_project.json'] };
  const H = head(root);
  const errors = []; const stale = [];
  let project;
  try { project = readJson(join(partsDir, '_project.json')); } catch (e) { return { errors: [`_project.json:${e.message}`] }; }
  errors.push(...validateSchema('project', project).map(e => `_project.json ${e}`));
  if (project.commit && project.commit !== H) stale.push('_project');
  const files = readdirSync(partsDir).filter(f => f.endsWith('.json') && f !== '_project.json').sort();
  if (!files.length) errors.push('parts/ 裡沒有任何模組');
  const modules = []; const ids = new Set();
  for (const f of files) {
    let p;
    try { p = readJson(join(partsDir, f)); } catch (e) { errors.push(`${f}:${e.message}`); continue; }
    const se = validateSchema('part', p);
    if (se.length) { errors.push(...se.map(e => `${f} ${e}`)); continue; }
    if (p.commit !== H) stale.push(p.module.id);
    if (ids.has(p.module.id)) errors.push(`模組 id 重複:${p.module.id}(${f})`);
    ids.add(p.module.id);
    modules.push(p);
  }
  if (stale.length) errors.push(`這些 part 的 commit 不等於 HEAD ${H.slice(0, 7)},要重做:${stale.join('、')}`);
  if (errors.length) return { errors, stale };
  const branch = git(root, ['rev-parse', '--abbrev-ref', 'HEAD']).trim();
  const dirty = git(root, ['status', '--porcelain', '--', '.', `:(exclude)${outRel}`]).trim() !== '';
  const spec = {
    kit: KIT, commit: H, branch, dirty,
    generated_at: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    project, modules, stats: countStats(modules),
  };
  writeFileSync(join(out, 'spec.json'), JSON.stringify(spec, null, 2) + '\n');
  return { errors: [], spec: join(outRel, 'spec.json'), modules: modules.length, stats: spec.stats, dirty };
}

if (isMain(import.meta.url)) {
  const [o] = process.argv.slice(2);
  if (!o) { console.error('用法:merge.mjs <輸出目錄>'); process.exit(2); }
  let r;
  try { r = merge(o); } catch (e) { r = { errors: [e.message] }; }
  console.log(JSON.stringify({ ok: r.errors.length === 0, ...r }));
  process.exit(r.errors.length ? 1 : 0);
}
