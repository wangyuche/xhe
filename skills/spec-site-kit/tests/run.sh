#!/usr/bin/env bash
# spec-site-kit 自我測試:在暫存 git repo 建假專案,跑 check / merge / render / sample(有 Chrome 時加截圖)。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; S="$HERE/../scripts"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/spec-site-kit-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0; skip=0
ok() { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1"; echo "      ${2:-}" | head -c 1500; echo; fail=$((fail+1)); }
skp() { echo "SKIP  $1"; skip=$((skip+1)); }
# expect <名稱> <預期結束碼> <輸出需含(可空)> -- 指令…
expect() {
  local name="$1" want="$2" grepfor="$3"; shift 4
  local out rc; out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ] && { [ -z "$grepfor" ] || printf '%s' "$out" | grep -qF -- "$grepfor"; }; then ok "$name"; else bad "$name" "rc=$rc 預期 $want;$out"; fi
}
# jset <檔> <JS 運算式,變數 j 是內容>
jset() { node -e 'const fs=require("fs");const f=process.argv[1];const j=JSON.parse(fs.readFileSync(f,"utf8"));(new Function("j",process.argv[2]))(j);fs.writeFileSync(f,JSON.stringify(j,null,2));' "$1" "$2"; }

R="$WORK/proj"; mkdir -p "$R/docs/specs" "$R/server" "$R/web" "$R/tests" "$R/agents"
cd "$R" && git init -q && git config user.email t@example.com && git config user.name t
printf '# 每日獎勵\n\n## FR-090 每日領取\n每天一次。\n\n## FR-091A 補領\n不做(backlog)。\n\n## FR-092 排行\n還沒做。關鍵字 leaderboardzz\n' > docs/specs/m04.md
printf 'package daily\n\n// FR-090\nfunc Claim() {}\n' > server/claim.go
printf 'export function showReward() {}\n' > web/reward.ts
printf 'import com.example.internal.Billing\n' > web/app.local.ts
printf 'test("FR-090 server", () => {})\n' > tests/claim.test.ts
printf 'test("FR-090 web", () => {})\n' > tests/reward.test.ts
printf -- '---\nname: x-agent\n---\n你是 x-agent。\n' > agents/x-agent.md
printf '# 假專案\n' > README.md
for i in $(seq 1 50); do echo "line $i"; done > docs/long.md
git add -A && git commit -qm init
H="$(git rev-parse HEAD)"
OUT="$R/docs/spec-site"; P="$OUT/parts"; mkdir -p "$P"

cat > "$P/_project.json" <<JSON
{"kit":"spec-site-kit/1","commit":"$H","product":{"name":"假專案","summary":"測試用。","scope":"全部","no_spec_docs":false},
 "sources_read":["README.md","docs/specs/m04.md"],
 "pending":[{"text":"補領要不要做","decider":"使用者","sources":[{"kind":"規格","path":"docs/specs/m04.md","line":6}]}],
 "flows":[{"name":"領取","steps":["進大廳","按 Claim"],"sources":[{"kind":"規格","path":"docs/specs/m04.md","line":3}]}]}
JSON
cat > "$P/m04.json" <<JSON
{"kit":"spec-site-kit/1","commit":"$H",
 "module":{"id":"m04","name":"每日獎勵","summary":"每天領金幣。","sources":[{"kind":"規格","path":"docs/specs/m04.md","line":1}]},
 "code_paths":["server/","web/","agents/"],"exclude_paths":["docs/"],
 "features":[
  {"id":"FR-090","name":"每日領取","summary":"每天可領一次。","sides":["後端","玩家端"],"status":"已完成","sources":[
    {"kind":"規格","path":"docs/specs/m04.md","line":3},
    {"kind":"程式","path":"server/claim.go","line":4,"side":"後端","keyword":"Claim"},
    {"kind":"程式","path":"web/reward.ts","line":1,"side":"玩家端","keyword":"showReward"},
    {"kind":"測試","path":"tests/claim.test.ts","line":1,"side":"後端","match":"引用編號"},
    {"kind":"測試","path":"tests/reward.test.ts","line":1,"side":"玩家端","match":"引用編號"}]},
  {"id":"FR-091A","name":"補領","summary":"漏領補發。","sides":["後端"],"status":"不做","reason":"backlog","sources":[{"kind":"規格","path":"docs/specs/m04.md","line":6}]},
  {"id":"FR-092","name":"排行","summary":"排行榜。","sides":["玩家端"],"status":"未開始","keywords":["leaderboardzz"],"sources":[{"kind":"規格","path":"docs/specs/m04.md","line":9}]}
 ],
 "mismatches":[{"text":"進度說已合併,程式找不到","doc":[{"kind":"規格","path":"docs/specs/m04.md","line":9}],"code":[],"keywords":["leaderboardzz"]}]}
