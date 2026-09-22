#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

# Audit complete linker output. Stripped symbols cannot prove absent code or
# identify the individual functions checked for pointer authentication/traps.
typeset -r root_dir=${0:A:h:h}
fail() { print -ru2 -- "$1"; exit 1; }
(( $# == 3 )) || fail "Usage: verify-app-code.zsh APP_EXECUTABLE ENGINE_EXECUTABLE SANITIZER"
typeset -r executable=$1 engine_extension_executable=$2 expected_sanitizer=$3
case $expected_sanitizer in
    none|address|thread) ;;
    *) fail "Unexpected sanitizer profile: $expected_sanitizer" ;;
esac
typeset parser_deps_prefix=${DEPS_PREFIX:-}
if [[ -z $parser_deps_prefix ]]; then
    case $expected_sanitizer in
        none) parser_deps_prefix="$root_dir/.build/deps/arm64e/prefix" ;;
        address) parser_deps_prefix="$root_dir/.build/deps/arm64e-address/prefix" ;;
        thread) parser_deps_prefix="$root_dir/.build/deps/arm64e-thread/prefix" ;;
    esac
fi
typeset -r libtorrent_archive="$parser_deps_prefix/lib/libtorrent-rasterbar.a"
typeset -r boost_recycler_verifier="$root_dir/Scripts/verify-boost-asio-recycling-allocator.zsh"
typeset -r parser_reachability_verifier="$root_dir/Scripts/verify-parser-reachability.zsh"
typeset -r bridge_object_directory=${TORRENT7_BRIDGE_OBJECT_DIR:-}
typeset -r temporary_dir=$(/usr/bin/mktemp -d)
typeset -r app_arch_output="$temporary_dir/app-arch.txt"
typeset -r app_header_output="$temporary_dir/app-header.txt"
typeset -r app_text_output="$temporary_dir/app-text.txt"
typeset -r app_symbol_output="$temporary_dir/app-symbols.txt"
typeset -r engine_arch_output="$temporary_dir/engine-arch.txt"
typeset -r engine_header_output="$temporary_dir/engine-header.txt"
typeset -r engine_text_output="$temporary_dir/engine-text.txt"
typeset -r engine_symbol_output="$temporary_dir/engine-symbols.txt"
typeset -r engine_strings_output="$temporary_dir/engine-strings.txt"
trap '/bin/rm -rf -- "$temporary_dir"' EXIT

require_match() {
    local -r pattern=$1
    local -r file=$2
    local -r message=$3

    /usr/bin/grep -Eq -- "$pattern" "$file" || fail "$message"
}

reject_match() {
    local -r pattern=$1
    local -r file=$2
    local -r message=$3

    if /usr/bin/grep -Eq -- "$pattern" "$file"; then
        fail "$message"
    fi
}

extract_disassembly_function() {
    local -r input=$1
    local -r symbol=$2
    local -r output=$3

    /usr/bin/awk -v label="$symbol:" '
        index($0, label) == 1 { capture = 1; next }
        capture && /^[^[:space:]][^:]*:$/ { exit }
        capture { print }
    ' "$input" >"$output"
    [[ -s "$output" ]] || fail "Missing targeted product function: $symbol"
}

verify_nearby_pac_instruction() {
    local -r label=$1
    local -r input=$2
    local -r discriminator=$3
    local -r instruction_kind=$4
    local -r distance=$5

    /usr/bin/awk -v discriminator="#$discriminator" \
        -v instruction_kind="$instruction_kind" -v distance="$distance" '
        /movk[[:space:]]+x[0-9]+,/ && index($0, discriminator) {
            modifier = $3
            sub(/,$/, "", modifier)
            remaining = distance
        }
        remaining > 0 && instruction_kind == "callback" \
            && /[[:space:]](braa|blraa)[[:space:]]/ \
            && index($0, ", " modifier) { found = 1 }
        remaining > 0 && instruction_kind == "data" \
            && /[[:space:]]autdb[[:space:]]/ \
            && index($0, ", " modifier) { found = 1 }
        remaining > 0 && instruction_kind == "callback-signing" \
            && /[[:space:]]pacia[[:space:]]/ \
            && index($0, ", " modifier) { found = 1 }
        remaining > 0 && instruction_kind == "data-signing" \
            && /[[:space:]]pacdb[[:space:]]/ \
            && index($0, ", " modifier) { found = 1 }
        remaining > 0 { remaining-- }
        END { exit !found }
    ' "$input" || fail "$label lacks targeted PAC role $discriminator"
}

