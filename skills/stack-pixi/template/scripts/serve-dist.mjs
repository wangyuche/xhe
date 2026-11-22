// 效能量測用靜態伺服器(stack-pixi):提供 production build,文字資源 gzip level 9(vite preview 不壓縮,傳輸量會失真)。
//   PORT=<埠> node scripts/serve-dist.mjs <distDir> [apiTarget]
//   apiTarget 有給時,/v1/* 反向代理過去(不改 Origin)。只綁 127.0.0.1。
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

const [dirArg, target] = process.argv.slice(2);
if (!dirArg) { console.error('用法:PORT=<埠> node scripts/serve-dist.mjs <distDir> [apiTarget]'); process.exit(2); }
const dir = path.resolve(dirArg);
const port = Number(process.env.PORT) || 4175;
const api = target ? new URL(target) : undefined;
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.webp': 'image/webp', '.avif': 'image/avif', '.ogg': 'audio/ogg', '.m4a': 'audio/mp4', '.woff2': 'font/woff2' };
const COMPRESS = new Set(['.html', '.js', '.css', '.json', '.svg']);
const gz = new Map();

http.createServer((req, res) => {
  if (api && req.url.startsWith('/v1/')) {
    const p = http.request({ host: api.hostname, port: api.port, path: req.url, method: req.method, headers: req.headers },
      (r) => { res.writeHead(r.statusCode, r.headers); r.pipe(res); });
    p.on('error', () => { res.writeHead(502); res.end(); });
    req.pipe(p);
    return;
  }
  let file = path.join(dir, decodeURIComponent(new URL(req.url, 'http://x').pathname));
  if (!file.startsWith(dir)) { res.writeHead(403); res.end(); return; }
  if (file.endsWith(path.sep) || file === dir) file = path.join(file, 'index.html');
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) { res.writeHead(404); res.end(); return; }
  const ext = path.extname(file);
  const headers = { 'content-type': TYPES[ext] ?? 'application/octet-stream', 'cache-control': 'no-cache' };
  if (COMPRESS.has(ext) && /gzip/.test(req.headers['accept-encoding'] ?? '')) {
    let body = gz.get(file);
    if (!body) { body = zlib.gzipSync(fs.readFileSync(file), { level: 9 }); gz.set(file, body); }
    res.writeHead(200, { ...headers, 'content-encoding': 'gzip', 'content-length': body.length });
    res.end(body);
  } else {
    const body = fs.readFileSync(file);
    res.writeHead(200, { ...headers, 'content-length': body.length });
    res.end(body);
  }
}).listen(port, '127.0.0.1', () => console.log(`serve-dist ${dir} on ${port}${api ? ` -> ${api.origin}` : ''}`));
