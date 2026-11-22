#!/usr/bin/env node
// 讓「不是伺服器的長時間指令」(例如 soak 量測)也能經 web-dev-kit serve.sh 在背景執行、由 stop.sh 整組停掉:
//   bash <kit>/scripts/serve.sh <name>-soak <專案> 4190 -- node <skill>/scripts/bg-job.mjs -- <指令...>
// - 在 127.0.0.1:$PORT(serve.sh 給的埠)回應 GET /:{"state":"running"|"done","code":<結束碼|null>,"signal":…,"startedAt","endedAt"}。
// - 子指令的 stdout / stderr 寫到自己的輸出(= serve.sh 的 server.log);子指令的環境變數不含 PORT(避免和要量測的伺服器埠混淆)。
// - 子指令結束後仍保持回應,直到 stop.sh;輪詢:curl -s http://127.0.0.1:<port>/
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';

const USAGE = '用法:node bg-job.mjs -- <指令...>(由 serve.sh 啟動,PORT 由 serve.sh 提供)';
const i = process.argv.indexOf('--');
const cmd = i >= 0 ? process.argv.slice(i + 1) : [];
const port = Number(process.env.PORT);
if (!cmd.length || !Number.isInteger(port) || port <= 0) { console.error(USAGE); process.exit(2); }

const status = { state: 'running', code: null, signal: null, startedAt: new Date().toISOString(), endedAt: null, cmd };
let child;
const server = createServer((req, res) => {
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify(status));
});
// 埠拿不到就整個失敗,子指令還沒啟動
server.on('error', (e) => { console.error(`bg-job: 無法監聽 ${port}:${e.message}`); if (child && status.state === 'running') child.kill('SIGTERM'); process.exit(1); });
server.listen(port, '127.0.0.1', () => {
  const env = { ...process.env };
  delete env.PORT;
  child = spawn(cmd[0], cmd.slice(1), { env, stdio: ['ignore', 'inherit', 'inherit'] });
  child.on('error', (e) => { console.error(`bg-job: 無法執行 ${cmd[0]}:${e.message}`); Object.assign(status, { state: 'done', code: 127, endedAt: new Date().toISOString() }); });
  child.on('exit', (code, signal) => { Object.assign(status, { state: 'done', code, signal, endedAt: new Date().toISOString() }); console.log(`bg-job: done code=${code} signal=${signal}`); });
});

const stop = () => { if (child && status.state === 'running') child.kill('SIGTERM'); process.exit(0); };
process.on('SIGTERM', stop);
process.on('SIGINT', stop);
