#!/usr/bin/env node
// 用法:node record-web.mjs <網址> <動作.json> <輸出.mp4>
// 用 Chrome headless(手機 540×960 @2x)錄網頁操作,輸出 1080×1920、30 fps、無聲 MP4。
// 只允許 http://localhost / 127.0.0.1;頁面對其他網域的請求一律擋掉(計數回報)。
// 動作.json:[{"do":"goto","url":"/"},{"do":"wait","ms":1500},{"do":"scroll","y":800,"ms":1200},
//            {"do":"click","selector":"button.buy"},{"do":"type","selector":"#q","text":"hello","delayMs":80}]
//   goto 的 url 可省略主機(相對於 <網址>);每個動作後自動多停 300 ms。
// stdout 一行 JSON:{"out":…,"duration":…,"frames":N,"marks":[{i,do,t}],"blockedRequests":[…],"errors":[…]};失敗結束碼 1。
//   marks:每個動作開始的時間(秒,相對成品開頭;第一個 goto 在開錄前,不列),用來決定鏡頭的 in 點。
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { launchChrome, guardNetwork, KIT_TMP } from './_chrome.mjs';

function usage(msg) {
  if (msg) console.error(`錯誤:${msg}`);
  console.error('用法:node record-web.mjs <網址> <動作.json> <輸出.mp4>');
  process.exit(2);
}
const args = process.argv.slice(2);
if (args.length !== 3) usage();
const [base, actionsPath, outArg] = args;
const isLocal = (u) => { try { const h = new URL(u).hostname; return h === 'localhost' || h === '127.0.0.1' || h === '[::1]'; } catch { return false; } };
if (!isLocal(base) || !/^https?:/.test(base)) usage(`只允許 localhost / 127.0.0.1 網址:${base}`);
let actions;
try { actions = JSON.parse(readFileSync(actionsPath, 'utf8')); } catch (e) { usage(`讀不到動作 JSON:${e.message}`); }
if (!Array.isArray(actions) || !actions.length) usage('動作 JSON 必須是非空陣列');
const out = resolve(outArg);
mkdirSync(dirname(out), { recursive: true });
mkdirSync(KIT_TMP, { recursive: true });
const tmp = mkdtempSync(join(KIT_TMP, 'rec-'));

