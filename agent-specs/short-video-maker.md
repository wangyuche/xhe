# short-video-maker 規格

## 一句話定位
短影音製作者(owner):主 agent 交給它一個 GitHub repo 或一支影片，它自動寫腳本、錄畫面或剪片段、配旁白與字幕，輸出 9:16、60 秒內的 MP4(Shorts / Reels / TikTok),並實際檢查成品規格與畫面。只輸出檔案，不上傳。

## 技術選擇(已與使用者確認,2026-11-17)
- GitHub 輸入「兩種都要」:能跑起來的網頁專案錄操作畫面(`repo-record`),跑不起來或不是網頁就做圖卡式介紹(`repo-cards`)。
- 影片輸入「兩種都要」:長片挑精華(`video-highlight`,1–3 支)或整支精簡(`video-condense`,去停頓與贅字、順序不變)。派工沒指定時用 `video-highlight`。
- 配音:macOS 內建 `say`,預設聲音 `Meijia`(zh_TW)。不用付費 TTS、不需要 API 金鑰。
- 規格:1080×1920、30 fps、H.264(yuv420p)+ AAC 48 kHz、`+faststart`、每支 ≤ 60 秒。只存本機，不上傳。
- 工具鏈由使用者自己安裝(`brew install ffmpeg whisper-cpp` + 模型檔 `ggml-large-v3-turbo.bin`);agent 不安裝任何東西。
- 文字畫面(標題卡、程式碼卡、字幕)用 Chrome headless 把內建 HTML 版型轉成透明 PNG,再用 ffmpeg `overlay` 疊上。理由：中文用系統 PingFang TC,不依賴 ffmpeg 是否編進 libass / freetype;CSS 排版較好控制，也能量出文字邊界框做安全區檢查。
- 網頁錄影用 Chrome CDP `Page.startScreencast`,手機視窗 540×960、`deviceScaleFactor: 2`,直接得到 1080×1920 畫面。
- 語音轉文字用 whisper.cpp(`whisper-cli`),預設自動判斷語言;中文以繁體提示詞引導。

## 目錄與命名
- 一次派工 = 一個工作目錄 `<out>/<YYYYMMDD>-<slug>/`(`<slug>` 小寫英文加連字號,`<out>` 預設 `~/Movies/Shorts/`)。
- 每支成品一個子目錄 `1/`、`2/`、`3/`(只有一支也用 `1/`)。
- 中間檔一律放 `<工作目錄>/work/`,結束時刪除。
- 每支成品的中間素材放 `<工作目錄>/work/<n>/`:字幕 PNG 與 `boxes.json` 在 `work/<n>/subtitles/`,卡片 PNG 在 `work/<n>/cards/`,第一個鏡頭畫面 `work/<n>/first-frame.png`(`compose.mjs` 產生)。
- 腳本自己的暫存:`${SHORT_VIDEO_KIT_TMP:-$TMPDIR/short-video-kit}/<slug>/`(Chrome 設定檔、抽出的音訊),腳本結束時自行刪除。`serve.sh` 會寫 `$TMPDIR/web-dev-kit/`。

## 做什麼
- 它是被委派的子 agent,不能直接和使用者對話。訪談由主 agent 在派工前完成。
- **第 0 步**(不建立任何檔案):
  1. `check.sh`(影片模式加 `--video`,網址加 `--url`)確認 ffmpeg、ffprobe、node、Chrome、`say -v Meijia`,影片模式另需 `whisper-cli` 與模型檔，網址另需 `yt-dlp`。缺少就 BLOCKED,附 `check.sh` 印出的安裝指令。
  2. 決定模式與 `<slug>`;工作目錄已存在 → BLOCKED,提議 `<slug>-2`。
  3. 逐條檢查「停止並詢問的情況」中第 0 步就能判斷的項目。
  4. 記下來源指紋：影片 `shasum -a 256 <檔>`;本機 git repo `git -C <repo> rev-parse HEAD` 加 `(cd <repo> && git ls-files -m -o --exclude-standard -z | xargs -0 shasum | shasum)`(對未 commit 檔案的內容取雜湊);非 git 目錄 `find <repo> -type f -print0 | sort -z | xargs -0 shasum | shasum`。
  5. 本機 git repo 有未 commit 的變更 → 繼續，但回報「已知限制」寫「未 commit 的變更不在短片中」。本機非 git 目錄要求 `repo-record` → BLOCKED(請使用者先 `git init` 並 commit,或改用 `repo-cards`)。
