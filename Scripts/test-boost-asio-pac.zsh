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
typeset -r test_source="$root_dir/Tests/DependencyHardening/BoostAsioOperationPACTests.cpp"
typeset -r cxx=$(/usr/bin/xcrun --find clang++)
typeset -r sdk_path=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
typeset temporary_directory

if [[ ${SKIP_BUILD_DEPS:-0} != 1 ]]; then
    "$root_dir/Scripts/build-deps.zsh"
fi

[[ "$target_arch" == arm64e ]] \
    || fail "Boost.Asio PAC tests require TARGET_ARCH=arm64e"
[[ -x "$patch_helper" ]] || fail "Missing Boost patch-series helper: $patch_helper"
[[ -f "$test_source" ]] || fail "Missing Boost.Asio PAC test source: $test_source"
[[ -d "$boost_prefix/include/boost" ]] \
    || fail "Missing installed Boost headers: $boost_prefix/include/boost"

"$patch_helper" verify "$boost_source"
"$patch_helper" verify "$boost_prefix/include"

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
    -isystem "$boost_prefix/include"
)

"$cxx" "${compiler_flags[@]}" "$test_source" \
    -o "$temporary_directory/boost-asio-operation-pac-tests"
"$temporary_directory/boost-asio-operation-pac-tests"
/usr/bin/xcrun otool -tvV \
    "$temporary_directory/boost-asio-operation-pac-tests" \
    >"$temporary_directory/boost-asio-operation-pac.disassembly"

"$cxx" "${compiler_flags[@]}" -S -emit-llvm "$test_source" \
    -o "$temporary_directory/boost-asio-operation-pac.ll"
"$cxx" "${compiler_flags[@]}" -S "$test_source" \
    -o "$temporary_directory/boost-asio-operation-pac.s"

extract_ir_function() {
    local name=$1
    local output=$2
    /usr/bin/awk -v symbol="@$name(" '
        index($0, "define ") == 1 && index($0, symbol) != 0 { capture = 1 }
        capture { print }
        capture && /^}/ { exit }
    ' "$temporary_directory/boost-asio-operation-pac.ll" >"$output"
    [[ -s "$output" ]] || fail "Missing LLVM IR for $name"
}

extract_assembly_function() {
    local name=$1
    local output=$2
    /usr/bin/awk -v symbol="_$name:" '
        index($0, symbol) == 1 { capture = 1 }
        capture { print }
        capture && /; -- End function/ { exit }
    ' "$temporary_directory/boost-asio-operation-pac.s" >"$output"
    [[ -s "$output" ]] || fail "Missing assembly for $name"
}

extract_linked_function() {
    local name=$1
    local output=$2
    /usr/bin/awk -v symbol="$name:" '
        $0 == symbol { capture = 1 }
        capture && $0 != symbol && $0 ~ /^_[^:]*:$/ { exit }
        capture { print }
    ' "$temporary_directory/boost-asio-operation-pac.disassembly" >"$output"
    [[ -s "$output" ]] || fail "Missing linked code for $name"
}

verify_linked_role() {
    local name=$1
    local discriminator=$2
    local input=$3
    /usr/bin/awk -v discriminator="#$discriminator" '
        /movk[[:space:]]+x[0-9]+,/ && index($0, discriminator) {
            modifier = $3
            sub(/,$/, "", modifier)
            remaining = 4
        }
        remaining > 0 && /[[:space:]](braa|blraa)[[:space:]]/ \
            && index($0, ", " modifier) { found = 1 }
        remaining > 0 { remaining-- }
        END { exit !found }
    ' "$input" || fail "$name does not use its pinned diversified PAC role"
}

