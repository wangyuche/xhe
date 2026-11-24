# short-video-maker 規格

## 一句話定位
短影音製作者(owner):主 agent 交給它一個 GitHub repo、一支影片或一個主題 / 文案，它自動寫腳本、錄畫面、剪片段或用區網 ComfyUI 生成插圖 / 動態鏡頭 / 配樂 / 音效，配旁白與字幕，輸出 9:16、60 秒內的 MP4(Shorts / Reels / TikTok),並實際檢查成品規格與畫面。只輸出檔案，不上傳。

## 技術選擇(已與使用者確認,2026-11-17)
- GitHub 輸入「兩種都要」:能跑起來的網頁專案錄操作畫面(`repo-record`),跑不起來或不是網頁就做圖卡式介紹(`repo-cards`)。
- 影片輸入「兩種都要」:長片挑精華(`video-highlight`,1–3 支)或整支精簡(`video-condense`,去停頓與贅字、順序不變)。派工沒指定時用 `video-highlight`。
- 配音:macOS 內建 `say`,預設聲音 `Meijia`(zh_TW)。不用付費 TTS、不需要 API 金鑰。
- 規格:1080×1920、30 fps、H.264(yuv420p)+ AAC 48 kHz、`+faststart`、每支 ≤ 60 秒。只存本機，不上傳。
- 工具鏈由使用者自己安裝(`brew install ffmpeg whisper-cpp` + 模型檔 `ggml-large-v3-turbo.bin`);agent 不安裝任何東西。
- 文字畫面(標題卡、程式碼卡、字幕)用 Chrome headless 把內建 HTML 版型轉成透明 PNG,再用 ffmpeg `overlay` 疊上。理由：中文用系統 PingFang TC,不依賴 ffmpeg 是否編進 libass / freetype;CSS 排版較好控制，也能量出文字邊界框做安全區檢查。
- 網頁錄影用 Chrome CDP `Page.startScreencast`,手機視窗 540×960、`deviceScaleFactor: 2`,直接得到 1080×1920 畫面。
- 語音轉文字用 whisper.cpp(`whisper-cli`),預設自動判斷語言;中文以繁體提示詞引導。

## ComfyUI AI 素材(已與使用者確認,2026-11-24)
- 四種都要:AI 插圖 / 背景(Qwen-Image)、AI 動態鏡頭(圖生影片:LTX-2.3 優先,Wan 2.2 TI2V 5B 備援)、AI 配樂(ACE-Step 1.5,純音樂)、AI 音效(Stable Audio 3)。
- 新增 `topic` 模式:只給主題或文案,畫面全部由 ComfyUI 生成,旁白仍用 macOS `say`。ComfyUI 連不上 → BLOCKED。
- 既有模式「主機可用就自動用」:第 0 步 `comfy.mjs check` 成功就用,連不上 / 缺模型就退回原本做法,回報寫原因。派工寫「不用 ComfyUI」時完全不用。
- 共用 `game-art-kit` 的 `comfy.mjs`(位址設定 `~/.config/game-art-kit/config`、不寫入伺服器 output/、拒絕雲端 API 節點、逾時收尾),不另寫一份 ComfyUI 客戶端。影片骨架(`ltx23-i2v`、`wan22-i2v`)放進 game-art-kit 的 `workflows/`,`check` 列出影片模型預設值。只做圖生影片:每個動態鏡頭都從 Qwen 生成的靜態圖開始,風格才會一致,也能先看靜態圖再決定要不要花時間做動態。
- ComfyUI 沒有不存檔的影片預覽節點(`SaveVideo` 會在伺服器留檔,`run` 拒絕),所以影片骨架輸出每一格 `PreviewImage`,下載後由 short-video-kit 的 `frames.sh` 在本機組成 MP4。
- 實測(2026-11-24,NVIDIA GB10,704×1280,121 格 ≈ 5 秒,同一張起始圖):LTX-2.3 + 蒸餾 LoRA 8 步 110 秒,動作與運鏡明顯,但背景冒出一塊亂碼招牌字;Wan 2.2 TI2V 5B 20 步 339 秒,畫面穩但幾乎只有推鏡。所以 LTX-2.3 優先,Wan 備援。121 張 PNG 下載在 60 秒內。
- AI 素材的來源誠實:AI 圖與鏡頭只當「概念插圖 / 情境畫面」,不畫產品介面、程式碼、文字、logo、真人或既有作品角色;repo 模式的產品畫面只能來自 repo 本身或錄影。每個 AI 素材在 `script.md` 的「AI 素材」表列出模型、提示詞、seed、用在哪個鏡頭;回報提醒上傳時開平台的「AI 生成內容」標示。

## 模板動畫模式
- 2026-11-24 新增 `template` 模式與 motion-video-kit,規格見 `short-video-maker.template-mode.md`。

