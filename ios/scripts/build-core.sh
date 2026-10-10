#!/usr/bin/env bash
# Kizuna for iOS/iPadOS - builds Vendor/lib/libKizunaCore.a
# SPDX-License-Identifier: AGPL-3.0-only
#
# What it does (macOS + Xcode only):
#   1. clones chiaki-ng at the pinned commit into Vendor/src/chiaki-ng
#      (+ the submodules the library needs: nanopb, jerasure, gf-complete, curl)
#   2. applies scripts/patch_chiaki.py (deployment target, libevent -> select())
#   3. creates a Python venv with protobuf for the nanopb generator
#   4. configures ios/Core/CMakeLists.txt with CMake's native iOS support
#      (chiaki-lib + mbedTLS 2.28 + json-c + miniupnpc + curl/SecureTransport
#      + Opus + the Kizuna shim, all static, arm64, iOS 17.0)
#   5. merges every produced static archive into Vendor/lib/libKizunaCore.a
#   6. copies headers to Vendor/include
#
# Usage: ios/scripts/build-core.sh [--clean]
# Inspired by TP Play's ios/scripts/build-core.sh (AGPL-3.0).

set -euo pipefail

CHIAKI_REPO="https://github.com/chiaki-ng/chiaki-ng.git"
CHIAKI_TAG="v1.10.0"
CHIAKI_COMMIT="0c4a45df0cae2af2ba2daef84e881850b07038a3"
DEPLOYMENT_TARGET="17.0"

script_dir="$(cd "$(dirname "$0")" && pwd)"
ios_dir="$(dirname "$script_dir")"
vendor="$ios_dir/Vendor"
src="$vendor/src/chiaki-ng"
build="$vendor/build/iphoneos"
venv="$vendor/python"

if [ "${1:-}" = "--clean" ]; then
	echo "==> Cleaning $vendor/build, $vendor/lib, $vendor/include"
	rm -rf "$vendor/build" "$vendor/lib" "$vendor/include"
fi

need() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "error: '$1' is required. $2" >&2
		exit 1
	fi
}
need git "Install the Xcode command line tools."
need xcrun "Install Xcode."
need cmake "brew install cmake"
need ninja "brew install ninja"
need protoc "brew install protobuf"
need python3 "brew install python"

# Do not let the host leak into the cross build.
unset SDKROOT CFLAGS CXXFLAGS CPPFLAGS LDFLAGS ARCHS MACOSX_DEPLOYMENT_TARGET || true
export PKG_CONFIG_LIBDIR=/nonexistent
export PKG_CONFIG_PATH=
jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

echo "==> Xcode: $(xcodebuild -version | tr '\n' ' ')"
echo "==> iPhoneOS SDK: $(xcrun --sdk iphoneos --show-sdk-path)"

# --------------------------------------------------------------------------
# 1. chiaki-ng source
# --------------------------------------------------------------------------
mkdir -p "$vendor/src"
if [ ! -d "$src/.git" ]; then
	echo "==> Cloning chiaki-ng $CHIAKI_TAG"
	git -c advice.detachedHead=false clone --depth 1 --branch "$CHIAKI_TAG" "$CHIAKI_REPO" "$src"
fi
actual="$(git -C "$src" rev-parse HEAD)"
if [ "$actual" != "$CHIAKI_COMMIT" ]; then
	echo "==> Checking out pinned commit $CHIAKI_COMMIT (found $actual)"
	git -C "$src" fetch --depth 1 origin "$CHIAKI_COMMIT"
	git -C "$src" -c advice.detachedHead=false checkout --force "$CHIAKI_COMMIT"
fi

submodules="third-party/nanopb third-party/jerasure third-party/gf-complete third-party/curl"
echo "==> Submodules: $submodules"
# shellcheck disable=SC2086
if ! git -C "$src" submodule update --init --depth 1 $submodules; then
	echo "    shallow submodule fetch failed, retrying with full history"
	# shellcheck disable=SC2086
	git -C "$src" submodule update --init $submodules
fi

# --------------------------------------------------------------------------
# 2. Python venv (nanopb generator) + patches
# --------------------------------------------------------------------------
if [ ! -x "$venv/bin/python" ]; then
	echo "==> Creating Python venv"
	python3 -m venv "$venv"
