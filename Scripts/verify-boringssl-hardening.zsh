#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail typeset_silent

fail() {
    print -ru2 -- "$1"
    exit 1
}

(( $# == 3 )) \
    || fail "Usage: ${0:t} <patched-source-dir> <build-dir> <prefix>"

typeset -r root_dir=${0:A:h:h}
typeset -r source_dir=$1
typeset -r build_dir=$2
typeset -r prefix=$3
typeset -r patch_helper="$root_dir/Scripts/boringssl-patch-series.sh"
typeset -r compile_commands="$build_dir/compile_commands.json"
typeset -r crypto_archive="$prefix/lib/libcrypto.a"
typeset -r ssl_archive="$prefix/lib/libssl.a"
typeset symbols
typeset defined_typed_allocators
typeset imported_typed_allocators
typeset -i compile_count
typeset -i typed_count
typeset -i pac_count

[[ -x $patch_helper ]] || fail "Missing BoringSSL patch-series helper: $patch_helper"
[[ -f $compile_commands ]] || fail "Missing BoringSSL compile database: $compile_commands"
[[ -f $crypto_archive ]] || fail "Missing BoringSSL crypto archive: $crypto_archive"
[[ -f $ssl_archive ]] || fail "Missing BoringSSL TLS archive: $ssl_archive"

"$patch_helper" verify "$source_dir"

compile_count=$(/usr/bin/grep -c '"file":' "$compile_commands")
typed_count=$(/usr/bin/grep -c \
    '"command":.*-ftyped-memory-operations-experimental' \
    "$compile_commands")
pac_count=$(/usr/bin/grep -c \
    '"command":.*-fptrauth-calls.*-fptrauth-auth-traps' \
    "$compile_commands")
(( compile_count > 0 )) || fail "BoringSSL compile database is empty"
(( typed_count == compile_count )) \
    || fail "BoringSSL was not compiled entirely with typed memory operations"
(( pac_count == compile_count )) \
    || fail "BoringSSL was not compiled entirely with authenticated indirect calls"

symbols=$(/usr/bin/xcrun nm -gU "$crypto_archive")
defined_typed_allocators=$(print -r -- "$symbols" \
    | /usr/bin/awk '$NF ~ /^_OPENSSL_(malloc|zalloc|calloc|realloc)_type$/ { print $NF }' \
    | /usr/bin/sort -u)
[[ $defined_typed_allocators == $'_OPENSSL_calloc_type\n_OPENSSL_malloc_type\n_OPENSSL_realloc_type\n_OPENSSL_zalloc_type' ]] \
    || fail "BoringSSL does not define the complete typed allocation override set"

symbols=$(/usr/bin/xcrun nm -u "$crypto_archive")
imported_typed_allocators=$(print -r -- "$symbols" \
    | /usr/bin/awk '$NF ~ /^_malloc_type_(free|malloc)$/ { print $NF }' \
    | /usr/bin/sort -u)
[[ $imported_typed_allocators == $'_malloc_type_free\n_malloc_type_malloc' ]] \
    || fail "BoringSSL does not use matched typed malloc/free entry points"
/usr/bin/grep -Fq \
    '::new (ptr) OpenSSLAllocationHeader{size, type_id};' \
    "$source_dir/crypto/mem.cc" \
    || fail "BoringSSL does not explicitly begin its allocation-header lifetime"

for role in \
    boringssl.ssl.custom-verify \
    boringssl.ssl.protocol-method \
    boringssl.ssl.handshake \
    boringssl.evp-aead.method \
    boringssl.evp-pkey.method \
    boringssl.evp-md.digest \
    boringssl.bio.method \
    boringssl.ec-group.method \
    boringssl.ssl-record.cipher; do
    /usr/bin/grep -R -Fq -- "\"$role\"" \
        "$source_dir/crypto" "$source_dir/include" "$source_dir/ssl" \
        || fail "Missing targeted BoringSSL PAC role: $role"
done

print -r -- "Verified BoringSSL PAC, no-ASM, and typed allocation hardening"
