#!/usr/bin/env bash
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/../.." && pwd)"

BUILD_DIR="${BUILD_DIR:-$TOOLS_DIR/libfuzzer-build}"
DEPS_ROOT="${LIBFUZZER_DEPS_ROOT:-$TOOLS_DIR/deps/arm64-libfuzzer}"
if [[ -n "${LIBFUZZER_DEPS_PREFIX:-}" \
    && "${LIBFUZZER_DEPS_PREFIX:-}" != "$DEPS_ROOT/prefix" ]]; then
    echo "LIBFUZZER_DEPS_PREFIX must be the prefix child of LIBFUZZER_DEPS_ROOT" >&2
    exit 1
fi
DEPS_PREFIX="$DEPS_ROOT/prefix"
BOOST_PREFIX="${BOOST_PREFIX:-$ROOT_DIR/.build/deps/source-cache/boost/boost_1_91_0}"
LLVM_PREFIX="${LLVM_PREFIX:-$(brew --prefix llvm 2>/dev/null || true)}"
CXX="${CXX:-$LLVM_PREFIX/bin/clang++}"
SDK_PATH="${SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
TARGET_TRIPLE="${TARGET_TRIPLE:-arm64-apple-macosx26.0}"

all_targets=(
    bridge_magnet
    bridge_torrent_file
    bridge_resume_startup
    bridge_session_api
)

if [[ "$#" -gt 0 ]]; then
    targets=("$@")
else
    targets=("${all_targets[@]}")
fi

deps_ready() {
    [[ -f "$DEPS_PREFIX/lib/libtorrent-rasterbar.a" \
        && -f "$DEPS_PREFIX/lib/libssl.a" \
        && -f "$DEPS_PREFIX/lib/libcrypto.a" ]]
}

"$TOOLS_DIR/build-libfuzzer-deps.sh"

if ! deps_ready; then
    echo "libFuzzer dependencies are still missing under $DEPS_PREFIX" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"

bridge_sources=()
while IFS= read -r source; do
    bridge_sources+=("$source")
done < <(find "$ROOT_DIR/Sources/TorrentBridge" -maxdepth 1 -type f -name '*.cpp' | sort)

cxx_flags=(
    -target "$TARGET_TRIPLE"
    -isysroot "$SDK_PATH"
    -mmacosx-version-min=26.0
    -std=c++23
    -O1
    -g
    -fexceptions
    -fno-omit-frame-pointer
    -fsanitize=fuzzer,address,undefined,local-bounds
    -fno-sanitize-recover=undefined,local-bounds
    -fsanitize-address-use-after-scope
    -Wall
    -Wextra
    -Wformat
    -Wformat-security
    -Werror=format-security
    -fstack-protector-strong
    # Fuzz targets always use ASan; keep fortify from obscuring its reports.
    -U_FORTIFY_SOURCE
    -fno-delete-null-pointer-checks
    -fno-strict-aliasing
    -fstrict-flex-arrays=3
    -ftrivial-auto-var-init=zero
    -fvisibility=hidden
    -fvisibility-inlines-hidden
    -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_DEBUG
    -DBOOST_ASIO_ENABLE_CANCELIO
    -DBOOST_ASIO_NO_DEPRECATED
    -DBOOST_SYSTEM_USE_UTF8
    -DTORRENT_ABI_VERSION=100
    # The sanitized libtorrent archive uses CMake's Debug configuration, whose
    # public interface enables assertions and changes internal object layouts.
    -DTORRENT_USE_ASSERTS=1
    -DTORRENT_USE_I2P=0
    -DTORRENT_USE_RTC=0
    -DTORRENT_DISABLE_LOGGING
    -DTORRENT_DISABLE_MUTABLE_TORRENTS
    -DTORRENT_DISABLE_STREAMING
    -DTORRENT_DISABLE_SUPERSEEDING
    -DTORRENT_DISABLE_SHARE_MODE
    -DTORRENT_DISABLE_PREDICTIVE_PIECES
    -DTORRENT_USE_OPENSSL
    -DTORRENT_USE_LIBCRYPTO
    -DTORRENT_SSL_PEERS
    -DOPENSSL_NO_SSL2
    -DOPENSSL_NO_SSL3
    -DOPENSSL_NO_TLS1
    -DOPENSSL_NO_TLS1_1
    -DOPENSSL_NO_DTLS1
    -I"$TOOLS_DIR/harnesses"
    -I"$ROOT_DIR/Sources/TorrentBridge/include"
    -I"$DEPS_PREFIX/include"
    -I"$BOOST_PREFIX"
)

link_flags=(
    "$DEPS_PREFIX/lib/libtorrent-rasterbar.a"
    "$DEPS_PREFIX/lib/libssl.a"
    "$DEPS_PREFIX/lib/libcrypto.a"
    -framework CoreFoundation
    -framework SystemConfiguration
)

source_for_target() {
    case "$1" in
        bridge_magnet)
            printf '%s\n' "$TOOLS_DIR/harnesses/BridgeMagnetFuzzer.cpp"
            ;;
        bridge_torrent_file)
            printf '%s\n' "$TOOLS_DIR/harnesses/BridgeTorrentFileFuzzer.cpp"
            ;;
        bridge_resume_startup)
            printf '%s\n' "$TOOLS_DIR/harnesses/BridgeResumeStartupFuzzer.cpp"
            ;;
        bridge_session_api)
            printf '%s\n' "$TOOLS_DIR/harnesses/BridgeSessionAPIFuzzer.cpp"
            ;;
        *)
            echo "Unknown fuzz target: $1" >&2
            exit 1
            ;;
    esac
}

for target in "${targets[@]}"; do
    source="$(source_for_target "$target")"
    output="$BUILD_DIR/$target"
    echo "Building libFuzzer target $target"
    "$CXX" \
        "${cxx_flags[@]}" \
        "$source" \
        "${bridge_sources[@]}" \
        "${link_flags[@]}" \
        -o "$output"
done

echo "$BUILD_DIR"
