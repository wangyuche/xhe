// spec-site-kit 共用:無依賴的最小 JSON Schema 驗證器、git 輔助、內容掃描。
import { readFileSync, existsSync, statSync, realpathSync } from 'node:fs';
import { dirname, join, resolve, relative, sep, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';

export const KIT = 'spec-site-kit/1';
export const HERE = dirname(fileURLToPath(import.meta.url));
export const KIT_DIR = resolve(HERE, '..');
export const STATUSES = ['已完成', '已實作未測', '未開始', '不做', '無法判定'];
export const SECTIONS = ['flows', 'rules', 'pending', 'mismatches', 'out_of_scope', 'tech'];

// ---- JSON Schema(只支援 schema 用到的關鍵字)----
const KNOWN = new Set(['$comment', '$defs', 'type', 'const', 'enum', 'pattern', 'minLength', 'minimum', 'minItems',
  'items', 'properties', 'required', 'additionalProperties', '$ref', 'uniqueBy']);
const typeOk = (t, v) => t === 'object' ? v !== null && typeof v === 'object' && !Array.isArray(v)
  : t === 'array' ? Array.isArray(v) : t === 'integer' ? Number.isInteger(v) : typeof v === t;

function check(schema, v, path, root, errs) {
  for (const k of Object.keys(schema)) if (!KNOWN.has(k)) throw new Error(`schema 用了不支援的關鍵字 ${k}(${path})`);
  if (schema.$ref) {
    const m = /^#\/\$defs\/(.+)$/.exec(schema.$ref);
    if (!m || !root.$defs?.[m[1]]) throw new Error(`無法解析 $ref ${schema.$ref}`);
    check(root.$defs[m[1]], v, path, root, errs);
  }
  const err = (msg) => errs.push(`${path || '(根)'}: ${msg}`);
  if (schema.type && !typeOk(schema.type, v)) return err(`應為 ${schema.type}`);
  if ('const' in schema && v !== schema.const) err(`應為 ${JSON.stringify(schema.const)}`);
  if (schema.enum && !schema.enum.includes(v)) err(`應為 ${schema.enum.map(x => JSON.stringify(x)).join(' / ')} 之一`);
  if (typeof v === 'string') {
    if (schema.pattern && !new RegExp(schema.pattern).test(v)) err(`不符合 ${schema.pattern}`);
    if (schema.minLength != null && v.trim().length < schema.minLength) err(`不可空白`);
  }
  if (typeof v === 'number' && schema.minimum != null && v < schema.minimum) err(`應 ≥ ${schema.minimum}`);
  if (Array.isArray(v)) {
    if (schema.minItems != null && v.length < schema.minItems) err(`至少 ${schema.minItems} 項`);
    if (schema.items) v.forEach((x, i) => check(schema.items, x, `${path}[${i}]`, root, errs));
    if (schema.uniqueBy) {
      const seen = new Set();
      for (const x of v) { const key = x?.[schema.uniqueBy]; if (seen.has(key)) err(`${schema.uniqueBy} 重複:${key}`); seen.add(key); }
    }
  }
  if (typeOk('object', v)) {
    const own = (o, k) => Object.prototype.hasOwnProperty.call(o ?? {}, k);
    for (const r of schema.required ?? []) if (!own(v, r)) err(`缺少 ${r}`);
    for (const [k, s] of Object.entries(schema.properties ?? {})) if (own(v, k)) check(s, v[k], path ? `${path}.${k}` : k, root, errs);
    if (schema.additionalProperties === false) for (const k of Object.keys(v)) if (!own(schema.properties, k)) err(`未知欄位 ${k}`);
  }
}

let SCHEMA;
export function validateSchema(def, obj) {
  SCHEMA ??= JSON.parse(readFileSync(join(KIT_DIR, 'schemas', 'spec.schema.json'), 'utf8'));
  const errs = [];
  check({ $ref: `#/$defs/${def}` }, obj, '', SCHEMA, errs);
  return errs;
}

// ---- 檔案 / git ----
export function readJson(p) {
  return JSON.parse(readFileSync(p, 'utf8'));
}
export function sha256File(p) {
  return createHash('sha256').update(readFileSync(p)).digest('hex');
}
export function git(root, args, { allowFail = false } = {}) {
  try {
    return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 256 * 1024 * 1024 });
  } catch (e) {
    if (allowFail) return null;
    throw new Error(`git ${args.join(' ')} 失敗:${(e.stderr || e.message).toString().trim()}`);
  }
}
export function gitRoot(dir) {
  const out = git(dir, ['rev-parse', '--show-toplevel'], { allowFail: true });
  return out ? realpathSync(out.trim()) : null;
}
export function head(root) {
  return git(root, ['rev-parse', 'HEAD']).trim();
}
// 輸出目錄 → 相對專案根的路徑(必須在根內)
export function relInside(root, abs) {
  let real = abs;
  try { real = realpathSync(abs); } catch { /* 不存在時用原路徑 */ }
  const r = relative(root, real);
  if (!r || r === '..' || r.startsWith('..' + sep) || isAbsolute(r)) return null;
  return r.split(sep).join('/');
}
let trackedCache = new Map();
export function tracked(root) {
  if (!trackedCache.has(root)) trackedCache.set(root, new Set(git(root, ['ls-files', '-z']).split('\0').filter(Boolean)));
  return trackedCache.get(root);
}
const untrackedCache = new Map();
export function untracked(root) {
  if (!untrackedCache.has(root)) untrackedCache.set(root, new Set(git(root, ['ls-files', '-z', '-o', '--exclude-standard']).split('\0').filter(Boolean)));
  return untrackedCache.get(root);
}
const lineCache = new Map();
const textCache = new Map();
// 取第 from ~ to 行(1 起算,含頭尾)的內容
export function linesText(abs, from, to) {
  if (!textCache.has(abs)) textCache.set(abs, readFileSync(abs, 'utf8').split('\n'));
  return textCache.get(abs).slice(from - 1, to).join('\n');
}
export const byOrder = (a, b) => ((a.module.order ?? 1e9) - (b.module.order ?? 1e9)) || a.module.id.localeCompare(b.module.id);
export function lineCount(abs) {
  if (!lineCache.has(abs)) {
    const t = readFileSync(abs, 'utf8');
    lineCache.set(abs, t === '' ? 0 : t.split('\n').length - (t.endsWith('\n') ? 1 : 0));
  }
  return lineCache.get(abs);
}

