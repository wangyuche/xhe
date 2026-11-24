# short-video-maker 規格增補：模板動畫模式(`template`)與 motion-video-kit

主規格見 `short-video-maker.md`,agent 本體 `agents/short-video-maker.md`。本檔只寫新增與改變的部分;沒寫到的沿用主規格。成功標準編號以 agent 本體為準(現有 1–14)。

## 為什麼要加(2026-11-24)
- 使用者評 2026-11-24 兩支用 ComfyUI 重做的短片(astryx/2、craft-anything/4)「做得很爛」。實際問題:實機畫面只佔上 2/3、下方 1/3 純色空白;UI 字太小;AI 畫面只在結尾、同一張圖用 3 次;文字卡插畫中間有空的佔位框;`say` 旁白機械。
- 使用者給了參考影片(資訊圖動畫型短片:米色底、吉祥物、兩行大標、白色卡片內容依旁白逐步彈出、逐詞字幕加關鍵詞膠囊),要求「這樣的影片模式」,並希望**做成模板,之後去網路找模板、快速大量產出**。
- 這修改主規格「配色每支自己選、kit 沒有預設配色、不要共用模板」(使用者 2026-11-21):**只在 `template` 模式**改由模板決定版型與配色;其他模式照舊。使用者 2026-11-24 補充:「我們有一些預設模板,但它也可以創專案用的模板」→ 兩層模板。
- `RULES.md` short-video-maker「kit 沒有預設配色」那列要加例外:template 模式由 `template.json` 決定配色(結構:motion-video-kit 只讀模板配色;short-video-kit 照舊),來源寫「2026-11-24 使用者要求」。

## 已與使用者確認
- 架構:一個渲染引擎 skill(`motion-video-kit`)+ 模板(資料,不是 skill)+ 之後另做 `video-template-forge`(把網路模板 / 參考影片轉成原創模板,**本次不做**,另立規格)。
- 模板分兩層:kit 內的**預設模板**(走 xhe PR)與輸出目錄下的**專案模板**(agent 依派工建立 / 修改)。
- 第一個預設模板 `github-hot-pastel`,畫面比例照參考影片 3:4。
  - 沿用參考影片的:版面結構(左上標籤、右上吉祥物、兩行大標、中央白色粗框卡片、底部逐詞字幕)、米色底加淡色幾何圖形、黑字配橘色重點字、橘色膠囊關鍵詞、卡片內容依旁白逐步出現的節奏。
  - 不沿用:參考影片的柴犬角色、它的確切配色值與字型檔、任何截圖或圖示素材。
  - 吉祥物:使用者選定的 ComfyUI 機器人(戴耳機、拿放大鏡)。從 `/Volumes/ariesdisk/Data/git/videoclip/_brand/mascot-robot/` 複製 7 張到 `templates/github-hot-pastel/assets/mascot/`:`base.png`(預設)、`happy.png`、`surprised.png`、`point.png`、`think.png`、`thumbs.png`、`search.png`;姿勢名 = 檔名去掉 `.png`。`_sheet.png` 是總覽圖,不複製。
- 旁白用 ComfyUI 的 Qwen3-TTS(CustomVoice 1.7B,預設聲音 Vivian;使用者試聽後說「Qwen3 都很棒」)。必須用 `runtime_mode = ⚠️ Shared Runtime`(實測 2026-11-24:Main Environment 載入失敗 `'default'`,只回 1 秒靜音)。
- 第一支實測片:Craft Anything(文案以 `20261118-craft-anything/3/script.md` 為基礎)。