JSON
cp "$P/m04.json" "$WORK/m04.good.json"
C() { node "$S/check.mjs" "$@"; }

# ---- self-test ----
if [ -x "${CHROME_PATH:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}" ]; then
  expect "self-test:kit、shot.mjs、Chrome 都在" 0 '"ok":true' -- C --self-test
else
  expect "self-test:沒有 Chrome 回 1 並說明" 1 '找不到 Google Chrome' -- C --self-test
fi
expect "self-test:--shot 指到不存在的檔 → 1" 1 '找不到 web-dev-kit 的 shot.mjs' -- C --self-test --shot /nope/shot.mjs
expect "self-test:Chrome 路徑不存在 → 1" 1 '找不到 Google Chrome' -- env CHROME_PATH=/nope/chrome node "$S/check.mjs" --self-test

# ---- part ----
expect "part:正確的模組通過" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
expect "part:_project.json 自己也能檢查" 0 '"ok":true' -- C --part "$P/_project.json" --root "$R"
mv "$P/_project.json" "$WORK/pj"
expect "part:沒有 _project.json(分批只寫 parts)也能檢查" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
expect "part:沒有 _project.json 時 --no-spec-docs 生效" 1 'no_spec_docs' -- C --part "$P/m04.json" --root "$R" --no-spec-docs
mv "$WORK/pj" "$P/_project.json"

jset "$P/m04.json" 'j.features[0].sources.splice(4,1)'
expect "part:已完成但玩家端缺測試 → 1" 1 '缺測試來源:玩家端' -- C --part "$P/m04.json" --root "$R"
jset "$P/m04.json" 'j.features[0].status="已實作未測"'
expect "part:缺一端測試時已實作未測通過" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].status="已實作未測"'
expect "part:每端都有測試又沒限制卻判已實作未測 → 1" 1 '應判「已完成」' -- C --part "$P/m04.json" --root "$R"
jset "$P/m04.json" 'j.features[0].notes=[{"type":"限制","text":"只有預覽","sources":[{"kind":"規格","path":"docs/specs/m04.md","line":4}]}]'
expect "part:有限制備註時已實作未測通過" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
jset "$P/m04.json" 'j.features[0].status="已完成"'
expect "part:有限制備註卻判已完成 → 1" 1 '狀態最多「已實作未測」' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].sources.splice(2,1);j.features[0].sources.splice(3,1);j.features[0].status="已實作未測"'
expect "part:只有部分端有程式卻判已實作未測 → 1" 1 '應判「無法判定」' -- C --part "$P/m04.json" --root "$R"

cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[2].keywords=["Claim"]'
expect "part:未開始的關鍵字在程式找得到 → 1" 1 '在程式搜尋範圍內找得到' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"
expect "part:關鍵字只在規格文件(排除路徑)裡 → 通過" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
jset "$P/m04.json" 'j.features[2].keywords=["x-agent"]'
expect "part:xhe 型:agents/x-agent.md 存在卻標未開始 → 1" 1 'agents/x-agent.md' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'delete j.features[2].keywords'
expect "part:未開始沒附關鍵字 → 1" 1 '要附搜尋過的 keywords' -- C --part "$P/m04.json" --root "$R"

cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].sources[1].line=99'
expect "part:行號超出 → 1" 1 '超出檔案行數' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].sources[2].keyword="noSuchFn"'
expect "part:程式來源的 keyword 不在那幾行 → 1" 1 '找不到「noSuchFn」' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].sources[1].line=3'
expect "part:keyword 在下一行也不行(要剛好在那一行)→ 1" 1 '找不到「Claim」' -- C --part "$P/m04.json" --root "$R"
jset "$P/m04.json" 'j.features[0].sources[1].end=4'
expect "part:有 end 時在範圍內就通過" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].sources[1].end=2'
OUTX="$(C --part "$P/m04.json" --root "$R")"
[ "$(printf '%s' "$OUTX" | grep -o 'sources\[1\]' | wc -l | tr -d ' ')" = "1" ] && ok "part:行範圍不合法時只報一個錯" || bad "part:重複報錯" "$OUTX"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'delete j.features[0].sources[1].keyword'
expect "part:程式來源沒附 keyword → 1" 1 '程式來源要附 keyword' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].sources[3].path="README.md"'
expect "part:引用編號的測試那幾行沒有功能編號 → 1" 1 '找不到「FR-090」' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].sources.splice(3,2,{"kind":"測試","path":"tests/claim.test.ts","line":1,"side":"跨端","match":"引用編號"})'
expect "part:端對端測試標「跨端」涵蓋每一端" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.mismatches[0].keywords=["showReward"]'
expect "part:不一致說程式找不到,關鍵字卻在程式裡 → 1" 1 '說程式找不到' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.mismatches[0].code=[{"kind":"測試","path":"README.md","line":1,"match":"引用編號"}]'
expect "part:段落裡的引用編號測試沒附 keyword → 1" 1 '要附 keyword' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].sources[0]={"kind":"規格","path":"docs/long.md","line":1,"end":40}'
expect "part:行範圍剛好 40 行通過" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
jset "$P/m04.json" 'j.features[0].sources[0].end=41'
expect "part:行範圍 41 行 → 1" 1 '超過 40 行' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.rules=[{"text":"登入後回傳 token:由後端簽發的短效憑證","sources":[{"kind":"規格","path":"README.md","line":1}]}]'
expect "part:中文說明 token 規則不算秘密" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.rules=[{"text":"api_key: OPENAI_API_KEY_V2;token = ACCESS_TOKEN_TTL_3600","sources":[{"kind":"規格","path":"README.md","line":1}]}]'
expect "part:環境變數名不算秘密" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
for sec in 'token=abcd1234efgh5678ijkl' 'password: Hunter2Hunter2Hunter2' 'api_key=sk9f8a7d6s5a4d3f2g1h' 'token=abc-1234-efgh-5678'; do
  node -e 'const fs=require("fs");const f=process.argv[1];const j=JSON.parse(fs.readFileSync(f,"utf8"));j.rules=[{text:process.argv[2],sources:[{kind:"規格",path:"README.md",line:1}]}];fs.writeFileSync(f,JSON.stringify(j))' "$P/m04.json" "$sec"
  expect "part:小寫 / 混合大小寫秘密要擋:$sec" 1 '疑似秘密值' -- C --part "$P/m04.json" --root "$R"