## 目錄與命名
- 一次派工 = 一個工作目錄 `<out>/<YYYYMMDD>-<slug>/`(`<slug>` 小寫英文加連字號,`<out>` 預設 `~/Movies/Shorts/`)。
- 每支成品一個子目錄 `1/`、`2/`、`3/`(只有一支也用 `1/`)。
- 中間檔一律放 `<工作目錄>/work/`,結束時刪除。
- AI 素材放 `<工作目錄>/work/<n>/ai/`(圖 `img-<k>.png`、影格 `clip-<k>-*.png` 與組好的 `clip-<k>.mp4`、配樂 `bgm.*`、音效 `sfx-<k>.*`;`comfy.mjs` 另寫 `ai/workflows/*.json`),跟著 `work/` 一起刪。
- 每支成品的中間素材放 `<工作目錄>/work/<n>/`:字幕 PNG 與 `boxes.json` 在 `work/<n>/subtitles/`,卡片 PNG 在 `work/<n>/cards/`,第一個鏡頭畫面 `work/<n>/first-frame.png`(`compose.mjs` 產生)。
- 腳本自己的暫存:`${SHORT_VIDEO_KIT_TMP:-$TMPDIR/short-video-kit}/<slug>/`(Chrome 設定檔、抽出的音訊),腳本結束時自行刪除。`serve.sh` 會寫 `$TMPDIR/web-dev-kit/`。

## 做什麼
- 它是被委派的子 agent,不能直接和使用者對話。訪談由主 agent 在派工前完成。
- **第 0 步**(不建立任何檔案;例外:`comfy.mjs check` 寫的節點快取 `~/.cache/game-art-kit/`):
  1. `check.sh`(影片模式加 `--video`,網址加 `--url`)確認 ffmpeg、ffprobe、node、Chrome、`say -v Meijia`,影片模式另需 `whisper-cli` 與模型檔，網址另需 `yt-dlp`。缺少就 BLOCKED,附 `check.sh` 印出的安裝指令。
  2. 決定模式與 `<slug>`;工作目錄已存在 → BLOCKED,提議 `<slug>-2`。
  3. 逐條檢查「停止並詢問的情況」中第 0 步就能判斷的項目。
  4. 記下來源指紋：影片 `shasum -a 256 <檔>`;本機 git repo `git -C <repo> rev-parse HEAD` 加 `(cd <repo> && git ls-files -m -o --exclude-standard -z | xargs -0 shasum | shasum)`(對未 commit 檔案的內容取雜湊);非 git 目錄 `find <repo> -type f -print0 | sort -z | xargs -0 shasum | shasum`。
  5. 本機 git repo 有未 commit 的變更 → 繼續，但回報「已知限制」寫「未 commit 的變更不在短片中」。本機非 git 目錄要求 `repo-record` → BLOCKED(請使用者先 `git init` 並 commit,或改用 `repo-cards`)。
  6. ComfyUI(派工寫「不用 ComfyUI」時跳過):`node <game-art-kit>/scripts/comfy.mjs check`。
     - 成功:記下 `workflows_available` 與 `defaults`(插圖 `qwen-t2i`、同角色 `qwen-edit-1ref`、動態 `ltx23-i2v` / `wan22-i2v`、配樂 `ace-step-bgm`、音效 `stable-audio-sfx`),之後只用為 `true` 的骨架。
     - 失敗(結束碼非 0:2 沒設定位址、3 ComfyUI 回錯誤、5 連不上、1 其他)或需要的骨架都是 `false`:`topic` 模式 → BLOCKED(附 check 的錯誤訊息與設定方式);其他模式 → 不用 AI 素材,回報「AI 素材」行寫「未使用:<原因>」。
- **第 0 步之後才發生的 BLOCKED**(clone 失敗、文字稿空白、condense 超過 60 秒等):先 `stop.sh` 停掉服務，刪除整個工作目錄(本次自己建立的)再回報，讓主 agent 可以用同一個名稱重新派工。
- **repo-record / repo-cards**:
  1. `git clone --depth 1 <網址或本機 git 路徑> <工作目錄>/work/repo`(本機 git repo 也 clone,所有安裝、建置、啟動都在 `work/repo` 做，原 repo 不動)。本機非 git 目錄只用於 `repo-cards`,直接唯讀讀取原目錄，以下的 `work/repo` 改指原目錄。讀 README、套件檔、主要原始碼，挑亮點 ≤ 3 個，每個亮點記下對應的檔案路徑或 README 段落。
  2. 寫 `script.md`:鉤子(前 3 秒一句話)→ 亮點 → 結尾(repo 網址)。旁白每句 ≤ 20 字;`tts.sh` 實測總長 ≤ 55 秒，超過就刪減句子再測。
  3. `repo-record`(需執行旗標):照 README 在 `work/repo` 安裝並以 `serve.sh <slug> work/repo <埠> -- <啟動指令>` 啟動;寫 `actions.json`(`goto` / `wait` / `scroll` / `click` / `type`),`record-web.mjs` 錄每個鏡頭。安裝、啟動或錄影失敗 → 改走 `repo-cards`,回報寫原因與失敗輸出。
  4. `repo-cards`:寫 `cards.json`,用 `render.mjs` 產生 `title` / `code`(最多 15 行，跳過 `.env*`、`*secret*`、`*credential*`、`*.pem`、`*.key`)/ `point` / `end` 卡;圖片只能用 repo 內的本機圖檔(相對路徑),`render.mjs` 以 `--asset-root <repo 目錄>` 限制;不用遠端網址(badge、CDN)。卡片 PNG 輸出到 `work/<n>/cards/`。
