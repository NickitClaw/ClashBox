#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
node ../../../scripts/generate-rpc.cjs --check
# Source: https://gitcode.com/openharmony-sig/ohos_golang_go
GO_BIN="${OHOS_GO:-${HOME}/.local/share/harmonyos7/native-toolchain/go-ohos/bin/go}"
OHOS_NATIVE_HOME="${OHOS_NATIVE_HOME:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native}"
ARCH="${1:-arm64}"
case "$ARCH" in
  arm64) target=aarch64; outdir=arm64-v8a ;;
  amd64) target=x86_64; outdir=x86_64 ;;
  *) echo 'Usage: build.sh [arm64|amd64]' >&2; exit 1 ;;
esac
test -x "$GO_BIN" || { echo 'Set OHOS_GO to the OpenHarmony Go executable' >&2; exit 1; }
test -f core/go.mod || { echo 'Initialize the pinned Go core submodule first' >&2; exit 1; }
export CC="$OHOS_NATIVE_HOME/llvm/bin/clang"
export CXX="$OHOS_NATIVE_HOME/llvm/bin/clang++"
export CGO_CFLAGS="--target=$target-linux-ohos --sysroot=$OHOS_NATIVE_HOME/sysroot"
export CGO_CXXFLAGS="$CGO_CFLAGS"
export CGO_LDFLAGS="$CGO_CFLAGS -Wl,-z,lazy"
export GOOS=openharmony GOARCH="$ARCH" CGO_ENABLED=1 GOTOOLCHAIN=local
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
node corepatches/overlay.cjs "$work"
revision="$(git -C core rev-parse --short=12 HEAD)"
"$GO_BIN" build -overlay="$work/core-overlay.json" -trimpath -buildmode=c-shared -tags 'ohos with_gvisor' \
  -ldflags "-s -w -checklinkname=0 -X github.com/metacubex/mihomo/constant.Version=ClashBox-$revision" \
  -o "$work/libflclash.so" .
mkdir -p "../../libs/$outdir"
# Failed builds never copy a stale library.
cp "$work/libflclash.so" "../../libs/$outdir/libflclash.so"
node ../../../scripts/native-provenance.cjs --write "$outdir" "$GO_BIN"
echo "Built ../../libs/$outdir/libflclash.so (core $revision)"
