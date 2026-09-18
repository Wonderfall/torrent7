#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
(( $# == 4 )) || { print -ru2 -- 'Usage: test-release-evidence.zsh APP BIN_DIR DEPS_PREFIX SBOM_DIR'; exit 2; }
typeset -r app_dir=${1:A} bin_dir=${2:A} deps_prefix=${3:A} sbom_dir=${4:A}
typeset -r temporary_dir=$(/usr/bin/mktemp -d "$root_dir/.build/release-evidence-test.XXXXXXXX")
trap '/bin/rm -rf -- "$temporary_dir"' EXIT
typeset -r archive="$root_dir/Scripts/archive-release-evidence.zsh"

"$archive" "$app_dir" "$bin_dir" "$deps_prefix" "$sbom_dir" "$temporary_dir/valid"
[[ -s "$temporary_dir/valid/Symbols.zip" && -s "$temporary_dir/valid/SBOM/native.cdx.json" ]]
/usr/bin/unzip -tq "$temporary_dir/valid/Symbols.zip"

/bin/mkdir -- "$temporary_dir/missing" "$temporary_dir/mismatched"
/usr/bin/ditto "$bin_dir/TorrentEngineExtension.dSYM" "$temporary_dir/mismatched/Torrent7.dSYM"
for fixture in missing mismatched; do
    if "$archive" "$app_dir" "$temporary_dir/$fixture" "$deps_prefix" "$sbom_dir" \
        "$temporary_dir/rejected" > "$temporary_dir/rejection.log" 2>&1; then
        print -ru2 -- "Accepted $fixture release symbols"
        exit 1
    fi
    [[ ! -e "$temporary_dir/rejected" ]] || { print -ru2 -- 'Published partial evidence'; exit 1; }
    case $fixture in
        missing) /usr/bin/grep -q 'Missing binary or dSYM' "$temporary_dir/rejection.log" ;;
        mismatched) /usr/bin/grep -q 'dSYM UUID does not match' "$temporary_dir/rejection.log" ;;
    esac
done
/usr/bin/ditto "$sbom_dir" "$temporary_dir/wrong-sbom"
typeset -a product_sboms=("$temporary_dir/wrong-sbom/Torrent7/"*.json(N))
(( ${#product_sboms} == 1 ))
/usr/bin/plutil -replace metadata.component.name -string WrongProduct "${product_sboms[1]}"
if "$archive" "$app_dir" "$bin_dir" "$deps_prefix" "$temporary_dir/wrong-sbom" \
    "$temporary_dir/rejected" > "$temporary_dir/rejection.log" 2>&1; then
    print -ru2 -- 'Accepted an SBOM for another product'
    exit 1
fi
[[ ! -e "$temporary_dir/rejected" ]]
/usr/bin/grep -q 'SBOM does not describe the expected product' "$temporary_dir/rejection.log"
print -r -- 'Release evidence: matching symbols archived; missing and mismatched symbols rejected.'
