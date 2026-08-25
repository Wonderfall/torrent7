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
SWIFTC="${SWIFTC:-$(xcrun --find swiftc)}"
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

all_targets=(
    ipc_json_preflight
    storage_broker_ipc
    storage_claim_validation
    storage_manifest
)

if [[ "$#" -gt 0 ]]; then
    targets=("$@")
else
    targets=("${all_targets[@]}")
fi

harness_for_target() {
    case "$1" in
        ipc_json_preflight)
            printf '%s\n' "$TOOLS_DIR/harnesses/IPCJSONPreflightFuzzer.cpp"
            ;;
        storage_broker_ipc)
            printf '%s\n' "$TOOLS_DIR/harnesses/StorageBrokerIPCFuzzer.cpp"
            ;;
        storage_claim_validation)
            printf '%s\n' "$TOOLS_DIR/harnesses/StorageClaimFuzzer.cpp"
            ;;
        storage_manifest)
            printf '%s\n' "$TOOLS_DIR/harnesses/StorageManifestFuzzer.cpp"
            ;;
        *)
            echo "Unknown fuzz target: $1" >&2
            exit 1
            ;;
    esac
}

support_for_target() {
    case "$1" in
        ipc_json_preflight | storage_broker_ipc)
            printf '%s\n' TorrentEngineIPCFuzzSupport
            ;;
        storage_claim_validation | storage_manifest)
            printf '%s\n' TorrentStorageFuzzSupport
            ;;
    esac
}

needs_storage_support=false
for target in "${targets[@]}"; do
    harness_for_target "$target" >/dev/null
    if [[ "$(support_for_target "$target")" == TorrentStorageFuzzSupport ]]; then
        needs_storage_support=true
    fi
done

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

if [[ "$needs_storage_support" == true ]]; then
    model_object="$SWIFT_BIN_DIR/TorrentEngineModel.build/TorrentEngineLimits.swift.o"
    if [[ ! -f "$model_object" ]]; then
        echo "Missing TorrentEngineModel limits object under $SWIFT_BIN_DIR" >&2
        exit 1
    fi

    storage_support_library="$SWIFT_BIN_DIR/libTorrentStorageFuzzSupport.dylib"
    "$SWIFTC" \
        -target "$TARGET_TRIPLE" \
        -sdk "$SDK_PATH" \
        -swift-version 6 \
        -parse-as-library \
        -emit-library \
        -module-name TorrentStorageFuzzSupport \
        -package-name swiftui_torrent \
        -g \
        -Onone \
        -sanitize=address \
        -sanitize-coverage=edge,indirect-calls,inline-8bit-counters,pc-table \
        -strict-concurrency=complete \
        -warn-soft-deprecated \
        -warnings-as-errors \
        -I "$SWIFT_BIN_DIR/Modules" \
        "$ROOT_DIR/Sources/TorrentApp/Storage/TorrentStorageClaim.swift" \
        "$ROOT_DIR/Sources/TorrentApp/Storage/TorrentManifestParser.swift" \
        "$TOOLS_DIR/StorageSupport/StorageAuthorityFuzzSupport.swift" \
        "$model_object" \
        -Xlinker -install_name \
        -Xlinker @rpath/libTorrentStorageFuzzSupport.dylib \
        -o "$storage_support_library"
fi

mkdir -p "$BUILD_DIR"
for target in "${targets[@]}"; do
    harness="$(harness_for_target "$target")"
    support="$(support_for_target "$target")"
    output="$BUILD_DIR/$target"
    echo "Building libFuzzer target $target"
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
        "$harness" \
        "$FUZZER_RUNTIME" \
        -L"$SWIFT_BIN_DIR" \
        -l"$support" \
        -Wl,-rpath,"$SWIFT_BIN_DIR" \
        -o "$output"
done

echo "$BUILD_DIR"
