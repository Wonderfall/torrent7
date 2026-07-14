#!/usr/bin/env bash
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/../.." && pwd)"

DEPS_ROOT="${LIBFUZZER_DEPS_ROOT:-$TOOLS_DIR/deps/arm64-libfuzzer}"
PREFIX="${LIBFUZZER_DEPS_PREFIX:-$DEPS_ROOT/prefix}"
BUILD_ROOT="$DEPS_ROOT/build"
OPENSSL_SOURCE="${OPENSSL_SOURCE:-$ROOT_DIR/.build/deps/arm64e/src/openssl-3.5.7}"
LIBTORRENT_SOURCE="${LIBTORRENT_SOURCE:-$ROOT_DIR/.build/deps/arm64e/src/libtorrent}"
LIBTORRENT_EXPECTED_COMMIT="578e06824c3546f3371ab43967ab288a7e253eca"
LIBTORRENT_EXPECTED_IO_BLOB="406c7c7aa7d4e34657d203517cd749aa71cb29f4"
LIBTORRENT_EXPECTED_PACKET_POOL_BLOB="799e3765cffa4cbb140d5a4e860629f07538eb2f"
LIBTORRENT_EXPECTED_FLAGS_BLOB="60224b1151d6fa714e0db38c1595ddd1532619bf"
BOOST_SOURCE="${BOOST_SOURCE:-$ROOT_DIR/.build/deps/source-cache/boost/boost_1_91_0}"
LLVM_PREFIX="${LLVM_PREFIX:-$(brew --prefix llvm 2>/dev/null || true)}"
CC="${CC:-$LLVM_PREFIX/bin/clang}"
CXX="${CXX:-$LLVM_PREFIX/bin/clang++}"
AR="${AR:-$LLVM_PREFIX/bin/llvm-ar}"
RANLIB="${RANLIB:-$LLVM_PREFIX/bin/llvm-ranlib}"
SDK_PATH="${SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
TARGET_TRIPLE="${TARGET_TRIPLE:-arm64-apple-macosx26.0}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
OPENSSL_SANITIZERS="${OPENSSL_SANITIZERS:-address}"
LIBTORRENT_SANITIZERS="${LIBTORRENT_SANITIZERS:-fuzzer-no-link,address,undefined,local-bounds}"

require_path() {
    local path="$1"
    local label="$2"
    if [[ ! -e "$path" ]]; then
        echo "Missing $label: $path" >&2
        exit 1
    fi
}

require_path "$CC" "LLVM clang"
require_path "$CXX" "LLVM clang++"
require_path "$AR" "LLVM llvm-ar"
require_path "$RANLIB" "LLVM llvm-ranlib"
require_path "$OPENSSL_SOURCE/Configure" "OpenSSL source"
require_path "$LIBTORRENT_SOURCE/CMakeLists.txt" "libtorrent source"
require_path "$LIBTORRENT_SOURCE/deps/try_signal/try_signal.cpp" "libtorrent try_signal source"
require_path "$BOOST_SOURCE/boost" "Boost headers"

BUILDER_SHA256="$(shasum -a 256 "$TOOLS_DIR/build-libfuzzer-deps.sh" | awk '{print $1}')"
CC_SHA256="$(shasum -a 256 "$CC" | awk '{print $1}')"
CXX_SHA256="$(shasum -a 256 "$CXX" | awk '{print $1}')"
AR_SHA256="$(shasum -a 256 "$AR" | awk '{print $1}')"
RANLIB_SHA256="$(shasum -a 256 "$RANLIB" | awk '{print $1}')"
LIBTORRENT_COMMIT="$(git -C "$LIBTORRENT_SOURCE" rev-parse HEAD)"
if [[ "$LIBTORRENT_COMMIT" != "$LIBTORRENT_EXPECTED_COMMIT" ]]; then
    echo "libtorrent checkout does not match the pinned 2.1.0 commit" >&2
    exit 1
