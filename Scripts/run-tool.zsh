#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
"$root_dir/Scripts/verify-xcode.zsh" >&2
(( $# > 0 )) || { print -ru2 -- "Usage: run-tool.zsh TOOL [ARGUMENTS]"; exit 2; }
typeset -r tool=$1
shift
case $tool in
    compare-entitlements|verify-enhanced-security-metadata|check-dependencies|write-native-sbom) ;;
    *) print -ru2 -- "Unknown repository tool: $tool"; exit 2 ;;
esac
typeset -r scratch_path=${REPOSITORY_TOOLS_SCRATCH_PATH:-$root_dir/.build/repository-tools}
export TORRENT7_REPOSITORY_ROOT="$root_dir"
exec /usr/bin/xcrun swift run \
    --package-path "$root_dir/Tools" \
    --scratch-path "$scratch_path" \
    --only-use-versions-from-resolved-file \
    "$tool" "$@"
