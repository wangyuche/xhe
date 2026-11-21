#!/bin/bash
# 用法:new-frontend.sh <專案根目錄> [--frontend frontend] [--api api]
# create-next-app@16 建立前端,再加上 Vitest、Playwright(channel chrome)、openapi-typescript、
# openapi-fetch、Prism 契約 mock、執行時轉發(src/proxy.ts 讀 BACKEND_URL)、standalone 輸出、Dockerfile 與 scripts。
# 前端目錄已存在且非空時失敗。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$DIR/.." && pwd)"
source "$DIR/versions.sh"

[ $# -ge 1 ] || { echo "用法:new-frontend.sh <專案根目錄> [--frontend frontend] [--api api]" >&2; exit 2; }
ROOT="$(cd "$1" && pwd -P)"; shift
FRONTEND="frontend"; API="api"
while [ $# -gt 0 ]; do
  case "$1" in
    --frontend) FRONTEND="${2%/}"; shift 2 ;;
    --api) API="${2%/}"; shift 2 ;;
    *) echo "未知參數:$1" >&2; exit 2 ;;
  esac
done
node_ok || { echo "錯誤:需要 Node.js >= $NODE_MIN(brew install node 或 brew upgrade node,由使用者執行)" >&2; exit 3; }

F="$ROOT/$FRONTEND"
if [ -d "$F" ] && [ -n "$(ls -A "$F" 2>/dev/null)" ]; then
  echo "錯誤:$F 已存在且不是空的" >&2; exit 1
fi
mkdir -p "$(dirname "$F")"
rmdir "$F" 2>/dev/null || true

NEXT_TELEMETRY_DISABLED=1 npx --yes "create-next-app@$CNA_VERSION" "$F" \
  --ts --app --eslint --no-tailwind --src-dir --import-alias "@/*" --use-npm --disable-git --yes >/dev/null

cd "$F"
npm install --save "${RUNTIME_DEPS[@]}" >/dev/null
npm install --save-dev "${DEV_DEPS[@]}" >/dev/null
cp -R "$SKILL/template/." "$F/"
mkdir -p src/lib/api

CONTRACT_REL="$(python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1],sys.argv[2]))' "$ROOT/$API/openapi.yaml" "$F")"
node -e '
const fs = require("fs");
const p = JSON.parse(fs.readFileSync("package.json", "utf8"));
const c = process.argv[1];
// output: "standalone":build 後把 static 與 public 複製進 .next/standalone,start 直接跑 server.js
// (next start 不支援 standalone 會警告)。PORT / HOSTNAME 由環境變數決定。
const assets =
  "rm -rf .next/standalone/.next/static .next/standalone/public" +
  " && cp -R .next/static .next/standalone/.next/static" +
  " && if [ -d public ]; then cp -R public .next/standalone/public; fi";
p.scripts = {
  ...p.scripts,
  postbuild: assets,
  start: "node .next/standalone/server.js",
  test: "vitest run",
  "test:e2e": "playwright test",
  "gen:api": `openapi-typescript ${c} -o src/lib/api/schema.d.ts`,
  "mock:api": `prism mock ${c} -h 127.0.0.1 -p \${PORT:-4010}`,
};
fs.writeFileSync("package.json", JSON.stringify(p, null, 2) + "\n");
' "$CONTRACT_REL"

GEN="略過(契約不存在)"
if [ -f "$ROOT/$API/openapi.yaml" ]; then npm run -s gen:api >/dev/null && GEN="已產生 src/lib/api/schema.d.ts"; fi
echo "已建立 $F(next $(node -p 'require("next/package.json").version'));型別:$GEN"
