#!/bin/bash
# game-art-kit 自我測試(離線):假 ComfyUI + 所有 workflow 骨架 + sheet.mjs + scrub-check + 遊戲素材(sprite.mjs、audio.mjs、schema)。
# 需要 Node ≥ 22;sheet 需要 Google Chrome、audio.mjs 需要 ffmpeg(含 libopus / aac)(沒有時 SKIP)。測完刪除暫存目錄、停掉假伺服器。
# 實機測試:另外設 COMFYUI_URL 後跑 `bash tests/run.sh --live`(只送 1 張 4 步小圖,上傳與輸出都在 temp,跑完刪 history)。
set -uo pipefail
K="$(cd "$(dirname "$0")/.." && pwd)"
C() { node "$K/scripts/comfy.mjs" "$@"; }
PASS=0; FAIL=0; SKIP=0
ok()   { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL  $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/      /' | tail -15; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP  $1"; SKIP=$((SKIP + 1)); }
W="$(mktemp -d)"; PID=""; REAL_HOME="$HOME"
PID2=""
cleanup() { [ -n "$PID" ] && kill "$PID" 2>/dev/null; [ -n "$PID2" ] && kill "$PID2" 2>/dev/null; rm -rf "$W"; }
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
echo "$c" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));process.exit(Array.isArray(d.unsupported_consistency)&&d.unsupported_consistency.length===0?0:1)' \
  && ok "check:沒有 IP-Adapter 時 unsupported_consistency 為空陣列" || bad "check unsupported_consistency" "$c"
# 只有 IP-Adapter 的主機:consistency_methods 為空(kit 沒有 IP-Adapter 骨架),IP-Adapter 只列在 unsupported_consistency
P2=$((PORT - 10000))   # PORT 在 20000–39999,P2 在 10000–29999:和第一個不同,也避開 macOS 臨時埠(49152 起)
node "$K/tests/fake-comfy.mjs" "$P2" "$W/req2.log" ipadapter-only > "$W/fake2.out" 2>&1 & PID2=$!
for i in $(seq 1 50); do grep -q listening "$W/fake2.out" 2>/dev/null && break; sleep 0.1; done
if ! grep -q listening "$W/fake2.out"; then bad "第二個假 ComfyUI 沒有啟動(埠 $P2)" "$(cat "$W/fake2.out")"; kill "$PID2" 2>/dev/null; PID2=""; else
c2="$(C check --url "http://127.0.0.1:$P2" 2>"$W/c2.err")"
kill "$PID2" 2>/dev/null; wait "$PID2" 2>/dev/null; PID2=""
echo "$c2" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));const w=d.workflows_available;const ok=d.consistency_methods.length===0&&d.unsupported_consistency.map(x=>x.method).join()==="ipadapter"&&w["flux-t2i"]===true&&w["qwen-edit-1ref"]===false&&w["flux-kontext"]===false;process.exit(ok?0:1)' \
  && ok "check:只有 IP-Adapter 的主機 → consistency_methods 為空、ipadapter 列在 unsupported_consistency" || bad "check IP-Adapter-only" "$c2 $(cat "$W/c2.err")"