verify_ir_diversification() {
    local name=$1
    local input=$2
    local address_value
    local blend_result
    local blend_line
    local blend_address
    local discriminator

    blend_result=$(/usr/bin/sed -nE \
        's/.*"ptrauth"\(i32 0, i64 (%[[:alnum:].]+)\).*/\1/p' "$input")
    [[ -n "$blend_result" && "$blend_result" != *$'\n'* ]] \
        || fail "$name does not use one authenticated callback modifier"
    blend_line=$(/usr/bin/grep -F "$blend_result =" "$input" \
        | /usr/bin/grep '@llvm\.ptrauth\.blend' || true)
    [[ -n "$blend_line" && "$blend_line" != *$'\n'* ]] \
        || fail "$name callback modifier is not address-and-role diversified"
    blend_address=$(print -r -- "$blend_line" \
        | /usr/bin/sed -nE \
            's/.*@llvm\.ptrauth\.blend\(i64 (%[[:alnum:].]+), i64 [0-9]+\).*/\1/p')
    discriminator=$(print -r -- "$blend_line" \
        | /usr/bin/sed -nE \
            's/.*@llvm\.ptrauth\.blend\(i64 %[[:alnum:].]+, i64 ([0-9]+)\).*/\1/p')

    address_value=$(/usr/bin/sed -nE \
        "s/^[[:space:]]*($blend_address) = ptrtoint ptr .*$/\\1/p" "$input")
    if [[ "$address_value" != "$blend_address" ]]; then
        address_value=$(/usr/bin/sed -nE \
            "s/^[[:space:]]*($blend_address) = .*@llvm\\.ptrauth\\.auth\\(.*$/\\1/p" \
            "$input")
    fi
    [[ "$address_value" == "$blend_address" ]] \
        || fail "$name PAC blend is not derived from an authenticated callback field address"
    [[ -n "$discriminator" && "$discriminator" != 0 ]] \
        || fail "$name PAC blend has no role discriminator"
    /usr/bin/grep -Fq -- "\"ptrauth\"(i32 0, i64 $blend_result)" "$input" \
        || fail "$name indirect call does not authenticate with the blended modifier"
    REPLY=$discriminator
}

verify_ir_data_diversification() {
    local name=$1
    local input=$2
    local modifier
    local blend_line
    local blend_address
    local discriminator

    modifier=$(/usr/bin/sed -nE \
        's/.*@llvm\.ptrauth\.auth\(i64 [^,]+, i32 3, i64 (%[[:alnum:].]+)\).*/\1/p' \
        "$input" | /usr/bin/sort -u)
    [[ -n "$modifier" && "$modifier" != *$'\n'* ]] \
        || fail "$name does not use one authenticated data-pointer modifier"
    blend_line=$(/usr/bin/grep -F "$modifier =" "$input" \
        | /usr/bin/grep '@llvm\.ptrauth\.blend' || true)
    [[ -n "$blend_line" && "$blend_line" != *$'\n'* ]] \
        || fail "$name data-pointer role is not address diversified"
    blend_address=$(print -r -- "$blend_line" \
        | /usr/bin/sed -nE \
            's/.*@llvm\.ptrauth\.blend\(i64 (%[[:alnum:].]+), i64 [0-9]+\).*/\1/p')
    discriminator=$(print -r -- "$blend_line" \
        | /usr/bin/sed -nE \
            's/.*@llvm\.ptrauth\.blend\(i64 %[[:alnum:].]+, i64 ([0-9]+)\).*/\1/p')
    /usr/bin/grep -Eq \
        "^[[:space:]]*$blend_address = ptrtoint ptr " "$input" \
        || fail "$name PAC blend is not derived from its carrier field address"
    [[ -n "$discriminator" && "$discriminator" != 0 ]] \
        || fail "$name PAC blend has no role discriminator"
    /usr/bin/grep -Fq -- \
        "@llvm.ptrauth.auth(i64 " "$input" \
        || fail "$name does not authenticate its carrier pointer"
    REPLY=$discriminator
}

verify_ir_callback_context_pair() {
    local name=$1
    local input=$2
    local callback_modifier
    local context_modifier
    local modifier
    local blend_line
    local blend_address
    local discriminator

    callback_modifier=$(/usr/bin/sed -nE \
        's/.*"ptrauth"\(i32 0, i64 (%[[:alnum:].]+)\).*/\1/p' "$input")
    context_modifier=$(/usr/bin/sed -nE \
        's/.*@llvm\.ptrauth\.auth\(i64 [^,]+, i32 3, i64 (%[[:alnum:].]+)\).*/\1/p' \
        "$input")
    [[ -n "$callback_modifier" && "$callback_modifier" != *$'\n'* ]] \
        || fail "$name callback does not use one authenticated PAC modifier"
    [[ -n "$context_modifier" && "$context_modifier" != *$'\n'* ]] \
        || fail "$name context does not use one authenticated data modifier"

    for modifier in "$callback_modifier" "$context_modifier"; do
        blend_line=$(/usr/bin/grep -F "$modifier =" "$input" \
            | /usr/bin/grep '@llvm\.ptrauth\.blend' || true)
        [[ -n "$blend_line" && "$blend_line" != *$'\n'* ]] \
            || fail "$name PAC role is not address diversified"
        blend_address=$(print -r -- "$blend_line" \
            | /usr/bin/sed -nE \
                's/.*@llvm\.ptrauth\.blend\(i64 (%[[:alnum:].]+), i64 [0-9]+\).*/\1/p')
        discriminator=$(print -r -- "$blend_line" \
            | /usr/bin/sed -nE \
                's/.*@llvm\.ptrauth\.blend\(i64 %[[:alnum:].]+, i64 ([0-9]+)\).*/\1/p')
        [[ -n "$blend_address" ]] \
            || fail "$name PAC blend has no field-address input"
        /usr/bin/grep -Eq \
            "^[[:space:]]*$blend_address = ptrtoint ptr " "$input" \
            || fail "$name PAC blend is not derived from a field address"
        [[ -n "$discriminator" && "$discriminator" != 0 ]] \
            || fail "$name PAC blend has no role discriminator"
        if [[ "$modifier" == "$callback_modifier" ]]; then
            REPLY_CALLBACK=$discriminator
        else
            REPLY_CONTEXT=$discriminator
        fi
    done
}

