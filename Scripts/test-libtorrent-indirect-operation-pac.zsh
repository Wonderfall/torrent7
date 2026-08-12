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
typeset -r source_dir="$deps_dir/src/libtorrent"
typeset -r patch_helper="$root_dir/Scripts/libtorrent-patch-series.sh"
typeset -r test_source="$root_dir/Tests/DependencyHardening/LibtorrentIndirectOperationPACTests.cpp"
typeset -r cxx=$(/usr/bin/xcrun --find clang++)
typeset -r sdk_path=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
typeset temporary_directory
typeset -a profile_defines=()
typeset -a sanitizer_flags=()

case ${SANITIZER_PROFILE:-} in
    "") ;;
    address)
        profile_defines=(-DTORRENT_USE_ASSERTS=1)
        sanitizer_flags=(
            -fsanitize=address,undefined
            -fno-sanitize-recover=undefined
        )
        ;;
    thread)
        profile_defines=(-DTORRENT_USE_ASSERTS=1)
        sanitizer_flags=(
            -fsanitize=thread,undefined
            -fno-sanitize-recover=undefined
        )
        ;;
    *) fail "SANITIZER_PROFILE must be address or thread" ;;
esac

if [[ ${SKIP_BUILD_DEPS:-0} != 1 ]]; then
    "$root_dir/Scripts/build-deps.zsh"
fi

[[ "$target_arch" == arm64e ]] \
    || fail "libtorrent indirect-operation PAC tests require TARGET_ARCH=arm64e"
[[ -x "$patch_helper" ]] || fail "Missing libtorrent patch-series helper: $patch_helper"
[[ -f "$test_source" ]] || fail "Missing libtorrent PAC test source: $test_source"
[[ -f "$deps_prefix/lib/libtorrent-rasterbar.a" ]] \
    || fail "Missing installed libtorrent archive: $deps_prefix/lib/libtorrent-rasterbar.a"

"$patch_helper" verify "$source_dir"

temporary_directory=$(/usr/bin/mktemp -d)
trap 'rm -rf -- "$temporary_directory"' EXIT INT TERM

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
    -fno-builtin-memcpy
    -fptrauth-calls
    -fptrauth-auth-traps
    -DTORRENT_ABI_VERSION=100
    -DTORRENT_USE_I2P=0
    -DTORRENT_USE_RTC=0
    -DTORRENT_USE_OPENSSL
    -DTORRENT_USE_LIBCRYPTO
    -isystem "$deps_prefix/include"
    -isystem "$boost_prefix/include"
    "${profile_defines[@]}"
)
typeset -ar linker_flags=(
    "$deps_prefix/lib/libtorrent-rasterbar.a"
    "$deps_prefix/lib/libssl.a"
    "$deps_prefix/lib/libcrypto.a"
    -framework CoreFoundation
    -framework SystemConfiguration
)

"$cxx" "${compiler_flags[@]}" "${sanitizer_flags[@]}" \
    "$test_source" "${linker_flags[@]}" \
    -o "$temporary_directory/libtorrent-indirect-operation-pac-tests"
"$temporary_directory/libtorrent-indirect-operation-pac-tests"

"$cxx" "${compiler_flags[@]}" -S -emit-llvm "$test_source" \
    -o "$temporary_directory/libtorrent-indirect-operation-pac.ll"
"$cxx" "${compiler_flags[@]}" -S "$test_source" \
    -o "$temporary_directory/libtorrent-indirect-operation-pac.s"

extract_ir_function() {
    local name=$1
    local output=$2
    /usr/bin/awk -v symbol="@$name(" '
        index($0, "define ") == 1 && index($0, symbol) != 0 { capture = 1 }
        capture { print }
        capture && /^}/ { exit }
    ' "$temporary_directory/libtorrent-indirect-operation-pac.ll" >"$output"
    [[ -s "$output" ]] || fail "Missing LLVM IR for $name"
}