- **topic**(主題 / 文案 → 全 AI 畫面):
  1. 派工給的是完整文案 → 照原意拆成每句 ≤ 20 字(不增刪內容,只斷句;tts 實測 > 55 秒 → 刪除工作目錄後 BLOCKED,附實際長度,請使用者刪減或同意改寫);給的是主題 → 自己寫鉤子 → 3–5 個重點 → 結尾。內容只寫普遍公認、不需查證的事;不確定的數字、日期、人名不寫,真的需要時列在回報「需要使用者確認的內容」。`tts.sh` 實測總長 ≤ 55 秒。
  2. 寫「風格基底」一段英文提示詞(畫風、光線、色調、鏡頭語言),所有鏡頭共用,寫進 `script.md`。每句旁白分配一個鏡頭(相鄰兩句可以共用)。
  3. 每個鏡頭先出一張靜態圖:`qwen-t2i`,928×1664(9:16),提示詞 = 風格基底 + 鏡頭內容 + `no text, no letters, no watermark, no logo`。同一個主角出現在多個鏡頭 → 第一張當定裝圖,其他鏡頭用 `qwen-edit-1ref` 以它為參考(`only one person, single character`)。Read 每張圖檢查:有任何文字或類文字圖樣(含亂碼)、肢體錯誤、主體不符就換 seed 重出(新名稱 `img-<k>-r2`…),每個鏡頭最多 3 次;仍不行改用另一個構圖再試 1 次,還是不合格 → 狀態 ISSUES,列出該鏡頭與問題。`qwen-t2i` / `qwen-edit-1ref` 在第 0 步之後連不上或逾時(結束碼 4 / 5)重試 1 次仍失敗 → 刪除工作目錄後 BLOCKED。
  4. 動態鏡頭:先用第 3 步的靜態圖寫 timeline(每個鏡頭都是圖片鏡頭)跑 `compose.mjs --dry-run` 取得每個鏡頭長度 D(最後一個鏡頭含結尾 0.6 秒)。只從 D ≤ 5.0 秒的鏡頭挑 1–3 個最重要的(鉤子優先);D 較長又必須動態的,把那句旁白拆成兩句重跑 tts 與 dry-run(後半句用同一張靜態圖 + `motion`)。以該鏡頭的靜態圖為起始格生成:
     - `ltx23-i2v`(優先):704×1280,格數 = 8k+1 且 ≥ D × 24 + 1(上限 121),`run` 加 `--queue-timeout 120 --download-timeout 90`(121 張 PNG 約 140 MB)。
     - `wan22-i2v`(`ltx23-i2v` 不可用時):格數 = 4k+1 且 ≥ D × 24 + 1(上限 97,只用在 D ≤ 4.0 秒的鏡頭;更長的鏡頭改用靜態圖 + `motion`),`run` 加 `--timeout 360 --queue-timeout 40`(合計加收尾、下載不超過 Bash 的 600 秒)。
     - `frames.sh <ai 目錄> <名稱> <ai 目錄>/<名稱>.mp4 --frames <length>` 組成 MP4,timeline 影片鏡頭設 `"fit":"crop"`。Read 首 / 中 / 末格:出現任何文字或類文字圖樣(含亂碼招牌)、主體變形或場景跳掉就換 seed 重出,重出一律用新名稱(`clip-<k>-r2`、`-r3`,避免舊影格混入)。重出 2 次仍不合格、生成失敗或逾時 → 該鏡頭改用靜態圖 + `motion`,回報寫明。其他鏡頭用靜態圖加 `motion`(緩慢推近 / 拉遠 / 平移)。
  5. 封面用第一個鏡頭的畫面;配色從鉤子鏡頭的靜態圖取色(同影片模式的取色方式,圖用鉤子鏡頭最後採用的靜態圖,即 AI 素材表上的那一份)。
- **既有模式的 AI 素材**(ComfyUI 可用時自動加):
  - `repo-cards` / `repo-record`:`qwen-t2i` 為 `true` 時,鉤子鏡頭一律用 1 個 AI 概念畫面(D 的取得方式、格數規則、重出與退回同 topic 第 4 步:D ≤ 5 秒且有影片骨架時做成動態鏡頭,否則靜態圖 + `motion`),標題卡改放在第二個鏡頭;亮點卡在 repo 沒有可用的本機圖時一律補 AI 概念插圖(另一批 `render.mjs --asset-root <job>/work/<n>/ai`)。派工指定鉤子畫面或「不用 ComfyUI」時不加。AI 畫面只表現專案解決的問題或情境,不畫介面、程式碼、文字;產品本身的畫面只能來自 repo 圖檔或錄影。
  - `video-highlight` / `video-condense`:不加 AI 畫面(畫面以來源為準),只在派工沒給背景音樂時加 AI 配樂。
- **AI 配樂與音效**(所有模式,ComfyUI 可用時):
  - 派工沒給背景音樂 → `ace-step-bgm` 生成純音樂(`lyrics` = `[instrumental]`,`seconds` = 片長 + 2,依內容選曲風、bpm、調性,寫進 `script.md`),timeline `music` 指向它,`volume` 0.2;compose 依旁白 / 原聲自動壓低。派工給了音樂檔 → 用派工的,不生成。
  - 音效只用在旁白模式(`topic`、repo 模式)的鏡頭切換,最多 3 個(例如鉤子後第一次切換、結尾):`stable-audio-sfx` 生成 → `node <game-art-kit>/scripts/audio.mjs process <下載的音訊> --type sfx --duration <秒> --out <job>/work/<n>/ai --name sfx-<k>` 去頭尾靜音並正規化,timeline 鏡頭加 `sfx`。原聲模式不加音效。
  - 音訊只做機械檢查(compose 響度、verify),沒有人耳試聽,回報寫明。
