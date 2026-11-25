# github-hot-pastel

motion-video-kit 的第一個預設模板(1080×1440、30 fps、3:4)。資訊圖動畫型短片:米色底加淡色幾何圖形緩慢漂移、上緣橘色進度條、左上深紫膠囊標籤、右上吉祥物站在卡片上緣(輕微上下浮動、換姿勢時小彈跳)、兩行超大粗體標題(黑字 + 橘色重點字,逐字彈出)、中央白色深紫粗框卡片(內容依旁白彈出、有 overshoot 回彈)、底部逐詞字幕(關鍵詞是橘色膠囊白字)。

- 建立:2026-11-24,xhe motion-video-kit(PR feat/motion-video-kit)。
- 版型靈感:使用者提供的參考影片(資訊圖動畫型 GitHub 專案介紹短片)。**只沿用版面結構與節奏**(左上標籤、右上吉祥物、兩行大標、中央白色粗框卡片、底部逐詞字幕、米色底幾何圖形、黑字配橘色重點字、橘色膠囊關鍵詞、卡片內容依旁白逐步出現)。**不沿用**參考影片的角色、確切配色值、字型檔、截圖或圖示素材;配色值、版面尺寸、動畫曲線、圖示(SVG)都是本模板自己畫的。
- 字型:macOS 系統字型 PingFang TC(標題與字幕)、Menlo(終端機),不內嵌字型檔。
- 吉祥物 `assets/mascot/*.png`:使用者選定的 ComfyUI 生成原創機器人(戴耳機、拿放大鏡),來源 `videoclip/_brand/mascot-robot/`(2026-11-24 生成),7 個姿勢 base / happy / surprised / point / think / thumbs / search 原檔複製,沒有修改。
- 範例截圖 `sample/*.png`:kit 作者用 HTML 自己畫的虛構產品畫面(Lumen、example/pixelforge),Chrome 擷圖,只給 `render.mjs --sample` 預覽用;不是任何真實網站或服務。
- 授權:同 xhe repo。

## 場景類型

`title`(只有大標,吉祥物跳進卡片中央)、`image`、`compare`、`terminal`、`chips`、`checklist`、`grid`、`stat`、`cta`。欄位見 `../../storyboard.schema.json`,範例見 `sample.storyboard.json`,預覽見 `preview/contact.png`。

## 版面(px)

| 區塊 | 位置 |
|---|---|
| 進度條 | 上緣 0–12 |
| 標籤 | 左 40、上 38 |
| 大標安全區 `safe.headline` | [36,108,772,432],每行單行,116 → 72 px 自動縮字 |
| 吉祥物 | 左 772、上 180、290×290(腳踩卡片上緣) |
| 卡片 | 左 40、上 452、1000×728,框 8、圓角 46;內容區約 944×676 |
| 字幕安全區 `safe.subtitle` | [48,1196,1032,1424],最多 2 行,62 → 46 px 自動縮字 |

## 專案模板可以改的

`template.json` 的 `palette`(注入成同名 CSS 變數:bg、ink、frame、accent、accent2、card、muted、terminal、shapes)、`fonts`(只能系統字型)、`tag`、`mascot`、`size`(1080×1920 / 1080×1440 / 1080×1080,`safe` 與 `template.html` 的 `--card-*`、`--mascot-*` 要跟著改);`template.html` 的 CSS 變數與樣式。不能改 `MVK.build` / `MVK.seek` 介面與場景元件的資料格式。
