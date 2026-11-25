# short-video-maker 使用紀錄

| 日期 | 任務 | 結果 | 證據 | 發現的問題 |
|---|---|---|---|---|
| 2026-11-18 | craft-anything repo → repo-cards(沒有執行旗標) | PASS | `verify.sh ok:true`(40.27 秒、−14 LUFS);5 張擷圖已描述;亮點路徑 `ls` 都存在(commit 9db8830) | 旁白把 MIT / Apache-2.0 雙授權講成「MIT 授權」;沒提 early alpha(agent 自己列在已知限制) |
| 2026-11-18 | 同上，第二版：主 agent 在 Docker 沙盒錄好桌面 App 畫面(1000×1400)交給 agent 剪 | PASS → 使用者退件 | `verify.sh ok:true`(51.6 秒);用整支 `fit: crop` 放大 | 使用者:「Reel 是直立式、網站是橫式，講功能時很多地方都被截斷」。右側欄、函式名稱被切;字幕蓋住 Add a brain 卡片。agent 看到裁切，寫在已知限制仍回 PASS;25/50/75% 擷圖沒涵蓋每個鏡頭。主 agent 派工寫「畫面可放大裁切」也是原因之一 |
| 2026-11-18 | 同上，第三版：逐鏡頭裁切 | BLOCKED → PASS | 第一次:kit 只有整支共用的 `fit`,agent 不能自己跑 ffmpeg → BLOCKED;主 agent 手動做好 8 個置頂片段後重派:`verify.sh ok:true`(54.8 秒),每個鏡頭中點與結尾都已檢查 | kit 缺逐鏡頭放大。已改：compose `region` + 置頂(結束碼 6)、verify `--scenes` 逐鏡頭擷圖;用第二版的真實設定重跑 → 結束碼 6 被擋 |
| 2026-11-24 | 新增 ComfyUI(topic 模式、AI 插圖 / 動態鏡頭 / 配樂 / 音效)後實測情境 8–12 | 8 ISSUES(行為正確)、9–12 PASS | 見 tests.md「結果(2026-11-24)」 | 兩次超出 Bash 白名單讀輸出(已改白名單);frames.sh 重出影格混入(已修);在地食物畫錯(已知限制) |
| 2026-11-24 | 使用者評 ComfyUI 重做版(astryx/2、craft-anything/4)「做得很爛」:下方 1/3 空白、UI 字太小、AI 只在結尾且同圖用 3 次、佔位框、say 機械 | 使用者退件 | 主 agent 攤開縮圖確認 | 起因:kit 只能置頂 + 純色底;AI 鏡頭沒有穿插規則。改做 template 模式 + motion-video-kit |
| 2026-11-24 | template 模式實測:craft-anything repo → `20261118-craft-anything/5/`(github-hot-pastel、Qwen3 台灣女聲) | ISSUES(主 agent 複核後視為可交付) | `verify.sh --size 1080x1440 ok:true`(57.7 秒、−14 LUFS);rhythm ok(maxEmpty 0.08、間隔 2.37–3.39 秒);19 場景、6 種卡片;主 agent 看過每 3 秒一格總表與換場逐格 | agent 判 ISSUES 的原因是片頭 0.1 秒卡片空白(進場動畫,0.1–0.8 秒),主 agent 判為正常進場不算缺陷。超出白名單 3 次(python3 改 storyboard、node -e 讀 JSON 兩次);第三次發生同類錯誤,待改成結構(提供讀 JSON 欄位的 kit 指令)。tester 角色未另外派出,以實跑代替 |
| 2026-11-25 | 使用者試聽 craft-anything/5:第 6 句「網站」念錯 | 使用者退件(單句) | whisper:第 5 版該句「例如一個獎斬」;第 6 版(say「網 站」)「例如一個網站」;其他 20 句與第 5 版逐位元相同(同 seed 可重現) | 主 agent 重做為 `20261118-craft-anything/6/`(verify ok,57.8 秒)。新增 kit 念法對照表 + `asr.mjs`。另:主 agent 先前把第 5 版 work/ 當測試檔刪掉,導致改一句要重 clone、重擷格、重生配樂(主 agent 記憶已更正;agent 本身照規格結束時刪 work/,待討論是否改成使用者確認後才刪) |