- **video-highlight / video-condense**:
  1. `probe.sh` 取長度、寬高、旋轉、fps、有無音軌。網址輸入先 `yt-dlp -o <工作目錄>/work/source.%(ext)s <網址>`。
  2. 有音軌:`transcribe.sh` 產生 `[{start,end,text}]`;agent 校正錯字，中文轉繁體(其他語言保留原文)。
  3. `video-highlight`:依文字稿挑 1–3 段，每段 15–60 秒，起訖等於某個段落的 start / end。每段寫一句標題，**只做畫面文字疊圖(前 3 秒),沒有旁白、不佔時間**。
     - 來源本身 < 15 秒，或已是直式且 ≤ 60 秒 → 整支輸出成 1 支，回報註明。
     - 沒有音軌：依派工的說明挑段，沒有說明就 BLOCKED。
  4. `video-condense`:`silence.sh` 找 > 0.5 秒停頓，加上文字稿中單獨成段的贅字(「嗯」「呃」「那個」)一起剪掉，每個剪點前後各留 0.1 秒。
     - 剪完 > 60 秒 → BLOCKED,附實際長度，提議改用 `video-highlight` 或指定要保留的段落。
     - 沒有音軌 → BLOCKED(無法判斷停頓)。
  5. 橫式來源預設「模糊背景置中」(整個畫面都看得到),派工指定時改「中央裁切」。旁白模式的橫式錄影鏡頭一律「置頂」:逐鏡頭用 `region` 放大旁白講到的區域、放在字幕區上方，不裁左右(2026-11-18 加入)。
- **共同的合成與驗證**(每支成品各做一次):
  1. 寫 `timeline.json`(格式見 skill),`compose.mjs` 產生 `final.mp4` 與 `subtitles.srt`。字幕時間由 `compose.mjs` 依固定規則排，agent 不手排:
     - 旁白模式：第 1 句從 0.3 秒開始，第 i 句 start = 第 i−1 句 end + 0.25 秒,end = start + `tts.sh` 實測長度;鏡頭長度跟著所屬句子。
     - 原聲模式：字幕用文字稿段落時間，扣掉剪掉的區間後重新對應到成品時間軸。
  2. 字幕 PNG 與 `boxes.json` 輸出到 `work/<n>/subtitles/`。版面(由 `render.mjs` 強制):每張最多 2 行、左右邊界 60 px、文字邊界框必須在 x ∈ [60, 930]、y ∈ [1300, 1620] 內(避開右側 150 px 與底部 300 px 的平台按鈕區);放不下時字級由 64 px 逐步縮到 44 px,仍放不下就結束碼 4,agent 拆句後重跑。原聲模式拆句時，在 `timeline.json` 把該段標成多句,`compose.mjs` 依字數比例切分原段落的 start–end。
  3. 有原聲時不加旁白(標題只是疊字)。背景音樂用派工給的檔案;沒給且 `ace-step-bgm` 可用時用 AI 配樂(見「AI 配樂與音效」);都以 sidechain 壓在旁白或原聲之下。
  4. 響度：整體 −14 LUFS(±1),true peak ≤ −1 dBTP(`loudnorm` 兩階段，在 `compose.mjs` 內做)。
  5. `cover.png`:`compose.mjs` 擷出 `work/<n>/first-frame.png`,`render.mjs --asset-root work/<n>` 的 `cover` 版型疊上標題，輸出 `<n>/cover.png`(1080×1920)。
  6. `verify.sh <n>/final.mp4 <n>/checks --boxes work/<n>/subtitles/boxes.json --cover <n>/cover.png` 檢查規格、長度、響度、亮度、字幕邊界框、封面尺寸，並在 0%、25%、50%、75%、末 1 秒各擷一張圖到 `checks/`;agent 全部 Read,確認字幕可讀、沒有錯字、畫面正確。
  7. 寫 `<n>/script.md`:旁白句、鏡頭清單、來源時間碼(影片)或亮點對應的 repo 路徑、condense 剪掉的區間與總秒數;有 AI 素材時加「風格基底」與「AI 素材」表(檔案、骨架、模型檔名、提示詞、seed、用在哪個鏡頭,只列最後採用的那一份)。
  8. 有用 AI 素材時:對每支成品 `node <game-art-kit>/scripts/comfy.mjs scrub-check <工作目錄>/<n>`(只查交付目錄;`script.md`、`timeline.json` 不得含 ComfyUI 位址 / 私有 IP),結束碼 1 就改掉再查。
  9. 結束:`stop.sh <slug>`(有啟動時)→ `rm -rf <工作目錄>/work` → 再記一次來源指紋，與第 0 步比對。

