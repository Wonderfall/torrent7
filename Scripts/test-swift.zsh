#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
typeset -r configuration=${CONFIGURATION:-debug}
typeset -r enable_diagnostics=${SANITIZER_DIAGNOSTICS:-0}
typeset scratch_profile=default
if [[ $enable_diagnostics == "1" ]]; then
    scratch_profile=diagnostics
fi
typeset -r scratch_path=${SWIFT_TEST_SCRATCH_PATH:-"$root_dir/.build/swift-test-$scratch_profile"}

cd -- "$root_dir"

export CC="${CC:-$(xcrun --find clang)}"
export CXX="${CXX:-$(xcrun --find clang++)}"

typeset -a swift_test_args=(
    --scratch-path "$scratch_path"
    --configuration "$configuration"
    --triple arm64e-apple-macosx26.0
)
if [[ $enable_diagnostics == "1" ]]; then
    swift_test_args+=(--sanitize address --sanitize undefined)
fi

swift test "${swift_test_args[@]}" "$@"
