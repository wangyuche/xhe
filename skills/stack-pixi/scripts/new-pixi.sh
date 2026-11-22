#!/bin/bash
# stack-pixi 骨架:建立 PixiJS 8 + Vite 8 + TypeScript 玩家端,或檢查骨架齊全。
#   bash new-pixi.sh <目錄> --design 1920x1080 [--name <套件名>] [--title <標題>] [--net ws] [--iframe] [--no-install]
#   bash new-pixi.sh --check <目錄>
# 目錄必須不存在或為空(只有 .git 也算空:可以先 git init 再建骨架)。依賴版本鎖在 template/package-lock.json(npm ci)。
# 素材驗證器從同層的 game-art-kit/schemas 複製到 <目錄>/scripts/schemas/。
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "new-pixi: $*" >&2; exit 2; }
# 跨平台取代(BSD / GNU sed 的 -i 不相容):repl <檔案> <舊> <新> [<舊> <新>]...
repl() { node -e 'const fs=require("fs");const [f,...p]=process.argv.slice(1);let s=fs.readFileSync(f,"utf8");for(let i=0;i<p.length;i+=2)s=s.split(p[i]).join(p[i+1]);fs.writeFileSync(f,s)' "$@"; }

REQUIRED=(package.json package-lock.json vite.config.ts tsconfig.json tsconfig.node.json playwright.config.ts index.html .gitignore
  src/main.ts src/config/design.ts src/core/app.ts src/core/pause.ts src/core/scene-manager.ts src/core/announce.ts src/core/modal-guard.ts
  src/core/input-modality.ts src/core/safe-area.ts src/core/layout.ts src/core/orientation.ts src/core/audio.ts
  src/components/a11y.ts src/i18n/en.ts src/i18n/index.ts src/assets/index.ts src/assets/early.ts src/assets/tier.ts
  scripts/build-assets.mjs scripts/serve-dist.mjs scripts/schemas/validate.mjs scripts/schemas/assets.schema.json scripts/schemas/needs.schema.json
  tests/e2e/fixtures/base.ts tests/perf/lib.ts tests/perf/first-screen.perf.spec.ts tests/perf/scene-switch.perf.spec.ts tests/perf/soak.perf.spec.ts
  docs/performance-budgets.md)
HEADINGS=(首屏 場景切換 傳輸量 長時間遊玩 素材預算 例外 最新實測)

check() {
  local d=$1 bad=0
  [ -d "$d" ] || die "--check:$d 不存在"
  d=$(cd "$d" && pwd)
  for f in "${REQUIRED[@]}"; do [ -f "$d/$f" ] || { echo "缺少 $f"; bad=1; }; done
  for d2 in src/scenes src/game src/services; do [ -d "$d/$d2" ] || { echo "缺少 $d2/"; bad=1; }; done
  if [ -f "$d/docs/performance-budgets.md" ]; then
    for h in "${HEADINGS[@]}"; do
      n=$(grep -cx "## $h" "$d/docs/performance-budgets.md" || true)
      [ "$n" = 1 ] || { echo "performance-budgets.md「## $h」出現 $n 次(應為 1)"; bad=1; }
    done
    grep -q '__[A-Z]*__' "$d/docs/performance-budgets.md" && { echo "performance-budgets.md 還有未填的 __佔位__(填數值、—,或標(推定))"; bad=1; }
  fi
  if [ -f "$d/src/config/design.ts" ] && grep -q '__DESIGN' "$d/src/config/design.ts"; then echo "design.ts 未填設計解析度"; bad=1; fi
  if [ -f "$d/package.json" ]; then
    node -e "const p=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));const v=(p.dependencies||{})['pixi.js']||'';if(!/^\D*8\./.test(v)){console.log('pixi.js 不是 8.x:'+v);process.exit(1)}" "$d/package.json" || bad=1
  fi
  if [ $bad = 0 ]; then echo '{"ok":true}'; else echo '{"ok":false}'; exit 1; fi
}

usage() {
  cat <<'EOF'
用法:
  bash new-pixi.sh <目錄> --design <W>x<H> [--name <套件名>] [--title <標題>] [--net ws] [--iframe] [--no-install]
  bash new-pixi.sh --check <目錄>
  bash new-pixi.sh --help
  --design   設計解析度(寬x高,各 3–4 位數、不可 0 開頭),例如 1920x1080
  --name     package.json 的 name(小寫英數與 -;預設 = 目錄名)
  --title    頁面標題(預設 = name)
  --net ws   加 WebSocket transport(src/services/net/)
  --iframe   加 iframe bridge(src/services/iframe/)
  --no-install  不執行 npm ci
目錄必須不存在或為空(只有 .git 也可以)。
EOF
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ "${1:-}" = "--check" ] && { check "${2:?用法:new-pixi.sh --check <目錄>}"; exit; }

