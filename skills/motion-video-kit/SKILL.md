---
name: motion-video-kit
description: 模板動畫短片(資訊圖動畫型,例如米色底 + 吉祥物 + 兩行大標 + 白色卡片內容依旁白彈出 + 逐詞字幕)的固定腳本:模板解析與檢查(kit 預設模板 / 專案模板)、storyboard.json 驗證(schema + at / 圖檔 / focus / 同圖次數)、Qwen3-TTS 旁白(ComfyUI,台灣口音聲音設計或預設聲音;或 macOS say;念法對照表)、旁白念錯字檢查(whisper 轉回文字比對)、固定規則排時間軸與節奏檢查(rhythm)、Chrome CDP + Web Animations 逐格渲染(可重現、網路隔離)、混音(共用 short-video-kit)、擷格、縮圖總表。第一個預設模板 github-hot-pastel(1080×1440、30 fps)。short-video-maker 的 template 模式使用;任何要用模板快速大量產出動畫解說短片的情境也可用。
---

# motion-video-kit

`<kit>` = 這個 skill 的目錄。需要 node ≥ 22、Google Chrome、ffmpeg / ffprobe;旁白用 ComfyUI 的 Qwen3-TTS(透過 game-art-kit 的 `comfy.mjs`,位址在 `~/.config/game-art-kit/config`,本 kit 不讀也不印)。Chrome 啟動 / 收尾沿用 short-video-kit 的 `_chrome.mjs`,混音沿用它的 `_mix.mjs`(都 import,不複製),所以三個 kit 要放在同一個 `skills/` 目錄底下。暫存放 `${SHORT_VIDEO_KIT_TMP:-$TMPDIR/short-video-kit}/`,結束時刪除。

結束碼通則:0 成功;2 輸入不合法(storyboard、路徑、參數;訊息指出欄位);3 缺工具或模板;4 版面放不下;5 ComfyUI 連不上(沿用 comfy.mjs;4 在 `tts.mjs` 是 ComfyUI 逾時);1 其他。

## 腳本

```bash
node <kit>/scripts/check.mjs [--template <名稱或路徑>] [--template-dir <路徑>] [--out <輸出根目錄>]
#   工具(node / Chrome / ffmpeg)+ 模板解析(印實際路徑與來源 path / project / kit)+ template.json 必填欄位;不合格結束碼 3
node <kit>/scripts/tts.mjs <storyboard.json> <輸出目錄> [--design "<聲音描述>"] [--design-seed 11] [--ref "<參考句>"] [--seed 7] [--only 3,5]
node <kit>/scripts/tts.mjs <storyboard.json> <輸出目錄> --preset Vivian [--instruct "<語氣>"]      # Qwen3 預設聲音(偏大陸口音)
node <kit>/scripts/tts.mjs <storyboard.json> <輸出目錄> --engine say [--voice Meijia]           # 派工寫「允許 say」時
#   選填 [--lexicon <專案念法對照表.json>] [--no-lexicon];kit 的 pronunciation.json 預設套用
#   → <輸出目錄>/NNN.wav(48 kHz)、tts.json [{i,text,say,spoken,file,duration,maxVolume,seed,retries,ok,…}]、tts-voice.json(聲音參數)、raw/workflows/(實際送出的參數,不含位址)
node <kit>/scripts/asr.mjs <tts 目錄> [--model <ggml 檔>] [--only 3,5]
#   旁白念錯字檢查:whisper 轉回文字和字幕 text 比對 → <tts 目錄>/asr.json [{i,text,spoken,heard,similarity,diffs:[{expected,heard}]}];有出入也結束碼 0
node <kit>/scripts/render.mjs <storyboard.json> <tts.json> <輸出目錄> --deliver <交付目錄> --asset-root <目錄>[,<目錄>…] [--template-dir <路徑>] [--out <輸出根目錄>] [--dry-run]
#   模板:--template-dir → storyboard 的 template 名稱(先找 <out>/_templates/<名稱>;沒給 --out 時 <out> = --deliver 往上兩層)→ kit
#   stderr 與輸出 JSON 印實際模板與來源(templateSource:project / kit / path);--dry-run 也要給 --deliver 才會找專案模板
#   tts.json 有 ok:false → 結束碼 2(重試與改寫 say 都失敗、仍要照做成品時加 --allow-bad-tts,輸出 badTts);say 和 storyboard 不同 → 結束碼 2
#   輸出目錄:silent.mp4、boxes.json、safe.json、timing.json、scenes.json;交付目錄:subtitles.srt、cover.png;進度印 stderr
node <kit>/scripts/render.mjs --sample [--template-dir <路徑> | --template <名稱>]   # 模板 preview/scene-NN.png + contact.png
node <kit>/scripts/mix.mjs <silent.mp4> <tts.json> <timing.json> <輸出.mp4> [--music <檔>] [--music-volume 0.2] [--sfx <sfx.json>]
node <kit>/scripts/frame.mjs <影片> <秒> <輸出.png>                    # 擷一格當截圖,輸出限 <job>/work/<n>/
node <kit>/scripts/contact.mjs <影片> <輸出.png> [--every 1] [--cols 6] [--width 240]
bash <kit>/tests/run.sh                                                 # 自我測試(SKIP 不算通過)
```

