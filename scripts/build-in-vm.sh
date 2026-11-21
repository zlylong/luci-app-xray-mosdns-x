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
mkdir -p package/luci-app-xray-mosdns-x
tar -C "$REPO_DIR" --exclude=.git --exclude=out -cf - . | tar -C package/luci-app-xray-mosdns-x -xf -

# First run: prepare feeds + .config. Later runs reuse the warm SDK (fast).
if [ ! -f .config ] || [ "${CI_FORCE_FEEDS:-0}" = "1" ]; then
	./scripts/feeds update -a >/dev/null
	./scripts/feeds install -a >/dev/null
	TERM=dumb make defconfig >/dev/null
	# the SDK ships CONFIG_ALL=y which makes every package/kmod rebuild on each run
	sed -i -e 's/^CONFIG_ALL=y/# CONFIG_ALL is not set/' \
		-e 's/^CONFIG_ALL_KMODS=y/# CONFIG_ALL_KMODS is not set/' \
		-e 's/^CONFIG_ALL_NONSHARED=y/# CONFIG_ALL_NONSHARED is not set/' .config
	TERM=dumb make oldconfig >/dev/null
fi
TERM=dumb make package/luci-app-xray-mosdns-x/compile V=s -j"$(nproc)"

mkdir -p "$REPO_DIR/out"
rm -f "$REPO_DIR"/out/*.apk
f=$(ls -t $(find bin -type f -name 'luci-app-xray-mosdns-x-*.apk' 2>/dev/null) 2>/dev/null | head -1)
[ -n "$f" ] && [ -f "$f" ] && cp -v "$f" "$REPO_DIR/out/"
ls -la "$REPO_DIR/out"
# a build that produced nothing is a failed build
ls "$REPO_DIR"/out/luci-app-xray-mosdns-x-*.apk >/dev/null 2>&1 || { echo "no package was built" >&2; exit 1; }
