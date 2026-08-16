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
typeset -r source_dir="$deps_dir/src/boringssl"
typeset -r build_dir="$deps_dir/build/boringssl"
typeset -r patch_helper="$root_dir/Scripts/boringssl-patch-series.sh"
typeset -r verifier="$root_dir/Scripts/verify-boringssl-hardening.zsh"
typeset -r test_source="$root_dir/Tests/DependencyHardening/BoringSSLHardeningTests.cpp"
typeset -r cxx=$(/usr/bin/xcrun --find clang++)
typeset -r sdk_path=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
typeset temporary_directory
typeset -a sanitizer_flags=()

case ${SANITIZER_PROFILE:-} in
    "") ;;
    address)
        sanitizer_flags=(-fsanitize=address,undefined -fno-sanitize-recover=undefined)
        ;;
    thread)
        sanitizer_flags=(-fsanitize=thread,undefined -fno-sanitize-recover=undefined)
        ;;
    *) fail "SANITIZER_PROFILE must be address or thread" ;;
esac

if [[ ${SKIP_BUILD_DEPS:-0} != 1 ]]; then
    "$root_dir/Scripts/build-deps.zsh"
fi

[[ $target_arch == arm64e ]] \
    || fail "BoringSSL hardening tests require TARGET_ARCH=arm64e"
[[ -x $patch_helper ]] || fail "Missing BoringSSL patch-series helper: $patch_helper"
[[ -x $verifier ]] || fail "Missing BoringSSL hardening verifier: $verifier"
[[ -f $test_source ]] || fail "Missing BoringSSL hardening test source: $test_source"

"$patch_helper" verify "$source_dir"
"$verifier" "$source_dir" "$build_dir" "$deps_prefix"

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
    -ftyped-memory-operations-experimental
    -ftyped-cxx-new-delete
    -ftyped-cxx-delete
    -isystem "$source_dir"
    -isystem "$deps_prefix/include"
)
typeset -ar linker_flags=(
    "$deps_prefix/lib/libssl.a"
    "$deps_prefix/lib/libcrypto.a"
)

"$cxx" "${compiler_flags[@]}" "${sanitizer_flags[@]}" \
    "$test_source" "${linker_flags[@]}" \
    -o "$temporary_directory/boringssl-hardening-tests"
"$temporary_directory/boringssl-hardening-tests"

"$cxx" "${compiler_flags[@]}" -S -emit-llvm "$test_source" \
    -o "$temporary_directory/boringssl-hardening.ll"
"$cxx" "${compiler_flags[@]}" -S "$test_source" \
    -o "$temporary_directory/boringssl-hardening.s"

extract_ir_function() {
    local name=$1
    local output=$2
    /usr/bin/awk -v symbol="@$name(" '
        index($0, "define ") == 1 && index($0, symbol) != 0 { capture = 1 }
        capture { print }
        capture && /^}/ { exit }
    ' "$temporary_directory/boringssl-hardening.ll" >"$output"
    [[ -s $output ]] || fail "Missing LLVM IR for $name"
}

extract_assembly_function() {
    local name=$1
    local output=$2
    /usr/bin/awk -v symbol="_$name:" '
        index($0, symbol) == 1 { capture = 1 }
        capture { print }
        capture && /; -- End function/ { exit }
    ' "$temporary_directory/boringssl-hardening.s" >"$output"
    [[ -s $output ]] || fail "Missing assembly for $name"
}

typeset callback_ir="$temporary_directory/custom-verify.ll"
typeset method_ir="$temporary_directory/protocol-method.ll"
typeset callback_assembly="$temporary_directory/custom-verify.s"
typeset method_assembly="$temporary_directory/protocol-method.s"
extract_ir_function torrent7_invoke_boringssl_custom_verify "$callback_ir"
extract_ir_function torrent7_load_boringssl_protocol_method "$method_ir"
extract_assembly_function torrent7_invoke_boringssl_custom_verify "$callback_assembly"
extract_assembly_function torrent7_load_boringssl_protocol_method "$method_assembly"

/usr/bin/grep -Fq '@llvm.ptrauth.blend' "$callback_ir" \
    || fail "BoringSSL custom-verify callback lacks address-and-role PAC blending"
/usr/bin/grep -Fq '"ptrauth"(i32 0' "$callback_ir" \
    || fail "BoringSSL custom-verify callback does not use the function-pointer key"
/usr/bin/grep -Eq '[[:space:]](braa|blraa)[[:space:]]' "$callback_assembly" \
    || fail "BoringSSL custom-verify callback lacks a diversified authenticated branch"
if /usr/bin/grep -Eq '[[:space:]](braaz|blraaz)[[:space:]]' "$callback_assembly"; then
    fail "BoringSSL custom-verify callback fell back to a zero-discriminator branch"
fi

/usr/bin/grep -Fq '@llvm.ptrauth.blend' "$method_ir" \
    || fail "BoringSSL protocol method lacks address-and-role PAC blending"
/usr/bin/grep -Fq '@llvm.ptrauth.auth' "$method_ir" \
    || fail "BoringSSL protocol method is not authenticated on load"
/usr/bin/grep -Eq '[[:space:]]autdb[[:space:]]' "$method_assembly" \
    || fail "BoringSSL protocol method does not use the process-dependent data key"

typeset typed_a_ir="$temporary_directory/typed-a.ll"
typeset typed_b_ir="$temporary_directory/typed-b.ll"
typeset typed_a_descriptor
typeset typed_b_descriptor
extract_ir_function torrent7_new_boringssl_typed_a "$typed_a_ir"
extract_ir_function torrent7_new_boringssl_typed_b "$typed_b_ir"
typed_a_descriptor=$(/usr/bin/sed -nE \
    's/.*@OPENSSL_malloc_type\(i64 [^,]+, i64 ([^)]+)\).*/\1/p' "$typed_a_ir")
typed_b_descriptor=$(/usr/bin/sed -nE \
    's/.*@OPENSSL_malloc_type\(i64 [^,]+, i64 ([^)]+)\).*/\1/p' "$typed_b_ir")
[[ -n $typed_a_descriptor && -n $typed_b_descriptor ]] \
    || fail "BoringSSL typed allocations did not lower to typed override calls"
[[ $typed_a_descriptor != 0 && $typed_b_descriptor != 0 ]] \
    || fail "BoringSSL typed allocations use an empty semantic descriptor"
[[ $typed_a_descriptor != $typed_b_descriptor ]] \
    || fail "Distinct BoringSSL allocation types share one descriptor"

print -r -- "BoringSSL PAC replay, codegen, and typed allocation tests passed"