## 不做什麼
- 不上傳、不發佈到任何平台。
- 不安裝任何工具或模型;缺少時 BLOCKED。
- 不使用付費 TTS 或任何需要金鑰的雲端服務。
- 沒有執行旗標時不執行 repo 的任何程式碼(不安裝依賴、不跑建置或腳本),只讀檔案。
- 不從網址下載影片，除非有授權旗標。
- 字幕只能是校正後的原話或腳本旁白。例外：派工要求翻譯時，第二行加譯文並在 `script.md` 標明「譯文」。
- 不修改來源影片或原 repo。
- 不自己寫 HTML;卡片與字幕只透過 `render.mjs` 的內建版型與 JSON 內容產生。
- 不用 ComfyUI 的雲端 API 節點(`comfy.mjs run` 會擋),不在 ComfyUI 主機安裝、下載或刪除模型,不寫入伺服器的 output/(輸出只用 Preview 節點,參考圖只上傳到 temp 區)。
- AI 素材不仿製真人、品牌 logo、既有作品的角色或畫面;不讓 AI 畫面冒充產品介面或真實紀錄畫面。
- 不靠 AI 生成的文字(擴散模型的字不可靠);畫面上的字一律由 `render.mjs` 疊上。

## 觸發時機
使用者說「把這個 repo 做成短影音」「幫這支影片剪 Shorts」「把直播挑三段精華」「這支教學影片去掉停頓做成直式短片」「做一支介紹台灣夜市的短影音」「把這段文案做成 Reels」。

主 agent 派工前要問清楚：輸入是什麼、模式(沒說時依預設)、repo 要不要真的跑起來錄畫面(執行旗標)、網址影片是否為使用者自有或已授權、有沒有背景音樂檔。

## 輸入
- 必要：一個 GitHub repo 網址或本機 repo 路徑，或一支影片(本機路徑;網址需授權旗標),或一個主題 / 一段文案(`topic` 模式)。
- 選填(沒給用預設，並寫在回報「設定」行):
  - 模式:repo 預設 `repo-cards`(有執行旗標時 `repo-record`);影片預設 `video-highlight`;主題 / 文案一律 `topic`。
  - ComfyUI:預設「可用就用」;派工寫「不用 ComfyUI」時不用(`topic` 模式不能關)。畫風要求(例如「水彩」「寫實」)寫進風格基底;沒給時依主題選並寫在 `script.md`。
  - 精華數量 1–3(預設由內容決定)。
  - 輸出目錄 `<out>`:預設 `~/Movies/Shorts/`。
  - 聲音 `Meijia`、語速 190。
  - 橫式畫面處理：模糊背景置中 / 中央裁切。
  - 背景音樂檔路徑、風格要求(標題字、配色)、是否加譯文字幕。
  - 配色沒給時,**每支依來源自己選**(repo 的 logo / 網站主色,影片畫面主色;都沒有就依專案性質推定並標明),kit 沒有預設配色(使用者 2026-11-21 要求:各專案不同,不要共用模板)。
- 同意旗標(寫在派工提示，沒寫就視為不同意):
  - 「使用者已同意執行 <repo> 的程式碼」
  - 「影片為使用者自有或已授權」(網址輸入時)

## 輸出
```
~/Movies/Shorts/20261117-xhe/
  1/
    final.mp4        # 成品
    cover.png        # 1080×1920 封面
    subtitles.srt
    script.md        # 旁白、鏡頭清單、來源時間碼或 repo 路徑
    timeline.json    # 合成設定(本機影片來源可重新渲染;網址、repo 模式的中間素材已刪除，需要重新執行 agent)
    checks/          # verify.sh 擷取的 5 張畫面
```

回報範例:

```markdown
## short-video-maker:xhe repo → PASS
- 模式:repo-cards(未給執行旗標)
- 輸出:~/Movies/Shorts/20261117-xhe/1/final.mp4
- 規格:`verify.sh` → {"width":1080,"height":1920,"fps":30,"vcodec":"h264","pixFmt":"yuv420p","acodec":"aac","sampleRate":48000,"faststart":true,"duration":42.6,"lufs":-14.2,"truePeak":-1.6,"minBrightness":38,"subtitleBoxes":"ok","cover":"1080x1920","ok":true}
- 腳本:鉤子「一個人怎麼管 8 個 AI 助手？」+ 3 個亮點(agents/、skills/web-dev-kit/、README「安裝」)+ 結尾;旁白 9 句，實測 38.4 秒
- 畫面檢查(checks/ 5 張已檢視):0% 標題卡;25% 程式碼卡 agents/backend-owner.md;50% 重點卡;75% 重點卡;末 1 秒結尾卡;字幕完整、無錯字
- 設定:Meijia、語速 190、無背景音樂、輸出 ~/Movies/Shorts/
- AI 素材:未使用:comfy.mjs check 結束碼 5(連不上)  ← 有用時寫:插圖 3 張(qwen-t2i)、動態鏡頭 1 個(ltx23-i2v,5.0 秒)、配樂 1 首(ace-step-bgm,44 秒)、音效 2 個;每張 / 每格已 Read;上傳時請開平台的 AI 生成內容標示
- 清理:work/ 已刪除;啟動的服務：無
- 亮點路徑檢查(commit a1b2c3d):`ls` agents/ skills/web-dev-kit/ README.md → 都存在
- 來源指紋：無本機來源(GitHub clone)
- 已知限制:say 語音較機械;程式碼卡只截取 15 行
- 需要使用者確認的內容:無  ← topic 模式時列出不確定的事實
```

多支精華時，每支一段結果，最後列總表(編號、來源時間碼、長度、標題)。

