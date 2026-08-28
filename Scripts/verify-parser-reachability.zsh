#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail typeset_silent

fail() {
    print -ru2 -- "$1"
    exit 1
}

(( $# == 2 || $# == 3 )) \
    || fail "Usage: ${0:t} ENGINE_EXECUTABLE LIBTORRENT_ARCHIVE [BRIDGE_OBJECT_DIRECTORY]"

typeset -r engine_executable=$1
typeset -r libtorrent_archive=$2
typeset -r bridge_object_directory=${3:-}
typeset -r temporary_directory=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf -- "$temporary_directory"' EXIT

[[ -f $engine_executable && ! -L $engine_executable ]] \
    || fail "Missing or linked engine executable: $engine_executable"
[[ -f $libtorrent_archive && ! -L $libtorrent_archive ]] \
    || fail "Missing or linked libtorrent archive: $libtorrent_archive"
if [[ -n $bridge_object_directory ]]; then
    [[ -d $bridge_object_directory && ! -L $bridge_object_directory ]] \
        || fail "Missing or linked bridge object directory: $bridge_object_directory"
fi

reject_match() {
    local -r pattern=$1
    local -r input=$2
    local -r message=$3

    if /usr/bin/grep -Eq -- "$pattern" "$input"; then
        fail "$message"
    fi
}

require_match() {
    local -r pattern=$1
    local -r input=$2
    local -r message=$3

    /usr/bin/grep -Eq -- "$pattern" "$input" || fail "$message"
}

typeset -ra retired_final_patterns=(
    '(^|[[:space:]])_TorrentClientAddTorrentFileData$'
    '(^|[[:space:]])_TorrentClientAddMagnet$'
    'load_torrent_buffer'
    'load_torrent_parsed'
    'parse_magnet_uri'
    'parse_info_section_impl'
    'parse_tracker_response'
    'extract_peer_info'
    'libtorrent.*verify_message_impl'
    'torrent_infoC[12].*bdecode_node'
)
typeset -ra required_bridge_patterns=(
    '(^|[[:space:]])_TorrentClientAddMetainfoCapsule$'
    'BridgeSwarmMetadataParser5parse'
    'BridgePeerMessageParser25parse_extension_handshake'
    'BridgePeerMessageParser17parse_ut_metadata'
    'BridgePeerMessageParser12parse_ut_pex'
    'BridgeTrackerResponseParser19parse_http_response'
    'BridgeDHTMessageParser13parse_message'
    'import_preparsed_metainfo_capsule'
    'import_preparsed_info_capsule'
)
typeset -ra required_swift_callback_patterns=(
    'torrentSwarmMetainfoParseCallback'
    'torrentSwarmMetainfoCapsuleReleaseCallback'
    'torrentExtensionHandshakeParseCallback'
    'torrentMetadataMessageParseCallback'
    'torrentPeerExchangeParseCallback'
    'torrentHTTPTrackerResponseParseCallback'
    'torrentDHTMessageParseCallback'
)
typeset -ra required_final_patterns=(
    "${required_bridge_patterns[@]}"
    "${required_swift_callback_patterns[@]}"
)

typeset engine_architecture_list
typeset archive_architecture_list
engine_architecture_list=$(/usr/bin/xcrun lipo -archs "$engine_executable")
archive_architecture_list=$(/usr/bin/xcrun lipo -archs "$libtorrent_archive")
typeset -a engine_architectures=(${=engine_architecture_list})
typeset -a archive_architectures=(${=archive_architecture_list})
(( ${#engine_architectures} > 0 )) \
    || fail "Engine executable has no inspectable architecture slices"
(( ${#archive_architectures} > 0 )) \
    || fail "Libtorrent archive has no inspectable architecture slices"

typeset -ra external_bencode_members=(
    torrent.cpp.o
    bt_peer_connection.cpp.o
    ut_metadata.cpp.o
    ut_pex.cpp.o
    http_tracker_connection.cpp.o
    dht_tracker.cpp.o
    find_data.cpp.o
    get_peers.cpp.o
    node.cpp.o
    rpc_manager.cpp.o
    sample_infohashes.cpp.o
    traversal_algorithm.cpp.o
)
typeset -r retired_external_reference_pattern='bdecode|bdecode_node|dict_find|verify_message|parse_tracker_response|load_torrent_(buffer|parsed)|parse_info_section_impl|parse_magnet_uri|on_extension_handshakeERKNS_12bdecode_node'
typeset -r retired_resume_metainfo_reference_pattern='torrent_infoC[12].*bdecode_node|load_torrent_(buffer|parsed)|parse_info_section_impl|parse_magnet_uri|parse_tracker_response'

extract_archive_member() {
    local -r archive_symbols=$1
    local -r member_name=$2
    local -r output=$3

    /usr/bin/awk -v heading="$member_name:" '
        $0 == heading {
            found = 1
            capture = 1
            next
        }
        capture && /^[^[:space:]].*\.o:$/ { exit }
        capture { print }
        END { if (!found) exit 2 }
    ' "$archive_symbols" >"$output" \
        || fail "Missing expected libtorrent archive member: $member_name"
}

typeset architecture pattern member member_output engine_symbols archive_symbols
for architecture in "${engine_architectures[@]}"; do
    (( ${archive_architectures[(Ie)$architecture]} > 0 )) \
        || fail "Libtorrent archive lacks the engine's $architecture slice"

    engine_symbols="$temporary_directory/engine-$architecture.txt"
    archive_symbols="$temporary_directory/libtorrent-$architecture.txt"
    /usr/bin/xcrun nm -m -arch "$architecture" "$engine_executable" \
        >"$engine_symbols"
    /usr/bin/xcrun nm -u -arch "$architecture" "$libtorrent_archive" \
        >"$archive_symbols"

    for pattern in "${retired_final_patterns[@]}"; do
        reject_match "$pattern" "$engine_symbols" \
            "Engine $architecture slice retains a uniquely retired parser route: $pattern"
    done
    for pattern in "${required_final_patterns[@]}"; do
        require_match "$pattern" "$engine_symbols" \
            "Engine $architecture slice lacks a required typed parser route: $pattern"
    done

    for member in "${external_bencode_members[@]}"; do
        member_output="$temporary_directory/$architecture-$member.txt"
        extract_archive_member "$archive_symbols" "$member" "$member_output"
        reject_match "$retired_external_reference_pattern" "$member_output" \
            "Libtorrent $architecture $member regains a retired external-input parser reference"
    done

    member_output="$temporary_directory/$architecture-read_resume_data.cpp.o.txt"
    extract_archive_member "$archive_symbols" read_resume_data.cpp.o "$member_output"
    reject_match "$retired_resume_metainfo_reference_pattern" "$member_output" \
        "Libtorrent $architecture resume reader regains a retired metainfo parser reference"
done

if [[ -n $bridge_object_directory ]]; then
    typeset -a bridge_objects=("$bridge_object_directory"/*.o(N))
    (( ${#bridge_objects} > 0 )) \
        || fail "Bridge object directory contains no object files: $bridge_object_directory"
    typeset -r bridge_symbols="$temporary_directory/bridge-objects.txt"
    /usr/bin/xcrun nm -m "${bridge_objects[@]}" >"$bridge_symbols"
    for pattern in "${retired_final_patterns[@]}"; do
        reject_match "$pattern" "$bridge_symbols" \
            "Production bridge objects retain a uniquely retired parser route: $pattern"
    done
    for pattern in "${required_bridge_patterns[@]}"; do
        require_match "$pattern" "$bridge_symbols" \
            "Production bridge objects lack a required typed parser route: $pattern"
    done
fi

print -r -- \
    "Verified typed parser reachability for ${(j:, :)engine_architectures}; retired external routes are absent."
