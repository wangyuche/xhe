// 讀 curl `-c` 產生的 Netscape cookie 檔(唯讀)。
// `#HttpOnly_` 開頭的行去掉前綴後當 cookie;其他 `#` 開頭的行是註解。
import { readFileSync } from 'node:fs';

export function readCookieJar(path) {
  const out = [];
  for (let line of readFileSync(path, 'utf8').split(/\r?\n/)) {
    let httpOnly = false;
    if (line.startsWith('#HttpOnly_')) { line = line.slice('#HttpOnly_'.length); httpOnly = true; }
    else if (line.startsWith('#') || line.trim() === '') continue;
    const f = line.split('\t');
    if (f.length < 7) continue;
    const [domain, , path_, secure, expires, name, value] = f;
    out.push({
      domain: domain.replace(/^\./, ''),
      path: path_ || '/',
      secure: secure === 'TRUE',
      expires: Number(expires) || undefined,
      name, value, httpOnly,
    });
  }
  return out;
}

export function cookieHeader(cookies) {
  return cookies.map(c => `${c.name}=${c.value}`).join('; ');
}