done
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.exclude_paths=["*.md"]'
expect "part:exclude_paths 不可用 glob → 1(schema)" 1 'exclude_paths' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.rules=[{"text":"token = generateAccessToken","sources":[{"kind":"規格","path":"README.md","line":1}]}]'
expect "part:token = 函式名 不算秘密" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[2].keywords=["/home/feedzz"]'
expect "part:keyword 是 /home/ 開頭的路由不算本機路徑" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
printf 'test("FR-090A FR-0901 FR-090-2 FR-090.1 X-FR-090 另一條", () => {})\ntest("test_FR-090 claim", () => {})\ntest("X_FR-090 M04.FR-090", () => {})\ntest_FR-090_daily_claim()\n' > "$R/tests/other.test.ts"; git -C "$R" add tests/other.test.ts; git -C "$R" commit -qm other
H2="$(git -C "$R" rev-parse HEAD)"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" "j.commit=\"$H2\";j.features[0].sources[3].path=\"tests/other.test.ts\""
jset "$P/_project.json" "j.commit=\"$H2\""
expect "part:FR-090 的測試指到只有 FR-090A / FR-090-2 / FR-090.1 / X-FR-090 的行 → 1" 1 '找不到「FR-090」' -- C --part "$P/m04.json" --root "$R"
jset "$P/m04.json" 'j.features[0].sources[3].path="tests/claim.test.ts";j.features[0].notes=[{"type":"限制","text":"預覽","sources":[{"kind":"測試","path":"tests/claim.test.ts","line":1,"side":"後端","match":"引用編號"}]}];j.features[0].status="已實作未測"'
expect "part:備註裡引用編號的測試用功能編號核對" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
jset "$P/m04.json" 'j.features[0].notes[0].sources[0].path="tests/other.test.ts";j.features[0].notes[0].sources[0].line=2'
expect "part:test_FR-090 算引用 FR-090" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
jset "$P/m04.json" 'j.features[0].notes[0].sources[0].line=3'
expect "part:X_FR-090 / M04.FR-090 不算引用 FR-090 → 1" 1 '找不到「FR-090」' -- C --part "$P/m04.json" --root "$R"
jset "$P/m04.json" 'j.features[0].notes[0].sources[0].line=2;j.features[0].notes[0].sources[0].keyword="FR-0901"'
expect "part:功能內引用編號一律核對自己的編號(keyword 換不掉)" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
jset "$P/m04.json" 'j.features[0].notes[0].sources[0].line=4'
expect "part:test_FR-090_daily_claim 算引用 FR-090" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" "j.commit=\"$H2\";j.mismatches[0].code=[{\"kind\":\"測試\",\"path\":\"tests/other.test.ts\",\"line\":1,\"match\":\"引用編號\",\"keyword\":\"FR-090\"}]"
expect "part:段落裡引用編號 + keyword 也套邊界 → 1" 1 '找不到「FR-090」' -- C --part "$P/m04.json" --root "$R"
git -C "$R" reset -q --hard HEAD~1; H="$(git -C "$R" rev-parse HEAD)"
jset "$P/_project.json" "j.commit=\"$H\""
cp "$WORK/m04.good.json" "$P/m04.json"
printf 'x\n' > "$R/server/untracked.go"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].sources[1].path="server/untracked.go";j.features[0].sources[1].line=1'
expect "part:未追蹤檔 → 1" 1 '不在 git 追蹤中' -- C --part "$P/m04.json" --root "$R"
rm "$R/server/untracked.go"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].sources[1].path="../etc/passwd"'
expect "part:路徑含 .. → 1(schema)" 1 'path' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].sources[1].path="./server/claim.go"'
expect "part:路徑 ./ 開頭 → 1(schema)" 1 'path' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.code_paths=["."];j.exclude_paths=["docs/","README.md"];j.features[2].keywords=["leaderboardzz"]'
expect "part:code_paths「.」= 整個 repo" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
mkdir -p "$R/server/newmod" && printf 'package newmod\n' > "$R/server/newmod/a.go"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.code_paths.push("server/newmod/")'
expect "part:code_paths 指到還沒 commit 的新目錄也可以" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
rm -rf "$R/server/newmod"
cp "$WORK/m04.good.json" "$WORK/loose.json"
expect "part:part 不在 parts/ 底下 → 1" 1 '要放在 <輸出目錄>/parts/' -- C --part "$WORK/loose.json" --root "$R"
printf 'func Leaderboardzz() {}\n' > "$R/server/new.go"
cp "$WORK/m04.good.json" "$P/m04.json"
expect "part:未 commit 的新檔裡有關鍵字也不能判未開始 → 1" 1 'server/new.go' -- C --part "$P/m04.json" --root "$R"
rm "$R/server/new.go"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].sources[1].line=20;j.features[0].sources[1].end=25'
OUTX="$(C --part "$P/m04.json" --root "$R")"
[ "$(printf '%s' "$OUTX" | grep -o 'sources\[1\]' | wc -l | tr -d ' ')" = "1" ] && ok "part:line 與 end 都超出只報一條" || bad "part:超出重複報錯" "$OUTX"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].sources[3].match="關鍵字"'
expect "part:測試 match 關鍵字沒附 keyword → 1" 1 '要附 keyword' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].sources[1].side="後台"'
expect "part:side 不在 sides → 1" 1 '不在 sides' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].summary="設定在 /Users/someone/x.txt"'
expect "part:本機絕對路徑 → 1" 1 '本機絕對路徑' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].summary="設定在/Users/someone/x.txt"'
expect "part:緊接中文的本機路徑 → 1" 1 '本機絕對路徑' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[2].keywords=["/Users/someone/.config/x"]'
expect "part:keyword 裡的 /Users 路徑 → 1" 1 '本機絕對路徑' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].summary="連 comfy.local:8188 出圖"'
expect "part:內網主機名 → 1" 1 '內網主機名' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].sources[2].path="web/app.local.ts";j.features[0].sources[2].line=1;j.features[0].sources[2].keyword="com.example.internal.Billing"'
expect "part:檔名 .local、keyword 套件名 .internal 不算內網主機名" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[2].keywords=["/private/ordersz","/tmp/uploadz"]'
expect "part:keyword 是 /private、/tmp 路由放行" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[2].sources.push({"kind":"測試","path":"tests/claim.test.ts","line":1,"side":"玩家端","match":"關鍵字","keyword":"FR-090"})'
expect "part:未開始卻有測試來源 → 1" 1 '未開始不可有測試來源' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].summary="連 192.168.1.20:8188"'
expect "part:私有 IP → 1" 1 '私有 IP' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].summary="token=ghp_abcdefghijklmnopqrstuvwxyz0123"'
expect "part:秘密樣式 → 1" 1 'GitHub token' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[1].status="不做";delete j.features[1].reason'
expect "part:不做沒寫原因 → 1" 1 '不做要寫 reason' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features[0].status="做好了"'
expect "part:狀態值不合法 → 1" 1 '已完成' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.mismatches[0].keywords=[]'
expect "part:不一致的程式那邊沒來源也沒關鍵字 → 1" 1 '程式那一邊要附來源' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"
jset "$P/_project.json" 'j.product.no_spec_docs=true'
expect "part:no_spec_docs 時已完成 / 未開始 → 1" 1 'no_spec_docs' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"; jset "$P/m04.json" 'j.features=[j.features[0]];j.features[0].status="已實作未測";j.mismatches=[]'
expect "part:no_spec_docs 時每端有測試也能判已實作未測" 0 '"ok":true' -- C --part "$P/m04.json" --root "$R"
cp "$WORK/m04.good.json" "$P/m04.json"
jset "$P/_project.json" 'j.product.no_spec_docs=false'

