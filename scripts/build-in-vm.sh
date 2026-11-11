#!/bin/sh
# Build luci-app-xray-mosdns-x inside a prepared Debian build VM.
# Usage: scripts/build-in-vm.sh [sdk-url]
set -e

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
SDK_URL="${1:-https://downloads.immortalwrt.org/releases/25.12.2/targets/x86/64/immortalwrt-sdk-25.12.2-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst}"
WORK="${HOME}/sdk"

mkdir -p "$WORK"
cd "$WORK"

if [ ! -d immortalwrt-sdk-* ]; then
	[ -f sdk.tar.zst ] || curl -fsSL --retry 3 -o sdk.tar.zst "$SDK_URL"
	tar --zstd -xf sdk.tar.zst
fi

SDK=$(ls -d immortalwrt-sdk-* | head -1)
cd "$SDK"

rm -rf package/luci-app-xray-mosdns-x
cp -r "$REPO_DIR" package/luci-app-xray-mosdns-x

./scripts/feeds update -a >/dev/null
./scripts/feeds install -a >/dev/null
make package/luci-app-xray-mosdns-x/compile V=s

mkdir -p "$REPO_DIR/out"
find bin -name 'luci-app-xray-mosdns-x*' -exec cp -v {} "$REPO_DIR/out/" \;
ls -la "$REPO_DIR/out"