extract_assembly_function() {
    local name=$1
    local output=$2
    /usr/bin/awk -v symbol="_$name:" '
        index($0, symbol) == 1 { capture = 1 }
        capture { print }
        capture && /; -- End function/ { exit }
    ' "$temporary_directory/libtorrent-indirect-operation-pac.s" >"$output"
    [[ -s "$output" ]] || fail "Missing assembly for $name"
}

verify_ir_diversification() {
    local name=$1
    local input=$2
    local address_value
    local blend_line
    local blend_address
    local blend_result
    local discriminator

    address_value=$(/usr/bin/sed -nE \
        's/^[[:space:]]*(%[[:alnum:].]+) = ptrtoint ptr .*$/\1/p' "$input")
    [[ -n "$address_value" && "$address_value" != *$'\n'* ]] \
        || fail "$name does not derive one PAC modifier from its callback field address"

    blend_line=$(/usr/bin/grep '@llvm\.ptrauth\.blend' "$input" || true)
    [[ -n "$blend_line" && "$blend_line" != *$'\n'* ]] \
        || fail "$name does not contain exactly one address-and-role PAC blend"
    blend_result=$(print -r -- "$blend_line" \
        | /usr/bin/sed -nE 's/^[[:space:]]*(%[[:alnum:].]+) = .*$/\1/p')
    blend_address=$(print -r -- "$blend_line" \
        | /usr/bin/sed -nE \
            's/.*@llvm\.ptrauth\.blend\(i64 (%[[:alnum:].]+), i64 [0-9]+\).*/\1/p')
    discriminator=$(print -r -- "$blend_line" \
        | /usr/bin/sed -nE \
            's/.*@llvm\.ptrauth\.blend\(i64 %[[:alnum:].]+, i64 ([0-9]+)\).*/\1/p')

    [[ "$blend_address" == "$address_value" ]] \
        || fail "$name PAC blend is not bound to the callback field address"
    [[ -n "$discriminator" && "$discriminator" != 0 ]] \
        || fail "$name PAC blend has no role discriminator"
    /usr/bin/grep -Fq -- "\"ptrauth\"(i32 0, i64 $blend_result)" "$input" \
        || fail "$name indirect call does not authenticate with the blended modifier"
    REPLY=$discriminator
}

typeset destructor_ir="$temporary_directory/destructor.ll"
typeset move_ir="$temporary_directory/move.ll"
typeset destructor_assembly="$temporary_directory/destructor.s"
typeset move_assembly="$temporary_directory/move.s"
extract_ir_function torrent7_invoke_chained_buffer_destructor "$destructor_ir"
extract_ir_function torrent7_invoke_heterogeneous_queue_move "$move_ir"
extract_assembly_function torrent7_invoke_chained_buffer_destructor "$destructor_assembly"
extract_assembly_function torrent7_invoke_heterogeneous_queue_move "$move_assembly"

verify_ir_diversification chained-buffer.destruct-holder "$destructor_ir"
typeset -r destructor_discriminator=$REPLY
verify_ir_diversification heterogeneous-queue.move "$move_ir"
typeset -r move_discriminator=$REPLY
[[ "$destructor_discriminator" != "$move_discriminator" ]] \
    || fail "libtorrent destructor and move callbacks share a PAC role discriminator"

for assembly in "$destructor_assembly" "$move_assembly"; do
    /usr/bin/grep -Eq '[[:space:]](braa|blraa)[[:space:]]' "$assembly" \
        || fail "Targeted libtorrent callback does not use diversified authenticated branch codegen"
    if /usr/bin/grep -Eq '[[:space:]](braaz|blraaz)[[:space:]]' "$assembly"; then
        fail "Targeted libtorrent callback fell back to a zero-discriminator authenticated branch"
    fi
done

print -r -- "libtorrent indirect-operation PAC codegen and replay tests passed"
