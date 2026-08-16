#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

fail() {
    print -ru2 -- "$1"
    exit 1
}

typeset -r root_dir=${0:A:h:h}
typeset -r target_arch=${TARGET_ARCH:-arm64e}
typeset -r sanitizer_profile=${SANITIZER_PROFILE:-}
case $sanitizer_profile in
    ""|address|thread) ;;
    *) fail "SANITIZER_PROFILE must be address or thread" ;;
esac

typeset deps_profile=$target_arch
[[ -z $sanitizer_profile ]] || deps_profile+="-$sanitizer_profile"
typeset -r deps_dir=${DEPS_DIR:-$root_dir/.build/deps/$deps_profile}
typeset -r archive=${1:-$deps_dir/prefix/lib/libtorrent-rasterbar.a}
[[ -f $archive && ! -L $archive ]] || fail "Missing libtorrent archive: $archive"

typeset -r symbols=$(/usr/bin/nm -u -- "$archive" | /usr/bin/awk '{ print $NF }' | /usr/bin/sort -u)
typeset required
for required in \
    _TLS_with_buffers_method \
    _SSL_CTX_set_custom_verify \
    _SSL_CTX_set1_buffer_pool \
    _SSL_get0_peer_certificates \
    _SecCertificateCreateWithData \
    _SecPolicyCreateSSL \
    _SecTrustCreateWithCertificates \
    _SecTrustSetNetworkFetchAllowed \
    _SecTrustEvaluateWithError; do
    print -r -- "$symbols" | /usr/bin/grep -Fx -- "$required" >/dev/null \
        || fail "Missing BoringSSL TLS hardening symbol in libtorrent: $required"
done

typeset forbidden
for forbidden in \
    _TLS_method \
    _TLS_client_method \
    _SSL_CTX_set_verify \
    _SSL_set_verify; do
    if print -r -- "$symbols" | /usr/bin/grep -Fx -- "$forbidden" >/dev/null; then
        fail "Legacy TLS/X.509 path remains reachable from libtorrent: $forbidden"
    fi
done

typeset -r legacy_symbols=$(print -r -- "$symbols" \
    | /usr/bin/grep -E '(^_X509|^_d2i_X509|^_i2d_X509|^_ASN1_|^_PEM_)' || true)
[[ -z $legacy_symbols ]] \
    || fail "Legacy X.509/ASN.1/PEM symbols remain reachable from libtorrent:\n$legacy_symbols"

print -r -- "Verified buffer-only BoringSSL TLS with macOS system trust: $archive"
