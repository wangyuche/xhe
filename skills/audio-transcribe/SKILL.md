---
name: audio-transcribe
description: 錄音／影片轉中文逐字稿（whisper.cpp + Apple GPU）。固定三步：ffmpeg 轉 16kHz wav → whisper-cli 轉錄（防重複參數）→ 清掉幻覺與重複。使用者給法說會、會議、Podcast 錄音或影片並說「轉文字」「整理重點」「這段錄音在講什麼」時使用；tw-stock-analyst 要用法說會錄音時，主 agent 先用這個轉成文字再交給它。
---

# audio-transcribe

2026-11-18 第一次處理旭隼法說會錄音（61 分鐘）時踩到的坑都寫在這裡。**照三步做，不要省略參數。**

## 前置

- whisper.cpp：`brew install whisper-cpp`（指令 `/opt/homebrew/bin/whisper-cli`）
- 模型：`ggml-large-v3-turbo.bin`（1.6GB，中文好、速度快）。路徑是本機環境設定，不寫在 repo：優先序 環境變數 `WHISPER_MODEL` > `~/.config/audio-transcribe/config` 的 `WHISPER_MODEL=` > 預設 `~/.cache/whisper/ggml-large-v3-turbo.bin`。設定檔的值寫絕對路徑，或 `~/`、`$HOME/` 開頭（不執行 shell 展開）。

  ```bash
  mkdir -p ~/.cache/whisper && curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
  # 模型放在別處時:
  mkdir -p ~/.config/audio-transcribe && echo 'WHISPER_MODEL=<模型路徑>' > ~/.config/audio-transcribe/config
  ```
- ffmpeg

## 步驟

### 1. 轉成 16kHz 單聲道 wav

```bash
bash ~/.claude/skills/audio-transcribe/scripts/prep.sh <輸入音檔或影片> <輸出.wav>
```

印出長度（分鐘）。m4a、mp3、mp4、mov 都可以。

### 2. 轉錄（要單獨一行執行）

先查模型路徑（印出絕對路徑；結束碼不是 0 就停下來，把 stderr 告訴使用者：3 = 找不到模型（附下載方式）、2 = 路徑含單引號或不是絕對路徑）：

```bash
bash ~/.claude/skills/audio-transcribe/scripts/model.sh
```

把印出的路徑**直接寫進**下面的 `-m`，用單引號包住（路徑可能有空白；不要用 `$(...)` 或變數，否則不是單獨一行的 whisper-cli，會進沙盒）：

```bash
/opt/homebrew/bin/whisper-cli -np -mc 0 -m '<model.sh 印出的路徑>' -l zh --prompt 以下是繁體中文的<公司名>法說會內容。 -otxt -of <輸出路徑不含副檔名> -f <步驟1的.wav>
```

- **`-mc 0` 一定要加**：沒加時上下文會一直帶到下一段，Q&A、雜音或冷場的地方容易卡在同一句。實例：同一句重複 743 次、161 次，整段問答消失。
- **`--prompt`**：寫語言（繁體中文）和主題（公司名、法說會），能改善專有名詞和繁簡。
- **`-otxt -of`**：直接寫成檔案，不要接管線。
- **沙盒**：`whisper-cli` 在沙盒 `excludedCommands` 裡，**只有單獨一行執行才會被排除**，才能用 GPU（Metal）。包在腳本裡、接 `|`、前面加 `cd` 都會變回沙盒內執行，Metal 會失敗（`failed to allocate Metal buffer`）。真的不能用 GPU 時，加 `-ng` 改用 CPU（慢很多）。
- 速度參考：M 系列 GPU，61 分鐘錄音幾分鐘內完成。長檔建議用背景執行。

### 3. 清理

```bash
python3 -I ~/.claude/skills/audio-transcribe/scripts/clean.py <步驟2的.txt> <清理後.txt>
```

刪掉只有填充字的行（對、嗯、謝謝…）、連續重複的行、whisper 常見幻覺句（整行都是頻道宣傳，例如「請不吝點贊 訂閱…」「字幕由…提供」、一句短句裡同時有按讚和訂閱；只提到「訂閱」「轉發」的正常內容，例如「訂閱制營收年增 30%」，會保留），單字重複（法法法法…）壓成 3 個。印出統計；`LOOP` 表示某句重複很多次，`WARN` 表示可能有段落沒辨識出來。

清完刪掉步驟 1 的 wav（只是中間產物，61 分鐘約 117MB）。

## 整理成摘要時

- **數字很容易聽錯**：「EPS 7.7 億元」、「營益率 11 元」這類單位錯亂很常見。摘要開頭寫「財報數字以公司公告為準」，聽不清楚的標「?」。能拿到公司公告或簡報時，用公告數字核對。
- **用兩個數字互相驗算**：例如淨利 ÷ 營收應該等於淨利率；對不上就標出來，不要硬寫。
- 不要用 `sort | uniq -c` 統計中文行重複：macOS 在中文語系下會把不同的行排在一起，數字不準。用 `clean.py` 的統計。

## 測試

```bash
python3 -I tests/test_audio_transcribe.py
```

測 `prep.sh` 轉檔、`model.sh` 模型路徑與 `clean.py` 清理（合成資料，不含任何真實錄音內容）。whisper 本身需要模型與真實語音，不在測試內。
