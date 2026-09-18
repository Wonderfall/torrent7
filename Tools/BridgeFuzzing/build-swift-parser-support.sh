#!/usr/bin/env bash
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/../.." && pwd)"
"$ROOT_DIR/Scripts/verify-xcode.zsh"
SWIFT_BUILD_DIR="${PARSER_SWIFT_BUILD_DIR:-$TOOLS_DIR/swift-build}"
SDK_PATH="${SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
TARGET_TRIPLE="${TARGET_TRIPLE:-arm64-apple-macosx27.0}"
SWIFT="${SWIFT:-$(xcrun --find swift)}"
SWIFTC="${SWIFTC:-$(xcrun --find swiftc)}"
PACKAGE_IDENTITY="$(basename "$ROOT_DIR" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"

swift_build_flags=(
    --package-path "$ROOT_DIR"
    --scratch-path "$SWIFT_BUILD_DIR"
    --disable-build-manifest-caching
    --arch "${TARGET_TRIPLE%%-*}"
    --configuration debug
    --sanitize address
    -Xswiftc -sanitize-coverage=edge,indirect-calls,inline-8bit-counters,pc-table
)

SWIFT_BIN_DIR="${PARSER_SWIFT_BIN_DIR:-$(/usr/bin/xcrun swift build "${swift_build_flags[@]}" --show-bin-path)}"

"$SWIFT" build \
    "${swift_build_flags[@]}" \
    --product TorrentStorageFuzzSupport

dependency_library="$SWIFT_BIN_DIR/libTorrentStorageFuzzSupport.dylib"
if [[ ! -f "$dependency_library" ]]; then
    echo "Missing Swift parser dependency library: $dependency_library" >&2
    exit 1
fi

output="$SWIFT_BIN_DIR/libTorrentParserBridgeFuzzSupport.dylib"
sources=(
    "$ROOT_DIR/Sources/TorrentEngineCore/TorrentMetainfoBridgeCapsule.swift"
    "$ROOT_DIR/Sources/TorrentEngineCore/TorrentSwarmMetainfoParser.swift"
    "$ROOT_DIR/Sources/TorrentEngineCore/TorrentPeerProtocolBridge.swift"
    "$ROOT_DIR/Sources/TorrentEngineCore/TorrentTrackerResponseBridge.swift"
    "$ROOT_DIR/Sources/TorrentEngineCore/TorrentDHTMessageBridge.swift"
    "$TOOLS_DIR/SwiftSupport/ParserBridgeFuzzSupport.swift"
)

"$SWIFTC" \
    -target "$TARGET_TRIPLE" \
    -sdk "$SDK_PATH" \
    -parse-as-library \
    -emit-library \
    -module-name TorrentParserBridgeFuzzSupport \
    -package-name "$PACKAGE_IDENTITY" \
    -swift-version 6 \
    -strict-concurrency=complete \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -default-isolation nonisolated \
    -warn-soft-deprecated \
    -strict-memory-safety \
    -warnings-as-errors \
    -g \
    -sanitize=address \
    -sanitize-coverage=edge,indirect-calls,inline-8bit-counters,pc-table \
    -I "$SWIFT_BIN_DIR" \
    -I "$TOOLS_DIR/SwiftSupport/TorrentBridgeModule" \
    -L "$SWIFT_BIN_DIR" \
    -lTorrentStorageFuzzSupport \
    -Xlinker -install_name \
    -Xlinker @rpath/libTorrentParserBridgeFuzzSupport.dylib \
    -Xlinker -rpath \
    -Xlinker "$SWIFT_BIN_DIR" \
    "${sources[@]}" \
    -o "$output"

echo "$SWIFT_BIN_DIR"