# ---- merge ----
cp "$P/m04.json" "$P/m05.json"; jset "$P/m05.json" 'j.module.id="m05";j.module.name="信箱";j.features=[{"id":"FR-100","name":"收信","summary":"看信。","sides":["玩家端"],"status":"無法判定","reason":"對不上","sources":[]}];j.mismatches=[]'
jset "$P/m05.json" 'j.module.order=1'; jset "$P/m04.json" 'j.module.order=2'
jset "$P/m05.json" 'j.commit="0000000000000000000000000000000000000000"'
expect "merge:part 的 commit 不是 HEAD → 1,列出要重做的模組" 1 '要重做:m05' -- node "$S/merge.mjs" "$OUT"
[ ! -e "$OUT/spec.json" ] && ok "merge:失敗時不寫 spec.json" || bad "merge:失敗時不寫 spec.json"
echo '{"kit":"spec-site-kit/1"}' > "$OUT/spec.json"; echo '<meta name="generator" content="spec-site-kit/1">' > "$OUT/index.html"
expect "merge:失敗時刪掉上一輪的 spec.json / index.html" 1 '已刪除上一輪的' -- node "$S/merge.mjs" "$OUT"
[ ! -e "$OUT/spec.json" ] && [ ! -e "$OUT/index.html" ] && ok "merge:舊檔確實刪除" || bad "merge:舊檔還在"
echo '<p>手寫</p>' > "$OUT/index.html"
expect "merge:失敗時不刪非本 kit 的 index.html" 1 '不是本 kit 產生的' -- node "$S/merge.mjs" "$OUT"
[ -e "$OUT/index.html" ] && ok "merge:手寫 index.html 還在" || bad "merge:手寫 index.html 被刪"
rm -f "$OUT/index.html"
jset "$P/m05.json" "j.commit=\"$H\""
expect "merge:成功,統計 4 項" 0 '"total":4' -- node "$S/merge.mjs" "$OUT"
expect "spec:check 通過" 0 '"ok":true' -- C "$OUT/spec.json" --root "$R"
cp "$OUT/spec.json" "$WORK/spec.good.json"
node -e 'const j=require(process.argv[1]);process.exit(j.modules.map(m=>m.module.id).join()==="m05,m04"?0:1)' "$OUT/spec.json" && ok "merge:依 module.order 排序" || bad "merge:排序"
jset "$OUT/spec.json" 'j.project.mismatches=[{"text":"專案層不一致","doc":[{"kind":"規格","path":"README.md","line":1}],"code":[],"keywords":["Claim"]}]'
expect "spec:專案層不一致的關鍵字逐模組驗證 → 1" 1 '說程式找不到' -- C "$OUT/spec.json" --root "$R"
cp "$WORK/spec.good.json" "$OUT/spec.json"
jset "$OUT/spec.json" 'j.modules[0].code_paths=["server/"];j.modules[0].exclude_paths=["docs/","web/"];j.modules[1].code_paths=["web/"];j.project.mismatches=[{"text":"x","doc":[{"kind":"規格","path":"README.md","line":1}],"code":[],"keywords":["showReward"]}]'
expect "spec:A 模組排除的路徑是 B 模組的程式,仍會搜到 → 1" 1 '說程式找不到' -- C "$OUT/spec.json" --root "$R"
cp "$WORK/spec.good.json" "$OUT/spec.json"
jset "$OUT/spec.json" 'const m=j.modules.find(x=>x.module.id==="m04");m.code_paths=["agents/"];const f=m.features.find(x=>x.id==="FR-092");f.keywords=["showReward"];const o=j.modules.find(x=>x.module.id==="m05");o.code_paths=["web/"]'
expect "spec:未開始的關鍵字在別的模組程式裡 → 1" 1 '在程式搜尋範圍內找得到' -- C "$OUT/spec.json" --root "$R"
cp "$WORK/spec.good.json" "$OUT/spec.json"
jset "$OUT/spec.json" 'j.stats["已完成"]=3'
expect "spec:統計對不上 → 1" 1 'stats.已完成' -- C "$OUT/spec.json" --root "$R"
cp "$WORK/spec.good.json" "$OUT/spec.json"; jset "$OUT/spec.json" 'j.modules[0].features[0].id="FR-090"'
expect "spec:跨模組功能編號重複 → 1" 1 '功能編號重複:FR-090' -- C "$OUT/spec.json" --root "$R"
cp "$WORK/spec.good.json" "$OUT/spec.json"
grep -q '"dirty": false' "$OUT/spec.json" && ok "merge:只有輸出目錄有變動時 dirty=false" || bad "merge:dirty" "$(grep dirty "$OUT/spec.json")"

