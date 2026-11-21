---
name: game-art-kit
description: 遊戲示意圖與分鏡用的 ComfyUI 固定腳本:位址解析(本機設定,不進 git)、check(模型、模型家族、可用的角色一致性方法)、上傳參考圖到 temp、送 workflow 並輪詢下載(含逾時、刪 history、不在伺服器留檔)、workflow 技術骨架(Qwen-Image、Qwen-Image-Edit 1–3 張參考圖、Flux、Flux Kontext、Z-Image、ControlNet canny)、拼分鏡表、產出不含位址檢查。game-concept-artist 出圖時使用;任何要用區網 ComfyUI 批次出圖的情境也可用。
---

# game-art-kit

`<kit>` = 這個 skill 的目錄。只用 Node 內建模組(≥ 22);`sheet.mjs` 需要本機 Google Chrome。**風格不放在這裡**:配色、畫風、提示詞基底寫在各遊戲的 `art/STYLE.md`。

## ComfyUI 位址(本機環境設定,不進 git)

優先序:`--url <位址>` > 環境變數 `COMFYUI_URL` > `~/.config/game-art-kit/config` 的 `COMFYUI_URL=`。

```bash
mkdir -p ~/.config/game-art-kit && chmod 700 ~/.config/game-art-kit
echo 'COMFYUI_URL=http://<主機>:8188' > ~/.config/game-art-kit/config && chmod 600 ~/.config/game-art-kit/config
```

ComfyUI 要用 `--listen` 啟動。macOS 連區網被擋(`No route to host`、0 ms 失敗,但瀏覽器打得開)時,到「系統設定 → 隱私權與安全性 → 本機網路」允許執行 Claude Code 的終端機 app,或排除 VPN 對區網的接管。

## 腳本

```bash
node <kit>/scripts/comfy.mjs check                     # JSON:models(含 family)、consistency_methods、workflows_available、defaults(建議檔名)
node <kit>/scripts/comfy.mjs upload <圖> --prefix <專案>-<角色id>
#   → {"loadImage":"<prefix>-<雜湊8>.png [temp]"}:放 ComfyUI temp 區(重開即清),workflow 的 ref 參數填 loadImage
node <kit>/scripts/comfy.mjs run <kit>/workflows/<骨架>.json --out <目錄> --name <檔名> --set key=value ... [--timeout 240] [--queue-timeout 180]
#   --timeout 只算開始執行後;排隊等待另算(--queue-timeout,預設 180)。預設值已符合下面的規則。兩者相加要比呼叫端(例如 Bash 工具,最長 600 秒)的逾時
#   少 180 秒以上(偵測延遲加上取消收尾最多約 2 分鐘),例如 --timeout 240 --queue-timeout 180 配 600 秒;否則會被外部中止而拿不到 timeout 結果。被 Ctrl-C / SIGHUP / SIGTERM 中止時取消自己的工作再結束(130 / 129 / 143)
#   → <目錄>/<檔名>.png、<目錄>/workflows/<檔名>.json(實際送出的參數,不含位址);印 {"status":"ok","seconds":…,"files":[{file,width,height}]}
node <kit>/scripts/comfy.mjs pngsize <圖>              # {"width":…,"height":…}
node <kit>/scripts/comfy.mjs scrub-check <目錄>        # 產出含 ComfyUI 位址 / 私有 IP / :8188 → 結束碼 1
node <kit>/scripts/sheet.mjs <spec.json> <輸出.png>    # 拼分鏡表 / 標註表(格式見檔頭)
bash <kit>/tests/run.sh                                # 離線自我測試(假 ComfyUI)
bash <kit>/tests/run.sh --live                         # 實機:check + 1 張 512×512 4 步小圖
```

結束碼:0 成功;1 一般錯誤 / scrub 找到位址;2 用法或參數錯誤(缺參數、多餘參數、SaveImage);3 ComfyUI 拒絕或執行失敗(印 node_errors);4 逾時(已中斷自己的工作並刪 history);5 連不上。

**不在伺服器留檔:** 上傳到 temp、輸出用 `PreviewImage`(`run` 拒絕 `SaveImage`)、下載後刪 history。逾時或中途出錯(含斷線)也會收尾:佇列中的移出、執行中的用 `prompt_id` 只中斷自己的工作,等 history 出現再刪。

## workflow 骨架(`workflows/`)

只放節點結構;`{{key}}` 由 `--set` 填。只有 `_meta.numeric` 列的參數會轉成數字(seed 不可超過 2^53−1),其他(提示詞、檔名)一律是字串。缺參數或多給參數都會結束碼 2。每個檔的 `_meta.params` 列出所有參數與說明。`lora=none` 會拿掉 LoRA 節點。

| 骨架 | 用途 | 實測參數(2026-11,秒數依硬體而異) |
|---|---|---|
| `qwen-t2i` | 文生圖(場景、定裝、UI) | Lightning LoRA:steps 4、cfg 1、euler/simple、shift 3.1(約 30 秒 / 1024²)。不用 LoRA:steps 20、cfg 2.5 |
| `qwen-edit-1ref` / `2ref` / `3ref` | **角色一致**:以 1–3 張參考圖編輯 / 生成新畫面 | Edit Lightning LoRA:steps 4、cfg 1、shift 3.1。提示詞用 `the character in image 1`、`image 2`… 指稱 |
| `flux-t2i` | 文生圖(寫實 / 繪畫感場景) | guidance 3.5、steps 20、euler/simple |
| `flux-kontext` | **角色一致**:1 張參考圖,輸出尺寸跟參考圖 | guidance 2.5、steps 20。臉部細節(疤痕等)保留最好,但每張約 45 秒 |
| `zimage-t2i` | 快速草圖 / UI 示意 | steps 8、cfg 1、res_multistep/simple、shift 3(約 16 秒) |
| `qwen-t2i-canny` | 依草圖線條控制構圖(分鏡指定構圖) | control_strength 0.8、control_end 0.8、steps 20、cfg 2.5 |

模型檔名用 `check` 的 `defaults` 或 STYLE.md 的生成設定,不要寫死。

## 出圖要點(實測)

- **單一角色要寫明** `only one person, single character`:參考圖編輯模型常把角色複製成兩個人。
- 參考圖編輯會保留服裝與髮型,但小細節(疤痕、飾品)容易掉;`character.md` 的識別物要寫進提示詞,看圖時逐項檢查。
- 擴散模型寫不好字:UI 示意上的文字不要求可讀,需要標註時用 `sheet.mjs` 的 caption / note。
- 定裝圖用素色背景、全身、中性姿勢(`full body, standing, plain light grey background`),參考效果最好。
