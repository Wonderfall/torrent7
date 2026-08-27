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
typeset open_payload="$temporary_directory/open-payload.txt"
typeset payload_size="$temporary_directory/payload-size.txt"
typeset swarm_retain="$temporary_directory/swarm-retain.txt"
typeset swarm_release="$temporary_directory/swarm-release.txt"
typeset swarm_parse="$temporary_directory/swarm-parse.txt"
typeset swarm_capsule_release="$temporary_directory/swarm-capsule-release.txt"
extract_function TorrentBridgeTestInvokeWake "$wake"
extract_function TorrentBridgeTestInvokePayloadRetain "$retain"
extract_function TorrentBridgeTestInvokePayloadRelease "$release"
extract_function TorrentBridgeTestInvokePayloadOpen "$open_payload"
extract_function TorrentBridgeTestInvokePayloadSize "$payload_size"
extract_function TorrentBridgeTestInvokeSwarmMetainfoRetain "$swarm_retain"
extract_function TorrentBridgeTestInvokeSwarmMetainfoRelease "$swarm_release"
extract_function TorrentBridgeTestInvokeSwarmMetainfoParse "$swarm_parse"
extract_function TorrentBridgeTestInvokeSwarmMetainfoCapsuleRelease "$swarm_capsule_release"

# AppleClang's pinned 16-bit string discriminators for the Bridge-owned slots.
verify_data_authentication wake.context "$wake" 0x8cdb
verify_callback_branch wake.callback "$wake" 0x9cc0
verify_data_authentication payload.context "$retain" 0x33e
verify_callback_branch payload.retain "$retain" 0x5c7
verify_callback_branch payload.release "$release" 0x26d6
verify_callback_branch payload.open "$open_payload" 0x2285
verify_callback_branch payload.size "$payload_size" 0x664f
verify_data_authentication swarm-metainfo.context "$swarm_retain" 0x4e83
verify_callback_branch swarm-metainfo.retain "$swarm_retain" 0xb73c
verify_callback_branch swarm-metainfo.release "$swarm_release" 0x1f63
verify_callback_branch swarm-metainfo.parse "$swarm_parse" 0xaa1c
verify_callback_branch swarm-metainfo.capsule-release "$swarm_capsule_release" 0xcfc7

print -r -- "Bridge callback/context PAC codegen verification passed"