DIR=${1:-}; [ -n "$DIR" ] && shift || { usage >&2; exit 2; }
case $DIR in -*) usage >&2; die "第一個參數要是目錄:$DIR" ;; esac
DESIGN=""; NAME=""; TITLE=""; NET=""; IFRAME=0; INSTALL=1
while [ $# -gt 0 ]; do
  case $1 in --design|--name|--title|--net) [ $# -ge 2 ] || die "$1 需要值" ;; esac
  case $1 in
    --design) DESIGN=${2:-}; shift 2 ;;
    --name) NAME=${2:-}; shift 2 ;;
    --title) TITLE=${2:-}; shift 2 ;;
    --net) NET=${2:-}; [ "$NET" = ws ] || die "--net 只支援 ws"; shift 2 ;;
    --iframe) IFRAME=1; shift ;;
    --no-install) INSTALL=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知參數 $1(--help 看用法)" ;;
  esac
done
[[ $DESIGN =~ ^([1-9][0-9]{2,3})x([1-9][0-9]{2,3})$ ]] || die "--design 必填,格式 1920x1080(各 3–4 位數、不可 0 開頭)"
W=${BASH_REMATCH[1]}; H=${BASH_REMATCH[2]}
if [ -e "$DIR" ] && [ -n "$(ls -A "$DIR" 2>/dev/null | grep -Fvx '.git')" ]; then die "$DIR 已有檔案(只建新專案;只有 .git 可以)"; fi
[ -n "$NAME" ] || NAME=$(basename "$(cd "$(dirname "$DIR")" 2>/dev/null && pwd)/$(basename "$DIR")" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/^-*//')
[[ $NAME =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "--name 只能用小寫英數與 -"
[ -n "$TITLE" ] || TITLE=$NAME
case $TITLE in *[\<\>\&\"\'\\\|]*) die "--title 不可含 < > & \" ' \\ |" ;; esac
[[ $TITLE =~ [[:cntrl:]] ]] && die "--title 不可含換行或控制字元"
SCHEMAS="$KIT/../game-art-kit/schemas"
[ -f "$SCHEMAS/validate.mjs" ] || die "找不到 $SCHEMAS/validate.mjs(stack-pixi 需要與 game-art-kit 放在同一層 skills 目錄)"

mkdir -p "$DIR"
cp -R "$KIT/template/." "$DIR/"
rm -rf "$DIR/optional"
mv "$DIR/gitignore" "$DIR/.gitignore"
mkdir -p "$DIR/scripts/schemas"
cp "$SCHEMAS/validate.mjs" "$SCHEMAS/assets.schema.json" "$SCHEMAS/needs.schema.json" "$DIR/scripts/schemas/"
if [ "$NET" = ws ]; then mkdir -p "$DIR/src/services/net"; cp "$KIT/template/optional/net/"* "$DIR/src/services/net/"; fi
if [ $IFRAME = 1 ]; then mkdir -p "$DIR/src/services/iframe"; cp "$KIT/template/optional/iframe/"* "$DIR/src/services/iframe/"; fi
# 取代佔位(只動文字檔)
repl "$DIR/package.json" __NAME__ "$NAME"
repl "$DIR/package-lock.json" __NAME__ "$NAME"
repl "$DIR/index.html" __TITLE__ "$TITLE"
repl "$DIR/src/i18n/en.ts" __TITLE__ "$TITLE"
repl "$DIR/src/config/design.ts" __DESIGN_W__ "$W" __DESIGN_H__ "$H"
if [ $INSTALL = 1 ]; then
  (cd "$DIR" && npm ci --no-audit --no-fund --loglevel=error)
fi
node -e 'const [dir,design,net,iframe]=process.argv.slice(1);console.log(JSON.stringify({ok:true,dir,design,net,iframe:iframe==="1"}))' "$DIR" "${W}x${H}" "${NET:-none}" "$IFRAME"
echo "下一步:填 docs/performance-budgets.md 的 __佔位__(依簡報;推定值標「(推定)」),再跑 new-pixi.sh --check" >&2
