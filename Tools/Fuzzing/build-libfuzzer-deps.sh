#!/usr/bin/env bash
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/../.." && pwd)"

DEPS_ROOT="${LIBFUZZER_DEPS_ROOT:-$TOOLS_DIR/deps/arm64-libfuzzer}"
PREFIX="${LIBFUZZER_DEPS_PREFIX:-$DEPS_ROOT/prefix}"
BUILD_ROOT="$DEPS_ROOT/build"
OPENSSL_SOURCE="${OPENSSL_SOURCE:-$ROOT_DIR/.build/deps/arm64e/src/openssl-3.5.7}"
LIBTORRENT_SOURCE="${LIBTORRENT_SOURCE:-$ROOT_DIR/.build/deps/arm64e/src/libtorrent}"
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
LIBTORRENT_SANITIZERS="${LIBTORRENT_SANITIZERS:-fuzzer-no-link,address,undefined}"

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
require_path "$BOOST_SOURCE/boost" "Boost headers"

expected_config="$(
    cat <<EOF
target=$TARGET_TRIPLE
sdk=$SDK_PATH
openssl_source=$OPENSSL_SOURCE
libtorrent_source=$LIBTORRENT_SOURCE
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
printf '%s\n' "$expected_config" > "$stamp_file"

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

    local libtorrent_common_flags="${base_flags[*]} -fsanitize=$LIBTORRENT_SANITIZERS -fsanitize-address-use-after-scope -fno-sanitize-recover=undefined -fno-sanitize=array-bounds,local-bounds -DTORRENT_DISABLE_SUPERSEEDING -DTORRENT_DISABLE_SHARE_MODE -DTORRENT_DISABLE_PREDICTIVE_PIECES"
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

lipo -info "$PREFIX/lib/libssl.a"
lipo -info "$PREFIX/lib/libcrypto.a"
lipo -info "$PREFIX/lib/libtorrent-rasterbar.a"

echo "$PREFIX"
