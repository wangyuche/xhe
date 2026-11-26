#!/bin/bash
# 唯讀盤點 + 規則 + 報告。用法見 collect.py。
exec python3 -I "$(dirname "$(realpath "$0")")/collect.py" "$@"