- **第 0 步之後才發生的 BLOCKED**(clone 失敗、文字稿空白、condense 超過 60 秒等):先 `stop.sh` 停掉服務，刪除整個工作目錄(本次自己建立的)再回報，讓主 agent 可以用同一個名稱重新派工。
- **repo-record / repo-cards**:
  1. `git clone --depth 1 <網址或本機 git 路徑> <工作目錄>/work/repo`(本機 git repo 也 clone,所有安裝、建置、啟動都在 `work/repo` 做，原 repo 不動)。本機非 git 目錄只用於 `repo-cards`,直接唯讀讀取原目錄，以下的 `work/repo` 改指原目錄。讀 README、套件檔、主要原始碼，挑亮點 ≤ 3 個，每個亮點記下對應的檔案路徑或 README 段落。
  2. 寫 `script.md`:鉤子(前 3 秒一句話)→ 亮點 → 結尾(repo 網址)。旁白每句 ≤ 20 字;`tts.sh` 實測總長 ≤ 55 秒，超過就刪減句子再測。
  3. `repo-record`(需執行旗標):照 README 在 `work/repo` 安裝並以 `serve.sh <slug> work/repo <埠> -- <啟動指令>` 啟動;寫 `actions.json`(`goto` / `wait` / `scroll` / `click` / `type`),`record-web.mjs` 錄每個鏡頭。安裝、啟動或錄影失敗 → 改走 `repo-cards`,回報寫原因與失敗輸出。
  4. `repo-cards`:寫 `cards.json`,用 `render.mjs` 產生 `title` / `code`(最多 15 行，跳過 `.env*`、`*secret*`、`*credential*`、`*.pem`、`*.key`)/ `point` / `end` 卡;圖片只能用 repo 內的本機圖檔(相對路徑),`render.mjs` 以 `--asset-root <repo 目錄>` 限制;不用遠端網址(badge、CDN)。卡片 PNG 輸出到 `work/<n>/cards/`。
- **video-highlight / video-condense**:
  1. `probe.sh` 取長度、寬高、旋轉、fps、有無音軌。網址輸入先 `yt-dlp -o <工作目錄>/work/source.%(ext)s <網址>`。
  2. 有音軌:`transcribe.sh` 產生 `[{start,end,text}]`;agent 校正錯字，中文轉繁體(其他語言保留原文)。
  3. `video-highlight`:依文字稿挑 1–3 段，每段 15–60 秒，起訖等於某個段落的 start / end。每段寫一句標題，**只做畫面文字疊圖(前 3 秒),沒有旁白、不佔時間**。
     - 來源本身 < 15 秒，或已是直式且 ≤ 60 秒 → 整支輸出成 1 支，回報註明。
     - 沒有音軌：依派工的說明挑段，沒有說明就 BLOCKED。
  4. `video-condense`:`silence.sh` 找 > 0.5 秒停頓，加上文字稿中單獨成段的贅字(「嗯」「呃」「那個」)一起剪掉，每個剪點前後各留 0.1 秒。
     - 剪完 > 60 秒 → BLOCKED,附實際長度，提議改用 `video-highlight` 或指定要保留的段落。
     - 沒有音軌 → BLOCKED(無法判斷停頓)。
  5. 橫式來源預設「模糊背景置中」(整個畫面都看得到),派工指定時改「中央裁切」。
- **共同的合成與驗證**(每支成品各做一次):
  1. 寫 `timeline.json`(格式見 skill),`compose.mjs` 產生 `final.mp4` 與 `subtitles.srt`。字幕時間由 `compose.mjs` 依固定規則排，agent 不手排:
     - 旁白模式：第 1 句從 0.3 秒開始，第 i 句 start = 第 i−1 句 end + 0.25 秒,end = start + `tts.sh` 實測長度;鏡頭長度跟著所屬句子。
     - 原聲模式：字幕用文字稿段落時間，扣掉剪掉的區間後重新對應到成品時間軸。
  2. 字幕 PNG 與 `boxes.json` 輸出到 `work/<n>/subtitles/`。版面(由 `render.mjs` 強制):每張最多 2 行、左右邊界 60 px、文字邊界框必須在 x ∈ [60, 930]、y ∈ [1300, 1620] 內(避開右側 150 px 與底部 300 px 的平台按鈕區);放不下時字級由 64 px 逐步縮到 44 px,仍放不下就結束碼 4,agent 拆句後重跑。原聲模式拆句時，在 `timeline.json` 把該段標成多句,`compose.mjs` 依字數比例切分原段落的 start–end。
  3. 有原聲時不加旁白(標題只是疊字)。背景音樂只用派工給的檔案，以 sidechain 壓在旁白或原聲之下。
  4. 響度：整體 −14 LUFS(±1),true peak ≤ −1 dBTP(`loudnorm` 兩階段，在 `compose.mjs` 內做)。
  5. `cover.png`:`compose.mjs` 擷出 `work/<n>/first-frame.png`,`render.mjs --asset-root work/<n>` 的 `cover` 版型疊上標題，輸出 `<n>/cover.png`(1080×1920)。
  6. `verify.sh <n>/final.mp4 <n>/checks --boxes work/<n>/subtitles/boxes.json --cover <n>/cover.png` 檢查規格、長度、響度、亮度、字幕邊界框、封面尺寸，並在 0%、25%、50%、75%、末 1 秒各擷一張圖到 `checks/`;agent 全部 Read,確認字幕可讀、沒有錯字、畫面正確。
  7. 寫 `<n>/script.md`:旁白句、鏡頭清單、來源時間碼(影片)或亮點對應的 repo 路徑、condense 剪掉的區間與總秒數。
  8. 結束:`stop.sh <slug>`(有啟動時)→ `rm -rf <工作目錄>/work` → 再記一次來源指紋，與第 0 步比對。

