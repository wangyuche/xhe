#!/usr/bin/env node
// 用法:node check.mjs [--template <名稱或路徑>] [--template-dir <路徑>] [--out <輸出根目錄>]
// 檢查 node ≥ 22、Google Chrome、ffmpeg / ffprobe,解析模板(路徑 → <out>/_templates/<名稱> → kit 預設)並檢查 template.json 必填欄位、
// mascot 檔案、template.html / README.md / sample.storyboard.json;沒給模板時用 github-hot-pastel。
// stdout 一行 JSON:{ok, template:{dir,source,name,size,fps,scenes,mascot}, tools:{…}, problems:[…]};缺工具或模板不合格結束碼 3。
import { existsSync } from 'node:fs';
import { main, fail, parseArgs, resolveTemplate, loadTemplate, hasCmd, CHROME, Fail } from './_lib.mjs';

const USAGE = '用法:node check.mjs [--template <名稱或路徑>] [--template-dir <路徑>] [--out <輸出根目錄>]';
main(() => {
  const a = parseArgs(process.argv.slice(2), { '--template': 'v', '--template-dir': 'v', '--out': 'v' }, USAGE);
  if (a._.length) fail(USAGE, 2);
  const problems = [];
  const major = Number(process.versions.node.split('.')[0]);
  const tools = { node: process.version, chrome: existsSync(CHROME) ? CHROME : null, ffmpeg: hasCmd('ffmpeg'), ffprobe: hasCmd('ffprobe') };
  if (major < 22) problems.push(`node ≥ 22(目前 ${process.version}):brew install node`);
  if (!tools.chrome) problems.push(`找不到 Google Chrome(${CHROME}):安裝 Google Chrome 或設定 CHROME_PATH`);
  if (!tools.ffmpeg || !tools.ffprobe) problems.push('缺 ffmpeg / ffprobe:brew install ffmpeg');
  let template = null;
  try {
    const t = resolveTemplate({ name: a.template, dir: a['template-dir'], out: a.out });
    const { tpl, problems: tp } = loadTemplate(t.dir);
    problems.push(...tp.map(p => `模板:${p}`));
    template = { dir: t.dir, source: t.source, name: tpl?.name ?? null, size: tpl?.size ?? null, fps: tpl?.fps ?? null, scenes: tpl?.scenes ?? null, mascot: tpl?.mascot ? Object.keys(tpl.mascot) : null };
  } catch (e) {
    if (!(e instanceof Fail)) throw e;
    if (e.code === 2) throw e;
    problems.push(e.message);
  }
  const out = { ok: problems.length === 0, template, tools, problems };
  console.log(JSON.stringify(out));
  if (!out.ok) process.exit(3);
});