fi

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
r="$(C run "$K/workflows/flux-t2i.json" --out "$W/o" --name fneg "${FS[@]}" --set width=64 --set height=64 --set negative=n 2>&1)"; rc=$?
[ $rc -eq 2 ] && echo "$r" | grep -q negative && [ ! -e "$W/o/fneg.png" ] && ok "Flux 骨架沒有 negative:多給 → 結束碼 2(agent 只在 _meta.params 有 negative 時才給)" || bad "flux-t2i 多給 negative" "rc=$rc $r"
r="$(C run "$K/workflows/flux-kontext.json" --out "$W/o" --name k1 "${FS[@]}" --set 'ref1=r.png [temp]')" && ok "flux-kontext 送出成功" || bad "flux-kontext" "$r"
r="$(C run "$K/workflows/zimage-t2i.json" --out "$W/o" --name z1 --set unet=u --set clip=c --set vae=v --set shift=3 --set prompt=p --set negative=n --set seed=1 --set steps=4 --set cfg=1 --set sampler=euler --set scheduler=simple --set width=64 --set height=64)" && ok "zimage-t2i 送出成功" || bad "zimage-t2i" "$r"
r="$(C run "$K/workflows/qwen-t2i-canny.json" --out "$W/o" --name c1 "${QS[@]}" --set width=64 --set height=64 --set controlnet=x --set 'control_image=s.png [temp]' --set control_strength=0.8 --set control_end=0.8)" && ok "qwen-t2i-canny 送出成功" || bad "qwen-t2i-canny" "$r"
grep -q '"path":"/history","query":{},"body":{"delete"' "$W/req.log" && ok "每張完成後刪除 history" || bad "每張完成後刪除 history" "$(tail -5 "$W/req.log")"
r="$( (exec node "$K/scripts/comfy.mjs" run "$K/workflows/qwen-t2i.json" --out "$W/sig" --name sg "${QS[@]/prompt=p/prompt=SLOW}" --set width=64 --set height=64 --timeout 60 2>&1) & p=$!; sleep 1.5; kill -TERM $p; wait $p; echo "rc=$?")"
echo "$r" | grep -q 'rc=143' && tail -3 "$W/req.log" | grep -q '"path":"/history","query":{},"body":{"delete"' && [ ! -e "$W/sig/sg.png" ] && ok "收到 SIGTERM → 取消並刪 history 後結束(143)" || bad "SIGTERM 收尾" "$r $(tail -3 "$W/req.log")"

