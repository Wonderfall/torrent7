#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
typeset -r configuration=${CONFIGURATION:-debug}

cd -- "$root_dir"

export CC="${CC:-$(xcrun --find clang)}"
export CXX="${CXX:-$(xcrun --find clang++)}"

swift test \
    --configuration "$configuration" \
    --triple arm64e-apple-macosx26.0 \
    "$@"
