---
name: short-video-kit
description: 9:16 短影音的固定腳本:工具檢查、影片探測、whisper 轉文字、停頓偵測、macOS say 旁白、Chrome 渲染卡片與字幕(安全區檢查)、Chrome 錄網頁、ffmpeg 合成(剪段 / 模糊背景 / 疊字幕 / 混音 / 響度 −14 LUFS)、成品規格驗證。short-video-maker 製作短片時使用;任何要把 repo 或影片做成直式短片的情境也可用。
---

# short-video-kit

`<kit>` = 這個 skill 的目錄。需要 ffmpeg、node ≥ 22、Google Chrome、macOS `say`(Meijia);轉文字另需 `whisper-cli` 與模型檔。腳本暫存放 `${SHORT_VIDEO_KIT_TMP:-$TMPDIR/short-video-kit}/`,結束時自行刪除。

## 腳本

```bash
bash <kit>/scripts/check.sh [--video] [--url]       # 缺工具結束碼 3,印安裝指令
bash <kit>/scripts/probe.sh <影片>                  # {"duration","width","height","rotation","fps","hasAudio","orientation"}(已套用旋轉)
bash <kit>/scripts/transcribe.sh <影片> <out.json> [--lang auto|zh|en]   # {"lang","segments":[{start,end,text}]}
bash <kit>/scripts/silence.sh <影片> [--min 0.5] [--db -35]              # [{start,end}];沒有音軌結束碼 3
bash <kit>/scripts/tts.sh <句子檔> <輸出目錄> [--voice Meijia] [--rate 190]  # 每行一句 → [{i,text,file,duration}]
node <kit>/scripts/render.mjs <cards.json> <輸出目錄> [--asset-root <目錄>]  # 卡片 / 字幕 PNG;字幕放不下結束碼 4
node <kit>/scripts/record-web.mjs <本機網址> <actions.json> <out.mp4>        # 1080×1920 30fps 無聲
node <kit>/scripts/compose.mjs <timeline.json> [--dry-run]                  # final.mp4 + subtitles.srt;超過 60 秒結束碼 5
bash <kit>/scripts/verify.sh <final.mp4> <checks 目錄> --boxes <boxes.json> --cover <cover.png>
bash <kit>/tests/run.sh                              # 自我測試(SKIP 不算通過)
```

## cards.json(render.mjs)

```json
{"theme": {"bg":"<#RRGGBB>","bg2":"<#RRGGBB>","fg":"<#RRGGBB>","accent":"<#RRGGBB>","muted":"<#RRGGBB>"},
 "cards": [
  {"type":"title","file":"001.png","tag":"github.com/o/r","title":"鉤子一句話","subtitle":"副標"},
  {"type":"point","file":"002.png","number":"1","title":"亮點","body":"說明","image":"docs/shot.png"},
  {"type":"code","file":"003.png","title":"(選填)","path":"src/main.go","code":"…"},
  {"type":"end","file":"004.png","title":"去 GitHub 看看","url":"github.com/o/r"},
  {"type":"cover","file":"cover.png","image":"first-frame.png","title":"封面標題"}   // image 省略 = 漸層底封面(repo 模式用)
 ]}
```

- **`theme` 沒有預設值**:有 title / point / code / end / headline 卡或沒有 image 的 cover 時,五個欄位都必填(缺了結束碼 2)。每支影片依來源自己選(repo 的 logo / 網站主色、影片畫面主色),不要沿用別支的色碼。只有字幕卡、有 image 的封面時可以省略(有圖封面的標題與 tag 一律白字,疊在照片上才看得清楚;theme 只影響漸層封面)。色碼一律 `#RRGGBB`(舊版接受的 `#RGB`、`#RRGGBBAA` 現在會結束碼 2,舊檔要改寫);要給 theme 時用物件格式 `{"theme":…,"cards":[…]}`。
- 全版卡(title / point / code / end)內容避開右側 170 px 與底部 340 px(平台按鈕區)。
- 文字一律以純文字放入,不解析 HTML;不要自己寫 HTML。
- `image` 只接受 `--asset-root` 內的相對路徑(symlink 解析後再檢查),沒給 `--asset-root` 就不接受圖片。所有網路請求都被擋掉,`blockedRequests` 會列出。
- code 卡最多 15 行,超過截斷並在 stderr 提示。
- subtitle / headline 由 compose.mjs 自動產生,通常不用手寫。

## actions.json(record-web.mjs)

```json
[{"do":"goto","url":"/"},{"do":"wait","ms":1500},{"do":"type","selector":"#q","text":"牛奶"},
 {"do":"click","selector":"button.add"},{"do":"scroll","y":800,"ms":1200}]
```

手機視窗 540×960 @2x。輸出的 `marks` 是每個動作開始的秒數(相對成品開頭),排鏡頭時用它決定 `in`(例如要拍到劃掉的瞬間,`in` 取 click 的 t 減 0.5)。只能錄 `localhost` / `127.0.0.1`,頁面對外的請求會被擋並列在 `blockedRequests`。網站用 web-dev-kit 的 `serve.sh` 啟動。

