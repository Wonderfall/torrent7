#!/usr/bin/env bash
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$TOOLS_DIR/../.." && pwd -P)"

DEFAULT_DEPS_PARENT="$TOOLS_DIR/deps"
DEFAULT_DEPS_ROOT="$TOOLS_DIR/deps/arm64-libfuzzer"
DEPS_ROOT="${LIBFUZZER_DEPS_ROOT:-$DEFAULT_DEPS_ROOT}"
if [[ -n "${LIBFUZZER_DEPS_PREFIX:-}" \
    && "${LIBFUZZER_DEPS_PREFIX:-}" != "$DEPS_ROOT/prefix" ]]; then
    echo "LIBFUZZER_DEPS_PREFIX must be the prefix child of LIBFUZZER_DEPS_ROOT" >&2
    exit 1
fi
PREFIX="$DEPS_ROOT/prefix"
BUILD_ROOT="$DEPS_ROOT/build"
OWNERSHIP_MARKER="$DEPS_ROOT/.torrent7-libfuzzer-deps-root"
OWNERSHIP_MARKER_CONTENT="torrent7-libfuzzer-deps-v1"
BORINGSSL_SOURCE="${BORINGSSL_SOURCE:-$ROOT_DIR/.build/deps/arm64e/src/boringssl}"
BORINGSSL_PATCH_HELPER="$ROOT_DIR/Scripts/boringssl-patch-series.sh"
LIBTORRENT_SOURCE="${LIBTORRENT_SOURCE:-$ROOT_DIR/.build/deps/arm64e/src/libtorrent}"
LIBTORRENT_PATCH_HELPER="$ROOT_DIR/Scripts/libtorrent-patch-series.sh"
LIBTORRENT_TLS_VERIFIER="$ROOT_DIR/Scripts/verify-libtorrent-boringssl-tls.zsh"
BOOST_SOURCE="${BOOST_SOURCE:-$ROOT_DIR/.build/deps/source-cache/boost/boost_1_92_0}"
BOOST_PATCH_HELPER="$ROOT_DIR/Scripts/boost-patch-series.sh"
LLVM_PREFIX="${LLVM_PREFIX:-$(brew --prefix llvm 2>/dev/null || true)}"
CC="${CC:-$LLVM_PREFIX/bin/clang}"
CXX="${CXX:-$LLVM_PREFIX/bin/clang++}"
AR="${AR:-$LLVM_PREFIX/bin/llvm-ar}"
RANLIB="${RANLIB:-$LLVM_PREFIX/bin/llvm-ranlib}"
SDK_PATH="${SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
TARGET_TRIPLE="${TARGET_TRIPLE:-arm64-apple-macosx26.0}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
BORINGSSL_SANITIZERS="${BORINGSSL_SANITIZERS:-address}"
LIBTORRENT_SANITIZERS="${LIBTORRENT_SANITIZERS:-fuzzer-no-link,address,undefined,local-bounds}"

require_path() {
    local path="$1"
    local label="$2"
    if [[ ! -e "$path" ]]; then
        echo "Missing $label: $path" >&2
        exit 1
    fi
}

fail() {
    echo "$1" >&2
    exit 1
}