fi
LIBTORRENT_STATUS="$(
    git -C "$LIBTORRENT_SOURCE" status \
        --porcelain=v1 \
        --untracked-files=all \
        --ignore-submodules=none
)"
LIBTORRENT_EXPECTED_STATUS=$' M include/libtorrent/aux_/io.hpp\n M include/libtorrent/aux_/packet_pool.hpp\n M include/libtorrent/flags.hpp'
if [[ "$LIBTORRENT_STATUS" != "$LIBTORRENT_EXPECTED_STATUS" ]]; then
    echo "libtorrent checkout does not contain only the expected compatibility patch" >&2
    exit 1
fi
LIBTORRENT_IO_BLOB="$(git hash-object --no-filters "$LIBTORRENT_SOURCE/include/libtorrent/aux_/io.hpp")"
LIBTORRENT_PACKET_POOL_BLOB="$(git hash-object --no-filters "$LIBTORRENT_SOURCE/include/libtorrent/aux_/packet_pool.hpp")"
LIBTORRENT_FLAGS_BLOB="$(git hash-object --no-filters "$LIBTORRENT_SOURCE/include/libtorrent/flags.hpp")"
if [[ "$LIBTORRENT_IO_BLOB" != "$LIBTORRENT_EXPECTED_IO_BLOB" \
    || "$LIBTORRENT_PACKET_POOL_BLOB" != "$LIBTORRENT_EXPECTED_PACKET_POOL_BLOB" \
    || "$LIBTORRENT_FLAGS_BLOB" != "$LIBTORRENT_EXPECTED_FLAGS_BLOB" ]]; then
    echo "libtorrent compatibility patch content does not match the pinned build" >&2
    exit 1
fi
LIBTORRENT_TRY_SIGNAL_COMMIT="$(git -C "$LIBTORRENT_SOURCE/deps/try_signal" rev-parse HEAD)"
LIBTORRENT_TRY_SIGNAL_EXPECTED_COMMIT="$(git -C "$LIBTORRENT_SOURCE" ls-tree HEAD deps/try_signal | awk '{print $3}')"
if [[ "$LIBTORRENT_TRY_SIGNAL_COMMIT" != "$LIBTORRENT_TRY_SIGNAL_EXPECTED_COMMIT" ]]; then
    echo "libtorrent try_signal checkout does not match the pinned source tree" >&2
    exit 1
fi
if [[ -n "$(git -C "$LIBTORRENT_SOURCE/deps/try_signal" status --porcelain=v1 --untracked-files=all)" ]]; then
    echo "libtorrent try_signal checkout is dirty" >&2
    exit 1
fi
expected_config="$(
    cat <<EOF
builder_sha256=$BUILDER_SHA256
target=$TARGET_TRIPLE
sdk=$SDK_PATH
prefix=$PREFIX
build_root=$BUILD_ROOT
cc=$CC
cc_sha256=$CC_SHA256
cxx=$CXX
cxx_sha256=$CXX_SHA256
ar=$AR
ar_sha256=$AR_SHA256
ranlib=$RANLIB
ranlib_sha256=$RANLIB_SHA256
openssl_source=$OPENSSL_SOURCE
libtorrent_source=$LIBTORRENT_SOURCE
libtorrent_commit=$LIBTORRENT_COMMIT
libtorrent_io_blob=$LIBTORRENT_IO_BLOB
libtorrent_packet_pool_blob=$LIBTORRENT_PACKET_POOL_BLOB
libtorrent_flags_blob=$LIBTORRENT_FLAGS_BLOB
libtorrent_try_signal_commit=$LIBTORRENT_TRY_SIGNAL_COMMIT
boost_source=$BOOST_SOURCE
openssl_sanitizers=$OPENSSL_SANITIZERS
libtorrent_sanitizers=$LIBTORRENT_SANITIZERS
EOF
)"
stamp_file="$DEPS_ROOT/.build-config"
if [[ "${LIBFUZZER_REBUILD_DEPS:-0}" == "1" ]]; then
    rm -rf "$PREFIX" "$BUILD_ROOT"
