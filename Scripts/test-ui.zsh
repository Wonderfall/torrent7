#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
"$root_dir/Scripts/verify-xcode.zsh"
typeset action=test
if [[ ${1:-} == --build-only ]]; then
    action=build-for-testing
    shift
fi
# Run on a logged-in graphical session with UI automation permission. The host
# has no engine or persisted data, and VoiceOver's initial state is restored.
exec /usr/bin/xcrun xcodebuild "$action" \
    -project "$root_dir/Tools/UIDiagnostics/UIDiagnostics.xcodeproj" \
    -scheme UIDiagnostics -destination 'platform=macOS,arch=arm64e' \
    -derivedDataPath "$root_dir/.build/ui-diagnostics" \
    -parallel-testing-enabled NO -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 30 -maximum-test-execution-time-allowance 60 "$@"
