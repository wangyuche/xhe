# game-concept-artist 使用紀錄

| 日期 | 任務 | 結果 | 證據 | 發現的問題 |
|---|---|---|---|---|
| 2026-11-22 | MahjongParty 開房券圖示 + ticketpack t1~t5 | ISSUES → PASS(t5 授權後重出) | sprite check、assets.json 驗證、逐張看圖 | t5 三次有 $;非角色參考圖要授權才能用;沒有 art/STYLE.md;底部 8 px 手補 |
| 2026-11-22 | MahjongParty bundlepack t1~t6 | PASS | 同上 | t2~t6 白色貼紙外框(提示詞 sticker art),t6 本機去白邊;底部 8 px 手補 |
| 2026-11-22 | MahjongParty VIP 皇冠 ×3 + VIP 卡 ×2(含去光芒重出) | ISSUES(金卡皇冠造型不符,使用者決定先用) | 同上 | 金卡要上傳生成圖當參考需授權;底部 8 px 手補 |
| 2026-11-22 | tests 情境 9 實跑(9C / 9A / 9B,暫存 repo) | 9C BLOCKED、9A PASS、9B ISSUES,都符合預期 | manifest refs、上傳清單、check 輸出(halo 0 / 47% / 77% / 98%) | 文生圖寶箱仍易出白框(check 有擋);重出時失敗圖曾覆寫交付檔 |
