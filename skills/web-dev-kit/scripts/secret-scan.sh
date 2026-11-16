#!/bin/bash
# 用法:secret-scan.sh <name>
# 只掃 scope.sh check 最近一次列為 IN 的檔案(被 .gitignore 排除的檔案不在 git status 內,不掃)。
# 印命中行(值以 *** 遮蔽)與 hits=<數量>;hits > 0 結束碼 1。
source "$(dirname "$0")/_common.sh"

[ $# -eq 1 ] || die "用法:secret-scan.sh <name>"
NAME="$1"; check_name "$NAME"
ND="$(name_dir "$NAME")"
[ -f "$ND/scope.in" ] || die "先執行 scope.sh snapshot 與 scope.sh check $NAME <可寫路徑>..."
ROOT="$(cd "$(git rev-parse --show-toplevel)" && pwd -P)"

# 讀最近一次 scope.sh check 列為 IN(新增或改變、未刪除)的檔案
FILES="$(cat "$ND/scope.in")"

HITS=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    *_test.go|*.test.ts|*.test.tsx|*.spec.ts|*.spec.tsx|*.env.example|.env.example) continue ;;
  esac
  [ -f "$ROOT/$f" ] || continue
  out="$(perl -ne '
    BEGIN { $n = 0 }
    my $line = $_; my $hit = 0;
    # 排除:dev / test / example / changeme 開頭的值
    my $fake = qr/^(dev|test|example|changeme)/i;
    if ($line =~ /NEXT_PUBLIC_[A-Z_]*(SECRET|KEY|TOKEN|PASSWORD)/) { $hit = 1 }
    while ($line =~ /(?i:secret|password|passwd|api[_-]?key|token|private[_-]?key)\s*[:=]\s*["\x27]([^"\x27]{8,})["\x27]/g) {
      $hit = 1 unless $1 =~ $fake;
    }
    $hit = 1 if $line =~ /-----BEGIN [A-Z ]*PRIVATE KEY-----/;
    $hit = 1 if $line =~ /sk-[A-Za-z0-9]{20,}/ && $line !~ /sk-(dev|test|example)/;
    $hit = 1 if $line =~ /AKIA[0-9A-Z]{16}/;
    if ($hit) {
      (my $m = $line) =~ s/(["\x27])[^"\x27]{4,}(["\x27])/$1***$2/g;
      $m =~ s/(sk-|AKIA)[A-Za-z0-9]+/$1***/g;
      chomp $m; print "$ARGV:$.: $m\n";
    }
  ' "$ROOT/$f")"
  if [ -n "$out" ]; then
    echo "$out"
    HITS=$((HITS + $(printf '%s\n' "$out" | wc -l | tr -d ' ')))
  fi
done <<EOF
$FILES
EOF

echo "hits=$HITS"
[ "$HITS" -eq 0 ]
