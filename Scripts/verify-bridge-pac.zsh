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
# Check the named architecture: lipo -verify_arch rejects arm64e executables
# carrying Swift Build's versioned arm64e ABI capability bits in Xcode 27.
[[ $(/usr/bin/xcrun lipo -archs "$test_binary") == arm64e ]] \
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
typeset peer_retain="$temporary_directory/peer-retain.txt"
typeset peer_release="$temporary_directory/peer-release.txt"
typeset peer_handshake="$temporary_directory/peer-handshake.txt"
typeset peer_metadata="$temporary_directory/peer-metadata.txt"
typeset peer_pex="$temporary_directory/peer-pex.txt"
typeset tracker_retain="$temporary_directory/tracker-retain.txt"
typeset tracker_release="$temporary_directory/tracker-release.txt"
typeset tracker_http="$temporary_directory/tracker-http.txt"
typeset dht_retain="$temporary_directory/dht-retain.txt"
typeset dht_release="$temporary_directory/dht-release.txt"
typeset dht_message="$temporary_directory/dht-message.txt"
extract_function TorrentBridgeTestInvokeWake "$wake"
extract_function TorrentBridgeTestInvokePayloadRetain "$retain"
extract_function TorrentBridgeTestInvokePayloadRelease "$release"
extract_function TorrentBridgeTestInvokePayloadOpen "$open_payload"
extract_function TorrentBridgeTestInvokePayloadSize "$payload_size"
extract_function TorrentBridgeTestInvokeSwarmMetainfoRetain "$swarm_retain"
extract_function TorrentBridgeTestInvokeSwarmMetainfoRelease "$swarm_release"
extract_function TorrentBridgeTestInvokeSwarmMetainfoParse "$swarm_parse"
extract_function TorrentBridgeTestInvokeSwarmMetainfoCapsuleRelease "$swarm_capsule_release"
extract_function TorrentBridgeTestInvokePeerProtocolRetain "$peer_retain"
extract_function TorrentBridgeTestInvokePeerProtocolRelease "$peer_release"
extract_function TorrentBridgeTestInvokePeerProtocolHandshake "$peer_handshake"
extract_function TorrentBridgeTestInvokePeerProtocolMetadata "$peer_metadata"
extract_function TorrentBridgeTestInvokePeerProtocolPEX "$peer_pex"
extract_function TorrentBridgeTestInvokeTrackerParserRetain "$tracker_retain"
extract_function TorrentBridgeTestInvokeTrackerParserRelease "$tracker_release"
extract_function TorrentBridgeTestInvokeTrackerParserHTTP "$tracker_http"
extract_function TorrentBridgeTestInvokeDHTParserRetain "$dht_retain"
extract_function TorrentBridgeTestInvokeDHTParserRelease "$dht_release"
extract_function TorrentBridgeTestInvokeDHTParserMessage "$dht_message"

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
verify_data_authentication peer-protocol.context "$peer_retain" 0x5d9e
verify_callback_branch peer-protocol.retain "$peer_retain" 0x55eb
verify_callback_branch peer-protocol.release "$peer_release" 0x27da
verify_callback_branch peer-protocol.handshake "$peer_handshake" 0x4c7
verify_callback_branch peer-protocol.metadata "$peer_metadata" 0x719
verify_callback_branch peer-protocol.pex "$peer_pex" 0x71df
verify_data_authentication tracker-parser.context "$tracker_retain" 0x2226
verify_callback_branch tracker-parser.retain "$tracker_retain" 0x5643
verify_callback_branch tracker-parser.release "$tracker_release" 0x10fd
verify_callback_branch tracker-parser.http "$tracker_http" 0xa3a7
verify_data_authentication dht-parser.context "$dht_retain" 0x13ee
verify_callback_branch dht-parser.retain "$dht_retain" 0x46a9
verify_callback_branch dht-parser.release "$dht_release" 0xbeff
verify_callback_branch dht-parser.message "$dht_message" 0x6d75

print -r -- "Bridge callback/context PAC codegen verification passed"