atomic_write_text() {
    local destination="$1"
    local contents="$2"
    local directory
    local temporary

    directory="$(dirname "$destination")"
    [[ -d "$directory" && ! -L "$directory" ]] \
        || fail "Refusing to write through a symlinked cache directory: $directory"
    temporary="$(mktemp "$directory/.${destination##*/}.tmp.XXXXXX")" \
        || fail "Could not create temporary cache metadata"
    if ! printf '%s\n' "$contents" > "$temporary"; then
        rm -f -- "$temporary"
        fail "Could not write cache metadata: $destination"
    fi
    if ! /bin/mv -fh "$temporary" "$destination"; then
        rm -f -- "$temporary"
        fail "Could not publish cache metadata: $destination"
    fi
}

initialize_dependency_root() {
    local requested_root="$DEPS_ROOT"
    local using_default=0

    [[ ! -L "$requested_root" ]] || fail "Refusing symlinked libFuzzer dependency root: $requested_root"
    if [[ "$requested_root" == "$DEFAULT_DEPS_ROOT" ]]; then
        using_default=1
        [[ ! -L "$DEFAULT_DEPS_PARENT" ]] \
            || fail "Refusing symlinked default libFuzzer dependency parent: $DEFAULT_DEPS_PARENT"
        if [[ ! -e "$DEFAULT_DEPS_PARENT" ]]; then
            mkdir -- "$DEFAULT_DEPS_PARENT"
        fi
        [[ -d "$DEFAULT_DEPS_PARENT" ]] \
            || fail "Default libFuzzer dependency parent is not a directory: $DEFAULT_DEPS_PARENT"
        [[ "$(cd "$DEFAULT_DEPS_PARENT" && pwd -P)" == "$DEFAULT_DEPS_PARENT" ]] \
            || fail "Default libFuzzer dependency parent resolves outside the project"
    else
        [[ "${ALLOW_EXTERNAL_LIBFUZZER_DEPS:-0}" == "1" ]] \
            || fail "External LIBFUZZER_DEPS_ROOT requires ALLOW_EXTERNAL_LIBFUZZER_DEPS=1"
        [[ -d "$(dirname "$requested_root")" ]] \
            || fail "Create the external dependency root parent before use: $(dirname "$requested_root")"
    fi

    if [[ ! -d "$requested_root" ]]; then
        mkdir -- "$requested_root"
    fi

    DEPS_ROOT="$(cd "$requested_root" && pwd -P)"
    if [[ "$DEPS_ROOT" == "/" \
        || "$DEPS_ROOT" == "${HOME:-}" \
        || "$DEPS_ROOT" == "$ROOT_DIR" \
        || "$DEPS_ROOT" == "$TOOLS_DIR" ]]; then
        fail "Refusing unsafe libFuzzer dependency root: $DEPS_ROOT"
    fi
    if [[ "$using_default" != "1" ]]; then
        if [[ ! -f "$DEPS_ROOT/.torrent7-libfuzzer-deps-root" \
            && -n "$(find "$DEPS_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
            fail "Refusing non-empty external dependency root without an ownership marker: $DEPS_ROOT"
        fi
    fi

    PREFIX="$DEPS_ROOT/prefix"
    BUILD_ROOT="$DEPS_ROOT/build"
    OWNERSHIP_MARKER="$DEPS_ROOT/.torrent7-libfuzzer-deps-root"
    [[ ! -L "$PREFIX" && ! -L "$BUILD_ROOT" ]] \
        || fail "Refusing symlinked libFuzzer cache child in $DEPS_ROOT"
    [[ ! -L "$OWNERSHIP_MARKER" ]] \
        || fail "Refusing symlinked dependency-root ownership marker: $OWNERSHIP_MARKER"
    if [[ -f "$OWNERSHIP_MARKER" ]]; then
        [[ "$(cat "$OWNERSHIP_MARKER")" == "$OWNERSHIP_MARKER_CONTENT" ]] \
            || fail "Invalid libFuzzer dependency-root ownership marker: $OWNERSHIP_MARKER"
    else
        [[ ! -e "$OWNERSHIP_MARKER" ]] \
            || fail "Dependency-root ownership marker is not a regular file: $OWNERSHIP_MARKER"
        atomic_write_text "$OWNERSHIP_MARKER" "$OWNERSHIP_MARKER_CONTENT"
    fi
}

remove_cached_dependencies() {
    [[ -d "$DEPS_ROOT" && ! -L "$DEPS_ROOT" ]] \
        || fail "Unsafe libFuzzer dependency root: $DEPS_ROOT"
    [[ -f "$OWNERSHIP_MARKER" \
        && "$(cat "$OWNERSHIP_MARKER")" == "$OWNERSHIP_MARKER_CONTENT" ]] \
        || fail "Refusing cleanup without a valid ownership marker: $DEPS_ROOT"
    [[ "$PREFIX" == "$DEPS_ROOT/prefix" && "$BUILD_ROOT" == "$DEPS_ROOT/build" ]] \
        || fail "Refusing cleanup outside the owned libFuzzer dependency root"
    [[ ! -L "$PREFIX" && ! -L "$BUILD_ROOT" ]] \
        || fail "Refusing cleanup through a symlinked cache child"
    rm -rf -- "$PREFIX" "$BUILD_ROOT"
}

initialize_dependency_root

require_path "$CC" "LLVM clang"
require_path "$CXX" "LLVM clang++"
require_path "$AR" "LLVM llvm-ar"
require_path "$RANLIB" "LLVM llvm-ranlib"
require_path "$BORINGSSL_SOURCE/CMakeLists.txt" "BoringSSL source"
require_path "$BORINGSSL_SOURCE/LICENSE" "BoringSSL license"
require_path "$BORINGSSL_PATCH_HELPER" "BoringSSL patch-series helper"
require_path "$LIBTORRENT_SOURCE/CMakeLists.txt" "libtorrent source"
require_path "$LIBTORRENT_SOURCE/deps/try_signal/try_signal.cpp" "libtorrent try_signal source"
require_path "$LIBTORRENT_PATCH_HELPER" "libtorrent patch-series helper"
require_path "$LIBTORRENT_TLS_VERIFIER" "libtorrent BoringSSL TLS verifier"
require_path "$BOOST_SOURCE/boost" "Boost headers"
require_path "$BOOST_PATCH_HELPER" "Boost patch-series helper"

BUILDER_SHA256="$(shasum -a 256 "$TOOLS_DIR/build-libfuzzer-deps.sh" | awk '{print $1}')"
BORINGSSL_PATCH_HELPER_SHA256="$(shasum -a 256 "$BORINGSSL_PATCH_HELPER" | awk '{print $1}')"
LIBTORRENT_PATCH_HELPER_SHA256="$(shasum -a 256 "$LIBTORRENT_PATCH_HELPER" | awk '{print $1}')"
BOOST_PATCH_HELPER_SHA256="$(shasum -a 256 "$BOOST_PATCH_HELPER" | awk '{print $1}')"
CC_SHA256="$(shasum -a 256 "$CC" | awk '{print $1}')"
CXX_SHA256="$(shasum -a 256 "$CXX" | awk '{print $1}')"
AR_SHA256="$(shasum -a 256 "$AR" | awk '{print $1}')"
RANLIB_SHA256="$(shasum -a 256 "$RANLIB" | awk '{print $1}')"
"$LIBTORRENT_PATCH_HELPER" verify "$LIBTORRENT_SOURCE"
LIBTORRENT_PATCH_MANIFEST="$("$LIBTORRENT_PATCH_HELPER" manifest "$LIBTORRENT_SOURCE")"
"$BOOST_PATCH_HELPER" verify "$BOOST_SOURCE"
BOOST_PATCH_MANIFEST="$("$BOOST_PATCH_HELPER" manifest "$BOOST_SOURCE")"
"$BORINGSSL_PATCH_HELPER" verify "$BORINGSSL_SOURCE"
BORINGSSL_PATCH_MANIFEST="$("$BORINGSSL_PATCH_HELPER" manifest "$BORINGSSL_SOURCE")"
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
boringssl_patch_helper_sha256=$BORINGSSL_PATCH_HELPER_SHA256
libtorrent_patch_helper_sha256=$LIBTORRENT_PATCH_HELPER_SHA256
boost_patch_helper_sha256=$BOOST_PATCH_HELPER_SHA256
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
boringssl_source=$BORINGSSL_SOURCE
$BORINGSSL_PATCH_MANIFEST
libtorrent_source=$LIBTORRENT_SOURCE
$LIBTORRENT_PATCH_MANIFEST
libtorrent_try_signal_commit=$LIBTORRENT_TRY_SIGNAL_COMMIT
boost_source=$BOOST_SOURCE
$BOOST_PATCH_MANIFEST
boringssl_sanitizers=$BORINGSSL_SANITIZERS
libtorrent_sanitizers=$LIBTORRENT_SANITIZERS
EOF
)"
stamp_file="$DEPS_ROOT/.build-config"
[[ ! -L "$stamp_file" ]] || fail "Refusing symlinked libFuzzer cache stamp: $stamp_file"
if [[ "${LIBFUZZER_REBUILD_DEPS:-0}" == "1" ]]; then
    remove_cached_dependencies
elif [[ -f "$stamp_file" ]]; then
    if [[ "$(cat "$stamp_file")" != "$expected_config" ]]; then
        remove_cached_dependencies
    fi
elif [[ -d "$PREFIX" || -d "$BUILD_ROOT" ]]; then
    remove_cached_dependencies
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
    # Fuzz dependencies always use sanitizers; keep fortify out of this profile.
    -U_FORTIFY_SOURCE
    -fno-delete-null-pointer-checks
    -fno-strict-aliasing
    -fstrict-flex-arrays=3
    -ftrivial-auto-var-init=zero
    -fvisibility=hidden
)

boringssl_flags=(
    "${base_flags[@]}"
    -fsanitize="$BORINGSSL_SANITIZERS"
    -fsanitize-address-use-after-scope
)

verify_boringssl() {
    local build_dir="$BUILD_ROOT/boringssl"
    local compile_commands="$build_dir/compile_commands.json"
    local compile_count
    local hardened_count

    require_path "$PREFIX/include/openssl/base.h" "BoringSSL headers"
    require_path "$PREFIX/lib/libssl.a" "BoringSSL TLS archive"
    require_path "$PREFIX/lib/libcrypto.a" "BoringSSL crypto archive"
    require_path "$compile_commands" "BoringSSL compile database"
    grep -q '^#define OPENSSL_IS_BORINGSSL' "$PREFIX/include/openssl/base.h" \
        || fail "Installed fuzz TLS headers are not BoringSSL"
    grep -q '^OPENSSL_NO_ASM:.*=ON$' "$build_dir/CMakeCache.txt" \
        || fail "Fuzz BoringSSL was not configured without assembly"
    grep -q '^OPENSSL_SMALL:.*=ON$' "$build_dir/CMakeCache.txt" \
        || fail "Fuzz BoringSSL was not configured with OPENSSL_SMALL"
    if grep -Eq '"file": ".*\.(S|s|asm)"' "$compile_commands"; then
        fail "Fuzz BoringSSL compile database contains assembly sources"
    fi
    compile_count="$(grep -c '"file":' "$compile_commands")"
    hardened_count="$(grep -c '"command":.*-DOPENSSL_NO_ASM.*-DOPENSSL_SMALL' "$compile_commands")"
    [[ "$compile_count" -gt 0 && "$hardened_count" == "$compile_count" ]] \
        || fail "Fuzz BoringSSL compile commands do not consistently disable assembly"
    [[ ! -e "$PREFIX/lib/libdecrepit.a" \
        && ! -e "$PREFIX/lib/libpki.a" \
        && ! -e "$PREFIX/bin/bssl" ]] \
        || fail "Unexpected BoringSSL target was installed into the fuzz prefix"
}

build_boringssl() {
    if [[ -f "$PREFIX/lib/libssl.a" && -f "$PREFIX/lib/libcrypto.a" ]]; then
        verify_boringssl
        return
    fi

    local build_dir="$BUILD_ROOT/boringssl"
    local -a generator_args=()
    rm -rf "$build_dir"
    mkdir -p "$build_dir" "$PREFIX/include" "$PREFIX/lib" \
        "$PREFIX/share/licenses/boringssl"
    if command -v ninja >/dev/null 2>&1; then
        generator_args=(-G Ninja)
    fi

    cmake \
        -S "$BORINGSSL_SOURCE" \
        -B "$build_dir" \
        "${generator_args[@]}" \
        -Wno-author \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
        -DCMAKE_C_COMPILER_TARGET="$TARGET_TRIPLE" \
        -DCMAKE_CXX_COMPILER_TARGET="$TARGET_TRIPLE" \
        -DCMAKE_C_FLAGS="${boringssl_flags[*]}" \
        -DCMAKE_CXX_FLAGS="${boringssl_flags[*]}" \
        -DCMAKE_C_VISIBILITY_PRESET=hidden \
        -DCMAKE_CXX_VISIBILITY_PRESET=hidden \
        -DCMAKE_VISIBILITY_INLINES_HIDDEN=ON \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DOPENSSL_NO_ASM=ON \
        -DOPENSSL_SMALL=ON \
        -DFIPS=OFF

    cmake --build "$build_dir" --target crypto ssl --parallel "$JOBS"
    cp -R "$BORINGSSL_SOURCE/include/openssl" "$PREFIX/include/"
    cp "$build_dir/libssl.a" "$PREFIX/lib/libssl.a"
    cp "$build_dir/libcrypto.a" "$PREFIX/lib/libcrypto.a"
    cp "$BORINGSSL_SOURCE/LICENSE" "$PREFIX/share/licenses/boringssl/LICENSE"
    verify_boringssl
}

build_libtorrent() {
    if [[ -f "$PREFIX/lib/libtorrent-rasterbar.a" ]]; then
        "$LIBTORRENT_TLS_VERIFIER" "$PREFIX/lib/libtorrent-rasterbar.a"
        return
    fi

    local build_dir="$BUILD_ROOT/libtorrent"
    rm -rf "$build_dir"

    # These diagnostics are audited pinned-upstream patterns: incomplete
    # negative capability annotations and ordinary named return paths. Keep
    # them scoped to libtorrent itself.
    local upstream_warning_flags="-Wno-thread-safety-negative -Wno-nrvo"
    local libtorrent_common_flags="${base_flags[*]} -fsanitize=$LIBTORRENT_SANITIZERS -fsanitize-address-use-after-scope -fno-sanitize-recover=undefined,local-bounds $upstream_warning_flags -DTORRENT_USE_RTC=0 -DTORRENT_DISABLE_SUPERSEEDING -DTORRENT_DISABLE_SHARE_MODE -DTORRENT_DISABLE_PREDICTIVE_PIECES"
    local -a generator_args=()
    if command -v ninja >/dev/null 2>&1; then
        generator_args=(-G Ninja)
    fi

    # Libtorrent discovers BoringSSL through CMake's OpenSSL-compatible API.
    cmake \
        -S "$LIBTORRENT_SOURCE" \
        -B "$build_dir" \
        "${generator_args[@]}" \
        -Wno-policy \
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
        -Dssl-torrents=OFF \
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
    "$LIBTORRENT_TLS_VERIFIER" "$PREFIX/lib/libtorrent-rasterbar.a"
}

build_boringssl
build_libtorrent

lipo "$PREFIX/lib/libssl.a" -verify_arch arm64
lipo "$PREFIX/lib/libcrypto.a" -verify_arch arm64
lipo "$PREFIX/lib/libtorrent-rasterbar.a" -verify_arch arm64
lipo -info "$PREFIX/lib/libssl.a"
lipo -info "$PREFIX/lib/libcrypto.a"
lipo -info "$PREFIX/lib/libtorrent-rasterbar.a"

atomic_write_text "$stamp_file" "$expected_config"

echo "$PREFIX"
