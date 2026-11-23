#!/usr/bin/env node
// 用法:node shot.mjs <url> <寬> <高> <輸出.png> [--mobile] [--viewport] [--anchor <id>] [--allow-redirect] [--cookie name=value]... [--cookie-jar <檔>] [--header 'K: V']...
// 只用 Node 22 內建 fetch / WebSocket,透過 CDP 控制本機 Google Chrome headless,截整頁。
// stdout 一行 JSON;HTTP 不是 200、consoleErrors > 0,或被轉址到別的網址(finalUrl ≠ url,例如沒登入被導到 /login;
// 伺服器 3xx 與頁面 JS 轉址都算)時結束碼 2(仍產生截圖)。預期會轉址時加 --allow-redirect。
// --viewport:只截目前畫面(網址可帶 #錨點捲到該段),長頁面用這個才看得清楚。
// 整頁截圖的像素高度超過 16384(Chrome 單張上限,超過會重複拼接)時 warnings 會提醒改用 --viewport(不影響結束碼)。
// 第一個參數也可以是本機絕對路徑(/ 開頭),內部用 pathToFileURL 轉成 file:// 網址(路徑含 # ? % 也正確);--anchor <id> 加上 #id。
// file:// 網址:不做 HTTP 檢查,檔案存在時 http 記 200、不存在記 0(結束碼 2);不支援 --cookie / --header。
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, existsSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { readCookieJar, cookieHeader } from './cookiejar.mjs';

const CHROME = process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

function usage(msg) {
  if (msg) console.error(`錯誤:${msg}`);
  console.error("用法:node shot.mjs <url|絕對路徑> <寬> <高> <輸出.png> [--mobile] [--viewport] [--anchor <id>] [--allow-redirect] [--cookie name=value]... [--cookie-jar <檔>] [--header 'K: V']...");
  process.exit(1);
}

const args = process.argv.slice(2);
if (args.length < 4) usage();
let [url, wStr, hStr, outArg] = args;
if (url.startsWith('/')) url = pathToFileURL(url).href;
const width = Number(wStr), height = Number(hStr);
if (!Number.isInteger(width) || !Number.isInteger(height)) usage('寬高必須是整數');
const out = resolve(outArg);
let mobile = false; let allowRedirect = false; let viewportOnly = false; let anchor = null; const cookies = []; const headers = {};
for (let i = 4; i < args.length; i++) {
  const a = args[i];
  if (a === '--mobile') mobile = true;
  else if (a === '--allow-redirect') allowRedirect = true;
  else if (a === '--viewport') viewportOnly = true;
  else if (a === '--anchor') anchor = args[++i] ?? usage('--anchor 缺值');
  else if (a === '--cookie') {
    const v = args[++i] ?? usage('--cookie 缺值');
    const eq = v.indexOf('=');
    if (eq < 1) usage(`--cookie 需要 name=value:${v}`);
    cookies.push({ name: v.slice(0, eq), value: v.slice(eq + 1) });
  } else if (a === '--cookie-jar') {
    const p = args[++i] ?? usage('--cookie-jar 缺值');
    for (const c of readCookieJar(p)) cookies.push({ name: c.name, value: c.value });
  } else if (a === '--header') {
    const v = args[++i] ?? usage('--header 缺值');
    const c = v.indexOf(':');
    if (c < 1) usage(`--header 需要 'K: V':${v}`);
    headers[v.slice(0, c).trim()] = v.slice(c + 1).trim();
  } else usage(`未知參數:${a}`);
}
if (anchor) { const u0 = new URL(url); u0.hash = anchor; url = u0.href; }
const isFile = /^file:/i.test(url);
if (isFile && (cookies.length || Object.keys(headers).length)) usage('file:// 不支援 --cookie / --cookie-jar / --header');
if (!existsSync(CHROME)) { console.error(`錯誤:找不到 Google Chrome:${CHROME}`); process.exit(1); }

const result = { http: 0, finalUrl: null, redirected: false, width, height, scrollWidth: null, innerWidth: null, pageHeight: null, consoleErrors: 0, errors: [], warnings: [], out };
const reqHeaders = { ...headers };
if (cookies.length) reqHeaders.Cookie = cookieHeader(cookies);

