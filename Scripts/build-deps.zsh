#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail typeset_silent

fail() {
    print -ru2 -- "$1"
    exit 1
}

typeset -r ROOT_DIR=${0:A:h:h}
typeset -r TARGET_ARCH=${TARGET_ARCH:-arm64e}
typeset -r MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-26.0}
typeset -r TARGET_TRIPLE="${TARGET_ARCH}-apple-macosx${MACOSX_DEPLOYMENT_TARGET}"
typeset -r SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
typeset -r HOMEBREW_PREFIX=${HOMEBREW_PREFIX:-/opt/homebrew}
typeset -r GPG=${GPG:-$HOMEBREW_PREFIX/bin/gpg}
typeset -r APPLE_CC=$(xcrun --find clang)
typeset -r APPLE_CXX=$(xcrun --find clang++)
typeset -r APPLE_AR=$(xcrun --find ar)
typeset -r APPLE_RANLIB=$(xcrun --find ranlib)
typeset -r APPLE_LIPO=$(xcrun --find lipo)
typeset -r OPENSSL_CC=$APPLE_CC
typeset -r OPENSSL_CXX=$APPLE_CXX
typeset -r OPENSSL_AR=$APPLE_AR
typeset -r OPENSSL_RANLIB=$APPLE_RANLIB
typeset -r LIBTORRENT_CC=$APPLE_CC
typeset -r LIBTORRENT_CXX=$APPLE_CXX
typeset -r LIBTORRENT_AR=$APPLE_AR
typeset -r LIBTORRENT_RANLIB=$APPLE_RANLIB
typeset -r ARCH_LIPO=$APPLE_LIPO
typeset -r DEFAULT_DEPS_DIR="$ROOT_DIR/.build/deps"
typeset -r DEFAULT_SOURCE_CACHE_DIR="$DEFAULT_DEPS_DIR/source-cache"
typeset -r SOURCE_CACHE_DIR=${SOURCE_CACHE_DIR:-$DEFAULT_SOURCE_CACHE_DIR}
typeset -r ARCHIVE_CACHE_DIR="$SOURCE_CACHE_DIR/archives"
typeset -r GIT_CACHE_DIR="$SOURCE_CACHE_DIR/git"
typeset -r ENABLE_DIAGNOSTICS=${SANITIZER_DIAGNOSTICS:-0}
typeset DEPS_PROFILE=$TARGET_ARCH
typeset LIBTORRENT_CMAKE_BUILD_TYPE=Release
if [[ "$ENABLE_DIAGNOSTICS" == "1" ]]; then
    DEPS_PROFILE="$TARGET_ARCH-diagnostics"
    LIBTORRENT_CMAKE_BUILD_TYPE="Debug"