狀態只能是 PASS / ISSUES / BLOCKED:
- PASS:成功標準全部通過。
- ISSUES:有成品但某項檢查沒過(修正 3 次仍失敗),逐條列出指令與實際輸出。
- BLOCKED:需要使用者決定或安裝工具，寫明原因、要問的問題、已做了什麼、已刪除的目錄。

## 成功標準
每條都必須能被實際檢查。
1. `verify.sh` 結束碼 0、`ok:true`:1080×1920、30 fps、`h264` + `yuv420p`、`aac` 48000 Hz、faststart、長度 ≤ 60 秒、`cover.png` 為 1080×1920。
2. 響度:`verify.sh` 量到 −15 到 −13 LUFS,true peak ≤ −1.0 dBTP。
3. 畫面:`verify.sh` 的 `minBrightness` > 5(5 張擷圖都不是全黑);`subtitleBoxes` 為 `ok`(`render.mjs` 記錄的每張字幕邊界框都在 x ∈ [60, 930]、y ∈ [1300, 1620]);agent 已 Read 5 張擷圖與每個鏡頭的中點 / 結尾擷圖(`verify.sh --scenes`)並逐張描述，旁白講到的元素完整、沒被裁切或被字幕蓋住。
4. 字幕與聲音一致:
   - 旁白模式:`subtitles.srt` 第 i 句文字等於 `script.md` 第 i 句旁白;時間等於「做什麼 › 共同的合成與驗證」第 1 步的公式(誤差 ≤ 0.05 秒)。
   - 原聲模式：每句字幕都能對應到 `transcribe.sh` 的一個段落(校正錯字、轉繁體可以，不得新增內容;譯文行除外)。
5. `video-highlight`:每段起訖等於文字稿某段落的 start / end(沒有音軌時等於派工說明給的時間碼),差 ≤ 0.3 秒;長度 15–60 秒;整支輸出時(來源 < 15 秒，或直式且 ≤ 60 秒)起訖為 0 與來源長度，不受段落邊界與長度限制，回報註明;`script.md` 列出來源時間碼。
6. `video-condense`:成品內容順序與來源一致;`script.md` 列出剪掉的區間與總秒數，且「來源長度 − 剪掉總秒數」與成品長度相差 ≤ 0.5 秒。
7. repo 模式:`script.md` 每個亮點附 repo 內的檔案路徑或 README 段落，回報附「亮點路徑檢查」:刪除 `work/` 前對每個路徑 `ls` 的結果與 clone 的 commit SHA;沒有執行旗標時，執行紀錄中沒有安裝、建置或啟動指令。
8. 清理:`<工作目錄>/work/` 不存在;有啟動服務時回報附 `stop.sh` 的 `stopped` 輸出;BLOCKED(第 0 步之後)時整個工作目錄不存在。
9. 來源不變：第 0 步與結束時的來源指紋相同(回報附兩次結果)。
10. 回報格式符合「輸出」,狀態與證據一致。
11. AI 素材(有用時):`script.md` 的「AI 素材」表每列有模型檔名、骨架、提示詞、seed、用在哪個鏡頭,且每個 timeline 用到的 `work/<n>/ai/` 檔案都在表內;每支成品 `comfy.mjs scrub-check <工作目錄>/<n>` 結束碼 0;每張 AI 靜態圖與每個動態鏡頭的首 / 中 / 末格都已 Read 並描述,沒有任何生成的文字或類文字圖樣(含亂碼)、沒有重複主體;所有 AI 動態鏡頭在 `compose.mjs` 摘要的 `hold` ≤ 0.5 秒(沒有長時間停格)。
12. `topic` 文案輸入時:`script.md` 旁白依序串接(去掉標點與空白)等於原文案(去掉標點與空白)。
13. ComfyUI 不可用時:`topic` 模式為 BLOCKED 且沒有留下工作目錄;其他模式照常完成,回報「AI 素材」行依情況寫:派工指定不用 →「未使用:派工指定」;check 失敗 →「未使用:check 結束碼 <n>(<訊息>)」;check 成功但需要的骨架為 `false` →「未使用:<骨架> 不可用」。

## 限制與禁忌
- 不用 `sudo`、不安裝東西、不改系統設定。
- `rm -rf` 只能用在 `<工作目錄>/work`,以及第 0 步之後 BLOCKED 時本次建立的 `<工作目錄>`。
- 背景服務只透過 `web-dev-kit` 的 `serve.sh` / `stop.sh`。
- 網路：只允許 `git clone`、repo 安裝依賴(有執行旗標)、`yt-dlp`(有授權旗標)、透過 `comfy.mjs` 連區網 ComfyUI;錄影只打 `localhost` / `127.0.0.1`;`render.mjs` 擋掉所有非 `file://` 請求。
- 不在畫面或字幕放 repo 裡的秘密值。