## 技術選擇(自己判斷,附理由)
- **動畫:HTML/CSS 動畫 + Web Animations API 逐格定位,零外部依賴。** 每格把頁面上所有動畫 `currentTime` 設成該格時間(`document.getAnimations()`),CDP `Page.captureScreenshot` 擷圖,串給 ffmpeg 編碼。理由:可重現、不掉格、不受機器快慢影響;沿用 short-video-kit 的 Chrome CDP;不引入 GSAP / Remotion(授權與依賴另議)。Lottie 留給 forge 階段(需要時 vendor `lottie-web`,MIT)。
- **網路隔離:** CDP `Fetch` 擋掉所有非 `file://` 請求;內容一律 `textContent` 放入;字型用系統 PingFang TC。
- **圖片路徑:** storyboard 裡的圖片路徑一律相對 `--asset-root`(可給多個,依序找第一個存在的;解析 symlink 後必須仍在該 root 內),模板自己的素材相對模板目錄。不存在 → 結束碼 2,**絕不畫佔位框**。
- **逐詞時間(決定):v1 依字數比例分配**(英數字詞以 1 個中文字計,標點 0)。理由:ComfyUI 上的 `UnifiedASRTranscribeNode` 輸出是 STRING,`comfy.mjs run` 只下載圖片與音訊,要改客戶端才拿得到;收益(關鍵詞早晚 0.1–0.3 秒)不值得這次做。列為已知限制,之後再評估 aligner。
- **規格:** 尺寸、fps 由模板決定(`github-hot-pastel`:1080×1440、30 fps);其餘(H.264 yuv420p、AAC 48 kHz、faststart、≤ 60 秒、−14 LUFS ±1、true peak ≤ −1 dBTP)同主規格。

### 模板
- 預設模板:kit 內 `templates/<名稱>/`,agent 唯讀。專案模板:`<out>/_templates/<名稱>/`。
- 解析順序:派工給的模板路徑 → `<out>/_templates/<名稱>` → kit 預設模板;回報寫明用的是哪一個(路徑)。派工沒指定模板 → `github-hot-pastel`。
- 每個模板:`template.html`(版型與場景元件)、`template.json`(必填:`size`、`fps`、`palette`、`fonts`、`scenes`(支援的場景類型)、`mascot`(姿勢 → 檔案)、`tag`(預設標籤文字)、`safe`(`headline` 與 `subtitle` 兩個矩形 `[x0,y0,x1,y1]`)、`minFont`(字幕與標題縮字下限)、`maxLineChars`(每句字數上限))、`assets/`、`sample.storyboard.json`(9 種場景示範)、`README.md`(來源、授權、改了什麼、日期)、`preview/contact.png`。

### 劇本格式 `storyboard.json`(格式由 `storyboard.schema.json` 定義,`render.mjs` 先驗證,不合結束碼 2 並指出欄位)
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
- `headline`:1–2 行,每行 `[黑字, 橘字]`(任一可為空字串)。
- `lines`:每項是字串或 `{text, say}`;`say` 是 TTS 念的文字(念法改寫用),沒有就念 `text`。`text` 裡 `*…*` = 橘色膠囊關鍵詞,半形空白 = 逐詞分段;**字幕顯示時去掉 `*` 與分段空白**(英文詞之間的空白保留為一個)。每句顯示字數 ≤ `maxLineChars`(github-hot-pastel:20)。
- `at`:卡片或卡片內元素在哪個詞出現(值 = 該場景 `lines` 裡某個分段詞,去掉 `*` 後比對)。找不到 → 結束碼 2;出現多次 → 取第一次;沒寫 → 場景開始時出現。
- 場景類型與最小欄位:
  - `title`:沒有 `card`(只有大標)。
  - `image`:`{"type":"image","src":"img/a.png","focus":[x,y,w,h],"zoom":"in|none"}`;`focus` 是來源像素座標的放大區域。來源寬度 > 卡片內寬 1.5 倍時 `focus` 必填(否則結束碼 2,避免 UI 字太小)。
  - `compare`:`{left, right, labels:[左,右], focus?:[…]}`。
  - `terminal`:`{"type":"terminal","lines":["$ npx craft-anything"],"typing":true}`(最多 6 行)。
  - `chips`:`{"type":"chips","items":[{"text":"Claude Code","at":"Claude"},…],"arrow":true|false}`(最多 6 個)。
  - `checklist`:`{"type":"checklist","items":[{"text":"對應路由","at":"路由"},…]}`(最多 5 項)。
  - `grid`:`{"type":"grid","cols":2,"items":[{"text":"Codex","sub":"可選"},…]}`(2×2 或 2×3)。
  - `stat`:`{"type":"stat","value":"9.5 萬","label":"GitHub 星星","icon":"star|none"}`。
  - `cta`:`{"type":"cta","text":"去 GitHub 搜尋","sub":"storytold/craft-anything"}`。