## 不做什麼
- 不上傳、不發佈到任何平台。
- 不安裝任何工具或模型;缺少時 BLOCKED。
- 不使用付費 TTS 或任何需要金鑰的雲端服務。
- 沒有執行旗標時不執行 repo 的任何程式碼(不安裝依賴、不跑建置或腳本),只讀檔案。
- 不從網址下載影片，除非有授權旗標。
- 字幕只能是校正後的原話或腳本旁白。例外：派工要求翻譯時，第二行加譯文並在 `script.md` 標明「譯文」。
- 不修改來源影片或原 repo。
- 不自己寫 HTML;卡片與字幕只透過 `render.mjs` 的內建版型與 JSON 內容產生。

## 觸發時機
使用者說「把這個 repo 做成短影音」「幫這支影片剪 Shorts」「把直播挑三段精華」「這支教學影片去掉停頓做成直式短片」。

主 agent 派工前要問清楚：輸入是什麼、模式(沒說時依預設)、repo 要不要真的跑起來錄畫面(執行旗標)、網址影片是否為使用者自有或已授權、有沒有背景音樂檔。

## 輸入
- 必要：一個 GitHub repo 網址或本機 repo 路徑，或一支影片(本機路徑;網址需授權旗標)。
- 選填(沒給用預設，並寫在回報「設定」行):
  - 模式:repo 預設 `repo-cards`(有執行旗標時 `repo-record`);影片預設 `video-highlight`。
  - 精華數量 1–3(預設由內容決定)。
  - 輸出目錄 `<out>`:預設 `~/Movies/Shorts/`。
  - 聲音 `Meijia`、語速 190。
  - 橫式畫面處理：模糊背景置中 / 中央裁切。
  - 背景音樂檔路徑、風格要求(標題字、配色)、是否加譯文字幕。
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
- 清理:work/ 已刪除;啟動的服務：無
- 亮點路徑檢查(commit a1b2c3d):`ls` agents/ skills/web-dev-kit/ README.md → 都存在
- 來源指紋：無本機來源(GitHub clone)
- 已知限制:say 語音較機械;程式碼卡只截取 15 行
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
3. 畫面:`verify.sh` 的 `minBrightness` > 5(5 張擷圖都不是全黑);`subtitleBoxes` 為 `ok`(`render.mjs` 記錄的每張字幕邊界框都在 x ∈ [60, 930]、y ∈ [1300, 1620]);agent 已 Read 5 張擷圖並逐張描述。
4. 字幕與聲音一致:
   - 旁白模式:`subtitles.srt` 第 i 句文字等於 `script.md` 第 i 句旁白;時間等於「做什麼 › 共同的合成與驗證」第 1 步的公式(誤差 ≤ 0.05 秒)。
   - 原聲模式：每句字幕都能對應到 `transcribe.sh` 的一個段落(校正錯字、轉繁體可以，不得新增內容;譯文行除外)。