// 1. 先確認 HTTP 狀態(跟著轉址走,http 是最後一站的狀態;有轉址時 redirected = true)
let fetchFinal = null;
// 轉址判定:Chrome 最後停在的網址(含 JS 轉址)或 fetch 的最後一站,和請求網址不同(忽略 #hash)。逾時時也要做
function checkRedirect() {
  const norm = (x) => { try { const v = new URL(x); v.hash = ''; return v.href; } catch { return x; } };
  result.finalUrl ??= fetchFinal;
  for (const f of [fetchFinal, result.finalUrl]) {
    if (f && norm(f) !== norm(url)) result.redirected = true;
  }
  if (result.redirected && !allowRedirect) result.errors.push(`redirect: ${url} → ${result.finalUrl}(預期轉址時加 --allow-redirect)`);
}
if (isFile) {
  let p = null;
  try { p = fileURLToPath(url); } catch (e) { result.errors.push(`fetch: file:// 網址無效:${e.message}`); }
  if (p !== null) {
    if (existsSync(p) && statSync(p).isFile()) { result.http = 200; fetchFinal = url; }
    else result.errors.push(existsSync(p) ? `fetch: 不是檔案(目錄?):${p}` : `fetch: 檔案不存在:${p}`);
  }
} else {
  try {
    const r = await fetch(url, { headers: reqHeaders, redirect: 'follow' });
    result.http = r.status;
    fetchFinal = r.url || url;
  } catch (e) {
    result.errors.push(`fetch: ${e.message}`);
  }
}

const profile = mkdtempSync(join(tmpdir(), 'web-dev-kit-chrome-'));
let chrome; let ws;
const cleanup = () => {
  try { ws?.close(); } catch {}
  try { chrome?.kill('SIGKILL'); } catch {}
  try { rmSync(profile, { recursive: true, force: true }); } catch {}
};
const hardTimeout = setTimeout(() => {
  result.errors.push('timeout: 60 秒內未完成');
  cleanup(); checkRedirect(); console.log(JSON.stringify(result)); process.exit(2);
}, 60000);

