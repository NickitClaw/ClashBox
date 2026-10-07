#!/usr/bin/env bash
# Requires initialized submodules, DevEco/API 26, devecocli, OHOS Go, host Go and ohpm dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v devecocli >/dev/null
command -v python3 >/dev/null
npm ci --ignore-scripts --no-audit --no-fund
bash proxy_core/src/flclash/build.sh arm64
npm run check
devecocli build clean
devecocli build --modules entry --build-mode debug
python3 scripts/verify-hap.py entry/build/default/outputs/default/entry-default-unsigned.hap
