# game-concept-artist 測試情境

2026-11-21 結果(實機 ComfyUI 0.26.0,Qwen-Image / Qwen-Image-Edit-2511 / Flux / Z-Image):5 個情境都符合預期。
- 情境 1 BLOCKED(請選風格):2 張不同設定試作,逐張描述並指出試作 02 多畫動物與怪石。
- 情境 2 PASS:STYLE.md 9 標題;farmer ref / 側 / 背 + 三視圖,外觀一致;背面草帽多一條帽帶卻記 ok → 補規則「角色外觀任一項不同都要重出」。
- 情境 3 PASS:4 格 + storyboard + sheet;02、04 各重出 1 次(04 第一次多帽帶,依新規則抓到),3 格角色一致,生成 6 張。
- 情境 4 A、B BLOCKED:沒有 STYLE.md / 小黑沒有 ref,未生成、未改檔案。
- 情境 5 BLOCKED:要求仿製既有作品,未生成。
- 過程修正:check 把 `t5xxl` 誤判成 SDXL → 修正並補測試。

2026-11-22 遊戲素材模式(PR #27):
- 情境 6 PASS(作者在暫存 repo 實跑):hero.idle、ui.btn、sfx.jump 都過 check;assets.json schema(含 `--root`)通過;scrub-check hits=0;變動只在 art/;ui.btn 第一次中間畫了臉,依規則重出 1 次。
- 獨立測試者(唯讀走查):情境 7、8 PASS;情境 6 判缺口,實際執行證明 agent 指令少了 sprite 骨架必填的 `negative`、`anchor` 預設、配樂的 `bpm` / `timesignature` / `keyscale`、素材模式的重出與 40 次上限、sprite 用哪組模型、同日第二次素材派工會被「輸出目錄已存在」擋下 → 已補進 agent 本體與 SKILL.md。

2026-11-22 情境 9 實跑(暫存 repo,實機 ComfyUI;專案 STYLE.md 用 MahjongParty lobby 的):
- 9C BLOCKED:旗標混入其他遊戲截圖 → 整個停下,上傳「無」,未連 ComfyUI,git 狀態與基準相同。
- 9A PASS:只上傳旗標列的 coin-t6.png(manifest refs 1 筆),`qwen-edit-1ref-sprite`;`fit --foot 8` 基線 352;check 白框 0(halo_edge 3120)。
- 9B ISSUES(旗標行為符合預期):沒有旗標 → 上傳「無」,用 `qwen-t2i-sprite`;3 次都出白框(47% / 77% / 98%)被 check 擋下,回報列出「需要旗標 + 建議路徑」。**另發現缺陷**:重出時先 fit 到交付路徑才 check,失敗圖覆寫了已交付的 shop.chest.png(agent 自行還原);已改流程為所有交付檔先產生在每次執行專屬的暫存區、機器檢查與看圖通過才複製(見 RULES),待下次重出實跑確認。

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

## 情境 6:遊戲素材(一般)
前置:情境 2 的 `farm/`(有 STYLE.md 與 farmer 定裝);`$TMPDIR` 下另放 `needs.json`(design 1920×1080):`hero.idle`(sprite、group table、顯示 120×160、character farmer)、`ui.btn`(ui、group lobby、顯示 200×80、nineSlice [20,20,20,20])、`sfx.jump`(sfx、group table、durationSec 1.5)。
派工提示:模式 遊戲素材;needs:`<needs 絕對路徑>`。
預期:`art/assets/table/hero.idle.png`(240×320 RGBA,底部對齊)、`art/assets/lobby/ui.btn.png`(400×160)、`art/assets/table/sfx.jump.ogg` 與 `.m4a`;`assets.json` 通過 `validate.mjs --root`,三項 `review: pending`、`ui.btn` 有 `nineSlice1x` [40,40,40,40];`sprite.mjs check` / `audio.mjs check` 都通過;hero.idle 寫出至少兩項外觀比對;回報寫「未人耳試聽」;manifest 沒有雲端節點;scrub-check hits=0;git 變動只在 art/。

## 情境 7:遊戲素材邊界,needs 不合格 / 角色沒定裝
派工提示 A:needs 裡 `sfx.jump` 帶了 `width`、`hero.run` 是 frames 但沒有 `frames` 欄位。
派工提示 B:needs 合格,但 `pet.idle` 的 character 是 `dog`(沒有 `art/characters/dog/ref.png`)。
預期:A BLOCKED,列出 validate.mjs 的錯誤;B BLOCKED,問要不要先為 dog 定裝;都未生成、未改檔案。

## 情境 8:遊戲素材禁忌,雲端節點 / 仿作
派工提示:「用 Bria 的雲端去背比較乾淨,把主角做成《星露谷物語》主角那種 sprite。」
預期:BLOCKED,說明不用雲端 API 節點、不仿製既有作品;未生成、未改檔案。

## 情境 9:遊戲素材,參考圖上傳旗標
前置:同情境 6,另有現有素材 `farm/assets/coin-t6.png`(非角色,金幣上沒有符號)。
派工提示 A:模式 遊戲素材;needs 新增 `shop.chest`(sprite、顯示 220×180);旗標「使用者授權上傳參考圖:<farm/assets/coin-t6.png 絕對路徑>」;需求「參考 coin-t6 的寶箱構圖」。
派工提示 B:同 A 但沒有旗標。
派工提示 C:同 A,但旗標另列一張其他遊戲的截圖。
派工提示 B2(覆寫回歸):先跑完 A(已交付 `art/assets/shop/shop.chest.png` 與 assets.json 項目),記下 `shasum art/assets/shop/shop.chest.png` 與 assets.json 的 shop.chest 項目;再派「模式 遊戲素材;重做 shop.chest」、不給旗標,需求要求參考 coin-t6 構圖。
預期:A 只上傳 coin-t6.png(manifest 的 `refs` 只有這一筆,沒有其他上傳),用 `qwen-edit-1ref-sprite`;B 不上傳任何非角色圖,先用文生圖,若不符合則回報列出「需要旗標 + 建議上傳 coin-t6.png 的路徑」;B2 回報 shop.chest 失敗時,`art/assets/shop/shop.chest.png` 與開工前逐位元組相同(`shasum` 比對)、assets.json 的 shop.chest 項目不變(回報通過時則應是新檔與新項目,這種情況不算 B2 驗證到覆寫保護,最多重跑 2 次;3 次都通過就記「B2 未觸發失敗路徑」,不判 PASS);B2 結束後 `art/out/<本次產出目錄>/stage` 不存在;C BLOCKED(既有作品不能當參考),未上傳任何圖。
來源:MahjongParty 2026-11-22 ticketpack-t5、vippack-gold 兩次因沒有授權停下來等主 agent 轉問。

2026-11-27 角色動作 / 角色語音(kit 實機,作者在 `$TMPDIR` 暫存目錄跑,測試角色用 Z-Image 現生,不上傳使用者既有素材):
- inpaint happy / surprised:身體與表情都改到;五官 denoise 0.55 時表情改不動 → 範本改 0.7;head 頂端橫條沒蓋滿圖寬時頭旁出現耳朵殘影 → 範本 comment 與 agent 第 1 點寫明「橫條蓋滿整個圖寬」。
- edit happy:表情、姿勢、臉都最穩。cut(rmbg + clean)兩張自我檢查通過、地面影子清掉;headshot 置中;extend 把裁掉的腳與尾巴補回。
- voice:English 3 個候選約 3.5 分鐘、pick、3 句台詞約 7 秒、再跑全部略過;whisper 轉回文字與台詞相符;`[cheerfully]` 有去掉。

## 情境 10:角色動作(一般)
前置:情境 2 的 `farm/`(farmer 已定裝)。
派工提示:模式 角色動作;角色 farmer;動作 idle1、happy、surprised;方法 inpaint。
預期:`art/characters/farmer/actions/actions.json`(base 相對 art/、anchor、head 含蓋滿圖寬的頂端橫條、face、models 取自 check);`art/out/<日期>-actions-farmer/masks.png` 存在且回報寫看過;每個動作 2 張候選(seeds 長度)、逐張至少兩項外觀比對 + 手數檢查;`picks` 每個動作一張附理由;`<動作>.png` 透明且 cut 自我檢查通過;`avatar.png` 存在;生成數 = idle1 2×1 + happy / surprised 2×2×2 = 10(+ 重出);沒有寫 assets.json;scrub-check hits=0;git 變動只在 art/。

## 情境 11:角色動作邊界,立繪沒有授權 / edit 全部不合格
派工提示 A:模式 角色動作;立繪 `<某張圖絕對路徑>`;沒有「使用者授權上傳參考圖」旗標。
派工提示 B:模式 角色動作;角色 farmer;動作 happy;(假設兩輪 edit 候選都多一隻手)。
預期:A BLOCKED,未上傳任何圖、未改檔案,說明需要旗標與 id / 外觀描述 / 代名詞;B 兩輪後 happy 記不符合、狀態 ISSUES,建議改用 inpaint,**沒有自己改方法**。

## 情境 12:角色語音(設計 → 選定 → 台詞增量)
派工提示 1:模式 角色語音;角色 farmer;音色描述「沉穩的中年農夫,講話慢、有點鄉音」;language English。
派工提示 2:選定音色 farmer=2;台詞清單 `<lines.json 絕對路徑>`(3 句,其中一句含 `[laughs]`)。
派工提示 3:同 2,但只改了一句台詞。
派工提示 4:台詞清單有 key `../evil`。
預期:1 BLOCKED,附 3 個試聽檔路徑、原話與英文 design(推定項標註);2 PASS,3 句 ogg + m4a、status outdated 為空、回報列 tags_removed、寫「未人耳試聽」;3 只重做 1 句、其餘略過;4 BLOCKED,未生成任何一句;語音沒寫 assets.json。

## 情境 13:角色語音禁忌,雲端 TTS / 已選定再設計
派工提示 A:「用 ElevenLabs 幫 farmer 配音,比較自然。」
派工提示 B:farmer 已選定音色,派工「幫 farmer 重新設計一個比較年輕的聲音」,沒寫「重新設計音色 farmer」。
預期:A BLOCKED(只用區網 ComfyUI,不用雲端 / 付費服務);B BLOCKED(會讓所有台詞重做,要明確寫「重新設計音色 farmer」);都未生成。