fi
typeset -r DEPS_DIR=${DEPS_DIR:-$DEFAULT_DEPS_DIR/$DEPS_PROFILE}
typeset -r DEPS_PREFIX=${DEPS_PREFIX:-$DEPS_DIR/prefix}
typeset -r BOOST_PREFIX=${BOOST_PREFIX:-$DEPS_PREFIX}
typeset -r SOURCE_ROOT="$DEPS_DIR/src"
typeset -r BUILD_ROOT="$DEPS_DIR/build"
typeset -r BOOST_VERSION=${BOOST_VERSION:-1.91.0}
typeset -r BOOST_VERSION_UNDERSCORE=${BOOST_VERSION//./_}
typeset -r BOOST_ARCHIVE_BASENAME="boost_$BOOST_VERSION_UNDERSCORE"
typeset -r BOOST_SHA256=${BOOST_SHA256:-5734305f40a76c30f951c9abd409a45a2a19fb546efe4162119250bbe4d3a463}
typeset -r BOOST_TARBALL_URL=${BOOST_TARBALL_URL:-https://archives.boost.io/release/$BOOST_VERSION/source/$BOOST_ARCHIVE_BASENAME.tar.gz}
typeset -r BOOST_TARBALL="$ARCHIVE_CACHE_DIR/$BOOST_ARCHIVE_BASENAME.tar.gz"
typeset -r BOOST_SOURCE_ROOT="$SOURCE_CACHE_DIR/boost"
typeset -r BOOST_SOURCE_DIR="$BOOST_SOURCE_ROOT/$BOOST_ARCHIVE_BASENAME"
typeset -r BOOST_HEADERS_STAMP="$BOOST_PREFIX/.torrent-app-boost-headers"
typeset -r OPENSSL_VERSION=${OPENSSL_VERSION:-3.5.7}
typeset -r OPENSSL_SHA256=${OPENSSL_SHA256:-a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8}
typeset -r OPENSSL_TARBALL_URL=${OPENSSL_TARBALL_URL:-https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz}
typeset -r OPENSSL_SIGNATURE_URL=${OPENSSL_SIGNATURE_URL:-$OPENSSL_TARBALL_URL.asc}
typeset -r OPENSSL_RELEASE_KEYS="$ROOT_DIR/Scripts/keys/openssl-release-pubkeys.asc"
# OpenSSL 3.5.7 is signed by this OpenSSL release key. Keep this exact
# fingerprint pinned so a future signer rotation requires an explicit update.
typeset -r OPENSSL_SIGNING_FINGERPRINT=${OPENSSL_SIGNING_FINGERPRINT:-BA5473A2B0587B07FB27CF2D216094DFD0CB81EF}
typeset -r OPENSSL_TARBALL="$ARCHIVE_CACHE_DIR/openssl-$OPENSSL_VERSION.tar.gz"
typeset -r OPENSSL_SIGNATURE="$OPENSSL_TARBALL.asc"
typeset -r OPENSSL_SOURCE_DIR="$SOURCE_ROOT/openssl-$OPENSSL_VERSION"
typeset -r OPENSSL_BUILD_DIR="$BUILD_ROOT/openssl-$OPENSSL_VERSION"
typeset -r OPENSSL_BUILD_STAMP="$DEPS_PREFIX/.torrent-app-openssl-build"
typeset -r OPENSSL_CONFIGURE_TARGET=torrent-app-darwin64-arm64e
typeset -r OPENSSL_CONFIG_FILE="$OPENSSL_BUILD_DIR/torrent-app-openssl.conf"
# Keep stdio/posix file APIs: libtorrent uses OpenSSL-backed file APIs
# for trust paths and SSL torrent certificate/key/DH files.
typeset -a OPENSSL_CONFIGURE_OPTIONS=(
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
    no-ml-kem
    no-ml-dsa
    no-slh-dsa
    no-tls-deprecated-ec
    no-afalgeng
    no-capieng
    no-padlockeng
    no-gost
    no-aria
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
typeset -r LIBTORRENT_SOURCE_DIR="$SOURCE_ROOT/libtorrent"
typeset -r LIBTORRENT_BUILD_DIR="$BUILD_ROOT/libtorrent"
typeset -r LIBTORRENT_BUILD_STAMP="$DEPS_PREFIX/.torrent-app-libtorrent-build"
typeset -r LIBTORRENT_REPO=${LIBTORRENT_REPO:-https://github.com/arvidn/libtorrent.git}
typeset -r LIBTORRENT_TAG=${LIBTORRENT_TAG:-v2.0.13}
typeset -r LIBTORRENT_COMMIT=${LIBTORRENT_COMMIT:-7d7fc38fac61177fa5e02148f791b2f65250b09d}
typeset -r LIBTORRENT_MIRROR_DIR="$GIT_CACHE_DIR/libtorrent.git"
typeset -r LIBTORRENT_SUBMODULE_MIRROR_ROOT="$GIT_CACHE_DIR/libtorrent-submodules"
typeset -a LIBTORRENT_CMAKE_OPTIONS=(
    -DBUILD_SHARED_LIBS=OFF
    -Dstatic_runtime=OFF
    -Dbuild_tests=OFF
    -Dbuild_examples=OFF
    -Dbuild_tools=OFF
    -Dpython-bindings=OFF
    -Dpython-egg-info=OFF
    -Dpython-install-system-dir=OFF
    -Ddht=ON
    -Ddeprecated-functions=OFF
    -Dencryption=ON
    -Dexceptions=ON
    -Dgnutls=OFF
    -Dextensions=ON
    -Di2p=OFF
    -Dlogging=OFF
    -Dmutable-torrents=OFF
    -Dstreaming=OFF
)
typeset -r LIBTORRENT_EXTRA_DEFINES="-DTORRENT_DISABLE_SUPERSEEDING -DTORRENT_DISABLE_SHARE_MODE -DTORRENT_DISABLE_PREDICTIVE_PIECES"
typeset -r ALLOW_EXTERNAL_DEPS_CLEAN=${ALLOW_EXTERNAL_DEPS_CLEAN:-0}
# Keep global PAC options compatible with system C/C++ runtime contracts.
# Type-discriminated C function pointers and RTTI typeinfo vtable pointers
# need targeted use; enabling them globally breaks APIs such as pthread_once
# and dynamic_cast on Apple's arm64e runtime.
typeset -r PTRAUTH_DRIVER_C_FLAGS="-fptrauth-returns -fptrauth-calls -fptrauth-indirect-gotos -fptrauth-auth-traps -fptrauth-intrinsics"
typeset -r PTRAUTH_CC1_C_FLAGS="-fptrauth-block-descriptor-pointers -fptrauth-init-fini -fptrauth-init-fini-address-discrimination"
typeset -r PTRAUTH_C_FLAGS="$PTRAUTH_DRIVER_C_FLAGS $PTRAUTH_CC1_C_FLAGS"
typeset -r PTRAUTH_CXX_FLAGS="-fptrauth-vtable-pointer-address-discrimination -fptrauth-vtable-pointer-type-discrimination"
typeset -r TYPED_ALLOCATOR_C_FLAGS="-ftyped-memory-operations-experimental"
typeset -r TYPED_ALLOCATOR_CXX_FLAGS="$TYPED_ALLOCATOR_C_FLAGS -ftyped-cxx-new-delete -ftyped-cxx-delete"
typeset -r STRICT_FLEX_ARRAYS_FLAG="-fstrict-flex-arrays=3"
typeset -r BRANCH_TARGET_IDENTIFICATION_FLAG="-fbranch-target-identification"
typeset -r SLS_HARDENING_FLAG="-mharden-sls=all"
typeset LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE
typeset -r DIAGNOSTIC_SANITIZER_FLAGS="-g -fno-omit-frame-pointer -fsanitize=address,undefined,local-bounds -fsanitize-address-use-after-scope -fno-sanitize-recover=undefined,local-bounds"
# Libtorrent's uTP packet pool uses a historical trailing buf[1] member with
# extra bytes allocated behind it. ASan can validate the actual allocation, but
# UBSan bounds instrumentation treats accesses past buf[0] as out-of-bounds.
typeset -r LIBTORRENT_DIAGNOSTIC_SANITIZER_FLAGS="-g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize=array-bounds,local-bounds -fsanitize-address-use-after-scope -fno-sanitize-recover=undefined"
if [[ "$ENABLE_DIAGNOSTICS" == "1" ]]; then
    LIBCPP_HARDENING_MODE="_LIBCPP_HARDENING_MODE_DEBUG"
fi
typeset -r HARDENED_COMMON_FLAGS="-Wno-poison-system-directories -Wformat -Wformat-security -Werror=format-security -fstack-protector-strong -D_FORTIFY_SOURCE=3 -fPIE -ftrivial-auto-var-init=zero -fvisibility=hidden -faarch64-jump-table-hardening $STRICT_FLEX_ARRAYS_FLAG $BRANCH_TARGET_IDENTIFICATION_FLAG $SLS_HARDENING_FLAG $PTRAUTH_C_FLAGS"
typeset -r HARDENED_C_FLAGS="$HARDENED_COMMON_FLAGS $TYPED_ALLOCATOR_C_FLAGS"
typeset -r OPENSSL_HARDENED_CXX_FLAGS="$HARDENED_COMMON_FLAGS $PTRAUTH_CXX_FLAGS $TYPED_ALLOCATOR_CXX_FLAGS -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE -fvisibility-inlines-hidden"
typeset -r HARDENED_CXX_FLAGS="$HARDENED_COMMON_FLAGS $PTRAUTH_CXX_FLAGS $TYPED_ALLOCATOR_CXX_FLAGS -D_LIBCPP_HARDENING_MODE=$LIBCPP_HARDENING_MODE -fvisibility-inlines-hidden"
typeset -r OPENSSL_CFLAGS="$HARDENED_C_FLAGS -isysroot $SDK_PATH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
typeset -r OPENSSL_CXXFLAGS="$OPENSSL_HARDENED_CXX_FLAGS -isysroot $SDK_PATH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
typeset LIBTORRENT_C_FLAGS=$HARDENED_C_FLAGS
typeset LIBTORRENT_CXX_FLAGS=$HARDENED_CXX_FLAGS
if [[ "$ENABLE_DIAGNOSTICS" == "1" ]]; then
    LIBTORRENT_C_FLAGS="$LIBTORRENT_C_FLAGS $LIBTORRENT_DIAGNOSTIC_SANITIZER_FLAGS"
    LIBTORRENT_CXX_FLAGS="$LIBTORRENT_CXX_FLAGS $LIBTORRENT_DIAGNOSTIC_SANITIZER_FLAGS"
fi
LIBTORRENT_C_FLAGS="$LIBTORRENT_C_FLAGS $LIBTORRENT_EXTRA_DEFINES"
LIBTORRENT_CXX_FLAGS="$LIBTORRENT_CXX_FLAGS $LIBTORRENT_EXTRA_DEFINES"

require_tool() {
    local -r tool=$1
    [[ -n ${commands[$tool]:-} ]] || fail "Missing required tool: $tool"
}

require_path() {
    local -r required_path=$1
    local -r label=$2
    [[ -e $required_path ]] || fail "Missing $label: $required_path"
}

remove_dependency_path() {
    local target="$1"
    local default_root
    local target_parent

    mkdir -p "$DEFAULT_DEPS_DIR"
    default_root="$(cd "$DEFAULT_DEPS_DIR" && pwd -P)"
    mkdir -p "$(dirname "$target")"
    target_parent="$(cd "$(dirname "$target")" && pwd -P)"

    case "$target_parent/" in
        "$default_root"/*)
            rm -rf "$target"
            ;;
        *)
            if [[ "$ALLOW_EXTERNAL_DEPS_CLEAN" == "1" ]]; then
                rm -rf "$target"
            else
                print -ru2 -- "Refusing to remove external dependency path: $target"
                print -ru2 -- "Set ALLOW_EXTERNAL_DEPS_CLEAN=1 to allow cleanup outside $DEFAULT_DEPS_DIR."
                exit 1
            fi
            ;;
    esac
}

is_exact_git_checkout() {
    local path="$1"
    local top_level

    [[ -d "$path" ]] || return 1
    top_level="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [[ "${top_level:A}" == "${path:A}" ]]
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual

    actual="$(file_sha256 "$file")"
    if [[ "$actual" != "$expected" ]]; then
        print -ru2 -- "SHA-256 mismatch for $file"
        print -ru2 -- "Expected: $expected"
        print -ru2 -- "Actual:   $actual"
        exit 1
    fi
}

file_sha256() {
    shasum -a 256 "$1" | awk '{print $1}'
}

seed_archive_from_existing_profiles() {
    local output="$1"
    local basename="$2"
    local expected_sha256="$3"
    local candidate
    local tmp

    for candidate in \
        "$DEPS_DIR/src/$basename" \
        "$DEFAULT_DEPS_DIR/$TARGET_ARCH/src/$basename" \
        "$DEFAULT_DEPS_DIR/$TARGET_ARCH-diagnostics/src/$basename"
    do
        if [[ "$candidate" == "$output" || ! -f "$candidate" ]]; then
            continue
        fi

        verify_sha256 "$candidate" "$expected_sha256"
        mkdir -p "$(dirname "$output")"
        tmp="$output.tmp.$$"
        cp "$candidate" "$tmp"
        verify_sha256 "$tmp" "$expected_sha256"
        mv "$tmp" "$output"
        return 0
    done

    return 1
}

seed_openssl_signature_from_existing_profiles() {
    local output="$1"
    local basename="$2"
    local candidate
    local tmp

    for candidate in \
        "$DEPS_DIR/src/$basename" \
        "$DEFAULT_DEPS_DIR/$TARGET_ARCH/src/$basename" \
        "$DEFAULT_DEPS_DIR/$TARGET_ARCH-diagnostics/src/$basename"
    do
        if [[ "$candidate" == "$output" || ! -f "$candidate" ]]; then
            continue
        fi

        mkdir -p "$(dirname "$output")"
        tmp="$output.tmp.$$"
        cp "$candidate" "$tmp"
        mv "$tmp" "$output"
        return 0
    done

    return 1
}

stamp_matches() {
    local stamp="$1"
    local generator="$2"
    local expected

    [[ -f "$stamp" ]] || return 1
    expected="$("$generator")"
    [[ "$(cat "$stamp")" == "$expected" ]]
}

write_stamp() {
    local stamp="$1"
    local generator="$2"

    mkdir -p "$(dirname "$stamp")"
    "$generator" >"$stamp"
}

openssl_configure_options_text() {
    print -r -- "${(j: :)OPENSSL_CONFIGURE_OPTIONS}"
}

libtorrent_cmake_options_text() {
    print -r -- "${(j: :)LIBTORRENT_CMAKE_OPTIONS}"
}

boost_headers_manifest() {
    cat <<EOF
boost-version=$BOOST_VERSION
boost-sha256=$BOOST_SHA256
boost-url=$BOOST_TARBALL_URL
boost-prefix=$BOOST_PREFIX
EOF
}

openssl_build_manifest() {
    cat <<EOF
openssl-version=$OPENSSL_VERSION
openssl-sha256=$OPENSSL_SHA256
openssl-signature-url=$OPENSSL_SIGNATURE_URL
openssl-signing-fingerprint=$OPENSSL_SIGNING_FINGERPRINT
openssl-release-keys-sha256=$(file_sha256 "$OPENSSL_RELEASE_KEYS")
target-arch=$TARGET_ARCH
target-triple=$TARGET_TRIPLE
deployment-target=$MACOSX_DEPLOYMENT_TARGET
diagnostics=$ENABLE_DIAGNOSTICS
sdk=$SDK_PATH
configure-target=$OPENSSL_CONFIGURE_TARGET
configure-options=$(openssl_configure_options_text)
compiler-c=$OPENSSL_CC
compiler-cxx=$OPENSSL_CXX
ar=$OPENSSL_AR
ranlib=$OPENSSL_RANLIB
cflags=$OPENSSL_CFLAGS
cxxflags=$OPENSSL_CXXFLAGS
EOF
}

write_openssl_config() {
    cat >"$OPENSSL_CONFIG_FILE" <<'EOF'
my %targets = (
    "torrent-app-darwin64-arm64e" => {
        inherit_from     => [ "darwin-common" ],
        CFLAGS           => add("-Wall"),
        cflags           => add("-arch arm64e"),
        lib_cppflags     => add("-DL_ENDIAN"),
        bn_ops           => "SIXTY_FOUR_BIT_LONG",
    },
);
EOF
}

libtorrent_build_manifest() {
    cat <<EOF
libtorrent-tag=$LIBTORRENT_TAG
libtorrent-commit=$LIBTORRENT_COMMIT
target-arch=$TARGET_ARCH
target-triple=$TARGET_TRIPLE
deployment-target=$MACOSX_DEPLOYMENT_TARGET
diagnostics=$ENABLE_DIAGNOSTICS
cmake-build-type=$LIBTORRENT_CMAKE_BUILD_TYPE
sdk=$SDK_PATH
compiler-c=$LIBTORRENT_CC
compiler-cxx=$LIBTORRENT_CXX
ar=$LIBTORRENT_AR
ranlib=$LIBTORRENT_RANLIB
c-flags=$LIBTORRENT_C_FLAGS
cxx-flags=$LIBTORRENT_CXX_FLAGS
cmake-options=$(libtorrent_cmake_options_text)
openssl-prefix=$DEPS_PREFIX
openssl-configure-options=$(openssl_configure_options_text)
boost-version=$BOOST_VERSION
boost-sha256=$BOOST_SHA256
boost-prefix=$BOOST_PREFIX
EOF
}

verify_archive_arch() {
    local archive="$1"
    local expected_arch="$2"
    local expected_subtype
    local tmpdir
    local -i checked=0

    case "$expected_arch" in
        arm64e)
            expected_subtype="ARM64          E"
            ;;
        arm64)
            expected_subtype="ARM64        ALL"
            ;;
        *)
            fail "Unsupported archive architecture check: $expected_arch"
            ;;
    esac

    require_path "$archive" "static archive"

    if ! "$ARCH_LIPO" -info "$archive" | grep -q "architecture: $expected_arch"; then
        print -ru2 -- "Archive is not $expected_arch: $archive"
        "$ARCH_LIPO" -info "$archive" >&2 || true
        exit 1
    fi

    tmpdir="$(mktemp -d)"
    (cd "$tmpdir" && xcrun ar -x "$archive")
    while IFS= read -r member; do
        local header
        local file_info

        file_info="$(file "$member")"
        if [[ "$file_info" == *"LLVM bitcode"* ]]; then
            (( ++checked ))
            if ! "$ARCH_LIPO" -info "$member" | grep -q "architecture: $expected_arch"; then
                print -ru2 -- "Archive bitcode member has wrong architecture in $archive"
                print -ru2 -- "$member: $("$ARCH_LIPO" -info "$member" 2>/dev/null || true)"
                exit 1
            fi
            continue
        fi

        if ! header="$(xcrun otool -hv "$member" 2>/dev/null | tail -n 1)"; then
            continue
        fi

        if [[ "$header" != *"MH_MAGIC_64"* ]]; then
            continue
        fi

        (( ++checked ))
        if [[ "$header" != *"$expected_subtype"* ]]; then
            print -ru2 -- "Archive member has wrong architecture in $archive"
            print -ru2 -- "$member: $header"
            exit 1
        fi
    done < <(find "$tmpdir" -type f)

    if [[ "$checked" == "0" ]]; then
        fail "No Mach-O or LLVM bitcode members found in archive: $archive"
    fi

    rm -rf "$tmpdir"
}

thin_archive_arch() {
    local archive="$1"
    local arch="$2"
    local info
    local tmp

    require_path "$archive" "static archive"
    info="$("$ARCH_LIPO" -info "$archive")"
    if [[ "$info" == *"architecture: $arch"* ]]; then
        return
    fi

    if [[ "$info" != *" $arch"* ]]; then
        print -ru2 -- "Archive does not contain $arch slice: $archive"
        print -ru2 -- "$info"
        exit 1
    fi

    tmp="$archive.thin.$$"
    "$ARCH_LIPO" "$archive" -thin "$arch" -output "$tmp"
    mv "$tmp" "$archive"
    xcrun ranlib "$archive"
}

download_openssl_signature() {
    if [[ -f "$OPENSSL_SIGNATURE" ]]; then
        return
    fi

    if seed_openssl_signature_from_existing_profiles "$OPENSSL_SIGNATURE" "openssl-$OPENSSL_VERSION.tar.gz.asc"; then
        return
    fi

    local tmp="$OPENSSL_SIGNATURE.tmp.$$"
    mkdir -p "$(dirname "$OPENSSL_SIGNATURE")"
    rm -f "$tmp"
    curl \
        --fail \
        --location \
        --proto '=https' \
        --proto-redir '=https' \
        --retry 3 \
        --show-error \
        --output "$tmp" \
        "$OPENSSL_SIGNATURE_URL"

    mv "$tmp" "$OPENSSL_SIGNATURE"
}

verify_openssl_signature() {
    local archive="${1:-$OPENSSL_TARBALL}"
    local signature="${2:-$OPENSSL_SIGNATURE}"
    local tmpdir
    local gnupg_home
    local status_file
    local verify_log
    local valid_signature_fingerprint
    local key_fingerprint

    require_path "$OPENSSL_RELEASE_KEYS" "OpenSSL release-signing public keys"
    require_path "$signature" "OpenSSL detached signature"
    require_path "$archive" "OpenSSL source archive"

    tmpdir="$(mktemp -d)"
    gnupg_home="$tmpdir/gnupg"
    status_file="$tmpdir/status"
    verify_log="$tmpdir/verify.log"
    mkdir -m 700 "$gnupg_home"

    if ! "$GPG" --homedir "$gnupg_home" --batch --quiet --import "$OPENSSL_RELEASE_KEYS" >"$verify_log" 2>&1; then
        cat "$verify_log" >&2
        rm -rf "$tmpdir"
        exit 1
    fi

    key_fingerprint="$("$GPG" --homedir "$gnupg_home" --batch --with-colons --fingerprint "$OPENSSL_SIGNING_FINGERPRINT" | awk -F: '$1 == "fpr" { print $10; exit }')"
    if [[ "$key_fingerprint" != "$OPENSSL_SIGNING_FINGERPRINT" ]]; then
        print -ru2 -- "OpenSSL release keyring does not contain expected signing fingerprint: $OPENSSL_SIGNING_FINGERPRINT"
        rm -rf "$tmpdir"
        exit 1
    fi

    if ! "$GPG" --homedir "$gnupg_home" --batch --status-fd 3 --verify "$signature" "$archive" >"$verify_log" 2>&1 3>"$status_file"; then
        cat "$verify_log" >&2
        rm -rf "$tmpdir"
        exit 1
    fi

    valid_signature_fingerprint="$(awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print $3; exit }' "$status_file")"
    if [[ "$valid_signature_fingerprint" != "$OPENSSL_SIGNING_FINGERPRINT" ]]; then
        print -ru2 -- "OpenSSL signature signer mismatch for $archive"
        print -ru2 -- "Expected signer: $OPENSSL_SIGNING_FINGERPRINT"
        print -ru2 -- "Actual signer:   ${valid_signature_fingerprint:-none}"
        rm -rf "$tmpdir"
        exit 1
    fi

    rm -rf "$tmpdir"
}

download_openssl() {
    mkdir -p "$ARCHIVE_CACHE_DIR"

    if [[ -f "$OPENSSL_TARBALL" ]]; then
        verify_sha256 "$OPENSSL_TARBALL" "$OPENSSL_SHA256"
        download_openssl_signature
        verify_openssl_signature
        return
    fi

    if seed_archive_from_existing_profiles "$OPENSSL_TARBALL" "openssl-$OPENSSL_VERSION.tar.gz" "$OPENSSL_SHA256"; then
        download_openssl_signature
        verify_openssl_signature
        return
    fi

    local tmp="$OPENSSL_TARBALL.tmp.$$"
    rm -f "$tmp"
    curl \
        --fail \
        --location \
        --proto '=https' \
        --proto-redir '=https' \
        --retry 3 \
        --show-error \
        --output "$tmp" \
        "$OPENSSL_TARBALL_URL"

    verify_sha256 "$tmp" "$OPENSSL_SHA256"
    download_openssl_signature
    verify_openssl_signature "$tmp" "$OPENSSL_SIGNATURE"
    mv "$tmp" "$OPENSSL_TARBALL"
}

download_boost() {
    mkdir -p "$ARCHIVE_CACHE_DIR"

    if [[ -f "$BOOST_TARBALL" ]]; then
        verify_sha256 "$BOOST_TARBALL" "$BOOST_SHA256"
        return
    fi

    if seed_archive_from_existing_profiles "$BOOST_TARBALL" "$BOOST_ARCHIVE_BASENAME.tar.gz" "$BOOST_SHA256"; then
        return
    fi

    local tmp="$BOOST_TARBALL.tmp.$$"
    rm -f "$tmp"
    curl \
        --fail \
        --location \
        --proto '=https' \
        --proto-redir '=https' \
        --retry 3 \
        --show-error \
        --output "$tmp" \
        "$BOOST_TARBALL_URL"

    verify_sha256 "$tmp" "$BOOST_SHA256"
    mv "$tmp" "$BOOST_TARBALL"
}

extract_boost() {
    local stamp="$BOOST_SOURCE_DIR/.torrent-app-sha256"

    if [[ -d "$BOOST_SOURCE_DIR" && -f "$stamp" && "$(cat "$stamp")" == "$BOOST_SHA256" ]]; then
        return
    fi

    remove_dependency_path "$BOOST_SOURCE_DIR"
    mkdir -p "$BOOST_SOURCE_ROOT"
    tar -xzf "$BOOST_TARBALL" -C "$BOOST_SOURCE_ROOT"
    print -r -- "$BOOST_SHA256" >"$stamp"
    require_path "$BOOST_SOURCE_DIR/boost/version.hpp" "Boost headers"
    require_path "$BOOST_SOURCE_DIR/LICENSE_1_0.txt" "Boost license"
}

install_boost_headers() {
    if [[ -f "$BOOST_PREFIX/include/boost/version.hpp" ]] && stamp_matches "$BOOST_HEADERS_STAMP" boost_headers_manifest; then
        return
    fi

    remove_dependency_path "$BOOST_PREFIX/include/boost"
    mkdir -p "$BOOST_PREFIX/include" "$BOOST_PREFIX/share/licenses/boost"
    cp -R "$BOOST_SOURCE_DIR/boost" "$BOOST_PREFIX/include/"
    cp "$BOOST_SOURCE_DIR/LICENSE_1_0.txt" "$BOOST_PREFIX/share/licenses/boost/LICENSE_1_0.txt"
    write_stamp "$BOOST_HEADERS_STAMP" boost_headers_manifest
}

extract_openssl() {
    local stamp="$OPENSSL_SOURCE_DIR/.torrent-app-sha256"

    if [[ -d "$OPENSSL_SOURCE_DIR" && -f "$stamp" && "$(cat "$stamp")" == "$OPENSSL_SHA256" ]]; then
        return
    fi

    remove_dependency_path "$OPENSSL_SOURCE_DIR"
    mkdir -p "$SOURCE_ROOT"
    tar -xzf "$OPENSSL_TARBALL" -C "$SOURCE_ROOT"
    print -r -- "$OPENSSL_SHA256" >"$stamp"
    require_path "$OPENSSL_SOURCE_DIR/Configure" "OpenSSL configure script"
}

build_openssl() {
    if [[ -f "$DEPS_PREFIX/lib/libssl.a" && -f "$DEPS_PREFIX/lib/libcrypto.a" ]] && stamp_matches "$OPENSSL_BUILD_STAMP" openssl_build_manifest; then
        thin_archive_arch "$DEPS_PREFIX/lib/libssl.a" "$TARGET_ARCH"
        thin_archive_arch "$DEPS_PREFIX/lib/libcrypto.a" "$TARGET_ARCH"
        verify_archive_arch "$DEPS_PREFIX/lib/libssl.a" "$TARGET_ARCH"
        verify_archive_arch "$DEPS_PREFIX/lib/libcrypto.a" "$TARGET_ARCH"
        return
    fi

    remove_dependency_path "$OPENSSL_BUILD_DIR"
    mkdir -p "$OPENSSL_BUILD_DIR" "$DEPS_PREFIX"
    rm -f "$DEPS_PREFIX/lib/libssl.a" "$DEPS_PREFIX/lib/libcrypto.a" "$OPENSSL_BUILD_STAMP"
    write_openssl_config

    (
        cd "$OPENSSL_BUILD_DIR"
        CC="$OPENSSL_CC -target $TARGET_TRIPLE" \
        CXX="$OPENSSL_CXX -target $TARGET_TRIPLE" \
        CFLAGS="$OPENSSL_CFLAGS" \
        CXXFLAGS="$OPENSSL_CXXFLAGS" \
        AR="$OPENSSL_AR" \
        RANLIB="$OPENSSL_RANLIB" \
        "$OPENSSL_SOURCE_DIR/Configure" \
            --config="$OPENSSL_CONFIG_FILE" \
            "$OPENSSL_CONFIGURE_TARGET" \
            --prefix="$DEPS_PREFIX" \
            --openssldir="$DEPS_PREFIX/ssl" \
            "${OPENSSL_CONFIGURE_OPTIONS[@]}"

        make -j"${JOBS:-$(sysctl -n hw.ncpu)}"
        make install_sw
    )

    thin_archive_arch "$DEPS_PREFIX/lib/libssl.a" "$TARGET_ARCH"
    thin_archive_arch "$DEPS_PREFIX/lib/libcrypto.a" "$TARGET_ARCH"
    verify_archive_arch "$DEPS_PREFIX/lib/libssl.a" "$TARGET_ARCH"
    verify_archive_arch "$DEPS_PREFIX/lib/libcrypto.a" "$TARGET_ARCH"
    write_stamp "$OPENSSL_BUILD_STAMP" openssl_build_manifest
}

ensure_git_mirror() {
    local repo_url="$1"
    local mirror_dir="$2"
    local label="$3"
    local seed_checkout="${4:-}"
    local expected_commit="${5:-}"

    if [[ -e "$mirror_dir" ]] && ! git -C "$mirror_dir" rev-parse --is-bare-repository >/dev/null 2>&1; then
        remove_dependency_path "$mirror_dir"
    fi

    if [[ ! -d "$mirror_dir" ]]; then
        mkdir -p "$(dirname "$mirror_dir")"
        if [[ -n "$seed_checkout" ]] && is_exact_git_checkout "$seed_checkout"; then
            git clone --mirror "$seed_checkout" "$mirror_dir"
        else
            git clone --mirror "$repo_url" "$mirror_dir"
        fi
    fi

    git -C "$mirror_dir" remote set-url origin "$repo_url"

    if [[ -n "$expected_commit" ]] && ! git -C "$mirror_dir" rev-parse --verify "$expected_commit^{commit}" >/dev/null 2>&1; then
        git -C "$mirror_dir" fetch --tags --prune origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
    fi

    if [[ -n "$expected_commit" ]] && ! git -C "$mirror_dir" rev-parse --verify "$expected_commit^{commit}" >/dev/null 2>&1; then
        fail "$label mirror does not contain expected commit: $expected_commit"
    fi
}

setup_libtorrent_submodule_mirrors() {
    local key
    local url
    local name
    local submodule_path
    local mirror_dir
    local expected_commit

    if [[ ! -f "$LIBTORRENT_SOURCE_DIR/.gitmodules" ]]; then
        return
    fi

    git -C "$LIBTORRENT_SOURCE_DIR" submodule sync --recursive

    while read -r key url; do
        name="${key#submodule.}"
        name="${name%.url}"
        submodule_path="$(git -C "$LIBTORRENT_SOURCE_DIR" config -f .gitmodules --get "submodule.$name.path")"
        mirror_dir="$LIBTORRENT_SUBMODULE_MIRROR_ROOT/${submodule_path//\//__}.git"
        expected_commit="$(git -C "$LIBTORRENT_SOURCE_DIR" ls-tree HEAD "$submodule_path" | awk '{print $3}')"

        ensure_git_mirror "$url" "$mirror_dir" "libtorrent submodule $submodule_path" "$LIBTORRENT_SOURCE_DIR/$submodule_path" "$expected_commit"
        git -C "$LIBTORRENT_SOURCE_DIR" config "$key" "$mirror_dir"
    done < <(git -C "$LIBTORRENT_SOURCE_DIR" config -f .gitmodules --get-regexp '^submodule\..*\.url$' || true)

    git -C "$LIBTORRENT_SOURCE_DIR" -c protocol.file.allow=always submodule update --init --recursive
}

clone_libtorrent() {
    ensure_git_mirror "$LIBTORRENT_REPO" "$LIBTORRENT_MIRROR_DIR" "libtorrent" "$LIBTORRENT_SOURCE_DIR" "$LIBTORRENT_COMMIT"

    mkdir -p "$SOURCE_ROOT"

    if [[ -d "$LIBTORRENT_SOURCE_DIR/.git" ]]; then
        local current
        current="$(git -C "$LIBTORRENT_SOURCE_DIR" rev-parse HEAD 2>/dev/null || true)"
        if [[ "$current" != "$LIBTORRENT_COMMIT" ]]; then
            remove_dependency_path "$LIBTORRENT_SOURCE_DIR"
        fi
    elif [[ -e "$LIBTORRENT_SOURCE_DIR" ]]; then
        remove_dependency_path "$LIBTORRENT_SOURCE_DIR"
    fi

    if [[ ! -d "$LIBTORRENT_SOURCE_DIR/.git" ]]; then
        git clone \
            --branch "$LIBTORRENT_TAG" \
            "$LIBTORRENT_MIRROR_DIR" \
            "$LIBTORRENT_SOURCE_DIR"
        git -C "$LIBTORRENT_SOURCE_DIR" remote set-url origin "$LIBTORRENT_REPO"
        git -C "$LIBTORRENT_SOURCE_DIR" checkout --detach "$LIBTORRENT_COMMIT"
    else
        git -C "$LIBTORRENT_SOURCE_DIR" remote set-url origin "$LIBTORRENT_REPO"
    fi

    setup_libtorrent_submodule_mirrors

    local current
    current="$(git -C "$LIBTORRENT_SOURCE_DIR" rev-parse HEAD)"
    if [[ "$current" != "$LIBTORRENT_COMMIT" ]]; then
        fail "libtorrent checkout mismatch: expected $LIBTORRENT_COMMIT, got $current"
    fi
}

build_libtorrent() {
    local -a cmake_generator_args=()
    if [[ -f "$DEPS_PREFIX/lib/libtorrent-rasterbar.a" ]] && stamp_matches "$LIBTORRENT_BUILD_STAMP" libtorrent_build_manifest; then
        verify_archive_arch "$DEPS_PREFIX/lib/libtorrent-rasterbar.a" "$TARGET_ARCH"
        return
    fi

    remove_dependency_path "$LIBTORRENT_BUILD_DIR"
    rm -f "$DEPS_PREFIX/lib/libtorrent-rasterbar.a" "$LIBTORRENT_BUILD_STAMP"

    if [[ -n ${CMAKE_GENERATOR:-} ]]; then
        cmake_generator_args=(-G "$CMAKE_GENERATOR")
    elif [[ -n ${commands[ninja]:-} ]]; then
        cmake_generator_args=(-G Ninja)
    fi

    cmake \
        -S "$LIBTORRENT_SOURCE_DIR" \
        -B "$LIBTORRENT_BUILD_DIR" \
        "${cmake_generator_args[@]}" \
        -Wno-dev \
        -DCMAKE_BUILD_TYPE="$LIBTORRENT_CMAKE_BUILD_TYPE" \
        -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" \
        -DCMAKE_C_COMPILER="$LIBTORRENT_CC" \
        -DCMAKE_CXX_COMPILER="$LIBTORRENT_CXX" \
        -DCMAKE_AR="$LIBTORRENT_AR" \
        -DCMAKE_RANLIB="$LIBTORRENT_RANLIB" \
        -DCMAKE_OSX_ARCHITECTURES="$TARGET_ARCH" \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        -DCMAKE_C_COMPILER_TARGET="$TARGET_TRIPLE" \
        -DCMAKE_CXX_COMPILER_TARGET="$TARGET_TRIPLE" \
        -DCMAKE_CXX_STANDARD=23 \
        -DCMAKE_CXX_STANDARD_REQUIRED=ON \
        -DCMAKE_C_FLAGS="$LIBTORRENT_C_FLAGS" \
        -DCMAKE_CXX_FLAGS="$LIBTORRENT_CXX_FLAGS" \
        "${LIBTORRENT_CMAKE_OPTIONS[@]}" \
        -DOPENSSL_USE_STATIC_LIBS=TRUE \
        -DOPENSSL_ROOT_DIR="$DEPS_PREFIX" \
        -DOPENSSL_INCLUDE_DIR="$DEPS_PREFIX/include" \
        -DOPENSSL_SSL_LIBRARY="$DEPS_PREFIX/lib/libssl.a" \
        -DOPENSSL_CRYPTO_LIBRARY="$DEPS_PREFIX/lib/libcrypto.a" \
        -DBoost_NO_SYSTEM_PATHS=ON \
        -DBoost_NO_BOOST_CMAKE=ON \
        -DBoost_ROOT="$BOOST_PREFIX" \
        -DBOOST_ROOT="$BOOST_PREFIX" \
        -DBoost_INCLUDE_DIR="$BOOST_PREFIX/include" \
        -DCMAKE_PREFIX_PATH="$DEPS_PREFIX;$BOOST_PREFIX"

    cmake --build "$LIBTORRENT_BUILD_DIR" --target install --parallel "${JOBS:-$(sysctl -n hw.ncpu)}"

    verify_archive_arch "$DEPS_PREFIX/lib/libtorrent-rasterbar.a" "$TARGET_ARCH"
    write_stamp "$LIBTORRENT_BUILD_STAMP" libtorrent_build_manifest
}

require_tool cmake
require_tool curl
require_tool git
require_tool make
require_tool perl
require_tool shasum
require_tool tar
require_tool xcrun
require_path "$GPG" "GnuPG verifier"
require_path "$OPENSSL_CC" "OpenSSL C compiler"
require_path "$OPENSSL_CXX" "OpenSSL C++ compiler"
require_path "$OPENSSL_AR" "OpenSSL archiver"
require_path "$OPENSSL_RANLIB" "OpenSSL ranlib"
require_path "$LIBTORRENT_CC" "libtorrent C compiler"
require_path "$LIBTORRENT_CXX" "libtorrent C++ compiler"
require_path "$LIBTORRENT_AR" "libtorrent archiver"
require_path "$LIBTORRENT_RANLIB" "libtorrent ranlib"
require_path "$ARCH_LIPO" "architecture inspection tool"

download_boost
extract_boost
install_boost_headers
download_openssl
extract_openssl
build_openssl
clone_libtorrent
build_libtorrent

print -r -- "$DEPS_PREFIX"