# 4. 參數檢查與錯誤
o="$(C run "$K/workflows/qwen-t2i.json" --out "$W/o" --name x "${QS[@]}" 2>&1)"; [ $? -eq 2 ] && echo "$o" | grep -q 'width' && ok "缺參數 → 結束碼 2 並列出" || bad "缺參數" "$o"
o="$(C run "$K/workflows/qwen-t2i.json" --out "$W/o" --name x "${QS[@]}" --set width=64 --set height=64 --set typo=1 2>&1)"; [ $? -eq 2 ] && echo "$o" | grep -q 'typo' && ok "多餘參數 → 結束碼 2" || bad "多餘參數" "$o"
o="$(C run "$K/workflows/qwen-t2i.json" --out "$W/o" --name failx "${QS[@]}" --set width=64 --set height=64 --set prompt=FAIL 2>&1)"; [ $? -eq 3 ] && [ ! -e "$W/o/workflows/failx.json" ] && ok "執行錯誤 → 結束碼 3,不留 workflow 檔" || bad "執行錯誤" "$o"
o="$(C run "$K/workflows/qwen-t2i.json" --out "$W/o" --name x "${QS[@]}" --set width=64 --set height=64 --set prompt=SLOW --timeout 2 2>&1)"; rc=$?
tid="$(echo "$o" | sed -n 's/.*"prompt_id":"\([^"]*\)".*/\1/p')"
[ $rc -eq 4 ] && grep -q "\"path\":\"/interrupt\",\"query\":{},\"body\":{\"prompt_id\":\"$tid\"" "$W/req.log" && ok "逾時 → 指定 prompt_id 中斷自己的工作($tid)、結束碼 4" || bad "逾時" "$o rc=$rc tid=$tid"
r="$(C run "$K/workflows/qwen-t2i.json" --out "$W/o" --name qd "${QS[@]/prompt=p/prompt=QUEUED}" --set width=64 --set height=64 --timeout 1 2>&1)" && [ -e "$W/o/qd.png" ] && ok "排隊時間不算 --timeout(排隊 2.5 秒、--timeout 1 仍成功)" || bad "排隊計時" "$r"
L0="$(wc -l < "$W/req.log" | tr -d ' ')"
r="$( (exec node "$K/scripts/comfy.mjs" run "$K/workflows/qwen-t2i.json" --out "$W/sig2" --name ss "${QS[@]/prompt=p/prompt=SLOW_SLOWSUBMIT}" --set width=64 --set height=64 --timeout 30 2>&1) & p=$!; sleep 0.5; kill -TERM $p; wait $p; echo "rc=$?")"
NEW="$(tail -n +"$((L0 + 1))" "$W/req.log")"
echo "$r" | grep -q 'rc=143' && echo "$NEW" | grep -q '"path":"/interrupt","query":{},"body":{"prompt_id":"fake-' && echo "$NEW" | tail -2 | grep -q '"path":"/history","query":{},"body":{"delete"' \
  && ok "送出途中收到 SIGTERM → 等到 prompt_id 再取消、刪 history(143)" || bad "送出途中中止" "$r $NEW"
r="$(C run "$K/workflows/qwen-t2i.json" --out "$W/o" --name fh "${QS[@]/prompt=p/prompt=FLAKYHIST}" --set width=64 --set height=64 2>&1)" && [ -e "$W/o/fh.png" ] && ok "輪詢 /history 暫時斷線 → 重試後成功" || bad "輪詢斷線重試" "$r"
r="$(C run "$K/workflows/qwen-t2i.json" --out "$W/o" --name qdn "${QS[@]/prompt=p/prompt=QUEUED_QUEUEDOWN}" --set width=64 --set height=64 --timeout 5 --queue-timeout 1 2>&1)" && [ -e "$W/o/qdn.png" ] && ok "/queue 一直回 500:不套排隊逾時、靠總時限兜底,工作完成" || bad "/queue 持續錯誤" "$r"
r="$(C run "$K/workflows/qwen-t2i.json" --out "$W/o" --name qe "${QS[@]/prompt=p/prompt=QUEUED_QUEUEERR}" --set width=64 --set height=64 --timeout 1 2>&1)" && [ -e "$W/o/qe.png" ] && ok "/queue 暫時回 500 不當成已開始執行" || bad "/queue 錯誤誤判" "$r"
o="$(C run "$K/workflows/qwen-t2i.json" --out "$W/o" --name qx "${QS[@]/prompt=p/prompt=QUEUED}" --set width=64 --set height=64 --queue-timeout 1 2>&1)"; [ $? -eq 4 ] && echo "$o" | grep -q '"reason":"queue"' && ok "排隊超過 --queue-timeout → 移出佇列、結束碼 4" || bad "--queue-timeout" "$o"
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

# 8. 遊戲素材模式:去背、音訊、雲端節點、sprite.mjs、audio.mjs、介面 schema
c="$(C check)"
echo "$c" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));const bg=d.background_removal;const w=d.workflows_available;
const ok=bg.length===1&&bg[0].node==="RMBG"&&bg[0].models.join()==="RMBG-2.0"&&d.audio_models.sfx.length===1&&d.audio_models.bgm.length===1&&w["qwen-t2i-sprite"]&&w["qwen-edit-1ref-sprite"]&&w["stable-audio-sfx"]&&w["ace-step-bgm"]&&d.defaults.sfx_clip==="t5gemma_b_b_ul2.safetensors";process.exit(ok?0:1)' \
  && ok "check:本機去背只列模型檔存在的選項(BEN 只有 model.py 不列)、音訊模型與 sprite / 音訊骨架可用" || bad "check 去背 / 音訊" "$c"
P3=$((PORT - 9000))
FAKE_NO_RMBG=1 FAKE_NO_AUDIO=1 node "$K/tests/fake-comfy.mjs" "$P3" "$W/req3.log" > "$W/fake3.out" 2>&1 & PID2=$!
for i in $(seq 1 50); do grep -q listening "$W/fake3.out" 2>/dev/null && break; sleep 0.1; done
c3="$(C check --url "http://127.0.0.1:$P3" 2>&1)"; kill "$PID2" 2>/dev/null; wait "$PID2" 2>/dev/null; PID2=""
echo "$c3" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));const w=d.workflows_available;process.exit(d.background_removal.length===0&&d.audio_models.sfx.length===0&&d.audio_models.bgm.length===0&&w["qwen-t2i-sprite"]===false&&w["stable-audio-sfx"]===false&&w["ace-step-bgm"]===false&&w["qwen-t2i"]===true?0:1)' \
  && ok "check:沒有去背模型檔 / 音訊模型 → background_removal 與 audio_models 為空、對應骨架不可用" || bad "check 缺去背 / 音訊" "$c3"