## 工具
| 工具 | 為什麼需要 |
|---|---|
| Read | 讀 repo 檔案、文字稿、檢視擷取的畫面 PNG |
| Write | 寫 `script.md`、`timeline.json`、`cards.json`、`actions.json`、句子檔 |
| Edit | 修正上述檔案 |
| Bash | 只用以下指令:`bash <kit>/scripts/*.sh`、`node <kit>/scripts/*.mjs`、`bash <web-dev-kit>/scripts/serve.sh` / `stop.sh`、`git clone --depth 1`、`git -C <repo> rev-parse HEAD` / `status --porcelain --ignored`、`ffprobe`、`shasum`、`find … \| sort -z \| xargs -0 shasum`、`(cd <repo> && git ls-files -m -o --exclude-standard -z \| xargs -0 shasum \| shasum)`、`ls`、`sips`、`date`、讀輸出用的 `grep` / `head` / `tail` / `wc` / `cat`(只讀 `<job>` 內的檔案或接在上述指令的管線後;要記結束碼時先導向 log 再讀,2026-11-24 加入:兩次實測 agent 都需要讀輸出而超出白名單,且接管線後 `$?` 取錯)、`mkdir -p <job>/work/<n>` / `<job>/<n>`(kit 的檔案用 Read 讀)、影片模式抽配色參考格 `ffmpeg -y -ss <秒> -i <來源> -frames:v 1 <job>/work/<n>/palette.png`(不加濾鏡)、`node <game-art-kit>/scripts/comfy.mjs check` / `upload` / `run` / `scrub-check`(`run` 的 `--out` 只能是 `<job>/work/<n>/ai`)、`node <game-art-kit>/scripts/audio.mjs process`(`--out` 只能是 `<job>/work/<n>/ai`)/ `check`、檢查 AI 影片格 `ffmpeg -y [-loglevel error] -ss <秒> -i <job>/work/<n>/ai/<clip>.mp4 -frames:v 1 <job>/work/<n>/ai/<名稱>.jpg`、`rm -rf`(限「限制與禁忌」所列路徑);有執行旗標時，在 `work/repo` 內執行 repo 的套件管理器 install / build / start;有授權旗標時 `yt-dlp`。其他指令一律不用 |

不給 WebFetch / WebSearch:repo / 影片模式內容只來自 repo 與影片本身;`topic` 模式只寫普遍公認的內容,不確定的列給使用者確認。

## 停止並詢問的情況(用 BLOCKED 回報給主 agent)
第 0 步可判斷(不建立任何檔案):
- `check.sh` 回報缺工具或模型。
- 影片網址但沒有授權旗標。
- 工作目錄已存在。
- 需求有多種解讀且會大幅影響成品(例如「做三支」沒說是同一主題的三段還是三種風格)。
- `topic` 模式但 ComfyUI 不可用(check 失敗,或 `qwen-t2i` 不是 `true`)。
- `topic` 模式的主題要畫真實人物、品牌或既有作品角色。

第 0 步之後(刪除工作目錄後回報):
- repo clone 失敗(私有、需要帳密或網址不存在;回報附 git 的錯誤輸出)。
- `topic` 的 `qwen-t2i` / `qwen-edit-1ref` 連不上或逾時,重試 1 次仍失敗。
- `topic` 文案 tts 實測 > 55 秒(附實際長度,請使用者刪減或同意改寫)。
- `video-condense` 剪完仍 > 60 秒，或來源沒有音軌。
- `video-highlight` 文字稿幾乎是空的(或沒有音軌),又沒有派工說明可挑段落。

不需要 BLOCKED:repo 沒有執行旗標或跑不起來 → 直接用 `repo-cards`,回報寫原因。

## 語言與語氣
旁白、字幕、標題預設繁體中文;原聲是其他語言時字幕保留原文，派工要求才加譯文行。回報簡潔，以證據為主。

## 已知限制(寫進 agent)
- `say` 語音較機械。
- whisper 常略過或合併「嗯、呃」,`video-condense` 主要靠停頓偵測，贅字可能剪不乾淨。
- `repo-record` 只支援能在本機用瀏覽器打開的網頁專案。
- AI 對在地食物 / 物品常畫錯(2026-11-24 實測:蚵仔煎畫成帶殼生蠔加荷包蛋),照規則判 ISSUES 並建議提供真實照片。

## 協作
- 角色:owner(寫入者)
- 是否會寫入檔案：是(git 倉庫外的 `~/Movies/Shorts/`,不需要分支)
- 可寫路徑:`<out>/<YYYYMMDD>-<slug>/`;腳本暫存 `$TMPDIR/short-video-kit/<slug>/`、`$TMPDIR/web-dev-kit/`、`$TMPDIR/gak-run-*`(comfy.mjs / audio.mjs 自行清除);節點快取 `~/.cache/game-art-kit/`;ComfyUI 伺服器只有 temp 區(上傳的起始圖,ComfyUI 重開即清)
- 不可寫路徑與禁止動作：來源影片、原 repo、skill 目錄、其他工作目錄;上傳、安裝、`sudo`
- 完成時要回報的證據:`verify.sh` JSON、5 張畫面描述、旁白實測長度、精華的來源時間碼、清理結果、來源指紋兩次;有 AI 素材時加 `comfy.mjs check` 摘要(可用骨架)、每支的 `scrub-check` 輸出、AI 素材表、每張 AI 圖與每個動態鏡頭首 / 中 / 末格的描述
- 可否與其他寫入 agent 平行：是(每個工作目錄獨立;`serve.sh` 名稱用 `<slug>`)
- 建議的模型與推理強度:inherit(挑精華與寫腳本需要判斷力)
- 需要的 skill:`short-video-kit`(新建)、`game-art-kit`(既有,2026-11-24 加入:共用 ComfyUI 客戶端、骨架、音訊處理)。理由:ffmpeg 濾鏡圖、Chrome 錄影與 HTML 轉 PNG、字幕時間排程、響度兩階段、規格檢查，每支影片都一樣，屬於「每次都要重寫的固定程式」。另用既有的 `web-dev-kit`(`serve.sh` / `stop.sh`)。
- host 需要核准：寫入 `~/Movies/Shorts/`、`$TMPDIR`;區網 ComfyUI(macOS「本機網路」權限);`github.com`(clone);有執行旗標時 repo 的套件 registry(`registry.npmjs.org`、`pypi.org` 等);有授權旗標時影片網站。

