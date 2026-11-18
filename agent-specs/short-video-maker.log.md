# short-video-maker 使用紀錄

| 日期 | 任務 | 結果 | 證據 | 發現的問題 |
|---|---|---|---|---|
| 2026-11-18 | craft-anything repo → repo-cards(沒有執行旗標) | PASS | `verify.sh ok:true`(40.27 秒、−14 LUFS);5 張擷圖已描述;亮點路徑 `ls` 都存在(commit 9db8830) | 旁白把 MIT / Apache-2.0 雙授權講成「MIT 授權」;沒提 early alpha(agent 自己列在已知限制) |
| 2026-11-18 | 同上，第二版：主 agent 在 Docker 沙盒錄好桌面 App 畫面(1000×1400)交給 agent 剪 | PASS → 使用者退件 | `verify.sh ok:true`(51.6 秒);用整支 `fit: crop` 放大 | 使用者:「Reel 是直立式、網站是橫式，講功能時很多地方都被截斷」。右側欄、函式名稱被切;字幕蓋住 Add a brain 卡片。agent 看到裁切，寫在已知限制仍回 PASS;25/50/75% 擷圖沒涵蓋每個鏡頭。主 agent 派工寫「畫面可放大裁切」也是原因之一 |
| 2026-11-18 | 同上，第三版：逐鏡頭裁切 | BLOCKED → PASS | 第一次:kit 只有整支共用的 `fit`,agent 不能自己跑 ffmpeg → BLOCKED;主 agent 手動做好 8 個置頂片段後重派:`verify.sh ok:true`(54.8 秒),每個鏡頭中點與結尾都已檢查 | kit 缺逐鏡頭放大。已改：compose `region` + 置頂(結束碼 6)、verify `--scenes` 逐鏡頭擷圖;用第二版的真實設定重跑 → 結束碼 6 被擋 |