r="$(C run "$K/workflows/qwen-t2i-sprite.json" --out "$W/a" --name sp1 "${QS[@]}" --set width=96 --set height=128 --set bg_model=RMBG-2.0)" && echo "$r" | grep -q '"channels":4' \
  && ok "qwen-t2i-sprite:同一 workflow 去背,下載的 PNG 有 alpha" || bad "qwen-t2i-sprite" "$r"
r="$(C run "$K/workflows/qwen-edit-1ref-sprite.json" --out "$W/a" --name sp2 "${QS[@]}" --set width=64 --set height=64 --set 'ref1=r.png [temp]' --set bg_model=RMBG-2.0)" && echo "$r" | grep -q '"channels":4' \
  && ok "qwen-edit-1ref-sprite:角色一致 + 去背" || bad "qwen-edit-1ref-sprite" "$r"
SA=(--set ckpt=s --set clip=t --set prompt=boing --set negative=music --set seconds=3 --set seed=1 --set steps=8 --set cfg=6 --set sampler=euler --set scheduler=simple)
r="$(C run "$K/workflows/stable-audio-sfx.json" --out "$W/a" --name sfx "${SA[@]}")" && [ -s "$W/a/sfx.wav" ] && echo "$r" | grep -q '"kind":"audio"' \
  && ok "stable-audio-sfx:下載 PreviewAudio 的音訊(副檔名照伺服器)" || bad "stable-audio-sfx" "$r"
r="$(C run "$K/workflows/ace-step-bgm.json" --out "$W/a" --name bgm --set ckpt=a --set tags=cozy --set 'lyrics=[instrumental]' --set seconds=10 --set bpm=100 --set timesignature=4 --set 'keyscale=C major' --set seed=1 --set steps=8 --set cfg=1 --set shift=3 --set sampler=euler --set scheduler=simple)" && [ -s "$W/a/bgm.wav" ] \
  && ok "ace-step-bgm:送出並下載音訊" || bad "ace-step-bgm" "$r"
sed 's/"PreviewAudio"/"SaveAudio"/' "$K/workflows/stable-audio-sfx.json" > "$W/saveaudio.json"
o="$(C run "$W/saveaudio.json" --out "$W/a" --name x "${SA[@]}" 2>&1)"; [ $? -eq 2 ] && echo "$o" | grep -q 'Save' && ok "拒絕 SaveAudio(不在伺服器留檔)" || bad "SaveAudio 沒被擋" "$o"
for node in BriaRemoveImageBackground FancyApiNode; do
  node -e 'const g=require(process.argv[1]);g["99"]={class_type:process.argv[3],inputs:{}};require("fs").writeFileSync(process.argv[2],JSON.stringify(g))' "$K/workflows/qwen-t2i.json" "$W/cloud.json" "$node"
  n0="$(grep -c '"path":"/prompt"' "$W/req.log")"
  o="$(C run "$W/cloud.json" --out "$W/a" --name x "${QS[@]}" --set width=64 --set height=64 2>&1)"; rc=$?
  [ $rc -eq 2 ] && echo "$o" | grep -q "雲端 API 節點.*$node" && [ "$(grep -c '"path":"/prompt"' "$W/req.log")" = "$n0" ] && ok "拒絕雲端 API 節點 $node(名稱黑名單 / api_node 旗標),不送出" || bad "雲端節點 $node" "rc=$rc $o"
done

