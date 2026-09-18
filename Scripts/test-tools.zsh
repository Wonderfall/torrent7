#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
"$root_dir/Scripts/verify-xcode.zsh"
typeset -r profile=${SANITIZER_PROFILE:-}
typeset -a sanitizer_args=()
case $profile in
    "") ;;
    address|thread) sanitizer_args=(--sanitize "$profile" --sanitize undefined) ;;
    *) print -ru2 -- "SANITIZER_PROFILE must be address or thread"; exit 2 ;;
esac
/usr/bin/xcrun swift test \
    --package-path "$root_dir/Tools" \
    --scratch-path "$root_dir/.build/repository-tools${profile:+-$profile}" \
    --configuration "${CONFIGURATION:-debug}" \
    --only-use-versions-from-resolved-file \
    "${sanitizer_args[@]}" "$@"
