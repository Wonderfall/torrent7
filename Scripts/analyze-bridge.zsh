#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

fail() {
    print -ru2 -- "$1"
    exit 1
}

typeset -r root_dir=${0:A:h:h}
typeset -r homebrew_prefix=${HOMEBREW_PREFIX:-/opt/homebrew}
typeset -r deps_prefix=${DEPS_PREFIX:-$root_dir/.build/deps/arm64e/prefix}
typeset -r boost_prefix=${BOOST_PREFIX:-$deps_prefix}
typeset -r boringssl_prefix=${BORINGSSL_PREFIX:-$deps_prefix}
typeset -r native_deps_build_id=$("$root_dir/Scripts/native-deps-build-id.zsh")
typeset -r libtorrent_source=${LIBTORRENT_SOURCE_DIR:-${deps_prefix:h}/src/libtorrent}
typeset -r libtorrent_patch_helper="$root_dir/Scripts/libtorrent-patch-series.sh"
typeset clang_tidy=${CLANG_TIDY:-$homebrew_prefix/opt/llvm/bin/clang-tidy}
typeset -r ripgrep=${commands[rg]:-}

[[ -n $ripgrep && -x $ripgrep ]] || fail "Missing ripgrep."

# Retired untrusted-input parsers may remain in tests as compatibility oracles,
# but no production source may make them reachable again.
typeset -a retired_parser_symbols=(
    "TorrentClientAddTorrentFileData"
    "load_torrent_buffer"
    "parse_magnet_uri"
)
for symbol in "${retired_parser_symbols[@]}"; do
    if "$ripgrep" -n --fixed-strings \
        --glob '*.cpp' \
        --glob '*.hpp' \
        --glob '*.h' \
        --glob '*.swift' \
        "$symbol" \
        "$root_dir/Sources"; then
        fail "Retired native parser route is reachable from production sources: $symbol"
    fi
done

[[ -d "$libtorrent_source/.git" ]] \
    || fail "Missing patched libtorrent source: $libtorrent_source"
"$libtorrent_patch_helper" verify "$libtorrent_source"
typeset -a retired_swarm_metadata_patterns=(
    "bdecode(metadata_buf"
    "make_shared<torrent_info>(metadata"
)
for pattern in "${retired_swarm_metadata_patterns[@]}"; do
    if "$ripgrep" -n --fixed-strings "$pattern" "$libtorrent_source/src/torrent.cpp"; then
        fail "Retired native swarm metadata parser route is reachable: $pattern"
    fi
done
"$ripgrep" -q --fixed-strings \
    "m_swarm_metadata_parser->parse(metadata_buf, ec)" \
    "$libtorrent_source/src/torrent.cpp" \
    || fail "Patched libtorrent does not require the external swarm metadata parser"
"$ripgrep" -q -U \
    'if \(m_swarm_metadata_parser\)\s+info = m_swarm_metadata_parser->parse\(metadata_buf, ec\);\s+else\s+ec = errors::invalid_swarm_metadata;' \
    "$libtorrent_source/src/torrent.cpp" \
    || fail "Patched libtorrent must fail closed when the swarm metadata parser is absent"

typeset -r peer_handshake_source="$libtorrent_source/src/bt_peer_connection.cpp"
typeset -r metadata_extension_source="$libtorrent_source/src/ut_metadata.cpp"
typeset -r pex_extension_source="$libtorrent_source/src/ut_pex.cpp"
if "$ripgrep" -n --fixed-strings \
    "bdecode(recv_buffer.subspan(2)" "$peer_handshake_source"; then
    fail "Retired native extension-handshake parser route is reachable"
fi
if "$ripgrep" -n --fixed-strings "bdecode(body" "$metadata_extension_source"; then
    fail "Retired native ut_metadata parser route is reachable"
fi
if "$ripgrep" -n --fixed-strings \
    "bdecode(body.begin(), body.end(), pex_msg" "$pex_extension_source"; then
    fail "Retired native ut_pex parser route is reachable"