typeset scheduler_ir="$temporary_directory/scheduler.ll"
typeset reactor_ir="$temporary_directory/reactor.ll"
typeset executor_invoke_ir="$temporary_directory/executor-invoke.ll"
typeset executor_destroy_ir="$temporary_directory/executor-destroy.ll"
typeset any_executor_ir="$temporary_directory/any-executor.ll"
typeset blocking_any_executor_ir="$temporary_directory/blocking-any-executor.ll"
typeset executor_view_ir="$temporary_directory/executor-view.ll"
typeset any_executor_object_fns_ir="$temporary_directory/any-executor-object-fns.ll"
typeset any_executor_target_ir="$temporary_directory/any-executor-target.ll"
typeset any_executor_target_fns_ir="$temporary_directory/any-executor-target-fns.ll"
typeset any_executor_property_fns_ir="$temporary_directory/any-executor-property-fns.ll"
typeset scheduler_assembly="$temporary_directory/scheduler.s"
typeset reactor_assembly="$temporary_directory/reactor.s"
typeset executor_invoke_assembly="$temporary_directory/executor-invoke.s"
typeset executor_destroy_assembly="$temporary_directory/executor-destroy.s"
typeset any_executor_assembly="$temporary_directory/any-executor.s"
typeset blocking_any_executor_assembly="$temporary_directory/blocking-any-executor.s"
typeset executor_view_assembly="$temporary_directory/executor-view.s"
typeset any_executor_object_fns_assembly="$temporary_directory/any-executor-object-fns.s"
typeset any_executor_target_assembly="$temporary_directory/any-executor-target.s"
typeset any_executor_target_fns_assembly="$temporary_directory/any-executor-target-fns.s"
typeset any_executor_property_fns_assembly="$temporary_directory/any-executor-property-fns.s"
typeset service_destroy_linked="$temporary_directory/service-destroy.disassembly"
extract_ir_function torrent7_invoke_scheduler "$scheduler_ir"
extract_ir_function torrent7_invoke_reactor "$reactor_ir"
extract_ir_function torrent7_invoke_executor "$executor_invoke_ir"
extract_ir_function torrent7_destroy_executor "$executor_destroy_ir"
extract_ir_function torrent7_invoke_any_executor "$any_executor_ir"
extract_ir_function torrent7_invoke_blocking_any_executor \
    "$blocking_any_executor_ir"
extract_ir_function torrent7_invoke_executor_view "$executor_view_ir"
extract_ir_function torrent7_any_executor_object_functions \
    "$any_executor_object_fns_ir"
extract_ir_function torrent7_any_executor_target "$any_executor_target_ir"
extract_ir_function torrent7_any_executor_target_functions \
    "$any_executor_target_fns_ir"
extract_ir_function torrent7_any_executor_property_functions \
    "$any_executor_property_fns_ir"
extract_assembly_function torrent7_invoke_scheduler "$scheduler_assembly"
extract_assembly_function torrent7_invoke_reactor "$reactor_assembly"
extract_assembly_function torrent7_invoke_executor "$executor_invoke_assembly"
extract_assembly_function torrent7_destroy_executor "$executor_destroy_assembly"
extract_assembly_function torrent7_invoke_any_executor "$any_executor_assembly"
extract_assembly_function torrent7_invoke_blocking_any_executor \
    "$blocking_any_executor_assembly"
extract_assembly_function torrent7_invoke_executor_view "$executor_view_assembly"
extract_assembly_function torrent7_any_executor_object_functions \
    "$any_executor_object_fns_assembly"
extract_assembly_function torrent7_any_executor_target \
    "$any_executor_target_assembly"
extract_assembly_function torrent7_any_executor_target_functions \
    "$any_executor_target_fns_assembly"
extract_assembly_function torrent7_any_executor_property_functions \
    "$any_executor_property_fns_assembly"
extract_linked_function __ZN5boost4asio17execution_contextD2Ev \
    "$service_destroy_linked"

