---
name: game-art-kit
description: 遊戲示意圖、分鏡與遊戲素材用的 ComfyUI 固定腳本:位址解析(本機設定,不進 git)、check(模型、模型家族、可用的角色一致性方法、本機去背、音訊模型)、上傳參考圖到 temp、送 workflow 並輪詢下載圖片與音訊(含逾時、刪 history、不在伺服器留檔、拒絕雲端 API 節點)、workflow 技術骨架(Qwen-Image、Qwen-Image-Edit 1–3 張參考圖、Flux、Flux Kontext、Z-Image、ControlNet canny、同 workflow 去背的透明 sprite、Stable Audio 音效、ACE-Step 配樂)、拼分鏡表、sprite.mjs(純 Node PNG 裁切 / 對齊 / 拼 sheet / 檢查)、audio.mjs(ffmpeg 響度 / 循環 / ogg + m4a / 檢查)、遊戲素材介面 schema(needs / assets)、產出不含位址檢查。game-concept-artist 出圖與做遊戲素材時使用;game-frontend-owner 用 schema 寫素材需求;任何要用區網 ComfyUI 批次出圖或出音效的情境也可用。
---

# game-art-kit

`<kit>` = 這個 skill 的目錄。只用 Node 內建模組(≥ 22.0);`sheet.mjs` 需要本機 Google Chrome;`audio.mjs` 需要 ffmpeg / ffprobe(含 libopus 與 aac 編碼器,`brew install ffmpeg`)。**風格不放在這裡**:配色、畫風、提示詞基底寫在各遊戲的 `art/STYLE.md`。

## ComfyUI 位址(本機環境設定,不進 git)

優先序:`--url <位址>` > 環境變數 `COMFYUI_URL` > `~/.config/game-art-kit/config` 的 `COMFYUI_URL=`。

```bash
mkdir -p ~/.config/game-art-kit && chmod 700 ~/.config/game-art-kit
echo 'COMFYUI_URL=http://<主機>:8188' > ~/.config/game-art-kit/config && chmod 600 ~/.config/game-art-kit/config
```

ComfyUI 要用 `--listen` 啟動。macOS 連區網被擋(`No route to host`、0 ms 失敗,但瀏覽器打得開)時,到「系統設定 → 隱私權與安全性 → 本機網路」允許執行 Claude Code 的終端機 app,或排除 VPN 對區網的接管。

## 腳本