- 同一個圖檔最多用在 2 個場景(`render.mjs` 檢查,超過結束碼 2)。

### 時間軸(`render.mjs` 依固定規則排,agent 不手排)
- 第 1 句 0.3 秒開始,第 i 句 start = 第 i−1 句 end + 0.25 秒,end = start + TTS 實測長度;場景長度 = 所屬句子;片尾 + 0.6 秒。
- 片長 = 依此公式算出的總長;`render.mjs --dry-run` 印出片長、`timing.json` 與 `rhythm`,不擷圖。
- `scenes.json`(給 verify,規則同 compose):場景 j 的 start = 0(j=0)或該場景第一句的 start;end = 下一場景第一句的 start,最後一個場景 = 片長。場景首尾相接、無空檔。
- `timing.json` 格式(固定):`{"duration":秒,"sentences":[{"i","start","end","text","words":[{"w","start","end","hl":bool}]}],"scenes":[{"start","end","type","mascot"}],"changes":[秒…],"cardEmpty":[{"start","end"}],"rhythm":{"maxEmpty","minInterval","maxInterval","ok"}}`。`changes` = 每個場景開始 + 每個 `at` 元素出現的時間(排序、去重);`cardEmpty` = 非 `title` 場景中卡片區還沒有任何元素的區間;`rhythm.ok` = `maxEmpty` ≤ 2 且相鄰 `changes` 間隔都在 2–4 秒(第 1 句之前與片尾 0.6 秒不計;單句 > 4 秒且句內沒有 `at` 時判失敗)。成功標準 16、19 直接引用 `rhythm`。
- `boxes.json` 每筆 `{file,kind,x,y,w,h}`,`kind` = `subtitle` | `headline`;`safe.json` = `{"subtitle":[x0,y0,x1,y1],"headline":[x0,y0,x1,y1]}`。`verify.sh` 依 `kind` 比對對應矩形,沒有 `kind` 的當 `subtitle`(既有測試不受影響)。

## agent 的 `template` 模式流程
觸發:派工寫「模板模式」或指定模板名稱;輸入可以是 repo 或主題 / 文案。

**建立 / 修改專案模板**(派工寫「建立專案模板 <名稱>」或「修改專案模板 <名稱>」時才做):
- 從預設模板(派工指定,沒指定用 `github-hot-pastel`)複製到 `<out>/_templates/<名稱>/` 再改;不從零寫。已存在且派工寫「建立」→ BLOCKED(提議改名或改成「修改」)。
- 可以改:`template.json` 的 `palette`、`fonts`(只能用系統字型)、`tag`、`mascot`、`size`(只能 1080×1920 / 1080×1440 / 1080×1080,`safe` 要跟著改);`assets/`(只能放 ComfyUI 生成的原創圖或派工給的本機檔);`template.html` 的 CSS 變數與版面樣式。不能改:場景元件的 JS 介面、網路隔離。
- 新吉祥物:game-art-kit `qwen-t2i-sprite` 出定裝圖 → `qwen-edit-1ref-sprite` 出 6 個姿勢(happy / surprised / point / think / thumbs / search);每張 Read 檢查一致性;不仿製既有角色。輸出到 `<out>/_templates/<名稱>/assets/mascot/`。
- 改完必跑 `check.mjs --template-dir <路徑>` 與 `render.mjs --sample --template-dir <路徑>`(寫 `preview/contact.png` 與 `preview/scene-NN.png`),Read 後才算完成;`README.md` 記錄來源模板、改了什麼、日期。

**製作一支片:**
1. 第 0 步(不建立檔案;例外同主規格):
   - `check.sh --no-say`(只檢查 ffmpeg / ffprobe / node / Chrome;派工寫「允許 say」時不加 `--no-say`)。
   - `node <motion-video-kit>/scripts/check.mjs --template <名稱或路徑>`。
   - `comfy.mjs check`:`workflows_available.qwen3-tts` 必須為 `true`。
   - 其餘同主規格(模式、`<slug>`、工作目錄、來源指紋、旗標)。