## timeline.json(compose.mjs)

路徑都相對於 timeline.json 所在目錄。共同欄位:`mode`、`work`(必填,中間檔目錄)、`out`(預設 timeline 所在目錄)、`fit`(`blur` 模糊背景置中,預設 / `crop` 中央裁切;原聲模式與直式鏡頭用,橫式錄影鏡頭見下方「置頂」)、`theme`(同 cards.json,沒有預設;原聲模式有 `headline` 時五個欄位必填、有置頂鏡頭時 `theme.bg` 必填,缺了結束碼 2,dry-run 也會擋)、`music`(`{"path":…,"volume":0.25}`,說話時自動壓低,結尾淡出)。

**旁白模式**(repo 影片):

```json
{"mode":"narration","work":"../work/1","theme":{"bg":"<#RRGGBB>","bg2":"<#RRGGBB>","fg":"<#RRGGBB>","accent":"<#RRGGBB>","muted":"<#RRGGBB>"},
 "narration": <tts.sh 的輸出原樣貼上>,
 "scenes":[{"image":"../work/1/cards/001.png","sentences":[0]},
           {"video":"../work/1/rec-1.mp4","in":0,"sentences":[1,2]},
           {"video":"../work/1/app.mp4","in":3,"region":[250,40,745,830],"sentences":[3]}]}
```

- **置頂**:影片鏡頭(或它的 `region`)比 9:16 寬時,一律放大到寬 1080、放在字幕區上方(下緣 ≤ 1280),不受 `fit` 影響,不會被左右裁掉。放大後高 > 1240 → 結束碼 6:用 `region`(來源像素 `[x,y,w,h]`)框出旁白在講的區域,或拆成兩個鏡頭。每個鏡頭各自設 `region`,講到哪裡就框哪裡(例如講右側欄時,`region` 要包含右側欄)。

- 字幕時間是固定規則:第 1 句 0.3 秒開始,之後每句 start = 前一句 end + 0.25,end = start + 實測長度;片長 = 最後一句 end + 0.6。
- 鏡頭從它第一句的 start 開始(第一個鏡頭從 0),到下一個鏡頭開始為止。影片太短就停在最後一格。
- `sentences` 要依序涵蓋每一句各一次。

**原聲模式**(影片精華 / 精簡):

```json
{"mode":"original","work":"../work/1","source":"/path/talk.mp4","theme":{"bg":"<#RRGGBB>","bg2":"<#RRGGBB>","fg":"<#RRGGBB>","accent":"<#RRGGBB>","muted":"<#RRGGBB>"},
 "keep":[[62.4,98.1]],                      // 精華:保留區間;或
 "cut":<silence.sh 輸出或 [[s,e],…]>,         // 精簡:剪掉區間(每個剪點前後各留 0.1 秒)
 "segments":[{"start":62.4,"end":66.0,"text":"校正後的原話"},
             {"start":66.0,"end":71.2,"texts":["太長就拆","成兩句"],"texts2":["譯文1","譯文2"]}],
 "headline":"片頭 3 秒的標題疊字(選填)"}
```

- `segments` 用來源時間,compose 會扣掉剪掉的區間,重新對應到成品時間。
- `texts` 依字數比例切分 start–end。
- 沒有音軌時混入靜音,這種成品響度檢查不會過,要提供背景音樂。

**輸出**:`<out>/final.mp4`、`<out>/subtitles.srt`、`<work>/subtitles/*.png` + `boxes.json`、`<work>/first-frame.png`(封面用,沒有字幕)、`<work>/mix.wav`、`<work>/scenes.json`(每個鏡頭的成品起訖,給 `verify.sh --scenes`)。stdout 摘要含 `duration`、`scenes`(置頂鏡頭有 `uiBottom`)、`keep`、`cuts`、`totalCut`、`sourceDuration`、`actualDuration`。

**字幕版面**:最多 2 行,字級 64 px 起往下縮到 44 px;字幕框必須在 x∈[60,930]、y∈[1300,1620]。放不下時 compose 結束碼 4,把該句改成 `texts` 拆句(原聲),或把旁白拆成兩句重跑 tts。

## verify.sh 檢查項目

1080×1920、30 fps、h264 + yuv420p、aac 48000 Hz、faststart、長度 ≤ 60 秒;響度 −15 ~ −13 LUFS、true peak ≤ −1.0;5 張擷圖(0.1 秒、25%、50%、75%、末 1 秒)最暗的平均亮度 > 5;boxes.json 全在安全區(找不到算失敗);cover 1080×1920;`--scenes`(必填)的鏡頭從 0 首尾相接到片長,並在每個鏡頭中點與結尾前 0.2 秒各擷一張(`checks/scene-NN-mid.png`、`scene-NN-end.png`,列在 `sceneChecks`)。印一行 JSON,失敗時有 `failures`,結束碼 1。