成品驗證用 short-video-kit:`verify.sh <final.mp4> <checks> --size 1080x1440 --safe-json <輸出目錄>/safe.json --boxes <輸出目錄>/boxes.json --cover <交付>/cover.png --scenes <輸出目錄>/scenes.json`。

## 模板

- **預設模板**:`<kit>/templates/<名稱>/`(唯讀;新增或修改走 xhe PR)。目前:`github-hot-pastel`。
- **專案模板**:`<out>/_templates/<名稱>/`(從預設模板 `cp -R` 再改)。
- 解析順序:給的路徑(`--template-dir`,或名稱含 `/`)→ `<out>/_templates/<名稱>`(`check.mjs --out`)→ kit 預設。`render.mjs` 依 storyboard 的 `template` 名稱自動找專案模板(`--deliver` 往上兩層當 `<out>`),也可直接給 `--template-dir`。沒指定 → `github-hot-pastel`。
- 每個模板:`template.html`(版型與場景元件,JS 介面 `MVK.build(data)` / `MVK.seek(t)` 不能改)、`template.json`(必填 `size`、`fps`、`palette`、`fonts`、`scenes`、`mascot`(姿勢 → 檔案,要有 `base`)、`tag`、`safe`(`headline`、`subtitle` 兩個 `[x0,y0,x1,y1]`)、`minFont`(`headline`、`subtitle` px)、`maxLineChars`;選填 `cardInner` `[寬,高]`)、`assets/`、`sample.storyboard.json`、`sample/`(範例圖)、`README.md`(來源、授權、改了什麼、日期)、`preview/contact.png`。
- `palette` 的每個鍵注入成同名 CSS 變數(`--bg`、`--accent`…);`fonts` 只能用系統字型(注入 `--f-<用途>`)。
- 改完專案模板:`check.mjs --template-dir <路徑>` 結束碼 0、`render.mjs --sample --template-dir <路徑>`,Read `preview/contact.png` 與 `scene-NN.png`。

## storyboard.json

格式由 `<kit>/storyboard.schema.json` 定義(`render.mjs` / `tts.mjs` 先驗證)。

```json
{"template":"github-hot-pastel","tag":"GitHub 熱門專案",
 "scenes":[
   {"headline":[["看到喜歡的軟體",""],["想知道","怎麼做的？"]],
    "card":{"type":"compare","left":"img/site.png","right":"img/clone.png","labels":["Original","Clone"],"at":"想知道"},
    "mascot":"think",
    "lines":["看到喜歡的軟體 *想知道* 怎麼做的？",
             {"text":"Craft Anything 先看懂","say":"克拉夫特 安尼辛 先看懂"}]}
 ]}
```

- `headline`:1–2 行,每行 `[黑字, 橘字]`(任一可為空字串,不能都空)。相鄰場景大標相同時不重播。
- `lines`:字串或 `{text, say}`;`say` = TTS 念的文字(念法改寫)。`text` 裡 `*…*` = 橘色膠囊關鍵詞(可含空白),半形空白 = 逐詞分段;字幕顯示時去掉 `*` 與分段空白,相鄰兩段交界都是英數字時保留一個空白(`Craft Anything`)。每句顯示字數 ≤ `maxLineChars`(github-hot-pastel:20),否則結束碼 2。
- `at`:卡片或卡片內元素在哪個分段詞出現(值 = 該場景 `lines` 裡某個分段詞,去掉 `*`);找不到結束碼 2;出現多次取第一次;沒寫 → 場景開始時(卡片內沒寫 `at` 的 items 依序間隔 0.12 秒出現)。
- `mascot`:模板的姿勢名(github-hot-pastel:base / happy / surprised / point / think / thumbs / search),沒寫 = base。
- 場景類型(`card.type`;沒有 `card` = `title`):