2. 內容:repo 輸入照 `repo-cards` 第 1 步讀 repo、挑亮點(沒有執行旗標就不執行);主題 / 文案照 `topic` 第 1 步。截圖來源只能是:repo 內圖檔(`--asset-root <job>/work/repo` 或本機非 git 目錄本身)、`repo-record` 錄影(有執行旗標)用 `frame.mjs` 擷格、派工給的本機影片(`frame.mjs`)或圖片(`--asset-root` 指到其目錄)。不讓 AI 圖冒充產品畫面。
3. 寫 `<job>/work/<n>/storyboard.json`:每 2–4 秒一個畫面變化(換場景、或同場景內卡片元素依 `at` 出現);每個場景指定吉祥物姿勢,同一姿勢不連續超過 3 個場景;卡片類型(不含 `title`、`cta`)至少 4 種。
4. `tts.mjs` 逐句生成(念 `say` 或 `text`)→ 每檔長度 > 0.5 秒且 max_volume > −30 dB,不合就換 seed 重生,最多 2 次。`render.mjs --dry-run` 算片長:> 59 秒 → repo / 主題模式刪減句子後重跑;完整文案 → 刪除工作目錄後 BLOCKED(附片長)。
5. `render.mjs <job>/work/<n>/storyboard.json <job>/work/<n>/tts.json <job>/work/<n> --deliver <job>/<n> --asset-root …`(進度印到 stderr;可能超過單次 Bash 600 秒時,用背景執行並等完成通知)→ 中間檔在 `<job>/work/<n>/`:`silent.mp4`、`boxes.json`、`safe.json`、`timing.json`、`scenes.json`;交付檔在 `<job>/<n>/`:`subtitles.srt`、`cover.png`(第一個場景最終狀態那一格,大標已在畫面上,不另疊字)。
6. AI 配樂(同主規格,`ace-step-bgm`)、轉場音效 ≤ 3;`mix.mjs <job>/work/<n>/silent.mp4 <job>/work/<n>/tts.json <job>/work/<n>/timing.json <job>/<n>/final.mp4 …` 混音。
7. 驗證:
   - `verify.sh <n>/final.mp4 <n>/checks --size <模板尺寸> --safe-json <job>/work/<n>/safe.json --boxes <job>/work/<n>/boxes.json --cover <n>/cover.png --scenes <job>/work/<n>/scenes.json`(`safe.json` 由 `render.mjs` 從模板 `safe` 寫出)。
   - `contact.mjs <n>/final.mp4 <n>/checks/contact.png --every 1`(看整體節奏與空白);逐場景全尺寸 `scene-NN-mid/end.png`(verify 產生)用來看錯字與裁切。
8. 寫 `script.md`(旁白句與念法、場景清單、亮點對應 repo 路徑、模板路徑、AI 素材表:每句 TTS(聲音、instruct、seed、重生次數)、配樂、音效;吉祥物註明「模板內建,來源見模板 README」),`scrub-check`,清理同主規格。

## 主規格成功標準在 template 模式的適用
| # | 適用 | 說明 |
|---|---|---|
| 1 | 取代 | 改為 15 |
| 2 | 沿用 | 響度 |
| 3 | 取代 | 改為 16 |
| 4 | 取代 | 改為 17 |
| 5、6 | 不適用 | 影片模式 |
| 7 | 沿用 | repo 輸入時 |
| 8、9、10 | 沿用 | 清理、來源指紋、回報格式 |
| 11 | 不適用 | 配色來自模板;`script.md` 改寫「模板:<路徑>」 |
| 12 | 沿用並擴充 | AI 素材表加 TTS 每句;`scrub-check` 照做 |
| 13 | 沿用 | 主題 / 文案輸入時 |
| 14 | 取代 | ComfyUI 不可用 → template 模式 BLOCKED(見停止條件) |

