#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail typeset_silent

fail() {
    print -ru2 -- "$1"
    exit 1
}

typeset -r root_dir=${0:A:h:h}
typeset -r target_arch=${TARGET_ARCH:-arm64e}
typeset deps_profile=$target_arch
if [[ ${SANITIZER_DIAGNOSTICS:-0} == "1" ]]; then
    deps_profile+="-diagnostics"
fi
typeset -r deps_dir=${DEPS_DIR:-$root_dir/.build/deps/$deps_profile}
typeset -r source_dir="$deps_dir/src/libtorrent"
typeset -r build_dir="$deps_dir/build/libtorrent"
typeset -r patch_helper="$root_dir/Scripts/libtorrent-patch-series.sh"
typeset -ra test_targets=(
    test_enum_net
    test_file
    test_http_connection
    test_http_parser
    test_storage
    test_web_seed_redirect
)
typeset restore_configuration=0

restore_build_configuration() {
    if (( restore_configuration )); then
        cmake -S "$source_dir" -B "$build_dir" -Dbuild_tests=OFF >/dev/null || true
    fi
}
trap restore_build_configuration EXIT

cd -- "$root_dir"

if [[ ${SKIP_BUILD_DEPS:-0} != "1" ]]; then
    "$root_dir/Scripts/build-deps.zsh"
fi

[[ -f "$build_dir/CMakeCache.txt" ]] \
    || fail "Missing configured libtorrent build: $build_dir"
"$patch_helper" verify "$source_dir"

restore_configuration=1
cmake -S "$source_dir" -B "$build_dir" -Dbuild_tests=ON
cmake --build "$build_dir" \
    --target "${test_targets[@]}" \
    --parallel "${JOBS:-$(sysctl -n hw.ncpu)}"
cmake -S "$source_dir" -B "$build_dir" -Dbuild_tests=OFF >/dev/null
restore_configuration=0

(
    cd -- "$build_dir/test"
    ./test_enum_net --no-redirect \
        "$source_dir/test/test_enum_net.cpp.is_global_addresses"
    ./test_enum_net --no-redirect \
        "$source_dir/test/test_enum_net.cpp.nat64_prefix_discovery"
    ./test_enum_net --no-redirect \
        "$source_dir/test/test_enum_net.cpp.nat64_discovery_fails_closed_on_malformed_answers"
    ./test_http_connection --no-redirect \
        "$source_dir/test/test_http_connection.cpp.no_proxy_ssl"
    ./test_http_parser --no-redirect \
        "$source_dir/test/test_http_parser.cpp.http_parser"
    ./test_web_seed_redirect --no-redirect \
        "$source_dir/test/test_web_seed_redirect.cpp.web_seed_proxy_request_target_uses_vetted_endpoint"
    ./test_web_seed_redirect --no-redirect \
        "$source_dir/test/test_web_seed_redirect.cpp.web_seed_proxy_request_uses_vetted_endpoint"
    ./test_web_seed_redirect --no-redirect \
        "$source_dir/test/test_web_seed_redirect.cpp.web_seed_https_redirect_downgrade"
    ./test_web_seed_redirect --no-redirect \
        "$source_dir/test/test_web_seed_redirect.cpp.web_seed_ssrf_blocks_non_global_endpoint"
    ./test_web_seed_redirect --no-redirect \
        "$source_dir/test/test_web_seed_redirect.cpp.web_seed_ssrf_resolves_socks_hostname_locally"
    ./test_web_seed_redirect --no-redirect \
        "$source_dir/test/test_web_seed_redirect.cpp.web_seed_numeric_host_honors_ip_filter_with_socks_dns"
    ./test_file --no-redirect \
        "$source_dir/test/test_file.cpp.confined_filesystem_operations"
    ./test_storage --no-redirect \
        "$source_dir/test/test_storage.cpp.confined_hard_link_write_pread"
    ./test_storage --no-redirect \
        "$source_dir/test/test_storage.cpp.confined_hard_link_write_mmap"
)