S() { node "$K/scripts/sprite.mjs" "$@"; }
# 產生測試圖:透明底 300×400、主體矩形(位置與高度可調)、可選外框殘留、可選全不透明
mk2() { node --input-type=module -e '
import { encodePng } from "'"$K"'/scripts/sprite.mjs"; import { writeFileSync } from "node:fs";
const [out, ox, oy, h, border, alpha] = process.argv.slice(1); const W = 300, H = 400, d = Buffer.alloc(W * H * 4);
for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) { const o = (y * W + x) * 4; d[o] = 90; d[o + 1] = 160; d[o + 2] = 90;
  const inBody = x >= +ox && x < +ox + 120 && y >= +oy && y < +oy + +h; const inBorder = border === "1" && (x < 6 || y < 6);
  d[o + 3] = alpha === "0" ? 255 : (inBody || inBorder) ? 255 : 0; }
writeFileSync(out, encodePng({ width: W, height: H, data: d }));' "$@"; }
mkdir -p "$W/sp"
mk2 "$W/sp/f1.png" 50 40 300 0 1; mk2 "$W/sp/f2.png" 120 80 290 0 1; mk2 "$W/sp/f3.png" 10 20 310 0 1; mk2 "$W/sp/f4.png" 90 60 300 0 1
o="$(S info "$W/sp/f1.png")" && echo "$o" | grep -q '"bbox":{"x":50,"y":40,"w":120,"h":300}' && ok "sprite.mjs info:讀 PNG、外接矩形正確" || bad "sprite info" "$o"
o="$(S fit "$W/sp/f1.png" --out "$W/sp/one.png" --width 120 --height 160)" && o2="$(S check "$W/sp/one.png" --width 120 --height 160 --character)" \
  && ok "sprite.mjs fit + check:單張裁切、底部對齊、通過檢查" || bad "sprite fit 單張" "$o $o2"
o="$(S fit "$W/sp/f1.png" "$W/sp/f2.png" "$W/sp/f3.png" "$W/sp/f4.png" --out "$W/sp/run.png" --width 120 --height 160)" && echo "$o" | grep -q '"columns":4' \
  && o2="$(S check "$W/sp/run.png" --width 120 --height 160 --frames 4 --character)" && ok "sprite.mjs:4 格同一縮放比例、腳底基線一致、拼成 sheet" || bad "sprite 動作格" "$o $o2"
o="$(S fit "$W/sp/f1.png" "$W/sp/f2.png" "$W/sp/f3.png" "$W/sp/f4.png" "$W/sp/f1.png" "$W/sp/f2.png" --out "$W/sp/wide.png" --width 400 --height 300)" && echo "$o" | grep -q '"columns":5,"rows":2' \
  && ok "sprite.mjs:sheet 寬超過 2048 換行(400 寬 × 6 格 → 5 欄 2 列)" || bad "sprite 換行" "$o"