## 新增成功標準(template 模式)
15. `verify.sh --size <模板尺寸>` 結束碼 0、`ok:true`:尺寸 / fps 同模板、`h264` + `yuv420p`、`aac` 48000 Hz、faststart、長度 ≤ 60 秒、`cover.png` 為模板尺寸。
16. 畫面:`minBrightness` > 5;`subtitleBoxes` 為 `ok`(依 `kind` 各自在模板 `safe` 的矩形內);`timing.json` 的 `rhythm.maxEmpty` ≤ 2;agent 已 Read `contact.png` 與每個場景的 mid / end 全尺寸擷圖並逐張描述,沒有錯字、截圖重點清楚、吉祥物沒被裁。
17. 字幕:`subtitles.srt` 第 i 句 = storyboard 所有 `lines` 依序第 i 句的 `text` 去掉 `*` 與分段空白;時間符合時間軸公式(誤差 ≤ 0.05 秒)。
18. 旁白:每個 TTS 檔長度 > 0.5 秒且 max_volume > −30 dB(`tts.mjs` 輸出含這兩個值);`script.md` 記錄聲音、instruct、seed、重生次數、念法改寫。
19. 節奏與變化:`timing.json` 的 `rhythm.ok` 為 `true`;同一姿勢不連續超過 3 個場景;卡片類型(不含 `title`、`cta`)≥ 4 種;同一圖檔 ≤ 2 個場景。
20. 專案模板(有建立 / 修改時):`check.mjs --template-dir` 結束碼 0;`preview/contact.png` 存在且已 Read;`README.md` 有來源模板、改動、日期。

## 停止並詢問的情況(template 模式)
第 0 步可判斷(不建立任何檔案):
- 模板找不到或 `check.mjs` 結束碼 3。
- `qwen3-tts` 不可用(check 失敗或為 `false`),且派工沒寫「允許 say」。派工同時寫「不用 ComfyUI」→ 視同 Qwen3 不可用:沒有「允許 say」就 BLOCKED;有就用 `say`(Meijia),配樂省略。
- 建立專案模板但目錄已存在。
- 主規格第 0 步的其他情況。

第 0 步之後(先刪除本次建立的工作目錄再回報):
- Qwen3-TTS 連不上或逾時(`comfy.mjs` 結束碼 4 / 5),重試 1 次仍失敗。
- 完整文案輸入、片長 > 59 秒。
- 主規格第 0 步之後的其他情況。

不需要 BLOCKED,照下列處理:
- 某句 TTS 重生 2 次仍不合格 → 改寫該句念法(`say`)再試 1 次;仍失敗 → 狀態 ISSUES,成品照做,回報列出該句。
- `render.mjs` 結束碼 4(字幕或標題縮到 `minFont` 仍放不下)→ 拆句或縮短標題後重跑。
- `render.mjs` 結束碼 2(storyboard 不合法、圖檔不存在、`at` 找不到、`focus` 缺、同圖超過 2 次)→ 依錯誤訊息修 storyboard 重跑;同一錯誤 3 次仍在 → ISSUES。

## 不做什麼(template 模式補充)
- 不改 kit 預設模板;新增或改預設模板走 xhe PR(人或之後的 forge)。專案模板只在派工要求時建立 / 修改;一般製作只寫 `storyboard.json`。
- 不用模板以外的配色、不放模板沒有的元素。
- 不使用雲端 TTS;Qwen3-TTS 只透過 `comfy.mjs run`(PreviewAudio 輸出)。

