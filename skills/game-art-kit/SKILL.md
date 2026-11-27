---
name: game-art-kit
description: 遊戲示意圖、分鏡與遊戲素材用的 ComfyUI 固定腳本:位址解析(本機設定,不進 git)、check(模型、模型家族、可用的角色一致性方法、本機去背、音訊模型)、上傳參考圖到 temp、送 workflow 並輪詢下載圖片與音訊(含逾時、刪 history、不在伺服器留檔、拒絕雲端 API 節點)、workflow 技術骨架(Qwen-Image、Qwen-Image-Edit 1–3 張參考圖、Flux、Flux Kontext、Z-Image、ControlNet canny、同 workflow 去背的透明 sprite、Stable Audio 音效、ACE-Step 配樂、Qwen3-TTS 旁白(預設聲音 / 台灣口音聲音設計)、LTX-2.3 / Wan 2.2 圖生影片(逐格輸出))、角色動作圖(actions.mjs:Codex 以預設圖出表情 / 姿勢候選,ChatGPT 方案額度,事件白名單、張數累計;8 種動作提示詞範本)、角色語音(voice.mjs:ElevenLabs 設計 / 選定 / 台詞雜湊增量、字元累計、金鑰掃描)、拼分鏡表、sprite.mjs(純 Node PNG 裁切 / 對齊 / 拼 sheet / 檢查 / 清理 / 頭像)、audio.mjs(ffmpeg 響度 / 循環 / ogg + m4a / 檢查)、遊戲素材介面 schema(needs / assets)、產出不含位址檢查。game-concept-artist 出圖與做遊戲素材時使用;game-frontend-owner 用 schema 寫素材需求;short-video-maker 生成短影音的 AI 插圖、動態鏡頭、配樂、音效、旁白時也使用;任何要用區網 ComfyUI 批次出圖、出影片或出音效的情境也可用。
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
#   --timeout 只算開始執行後;排隊等待另算(--queue-timeout,預設 180);下載另算(--download-timeout,預設 60)。預設值已符合下面的規則。三者相加(≤ 480)要比呼叫端(例如 Bash 工具,最長 600 秒)的逾時
#   少 180 秒以上(`--timeout` + `--queue-timeout` + `--download-timeout` > 480 直接結束碼 2;送出前要節點旗標:用 `check` 存在 `~/.cache/game-art-kit/` 的快取,1 小時內、而且 workflow 的節點都在快取裡就不另外抓;用 RMBG 的骨架必須先跑過 check;沒有快取時抓 `/object_info` 最多 30 秒(落在 180 秒餘量內),所以**先跑 check 再 run**;時限到了之後:偵測最多約 50 秒、下載上限 `--download-timeout`(預設 60 秒)、收尾上限 40 秒),例如 --timeout 240 --queue-timeout 180 配 600 秒;否則會被外部中止而拿不到 timeout 結果。被 Ctrl-C / SIGHUP / SIGTERM 中止時取消自己的工作再結束(130 / 129 / 143)
#   → <目錄>/<檔名>.png(去背骨架是 RGBA)或 <檔名>.<伺服器給的音訊副檔名>(通常 .flac)、<目錄>/workflows/<檔名>.json(實際送出的參數,不含位址);
#     印 {"status":"ok","seconds":…,"files":[{file,width,height,channels} 或 {file,kind:"audio",bytes}]}
#   逾時印 {"status":"timeout","reason":"run|queue|total","seconds":<設定的上限>,"elapsed":<實際秒數>}
node <kit>/scripts/comfy.mjs pngsize <圖>              # {"width":…,"height":…}
node <kit>/scripts/comfy.mjs scrub-check <目錄> [--paths]   # 產出含 ComfyUI 位址 / 私有 IP / :8188 → 結束碼 1;--paths 另查 $HOME、/Users/、/home/、generated_images(角色動作 / 語音用)
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
node <kit>/scripts/sprite.mjs clean <透明圖> --out <out.png> [--key-white]
#   角色動作圖清理:alpha 依 16..250 拉開(人物調實、背景霧清掉)→ 只留跟中間直帶連在一起的塊 → 離實心處 > 4 px 的淡線透明;--key-white 只給白底不透明圖。
#   印 {ok,errors,coverage,border,touches};碰邊(touches)或覆蓋率不對 → 結束碼 1
node <kit>/scripts/sprite.mjs headshot <透明圖> --anchor x,y,h --out <avatar.png> [--size 256] [--zoom 1.15] [--pad l,t,r,b]   # 依頭中心 / 頭高(0–1)裁方形頭像
node <kit>/scripts/actions.mjs prompt|gen|masks|sheet …   # 角色動作(Codex,見下方「角色動作」)
node <kit>/scripts/voice.mjs design|pick|plan|lines|status|scan …   # 角色語音(ElevenLabs,見下方「角色語音」)
node <kit>/scripts/audio.mjs process <下載的音訊> --type sfx|bgm|voice --duration <秒> --out <目錄> --name <id> [--loop]
#   sfx:去頭尾靜音、裁到 ≤ duration、−16 LUFS(短於 0.4 秒改峰值正規化,輸出 normalized: peak,check 要加 --peak);bgm:裁到 duration(--loop 頭尾 0.5 秒交叉淡化,輸入要 ≥ duration + 0.5)、−18 LUFS;
#   限幅器保證 true peak ≤ −1.5 dBTP;輸出 <id>.ogg(Opus)+ <id>.m4a(AAC)
node <kit>/scripts/audio.mjs check <id>.ogg <id>.m4a --type sfx|bgm|voice --duration <秒> [--loop [--approx]] [--peak]
#   長度、非靜音(RMS > −50 dBFS)、true peak ≤ −1 dBTP、響度(sfx −20~−12、bgm −20~−16 LUFS)、接縫 RMS 差 ≤ 6 dB(--loop)
node <kit>/schemas/validate.mjs needs|assets <檔案.json> [--root <art/assets>]   # 遊戲素材介面 schema 驗證(--root 檢查檔案存在)
bash <kit>/tests/run.sh                                # 離線自我測試(假 ComfyUI)
bash <kit>/tests/run.sh --live                         # 實機:check + 1 張 512×512 4 步小圖
```

結束碼(comfy.mjs):0 成功;1 一般錯誤 / scrub 找到位址;2 用法或參數錯誤(缺參數、多餘參數、Save* 節點、雲端 API 節點);3 ComfyUI 拒絕或執行失敗(印 node_errors);4 逾時(已中斷自己的工作並刪 history);5 連不上。

**不在伺服器留檔:** 上傳到 temp、輸出用 `PreviewImage` / `PreviewAudio`(`run` 拒絕 `SaveImage`、`SaveAudio` 等 Save* 節點)、下載後刪 history。**不用雲端 API 節點:** `run` 依名稱(Bria、Recraft、Stability…)與 `/object_info` 的 `api_node` 旗標拒絕,送出前就擋下。逾時或中途出錯(含斷線)也會收尾:佇列中的移出、執行中的用 `prompt_id` 只中斷自己的工作,等 history 出現再刪。

## workflow 骨架(`workflows/`)

只放節點結構;`{{key}}` 由 `--set` 填。只有 `_meta.numeric` 列的參數會轉成數字(`_meta.max` 列了上限的參數超過就結束碼 2,例如 `wan22-i2v` 的 `length` ≤ 97)(seed 不可超過 2^53−1),其他(提示詞、檔名)一律是字串。缺參數或多給參數都會結束碼 2(例如 Flux 骨架沒有 `negative`,不能給)。每個檔的 `_meta.params` 列出所有參數與說明。`lora=none` 會拿掉 LoRA 節點。

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
| `ltx23-i2v` | **圖生影片(優先)**:第一格 = 參考圖,LTX-2.3 + 8 步蒸餾 LoRA,cfg 1(負向提示詞固定在骨架裡) | 704×1280、`length` = 8k+1(24 fps,121 格 ≈ 5 秒):121 格約 110 秒(含載入模型),49 格約 40 秒。`run` 加 `--queue-timeout 120 --download-timeout 90`(121 張 PNG 約 140 MB;240 + 120 + 抓 /object_info 30 + 偵測 50 + 90 + 收尾 40 = 570 秒 < 600)。`lora` 用 `defaults.ltx_distill_lora`(主機只有已蒸餾的 checkpoint 時是 `none`)。同名重跑時 `run` 只覆寫 `<name>-1..N`,上一輪多出來的格數還在:組影片用 short-video-kit 的 `frames.sh --frames N`(N = 這次的 `length`)只取 1..N。動作與運鏡明顯,但背景偶爾冒出亂碼字,逐格看圖 |
| `wan22-i2v` | 圖生影片(備援,`ltx23-i2v` 不可用時) | 704×1280、`length` = 4k+1,**上限 97 格(≈ 4 秒)**、steps 20、cfg 5、shift 8、uni_pc/simple:97 格約 270 秒,121 格約 340 秒(冷啟動再加載入模型的時間,會逼近時限,所以不用 121 格;`--timeout 360 --queue-timeout 40`,下載維持預設 60 秒:360 + 40 + 30 + 50 + 60 + 40 = 580 秒;主機忙碌排隊超過 40 秒會逾時,改用 LTX 或稍後再試;慢速網路下載不完時改用 LTX 或縮短格數),49 格約 110 秒。畫面穩、動作小 |
| `ace-step-bgm` | 配樂(ACE-Step 1.5 turbo,本機,純音樂) | steps 8、cfg 1、shift 3、euler/simple;`lyrics` = `[instrumental]`;另需 `bpm`、`timesignature`(2 / 3 / 4 / 6)、`keyscale`(例如 `C major`);seconds = 目標長度 + 1(循環要多 0.5 秒以上;20 秒約 11 秒) |
| `qwen3-tts-design` | **旁白(台灣口音,motion-video-kit `tts.mjs` 預設)**:VoiceDesign 1.7B 依 `design` 描述設計聲音(念 `ref` 參考句)→ Base 1.7B 複製該聲音念 `text`;兩個 engine 都 `⚠️ Shared Runtime` | 同一支片 `design` / `ref` / `dseed` 固定,聲音才一致;`seed` 控制念法。`check`:`workflows_available.qwen3-tts-design` 要主機有 `local:Qwen3-TTS-12Hz-1.7B-VoiceDesign` 與 `-Base` 和 `UnifiedVoiceDesignerNode`。`--timeout 200 --queue-timeout 60` |
| `qwen3-tts` | 旁白(Qwen3 預設聲音,偏大陸口音):CustomVoice 1.7B,`voice`(Vivian 等)+ `instruct` 語氣指示 | `variant` = `defaults.tts_variant`;`runtime_mode` 固定 `⚠️ Shared Runtime`(2026-11-24 實測 Main Environment 載入失敗,只回 1 秒靜音);seed ≤ 4294967295 |

模型檔名用 `check` 的 `defaults` 或 STYLE.md 的生成設定,不要寫死。

## 出圖要點(實測)

- **單一角色要寫明** `only one person, single character`:參考圖編輯模型常把角色複製成兩個人。
- 參考圖編輯會保留服裝與髮型,但小細節(疤痕、飾品)容易掉;`character.md` 的識別物要寫進提示詞,看圖時逐項檢查。
- 擴散模型寫不好字:UI 示意上的文字不要求可讀,需要標註時用 `sheet.mjs` 的 caption / note。
- 定裝圖用素色背景、全身、中性姿勢(`full body, standing, plain light grey background`),參考效果最好。
- 去背骨架下載的 PNG 是 RGBA(`run` 輸出 `channels: 4`);接著 `sprite.mjs fit` 再 `check`,不要直接交未裁切的生成圖。
- **影片骨架逐格輸出**:ComfyUI 沒有不存檔的影片預覽節點(`SaveVideo` 會留檔,`run` 拒絕),所以影片骨架用 `PreviewImage` 輸出每一格,`run` 下載成 `<name>-1.png … <name>-N.png`(121 格 704×1280 約 140 MB,有線區網實測 60 秒內下載完;Wi-Fi 等慢速網路加大 `--download-timeout` 時要同時調小 `--queue-timeout`,三者合計 ≤ 480,例如 LTX 用 `--queue-timeout 60 --download-timeout 180`);組成影片用 short-video-kit 的 `frames.sh`。LTX-2.3 會同時生成音訊,骨架直接丟棄。
- 音訊只做機械檢查(長度、響度、峰值、非靜音、接縫),沒有人耳試聽;回報要寫明。

## 角色動作(`actions.mjs`,Codex)

立繪級的表情 / 姿勢集(不是動畫格)。**用使用者 ChatGPT 方案額度**(`codex exec`;`codex login status` 必須是「Logged in using ChatGPT」,否則結束碼 2;子程序環境拿掉 `OPENAI_API_KEY` / `CODEX_API_KEY`)。會把底圖送到 OpenAI:只在簡報有使用者同意旗標時用。

設定檔 `art/characters/<id>/actions/actions.json`:`id`、`name`、`pronoun`(he / she / they)、`base`(相對 `art/`,不寫本機絕對路徑)、`style`、`features`、`outfit`、`hands`(選填)、`anchor {x,y,h}`(0–1,在選定的 idle1 上估)、`count`(預設 2)、`candidates.<動作>`、`picks.<動作> = {n, reason}`、`actions.<動作>` 覆寫(expr / pose / extra)。

```bash
node <kit>/scripts/actions.mjs prompt --config <actions.json> --action happy
node <kit>/scripts/actions.mjs gen    --config <actions.json> --action happy --out-dir art/out/<日期>-actions-<id> --budget <tmp>/<派工 id>/budget.json --limit <M> --run <派工 id> [--timeout 540]
#   一次一張(約 1–3 分鐘)→ <out-dir>/<動作>-<n>.png(n 往上編號)、追加 manifest.json;結束碼:3 沒出圖("quota":true = 額度上限,停止)、4 逾時(殺程序群組)、
#   6 超過 M 張(沒送出)、7 Codex 用了白名單以外的工具(item 只允許 agent_message / reasoning / todo_list / error 與 image_gen* 開頭的出圖工具;不採用、停止剩下的動作)
node <kit>/scripts/actions.mjs masks  --config <actions.json> --image <選定的 idle1> --out art/out/<日期>-actions-<id>/masks.png   # anchor 預覽
node <kit>/scripts/actions.mjs sheet  --out art/characters/<id>/actions/sheet.png <底圖> <候選>...
node <kit>/scripts/sprite.mjs clean <選定候選> --out art/characters/<id>/actions/<動作>.png
node <kit>/scripts/sprite.mjs headshot art/characters/<id>/actions/idle1.png --anchor x,y,h --out art/characters/<id>/actions/avatar.png
```

- Codex 的圖從 `$CODEX_HOME/generated_images/<thread id>/` 抄出後就刪掉該目錄(thread id 要是 UUID、realpath 在 generated_images 底下);manifest 不記本機路徑。
- 實測(2026-11,codex-cli 0.172):一張 57 秒–3 分鐘,1024×1536 透明 PNG;`--json` 事件只有 `agent_message`(出圖工具不出現在事件裡);臉、服裝、尾巴與底圖一致,表情與姿勢照指示改。
- 已知限制:codex 0.172 沒有能關掉 shell 工具的旗標,白名單是事後偵測(資料可能已送出),違規就整批停下。

## 角色語音(`voice.mjs`,ElevenLabs)

付費:只在簡報有「使用者同意 ElevenLabs 付費:最多 N 字元」時用。金鑰:環境變數 `ELEVENLABS_API_KEY` 或 `~/.elevenlabs/.env`(`ELEVENLABS_API_KEY=...`,chmod 600,使用者自己建立,不貼進對話);只進記憶體。字元 = 送出文字的長度(含 `[sweetly]` 這類標記)。

`art/characters/<id>/voice.json`:`design`(英文描述;不寫真實人物 / 既有角色的名字)、`design_notes`、`design_source`、`preview_text`(100–1000 字元)、`voice_name`、`models`(預設 `eleven_ttv_v3` / `eleven_v4` / `mp3_44100_128`)、`stability`(0.5)、`candidates`、`voice_id`、`prev_voice_id`、`line_seeds`、`lines`(key → 雜湊)。

```bash
node <kit>/scripts/voice.mjs design --voice <voice.json> --out-dir art/out/<日期>-voice-<id> --budget … --limit <N> --run <派工 id> [--redesign]   # 3 個候選 → 請使用者試聽
node <kit>/scripts/voice.mjs pick   --voice <voice.json> --n 2 [--repick]           # 建成正式 voice(已選定要換選加 --repick,舊的留 prev_voice_id)
node <kit>/scripts/voice.mjs plan   --voice <voice.json> --lines <lines.json> [--out art/voice/<id>]   # 首次字元、含重錄最多字元
node <kit>/scripts/voice.mjs lines  --voice <voice.json> --lines <lines.json> --out art/voice/<id> --raw-dir art/out/<日期>-voice-<id> --budget … --limit <N> --run <派工 id> [--all] [--max-seconds 480]
node <kit>/scripts/voice.mjs status --voice <voice.json> --lines <lines.json> --out art/voice/<id>
node <kit>/scripts/voice.mjs scan   --art art          # 金鑰完全比對(只印有 / 無與檔名)
```

- 字元在**每次 HTTP 嘗試**前都記(逾時 / 5xx 重試的請求服務端可能已計費;429 限流退回);`plan` 的 `max_chars` 含重錄、不含網路重試,上限 N 宜留一點餘裕;試聽候選的長度上限是 60 秒;錄音先放過程目錄的 `stage/`,check 通過才換掉 `art/voice/` 的成品(失敗不蓋掉原本好的);超過 15 秒不重錄(請拆句)。
- 台詞 key 要符合 `^[a-z0-9][a-z0-9._-]*$`(不合 → 整批結束碼 2)。雜湊 = sha256(JSON([原文, voice_id, tts 模型, stability, output_format, seed]));只重錄雜湊不同或缺檔的;check 不過換 seed 重錄,每句最多 2 次;每句完成就存。
- 結束碼:1 有句子不合格;3 HTTP 錯誤(429 / 409 / 5xx 已退避重試,最多 5 次嘗試 = 4 次重試);4 額度用完(402 / 401 quota);5 金鑰錯誤或找不到;6 超過字元上限(沒送出);8 帳號 voice 名額已滿。
- 測試:`ELEVENLABS_API_URL` 只接受 `http://127.0.0.1:<埠>`,有設時用假金鑰、不讀真的。尚未以真實帳號實測(使用者買了 ElevenLabs 之後補)。

## 付費用量累計(`budget.mjs`)

角色動作的張數(M)與角色語音的字元(N)都記在本次派工專屬的累計檔(`$TMPDIR/game-art-kit/<name>/<派工 id>/budget.json`);每次送出前檢查「累計 + 本次 ≤ 上限」,超過不送(結束碼 6)。manifest 每筆記派工 id 與當時累計值。

## 遊戲素材介面(`schemas/`)

`needs.schema.json`(遊戲端寫 `assets.needs.json`)與 `assets.schema.json`(美術寫 `art/assets/assets.json`)。重點:`width` / `height` 是設計座標的**顯示尺寸**;1x 檔案 = 顯示 × `density`(預設 2,但單張與 frames 整張 sheet 都要 ≤ 2048,超過時 density 往下調;以 `sprite.mjs density` 的輸出為準);`frames` 的尺寸是單格;音訊只有 `durationSec` / `loop`;`nineSlice1x` = `nineSlice` × density 四捨五入;`review` 一律先寫 `pending`。機器可驗證的定義以本 kit 的 schema、`validate.mjs` 與 `sprite.mjs density` 為準(輸出 `lowered: true` 表示 density 被調低);`agent-specs/game-frontend-owner.md`「尺寸定義與素材介面」是文字說明。