mk2 "$W/sp/dirty.png" 50 40 300 1 1
o="$(S check "$W/sp/dirty.png" --width 300 --height 400)"; [ $? -eq 1 ] && echo "$o" | grep -q '外框' && ok "sprite.mjs check:外框有殘留 → 不通過" || bad "sprite 外框殘留" "$o"
o="$(S check "$W/o/q1.png" --width 96 --height 64)"; [ $? -eq 1 ] && echo "$o" | grep -q 'alpha' && ok "sprite.mjs check:沒有 alpha → 不通過" || bad "sprite 沒有 alpha" "$o"
o="$(S check "$W/sp/one.png" --width 100 --height 160)"; [ $? -eq 1 ] && echo "$o" | grep -q '尺寸' && ok "sprite.mjs check:尺寸不符 → 不通過" || bad "sprite 尺寸" "$o"
o="$(S fit "$W/sp/f1.png" "$W/sp/f1.png" "$W/sp/f1.png" "$W/sp/f1.png" "$W/sp/f1.png" "$W/sp/f1.png" "$W/sp/f1.png" "$W/sp/f1.png" "$W/sp/f1.png" --out "$W/sp/x.png" --width 64 --height 64 2>&1)"; [ $? -eq 2 ] && ok "sprite.mjs fit:超過 8 格 → 結束碼 2" || bad "sprite 9 格" "$o"
# 角色各格高度差太大(未用同一縮放、或生成時角色大小不一致)
node --input-type=module -e '
import { decodePng, encodePng } from "'"$K"'/scripts/sprite.mjs"; import { readFileSync, writeFileSync } from "node:fs";
const a = decodePng(readFileSync(process.argv[1])); const b = decodePng(readFileSync(process.argv[2]));
const s = { width: a.width * 2, height: a.height, data: Buffer.alloc(a.width * 2 * a.height * 4) };
for (let y = 0; y < a.height; y++) { a.data.copy(s.data, y * s.width * 4, y * a.width * 4, (y + 1) * a.width * 4); b.data.copy(s.data, (y * s.width + a.width) * 4, y * b.width * 4, (y + 1) * b.width * 4); }
writeFileSync(process.argv[3], encodePng(s));' "$W/sp/one.png" "$(S fit "$W/sp/f1.png" --out "$W/sp/small.png" --width 120 --height 160 --margin 40 >/dev/null; echo "$W/sp/small.png")" "$W/sp/mismatch.png"
o="$(S check "$W/sp/mismatch.png" --width 120 --height 160 --frames 2 --columns 2 --character)"; [ $? -eq 1 ] && echo "$o" | grep -q '高度差\|基線' && ok "sprite.mjs check:各格高度 / 基線不一致 → 不通過" || bad "sprite 各格不一致" "$o"
mk2 "$W/sp/tile.png" 0 0 400 0 0
o="$(S cover "$W/sp/tile.png" --out "$W/sp/cov.png" --width 200 --height 100)" && [ "$(C pngsize "$W/sp/cov.png")" = '{"width":200,"height":100}' ] && S check "$W/sp/cov.png" --width 200 --height 100 --opaque >/dev/null \
  && ok "sprite.mjs cover:不透明素材等比蓋滿裁切到 1x" || bad "sprite cover" "$o"
o="$(S check "$W/sp/tile.png" --width 300 --height 400 --opaque --tileable)" && ok "sprite.mjs check:均勻地圖塊可平鋪" || bad "sprite tileable 均勻" "$o"
node --input-type=module -e '
import { encodePng } from "'"$K"'/scripts/sprite.mjs"; import { writeFileSync } from "node:fs";
const W = 64, H = 64, d = Buffer.alloc(W * H * 4); for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) { const o = (y * W + x) * 4; d[o] = x * 4; d[o + 1] = 0; d[o + 2] = 0; d[o + 3] = 255; }
writeFileSync(process.argv[1], encodePng({ width: W, height: H, data: d }));' "$W/sp/grad.png"
o="$(S check "$W/sp/grad.png" --width 64 --height 64 --opaque --tileable)"; [ $? -eq 1 ] && echo "$o" | grep -q '平鋪' && ok "sprite.mjs check:漸層地圖塊左右接不起來 → 不通過" || bad "sprite tileable 漸層" "$o"