## motion-video-kit skill 內容(新建)
結束碼通則:0 成功;2 輸入不合法(storyboard、路徑、參數;訊息指出欄位);3 缺工具或模板;4 版面放不下;5 ComfyUI 連不上(沿用 comfy.mjs);1 其他。
- `scripts/check.mjs --template <名稱> | --template-dir <路徑>`:node / Chrome / ffmpeg;模板解析(印實際路徑)與 `template.json` 必填欄位;結束碼 3。
- `scripts/tts.mjs <storyboard.json> <輸出目錄> [--voice Vivian] [--instruct …] [--seed 7] [--engine qwen3|say]`:逐句呼叫 `comfy.mjs run workflows/qwen3-tts.json`(`runtime_mode` 固定 Shared Runtime)或 `say`;轉 48 kHz;印 `[{i,text,say,file,duration,maxVolume,seed,retries}]`;可只重生指定句(`--only 3,5`)。
- `scripts/render.mjs <storyboard.json> <tts.json> <輸出目錄> --deliver <交付目錄> --asset-root <目錄>[,<目錄>…] [--template-dir <路徑>] [--dry-run]`:schema 驗證 → 排時間軸 → 注入頁面 → 逐格擷圖 → ffmpeg;輸出目錄寫 `silent.mp4`、`boxes.json`、`safe.json`、`timing.json`、`scenes.json`,交付目錄寫 `subtitles.srt`、`cover.png`;stderr 印進度。`--sample` 用模板 `sample.storyboard.json` 與假旁白(每句依字數 0.2 秒 / 字)輸出到模板 `preview/`。
- `scripts/mix.mjs <silent.mp4> <tts.json> <timing.json> <輸出.mp4> [--music <檔>] [--sfx <json>]`:旁白排程、配樂 sidechain、loudnorm 兩階段;實作抽出 short-video-kit `compose.mjs` 的混音段為共用模組(不複製)。
- `scripts/frame.mjs <影片> <秒> <輸出.png>`:擷一格(輸出限 `<job>/work/<n>/`)。
- `scripts/contact.mjs <影片> <輸出.png> [--every 1]`:縮圖總表。
- `storyboard.schema.json`。
- `templates/github-hot-pastel/`(見上)。
- `tests/run.sh`:用 `say` 或正弦波當假旁白跑 9 種場景,檢查:輸出尺寸 / fps / 長度;可重現(同輸入兩次渲染,第 0、中、末格 PNG 雜湊相同);60 秒片的渲染時間(印出,供估算);越界縮字與結束碼 4;storyboard 錯誤(缺欄位、圖不存在、`at` 找不到、缺 `focus`、同圖 3 次)結束碼 2;內容含 `<script>` / 外部 `<img>` 不執行、不連線;`*關鍵詞*` 轉成膠囊、字幕去掉 `*` 與分段空白;SRT 時間等於公式。缺 Chrome / ffmpeg 印 SKIP,SKIP 不算通過。
- game-art-kit:新增 `workflows/qwen3-tts.json`;`check` 的 `workflows_available` 加 `qwen3-tts`(偵測 `Qwen3TTSEngineNode`、`UnifiedTTSTextNode` 與本機 CustomVoice 模型)。
- short-video-kit:`verify.sh` 加 `--size WxH`(影片與封面都用,預設 1080×1920)與 `--safe-json <檔>`(依 `boxes.json` 的 `kind` 比對;沒給時維持現有 x∈[60,930]、y∈[1300,1620]);`check.sh` 加 `--no-say`。既有測試要照樣通過。

## agent 本體要改的地方
- frontmatter `description`:加入模板模式、Qwen3 旁白、3:4 / 1:1 尺寸;`skills:` 加 `motion-video-kit`。
- 工作流程加「template 模式」一節(內容如上)、成功標準 15–20、停止條件、主規格標準適用表。
- Bash 白名單加:`node <motion-video-kit>/scripts/*.mjs`;派工要求建立 / 修改專案模板時,`cp -R <預設模板> <out>/_templates/<名稱>` 與 `mkdir -p <out>/_templates/<名稱>/...`;`comfy.mjs run` 的 `--out` 加允許 `<out>/_templates/<名稱>/assets/mascot`。不給 kit 的 `tests/run.sh`。
- 可寫路徑:工作目錄;派工要求時加 `<out>/_templates/<名稱>/`。

## 已知限制
- Qwen3 預設聲音偏大陸普通話口音;比 `say` 慢約 15%。
- 逐詞時間依字數比例,關鍵詞亮起可能與實際發音差 0.1–0.3 秒。
- 3:4 成品上傳到 Shorts / Reels 會有上下黑邊或被平台裁成 9:16 顯示(使用者選的比例)。
