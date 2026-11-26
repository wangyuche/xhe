#!/bin/bash
# 環境檢查。用法:check.sh yaml | check.sh review|plan|change <專案>
exec python3 -I "$(dirname "$(realpath "$0")")/check.py" "$@"
