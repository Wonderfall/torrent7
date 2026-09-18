#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
"$root_dir/Scripts/verify-xcode.zsh"
(( $# == 2 )) || { print -ru2 -- 'Usage: profile-app.zsh swiftui|concurrency PID'; exit 2; }
typeset template
case $1 in
    swiftui) template=SwiftUI ;;
    concurrency) template='Swift Concurrency' ;;
    *) print -ru2 -- 'Choose swiftui or concurrency'; exit 2 ;;
esac
[[ $2 == <1-> ]] || { print -ru2 -- 'PID must be a positive integer'; exit 2; }
typeset -r output_dir="$root_dir/.build/profiles"
/bin/mkdir -p -- "$output_dir"
# Attach only to the requested process. The 15-second window stays bounded and
# does not launch another app instance or change its settings.
exec /usr/bin/xcrun xctrace record --template "$template" --attach "$2" \
    --time-limit 15s --no-prompt --output "$output_dir"
