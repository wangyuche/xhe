// 共用:啟動本機 Google Chrome headless 並用 CDP 控制(只用 Node 內建 fetch / WebSocket)。
// 每次使用自己的設定檔目錄(放在 SHORT_VIDEO_KIT_TMP 底下),await close() 時刪除。
// Chrome 會開子程序(網路服務等),只殺主程序時子程序會在資料夾刪掉後再寫回檔案(實測留下 Default/Reporting and NEL-journal),
// 所以關閉時連同所有子孫程序一起殺(pgrep -P 逐層找)、等主程序結束後再刪,最後重試刪除。
// Chrome 留在 node 的程序群組裡:外層對整個群組送 SIGKILL(例如 Bash 工具逾時)時會一起被殺。
// 收到 SIGINT / SIGTERM / SIGHUP 時收掉還開著的 Chrome 再結束(模組層級只註冊一次,關閉的實例會移出名單)。
import { spawn, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export const CHROME = process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
export const KIT_TMP = (process.env.SHORT_VIDEO_KIT_TMP || join(process.env.TMPDIR || tmpdir(), 'short-video-kit')).replace(/\/$/, '');

// 主程序與所有子孫程序的 PID(子孫先找,避免主程序先死後子程序被過繼找不到)
function processTree(pid) {
  const out = []; const queue = [pid];
  while (queue.length) {
    const p = queue.shift();
    const r = spawnSync('pgrep', ['-P', String(p)], { encoding: 'utf8' });
    for (const c of (r.stdout || '').split('\n').map(Number).filter(Boolean)) { out.push(c); queue.push(c); }
  }
  return [pid, ...out];
}
const live = new Set(); // 還開著的 { chrome, profile }
function killNow(x) {
  if (x.chrome.exitCode === null && x.chrome.signalCode === null) {
    for (const p of processTree(x.chrome.pid).reverse()) { try { process.kill(p, 'SIGKILL'); } catch {} }
  }
}
let signalsHooked = false;
function hookSignals() {
  if (signalsHooked) return; signalsHooked = true;
  for (const sg of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sg, () => {
    for (const x of live) { killNow(x); try { rmSync(x.profile, { recursive: true, force: true }); } catch {} }
    process.exit({ SIGINT: 130, SIGHUP: 129 }[sg] ?? 143);
  });
}

export async function launchChrome() {
  if (!existsSync(CHROME)) throw new Error(`找不到 Google Chrome:${CHROME}`);
  mkdirSync(KIT_TMP, { recursive: true });
  const profile = mkdtempSync(join(KIT_TMP, 'chrome-'));
  const chrome = spawn(CHROME, [
    '--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`,
    '--no-first-run', '--no-default-browser-check', '--disable-extensions',
    '--hide-scrollbars', '--mute-audio', '--disable-background-networking',
    '--disable-component-update', '--disable-sync', '--metrics-recording-only',
    '--font-render-hinting=none', 'about:blank',
  ], { stdio: 'ignore' });
  const inst = { chrome, profile };
  live.add(inst); hookSignals();

  let ws;
  const exited = new Promise(r => { if (chrome.exitCode !== null || chrome.signalCode !== null) r(); else chrome.once('exit', r); });
  let closing = null;
  const close = () => closing ??= (async () => {
    try { ws?.close(); } catch {}
    killNow(inst);
    await Promise.race([exited, new Promise(r => setTimeout(r, 3000))]);
    for (let i = 0; i < 3; i++) {
      try { rmSync(profile, { recursive: true, force: true }); } catch {}
      await new Promise(r => setTimeout(r, 200));
      if (!existsSync(profile)) break;
    }
    live.delete(inst);
  })();
  try {
    const portFile = join(profile, 'DevToolsActivePort');
    let port;
    for (let i = 0; i < 150 && !port; i++) {
      if (existsSync(portFile)) port = readFileSync(portFile, 'utf8').split('\n')[0].trim();
      if (!port) await new Promise(r => setTimeout(r, 100));
    }
    if (!port) throw new Error('Chrome 沒有開出 DevTools 埠');
    const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
    ws = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error('CDP WebSocket 連線失敗')); });
  } catch (e) { await close(); throw e; }

  let id = 0; const pending = new Map(); const listeners = [];
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) {
      const { res, rej } = pending.get(msg.id); pending.delete(msg.id);
      msg.error ? rej(new Error(`${msg.error.message}`)) : res(msg.result);
    } else if (msg.method) for (const l of listeners) l(msg);
  };
  const send = (method, params = {}) => new Promise((res, rej) => {
    const i = ++id; pending.set(i, { res, rej }); ws.send(JSON.stringify({ id: i, method, params }));
  });
  const on = (fn) => listeners.push(fn);
  return { send, on, close };
}

// 攔截所有網路請求:allow(url) 為 true 才放行,其餘一律擋掉並計數。
export async function guardNetwork(cdp, allow) {
  const stats = { blocked: [], allowed: 0 };
  cdp.on((m) => {
    if (m.method !== 'Fetch.requestPaused') return;
    const { requestId, request } = m.params;
    if (allow(request.url)) { stats.allowed++; cdp.send('Fetch.continueRequest', { requestId }).catch(() => {}); }
    else { stats.blocked.push(request.url.slice(0, 200)); cdp.send('Fetch.failRequest', { requestId, errorReason: 'BlockedByClient' }).catch(() => {}); }
  });
  await cdp.send('Fetch.enable', { patterns: [{ urlPattern: '*' }] });
  return stats;
}
