#!/bin/bash
# 用法:scope.sh snapshot <name>
#       scope.sh check <name> [<可寫路徑>...]
# 在專案根目錄(git repo 內)執行。check 列出相對基準「新增、內容改變、或消失」的項目:
#   IN / OUT          可寫路徑內 / 外的新增或改變
#   IN-DEL / OUT-DEL  可寫路徑內 / 外的消失(被刪除,或被還原回 HEAD 而從 git status 消失)
# 最後印 out=<數量>;out > 0 結束碼 1。零個可寫路徑時任何變動都算 OUT。
source "$(dirname "$0")/_common.sh"

[ $# -ge 2 ] || die "用法:scope.sh snapshot <name> | scope.sh check <name> [<可寫路徑>...]"
MODE="$1"; NAME="$2"; shift 2
check_name "$NAME"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "目前目錄不是 git repo"
ROOT="$(cd "$(git rev-parse --show-toplevel)" && pwd -P)"
ND="$(name_dir "$NAME")"; mkdir -p "$ND"
BASE="$ND/scope.base"

# 列出目前 git status 的每個路徑與狀態雜湊:<雜湊>\t<路徑>
current_state() {
  ( cd "$ROOT"
    git -c core.quotepath=off status --porcelain=v1 -uall -z | perl -0 -ne '
      chomp;
      if (/^R. |^C. /) { $rename = 1; print substr($_,3), "\n"; next }
      if ($rename) { $rename = 0; print $_, "\n"; next }   # 改名的來源路徑
      print substr($_,3), "\n" if length($_) > 3;
    ' | sort -u | while IFS= read -r p; do
      if [ -f "$p" ] || [ -L "$p" ]; then
        h="$(shasum "$p" 2>/dev/null | cut -c1-40)"
      else
        h="DELETED"
      fi
      printf '%s\t%s\n' "$h" "$p"
    done )
}

ignored() {
  case "$1" in
    */.next/*|.next/*|*/node_modules/*|node_modules/*) return 0 ;;
  esac
  case "$ROOT/$1" in "$KIT_TMP"/*) return 0 ;; esac
  return 1
}

if [ "$MODE" = "snapshot" ]; then
  current_state > "$BASE"
  echo "snapshot=$BASE entries=$(wc -l < "$BASE" | tr -d ' ')"
  exit 0
fi

[ "$MODE" = "check" ] || die "未知模式:$MODE"
[ -f "$BASE" ] || die "沒有基準,先執行 scope.sh snapshot $NAME"

# 可寫路徑轉成相對 repo 根目錄、去掉結尾斜線
PREFIXES=()
for w in "$@"; do
  w="${w%/}"; w="${w#./}"
  if [ -d "$(dirname "$w")" ]; then
    abs="$(cd "$(dirname "$w")" && pwd -P)/$(basename "$w")"
  else
    abs="$(pwd -P)/$w"
  fi
  abs="${abs%/.}"
  PREFIXES+=("${abs#$ROOT/}")
done

in_scope() {
  local p="$1" w
  [ ${#PREFIXES[@]} -eq 0 ] && return 1
  for w in "${PREFIXES[@]}"; do
    [ "$p" = "$w" ] && return 0
    case "$p" in "$w"/*) return 0 ;; esac
  done
  return 1
}

NOW="$ND/scope.now"
current_state > "$NOW"

OUT=0; INN=0
INLIST="$ND/scope.in"; : > "$INLIST"
# 合併所有路徑
ALL="$( (cut -f2- "$BASE"; cut -f2- "$NOW") | sort -u )"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  ignored "$p" && continue
  b="$(awk -F'\t' -v p="$p" '$2==p{print $1; exit}' "$BASE")"
  n="$(awk -F'\t' -v p="$p" '$2==p{print $1; exit}' "$NOW")"
  [ "$b" = "$n" ] && continue
  if [ -z "$n" ] || [ "$n" = "DELETED" ]; then tag="DEL"; else tag=""; fi
  if in_scope "$p"; then
    echo "IN${tag:+-$tag} $p"; INN=$((INN + 1))
    [ -z "$tag" ] && printf '%s\n' "$p" >> "$INLIST"
  else
    echo "OUT${tag:+-$tag} $p"; OUT=$((OUT + 1))
  fi
done <<EOF
$ALL
EOF

echo "in=$INN out=$OUT"
[ "$OUT" -eq 0 ]