fi
for source in "$metadata_extension_source" "$pex_extension_source"; do
    if "$ripgrep" -n --fixed-strings \
        "on_extension_handshake(bdecode_node const&" "$source"; then
        fail "Retired plugin extension-handshake parser route is reachable: $source"
    fi
done
"$ripgrep" -q --fixed-strings \
    "parse_extension_handshake(recv_buffer.subspan(2)" "$peer_handshake_source" \
    || fail "Patched libtorrent does not require the external extension-handshake parser"
"$ripgrep" -q --fixed-strings "parser == nullptr" "$peer_handshake_source" \
    || fail "Patched libtorrent must fail closed when the extension-handshake parser is absent"
"$ripgrep" -q --fixed-strings \
    "parse_ut_metadata(body" "$metadata_extension_source" \
    || fail "Patched libtorrent does not require the external ut_metadata parser"
"$ripgrep" -q --fixed-strings "parser == nullptr" "$metadata_extension_source" \
    || fail "Patched libtorrent must fail closed when the ut_metadata parser is absent"
"$ripgrep" -q --fixed-strings \
    "parse_ut_pex(body.first(length)" "$pex_extension_source" \
    || fail "Patched libtorrent does not require the external ut_pex parser"
"$ripgrep" -q --fixed-strings "parser == nullptr" "$pex_extension_source" \
    || fail "Patched libtorrent must fail closed when the ut_pex parser is absent"

typeset -r http_tracker_source="$libtorrent_source/src/http_tracker_connection.cpp"
typeset -r http_tracker_header="$libtorrent_source/include/libtorrent/aux_/http_tracker_connection.hpp"
for source in "$http_tracker_source" "$http_tracker_header"; do
    if "$ripgrep" -n "bdecode|parse_tracker_response" "$source"; then
        fail "Retired native HTTP tracker bencode parser route is reachable: $source"
    fi
done
[[ $("$ripgrep" --count-matches --fixed-strings \
    "response_parser->parse_http_response(data" "$http_tracker_source") == 1 ]] \
    || fail "Patched libtorrent must call the external HTTP tracker parser exactly once"
"$ripgrep" -q --fixed-strings "response_parser == nullptr" "$http_tracker_source" \
    || fail "Patched libtorrent must fail closed when the HTTP tracker parser is absent"
"$ripgrep" -q --fixed-strings \
    "tracker_response_parser::maximum_http_body_size" "$http_tracker_source" \
    || fail "Patched libtorrent does not cap the final HTTP tracker body before parsing"

typeset -r dht_tracker_source="$libtorrent_source/src/kademlia/dht_tracker.cpp"
typeset -r dht_parser_header="$libtorrent_source/include/libtorrent/aux_/dht_message_parser.hpp"
typeset -a typed_dht_consumer_sources=(
    "$dht_tracker_source"
    "$libtorrent_source/src/kademlia/find_data.cpp"
    "$libtorrent_source/src/kademlia/get_peers.cpp"
    "$libtorrent_source/src/kademlia/node.cpp"
    "$libtorrent_source/src/kademlia/rpc_manager.cpp"
    "$libtorrent_source/src/kademlia/sample_infohashes.cpp"
    "$libtorrent_source/src/kademlia/traversal_algorithm.cpp"
)
for source in "${typed_dht_consumer_sources[@]}"; do
    if "$ripgrep" -n "bdecode|bdecode_node|dict_find|verify_message" "$source"; then
        fail "Retired native KRPC parser route is reachable: $source"
    fi
done
[[ $("$ripgrep" --count-matches --fixed-strings \
    "m_message_parser->parse_message(buf" "$dht_tracker_source") == 1 ]] \
    || fail "Patched libtorrent must call the external DHT parser exactly once"
"$ripgrep" -q --fixed-strings \
    "m_message_parser == nullptr" "$dht_tracker_source" \
    || fail "Patched libtorrent must fail closed when the DHT parser is absent"
"$ripgrep" -q --fixed-strings \
    "static constexpr int maximum_message_size = 1500" "$dht_parser_header" \
    || fail "Patched libtorrent does not declare the bounded DHT datagram contract"