A() { node "$K/scripts/audio.mjs" "$@"; }
if A tools >/dev/null 2>&1; then
  mkdir -p "$W/au"
  ffmpeg -v error -y -f lavfi -i "anullsrc=r=48000:cl=stereo:d=0.5" -f lavfi -i "sine=f=660:d=0.8,volume=0.9" -f lavfi -i "anullsrc=r=48000:cl=stereo:d=1" -filter_complex "[1]aformat=sample_rates=48000:channel_layouts=stereo[s];[0][s][2]concat=n=3:v=0:a=1" "$W/au/raw.wav"
  o="$(A process "$W/au/raw.wav" --type sfx --duration 3 --out "$W/au" --name sfx.jump)" && o2="$(A check "$W/au/sfx.jump.ogg" "$W/au/sfx.jump.m4a" --type sfx --duration 3)" \
    && echo "$o" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));process.exit(d.durationSec<1&&d.durationSec>0.7?0:1)' \
    && ok "audio.mjs sfx:去頭尾靜音(2.3 秒 → 約 0.8 秒)、−16 LUFS、ogg + m4a 通過檢查" || bad "audio sfx" "$o $o2"
  ffmpeg -v error -y -f lavfi -i "anullsrc=r=48000:cl=stereo:d=2" "$W/au/silent.wav"
  o="$(A process "$W/au/silent.wav" --type sfx --duration 2 --out "$W/au" --name s 2>&1)"; [ $? -eq 1 ] && ok "audio.mjs:靜音輸入 → 結束碼 1" || bad "audio 靜音" "$o"
  ffmpeg -v error -y -f lavfi -i "sine=f=220:d=6.5,volume=0.5" -f lavfi -i "sine=f=330:d=6.5,volume=0.3" -filter_complex "[0][1]amix=inputs=2,aformat=sample_rates=48000:channel_layouts=stereo" "$W/au/music.wav"
  o="$(A process "$W/au/music.wav" --type bgm --duration 6 --loop --out "$W/au" --name bgm.stage1)" && echo "$o" | grep -q '"loop":true' \
    && o2="$(A check "$W/au/bgm.stage1.ogg" "$W/au/bgm.stage1.m4a" --type bgm --duration 6 --loop)" && ok "audio.mjs bgm:交叉淡化循環、−18 LUFS、接縫檢查通過" || bad "audio bgm loop" "$o $o2"
  o="$(A process "$W/au/music.wav" --type bgm --duration 6.3 --loop --out "$W/au" --name x 2>&1)"; [ $? -eq 2 ] && echo "$o" | grep -q 'duration + 1' && ok "audio.mjs:--loop 輸入不夠長 → 結束碼 2 並提示生成長度" || bad "audio loop 太短" "$o"
  o="$(A check "$W/au/bgm.stage1.ogg" "$W/au/bgm.stage1.m4a" --type bgm --duration 20)"; [ $? -eq 1 ] && echo "$o" | grep -q '長度' && ok "audio.mjs check:長度不符 → 不通過" || bad "audio check 長度" "$o"
  ffmpeg -v error -y -f lavfi -i "sine=f=440:d=2,volume=8" "$W/au/loud.ogg"; ffmpeg -v error -y -f lavfi -i "sine=f=440:d=2,volume=8" "$W/au/loud.m4a"
  o="$(A check "$W/au/loud.ogg" "$W/au/loud.m4a" --type sfx --duration 3)"; [ $? -eq 1 ] && echo "$o" | grep -q 'true peak' && ok "audio.mjs check:削波 / 過大聲 → 不通過" || bad "audio check 削波" "$o"
  o="$(A check "$W/au/sfx.jump.ogg" --type sfx --duration 3 2>&1)"; [ $? -eq 1 ] && ok "audio.mjs check:缺 m4a → 不通過" || bad "audio check 缺檔" "$o"
else skip "audio.mjs(沒有 ffmpeg / libopus / aac)"; fi