| 類型 | 欄位 | 畫面 |
|---|---|---|
| `title` | (沒有 card) | 只有大標;吉祥物跳進卡片中央(放射光 + 星芒),右上吉祥物暫時隱藏 |
| `image` | `src`、`focus?`、`zoom?: in\|none` | 截圖放滿卡片;`focus` = 來源像素 `[x,y,w,h]`,框內區域置中放大(周圍保留上下文)。**圖寬 > 卡片內寬(`cardInner[0]`)1.5 倍時 `focus` 必填**;沒有 focus 時整張等比縮放。`zoom:"in"` 緩慢推近 6% |
| `compare` | `left`、`right`、`labels:[左,右]`、`focus?` | 左右並排(右邊晚 0.45 秒),標籤膠囊(右邊橘色);沒有 focus 時上緣對齊裁切 |
| `terminal` | `lines`(≤ 6)、`typing?` | 深色終端機視窗;`$`/`>`/`#` 開頭的提示符上色;`typing` 逐字打出(場景結束前 0.4 秒打完) |
| `chips` | `items:[{text,at?}]`(≤ 6)、`arrow?` | 膠囊標籤(最後一個橘色),`arrow` 在之間加箭頭 |
| `checklist` | `items:[{text,at?}]`(≤ 5) | 打勾清單,勾勾彈出、文字滑入 |
| `grid` | `cols: 2\|3`、`items:[{text,sub?,at?}]`(4 或 6,要排滿) | 方格卡 |
| `stat` | `value`、`label`、`icon?: star\|none` | 大數字 + 星星旋轉彈出 + 標籤 |
| `cta` | `text`、`sub?` | 橘色大按鈕(呼吸縮放)+ 向下箭頭 + 等寬字副標 |

- 圖片路徑一律相對 `--asset-root`(可給多個,逗號分隔,依序找第一個存在的;解析 symlink 後必須仍在該 root 內;png / jpg / webp)。不存在 → 結束碼 2,**絕不畫佔位框**。同一個圖檔最多用在 2 個場景。
- 卡片內文字放不下時整體縮字到 0.62 倍;仍放不下 → 結束碼 4。

## 旁白(tts.mjs)

- 預設:game-art-kit `qwen3-tts-design`(VoiceDesign 1.7B 依 `--design` 設計聲音 → Base 1.7B 複製念每句;兩個 engine 都 `⚠️ Shared Runtime`)。預設描述是台灣口音年輕女聲(2026-11-24 實測的描述),`--ref` 是設計聲音時念的參考句,`--design-seed` 預設 11。**同一支片 design / ref / design-seed 不要變**,聲音才一致;要換男聲就換 `--design`。
- `--preset <聲音>`:`qwen3-tts`(CustomVoice 1.7B 預設聲音,偏大陸口音),可加 `--instruct`。
- 第 0 步:`comfy.mjs check` 的 `workflows_available.qwen3-tts-design`(或用 `--preset` 時 `qwen3-tts`)要是 `true`。
- 每句去頭尾靜音、轉 48 kHz;長度 > 0.5 秒且 max_volume > −30 dB,不合格換 seed(+101、+202)重生,最多 2 次;仍不合格 `ok:false`、結束碼 1 → 改寫 `say` 後 `--only <句號>` 重跑。
- **念法對照表** `<kit>/pronunciation.json`(`{"words":{"網站":"網 站"}}`):tts.mjs 把念的文字(`say`,沒有就是 `text`)裡的詞換掉再送 TTS,字幕不變,實際念的記在 `tts.json` 的 `spoken`。專案另加或覆蓋用 `--lexicon <檔>`(同格式),`--no-lexicon` 全部不套。每一筆都要有證據:換之前 asr 列出、換之後 asr 正確(來源寫在檔案的 `_來源`)。新增到 kit 的對照表走 xhe PR。
- **念錯字檢查(asr.mjs)**:tts 之後跑。whisper 也會聽錯(專有名詞、台灣口音:2026-11-25 craft-anything 21 句中 9 句有出入,使用者實聽只有「網站」真的念錯),所以**有出入 ≠ 念錯**,不擋交片。處理:有出入的詞改寫 `say` 後 `tts.mjs --only` + `asr.mjs --only`,辨識變正確才採用;改寫法依序試「把詞拆開加空格(網 站)」→ 同音字(往站)→ 換說法(把「例如」換成「像是」對「網站」無效);都不對就保留原句,在回報列「辨識有出入的詞」請人聽。
- 實測(2026-11-24,區網 ComfyUI GB10):聲音設計模式每句約 2–3 秒(模型已載入時)。

## 時間軸與節奏(render.mjs 依固定規則排,不手排)