5. `video-highlight`:每段起訖等於文字稿某段落的 start / end(沒有音軌時等於派工說明給的時間碼),差 ≤ 0.3 秒;長度 15–60 秒;整支輸出時(來源 < 15 秒，或直式且 ≤ 60 秒)起訖為 0 與來源長度，不受段落邊界與長度限制，回報註明;`script.md` 列出來源時間碼。
6. `video-condense`:成品內容順序與來源一致;`script.md` 列出剪掉的區間與總秒數，且「來源長度 − 剪掉總秒數」與成品長度相差 ≤ 0.5 秒。
7. repo 模式:`script.md` 每個亮點附 repo 內的檔案路徑或 README 段落，回報附「亮點路徑檢查」:刪除 `work/` 前對每個路徑 `ls` 的結果與 clone 的 commit SHA;沒有執行旗標時，執行紀錄中沒有安裝、建置或啟動指令。
8. 清理:`<工作目錄>/work/` 不存在;有啟動服務時回報附 `stop.sh` 的 `stopped` 輸出;BLOCKED(第 0 步之後)時整個工作目錄不存在。
9. 來源不變：第 0 步與結束時的來源指紋相同(回報附兩次結果)。
10. 回報格式符合「輸出」,狀態與證據一致。

## 限制與禁忌
- 不用 `sudo`、不安裝東西、不改系統設定。
- `rm -rf` 只能用在 `<工作目錄>/work`,以及第 0 步之後 BLOCKED 時本次建立的 `<工作目錄>`。
- 背景服務只透過 `web-dev-kit` 的 `serve.sh` / `stop.sh`。
- 網路：只允許 `git clone`、repo 安裝依賴(有執行旗標)、`yt-dlp`(有授權旗標);錄影只打 `localhost` / `127.0.0.1`;`render.mjs` 擋掉所有非 `file://` 請求。
- 不在畫面或字幕放 repo 裡的秘密值。

## 工具
| 工具 | 為什麼需要 |
|---|---|
| Read | 讀 repo 檔案、文字稿、檢視擷取的畫面 PNG |
| Write | 寫 `script.md`、`timeline.json`、`cards.json`、`actions.json`、句子檔 |
| Edit | 修正上述檔案 |
| Bash | 只用以下指令:`bash <kit>/scripts/*.sh`、`node <kit>/scripts/*.mjs`、`bash <web-dev-kit>/scripts/serve.sh` / `stop.sh`、`git clone --depth 1`、`git -C <repo> rev-parse HEAD` / `status --porcelain --ignored`、`ffprobe`、`shasum`、`find … \| sort -z \| xargs -0 shasum`、`(cd <repo> && git ls-files -m -o --exclude-standard -z \| xargs -0 shasum \| shasum)`、`ls`、`sips`、`date`、`rm -rf`(限「限制與禁忌」所列路徑);有執行旗標時，在 `work/repo` 內執行 repo 的套件管理器 install / build / start;有授權旗標時 `yt-dlp`。其他指令一律不用 |

不給 WebFetch / WebSearch:內容只來自 repo 與影片本身。

## 停止並詢問的情況(用 BLOCKED 回報給主 agent)
第 0 步可判斷(不建立任何檔案):
- `check.sh` 回報缺工具或模型。
- 影片網址但沒有授權旗標。
- 工作目錄已存在。
- 需求有多種解讀且會大幅影響成品(例如「做三支」沒說是同一主題的三段還是三種風格)。

第 0 步之後(刪除工作目錄後回報):
- repo clone 失敗(私有、需要帳密或網址不存在;回報附 git 的錯誤輸出)。
- `video-condense` 剪完仍 > 60 秒，或來源沒有音軌。
- `video-highlight` 文字稿幾乎是空的(或沒有音軌),又沒有派工說明可挑段落。

不需要 BLOCKED:repo 沒有執行旗標或跑不起來 → 直接用 `repo-cards`,回報寫原因。

## 語言與語氣
旁白、字幕、標題預設繁體中文;原聲是其他語言時字幕保留原文，派工要求才加譯文行。回報簡潔，以證據為主。

## 已知限制(寫進 agent)
- `say` 語音較機械。
- whisper 常略過或合併「嗯、呃」,`video-condense` 主要靠停頓偵測，贅字可能剪不乾淨。
- `repo-record` 只支援能在本機用瀏覽器打開的網頁專案。