```bash
node <kit>/scripts/comfy.mjs check                     # JSON:models(含 family)、consistency_methods(只列有可用骨架的)、unsupported_consistency(主機有但沒骨架,例如 IP-Adapter)、
#   background_removal(本機 RMBG 節點、模型需要的檔案全在主機上的選項;缺檔的不列,避免主機自動下載)、audio_models(sfx / bgm)、workflows_available、defaults(建議檔名)
node <kit>/scripts/comfy.mjs upload <圖> --prefix <專案>-<角色id>
#   → {"loadImage":"<prefix>-<雜湊8>.png [temp]"}:放 ComfyUI temp 區(重開即清),workflow 的 ref 參數填 loadImage
node <kit>/scripts/comfy.mjs run <kit>/workflows/<骨架>.json --out <目錄> --name <檔名> --set key=value ... [--timeout 240] [--queue-timeout 180]
#   --timeout 只算開始執行後;排隊等待另算(--queue-timeout,預設 180)。預設值已符合下面的規則。兩者相加要比呼叫端(例如 Bash 工具,最長 600 秒)的逾時
#   少 180 秒以上(送出前要節點旗標:用 `check` 存在 `~/.cache/game-art-kit/` 的快取,1 小時內、而且 workflow 的節點都在快取裡就不另外抓;用 RMBG 的骨架必須先跑過 check;沒有快取時抓 `/object_info` 最多 30 秒(落在 180 秒餘量內),所以**先跑 check 再 run**;時限到了之後:偵測最多約 50 秒、下載上限 60 秒、收尾上限 40 秒),例如 --timeout 240 --queue-timeout 180 配 600 秒;否則會被外部中止而拿不到 timeout 結果。被 Ctrl-C / SIGHUP / SIGTERM 中止時取消自己的工作再結束(130 / 129 / 143)
#   → <目錄>/<檔名>.png(去背骨架是 RGBA)或 <檔名>.<伺服器給的音訊副檔名>(通常 .flac)、<目錄>/workflows/<檔名>.json(實際送出的參數,不含位址);
#     印 {"status":"ok","seconds":…,"files":[{file,width,height,channels} 或 {file,kind:"audio",bytes}]}
#   逾時印 {"status":"timeout","reason":"run|queue|total","seconds":<設定的上限>,"elapsed":<實際秒數>}
node <kit>/scripts/comfy.mjs pngsize <圖>              # {"width":…,"height":…}
node <kit>/scripts/comfy.mjs scrub-check <目錄>        # 產出含 ComfyUI 位址 / 私有 IP / :8188 → 結束碼 1
node <kit>/scripts/sheet.mjs <spec.json> <輸出.png>    # 拼分鏡表 / 標註表(格式見檔頭)
node <kit>/scripts/sprite.mjs density --width <顯示寬> --height <顯示高> [--frames N] [--density d]   # 整數 1x 尺寸 + 實際 density(單格與 sheet 都 ≤ 2048)
node <kit>/scripts/sprite.mjs fit <去背後.png>... --out <id>.png --width <1x 寬> --height <1x 高> [--align bottom|center] [--margin 0] [--foot px]
#   裁透明邊 → 同一動作各格用同一縮放比例 → 角色底部對齊(腳底離下緣 3 px;簡報要求和既有素材對齊時用 --foot,例如 --foot 8,範圍 2 ~ (H − margin) / 2;同一動作的所有格要在同一次 fit 用同一個 --foot)/ 其他置中補到 1x 尺寸;--margin 0(單張 UI / 九宮格)等比放滿,比例差 > 3% 失敗 → 多格拼 sheet(橫向,寬超過 2048 換行);印 columns / rows
node <kit>/scripts/sprite.mjs cover <背景.png> --out <id>.png --width <1x 寬> --height <1x 高> [--exact]   # 不透明素材:等比蓋滿再置中裁切;地圖塊加 --exact(同比例、不裁切)
node <kit>/scripts/sprite.mjs check <id>.png --width <1x 寬> --height <1x 高> [--frames N --columns C] [--character] [--opaque] [--tileable] [--full-bleed] [--allow-white-edge]
#   有 alpha、尺寸、每格覆蓋率 10–90%、外框 2 px 不透明 < 1%(--full-bleed:fit --margin 0 的 UI 不查外框與覆蓋率上限)、外緣白框 ≤ 30%(白色貼紙外框;主體本身是白色或很淺的顏色(白票、雲、銀白物件)時加 --allow-white-edge,並在回報說明)、各格基線差 ≤ 2 px / 高度差 ≤ 10%(--character)、平鋪邊緣差 ≤ 8(--tileable)
node <kit>/scripts/deliver.mjs --stage <stage 根目錄> --assets art/assets --json <新的 assets.json> <相對 art/assets 的檔案>...
#   stage → art/assets 全有或全無交付(有交付日誌,提交前失敗全部還原,結束碼 1);有變更的項目 files 要全部一起交付;
#   上次中斷留下日誌時先 node <kit>/scripts/deliver.mjs --recover --assets art/assets
node <kit>/scripts/audio.mjs process <下載的音訊> --type sfx|bgm --duration <秒> --out <目錄> --name <id> [--loop]
#   sfx:去頭尾靜音、裁到 ≤ duration、−16 LUFS(短於 0.4 秒改峰值正規化,輸出 normalized: peak,check 要加 --peak);bgm:裁到 duration(--loop 頭尾 0.5 秒交叉淡化,輸入要 ≥ duration + 0.5)、−18 LUFS;
#   限幅器保證 true peak ≤ −1.5 dBTP;輸出 <id>.ogg(Opus)+ <id>.m4a(AAC)
node <kit>/scripts/audio.mjs check <id>.ogg <id>.m4a --type sfx|bgm --duration <秒> [--loop [--approx]] [--peak]
#   長度、非靜音(RMS > −50 dBFS)、true peak ≤ −1 dBTP、響度(sfx −20~−12、bgm −20~−16 LUFS)、接縫 RMS 差 ≤ 6 dB(--loop)
node <kit>/schemas/validate.mjs needs|assets <檔案.json> [--root <art/assets>]   # 遊戲素材介面 schema 驗證(--root 檢查檔案存在)
bash <kit>/tests/run.sh                                # 離線自我測試(假 ComfyUI)
bash <kit>/tests/run.sh --live                         # 實機:check + 1 張 512×512 4 步小圖
```

結束碼(comfy.mjs):0 成功;1 一般錯誤 / scrub 找到位址;2 用法或參數錯誤(缺參數、多餘參數、Save* 節點、雲端 API 節點);3 ComfyUI 拒絕或執行失敗(印 node_errors);4 逾時(已中斷自己的工作並刪 history);5 連不上。

**不在伺服器留檔:** 上傳到 temp、輸出用 `PreviewImage` / `PreviewAudio`(`run` 拒絕 `SaveImage`、`SaveAudio` 等 Save* 節點)、下載後刪 history。**不用雲端 API 節點:** `run` 依名稱(Bria、Recraft、Stability…)與 `/object_info` 的 `api_node` 旗標拒絕,送出前就擋下。逾時或中途出錯(含斷線)也會收尾:佇列中的移出、執行中的用 `prompt_id` 只中斷自己的工作,等 history 出現再刪。

## workflow 骨架(`workflows/`)