elif [[ -f "$stamp_file" ]]; then
    if [[ "$(cat "$stamp_file")" != "$expected_config" ]]; then
        rm -rf "$PREFIX" "$BUILD_ROOT"
    fi
elif [[ -d "$PREFIX" || -d "$BUILD_ROOT" ]]; then
    rm -rf "$PREFIX" "$BUILD_ROOT"
fi

mkdir -p "$PREFIX" "$BUILD_ROOT"
# Publish the cache stamp only after both archives build and pass architecture
# verification. A failed or interrupted build must never look complete.
rm -f "$stamp_file"

base_flags=(
    -target "$TARGET_TRIPLE"
    -isysroot "$SDK_PATH"
    -mmacosx-version-min=26.0
    -O1
    -g
    -fno-omit-frame-pointer
    -fstack-protector-strong
    -U_FORTIFY_SOURCE
    -D_FORTIFY_SOURCE=3
    -fstrict-flex-arrays=3
    -ftrivial-auto-var-init=zero
    -fvisibility=hidden
)

openssl_flags=(
    "${base_flags[@]}"
    -fsanitize="$OPENSSL_SANITIZERS"
    -fsanitize-address-use-after-scope
)

openssl_options=(
    no-shared
    no-pinshared
    no-module
    no-tests
    no-apps
    no-docs
    no-asm
    no-comp
    no-ssl3
    no-tls1
    no-tls1_1
    no-tls1-method
    no-tls1_1-method
    no-dtls
    no-dtls1
    no-dtls1_2
    no-dtls1-method
    no-dtls1_2-method
    no-dgram
    no-async
    no-atexit
    no-autoerrinit
    no-autoload-config
    no-cmp
    no-cms
    no-ct
    no-dso
    no-engine
    no-dynamic-engine
    no-filenames
    no-http
    no-integrity-only-ciphers
    no-legacy
    no-multiblock
    no-nextprotoneg
    no-ocsp
    no-psk
    no-rfc3779
    no-sock
    no-srp
    no-srtp
    no-thread-pool
    no-default-thread-pool
    no-ts
    no-ui-console
    no-quic
    no-cached-fetch
    no-egd
    no-external-tests
    no-fips
    no-fips-securitychecks
    no-md2
    no-msan
    no-sctp
    no-tfo
    no-uplink
    no-bf
    no-blake2
    no-camellia
    no-cast
    no-cmac
    no-des
    no-dsa
    no-ec2m
    no-idea
    no-md4
    no-mdc2
    no-ocb
    no-rc2
    no-rc4
    no-rmd160
    no-scrypt
    no-seed
    no-siphash
    no-siv
    no-sm2
    no-sm2-precomp
    no-sm3
    no-sm4
    no-whirlpool
    no-ssl-trace
    no-weak-ssl-ciphers
)

build_openssl() {
    if [[ -f "$PREFIX/lib/libssl.a" && -f "$PREFIX/lib/libcrypto.a" ]]; then
        return
    fi

    local build_dir="$BUILD_ROOT/openssl"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    (
        cd "$build_dir"
        CC="$CC" \
        CXX="$CXX" \
        AR="$AR" \
        RANLIB="$RANLIB" \
        CFLAGS="${openssl_flags[*]}" \
        CXXFLAGS="${openssl_flags[*]} -std=c++23" \
        "$OPENSSL_SOURCE/Configure" \
            darwin64-arm64-cc \
            --prefix="$PREFIX" \
            --openssldir="$PREFIX/ssl" \
            "${openssl_options[@]}"

        make -j"$JOBS"
        make install_sw
    )
}