try {
  chrome = spawn(CHROME, [
    '--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`,
    '--no-first-run', '--no-default-browser-check', '--disable-extensions',
    '--hide-scrollbars', '--mute-audio', 'about:blank',
  ], { stdio: 'ignore' });

  // 2. 從 DevToolsActivePort 取得 CDP 埠
  const portFile = join(profile, 'DevToolsActivePort');
  let port;
  for (let i = 0; i < 100 && !port; i++) {
    if (existsSync(portFile)) port = readFileSync(portFile, 'utf8').split('\n')[0].trim();
    if (!port) await new Promise(r => setTimeout(r, 100));
  }
  if (!port) throw new Error('Chrome 沒有開出 DevTools 埠');

  const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
  ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error('CDP WebSocket 連線失敗')); });

  let id = 0; const pending = new Map(); const listeners = [];
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) {
      const { res, rej } = pending.get(msg.id); pending.delete(msg.id);
      msg.error ? rej(new Error(msg.error.message)) : res(msg.result);
    } else if (msg.method) listeners.forEach(l => l(msg));
  };
  const send = (method, params = {}) => new Promise((res, rej) => {
    const i = ++id; pending.set(i, { res, rej }); ws.send(JSON.stringify({ id: i, method, params }));
  });

  // 3. 收集錯誤與網路狀態
  let inflight = 0; let lastNet = Date.now(); let loaded = false;
  listeners.push((m) => {
    switch (m.method) {
      case 'Runtime.consoleAPICalled':
        if (m.params.type === 'error') result.errors.push(`console: ${m.params.args.map(a => a.value ?? a.description ?? '').join(' ')}`);
        break;
      case 'Runtime.exceptionThrown':
        result.errors.push(`exception: ${m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text}`);
        break;
      case 'Log.entryAdded':
        // 瀏覽器自動請求的 /favicon.ico 404 不是頁面的錯誤
        if (m.params.entry.level === 'error' && !/\/favicon\.ico(\?|$)/.test(m.params.entry.url ?? '')) result.errors.push(`log: ${m.params.entry.text} ${m.params.entry.url ?? ''}`.trim());
        break;
      case 'Network.requestWillBeSent': inflight++; lastNet = Date.now(); break;
      case 'Network.loadingFinished': case 'Network.loadingFailed':
        inflight = Math.max(0, inflight - 1); lastNet = Date.now(); break;
      case 'Page.loadEventFired': loaded = true; break;
    }
  });
  await send('Page.enable'); await send('Runtime.enable'); await send('Network.enable'); await send('Log.enable');

  const u = new URL(url);
  if (!isFile) for (const c of cookies) await send('Network.setCookie', { name: c.name, value: c.value, domain: u.hostname, path: '/' });
  if (Object.keys(headers).length) await send('Network.setExtraHTTPHeaders', { headers });

  await send('Emulation.setDeviceMetricsOverride', mobile
    ? { width, height, deviceScaleFactor: 3, mobile: true }
    : { width, height, deviceScaleFactor: 1, mobile: false });
  if (mobile) await send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });

  // 4. 導覽,等 load + 網路閒置 500 ms(上限 15 秒)
  await send('Page.navigate', { url });
  const start = Date.now();
  while (Date.now() - start < 15000) {
    if (loaded && inflight === 0 && Date.now() - lastNet >= 500) break;
    await new Promise(r => setTimeout(r, 100));
  }
  if (!loaded) result.errors.push('load: 15 秒內沒有觸發 load 事件');

  // 5. 先量,再截整頁
  const m = await send('Runtime.evaluate', {
    // innerWidth 用版面寬度 clientWidth:手機模擬時內容過寬,瀏覽器會縮小畫面讓 window.innerWidth 變大
    expression: 'JSON.stringify({sw: document.documentElement.scrollWidth, iw: document.documentElement.clientWidth, ph: document.documentElement.scrollHeight, href: location.href})',
    returnByValue: true,
  });
  const meas = JSON.parse(m.result.value);
  result.scrollWidth = meas.sw; result.innerWidth = meas.iw; result.pageHeight = meas.ph;
  // 載入失敗時 Chrome 停在 chrome-error://(不是轉址):記為導覽錯誤,finalUrl 改用 fetch 的結果
  if (/^https?:/.test(meas.href) || (isFile && /^file:/.test(meas.href))) result.finalUrl = meas.href;
  else result.errors.push(`navigate: Chrome 沒有載入頁面(停在 ${meas.href})`);

  let shot;
  if (viewportOnly) {
    shot = await send('Page.captureScreenshot', { format: 'png' });
  } else {
    const metrics = await send('Page.getLayoutMetrics');
    const cs = metrics.cssContentSize || metrics.contentSize;
    const dpr = mobile ? 3 : 1;
    const px = Math.ceil(cs.height) * dpr, pw = Math.max(width, Math.ceil(cs.width)) * dpr;
    if (px > 16384) result.warnings.push(`整頁截圖高 ${px} 像素超過 Chrome 單張上限 16384,圖可能重複拼接;改用 --viewport(可加 #錨點)看各段`);
    if (pw > 16384) result.warnings.push(`整頁截圖寬 ${pw} 像素超過 Chrome 單張上限 16384,圖可能重複拼接;改用 --viewport`);
    shot = await send('Page.captureScreenshot', {
      format: 'png', captureBeyondViewport: true,
      clip: { x: 0, y: 0, width: Math.max(width, Math.ceil(cs.width)), height: Math.ceil(cs.height), scale: 1 },
    });
  }
  writeFileSync(out, Buffer.from(shot.data, 'base64'));
} catch (e) {
  result.errors.push(`shot: ${e.message}`);
} finally {
  clearTimeout(hardTimeout);
  cleanup();
}

checkRedirect();

result.consoleErrors = result.errors.filter(e => /^(console|exception|log):/.test(e)).length;
console.log(JSON.stringify(result));
const failed = result.http !== 200 || result.consoleErrors > 0 || result.errors.some(e => /^(shot|fetch|timeout|redirect|navigate):/.test(e));
process.exit(failed ? 2 : 0);
