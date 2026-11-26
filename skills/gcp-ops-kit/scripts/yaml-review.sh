#!/bin/bash
# k8s YAML 審查(不需 GCP)。用法:yaml-review.sh <檔案或目錄>... [--label <名稱>]
exec python3 -I "$(dirname "$(realpath "$0")")/yaml_review.py" "$@"