require_literal_match() {
    local -r value=$1
    local -r file=$2
    local -r message=$3

    /usr/bin/grep -Fq -- "$value" "$file" || fail "$message"
}

verify_code_hardening() {
    local -r label=$1 arch_file=$2 header_file=$3 text_file=$4 requires_bti=$5
    require_match "architecture: arm64e" "$arch_file" "$label executable is not arm64e"
    require_match "[[:space:]]PIE([[:space:]]|$)" "$header_file" \
        "$label executable is not position-independent"
    require_match "pacibsp|retab|autd|braa|blraa" "$text_file" \
        "$label executable has no expected PAC instructions"
    if [[ $requires_bti == true ]]; then
        require_match "[[:space:]]bti[[:space:]]+[cj]" "$text_file" \
            "$label executable has no expected BTI landing-pad instructions"
    fi
}

for binary in "$executable" "$engine_extension_executable"; do
    [[ -f $binary && ! -L $binary ]] || fail "Missing or linked audit executable: $binary"
    /usr/bin/xcrun nm -ap "$binary" > "$temporary_dir/unstripped-symbols.txt"
    require_match '[[:space:]]t[[:space:]]' "$temporary_dir/unstripped-symbols.txt" \
        "Code audits require unstripped local function symbols: $binary"
done

/usr/bin/xcrun lipo -info "$executable" >"$app_arch_output"
/usr/bin/xcrun lipo -info "$engine_extension_executable" >"$engine_arch_output"
/usr/bin/xcrun otool -hv "$executable" >"$app_header_output"
/usr/bin/xcrun otool -hv "$engine_extension_executable" >"$engine_header_output"
/usr/bin/xcrun otool -tvV "$executable" >"$app_text_output"
/usr/bin/xcrun otool -tvV "$engine_extension_executable" >"$engine_text_output"
/usr/bin/xcrun nm -m "$executable" >"$app_symbol_output"
/usr/bin/xcrun nm -m "$engine_extension_executable" >"$engine_symbol_output"

typeset tls_symbol
for tls_symbol in \
    _TLS_with_buffers_method \
    _SSL_CTX_set_custom_verify \
    _SSL_CTX_set1_buffer_pool \
    _SSL_get0_peer_certificates \
    _SecCertificateCreateWithData \
    _SecPolicyCreateSSL \
    _SecTrustCreateWithCertificates \
    _SecTrustSetNetworkFetchAllowed \
    _SecTrustEvaluateWithError; do
    require_match "[[:space:]]${tls_symbol}([[:space:]]|$)" "$engine_symbol_output" \
        "Engine extension lacks required buffer-only TLS symbol: $tls_symbol"
done
reject_match "[[:space:]]_(TLS_method|TLS_client_method|SSL_CTX_set_verify|SSL_set_verify)([[:space:]]|$)" \
    "$engine_symbol_output" \
    "Engine extension retains a legacy BoringSSL TLS/X.509 entry point"
reject_match "[[:space:]]_(X509|d2i_X509|i2d_X509|ASN1_|PEM_)[^[:space:]]*([[:space:]]|$)" \
    "$engine_symbol_output" \
    "Engine extension retains BoringSSL X.509/ASN.1/PEM code"
reject_match "parse_magnet_uri" "$engine_symbol_output" \
    "Engine extension retains libtorrent's retired raw magnet parser"
reject_match "TorrentClientAddMagnet" "$engine_symbol_output" \
    "Engine extension retains the retired raw magnet bridge entry point"
[[ -x $parser_reachability_verifier ]] \
    || fail "Missing parser-reachability verifier: $parser_reachability_verifier"
