#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail typeset_silent

fail() {
    print -ru2 -- "$1"
    exit 1
}

typeset -r test_binary=$1
typeset temporary_directory

[[ -x "$test_binary" ]] || fail "Missing Bridge PAC test executable: $test_binary"

temporary_directory=$(/usr/bin/mktemp -d)
trap 'rm -rf -- "$temporary_directory"' EXIT INT TERM
/usr/bin/xcrun lipo "$test_binary" -verify_arch arm64e \
    || fail "Bridge PAC verification requires an arm64e test executable"
/usr/bin/xcrun otool -tvV "$test_binary" >"$temporary_directory/disassembly.txt"

extract_function() {
    local name=$1
    local output=$2
    /usr/bin/awk -v symbol="_$name:" '
        index($0, symbol) == 1 { capture = 1; next }
        capture && /^[^[:space:]][^:]*:$/ { exit }
        capture { print }
    ' "$temporary_directory/disassembly.txt" >"$output"
    [[ -s "$output" ]] || fail "Missing Bridge PAC codegen probe: $name"
}

verify_data_authentication() {
    local name=$1
    local input=$2
    local discriminator=$3
    /usr/bin/awk -v discriminator="#$discriminator" '
        /movk[[:space:]]+x[0-9]+,/ && index($0, discriminator) {
            modifier = $3
            sub(/,$/, "", modifier)
            remaining = 4
        }
        remaining > 0 && /[[:space:]]autdb[[:space:]]/ && index($0, ", " modifier) { found = 1 }
        remaining > 0 { remaining-- }
        END { exit !found }
    ' "$input" || fail "$name does not authenticate its address-diversified context with role $discriminator"
}

verify_callback_branch() {
    local name=$1
    local input=$2
    local discriminator=$3
    /usr/bin/awk -v discriminator="#$discriminator" '
        /movk[[:space:]]+x[0-9]+,/ && index($0, discriminator) {
            modifier = $3
            sub(/,$/, "", modifier)
            remaining = 40
        }
        remaining > 0 && /[[:space:]](braa|blraa)[[:space:]]/ \
            && index($0, ", " modifier) { found = 1 }
        remaining > 0 { remaining-- }
        END { exit !found }
    ' "$input" || fail "$name does not branch through its address-diversified callback role $discriminator"
    if /usr/bin/grep -Eq '[[:space:]](braaz|blraaz)[[:space:]]' "$input"; then
        fail "$name fell back to a zero-discriminator authenticated callback branch"
    fi
}

typeset wake="$temporary_directory/wake.txt"
typeset retain="$temporary_directory/retain.txt"
typeset release="$temporary_directory/release.txt"
extract_function TorrentBridgeTestInvokeWake "$wake"
extract_function TorrentBridgeTestInvokeAuthorizedRootRetain "$retain"
extract_function TorrentBridgeTestInvokeAuthorizedRootRelease "$release"

# AppleClang's pinned 16-bit string discriminators for the Bridge-owned slots.
verify_data_authentication wake.context "$wake" 0x8cdb
verify_callback_branch wake.callback "$wake" 0x9cc0
verify_data_authentication authorized-root.context "$retain" 0x2f9a
verify_callback_branch authorized-root.retain "$retain" 0xca4d
verify_data_authentication authorized-root.context "$release" 0x2f9a
verify_callback_branch authorized-root.release "$release" 0xc7ee

print -r -- "Bridge callback/context PAC codegen verification passed"