const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const result = { out, duration: 0, frames: 0, marks: [], blockedRequests: [], errors: [] };
const frames = []; // {file, t}
let cdp; let t0 = null; let wall0 = null; let wallEnd = null;
try {
  cdp = await launchChrome();
  const stats = await guardNetwork(cdp, (u) => isLocal(u) || u.startsWith('data:') || u.startsWith('blob:'));
  await cdp.send('Page.enable'); await cdp.send('Runtime.enable');
  await cdp.send('Emulation.setDeviceMetricsOverride', { width: 540, height: 960, deviceScaleFactor: 2, mobile: true });
  await cdp.send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });
  cdp.on((m) => {
    if (m.method === 'Runtime.exceptionThrown') result.errors.push(`exception: ${m.params.exceptionDetails.exception?.description?.split('\n')[0] ?? m.params.exceptionDetails.text}`);
    if (m.method !== 'Page.screencastFrame') return;
    const { data, sessionId, metadata } = m.params;
    const t = metadata.timestamp ?? Date.now() / 1000;
    if (t0 === null) { t0 = t; wall0 = Date.now() / 1000; }
    const file = join(tmp, `f${String(frames.length).padStart(5, '0')}.jpg`);
    writeFileSync(file, Buffer.from(data, 'base64'));
    frames.push({ file, t: t - t0 });
    cdp.send('Page.screencastFrameAck', { sessionId }).catch(() => {});
  });

  let loaded = false;
  cdp.on((m) => { if (m.method === 'Page.loadEventFired') loaded = true; });
  const goto = async (u) => {
    const url = new URL(u ?? '/', base).href;
    if (!isLocal(url)) throw new Error(`goto 只允許本機網址:${url}`);
    loaded = false;
    await cdp.send('Page.navigate', { url });
    for (let i = 0; i < 150 && !loaded; i++) await sleep(100);
    if (!loaded) result.errors.push(`load: 15 秒內沒有載入完成 ${url}`);
  };
  const evalJs = async (expression) => {
    const r = await cdp.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description?.split('\n')[0] ?? r.exceptionDetails.text);
    return r.result.value;
  };

  // 第一個動作若是 goto,先載入再開始錄,避免片頭空白
  let i = 0;
  if (actions[0]?.do === 'goto') { await goto(actions[0].url); await sleep(500); i = 1; }
  await cdp.send('Page.startScreencast', { format: 'jpeg', quality: 90, maxWidth: 1080, maxHeight: 1920, everyNthFrame: 1 });
  await sleep(400);
  for (; i < actions.length; i++) {
    const a = actions[i];
    // 動作開始時間(相對成品開頭,秒),排鏡頭 in 點用
    result.marks.push({ i, do: a.do, t: wall0 === null ? 0 : Math.round((Date.now() / 1000 - wall0) * 1000) / 1000 });
    switch (a.do) {
      case 'goto': await goto(a.url); break;
      case 'wait': await sleep(Math.min(Number(a.ms) || 1000, 20000)); break;
      case 'scroll': {
        const y = Number(a.y) || 600, ms = Math.max(200, Number(a.ms) || 1000);
        await evalJs(`new Promise(res => { const s = scrollY, t0 = performance.now(); const step = (t) => { const p = Math.min(1, (t - t0) / ${ms}); const e = p < .5 ? 2*p*p : 1 - Math.pow(-2*p + 2, 2) / 2; scrollTo(0, s + ${y} * e); p < 1 ? requestAnimationFrame(step) : res(); }; requestAnimationFrame(step); })`);
        break;
      }
      case 'click': {
        const sel = JSON.stringify(String(a.selector ?? ''));
        const box = await evalJs(`(() => { const e = document.querySelector(${sel}); if (!e) return null; e.scrollIntoView({block:'center'}); const r = e.getBoundingClientRect(); return {x: r.x + r.width/2, y: r.y + r.height/2}; })()`);
        if (!box) throw new Error(`click 找不到元素:${a.selector}`);
        await sleep(250);
        await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: box.x, y: box.y }] });
        await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
        break;
      }
      case 'type': {
        const sel = JSON.stringify(String(a.selector ?? ''));
        const ok = await evalJs(`(() => { const e = document.querySelector(${sel}); if (!e) return false; e.scrollIntoView({block:'center'}); e.focus(); return true; })()`);
        if (!ok) throw new Error(`type 找不到元素:${a.selector}`);
        for (const ch of String(a.text ?? '')) {
          await cdp.send('Input.insertText', { text: ch });
          await sleep(Math.min(Number(a.delayMs) || 80, 500));
        }
        break;
      }
      default: throw new Error(`未知動作:${JSON.stringify(a)}`);
    }
    await sleep(300);
  }
  wallEnd = Date.now() / 1000;
  await cdp.send('Page.stopScreencast');
  result.blockedRequests = stats.blocked;
} catch (e) {
  result.errors.push(`record: ${e.message}`);
} finally {
  cdp?.close();
}

let failed = result.errors.some(e => e.startsWith('record:'));
if (!failed && frames.length === 0) { result.errors.push('record: 沒有收到任何畫面'); failed = true; }
if (!failed) {
  // 依實際時間戳記組成 concat 清單,轉成固定 30 fps
  const lastT = frames[frames.length - 1].t;
  // 畫面沒變化時 Chrome 不送新影格,最後一張要撐到錄影結束
  const total = Math.max(lastT + 1 / 30, wallEnd - wall0);
  let list = '';
  for (let k = 0; k < frames.length; k++) {
    const d = (k + 1 < frames.length ? frames[k + 1].t : total) - frames[k].t;
    list += `file '${frames[k].file}'\nduration ${Math.max(d, 0.001).toFixed(4)}\n`;
  }
  list += `file '${frames[frames.length - 1].file}'\n`;
  writeFileSync(join(tmp, 'list.txt'), list);
  const ff = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', join(tmp, 'list.txt'),
    '-vf', 'scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2,fps=30,format=yuv420p,setsar=1',
    '-c:v', 'libx264', '-preset', 'medium', '-crf', '18', '-an', out], { encoding: 'utf8' });
  if (ff.status !== 0) { result.errors.push(`record: ffmpeg 失敗 ${ff.stderr.slice(-400)}`); failed = true; }
  else { result.duration = Math.round(total * 1000) / 1000; result.frames = frames.length; }
}
rmSync(tmp, { recursive: true, force: true });
console.log(JSON.stringify(result));
process.exit(failed ? 1 : 0);