"$ripgrep" -q --fixed-strings \
    "find_data_observer::reply(m)" "$libtorrent_source/src/kademlia/get_item.cpp" \
    || fail "Patched libtorrent must not import arbitrary BEP 44 response values"

typeset -r resume_reader_source="$libtorrent_source/src/read_resume_data.cpp"
typeset -r resume_support_source="$root_dir/Sources/TorrentBridge/TorrentBridgeSupport.cpp"
typeset -r resume_restore_source="$root_dir/Sources/TorrentBridge/TorrentBridgeClientPersistence.cpp"
if "$ripgrep" -n --fixed-strings \
    "make_shared<torrent_info>(info" "$resume_reader_source"; then
    fail "Retired native resume metainfo parser route is reachable"
fi
"$ripgrep" -q --fixed-strings \
    'if (rd.dict_find("info"))' "$resume_reader_source" \
    || fail "Patched libtorrent must reject legacy nested resume metainfo"
"$ripgrep" -q --fixed-strings \
    "state.ti.reset()" "$resume_support_source" \
    || fail "Resume persistence must keep exact metainfo out of nested bencoding"
"$ripgrep" -q --fixed-strings \
    "kPreparsedInfoResumeKey" "$resume_support_source" \
    || fail "Resume persistence must store exact metainfo as an opaque byte string"
"$ripgrep" -q --fixed-strings \
    "preparsed_info_from_resume_data(*buffer)" "$resume_restore_source" \
    || fail "Resume restore must reject legacy metainfo before native resume decoding"
"$ripgrep" -q --fixed-strings \
    "swarm_metadata_parser->parse(" "$resume_restore_source" \
    || fail "Resume metainfo must return through the shared Swift InfoCore parser"

if [[ ! -x $clang_tidy ]]; then
    clang_tidy=${commands[clang-tidy]:-}
fi

[[ -n $clang_tidy && -x $clang_tidy ]] \
    || fail "Missing clang-tidy. Install LLVM with Homebrew or set CLANG_TIDY."

typeset -r sdk_path=$(xcrun --sdk macosx --show-sdk-path)

typeset -a checks=(
    "clang-analyzer-*"
    "bugprone-*"
    "cert-*"
    "cppcoreguidelines-*"
    "performance-*"
    "modernize-*"
    "darwin-*"
    "android-cloexec-open"
    "misc-confusable-identifiers"
    "misc-definitions-in-headers"
    "misc-header-include-cycle"
    "misc-misleading-bidirectional"
    "misc-misleading-identifier"
    "misc-misplaced-const"
    "misc-no-recursion"
    "misc-override-with-different-visibility"
    "misc-redundant-expression"
    "misc-uniqueptr-reset-release"
    "misc-use-internal-linkage"
    "portability-no-assembler"
    "portability-std-allocator-const"
    "readability-ambiguous-smartptr-reset-call"
    "readability-braces-around-statements"
    "readability-implicit-bool-conversion"
    "readability-inconsistent-declaration-parameter-name"
    "readability-inconsistent-ifelse-braces"
    "readability-math-missing-parentheses"
    "readability-misplaced-array-index"
    "readability-redundant-declaration"
    "readability-redundant-member-init"
    "readability-reference-to-constructed-temporary"
    "readability-string-compare"
    "readability-suspicious-call-argument"
    "readability-uniqueptr-delete-release"
    "-modernize-use-trailing-return-type"
    "-modernize-use-using"
    "-modernize-avoid-c-arrays"
    "-cppcoreguidelines-avoid-c-arrays"
    "-cppcoreguidelines-avoid-magic-numbers"
    "-cppcoreguidelines-pro-bounds-array-to-pointer-decay"
    "-cppcoreguidelines-pro-type-vararg"
    "-cppcoreguidelines-pro-type-union-access"
)
typeset -r checks_csv=${(j:,:)checks}