build_libtorrent() {
    if [[ -f "$PREFIX/lib/libtorrent-rasterbar.a" ]]; then
        return
    fi

    local build_dir="$BUILD_ROOT/libtorrent"
    rm -rf "$build_dir"

    # These diagnostics are audited pinned-upstream patterns: conservative
    # mutex annotations, a non-elided endpoint return, and fields unused only
    # because streaming is disabled. Keep them scoped to libtorrent itself.
    local upstream_warning_flags="-Wno-thread-safety-negative -Wno-thread-safety-analysis -Wno-nrvo -Wno-unused-private-field"
    local libtorrent_common_flags="${base_flags[*]} -fsanitize=$LIBTORRENT_SANITIZERS -fsanitize-address-use-after-scope -fno-sanitize-recover=undefined,local-bounds $upstream_warning_flags -DTORRENT_USE_RTC=0 -DTORRENT_DISABLE_SUPERSEEDING -DTORRENT_DISABLE_SHARE_MODE -DTORRENT_DISABLE_PREDICTIVE_PIECES"
    local -a generator_args=()
    if command -v ninja >/dev/null 2>&1; then
        generator_args=(-G Ninja)
    fi

    cmake \
        -S "$LIBTORRENT_SOURCE" \
        -B "$build_dir" \
        "${generator_args[@]}" \
        -Wno-dev \
        -DCMAKE_BUILD_TYPE=Debug \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
        -DCMAKE_C_COMPILER_TARGET="$TARGET_TRIPLE" \
        -DCMAKE_CXX_COMPILER_TARGET="$TARGET_TRIPLE" \
        -DCMAKE_CXX_STANDARD=23 \
        -DCMAKE_CXX_STANDARD_REQUIRED=ON \
        -DCMAKE_C_FLAGS="$libtorrent_common_flags" \
        -DCMAKE_CXX_FLAGS="$libtorrent_common_flags -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_DEBUG -fvisibility-inlines-hidden" \
        -DBUILD_SHARED_LIBS=OFF \
        -Dstatic_runtime=OFF \
        -Dbuild_tests=OFF \
        -Dbuild_examples=OFF \
        -Dbuild_tools=OFF \
        -Dpython-bindings=OFF \
        -Dpython-egg-info=OFF \
        -Dpython-install-system-dir=OFF \
        -Ddht=ON \
        -Ddeprecated-functions=OFF \
        -Dencryption=ON \
        -Dexceptions=ON \
        -Dgnutls=OFF \
        -Dextensions=ON \
        -Di2p=OFF \
        -Dlogging=OFF \
        -Dmutable-torrents=OFF \
        -Dstreaming=OFF \
        -Dwebtorrent=OFF \
        -DOPENSSL_USE_STATIC_LIBS=TRUE \
        -DOPENSSL_ROOT_DIR="$PREFIX" \
        -DOPENSSL_INCLUDE_DIR="$PREFIX/include" \
        -DOPENSSL_SSL_LIBRARY="$PREFIX/lib/libssl.a" \
        -DOPENSSL_CRYPTO_LIBRARY="$PREFIX/lib/libcrypto.a" \
        -DBoost_NO_SYSTEM_PATHS=ON \
        -DBoost_NO_BOOST_CMAKE=ON \
        -DBoost_ROOT="$BOOST_SOURCE" \
        -DBOOST_ROOT="$BOOST_SOURCE" \
        -DBoost_INCLUDE_DIR="$BOOST_SOURCE" \
        -DCMAKE_PREFIX_PATH="$PREFIX;$BOOST_SOURCE"

    cmake --build "$build_dir" --target install --parallel "$JOBS"
}

build_openssl
build_libtorrent

lipo "$PREFIX/lib/libssl.a" -verify_arch arm64
lipo "$PREFIX/lib/libcrypto.a" -verify_arch arm64
lipo "$PREFIX/lib/libtorrent-rasterbar.a" -verify_arch arm64
lipo -info "$PREFIX/lib/libssl.a"
lipo -info "$PREFIX/lib/libcrypto.a"
lipo -info "$PREFIX/lib/libtorrent-rasterbar.a"

stamp_tmp="$(mktemp "$DEPS_ROOT/.build-config.tmp.XXXXXX")"
trap 'rm -f "$stamp_tmp"' EXIT
printf '%s\n' "$expected_config" > "$stamp_tmp"
mv "$stamp_tmp" "$stamp_file"
trap - EXIT

echo "$PREFIX"
