#!/usr/bin/env bash
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$TOOLS_DIR/libfuzzer-build}"
SWIFT_BUILD_DIR="${SWIFT_BUILD_DIR:-$TOOLS_DIR/swift-build}"
SWIFT_BIN_DIR="${SWIFT_BIN_DIR:-$SWIFT_BUILD_DIR/arm64-apple-macosx/debug}"
SDK_PATH="${SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
TARGET_TRIPLE="${TARGET_TRIPLE:-arm64-apple-macosx26.0}"
CXX="${CXX:-$(xcrun --find clang++)}"
LLVM_PREFIX="${LLVM_PREFIX:-$(brew --prefix llvm 2>/dev/null || true)}"
FUZZER_RUNTIME="${FUZZER_RUNTIME:-}"
if [[ -z "$FUZZER_RUNTIME" && -n "$LLVM_PREFIX" ]]; then
    FUZZER_RUNTIME="$(
        find "$LLVM_PREFIX/lib/clang" \
            -path '*/lib/darwin/libclang_rt.fuzzer_osx.a' \
            -print \
            -quit
    )"
fi
if [[ ! -f "$FUZZER_RUNTIME" ]]; then
    echo "Homebrew LLVM libFuzzer runtime not found; install llvm or set FUZZER_RUNTIME" >&2
    exit 1
fi

swift_build_flags=(
    --package-path "$ROOT_DIR"
    --scratch-path "$SWIFT_BUILD_DIR"
    --disable-build-manifest-caching
    --triple "$TARGET_TRIPLE"
    --configuration debug
    --sanitize address
    -Xswiftc -sanitize-coverage=edge,indirect-calls,inline-8bit-counters,pc-table
)

swift build \
    "${swift_build_flags[@]}" \
    --product TorrentEngineIPCFuzzSupport

support_library="$SWIFT_BIN_DIR/libTorrentEngineIPCFuzzSupport.dylib"
if [[ ! -f "$support_library" ]]; then
    echo "Missing Swift fuzz support library: $support_library" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"
output="$BUILD_DIR/ipc_json_preflight"
"$CXX" \
    -target "$TARGET_TRIPLE" \
    -isysroot "$SDK_PATH" \
    -mmacosx-version-min=26.0 \
    -std=c++23 \
    -O1 \
    -g \
    -fno-omit-frame-pointer \
    -fsanitize=fuzzer-no-link,address,undefined \
    -fno-sanitize-recover=undefined \
    -Wall \
    -Wextra \
    -Wconversion \
    -Werror \
    "$TOOLS_DIR/harnesses/IPCJSONPreflightFuzzer.cpp" \
    "$FUZZER_RUNTIME" \
    -L"$SWIFT_BIN_DIR" \
    -lTorrentEngineIPCFuzzSupport \
    -Wl,-rpath,"$SWIFT_BIN_DIR" \
    -o "$output"

echo "$output"
