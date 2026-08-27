#!/usr/bin/env bash
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/../.." && pwd)"

BUILD_DIR="${BUILD_DIR:-$TOOLS_DIR/libfuzzer-build}"
DEPS_ROOT="${LIBFUZZER_DEPS_ROOT:-$TOOLS_DIR/deps/arm64-libfuzzer}"
PARSER_SWIFT_BUILD_DIR="${PARSER_SWIFT_BUILD_DIR:-$TOOLS_DIR/swift-build}"
PARSER_SWIFT_BIN_DIR="${PARSER_SWIFT_BIN_DIR:-$PARSER_SWIFT_BUILD_DIR/arm64-apple-macosx/debug}"
if [[ -n "${LIBFUZZER_DEPS_PREFIX:-}" \
    && "${LIBFUZZER_DEPS_PREFIX:-}" != "$DEPS_ROOT/prefix" ]]; then
    echo "LIBFUZZER_DEPS_PREFIX must be the prefix child of LIBFUZZER_DEPS_ROOT" >&2
    exit 1
fi
DEPS_PREFIX="$DEPS_ROOT/prefix"
BOOST_PREFIX="${BOOST_PREFIX:-$ROOT_DIR/.build/deps/source-cache/boost/boost_1_92_0}"
LLVM_PREFIX="${LLVM_PREFIX:-$(brew --prefix llvm 2>/dev/null || true)}"
CXX="${CXX:-$(xcrun --find clang++)}"
FUZZER_RUNTIME="${FUZZER_RUNTIME:-}"
if [[ -z "$FUZZER_RUNTIME" && -n "$LLVM_PREFIX" ]]; then
    FUZZER_RUNTIME="$(
        find "$LLVM_PREFIX/lib/clang" \
            -path '*/lib/darwin/libclang_rt.fuzzer_osx.a' \
            -print \
            -quit
    )"
fi
SDK_PATH="${SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
TARGET_TRIPLE="${TARGET_TRIPLE:-arm64-apple-macosx26.0}"

all_targets=(
    bridge_magnet
    bridge_metainfo_capsule
    bridge_parser_callbacks
    bridge_resume_startup
    bridge_session_api
    bridge_payload_broker
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
    '-DTORRENT7_NATIVE_DEPS_BUILD_ID="torrent7-native-deps:fuzz"'
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
    -I"$TOOLS_DIR/harnesses"
    -I"$TOOLS_DIR/SwiftSupport"
    -I"$ROOT_DIR/Sources/TorrentBridge"
    -I"$ROOT_DIR/Sources/TorrentBridge/include"
    -I"$DEPS_PREFIX/include"
    -I"$BOOST_PREFIX"
)

link_flags=(
    "$DEPS_PREFIX/lib/libtorrent-rasterbar.a"
    "$DEPS_PREFIX/lib/libssl.a"
    "$DEPS_PREFIX/lib/libcrypto.a"
    -framework CoreFoundation
    -framework Security
    -framework SystemConfiguration
)

source_for_target() {
    case "$1" in
        bridge_magnet)
            printf '%s\n' "$TOOLS_DIR/harnesses/BridgeMagnetFuzzer.cpp"
            ;;
        bridge_metainfo_capsule)
            printf '%s\n' "$TOOLS_DIR/harnesses/BridgeMetainfoCapsuleFuzzer.cpp"
            ;;
        bridge_parser_callbacks)
            printf '%s\n' "$TOOLS_DIR/harnesses/BridgeParserCallbacksFuzzer.cpp"
            ;;
        bridge_resume_startup)
            printf '%s\n' "$TOOLS_DIR/harnesses/BridgeResumeStartupFuzzer.cpp"
            ;;
        bridge_session_api)
            printf '%s\n' "$TOOLS_DIR/harnesses/BridgeSessionAPIFuzzer.cpp"
            ;;
        bridge_payload_broker)
            printf '%s\n' "$TOOLS_DIR/harnesses/BridgePayloadBrokerFuzzer.cpp"
            ;;
        *)
            echo "Unknown fuzz target: $1" >&2
            exit 1
            ;;
    esac
}

needs_swift_parser_support=false
for target in "${targets[@]}"; do
    source_for_target "$target" >/dev/null
    if [[ "$target" == bridge_parser_callbacks ]]; then
        needs_swift_parser_support=true
    fi
done

if [[ ! -f "$FUZZER_RUNTIME" ]]; then
    echo "Homebrew LLVM libFuzzer runtime not found; install llvm or set FUZZER_RUNTIME" >&2
    exit 1
fi

if [[ "$needs_swift_parser_support" == true ]]; then
    PARSER_SWIFT_BUILD_DIR="$PARSER_SWIFT_BUILD_DIR" \
        PARSER_SWIFT_BIN_DIR="$PARSER_SWIFT_BIN_DIR" \
        "$TOOLS_DIR/build-swift-parser-support.sh"
fi

for target in "${targets[@]}"; do
    source="$(source_for_target "$target")"
    output="$BUILD_DIR/$target"
    target_link_flags=("$FUZZER_RUNTIME" "${link_flags[@]}")
    if [[ "$target" == bridge_parser_callbacks ]]; then
        target_link_flags+=(
            -L"$PARSER_SWIFT_BIN_DIR"
            -lTorrentParserBridgeFuzzSupport
            -lTorrentStorageFuzzSupport
            -Wl,-rpath,"$PARSER_SWIFT_BIN_DIR"
        )
    fi
    echo "Building libFuzzer target $target"
    "$CXX" \
        "${cxx_flags[@]}" \
        -fsanitize=fuzzer-no-link,address,undefined,local-bounds \
        "$source" \
        "${bridge_sources[@]}" \
        "${target_link_flags[@]}" \
        -o "$output"
done

echo "$BUILD_DIR"
