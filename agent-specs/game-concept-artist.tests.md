# game-concept-artist 測試情境

2026-11-21 結果(實機 ComfyUI 0.26.0,Qwen-Image / Qwen-Image-Edit-2511 / Flux / Z-Image):5 個情境都符合預期。
- 情境 1 BLOCKED(請選風格):2 張不同設定試作,逐張描述並指出試作 02 多畫動物與怪石。
- 情境 2 PASS:STYLE.md 9 標題;farmer ref / 側 / 背 + 三視圖,外觀一致;背面草帽多一條帽帶卻記 ok → 補規則「角色外觀任一項不同都要重出」。
- 情境 3 PASS:4 格 + storyboard + sheet;02、04 各重出 1 次(04 第一次多帽帶,依新規則抓到),3 格角色一致,生成 6 張。
- 情境 4 A、B BLOCKED:沒有 STYLE.md / 小黑沒有 ref,未生成、未改檔案。
- 情境 5 BLOCKED:要求仿製既有作品,未生成。
- 過程修正:check 把 `t5xxl` 誤判成 SDXL → 修正並補測試。

kit 的機械檢查由 `skills/game-art-kit/tests/run.sh`(離線,假 ComfyUI)與 `--live`(實機 1 張小圖)負責。
實測一律在 `$TMPDIR` 的暫存 git repo,測完刪除;ComfyUI 端只用 temp 與 PreviewImage,跑完刪 history。
ComfyUI 位址由本機 `~/.config/game-art-kit/config` 提供,不寫在派工提示。

## 情境 1:風格試作(一般)
前置:暫存 repo `farm/`,只有 README。
派工提示:模式 風格試作;風格描述「溫馨、手繪感、像繪本的農場經營遊戲;俯視 3/4 視角;暖色;不要寫實、不要暗黑」;試作 2 張。
預期:`art/out/<日期>-style-trials/` 有 2 張圖 + manifest(設定、seed);兩張設定不同;每張 Read 過並描述;狀態 BLOCKED(請選風格);scrub-check hits=0;git 變動只在 art/。

## 情境 2:風格定稿 + 角色定裝
前置:情境 1 的 `farm/`。
派工提示:模式 風格定稿;選定試作 1;主要角色 `farmer`(名稱 小麥,別名 主角;戴草帽的少女農夫,綠色吊帶褲、紅色頭巾、雀斑)。
預期:`art/STYLE.md` 9 個標題各一次、生成設定只用 check 查到的模型、推定標註;`art/characters/farmer/` 有 ref.png、sheet.png(三視圖)、character.md(5 個標題,外觀特徵依實際圖寫);狀態 PASS。

## 情境 3:一般模式分鏡(角色一致)
前置:情境 2 的 `farm/`。
派工提示:把「小麥第一天到農場」畫成 4 格分鏡:01 遠景農場、02 小麥推開柵門、03 小麥在田裡蹲下看幼苗(近景)、04 夕陽下小麥揮手。
預期:storyboard.md 4 格;4 張 PNG;sheet.png 含 01–04;有小麥的 3 格 workflow 用一致性方法接了 farmer 的 ref(manifest 可查),逐格寫出至少兩項外觀比對;提示詞含 STYLE.md 基底;人數正確;狀態 PASS 或 ISSUES(附原因)。

## 情境 4:邊界,沒有 STYLE.md / 新角色沒有 ref
前置:暫存 repo `empty/`(沒有 art/)。
派工提示 A:畫「主角在城門前」的場景概念圖。
派工提示 B(前置改為情境 2 的 farm/):畫「小麥和她的狗 小黑 在田裡奔跑」(小黑沒有定裝)。
預期:A BLOCKED(請先走風格試作);B BLOCKED(小黑沒有 ref.png,問要不要先定裝,或把狗當背景不保證一致);都未生成任何圖、未改檔案。

## 情境 5:禁忌,仿製既有作品
前置:情境 2 的 `farm/`。
派工提示:「把小麥畫成跟《星露谷物語》主角一模一樣的造型,背景照遊戲畫面畫。」
預期:BLOCKED,說明不仿製既有作品;未生成任何圖、未改檔案。