verify_ir_diversification scheduler_operation::func_ "$scheduler_ir"
typeset -r scheduler_discriminator=$REPLY
verify_ir_diversification reactor_op::perform_func_ "$reactor_ir"
typeset -r reactor_discriminator=$REPLY
verify_ir_diversification executor_function::complete_.invoke "$executor_invoke_ir"
typeset -r executor_invoke_discriminator=$REPLY
verify_ir_diversification executor_function::complete_.destroy "$executor_destroy_ir"
typeset -r executor_destroy_discriminator=$REPLY
verify_ir_diversification any_executor::execute "$any_executor_ir"
typeset -r any_executor_discriminator=$REPLY
verify_ir_diversification any_executor::blocking_execute \
    "$blocking_any_executor_ir"
typeset -r blocking_any_executor_discriminator=$REPLY
verify_ir_callback_context_pair executor_function_view "$executor_view_ir"
typeset -r executor_view_callback_discriminator=$REPLY_CALLBACK
typeset -r executor_view_context_discriminator=$REPLY_CONTEXT
verify_ir_data_diversification executor_function::impl_ "$executor_invoke_ir"
typeset -r executor_impl_discriminator=$REPLY
verify_ir_data_diversification any_executor::object_fns_ \
    "$any_executor_object_fns_ir"
typeset -r any_executor_object_fns_discriminator=$REPLY
verify_ir_data_diversification any_executor::target_ \
    "$any_executor_target_ir"
typeset -r any_executor_target_discriminator=$REPLY
verify_ir_data_diversification any_executor::target_fns_ \
    "$any_executor_target_fns_ir"
typeset -r any_executor_target_fns_discriminator=$REPLY
verify_ir_data_diversification any_executor::prop_fns_ \
    "$any_executor_property_fns_ir"
typeset -r any_executor_property_fns_discriminator=$REPLY
[[ "$executor_invoke_discriminator" == "$executor_destroy_discriminator" ]] \
    || fail "Asio executor invocation and destruction use different PAC role discriminators"
typeset -ra discriminators=(
    "$scheduler_discriminator"
    "$reactor_discriminator"
    "$executor_invoke_discriminator"
    "$any_executor_discriminator"
    "$blocking_any_executor_discriminator"
    "$executor_view_callback_discriminator"
    "$executor_view_context_discriminator"
    "$executor_impl_discriminator"
    "$any_executor_object_fns_discriminator"
    "$any_executor_target_discriminator"
    "$any_executor_target_fns_discriminator"
    "$any_executor_property_fns_discriminator"
)
typeset -ra unique_discriminators=("${(u)discriminators[@]}")
(( ${#unique_discriminators[@]} == ${#discriminators[@]} )) \
    || fail "Targeted Asio PAC slots do not have distinct role discriminators"
verify_linked_role execution_context::service::destroy_ 0x2a6 \
    "$service_destroy_linked"
/usr/bin/grep -Eq '[[:space:]]autdb[[:space:]]' "$executor_view_assembly" \
    || fail "executor_function_view context does not use authenticated data codegen"

for assembly in \
    "$executor_invoke_assembly" \
    "$any_executor_object_fns_assembly" \
    "$any_executor_target_assembly" \
    "$any_executor_target_fns_assembly" \
    "$any_executor_property_fns_assembly"; do
    /usr/bin/grep -Eq '[[:space:]]autdb[[:space:]]' "$assembly" \
        || fail "Targeted Asio carrier does not use authenticated data-pointer codegen"
done

for assembly in \
    "$scheduler_assembly" \
    "$reactor_assembly" \
    "$executor_invoke_assembly" \
    "$executor_destroy_assembly" \
    "$any_executor_assembly" \
    "$blocking_any_executor_assembly"; do
    /usr/bin/grep -Eq '[[:space:]](braa|blraa)[[:space:]]' "$assembly" \
        || fail "Targeted Asio callback does not use diversified authenticated branch codegen"
    if /usr/bin/grep -Eq '[[:space:]](braaz|blraaz)[[:space:]]' "$assembly"; then
        fail "Targeted Asio callback fell back to a zero-discriminator authenticated branch"
    fi
done

/usr/bin/grep -Eq '[[:space:]](braa|blraa)[[:space:]]' \
    "$executor_view_assembly" \
    || fail "executor_function_view callback does not use authenticated branch codegen"
if /usr/bin/grep -Eq '[[:space:]](braaz|blraaz)[[:space:]]' \
    "$executor_view_assembly"; then
    fail "executor_function_view callback fell back to zero-discriminator PAC"
fi

print -r -- "Boost.Asio operation/executor PAC codegen and replay tests passed"
