#!/usr/bin/env node
// 用法:
//   node render.mjs <storyboard.json> <tts.json> <輸出目錄> --deliver <交付目錄> --asset-root <目錄>[,<目錄>…] [--template-dir <路徑>] [--out <輸出根目錄>] [--dry-run]
//   模板:--template-dir → storyboard 的 template 名稱(先找 <out>/_templates/<名稱>,<out> 預設 = --deliver 往上兩層 <out>/<job>/<n>)→ kit 預設。
//   node render.mjs --sample [--template-dir <路徑> | --template <名稱>]
// 流程:schema 驗證 → 語意檢查 → 排時間軸 → Chrome 開模板頁、注入內容 → 逐格(Web Animations currentTime)擷圖 → ffmpeg。
//   輸出目錄:silent.mp4、boxes.json、safe.json、timing.json、scenes.json;交付目錄:subtitles.srt、cover.png。
//   --dry-run:只驗證與排時間軸,stdout 印 {duration, rhythm, timing},不開 Chrome、不寫檔。
//   --sample:用模板的 sample.storyboard.json(圖片相對模板的 sample/)與假旁白(每句 0.2 秒 / 字),
//             只擷每個場景最終狀態,寫模板 preview/scene-NN.png 與 preview/contact.png。
// 時間軸:第 1 句 0.3 秒開始;第 i 句 start = 前句 end + 0.25;end = start + TTS 長度;片長 = 最後一句 end + 0.6。
// 網路:CDP Fetch 只放行 file:// 與 data:,其他一律擋下並列在 blockedRequests;內容一律 textContent。
// 結束碼:0 成功;2 storyboard / 參數 / 圖檔不合法;3 缺工具或模板;4 字幕或大標縮到 minFont 仍放不下;1 其他。
import { readFileSync, writeFileSync, mkdirSync, existsSync, realpathSync, rmSync, mkdtempSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { resolve, join, dirname } from 'node:path';
import { pathToFileURL } from 'node:url';
import {
  KIT, SVK, main, fail, Fail, parseArgs, resolveTemplate, loadTemplate, validateSchema, tokenize, lineText,
  buildTimeline, findAt, rhythmOf, resolveAsset, probeSize, r3, srtTime, CHROME, hasCmd,
} from './_lib.mjs';

const USAGE = '用法:node render.mjs <storyboard.json> <tts.json> <輸出目錄> --deliver <交付目錄> --asset-root <目錄>[,<目錄>…] [--template-dir <路徑>] [--out <輸出根目錄>] [--allow-bad-tts] [--dry-run]\n' +
  '      node render.mjs --sample [--template-dir <路徑> | --template <名稱>]';

main(async () => {
  const a = parseArgs(process.argv.slice(2), { '--deliver': 'v', '--asset-root': 'v', '--template-dir': 'v', '--template': 'v', '--out': 'v', '--allow-bad-tts': 'flag', '--dry-run': 'flag', '--sample': 'flag' }, USAGE);
  const sample = !!a.sample;
  if (!sample && a._.length !== 3) fail(USAGE, 2);
  if (sample && a._.length) fail(`--sample 不接受位置參數\n${USAGE}`, 2);
  if (!sample && !a['dry-run'] && !a.deliver) fail(`缺 --deliver <交付目錄>(subtitles.srt、cover.png 寫這裡)\n${USAGE}`, 2);

  // ---------- 讀 storyboard 與模板 ----------
  let board, boardPath;
  let tdir, tsource = 'path';
  if (sample) {
    tdir = resolveTemplate({ dir: a['template-dir'], name: a.template }).dir;
    boardPath = join(tdir, 'sample.storyboard.json');
  } else boardPath = resolve(a._[0]);
  try { board = JSON.parse(readFileSync(boardPath, 'utf8')); } catch (e) { fail(`讀不到 storyboard:${e.message}`, 2); }
  const schema = JSON.parse(readFileSync(join(KIT, 'storyboard.schema.json'), 'utf8'));
  const serr = validateSchema(schema, board);
  if (serr.length) fail(`storyboard 不符合 storyboard.schema.json:\n  ${serr.slice(0, 20).join('\n  ')}`, 2);
  if (!tdir) {
    const out = a.out ?? (a.deliver ? resolve(a.deliver, '..', '..') : undefined);
    const t = a['template-dir'] ? resolveTemplate({ dir: a['template-dir'] }) : resolveTemplate({ name: board.template, out });
    tdir = t.dir; tsource = t.source;
    process.stderr.write(`模板:${tdir}(${t.source === 'project' ? '專案模板' : t.source === 'kit' ? 'kit 預設模板' : '指定路徑'}${t.source === 'kit' && !out ? ';沒給 --out / --deliver,沒找專案模板' : ''})\n`);
  }
  const { tpl, problems } = loadTemplate(tdir);
  if (problems.length) fail(`模板 ${tdir} 不合格:\n  ${problems.join('\n  ')}`, 3);
  const [W, H] = tpl.size; const FPS = tpl.fps;

  // ---------- 句子(* 成對、顯示字數)----------
  board.scenes.forEach((sc, j) => sc.lines.forEach((l, k) => {
    const tok = tokenize(lineText(l));
    if (tok.error) fail(`scenes[${j}].lines[${k}]:${tok.error}`, 2);
    const n = [...tok.display].length;
    if (n > tpl.maxLineChars) fail(`scenes[${j}].lines[${k}] 顯示 ${n} 字 > ${tpl.maxLineChars}(模板 maxLineChars):「${tok.display}」;拆成兩句`, 2);
  }));

  // ---------- 旁白長度 ----------
  const allLines = board.scenes.flatMap(s => s.lines);
  let durations, tts = null, ttsDir = null; const badTts = [];
  if (sample) durations = allLines.map(l => r3(Math.max(0.6, [...tokenize(lineText(l)).display].filter(c => c !== ' ').length * 0.2)));
  else {
    const ttsPath = resolve(a._[1]); ttsDir = dirname(ttsPath);
    try { tts = JSON.parse(readFileSync(ttsPath, 'utf8')); } catch (e) { fail(`讀不到 tts.json:${e.message}`, 2); }
    if (!Array.isArray(tts)) fail('tts.json 要是 tts.mjs 輸出的陣列', 2);
    if (tts.length !== allLines.length) fail(`tts.json 有 ${tts.length} 句,storyboard 有 ${allLines.length} 句(改了 storyboard 要重跑 tts.mjs)`, 2);
    durations = tts.map((x, i) => {
      if (x?.ok === false) {
        if (!a['allow-bad-tts']) fail(`tts.json 第 ${i + 1} 句 ok:false(無聲或太短):改寫念法(say)後 tts.mjs --only ${i + 1} 重生;仍失敗而要照做成品時加 --allow-bad-tts`, 2);
        badTts.push(i + 1); process.stderr.write(`警告:第 ${i + 1} 句 ok:false,依 --allow-bad-tts 照做(該句可能無聲)\n`);
      }
      const d = Number(x?.duration);
      if (!(d > 0)) fail(`tts.json[${i}].duration 不合法`, 2);
      const want = tokenize(lineText(allLines[i])).display;
      const wantSay = typeof allLines[i] === 'object' ? (allLines[i].say ?? null) : null;
      if ('say' in x && (x.say ?? null) !== wantSay) fail(`tts.json 第 ${i + 1} 句念法是「${x.say ?? '(無)'}」,storyboard 是「${wantSay ?? '(無)'}」(改了 say 要 tts.mjs --only ${i + 1})`, 2);
      if (typeof x.text === 'string' && x.text !== want) fail(`tts.json 第 ${i + 1} 句是「${x.text}」,storyboard 是「${want}」(改了 storyboard 要重跑 tts.mjs)`, 2);
      return d;
    });
  }

  // ---------- 語意檢查 ----------
  const roots = sample ? [realpathSync(join(tdir, 'sample'))]
    : (a['asset-root'] ?? '').split(',').filter(Boolean).map((r) => { const p = resolve(r); if (!existsSync(p)) fail(`--asset-root 不存在:${r}`, 2); return realpathSync(p); });
  const poses = Object.keys(tpl.mascot);
  const imgUse = new Map(); // 實際路徑 → Set(場景)
  const cardInnerW = tpl.cardInner?.[0] ?? W * 0.85;
  const probeImg = (real, where) => { const s = probeSize(real); if (!s) fail(`${where}:讀不出圖片尺寸`, 2); return s; };
  board.scenes.forEach((sc, j) => {
    const where = `scenes[${j}]`;
    sc.headline.forEach((h, k) => { if (!h[0] && !h[1]) fail(`${where}.headline[${k}] 黑字與橘字不能都是空字串`, 2); });
    if (sc.mascot && !poses.includes(sc.mascot)) fail(`${where}.mascot「${sc.mascot}」不是模板的姿勢(${poses.join(' / ')})`, 2);
    const type = sc.card?.type ?? 'title';
    if (!tpl.scenes.includes(type)) fail(`${where}:模板 ${tpl.name ?? tdir} 不支援場景類型 ${type}`, 2);
    const use = (rel, w) => {
      const real = resolveAsset(rel, roots, w);
      if (!imgUse.has(real)) imgUse.set(real, new Set());
      imgUse.get(real).add(j);
      const [iw, ih] = probeImg(real, w);
      return { real, w: iw, h: ih };
    };
    const cd = sc.card;
    if (!cd) return;
    if (cd.type === 'image') {
      cd._img = use(cd.src, `${where}.card.src`);
      if (!cd.focus && cd._img.w > cardInnerW * 1.5) fail(`${where}.card:圖寬 ${cd._img.w} > 卡片內寬 ${cardInnerW} 的 1.5 倍,focus 必填(來源像素 [x,y,w,h],框出旁白在講的區域,避免字太小)`, 2);
    }
    if (cd.type === 'compare') { cd._left = use(cd.left, `${where}.card.left`); cd._right = use(cd.right, `${where}.card.right`); }
    if (cd.focus) {
      const [fx, fy, fw, fh] = cd.focus; const imgs = cd.type === 'image' ? [cd._img] : [cd._left, cd._right];
      if (!(fw > 0 && fh > 0)) fail(`${where}.card.focus 寬高要 > 0`, 2);
      for (const im of imgs) if (fx + fw > im.w + 0.5 || fy + fh > im.h + 0.5) fail(`${where}.card.focus ${JSON.stringify(cd.focus)} 超出圖片 ${im.w}×${im.h}`, 2);
    }
    if (cd.type === 'grid' && cd.items.length % cd.cols !== 0) fail(`${where}.card:grid 要排滿(cols ${cd.cols},items ${cd.items.length};2×2、2×3 或 3×2)`, 2);
  });
  for (const [real, set] of imgUse) if (set.size > 2) fail(`同一個圖檔用在 ${set.size} 個場景(上限 2):${real.split('/').slice(-2).join('/')}(場景 ${[...set].map(x => x + 1).join(', ')})`, 2);

  // ---------- 時間軸 ----------
  const tl = buildTimeline(board, durations);
  const events = []; // { scene, t, at }
  const atTime = (j, at, where) => {
    if (at === undefined) return null;
    const t = findAt(tl, j, at);
    if (t === null) fail(`${where}.at「${at}」在場景 ${j + 1} 的 lines 分段詞裡找不到(要等於某個分段詞,去掉 *)`, 2);
    return t;
  };
  const pageScenes = board.scenes.map((sc, j) => {
    const s = tl.scenes[j]; const where = `scenes[${j}].card`;
    const base = { start: s.start, end: s.end, type: s.type, mascot: s.mascot, headline: sc.headline, t: r3(s.start + (j === 0 ? 0.35 : 0.08)) };
    const cd = sc.card; if (!cd) return base;
    const at = atTime(j, cd.at, where);
    const t = at ?? base.t;
    events.push({ scene: j, t, at: at !== null });
    const card = { ...cd, t };
    delete card._img; delete card._left; delete card._right;
    const imgOf = (im) => ({ url: pathToFileURL(im.real).href, w: im.w, h: im.h });
    if (cd._img) card.img = imgOf(cd._img);
    if (cd._left) { card.leftImg = imgOf(cd._left); card.rightImg = imgOf(cd._right); }
    if (Array.isArray(cd.items)) card.items = cd.items.map((it, k) => {
      const ti = atTime(j, it.at, `${where}.items[${k}]`);
      const tt = ti !== null ? Math.max(ti, t) : r3(t + 0.12 * k);
      events.push({ scene: j, t: tt, at: ti !== null && ti > t });
      return { ...it, t: tt };
    });
    return { ...base, card };
  });
  const { changes, cardEmpty, rhythm, problems: rp } = rhythmOf(tl, events);
  const timing = { duration: tl.duration, sentences: tl.sentences.map(({ i, start, end, text, words }) => ({ i, start, end, text, words: words.map(({ w, start, end, hl }) => ({ w, start, end, hl })) })), scenes: tl.scenes, changes, cardEmpty, rhythm };
  if (rp.length) console.error(`節奏提醒:\n  ${rp.join('\n  ')}`);

  if (a['dry-run']) {
    console.log(JSON.stringify({ template: tdir, templateSource: tsource, duration: tl.duration, rhythm, timing }));
    return;
  }
  if (!sample && tl.duration > 60) fail(`片長 ${tl.duration} 秒超過 60 秒(先 --dry-run 刪句)`, 2);
  for (const c of ['ffmpeg', 'ffprobe']) if (!hasCmd(c)) fail(`缺 ${c}(brew install ffmpeg)`, 3);
  if (!existsSync(CHROME)) fail(`找不到 Google Chrome:${CHROME}`, 3);

  // ---------- 輸出位置 ----------
  const outDir = sample ? join(tdir, 'preview') : resolve(a._[2]);
  const deliver = sample ? outDir : resolve(a.deliver);
  mkdirSync(outDir, { recursive: true }); mkdirSync(deliver, { recursive: true });

  // ---------- Chrome ----------
  const { launchChrome, guardNetwork, cleanupOnSignal } = await import(pathToFileURL(join(SVK, '_chrome.mjs')).href);
  const mascot = Object.fromEntries(Object.entries(tpl.mascot).map(([k, f]) => [k, pathToFileURL(resolve(tdir, f)).href]));
  const data = {
    size: tpl.size, duration: tl.duration, palette: tpl.palette, fonts: tpl.fonts, tag: board.tag ?? tpl.tag, safe: tpl.safe, minFont: tpl.minFont,
    mascot, sentences: tl.sentences, scenes: pageScenes,
  };
  let cdp, ff, tmpDir;
  let result;
  try {
    // 可重現:軟體繪製(--disable-gpu)+ 每次定位後等一個 animation frame 再擷圖(2026-11-24 實測:GPU 繪製或不等待時,縮放動畫中的字形偶爾有肉眼看不出的像素差,x264 輸出就不同;兩者都做後 5 次渲染 MP4 逐位元相同)
    cdp = await launchChrome({ args: ['--disable-gpu'] });
    const stats = await guardNetwork(cdp, (u) => u.startsWith('file://') || u.startsWith('data:'));
    await cdp.send('Page.enable'); await cdp.send('Runtime.enable');
    await cdp.send('Emulation.setDeviceMetricsOverride', { width: W, height: H, deviceScaleFactor: 1, mobile: false });
    const loaded = new Promise(r => cdp.on(m => { if (m.method === 'Page.loadEventFired') r(); }));
    await cdp.send('Page.navigate', { url: pathToFileURL(join(tdir, 'template.html')).href });
    await Promise.race([loaded, new Promise(r => setTimeout(r, 10000))]);
    const ev = async (expr) => {
      const r = await cdp.send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
      if (r.exceptionDetails) throw new Error(`模板頁執行失敗:${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
      return r.result.value;
    };
    const built = await ev(`MVK.build(${JSON.stringify(data)}).then(r => JSON.stringify(r))`).then(JSON.parse);
    if (built.errors.length) {
      const layout = built.errors.filter(e => /放不下/.test(e));
      if (layout.length) throw new Fail(`版面放不下(拆句、縮短大標或卡片文字後重跑):\n  ${layout.join('\n  ')}`, 4);
      throw new Error(built.errors.join('\n'));
    }
    const shotAt = async (t, format = 'png', quality) => {
      await ev(`MVK.seek(${t}); new Promise(r => requestAnimationFrame(() => r(0)))`);
      const r = await cdp.send('Page.captureScreenshot', { format, ...(quality ? { quality } : {}), optimizeForSpeed: true, clip: { x: 0, y: 0, width: W, height: H, scale: 1 } });
      return Buffer.from(r.data, 'base64');
    };
    const coverT = Math.max(0, Math.min(tl.scenes[0].end - 0.2, tl.scenes[0].end - 0.05));

    if (sample) {
      // 每個場景最終狀態(場景結束前 0.2 秒)
      tmpDir = mkdtempSync(join(outDir, '.tmp-'));
      cleanupOnSignal(tmpDir);
      const files = [];
      for (let j = 0; j < tl.scenes.length; j++) {
        const s = tl.scenes[j];
        const buf = await shotAt(Math.max(s.start + 0.05, s.end - 0.2));
        const f = join(outDir, `scene-${String(j + 1).padStart(2, '0')}.png`);
        writeFileSync(f, buf); writeFileSync(join(tmpDir, `${String(j + 1).padStart(3, '0')}.png`), buf); files.push(f);
      }
      const n = files.length, cols = Math.min(3, n), rows = Math.ceil(n / cols);
      const tw = Math.round(W / cols / 2) * 2 - 12;
      spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-framerate', '1', '-i', join(tmpDir, '%03d.png'),
        '-vf', `scale=${tw}:-2,tile=${cols}x${rows}:padding=8:margin=8:color=0xF5EADC`, '-frames:v', '1', '-update', '1', join(outDir, 'contact.png')], { stdio: 'inherit' });
      result = { template: tdir, scenes: files, contact: join(outDir, 'contact.png'), duration: tl.duration, rhythm, blockedRequests: stats.blocked };
    } else {
      // 逐格擷圖 → ffmpeg(JPEG 管線比 PNG 快;x264 crf 16)
      const silent = join(outDir, 'silent.mp4');
      const N = Math.round(tl.duration * FPS);
      ff = spawn('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'image2pipe', '-c:v', 'mjpeg', '-framerate', String(FPS), '-i', '-',
        '-vf', 'scale=in_range=pc:out_range=tv,format=yuv420p', '-c:v', 'libx264', '-preset', 'medium', '-crf', '16', '-profile:v', 'high', '-pix_fmt', 'yuv420p',
        '-color_range', 'tv', '-r', String(FPS), '-frames:v', String(N), '-movflags', '+faststart', silent], { stdio: ['pipe', 'ignore', 'pipe'] });
      let ffErr = ''; ff.stderr.on('data', d => { ffErr += d; });
      let ffExited = false, pipeErr = null;
      const ffDone = new Promise(r => ff.on('close', c => { ffExited = true; r(c); }));
      ff.stdin.on('error', e => { pipeErr = e; });   // ffmpeg 先結束時寫入會 EPIPE:記下來,不讓它變成未處理例外
      const t0 = Date.now();
      for (let f = 0; f < N; f++) {
        const buf = await shotAt(r3(f / FPS), 'jpeg', 92);
        if (ffExited || pipeErr) break;
        if (!ff.stdin.write(buf)) { await Promise.race([new Promise(r => ff.stdin.once('drain', r)), ffDone]); if (ffExited || pipeErr) break; }
        if (f % (FPS * 2) === 0 || f === N - 1) process.stderr.write(`\r渲染 ${f + 1}/${N} 格(${Math.round((f + 1) / N * 100)}%,${((Date.now() - t0) / 1000).toFixed(0)} 秒)`);
      }
      process.stderr.write('\n');
      ff.stdin.end();
      const code = await ffDone; ff = null;
      if (code !== 0 || pipeErr) throw new Error(`ffmpeg 編碼失敗(結束碼 ${code}${pipeErr ? `,${pipeErr.code ?? pipeErr.message}` : ''}):${ffErr.slice(-800)}`);
      writeFileSync(join(deliver, 'cover.png'), await shotAt(coverT));
      const renderSeconds = r3((Date.now() - t0) / 1000);
      // 輸出
      writeFileSync(join(outDir, 'boxes.json'), JSON.stringify(built.boxes, null, 1));
      writeFileSync(join(outDir, 'safe.json'), JSON.stringify({ subtitle: tpl.safe.subtitle, headline: tpl.safe.headline }));
      writeFileSync(join(outDir, 'timing.json'), JSON.stringify(timing, null, 1));
      writeFileSync(join(outDir, 'scenes.json'), JSON.stringify(tl.scenes.map(({ start, end, type }) => ({ start, end, type })), null, 1));
      writeFileSync(join(deliver, 'subtitles.srt'), tl.sentences.map((s, k) => `${k + 1}\n${srtTime(s.start)} --> ${srtTime(s.end)}\n${s.text}\n`).join('\n'));
      result = {
        template: tdir, templateSource: tsource, badTts, duration: tl.duration, frames: N, fps: FPS, size: `${W}x${H}`, renderSeconds, rhythm,
        silent, cover: join(deliver, 'cover.png'), srt: join(deliver, 'subtitles.srt'),
        boxes: join(outDir, 'boxes.json'), safe: join(outDir, 'safe.json'), timing: join(outDir, 'timing.json'), scenesFile: join(outDir, 'scenes.json'),
        blockedRequests: stats.blocked,
      };
    }
  } finally {
    if (ff) { try { ff.stdin.destroy(); ff.kill('SIGKILL'); } catch {} }
    if (tmpDir) rmSync(tmpDir, { recursive: true, force: true });
    await cdp?.close();
  }
  console.log(JSON.stringify(result));
});
