#!/bin/bash
# 印出 whisper 模型檔路徑(本機環境設定,不進 git)。
# 優先序:環境變數 WHISPER_MODEL > ~/.config/audio-transcribe/config 的 WHISPER_MODEL= > ~/.cache/whisper/ggml-large-v3-turbo.bin
# 找不到檔案時結束碼 3,stderr 印設定與下載方式。
CONF="$HOME/.config/audio-transcribe/config"
DEFAULT="$HOME/.cache/whisper/ggml-large-v3-turbo.bin"
M="$WHISPER_MODEL"; SRC="環境變數 WHISPER_MODEL"
if [ -z "$M" ] && [ -f "$CONF" ]; then
  # 只取 WHISPER_MODEL=(可有 export、引號、行尾註解),不 source 設定檔
  M=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?WHISPER_MODEL=//p' "$CONF" | tail -1 \
      | sed -E 's/[[:space:]]+#.*$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')
  case "$M" in "~/"*) M="$HOME/${M#\~/}" ;; esac
  SRC="$CONF"
fi
[ -n "$M" ] || { M="$DEFAULT"; SRC="預設路徑"; }
if [ ! -f "$M" ]; then
  {
    echo "找不到 whisper 模型:$M(來源:$SRC)"
    echo "下載:mkdir -p ~/.cache/whisper && curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
    echo "或指定已有的檔案:mkdir -p ~/.config/audio-transcribe && echo 'WHISPER_MODEL=<模型路徑>' > ~/.config/audio-transcribe/config"
  } >&2
  exit 3
fi
echo "$M"