- 第 1 句 0.3 秒開始;第 i 句 start = 前句 end + 0.25;end = start + TTS 長度;片長 = 最後一句 end + 0.6。字幕逐詞時間依字數比例(中日韓字 1、英數字詞 1、標點 0);**已知限制**:關鍵詞亮起可能和實際發音差 0.1–0.3 秒。
- 場景 j:start = 0(j = 0)或第一句的 start;end = 下一場景第一句的 start,最後一個 = 片長(`scenes.json`,同 compose)。
- `timing.json`:`{"duration","sentences":[{"i","start","end","text","words":[{"w","start","end","hl"}]}],"scenes":[{"start","end","type","mascot"}],"changes":[…],"cardEmpty":[{"start","end"}],"rhythm":{"maxEmpty","minInterval","maxInterval","ok"}}`。
  - `changes` = 每個場景開始 + 每個 `at` 元素出現時間(排序、去重)。
  - `cardEmpty` = 非 `title` 場景中卡片區還沒有任何元素的區間。
  - `rhythm.ok` = `maxEmpty` ≤ 2 且相鄰 `changes` 間隔都在 2–4 秒(第 1 句之前與片尾 0.6 秒不計;單句 > 4 秒而句內沒有 `at` 判失敗)。不合格時 stderr 印「節奏提醒」逐條說明。
  - 經驗:`at` 會新增一次變化,同場景兩個 `at` 要相隔 ≥ 2 秒;第一個元素不要用 `at`(否則卡片空檔、間隔太短),後面的句子才用。
- `--dry-run`:印 `{duration, rhythm, timing}`,不開 Chrome、不寫檔。片長 > 60 秒時正式渲染結束碼 2。
- `boxes.json`:`[{file,kind,x,y,w,h,fontSize}]`,`kind` = `subtitle`(每句一筆)| `headline`(每組大標一筆);`safe.json` = `{"subtitle":[…],"headline":[…]}`(模板 `safe`),給 `verify.sh --safe-json`。字幕先試單行再試兩行,62 px 縮到 `minFont.subtitle`;大標每行單行,116 px 縮到 `minFont.headline`;放不下結束碼 4 → 拆句或縮短大標。
- `cover.png`:第一個場景結束前 0.2 秒那一格(大標已在畫面上,不另疊字)。

## 渲染(可重現、網路隔離)

- Chrome headless(`--disable-gpu` 軟體繪製)開模板 `template.html`(file://),`MVK.build(data)` 建好整支片的 DOM 與 Web Animations(全部暫停),逐格把所有動畫的 `currentTime` 設成該格時間、等一個 animation frame 再 `Page.captureScreenshot`(JPEG 92)→ ffmpeg(libx264 crf 16、yuv420p、tv range、faststart)。不掉格、不受機器快慢影響;同輸入渲染結果相同(2026-11-24 實測 5 次 MP4 逐位元相同;測試比對第 0 / 中 / 末格 PNG 雜湊)。用 GPU 繪製或不等 animation frame 時,縮放動畫中的字形偶爾有肉眼看不出的像素差。
- CDP `Fetch` 只放行 `file://` 與 `data:`,其他請求擋下並列在 `blockedRequests`;storyboard 內容一律 `textContent`,`<script>` / `<img>` 只會被當文字顯示。
- **渲染速度**(2026-11-24 實測,本機 Apple Silicon、`tests/run.sh` 第 11 項,github-hot-pastel 1080×1440 30 fps、軟體繪製):**60 秒片(59.5 秒、1785 格)render.mjs 約 93 秒**(擷圖 + 編碼 ≈ 1.6 倍片長;mix.mjs 另約 3 秒);9 個場景 32.8 秒的範例片約 53 秒;`--sample` 約 10 秒。粗估 render 秒數 ≈ 片長 × 1.6。render + mix + verify 在單次 Bash 600 秒內做得完,但機器忙碌時會變慢,60 秒片的 render 建議背景執行並等完成通知。

## 混音(mix.mjs)

旁白依 `timing.json` 排程、配樂(`--music`,預設 volume 0.2)說話時 sidechain 壓低、結尾 1.5 秒淡出、音效(`sfx.json` = `[{"path":相對 sfx.json,"at":秒,"volume":0~2}]`,≤ 3 個)、loudnorm 兩階段(−14 LUFS、TP −1.5);影片串流直接複製。實作在 short-video-kit `scripts/_mix.mjs`(compose.mjs 共用)。

## 已知限制

- Qwen3 `--preset` 聲音偏大陸普通話口音(預設改用聲音設計的台灣口音);比 `say` 慢。
- 逐詞時間依字數比例,不是實際發音對齊。
- 3:4 成品上傳 Shorts / Reels 會有上下黑邊或被裁成 9:16 顯示。
- 字型用系統 PingFang TC(粗體用 600 + 描邊加粗),非 macOS 環境字形會不同。