# ---- render ----
expect "render:產出 index.html" 0 '"ok":true' -- node "$S/render.mjs" "$OUT/spec.json"
expect "html:check --html 通過" 0 '"ok":true' -- C --html "$OUT/index.html"
grep -q '(Claim)' "$OUT/index.html" && grep -q 'FR-091A' "$OUT/index.html" && grep -q '由使用者決定(1)' "$OUT/index.html" && grep -q '搜尋過 <code>leaderboardzz</code>' "$OUT/index.html" && ok "render:功能、待決分類、不一致都在頁面上" || bad "render:內容"
jset "$OUT/spec.json" 'j.project.product.summary="改過"'
expect "html:spec.json 改過沒重新 render → 1" 1 'spec-sha256 與目前 spec.json 不符' -- C --html "$OUT/index.html"
cp "$WORK/spec.good.json" "$OUT/spec.json"; node "$S/render.mjs" "$OUT/spec.json" >/dev/null
printf '<script>x</script>' >> "$OUT/index.html"
expect "html:含 script → 1" 1 '不可含 <script>' -- C --html "$OUT/index.html"
node "$S/render.mjs" "$OUT/spec.json" >/dev/null; sed -i.bak 's/<body>/<body onload="x()">/' "$OUT/index.html"; rm -f "$OUT/index.html.bak"
expect "html:含 onload → 1" 1 'on* 事件屬性' -- C --html "$OUT/index.html"
node "$S/render.mjs" "$OUT/spec.json" >/dev/null
jset "$OUT/spec.json" 'j.project.product.summary="背景用 CSS url(bg.png),主題用 @import 拆檔,圖 src=https://example.com/a.png"'; node "$S/render.mjs" "$OUT/spec.json" >/dev/null
expect "html:正文提到 url( / @import / src=https 不誤判" 0 '"ok":true' -- C --html "$OUT/index.html"
jset "$OUT/spec.json" 'j.project.product.name="<b>x</b>"'; node "$S/render.mjs" "$OUT/spec.json" >/dev/null
grep -q '&lt;b&gt;x&lt;/b&gt;' "$OUT/index.html" && ok "render:HTML 跳脫" || bad "render:跳脫"
cp "$WORK/spec.good.json" "$OUT/spec.json"; node "$S/render.mjs" "$OUT/spec.json" >/dev/null

