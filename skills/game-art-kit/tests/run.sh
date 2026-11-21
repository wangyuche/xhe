#!/bin/bash
# game-art-kit 自我測試(離線):假 ComfyUI + 所有 workflow 骨架 + sheet.mjs + scrub-check。
# 需要 Node ≥ 22;sheet 需要 Google Chrome(沒有時 SKIP)。測完刪除暫存目錄、停掉假伺服器。
# 實機測試:另外設 COMFYUI_URL 後跑 `bash tests/run.sh --live`(只送 1 張 4 步小圖,上傳與輸出都在 temp,跑完刪 history)。
set -uo pipefail
K="$(cd "$(dirname "$0")/.." && pwd)"
C() { node "$K/scripts/comfy.mjs" "$@"; }
PASS=0; FAIL=0; SKIP=0
ok()   { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL  $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/      /' | tail -15; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP  $1"; SKIP=$((SKIP + 1)); }
W="$(mktemp -d)"; PID=""; REAL_HOME="$HOME"
cleanup() { [ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT

if [ "${1:-}" = "--live" ]; then
  c="$(C check 2>&1)" && ok "live check" || { bad "live check" "$c"; echo "pass=$PASS fail=$FAIL skip=$SKIP"; exit 1; }
  d() { echo "$c" | node -e "const d=JSON.parse(require('fs').readFileSync(0,'utf8')).defaults;console.log(d['$1']??'')"; }
  if [ -n "$(d qwen_unet)" ]; then
    r="$(C run "$K/workflows/qwen-t2i.json" --out "$W/live" --name live --set unet="$(d qwen_unet)" --set clip="$(d qwen_clip)" --set vae="$(d qwen_vae)" \
      --set lora="$( [ -n "$(d qwen_lightning)" ] && d qwen_lightning || echo none)" --set lora_strength=1 --set shift=3.1 --set "prompt=a red apple on a table" --set negative= \
      --set width=512 --set height=512 --set seed=1 --set steps=4 --set cfg=1 --set sampler=euler --set scheduler=simple 2>&1)" \
      && [ "$(C pngsize "$W/live/live.png")" = '{"width":512,"height":512}' ] && ok "live qwen-t2i 512×512" || bad "live qwen-t2i" "$r"
  else skip "live qwen-t2i(這台沒有 Qwen-Image)"; fi
  echo "---"; echo "pass=$PASS fail=$FAIL skip=$SKIP"; [ "$FAIL" -eq 0 ]; exit
fi

PORT=$((20000 + RANDOM % 20000))
node "$K/tests/fake-comfy.mjs" "$PORT" "$W/req.log" > "$W/fake.out" 2>&1 & PID=$!
for i in $(seq 1 50); do grep -q listening "$W/fake.out" 2>/dev/null && break; sleep 0.1; done
export COMFYUI_URL="http://127.0.0.1:$PORT"
export HOME="$W/home"; mkdir -p "$HOME"   # 不讀使用者的 ~/.config

# 1. 位址解析
o="$(env -u COMFYUI_URL node "$K/scripts/comfy.mjs" check 2>&1)"; [ $? -eq 2 ] && echo "$o" | grep -q '找不到 ComfyUI 位址' && ok "沒有位址 → 結束碼 2 並附設定方式" || bad "沒有位址" "$o"
mkdir -p "$HOME/.config/game-art-kit"; printf 'export COMFYUI_URL="http://127.0.0.1:%s"  # 區網主機\n' "$PORT" > "$HOME/.config/game-art-kit/config"
o="$(env -u COMFYUI_URL node "$K/scripts/comfy.mjs" check 2>&1)" && ok "從 ~/.config/game-art-kit/config 讀位址(export、引號、註解)" || bad "讀設定檔" "$o"
o="$(C check --url http://127.0.0.1:1 2>&1)"; [ $? -eq 5 ] && ok "--url 覆寫優先、連不上 → 結束碼 5" || bad "--url 覆寫" "$o"
for bu in 192.168.1.20:8188 comfy:8188 ftp://x:1; do
  o="$(C check --url "$bu" 2>&1)"; rc=$?; [ $rc -eq 2 ] && echo "$o" | grep -q '格式錯誤' && ok "位址 $bu 格式錯誤 → 結束碼 2" || bad "位址格式 $bu" "rc=$rc $o"
  o="$(C scrub-check "$K" --url "$bu" 2>&1)"; [ $? -eq 2 ] || bad "scrub-check 位址格式 $bu" "$o"
done

# 2. check
c="$(C check)"
echo "$c" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));const m=d.consistency_methods.map(x=>x.method);process.exit(m.includes("qwen-image-edit")&&!m.includes("flux-kontext")&&d.workflows_available["qwen-t2i"]&&d.workflows_available["qwen-edit-3ref"]===true&&d.workflows_available["flux-t2i"]===true?0:1)' \
  && ok "check:依節點與模型判斷一致性方法(有 Qwen-Edit 1–3 參考、沒有 Kontext;flux-t2i 可用)" || bad "check 方法判斷" "$c"
echo "$c" | grep -q '"family": "qwen-image-edit"' && ! echo "$c" | grep -q '"family": "sdxl"' && echo "$c" | grep -q '"name": "t5xxl_fp8_e4m3fn.safetensors",' && ok "check:依檔名推斷模型家族(t5xxl 不誤判成 SDXL)" || bad "check 家族" "$c"

# 3. 骨架:每個都能填、送出、拿回正確尺寸
QS=(--set unet=u --set clip=c --set vae=v --set lora=none --set lora_strength=1 --set shift=3 --set prompt=p --set negative=n --set seed=1 --set steps=4 --set cfg=1 --set sampler=euler --set scheduler=simple)
FS=(--set unet=u --set clip_l=a --set t5=b --set vae=v --set guidance=3 --set prompt=p --set seed=1 --set steps=4 --set sampler=euler --set scheduler=simple)
r="$(C run "$K/workflows/qwen-t2i.json" --out "$W/o" --name q1 "${QS[@]}" --set width=96 --set height=64)" && [ "$(C pngsize "$W/o/q1.png")" = '{"width":96,"height":64}' ] \
  && ok "qwen-t2i:輸出尺寸等於設定" || bad "qwen-t2i" "$r"
grep -q '"LoraLoaderModelOnly"' "$W/o/workflows/q1.json" && bad "lora=none 應拿掉 LoRA 節點" || ok "lora=none 拿掉 LoRA 節點並重接 model"
for n in 1 2 3; do
  refs=(); for i in $(seq 1 $n); do refs+=(--set "ref$i=r$i.png [temp]"); done
  r="$(C run "$K/workflows/qwen-edit-${n}ref.json" --out "$W/o" --name e$n "${QS[@]}" --set width=64 --set height=64 "${refs[@]}")" && ok "qwen-edit-${n}ref 送出成功" || bad "qwen-edit-${n}ref" "$r"
done
r="$(C run "$K/workflows/flux-t2i.json" --out "$W/o" --name f1 "${FS[@]}" --set width=64 --set height=64)" && ok "flux-t2i 送出成功" || bad "flux-t2i" "$r"
r="$(C run "$K/workflows/flux-kontext.json" --out "$W/o" --name k1 "${FS[@]}" --set 'ref1=r.png [temp]')" && ok "flux-kontext 送出成功" || bad "flux-kontext" "$r"
r="$(C run "$K/workflows/zimage-t2i.json" --out "$W/o" --name z1 --set unet=u --set clip=c --set vae=v --set shift=3 --set prompt=p --set negative=n --set seed=1 --set steps=4 --set cfg=1 --set sampler=euler --set scheduler=simple --set width=64 --set height=64)" && ok "zimage-t2i 送出成功" || bad "zimage-t2i" "$r"
r="$(C run "$K/workflows/qwen-t2i-canny.json" --out "$W/o" --name c1 "${QS[@]}" --set width=64 --set height=64 --set controlnet=x --set 'control_image=s.png [temp]' --set control_strength=0.8 --set control_end=0.8)" && ok "qwen-t2i-canny 送出成功" || bad "qwen-t2i-canny" "$r"
grep -q '"path":"/history","query":{},"body":{"delete"' "$W/req.log" && ok "每張完成後刪除 history"
r="$(C run "$K/workflows/qwen-t2i.json" --out "$W/sig" --name sg "${QS[@]/prompt=p/prompt=SLOW}" --set width=64 --set height=64 --timeout 60 2>&1 & p=$!; sleep 1.5; kill -TERM $p; wait $p; echo "rc=$?")"
echo "$r" | grep -q 'rc=143' && tail -3 "$W/req.log" | grep -q '"path":"/history","query":{},"body":{"delete"' && [ ! -e "$W/sig/sg.png" ] && ok "收到 SIGTERM → 取消並刪 history 後結束(143)" || bad "SIGTERM 收尾" "$r $(tail -3 "$W/req.log")" || bad "沒刪 history" "$(tail -3 "$W/req.log")"

# 4. 參數檢查與錯誤
o="$(C run "$K/workflows/qwen-t2i.json" --out "$W/o" --name x "${QS[@]}" 2>&1)"; [ $? -eq 2 ] && echo "$o" | grep -q 'width' && ok "缺參數 → 結束碼 2 並列出" || bad "缺參數" "$o"
o="$(C run "$K/workflows/qwen-t2i.json" --out "$W/o" --name x "${QS[@]}" --set width=64 --set height=64 --set typo=1 2>&1)"; [ $? -eq 2 ] && echo "$o" | grep -q 'typo' && ok "多餘參數 → 結束碼 2" || bad "多餘參數" "$o"
o="$(C run "$K/workflows/qwen-t2i.json" --out "$W/o" --name failx "${QS[@]}" --set width=64 --set height=64 --set prompt=FAIL 2>&1)"; [ $? -eq 3 ] && [ ! -e "$W/o/workflows/failx.json" ] && ok "執行錯誤 → 結束碼 3,不留 workflow 檔" || bad "執行錯誤" "$o"
o="$(C run "$K/workflows/qwen-t2i.json" --out "$W/o" --name x "${QS[@]}" --set width=64 --set height=64 --set prompt=SLOW --timeout 2 2>&1)"; [ $? -eq 4 ] && grep -q '"path":"/interrupt","query":{},"body":{"prompt_id":"fake-' "$W/req.log" && ok "逾時 → 指定 prompt_id 中斷自己的工作、結束碼 4" || bad "逾時" "$o"
o="$(C run "$K/workflows/qwen-t2i.json" --out "$W/o" --name x "${QS[@]}" --set width=64 --set height=64 --timeout 5m 2>&1)"; [ $? -eq 2 ] && ok "--timeout 不是數字 → 結束碼 2" || bad "--timeout 檢查" "$o"
o="$(C run "$K/workflows/qwen-t2i.json" --out "$W/o" --name x "${QS[@]/seed=1/seed=18446744073709551615}" --set width=64 --set height=64 2>&1)"; [ $? -eq 2 ] && echo "$o" | grep -q seed && ok "seed 超過安全整數 → 結束碼 2" || bad "大 seed" "$o"
r="$(C run "$K/workflows/qwen-t2i.json" --out "$W/o" --name s1 "${QS[@]/negative=n/negative=0}" --set width=64 --set height=64)" && grep -q '"text": "0"' "$W/o/workflows/s1.json" && grep -q '"seed": 1,' "$W/o/workflows/s1.json" \
  && ok "只有 numeric 參數轉數字(negative=0 保持字串、seed 是數字)" || bad "參數型別" "$r $(grep -n '"text"\|"seed"' "$W/o/workflows/s1.json")"
o="$(C run "$K/workflows/qwen-t2i.json" --out "$W/o" --name x "${QS[@]/prompt=p/prompt=DROPVIEW}" --set width=64 --set height=64 2>&1)"; rc=$?
id="$(grep '"path":"/prompt"' "$W/req.log" | wc -l | tr -d ' ')"
[ $rc -eq 5 ] && grep -q "\"delete\":\[\"fake-$id\"\]" "$W/req.log" && ok "下載途中斷線 → 結束碼 5,仍刪掉自己的 history" || bad "斷線清理" "$o rc=$rc id=$id"
sed 's/"PreviewImage"/"SaveImage"/' "$K/workflows/qwen-t2i.json" > "$W/save.json"
o="$(C run "$W/save.json" --out "$W/o" --name x "${QS[@]}" --set width=64 --set height=64 2>&1)"; [ $? -eq 2 ] && ok "拒絕 SaveImage(不在伺服器留檔)" || bad "SaveImage 沒被擋" "$o"
node -e 'const g=require(process.argv[1]);g["99"]={class_type:"NoSuchNode",inputs:{}};require("fs").writeFileSync(process.argv[2],JSON.stringify(g))' "$K/workflows/qwen-t2i.json" "$W/badnode.json"
o="$(C run "$W/badnode.json" --out "$W/o" --name x "${QS[@]}" --set width=64 --set height=64 2>&1)"; [ $? -eq 3 ] && echo "$o" | grep -q NoSuchNode && ok "未知節點 → 結束碼 3 並印出 node_errors" || bad "未知節點" "$o"

# 5. upload:放 temp、檔名含雜湊
printf 'fakepng' > "$W/ref.png"
o="$(C upload "$W/ref.png" --prefix 'my game/hero')" && echo "$o" | grep -q '"loadImage":"my-game-hero-[0-9a-f]\{8\}.png \[temp\]"' && grep -q '"type":"temp"' "$W/req.log" \
  && ok "upload:上傳到 temp、檔名 <prefix>-<雜湊>" || bad "upload" "$o $(grep upload "$W/req.log")"

# 6. 產出不含位址
grep -rq "127.0.0.1:$PORT" "$W/o" && bad "workflow 產出含位址" || ok "存下的 workflow 不含 ComfyUI 位址"
o="$(C scrub-check "$W/o")" && ok "scrub-check:乾淨目錄通過" || bad "scrub-check 乾淨" "$o"
echo '{"note":"from http://192.168.1.20:8188"}' > "$W/o/leak.json"
o="$(C scrub-check "$W/o")"; [ $? -eq 1 ] && echo "$o" | grep -q 'leak.json:1' && ok "scrub-check:找到私有 IP → 結束碼 1" || bad "scrub-check 沒抓到" "$o"
rm "$W/o/leak.json"; mkdir -p "$W/s"; echo 'uses comfy.mjs run' > "$W/s/a.md"
o="$(env -u COMFYUI_URL HOME="$W/nohome" node "$K/scripts/comfy.mjs" scrub-check "$W/s")" && ok "scrub-check:沒有設定位址也照常檢查(不會結束碼 2)" || bad "scrub-check 沒位址" "$o"
o="$(C scrub-check "$W/s" --url http://comfy)" && ok "scrub-check:主機名稱 comfy 不誤中 comfy.mjs" || bad "scrub-check 主機名稱誤判" "$o"
echo 'rendered on gpu-box.tailnet.ts.net' > "$W/s/c.md"; o="$(C scrub-check "$W/s" --url http://gpu-box.tailnet.ts.net:8000)"; [ $? -eq 1 ] && echo "$o" | grep -q 'c.md' && ok "scrub-check:含點的主機名稱沒有埠號也抓得到" || bad "scrub-check 主機名稱無埠" "$o"
rm "$W/s/c.md"; echo 'peer 100.101.102.103 ok' > "$W/s/d.md"; o="$(C scrub-check "$W/s" --url http://comfy)"; [ $? -eq 1 ] && echo "$o" | grep -q 'd.md' && ok "scrub-check:Tailscale 100.64/10 位址" || bad "scrub-check 100.x" "$o"
rm "$W/s/d.md"
echo 'see http://comfy/view' > "$W/s/b.md"; o="$(C scrub-check "$W/s" --url http://comfy)"; [ $? -eq 1 ] && ok "scrub-check:--url 覆寫的主機也會檢查" || bad "scrub-check --url" "$o"

# 7. sheet.mjs
if [ -x "${CHROME_PATH:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}" ]; then
  cp "$W/o/q1.png" "$W/o/a.png"; cp "$W/o/q1.png" "$W/o/b.png"
  echo '{"title":"測試分鏡","cols":2,"cellWidth":300,"items":[{"image":"a.png","label":"01","caption":"第一格"},{"image":"b.png","label":"02","caption":"第二格","note":"備註"},{"image":"a.png","label":"03","caption":"第三格"}]}' > "$W/o/spec.json"
  o="$(HOME="$REAL_HOME" node "$K/scripts/sheet.mjs" "$W/o/spec.json" "$W/o/sheet.png" 2>&1)" && echo "$o" | grep -q '"items":3' && [ "$(C pngsize "$W/o/sheet.png" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(d.width)')" = 668 ] \
    && ok "sheet.mjs:2 欄 3 格、寬度正確" || bad "sheet.mjs" "$o"
  # 高度 = 上下 padding 48 + 標題 64 + 兩列(圖 200 + 說明 64)+ 一個間距 20 = 660(最後一列不加間距)
  [ "$(C pngsize "$W/o/sheet.png" | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).height)')" = 660 ] && ok "sheet.mjs:高度正確(最後一列不多算間距)" || bad "sheet 高度" "$(C pngsize "$W/o/sheet.png")"
  printf 'RIFFxxxxWEBPVP8X' > "$W/o/bad.webp"; printf '\0\0\0\0\0\0\0\0\0\0\0\0\0\0' >> "$W/o/bad.webp"
  node -e 'const fs=require("fs");const b=Buffer.alloc(30);b.write("RIFF",0);b.write("WEBP",8);b.write("VP8X",12);b.writeUIntLE(1023,24,3);b.writeUIntLE(511,27,3);fs.writeFileSync(process.argv[1],b)' "$W/o/x.webp"
  echo '{"cols":1,"cellWidth":300,"items":[{"image":"x.webp","caption":"webp"}]}' > "$W/o/w.json"
  o="$(HOME="$REAL_HOME" node "$K/scripts/sheet.mjs" "$W/o/w.json" "$W/o/w.png" 2>&1)"; h="$(C pngsize "$W/o/w.png" 2>/dev/null | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).height)' 2>/dev/null)"
  [ "$h" = "$((48 + 150 + 64))" ] && ok "sheet.mjs:WebP 依實際比例(1024×512 → 高 150)" || bad "sheet WebP 比例" "$o h=$h"
  echo '{"items":[{"image":"q1.png"},{"image":"nope.jpg"}]}' > "$W/o/j.json"; cp "$W/o/q1.png" "$W/o/nope.jpg"
  o="$(node "$K/scripts/sheet.mjs" "$W/o/j.json" "$W/o/j.png" 2>&1)"; [ $? -eq 2 ] && echo "$o" | grep -q '讀不出' && ok "sheet.mjs:讀不出尺寸 → 結束碼 2(不猜比例)" || bad "sheet 尺寸讀不出" "$o"
  node -e 'const fs=require("fs");const app1=Buffer.alloc(2+2+6+8+2+12+4);let o=0;app1.writeUInt16BE(0xffe1,o);o+=2;app1.writeUInt16BE(app1.length-2,o);o+=2;app1.write("Exif\0\0",o,"latin1");o+=6;const t=o;app1.write("MM",o);o+=2;app1.writeUInt16BE(42,o);o+=2;app1.writeUInt32BE(8,o);o+=4;app1.writeUInt16BE(1,o);o+=2;app1.writeUInt16BE(0x0112,o);app1.writeUInt16BE(3,o+2);app1.writeUInt32BE(1,o+4);app1.writeUInt16BE(6,o+8);const sof=Buffer.from([0xff,0xc0,0,11,8,0,100,0,200,1,1,0x11,0]);fs.writeFileSync(process.argv[1],Buffer.concat([Buffer.from([0xff,0xd8]),app1,sof,Buffer.from([0xff,0xd9])]))' "$W/o/rot.jpg"
  echo '{"cols":1,"cellWidth":300,"items":[{"image":"rot.jpg"}]}' > "$W/o/r.json"
  o="$(HOME="$REAL_HOME" node "$K/scripts/sheet.mjs" "$W/o/r.json" "$W/o/r.png" 2>&1)"; h="$(C pngsize "$W/o/r.png" 2>/dev/null | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).height)' 2>/dev/null)"
  [ "$h" = "$((48 + 600 + 64))" ] && ok "sheet.mjs:JPEG 依 EXIF 方向(200×100、Orientation 6 → 直式 100×200,圖高 600)" || bad "sheet EXIF" "$o h=$h"
  echo '{"cols":2.5,"items":[{"image":"a.png"}]}' > "$W/o/c.json"; o="$(node "$K/scripts/sheet.mjs" "$W/o/c.json" "$W/o/c.png" 2>&1)"; [ $? -eq 2 ] && ok "sheet.mjs:cols 不是正整數 → 結束碼 2" || bad "sheet cols" "$o"
  o="$(node "$K/scripts/sheet.mjs" "$W/o/nope.json" "$W/o/x.png" 2>&1)"; [ $? -eq 2 ] && ok "sheet.mjs:spec 不存在 → 結束碼 2" || bad "sheet.mjs 錯誤處理" "$o"
else skip "sheet.mjs(沒有 Google Chrome)"; fi

echo "---"
echo "pass=$PASS fail=$FAIL skip=$SKIP"
[ "$FAIL" -eq 0 ]
