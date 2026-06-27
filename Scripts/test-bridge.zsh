#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
typeset -r configuration=${CONFIGURATION:-debug}

cd -- "$root_dir"

export CC="$(xcrun --find clang)"
export CXX="$(xcrun --find clang++)"

if [[ "${SKIP_BUILD_DEPS:-0}" != "1" ]]; then
    "$root_dir/Scripts/build-deps.zsh"
fi

swift run \
    --configuration "$configuration" \
    --triple arm64e-apple-macosx26.0 \
    TorrentBridgeTests \
    "$@"