typeset -a parser_reachability_arguments=(
    "$engine_extension_executable"
    "$libtorrent_archive"
)
if [[ -n $bridge_object_directory ]]; then
    parser_reachability_arguments+=("$bridge_object_directory")
fi
"$parser_reachability_verifier" "${parser_reachability_arguments[@]}"
/usr/bin/strings -a "$engine_extension_executable" >"$engine_strings_output"

# Swift arm64e emits PAC but has no BTI codegen switch; BTI applies to the native engine.
verify_code_hardening "App" "$app_arch_output" "$app_header_output" "$app_text_output" false
verify_code_hardening "Engine extension" "$engine_arch_output" "$engine_header_output" "$engine_text_output" true
require_match "[[:space:]]pacdb[[:space:]]" "$engine_text_output" \
    "Engine extension has no authenticated data-pointer signing"
require_match "[[:space:]]autdb[[:space:]]" "$engine_text_output" \
    "Engine extension has no authenticated data-pointer use"
typeset -r wake_pac_output="$temporary_dir/wake-pac.txt"
extract_disassembly_function \
    "$engine_text_output" \
    "__ZN14torrent_bridge8internal14TTorrentClient20invoke_wake_callbackERKNS0_22WakeCallbackInvocationE" \
    "$wake_pac_output"
verify_nearby_pac_instruction wake.callback "$wake_pac_output" 0x9cc0 callback 40
verify_nearby_pac_instruction wake.context "$wake_pac_output" 0x8cdb data 4

typeset -r payload_retain_pac_output="$temporary_dir/payload-retain-pac.txt"
typeset -r payload_release_pac_output="$temporary_dir/payload-release-pac.txt"
typeset -r payload_open_pac_output="$temporary_dir/payload-open-pac.txt"
typeset -r payload_size_pac_output="$temporary_dir/payload-size-pac.txt"
extract_disassembly_function \
    "$engine_text_output" \
    "__ZN14torrent_bridge8internal20PayloadBrokerContextC2E30TTorrentPayloadBrokerCallbacks" \
    "$payload_retain_pac_output"
extract_disassembly_function \
    "$engine_text_output" \
    "__ZN14torrent_bridge8internal20PayloadBrokerContextD2Ev" \
    "$payload_release_pac_output"
extract_disassembly_function \
    "$engine_text_output" \
    "__ZNK14torrent_bridge8internal20PayloadBrokerContext12open_payloadERK25TTorrentStorageActivationN10libtorrent3aux14strong_typedefIiNS6_14file_index_tagEvEEbRN5boost6system10error_codeE" \
    "$payload_open_pac_output"
extract_disassembly_function \
    "$engine_text_output" \
    "__ZNK14torrent_bridge8internal20PayloadBrokerContext12payload_sizeERK25TTorrentStorageActivationN10libtorrent3aux14strong_typedefIiNS6_14file_index_tagEvEERN5boost6system10error_codeE" \
    "$payload_size_pac_output"
verify_nearby_pac_instruction \
    payload-broker.context "$payload_open_pac_output" 0x33e data 4
verify_nearby_pac_instruction \
    payload-broker.retain "$payload_retain_pac_output" 0x5c7 callback 160
verify_nearby_pac_instruction \
    payload-broker.release "$payload_release_pac_output" 0x26d6 callback 40
verify_nearby_pac_instruction \
    payload-broker.open "$payload_open_pac_output" 0x2285 callback 40
verify_nearby_pac_instruction \
    payload-broker.size "$payload_size_pac_output" 0x664f callback 40
verify_nearby_pac_instruction \
    asio.executor-function.complete "$engine_text_output" 0x9890 callback 4
verify_nearby_pac_instruction \
    asio.any-executor.execute "$engine_text_output" 0x4642 callback 4
verify_nearby_pac_instruction \
    asio.execution-context.service.destroy "$engine_text_output" 0x2a6 callback 4
verify_nearby_pac_instruction \
    asio.executor-function-view.complete "$engine_text_output" 0x8444 callback-signing 4
verify_nearby_pac_instruction \
    asio.executor-function-view.context "$engine_text_output" 0x5f88 data-signing 4