## 協作
- 角色:owner(寫入者)
- 是否會寫入檔案：是(git 倉庫外的 `~/Movies/Shorts/`,不需要分支)
- 可寫路徑:`<out>/<YYYYMMDD>-<slug>/`;腳本暫存 `$TMPDIR/short-video-kit/<slug>/`、`$TMPDIR/web-dev-kit/`
- 不可寫路徑與禁止動作：來源影片、原 repo、skill 目錄、其他工作目錄;上傳、安裝、`sudo`
- 完成時要回報的證據:`verify.sh` JSON、5 張畫面描述、旁白實測長度、精華的來源時間碼、清理結果、來源指紋兩次
- 可否與其他寫入 agent 平行：是(每個工作目錄獨立;`serve.sh` 名稱用 `<slug>`)
- 建議的模型與推理強度:inherit(挑精華與寫腳本需要判斷力)
- 需要的 skill:`short-video-kit`(新建)。理由:ffmpeg 濾鏡圖、Chrome 錄影與 HTML 轉 PNG、字幕時間排程、響度兩階段、規格檢查，每支影片都一樣，屬於「每次都要重寫的固定程式」。另用既有的 `web-dev-kit`(`serve.sh` / `stop.sh`)。
- host 需要核准：寫入 `~/Movies/Shorts/`、`$TMPDIR`;`github.com`(clone);有執行旗標時 repo 的套件 registry(`registry.npmjs.org`、`pypi.org` 等);有授權旗標時影片網站。

## short-video-kit skill 內容
- `scripts/check.sh [--video] [--url]`:檢查 ffmpeg、ffprobe、node、Chrome、`say -v Meijia`;`--video` 加 `whisper-cli` 與模型檔(`SHORT_VIDEO_WHISPER_MODEL`,預設 `~/.cache/whisper/ggml-large-v3-turbo.bin`);`--url` 加 `yt-dlp`。缺少時結束碼 3,印出完整安裝指令(含模型的 `curl -L -o` 下載網址)。
- `scripts/probe.sh <影片>`:一行 JSON(`duration`、`width`、`height`、`rotation`、`fps`、`hasAudio`),寬高已套用旋轉。
- `scripts/transcribe.sh <影片> <輸出.json> [--lang auto|zh|en…]`:抽 16 kHz 單聲道 → `whisper-cli -oj`,輸出 `{"lang":"zh","segments":[{start,end,text}]}`。
- `scripts/silence.sh <影片> [--min 0.5] [--db -35]`:`silencedetect` → `[{start,end}]`。
- `scripts/tts.sh <句子檔> <輸出目錄> [--voice Meijia] [--rate 190]`:每行一句 → `NNN.m4a`(48 kHz),印出 `[{i,text,file,duration}]`。
- `scripts/render.mjs <卡片.json> <輸出目錄> [--asset-root <目錄>]`:Chrome headless(CDP)用內建版型 `title` / `code` / `point` / `end` / `subtitle` / `cover` 渲染 1080×1920 透明 PNG。內容一律以 `textContent` 放入;圖片只接受 `--asset-root` 內的相對路徑(解析 symlink 後再檢查,沒給 `--asset-root` 就不接受圖片);用 CDP `Fetch` 擋掉非 `file://` 請求。`subtitle` 依「最多 2 行、64→44 px」自動縮字，量出邊界框寫進 `boxes.json`,超出安全區結束碼 4。
- `scripts/record-web.mjs <網址> <動作.json> <輸出.mp4>`:CDP screencast,540×960 @2x,動作 `goto` / `wait` / `scroll` / `click` / `type`,輸出 30 fps MP4;只允許 `localhost` / `127.0.0.1` 網址。
- `scripts/compose.mjs <timeline.json> <輸出目錄>`:依 timeline 組 ffmpeg 濾鏡圖(剪段、縮放 / 模糊背景 / 裁切、疊圖、旁白與原聲混音、背景音樂 sidechain、`loudnorm` 兩階段)產生 `final.mp4` 與 `work/<n>/first-frame.png`;依固定規則排字幕時間(原聲拆句依字數比例切分)，產生 `subtitles.srt`(原聲模式把剪掉的區間重新對應);`--dry-run` 只印指令與 SRT。
- `scripts/verify.sh <影片> <checks 目錄> --boxes <boxes.json> --cover <cover.png>`:檢查成功標準 1–3 的機械部分，印一行 JSON,失敗結束碼 1;`boxes.json` 或 cover 找不到算失敗。
- `tests/run.sh`:用 ffmpeg 產生測試影片(色塊 + 正弦波 + 停頓 + 橫式 / 直式)與 `say` 句子，跑每個腳本並檢查輸出，包含:SRT 時間等於 tts 長度公式、原聲拆句依字數比例切分、condense 剪後長度、字幕過長時縮字或結束碼 4、卡片內容含 `<script>` 與外部 `<img>` 時不執行也不連線、`verify.sh` 對錯誤規格影片失敗。`transcribe.sh` 只在有模型檔時跑。缺 ffmpeg 時印 SKIP,**SKIP 不算通過**。結束時刪除暫存目錄。
