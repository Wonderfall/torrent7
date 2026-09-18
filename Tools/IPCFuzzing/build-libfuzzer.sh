#!/usr/bin/env bash
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/../.." && pwd)"
"$ROOT_DIR/Scripts/verify-xcode.zsh"
BUILD_DIR="${BUILD_DIR:-$TOOLS_DIR/libfuzzer-build}"
SWIFT_BUILD_DIR="${SWIFT_BUILD_DIR:-$TOOLS_DIR/swift-build}"
SDK_PATH="${SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
TARGET_TRIPLE="${TARGET_TRIPLE:-arm64-apple-macosx27.0}"
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

all_targets=(
    dht_message_parser
    http_tracker_response_parser
    ipc_json_preflight
    magnet_parser
    peer_protocol_parser
    storage_broker_ipc
    storage_claim_validation
    storage_manifest
    swarm_info_parser
)

if [[ "$#" -gt 0 ]]; then
    targets=("$@")
else
    targets=("${all_targets[@]}")
fi

harness_for_target() {
    case "$1" in
        dht_message_parser)
            printf '%s\n' "$TOOLS_DIR/harnesses/DHTMessageParserFuzzer.cpp"
            ;;
        http_tracker_response_parser)
            printf '%s\n' "$TOOLS_DIR/harnesses/HTTPTrackerResponseParserFuzzer.cpp"
            ;;
        ipc_json_preflight)
            printf '%s\n' "$TOOLS_DIR/harnesses/IPCJSONPreflightFuzzer.cpp"
            ;;
        magnet_parser)
            printf '%s\n' "$TOOLS_DIR/harnesses/MagnetParserFuzzer.cpp"
            ;;
        peer_protocol_parser)
            printf '%s\n' "$TOOLS_DIR/harnesses/PeerProtocolParserFuzzer.cpp"
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
        swarm_info_parser)
            printf '%s\n' "$TOOLS_DIR/harnesses/SwarmInfoParserFuzzer.cpp"
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
        dht_message_parser | http_tracker_response_parser | magnet_parser | peer_protocol_parser | storage_claim_validation | storage_manifest | swarm_info_parser)
            printf '%s\n' TorrentStorageFuzzSupport
            ;;
    esac
}

needs_ipc_support=false
needs_storage_support=false
for target in "${targets[@]}"; do
    harness_for_target "$target" >/dev/null
    case "$(support_for_target "$target")" in
        TorrentEngineIPCFuzzSupport) needs_ipc_support=true ;;
        TorrentStorageFuzzSupport) needs_storage_support=true ;;
    esac
done

swift_build_flags=(
    --package-path "$ROOT_DIR"
    --scratch-path "$SWIFT_BUILD_DIR"
    --disable-build-manifest-caching
    --arch "${TARGET_TRIPLE%%-*}"
    --configuration debug
    --sanitize address
    -Xswiftc -sanitize-coverage=edge,indirect-calls,inline-8bit-counters,pc-table
)

SWIFT_BIN_DIR="${SWIFT_BIN_DIR:-$(/usr/bin/xcrun swift build "${swift_build_flags[@]}" --show-bin-path)}"

if [[ "$needs_ipc_support" == true ]]; then
    /usr/bin/xcrun swift build \
        "${swift_build_flags[@]}" \
        --product TorrentEngineIPCFuzzSupport
    ipc_support_library="$SWIFT_BIN_DIR/libTorrentEngineIPCFuzzSupport.dylib"
    if [[ ! -f "$ipc_support_library" ]]; then
        echo "Missing Swift fuzz support library: $ipc_support_library" >&2
        exit 1
    fi
fi

if [[ "$needs_storage_support" == true ]]; then
    /usr/bin/xcrun swift build \
        "${swift_build_flags[@]}" \
        --product TorrentStorageFuzzSupport
    storage_support_library="$SWIFT_BIN_DIR/libTorrentStorageFuzzSupport.dylib"
    if [[ ! -f "$storage_support_library" ]]; then
        echo "Missing Swift fuzz support library: $storage_support_library" >&2
        exit 1
    fi
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
        -mmacosx-version-min=27.0 \
        -std=c++23 \
        -O1 \
        -g \
        -fno-omit-frame-pointer \
        -fsanitize=fuzzer-no-link,address,undefined \
        -fno-sanitize-recover=undefined \
        -Wall \
        -Wextra \
        -Wconditional-uninitialized \
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
