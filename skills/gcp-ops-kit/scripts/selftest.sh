#!/bin/bash
# kit 自我測試(只用假 gcloud / kubectl,不連雲端)。用法:selftest.sh [-v]
exec python3 -I "$(dirname "$(dirname "$(realpath "$0")")")/tests/selftest.py" "$@"