fi
"$venv/bin/python" -m pip install --disable-pip-version-check --quiet --upgrade pip
# grpcio-tools ships a protoc that matches its protobuf runtime; nanopb's
# generator prefers it when present, which avoids gencode/runtime mismatches
# with Homebrew's protoc. Plain protobuf is the fallback.
if ! "$venv/bin/python" -c 'import grpc_tools, google.protobuf' >/dev/null 2>&1; then
	"$venv/bin/python" -m pip install --disable-pip-version-check --quiet grpcio-tools \
		|| "$venv/bin/python" -m pip install --disable-pip-version-check --quiet protobuf
fi
"$venv/bin/python" -c 'import google.protobuf as p; print("==> python protobuf", p.__version__)'

echo "==> Patching chiaki-ng"
"$venv/bin/python" "$script_dir/patch_chiaki.py" "$src"

# --------------------------------------------------------------------------
# 3. Configure + build
# --------------------------------------------------------------------------
echo "==> Configuring (CMake $(cmake --version | head -n1))"
cmake -S "$ios_dir/Core" -B "$build" -G Ninja \
	-DCMAKE_SYSTEM_NAME=iOS \
	-DCMAKE_OSX_SYSROOT=iphoneos \
	-DCMAKE_OSX_ARCHITECTURES=arm64 \
	-DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	-DKIZUNA_CHIAKI_DIR="$src" \
	-DPYTHON_EXECUTABLE="$venv/bin/python" \
	-DPython_EXECUTABLE="$venv/bin/python" \
	-DPython3_EXECUTABLE="$venv/bin/python" \
	-DPROTOC="$(command -v protoc)" \
	-DFETCHCONTENT_QUIET=OFF

echo "==> Building kizuna_core ($jobs jobs)"
cmake --build "$build" --target kizuna_core -j "$jobs"

# --------------------------------------------------------------------------
# 4. Merge archives
# --------------------------------------------------------------------------
mkdir -p "$vendor/lib" "$vendor/include"
archives=()
while IFS= read -r a; do
	archives+=("$a")
done < <(find "$build" -name '*.a' -not -path '*/CMakeFiles/*' | sort)

if [ "${#archives[@]}" -eq 0 ]; then
	echo "error: no static libraries were produced" >&2
	exit 1
fi
echo "==> Merging ${#archives[@]} archives:"
printf '    %s\n' "${archives[@]#$build/}"

for required in libkizuna_core.a libchiaki.a libopus.a; do
	found=0
	for a in "${archives[@]}"; do
		if [ "$(basename "$a")" = "$required" ]; then found=1; fi
	done
	if [ "$found" -ne 1 ]; then
		echo "error: $required was not built" >&2
		exit 1
	fi
done

rm -f "$vendor/lib/libKizunaCore.a"
xcrun libtool -static -no_warning_for_no_symbols -o "$vendor/lib/libKizunaCore.a" "${archives[@]}"

# --------------------------------------------------------------------------
# 5. Headers + sanity checks
# --------------------------------------------------------------------------
rm -rf "$vendor/include/chiaki"
cp "$ios_dir/Core/KizunaCore.h" "$vendor/include/KizunaCore.h"
cp -R "$src/lib/include/chiaki" "$vendor/include/chiaki"
config_h="$(find "$build" -path '*/lib/include/chiaki/config.h' | head -n1)"
if [ -n "$config_h" ]; then
	cp "$config_h" "$vendor/include/chiaki/config.h"
fi

# (nm output goes to a file first: with pipefail, `nm | grep -q` can fail on SIGPIPE)
symbols_file="$build/libKizunaCore.symbols.txt"
xcrun nm -gU "$vendor/lib/libKizunaCore.a" > "$symbols_file" 2>/dev/null || true
for symbol in _kz_session_create_lan _kz_regist_start_psn _chiaki_session_init _chiaki_holepunch_session_init _opus_decode _curl_easy_init _mbedtls_ecdh_compute_shared _json_tokener_parse_ex; do
	if ! grep -q " T $symbol\$" "$symbols_file"; then
		echo "error: $symbol missing from libKizunaCore.a" >&2
		exit 1
	fi
done
xcrun lipo -info "$vendor/lib/libKizunaCore.a"

cat > "$vendor/VERSION" <<EOF
chiaki-ng $CHIAKI_TAG $CHIAKI_COMMIT
built $(date -u +%Y-%m-%dT%H:%M:%SZ) for iphoneos arm64, deployment target $DEPLOYMENT_TARGET
EOF
echo "==> Done: $vendor/lib/libKizunaCore.a ($(du -h "$vendor/lib/libKizunaCore.a" | cut -f1))"
