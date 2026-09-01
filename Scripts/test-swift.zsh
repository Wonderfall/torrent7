#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
typeset -r configuration=${CONFIGURATION:-debug}
typeset -r sanitizer_profile=${SANITIZER_PROFILE:-}
case $sanitizer_profile in
    ""|address|thread) ;;
    *) print -ru2 -- "SANITIZER_PROFILE must be address or thread"; exit 2 ;;
esac
typeset -r scratch_profile=${sanitizer_profile:-default}
typeset -r scratch_path=${SWIFT_TEST_SCRATCH_PATH:-"$root_dir/.build/swift-test-$scratch_profile"}

cd -- "$root_dir"

"$root_dir/Scripts/lint-unsafe-boundaries.zsh"

export CC="${CC:-$(xcrun --find clang)}"
export CXX="${CXX:-$(xcrun --find clang++)}"
export TORRENT7_NATIVE_DEPS_BUILD_ID=$("$root_dir/Scripts/native-deps-build-id.zsh")

typeset -a swift_build_args=(
    --scratch-path "$scratch_path"
    --configuration "$configuration"
    --triple arm64e-apple-macosx26.0
    --explicit-target-dependency-import-check error
)
case $sanitizer_profile in
    address) swift_build_args+=(--sanitize address --sanitize undefined) ;;
    thread) swift_build_args+=(--sanitize thread --sanitize undefined) ;;
esac

typeset -ra fuzz_support_products=(
    TorrentEngineIPCFuzzSupport
    TorrentStorageFuzzSupport
)
for product in "${fuzz_support_products[@]}"; do
    swift build "${swift_build_args[@]}" --product "$product"
done

verify_exported_symbols() {
    local -r library=$1
    shift
    [[ -f $library ]] || {
        print -ru2 -- "Missing Swift fuzz support library: $library"
        return 1
    }

    local symbol
    for symbol in "$@"; do
        /usr/bin/nm -gjU "$library" | /usr/bin/grep -Fqx -- "_$symbol" || {
            print -ru2 -- "Missing Swift fuzz support export $symbol in $library"
            return 1
        }
    done
}

typeset -r fuzz_support_dir="$scratch_path/arm64e-apple-macosx/$configuration"
verify_exported_symbols \
    "$fuzz_support_dir/libTorrentEngineIPCFuzzSupport.dylib" \
    TorrentEngineIPCJSONPreflightFuzzOneInput \
    TorrentStorageBrokerIPCFuzzOneInput
verify_exported_symbols \
    "$fuzz_support_dir/libTorrentStorageFuzzSupport.dylib" \
    TorrentDHTMessageParserFuzzOneInput \
    TorrentHTTPTrackerResponseParserFuzzOneInput \
    TorrentMagnetParserFuzzOneInput \
    TorrentPeerProtocolParserFuzzOneInput \
    TorrentStorageClaimFuzzOneInput \
    TorrentStorageManifestFuzzOneInput \
    TorrentSwarmInfoParserFuzzOneInput

swift test "${swift_build_args[@]}" "$@"