只放節點結構;`{{key}}` 由 `--set` 填。只有 `_meta.numeric` 列的參數會轉成數字(seed 不可超過 2^53−1),其他(提示詞、檔名)一律是字串。缺參數或多給參數都會結束碼 2(例如 Flux 骨架沒有 `negative`,不能給)。每個檔的 `_meta.params` 列出所有參數與說明。`lora=none` 會拿掉 LoRA 節點。

| 骨架 | 用途 | 實測參數(2026-11,秒數依硬體而異) |
|---|---|---|
| `qwen-t2i` | 文生圖(場景、定裝、UI) | Lightning LoRA:steps 4、cfg 1、euler/simple、shift 3.1(約 30 秒 / 1024²)。不用 LoRA:steps 20、cfg 2.5 |
| `qwen-edit-1ref` / `2ref` / `3ref` | **角色一致**:以 1–3 張參考圖編輯 / 生成新畫面 | Edit Lightning LoRA:steps 4、cfg 1、shift 3.1。提示詞用 `the character in image 1`、`image 2`… 指稱 |
| `flux-t2i` | 文生圖(寫實 / 繪畫感場景) | guidance 3.5、steps 20、euler/simple |
| `flux-kontext` | **角色一致**:1 張參考圖,輸出尺寸跟參考圖 | guidance 2.5、steps 20。臉部細節(疤痕等)保留最好,但每張約 45 秒 |
| `zimage-t2i` | 快速草圖 / UI 示意 | steps 8、cfg 1、res_multistep/simple、shift 3(約 16 秒) |
| `qwen-t2i-canny` | 依草圖線條控制構圖(分鏡指定構圖) | control_strength 0.8、control_end 0.8、steps 20、cfg 2.5 |
| `qwen-t2i-sprite` | **透明 sprite / UI**:文生圖 → RMBG 去背 → `InvertMask` → `JoinImageWithAlpha`,同一個 workflow | 同 qwen-t2i;`bg_model` 用 `RMBG-2.0`(768×1024 全身角色去背乾淨,約 30 秒)。提示詞要 `plain flat light grey background, single subject, full body, centered` |
| `qwen-edit-1ref-sprite` | **角色一致的透明 sprite / 動作格**:以角色 ref 生成新姿勢 + 去背 | 同 qwen-edit-1ref + `bg_model` |
| `stable-audio-sfx` | 音效(Stable Audio 3,本機) | `ckpt` = `defaults.sfx_ckpt`、`clip` = `defaults.sfx_clip`(t5gemma,CLIPLoader type stable_audio);steps 50、cfg 6、dpmpp_3m_sde_gpu / exponential;seconds 比目標長 1 秒(3 秒約 4 秒) |
| `ace-step-bgm` | 配樂(ACE-Step 1.5 turbo,本機,純音樂) | steps 8、cfg 1、shift 3、euler/simple;`lyrics` = `[instrumental]`;另需 `bpm`、`timesignature`(2 / 3 / 4 / 6)、`keyscale`(例如 `C major`);seconds = 目標長度 + 1(循環要多 0.5 秒以上;20 秒約 11 秒) |

模型檔名用 `check` 的 `defaults` 或 STYLE.md 的生成設定,不要寫死。

## 出圖要點(實測)

- **單一角色要寫明** `only one person, single character`:參考圖編輯模型常把角色複製成兩個人。
- 參考圖編輯會保留服裝與髮型,但小細節(疤痕、飾品)容易掉;`character.md` 的識別物要寫進提示詞,看圖時逐項檢查。
- 擴散模型寫不好字:UI 示意上的文字不要求可讀,需要標註時用 `sheet.mjs` 的 caption / note。
- 定裝圖用素色背景、全身、中性姿勢(`full body, standing, plain light grey background`),參考效果最好。
- 去背骨架下載的 PNG 是 RGBA(`run` 輸出 `channels: 4`);接著 `sprite.mjs fit` 再 `check`,不要直接交未裁切的生成圖。
- 音訊只做機械檢查(長度、響度、峰值、非靜音、接縫),沒有人耳試聽;回報要寫明。

## 遊戲素材介面(`schemas/`)

`needs.schema.json`(遊戲端寫 `assets.needs.json`)與 `assets.schema.json`(美術寫 `art/assets/assets.json`)。重點:`width` / `height` 是設計座標的**顯示尺寸**;1x 檔案 = 顯示 × `density`(預設 2,但單張與 frames 整張 sheet 都要 ≤ 2048,超過時 density 往下調;以 `sprite.mjs density` 的輸出為準);`frames` 的尺寸是單格;音訊只有 `durationSec` / `loop`;`nineSlice1x` = `nineSlice` × density 四捨五入;`review` 一律先寫 `pending`。機器可驗證的定義以本 kit 的 schema、`validate.mjs` 與 `sprite.mjs density` 為準(輸出 `lowered: true` 表示 density 被調低);`agent-specs/game-frontend-owner.md`「尺寸定義與素材介面」是文字說明。