## short-video-kit skill 內容
- `scripts/check.sh [--video] [--url]`:檢查 ffmpeg、ffprobe、node、Chrome、`say -v Meijia`;`--video` 加 `whisper-cli` 與模型檔(`SHORT_VIDEO_WHISPER_MODEL`,預設 `~/.cache/whisper/ggml-large-v3-turbo.bin`);`--url` 加 `yt-dlp`。缺少時結束碼 3,印出完整安裝指令(含模型的 `curl -L -o` 下載網址)。
- `scripts/probe.sh <影片>`:一行 JSON(`duration`、`width`、`height`、`rotation`、`fps`、`hasAudio`),寬高已套用旋轉。
- `scripts/transcribe.sh <影片> <輸出.json> [--lang auto|zh|en…]`:抽 16 kHz 單聲道 → `whisper-cli -oj`,輸出 `{"lang":"zh","segments":[{start,end,text}]}`。
- `scripts/silence.sh <影片> [--min 0.5] [--db -35]`:`silencedetect` → `[{start,end}]`。
- `scripts/tts.sh <句子檔> <輸出目錄> [--voice Meijia] [--rate 190]`:每行一句 → `NNN.m4a`(48 kHz),印出 `[{i,text,file,duration}]`。
- `scripts/render.mjs <卡片.json> <輸出目錄> [--asset-root <目錄>]`:Chrome headless(CDP)用內建版型 `title` / `code` / `point` / `end` / `subtitle` / `cover` 渲染 1080×1920 透明 PNG。內容一律以 `textContent` 放入;圖片只接受 `--asset-root` 內的相對路徑(解析 symlink 後再檢查,沒給 `--asset-root` 就不接受圖片);用 CDP `Fetch` 擋掉非 `file://` 請求。`subtitle` 依「最多 2 行、64→44 px」自動縮字，量出邊界框寫進 `boxes.json`,超出安全區結束碼 4。
- `scripts/record-web.mjs <網址> <動作.json> <輸出.mp4>`:CDP screencast,540×960 @2x,動作 `goto` / `wait` / `scroll` / `click` / `type`,輸出 30 fps MP4;只允許 `localhost` / `127.0.0.1` 網址。
- `scripts/compose.mjs <timeline.json> <輸出目錄>`:依 timeline 組 ffmpeg 濾鏡圖(剪段、縮放 / 模糊背景 / 裁切、疊圖、旁白與原聲混音、背景音樂 sidechain、`loudnorm` 兩階段)產生 `final.mp4` 與 `work/<n>/first-frame.png`;依固定規則排字幕時間(原聲拆句依字數比例切分)，產生 `subtitles.srt`(原聲模式把剪掉的區間重新對應);`--dry-run` 只印指令與 SRT。
- `scripts/frames.sh <影格目錄> <名稱> <輸出.mp4> --frames N [--fps 24]`(`--frames` 必填 = 骨架的 length,只取 1..N,同名重跑留下的舊格數不會混入):把 `comfy.mjs run` 下載的 `<名稱>-1.png … <名稱>-N.png` 組成 H.264 MP4(檢查編號連續、尺寸一致),印 `{frames,fps,duration,width,height}`。
- `compose.mjs` 旁白模式的鏡頭新增欄位(2026-11-24):圖片鏡頭 `fill: true`(等比蓋滿再置中裁切,AI 圖用;卡片不用)與 `motion: "in" | "out" | "left" | "right"`(緩慢推近 / 拉遠 / 平移,自動蓋滿,不需另設 `fill`);影片鏡頭 `fit` 覆寫整支的設定;任一鏡頭 `sfx: {"path", "volume"}` 在鏡頭開始時播放。摘要的每個影片鏡頭附 `hold`(來源不夠長、停在最後一格的秒數)。
- `scripts/verify.sh <影片> <checks 目錄> --boxes <boxes.json> --cover <cover.png>`:檢查成功標準 1–3 的機械部分，印一行 JSON,失敗結束碼 1;`boxes.json` 或 cover 找不到算失敗。
- `tests/run.sh`:用 ffmpeg 產生測試影片(色塊 + 正弦波 + 停頓 + 橫式 / 直式)與 `say` 句子，跑每個腳本並檢查輸出，包含:SRT 時間等於 tts 長度公式、原聲拆句依字數比例切分、condense 剪後長度、字幕過長時縮字或結束碼 4、卡片內容含 `<script>` 與外部 `<img>` 時不執行也不連線、`verify.sh` 對錯誤規格影片失敗。`transcribe.sh` 只在有模型檔時跑。缺 ffmpeg 時印 SKIP,**SKIP 不算通過**。結束時刪除暫存目錄。
