#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
"$root_dir/Scripts/verify-xcode.zsh"
typeset -r configuration=${CONFIGURATION:-debug}
typeset -r sanitizer_profile=${SANITIZER_PROFILE:-}
case $sanitizer_profile in
    ""|address|thread) ;;
    *) print -ru2 -- "SANITIZER_PROFILE must be address or thread"; exit 2 ;;
esac
typeset -r scratch_profile=${sanitizer_profile:-default}
typeset -r scratch_path=${BRIDGE_TEST_SCRATCH_PATH:-"$root_dir/.build/bridge-test-$scratch_profile"}

cd -- "$root_dir"

export CC="$(xcrun --find clang)"
export CXX="$(xcrun --find clang++)"

if [[ "${SKIP_BUILD_DEPS:-0}" != "1" ]]; then
    "$root_dir/Scripts/build-deps.zsh"
fi
export TORRENT7_NATIVE_DEPS_BUILD_ID=$("$root_dir/Scripts/native-deps-build-id.zsh")

typeset -a swift_run_args=(
    --scratch-path "$scratch_path"
    --configuration "$configuration"
    --arch arm64e
)
case $sanitizer_profile in
    address) swift_run_args+=(--sanitize address --sanitize undefined) ;;
    thread) swift_run_args+=(--sanitize thread --sanitize undefined) ;;
esac

/usr/bin/xcrun swift run "${swift_run_args[@]}" TorrentBridgeTests "$@"
typeset -r bin_dir=$(/usr/bin/xcrun swift build "${swift_run_args[@]}" --show-bin-path)
"$root_dir/Scripts/verify-bridge-pac.zsh" "$bin_dir/TorrentBridgeTests"
