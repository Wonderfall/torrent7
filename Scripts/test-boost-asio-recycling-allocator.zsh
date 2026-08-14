#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail typeset_silent

fail() {
    print -ru2 -- "$1"
    exit 1
}

typeset -r root_dir=${0:A:h:h}
typeset -r target_arch=${TARGET_ARCH:-arm64e}
typeset -r deployment_target=${MACOSX_DEPLOYMENT_TARGET:-26.0}
typeset -r target_triple="$target_arch-apple-macosx$deployment_target"
typeset -r deps_profile=${SANITIZER_PROFILE:+$target_arch-$SANITIZER_PROFILE}
typeset -r resolved_profile=${deps_profile:-$target_arch}
typeset -r deps_dir=${DEPS_DIR:-$root_dir/.build/deps/$resolved_profile}
typeset -r deps_prefix=${DEPS_PREFIX:-$deps_dir/prefix}
typeset -r boost_prefix=${BOOST_PREFIX:-$deps_prefix}
typeset -r source_cache_dir=${SOURCE_CACHE_DIR:-$root_dir/.build/deps/source-cache}
typeset -r boost_source_root=${BOOST_SOURCE_ROOT:-$source_cache_dir/boost}
typeset -r boost_source=${BOOST_SOURCE:-$boost_source_root/boost_1_92_0}
typeset -r patch_helper="$root_dir/Scripts/boost-patch-series.sh"
typeset -r verifier="$root_dir/Scripts/verify-boost-asio-recycling-allocator.zsh"
typeset -r test_source="$root_dir/Tests/DependencyHardening/BoostAsioRecyclingAllocatorTests.cpp"
typeset -r cxx=$(/usr/bin/xcrun --find clang++)
typeset -r sdk_path=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
typeset temporary_directory

if [[ ${SKIP_BUILD_DEPS:-0} != 1 ]]; then
    "$root_dir/Scripts/build-deps.zsh"
fi

[[ $target_arch == arm64e ]] \
    || fail "Boost.Asio recycler tests require TARGET_ARCH=arm64e"
[[ -x $patch_helper ]] || fail "Missing Boost patch-series helper: $patch_helper"
[[ -x $verifier ]] || fail "Missing Boost.Asio recycler verifier: $verifier"
[[ -f $test_source ]] || fail "Missing Boost.Asio recycler test source: $test_source"
[[ -d $boost_prefix/include/boost ]] \
    || fail "Missing installed Boost headers: $boost_prefix/include/boost"

"$patch_helper" verify "$boost_source"
"$patch_helper" verify "$boost_prefix/include"

temporary_directory=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf -- "$temporary_directory"' EXIT INT TERM
typeset -r executable="$temporary_directory/boost-asio-recycling-allocator-tests"
typeset -ar compiler_flags=(
    -target "$target_triple"
    -isysroot "$sdk_path"
    -mmacosx-version-min="$deployment_target"
    -std=c++23
    -O2
    -Wall
    -Wextra
    -Wpedantic
    -Werror
    -fstack-protector-strong
    -ftyped-memory-operations-experimental
    -isystem "$boost_prefix/include"
)

"$cxx" "${compiler_flags[@]}" "$test_source" -o "$executable"
"$executable"
"$verifier" "$executable"