// ---- 內容掃描:絕對路徑、私有 IP、秘密樣式 ----
const FORBIDDEN = [
  [/(^|[^A-Za-z0-9._~-])\/(Users|Volumes|private\/var|var\/folders)\/[^\s/]+/, '本機絕對路徑'],
  [/(^|[^A-Za-z0-9._~-])\/(private|tmp|root)\/[^\s/]+/, '本機絕對路徑', 'route'],
  [/(^|[^A-Za-z0-9._~-])\/home\/[^\s/]+\//, '本機絕對路徑(/home)', 'route'],
  [/(^|[\s"'`(=:@/])[a-z0-9][a-z0-9-]*(\.[a-z0-9-]+)*\.(local|lan|internal|home\.arpa)(?=$|[\s"'`):/,;!?)]|\.(\s|$))/i, '內網主機名'],
  [/\b[A-Za-z]:\\/, 'Windows 絕對路徑'],
  [/\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/, '私有 IP(10/8)'],
  [/\b192\.168\.\d{1,3}\.\d{1,3}\b/, '私有 IP(192.168/16)'],
  [/\b172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b/, '私有 IP(172.16/12)'],
  [/\b100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b/, 'CGNAT / Tailscale IP(100.64/10)'],
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----/, '私鑰'],
  [/\bAKIA[0-9A-Z]{16}\b/, 'AWS 金鑰'],
  [/\b(ghp|gho|ghs|ghu|github_pat)_[A-Za-z0-9_]{20,}/, 'GitHub token'],
  [/\bglpat-[A-Za-z0-9_-]{20,}/, 'GitLab token'],
  [/\bxox[abpr]-[A-Za-z0-9-]{10,}/, 'Slack token'],
  [/\bsk-(ant-)?[A-Za-z0-9_-]{20,}/, 'API 金鑰'],
  [/\b\d{8,10}:[A-Za-z0-9_-]{35}\b/, 'Telegram bot token'],
  [/\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/, 'JWT'],
  [/\b(password|passwd|secret|api[_-]?key|token)\s*[:=]\s*['"]?(?=[A-Za-z0-9_\-+/=.]*\d)[A-Za-z0-9_\-+/=.]{16,}/i, '疑似秘密值'],
];
// keyword / keywords 是程式裡的字串:像路由的 /home/…、/private/…、/tmp/…、/root/… 放行,/Users、/Volumes 等照擋(keyword 也會印在頁面上)。
// path、sources_read、code_paths、exclude_paths 是 repo 內相對路徑(schema 已限制),不掃(檔名常有 .local、.internal)。
const SKIP_KEYS = new Set(['path', 'sources_read', 'code_paths', 'exclude_paths']);
export function scanStrings(obj, path = '', out = [], key = '') {
  if (SKIP_KEYS.has(key)) return out;
  if (typeof obj === 'string') {
    const isKw = key === 'keyword' || key === 'keywords';
    for (const [re, what, kind] of FORBIDDEN) if (!(isKw && kind === 'route') && re.test(obj)) out.push(`${path || '(根)'}: 含${what}:${obj.slice(0, 80)}`);
  } else if (Array.isArray(obj)) obj.forEach((x, i) => scanStrings(x, `${path}[${i}]`, out, key));
  else if (obj && typeof obj === 'object') for (const [k, v] of Object.entries(obj)) scanStrings(v, path ? `${path}.${k}` : k, out, k);
  return out;
}

export const isMain = (url) => { try { return !!process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(url)); } catch { return false; } };
export { existsSync, statSync, join, resolve };