# Xcode's Apple clang is the production compiler, but it does not ship
# clang-tidy. Keep this command close to the bridge build flags while using
# upstream LLVM spellings where needed and omitting Apple-only typed allocator
# flags that upstream LLVM clang-tidy cannot parse.
typeset -a bridge_sources=("$root_dir"/Sources/TorrentBridge/*.cpp(N))
typeset -a compiler_args=(
    -std=c++23
    -target arm64e-apple-macosx26.0
    -isysroot "$sdk_path"
    -I "$root_dir/Sources/TorrentBridge/include"
    -isystem "$deps_prefix/include"
    -isystem "$boost_prefix/include"
    -isystem "$boringssl_prefix/include"
    -fexceptions
    -Wall
    -Wextra
    -Wconversion
    -Wimplicit-fallthrough
    -Wshadow
    -Wempty-body
    -Wbuiltin-memcpy-chk-size
    -Wformat
    -Wformat-security
    -Wformat-nonliteral
    -Warray-bounds
    -Warray-bounds-pointer-arithmetic
    -Wsuspicious-memaccess
    -Wsizeof-array-div
    -Wsizeof-pointer-div
    -Wreturn-stack-address
    -Wpointer-arith
    -Wpragma-pack
    -Wpragma-pack-suspicious-include
    -Wunreachable-code-loop-increment
    -Wnon-virtual-dtor
    -Wdangling
    -Wnull-dereference
    -Wcast-align
    -Wcast-qual
    -Wundef
    -Wthread-safety
    -Wthread-safety-negative
    -Wthread-safety-pointer
    -Walloca
    -Wvla
    -Wframe-larger-than=16384
    -Wunsafe-buffer-usage
    -Werror
    -fstack-protector-strong
    -U_FORTIFY_SOURCE
    -D_FORTIFY_SOURCE=3
    -fPIE
    -fapplication-extension
    -ftrivial-auto-var-init=zero
    -fno-delete-null-pointer-checks
    -fno-strict-aliasing
    -fzero-call-used-regs=used-gpr
    -fvisibility=hidden
    -fvisibility-inlines-hidden
    -faarch64-jump-table-hardening
    -fstrict-flex-arrays=3
    -mbranch-protection=bti
    -mharden-sls=all
    -fptrauth-returns
    -fptrauth-calls
    -Xclang -fptrauth-block-descriptor-pointers
    -Xclang -fptrauth-init-fini
    -Xclang -fptrauth-init-fini-address-discrimination
    -fptrauth-indirect-gotos
    -fptrauth-auth-traps
    -fptrauth-intrinsics
    -fptrauth-vtable-pointer-address-discrimination
    -fptrauth-vtable-pointer-type-discrimination
    -fsanitize=undefined,local-bounds,unsigned-integer-overflow,implicit-conversion
    -fsanitize-trap=undefined,local-bounds,unsigned-integer-overflow,implicit-conversion
    -fno-sanitize-recover=undefined,local-bounds,unsigned-integer-overflow,implicit-conversion
    -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE
    "-DTORRENT7_NATIVE_DEPS_BUILD_ID=\"torrent7-native-deps:$native_deps_build_id\""
    -DBOOST_ASIO_ENABLE_CANCELIO
    -DBOOST_ASIO_NO_DEPRECATED
    -DBOOST_SYSTEM_USE_UTF8
    -DTORRENT_ABI_VERSION=100
    -DTORRENT_USE_I2P=0
    -DTORRENT_USE_RTC=0
    -DTORRENT_DISABLE_LOGGING
    -DTORRENT_DISABLE_MUTABLE_TORRENTS
    -DTORRENT_DISABLE_STREAMING
    -DTORRENT_DISABLE_SUPERSEEDING
    -DTORRENT_DISABLE_SHARE_MODE
    -DTORRENT_DISABLE_PREDICTIVE_PIECES
    -DTORRENT_USE_OPENSSL
    -DTORRENT_USE_LIBCRYPTO
)

"$clang_tidy" --checks="$checks_csv" --verify-config

for source in "${bridge_sources[@]}"; do
    "$clang_tidy" "$source" \
        --quiet \
        --warnings-as-errors="*" \
        --header-filter="^$root_dir/Sources/TorrentBridge/.*" \
        --checks="$checks_csv" \
        -- \
        "${compiler_args[@]}"
done