# ---- sample ----
a="$(node "$S/sample.mjs" "$OUT/spec.json")"; b="$(node "$S/sample.mjs" "$OUT/spec.json")"
[ "$a" = "$b" ] && echo "$a" | grep -q "\"seed\":\"$H:1\"" && ok "sample:同一輪結果可重現,種子 = commit:輪次" || bad "sample:重現" "$a"
r2="$(node "$S/sample.mjs" "$OUT/spec.json" --round 2)"
echo "$r2" | grep -q '"excluded":\["FR-090","FR-092"\]' && echo "$r2" | grep -q '"picks":\[\]' && ok "sample:第 2 輪排除第 1 輪抽過的" || bad "sample:第 2 輪" "$r2"
echo "$a" | grep -q '"shortfall":\["已完成 只剩 1 條可抽(要 5)","未開始 只剩 1 條可抽(要 3)"\]' && ok "sample:不足時 shortfall 說明" || bad "sample:shortfall" "$a"
expect "sample:輪次不合法 → 2" 2 '' -- node "$S/sample.mjs" "$OUT/spec.json" --round 0
echo '{"commit":"x"}' > "$WORK/badspec.json"
expect "sample:格式錯的 spec → 1 並輸出 JSON" 1 '"ok":false' -- node "$S/sample.mjs" "$WORK/badspec.json"

# ---- SHA-256 repo、輸出目錄 = 專案根 ----
R2="$WORK/sha256"; mkdir -p "$R2"
if git -C "$R2" init -q --object-format=sha256 2>/dev/null; then
  printf '# x\n' > "$R2/README.md"; git -C "$R2" add -A; git -C "$R2" -c user.email=t@example.com -c user.name=t commit -qm i
  H3="$(git -C "$R2" rev-parse HEAD)"; mkdir -p "$R2/docs/spec-site/parts"
  printf '{"kit":"spec-site-kit/1","commit":"%s","module":{"id":"m","name":"m","summary":"s","sources":[{"kind":"規格","path":"README.md","line":1}]},"code_paths":["."],"exclude_paths":["README.md"],"features":[{"id":"X-1","name":"x","summary":"x","sides":["後端"],"status":"無法判定","reason":"r","sources":[]}]}' "$H3" > "$R2/docs/spec-site/parts/m.json"
  expect "sha256 repo:64 位 commit 通過" 0 '"ok":true' -- C --part "$R2/docs/spec-site/parts/m.json" --root "$R2"
  mkdir -p "$R2/parts"; cp "$R2/docs/spec-site/parts/m.json" "$R2/parts/m.json"
  expect "輸出目錄 = 專案根 → 1 並說明" 1 '不可以是專案根' -- C --part "$R2/parts/m.json" --root "$R2"
else skp "sha256 repo:git 不支援 --object-format=sha256"; fi

# ---- 截圖(file://)----
SHOT="$S/../../web-dev-kit/scripts/shot.mjs"
if [ -x "${CHROME_PATH:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}" ] && [ -f "$SHOT" ]; then
  out="$(node "$SHOT" "file://$OUT/index.html" 390 844 "$WORK/m.png" --mobile)"; rc=$?
  [ $rc -eq 0 ] && echo "$out" | grep -q '"scrollWidth":390' && ok "shot:390 寬沒有水平捲動" || bad "shot:390" "rc=$rc $out"
  out="$(node "$SHOT" "file://$OUT/index.html" 1280 800 "$WORK/d.png")"; rc=$?
  [ $rc -eq 0 ] && echo "$out" | grep -q '"scrollWidth":1280' && ok "shot:1280 正常" || bad "shot:1280" "rc=$rc $out"
else skp "shot:沒有 Chrome 或 web-dev-kit"; fi

[ -z "$(git -C "$R" status --porcelain -- . ':(exclude)docs/spec-site')" ] && ok "整體:輸出目錄以外沒有變動" || bad "整體:有輸出目錄以外的變動" "$(git -C "$R" status --porcelain)"

echo "---"; echo "pass=$pass fail=$fail skip=$skip"
[ $fail -eq 0 ]
