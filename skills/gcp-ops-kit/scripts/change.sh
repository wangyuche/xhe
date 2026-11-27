#!/bin/bash
# 執行使用者逐條核准的變更。用法:change.sh <plan.json> --sha <sha256> --approved "使用者已核准變更 C1, C3"
exec python3 -I "$(dirname "$(realpath "$0")")/change.py" "$@"