verify_nearby_pac_instruction \
    asio.executor-function.impl "$engine_text_output" 0xc4a3 data 4
verify_nearby_pac_instruction \
    asio.any-executor.object-fns "$engine_text_output" 0x8efa data 4
verify_nearby_pac_instruction \
    asio.any-executor.target "$engine_text_output" 0xeffa data 4
verify_nearby_pac_instruction \
    asio.any-executor.target-fns "$engine_text_output" 0x380f data 4
verify_nearby_pac_instruction \
    asio.any-executor.property-fns "$engine_text_output" 0xed97 data 4
typeset -r boringssl_verify_output="$temporary_dir/boringssl-verify-peer.txt"
typeset -r boringssl_handshake_output="$temporary_dir/boringssl-run-handshake.txt"
extract_disassembly_function \
    "$engine_text_output" \
    "__ZN4bssl20ssl_verify_peer_certEPNS_13SSL_HANDSHAKEE" \
    "$boringssl_verify_output"
verify_nearby_pac_instruction \
    boringssl.ssl.custom-verify "$boringssl_verify_output" 0x5b45 callback 4
extract_disassembly_function \
    "$engine_text_output" \
    "__ZN4bssl17ssl_run_handshakeEPNS_13SSL_HANDSHAKEEPb" \
    "$boringssl_handshake_output"
verify_nearby_pac_instruction \
    boringssl.ssl.protocol-method "$boringssl_handshake_output" 0xcc6f data 4
typeset native_deps_sanitizer_profile=$expected_sanitizer
[[ $native_deps_sanitizer_profile != none ]] || native_deps_sanitizer_profile=
typeset -r expected_native_deps_build_id=$(
    SANITIZER_PROFILE=$native_deps_sanitizer_profile \
        "$root_dir/Scripts/native-deps-build-id.zsh"
)
require_literal_match \
    "torrent7-native-deps:$expected_native_deps_build_id" \
    "$engine_strings_output" \
    "Engine extension does not match the current native dependencies"
if [[ $expected_sanitizer == none ]]; then
    require_match \
        $'[[:space:]]brk[[:space:]]+#0x55[0-9a-f]+' \
        "$boringssl_handshake_output" \
        "Engine extension lacks trap-only checks in BoringSSL handshake code"
    typeset -r libtorrent_trap_output="$temporary_dir/libtorrent-trap-only.txt"
    extract_disassembly_function \
        "$engine_text_output" \
        "__ZN10libtorrent3aux12session_impl13start_sessionEv" \
        "$libtorrent_trap_output"
    require_match \
        $'[[:space:]]brk[[:space:]]+#0x55[0-9a-f]+' \
        "$libtorrent_trap_output" \
        "Engine extension lacks trap-only checks in libtorrent session code"
    reject_match "___ubsan_handle_" "$engine_symbol_output" \
        "Engine extension unexpectedly depends on the UBSan runtime"
fi
require_match "_malloc_type_malloc" "$engine_symbol_output" \
    "Engine extension has no typed malloc symbol"
for typed_allocator in \
    _OPENSSL_malloc_type \
    _OPENSSL_zalloc_type \
    _OPENSSL_calloc_type \
    _OPENSSL_realloc_type \
    _malloc_type_free; do
    require_match "[[:space:]]${typed_allocator}([[:space:]]|$)" \
        "$engine_symbol_output" \
        "Engine extension lacks BoringSSL typed allocator symbol: $typed_allocator"
done
require_match "__ZnwmSt19__type_descriptor_t" "$engine_symbol_output" \
    "Engine extension has no typed C++ operator new symbol"
[[ -x $boost_recycler_verifier ]] \
    || fail "Missing Boost.Asio recycler verifier: $boost_recycler_verifier"
"$boost_recycler_verifier" "$engine_extension_executable"
require_match "[[:space:]]_NSExtensionMain" "$engine_symbol_output" \
    "Engine extension is not linked with the ExtensionKit process entry point"
reject_match "[[:space:]]_Torrent(Client|Bridge)|__ZN10libtorrent|libtorrent-rasterbar" \
    "$app_symbol_output" \
    "GUI executable still contains native torrent-engine symbols"
