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
typeset -r openssl_prefix=${OPENSSL_PREFIX:-$deps_prefix}
typeset clang_tidy=${CLANG_TIDY:-$homebrew_prefix/opt/llvm/bin/clang-tidy}

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
    "hicpp-exception-baseclass"
    "hicpp-no-assembler"
    "hicpp-signed-bitwise"
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
    -isystem "$openssl_prefix/include"
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
    -DTORRENT_SSL_PEERS
    -DOPENSSL_NO_SSL2
    -DOPENSSL_NO_SSL3
    -DOPENSSL_NO_TLS1
    -DOPENSSL_NO_TLS1_1
    -DOPENSSL_NO_DTLS1
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