V() { node "$K/schemas/validate.mjs" "$@"; }
mkdir -p "$W/v/table"
echo '{"version":1,"design":{"width":1920,"height":1080},"needs":[{"id":"hero.run","type":"frames","group":"table","purpose":"跑","width":120,"height":160,"frames":{"count":4,"fps":10},"character":"farmer"},{"id":"sfx.jump","type":"sfx","group":"table","purpose":"跳","durationSec":1}]}' > "$W/v/needs.json"
o="$(V needs "$W/v/needs.json")" && ok "schema:合法 needs 通過" || bad "schema needs 合法" "$o"
echo '{"version":1,"design":{"width":1920,"height":1080},"needs":[{"id":"Hero","type":"frames","group":"table","purpose":"x","width":120,"height":160},{"id":"sfx.a","type":"sfx","group":"table","purpose":"x","width":3}]}' > "$W/v/bad.json"
o="$(V needs "$W/v/bad.json")"; [ $? -eq 1 ] && echo "$o" | grep -q '缺少 frames' && echo "$o" | grep -q '缺少 durationSec' && echo "$o" | grep -q '不可有 width' && ok "schema:id 格式、frames 必填、音訊不可有尺寸" || bad "schema needs 錯誤" "$o"
cp "$W/sp/run.png" "$W/v/table/hero.run.png"; printf 'x' > "$W/v/table/sfx.jump.ogg"
echo '{"version":1,"assets":[{"id":"hero.run","type":"frames","group":"table","files":["table/hero.run.png"],"width":60,"height":80,"density":2,"anchor":[0.5,1],"frames":{"count":4,"fps":10,"frameWidth":120,"frameHeight":160,"columns":4},"character":"farmer","source":"out/20261122-assets/manifest.json#hero-run","review":"pending"},{"id":"sfx.jump","type":"sfx","group":"table","files":["table/sfx.jump.ogg","table/sfx.jump.m4a"],"durationSec":0.8,"lufs":-16,"source":"out/20261122-assets/manifest.json#sfx-jump","review":"pending"}]}' > "$W/v/assets.json"
o="$(V assets "$W/v/assets.json")" && ok "schema:合法 assets 通過" || bad "schema assets 合法" "$o"
o="$(V assets "$W/v/assets.json" --root "$W/v")"; [ $? -eq 1 ] && echo "$o" | grep -q 'sfx.jump.m4a' && ok "schema:--root 檢查檔案存在(缺 m4a)" || bad "schema --root" "$o"
echo '{"version":1,"assets":[{"id":"ui.btn","type":"ui","group":"lobby","files":["lobby/ui.btn.png"],"width":200,"height":80,"density":2,"anchor":[0.5,0.5],"nineSlice":[20,20,20,20],"nineSlice1x":[20,20,20,20],"source":"out/x/manifest.json#b","review":"pending"},{"id":"bgm.a","type":"bgm","group":"lobby","files":["lobby/bgm.a.ogg"],"durationSec":60,"lufs":-18,"source":"out/x/manifest.json#a","review":"done"}]}' > "$W/v/a2.json"
o="$(V assets "$W/v/a2.json")"; [ $? -eq 1 ] && echo "$o" | grep -q 'nineSlice1x 應為 \[40,40,40,40\]' && echo "$o" | grep -q '.ogg 與 .m4a' && echo "$o" | grep -q 'review' && ok "schema:nineSlice1x = nineSlice × density、音訊雙格式、review 值" || bad "schema assets 錯誤" "$o"

# 7. sheet.mjs
# 不需要 Chrome:尺寸讀不出來時,在啟動 Chrome 之前就結束
mkdir -p "$W/o"; printf 'RIFFxxxxWEBPVP8X' > "$W/o/bad.webp"
echo '{"items":[{"image":"bad.webp"}]}' > "$W/o/bw.json"; o="$(node "$K/scripts/sheet.mjs" "$W/o/bw.json" "$W/o/bw.png" 2>&1)"; [ $? -eq 2 ] && echo "$o" | grep -q '不完整' && ok "sheet.mjs:截斷的 WebP → 結束碼 2" || bad "sheet 截斷 WebP" "$o"
if [ -x "${CHROME_PATH:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}" ]; then
  cp "$W/o/q1.png" "$W/o/a.png"; cp "$W/o/q1.png" "$W/o/b.png"
  echo '{"title":"測試分鏡","cols":2,"cellWidth":300,"items":[{"image":"a.png","label":"01","caption":"第一格"},{"image":"b.png","label":"02","caption":"第二格","note":"備註"},{"image":"a.png","label":"03","caption":"第三格"}]}' > "$W/o/spec.json"
  o="$(HOME="$REAL_HOME" node "$K/scripts/sheet.mjs" "$W/o/spec.json" "$W/o/sheet.png" 2>&1)" && echo "$o" | grep -q '"items":3' && [ "$(C pngsize "$W/o/sheet.png" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(d.width)')" = 668 ] \
    && ok "sheet.mjs:2 欄 3 格、寬度正確" || bad "sheet.mjs" "$o"
  # 高度 = 上下 padding 48 + 標題 64 + 兩列(圖 200 + 說明 64)+ 一個間距 20 = 660(最後一列不加間距)
  [ "$(C pngsize "$W/o/sheet.png" | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).height)')" = 660 ] && ok "sheet.mjs:高度正確(最後一列不多算間距)" || bad "sheet 高度" "$(C pngsize "$W/o/sheet.png")"
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
