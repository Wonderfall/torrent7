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
typeset -r SDK_PATH=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
typeset -r APPLE_CC=$(/usr/bin/xcrun --find clang)
typeset -r APPLE_CXX=$(/usr/bin/xcrun --find clang++)
typeset -r APPLE_AR=$(/usr/bin/xcrun --find ar)
typeset -r APPLE_RANLIB=$(/usr/bin/xcrun --find ranlib)
typeset -r APPLE_LIPO=$(/usr/bin/xcrun --find lipo)
typeset -r BORINGSSL_CC=$APPLE_CC
typeset -r BORINGSSL_CXX=$APPLE_CXX
typeset -r BORINGSSL_AR=$APPLE_AR
typeset -r BORINGSSL_RANLIB=$APPLE_RANLIB
typeset -r LIBTORRENT_CC=$APPLE_CC
typeset -r LIBTORRENT_CXX=$APPLE_CXX
typeset -r LIBTORRENT_AR=$APPLE_AR
typeset -r LIBTORRENT_RANLIB=$APPLE_RANLIB
typeset -r ARCH_LIPO=$APPLE_LIPO
typeset -r DEFAULT_DEPS_DIR="$ROOT_DIR/.build/deps"
typeset -r DEFAULT_SOURCE_CACHE_DIR="$DEFAULT_DEPS_DIR/source-cache"
typeset -r SOURCE_CACHE_DIR=${SOURCE_CACHE_DIR:-$DEFAULT_SOURCE_CACHE_DIR}
typeset -r SOURCE_CACHE_SEED_DIR=${SOURCE_CACHE_SEED_DIR:-}
typeset -r ARCHIVE_CACHE_DIR="$SOURCE_CACHE_DIR/archives"
typeset -r GIT_CACHE_DIR="$SOURCE_CACHE_DIR/git"
typeset -r SANITIZER_PROFILE=${SANITIZER_PROFILE:-}
case "$SANITIZER_PROFILE" in
    ""|address|thread) ;;
    *) fail "SANITIZER_PROFILE must be address or thread" ;;
esac
typeset DEPS_PROFILE=$TARGET_ARCH
typeset LIBTORRENT_CMAKE_BUILD_TYPE=Release
if [[ -n "$SANITIZER_PROFILE" ]]; then
    DEPS_PROFILE="$TARGET_ARCH-$SANITIZER_PROFILE"
    LIBTORRENT_CMAKE_BUILD_TYPE="Debug"
fi
typeset -r DEPS_DIR=${DEPS_DIR:-$DEFAULT_DEPS_DIR/$DEPS_PROFILE}
typeset -r DEPS_PREFIX=${DEPS_PREFIX:-$DEPS_DIR/prefix}
typeset -r BOOST_PREFIX=${BOOST_PREFIX:-$DEPS_PREFIX}
typeset -r SOURCE_ROOT="$DEPS_DIR/src"
typeset -r BUILD_ROOT="$DEPS_DIR/build"
typeset -r BOOST_VERSION=${BOOST_VERSION:-1.92.0}
typeset -r BOOST_VERSION_UNDERSCORE=${BOOST_VERSION//./_}
typeset -r BOOST_ARCHIVE_BASENAME="boost_$BOOST_VERSION_UNDERSCORE"
typeset -r BOOST_SHA256=${BOOST_SHA256:-c4a3b310ddd2472416e091067166b0713be97c63f38c212c484ada022fd296ce}
typeset -r BOOST_TARBALL_URL=${BOOST_TARBALL_URL:-https://archives.boost.io/release/$BOOST_VERSION/source/$BOOST_ARCHIVE_BASENAME.tar.gz}
typeset -r BOOST_TARBALL="$ARCHIVE_CACHE_DIR/$BOOST_ARCHIVE_BASENAME.tar.gz"
typeset -r BOOST_SOURCE_ROOT=${BOOST_SOURCE_ROOT:-$SOURCE_CACHE_DIR/boost}
typeset -r BOOST_SOURCE_DIR="$BOOST_SOURCE_ROOT/$BOOST_ARCHIVE_BASENAME"
typeset -r BOOST_SOURCE_STAMP="$BOOST_SOURCE_DIR/.torrent-app-source"
typeset -r BOOST_HEADERS_STAMP="$BOOST_PREFIX/.torrent-app-boost-headers"
typeset -r BOOST_PATCH_HELPER="$ROOT_DIR/Scripts/boost-patch-series.sh"
typeset -r BOOST_RECYCLER_VERIFIER="$ROOT_DIR/Scripts/verify-boost-asio-recycling-allocator.zsh"
typeset -r BORINGSSL_REPO=${BORINGSSL_REPO:-https://boringssl.googlesource.com/boringssl}
typeset -r BORINGSSL_COMMIT=${BORINGSSL_COMMIT:-b0760837957bf86bd2014d258a948ee76f43c83f}
typeset -r BORINGSSL_TREE=${BORINGSSL_TREE:-8934bb26100bb063ecfaf9314ed169df37c4d44e}
typeset -r BORINGSSL_ARCHIVE_SHA256=${BORINGSSL_ARCHIVE_SHA256:-ecfd93ea2b8b10c2c93fffbba2c1d7aa0e1856faa65d1cf1b670205f42e1408f}
typeset -r BORINGSSL_MIRROR_DIR="$GIT_CACHE_DIR/boringssl.git"
typeset -r BORINGSSL_PRISTINE_ROOT=${BORINGSSL_SOURCE_ROOT:-$SOURCE_CACHE_DIR/boringssl}
typeset -r BORINGSSL_PRISTINE_DIR="$BORINGSSL_PRISTINE_ROOT/source"
typeset -r BORINGSSL_SOURCE_DIR="$SOURCE_ROOT/boringssl"
typeset -r BORINGSSL_BUILD_DIR="$BUILD_ROOT/boringssl"
typeset -r BORINGSSL_BUILD_STAMP="$DEPS_PREFIX/.torrent-app-boringssl-build"
typeset -r BORINGSSL_PROVENANCE="$DEPS_PREFIX/share/torrent7/boringssl-provenance.txt"
typeset -r BORINGSSL_PATCH_HELPER="$ROOT_DIR/Scripts/boringssl-patch-series.sh"
typeset -r BORINGSSL_HARDENING_VERIFIER="$ROOT_DIR/Scripts/verify-boringssl-hardening.zsh"
typeset -ar BORINGSSL_CMAKE_OPTIONS=(
    -DBUILD_SHARED_LIBS=OFF
    -DBUILD_TESTING=OFF
    -DOPENSSL_NO_ASM=ON
    -DOPENSSL_SMALL=ON
    -DFIPS=OFF
)
typeset -r LIBTORRENT_SOURCE_DIR="$SOURCE_ROOT/libtorrent"
typeset -r LIBTORRENT_BUILD_DIR="$BUILD_ROOT/libtorrent"
typeset -r LIBTORRENT_BUILD_STAMP="$DEPS_PREFIX/.torrent-app-libtorrent-build"
typeset -r LIBTORRENT_PROVENANCE="$DEPS_PREFIX/share/torrent7/libtorrent-provenance.txt"
typeset -r LIBTORRENT_PATCH_HELPER="$ROOT_DIR/Scripts/libtorrent-patch-series.sh"
typeset -r LIBTORRENT_TLS_VERIFIER="$ROOT_DIR/Scripts/verify-libtorrent-boringssl-tls.zsh"
typeset -r LIBTORRENT_REPO=${LIBTORRENT_REPO:-https://github.com/arvidn/libtorrent.git}
typeset -r LIBTORRENT_TAG=${LIBTORRENT_TAG:-v2.1.1}
typeset -r LIBTORRENT_COMMIT=$("$LIBTORRENT_PATCH_HELPER" commit)
typeset -r LIBTORRENT_MIRROR_DIR="$GIT_CACHE_DIR/libtorrent.git"
typeset -r LIBTORRENT_SUBMODULE_MIRROR_ROOT="$GIT_CACHE_DIR/libtorrent-submodules"
typeset -ar LIBTORRENT_REQUIRED_SUBMODULES=(
    deps/try_signal
)
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
    -Dssl-torrents=OFF
    -Dexceptions=ON
    -Dgnutls=OFF
    -Dextensions=ON
    -Di2p=OFF
    -Dlogging=OFF
    -Dmutable-torrents=OFF
    -Dstreaming=OFF
    -Dwebtorrent=OFF
)
typeset -r LIBTORRENT_EXTRA_DEFINES="-DTORRENT_DISABLE_SUPERSEEDING -DTORRENT_DISABLE_SHARE_MODE -DTORRENT_DISABLE_PREDICTIVE_PIECES"
# These AppleClang diagnostics are audited upstream implementation patterns:
# incomplete negative capability annotations and ordinary named return paths.
# Keep the suppressions scoped to the pinned libtorrent build rather than
# weakening bridge warnings.
typeset -r LIBTORRENT_UPSTREAM_WARNING_FLAGS="-Wno-thread-safety-negative -Wno-nrvo"
typeset -r ALLOW_EXTERNAL_DEPS_CLEAN=${ALLOW_EXTERNAL_DEPS_CLEAN:-0}
typeset -a TEMPORARY_FILES=()
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
typeset -r ZERO_CALL_USED_REGS_FLAG="-fzero-call-used-regs=used-gpr"
typeset -r RETAIN_NULL_POINTER_CHECKS_FLAG="-fno-delete-null-pointer-checks"
typeset -r NO_STRICT_ALIASING_FLAG="-fno-strict-aliasing"
# BoringSSL and libtorrent intentionally use unsigned modular arithmetic and
# narrowing. Reserve those extra traps for the owned Bridge; keep dependency
# production profiles focused on actual UB and bounds.
typeset -r DEPENDENCY_TRAP_ONLY_SANITIZERS="undefined,local-bounds"
typeset -r DEPENDENCY_TRAP_ONLY_FLAGS="-fsanitize=$DEPENDENCY_TRAP_ONLY_SANITIZERS -fsanitize-trap=$DEPENDENCY_TRAP_ONLY_SANITIZERS -fno-sanitize-recover=$DEPENDENCY_TRAP_ONLY_SANITIZERS"
typeset LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE
# Keep fortify out of sanitizer profiles so it cannot obscure reports.
typeset FORTIFY_FLAGS="-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3"
typeset BORINGSSL_SANITIZER_FLAGS="$DEPENDENCY_TRAP_ONLY_FLAGS"
typeset LIBTORRENT_SANITIZER_FLAGS="$DEPENDENCY_TRAP_ONLY_FLAGS"
case "$SANITIZER_PROFILE" in
    address)
        BORINGSSL_SANITIZER_FLAGS="-g -fno-omit-frame-pointer -fsanitize=address,undefined,local-bounds -fsanitize-address-use-after-scope -fno-sanitize-recover=undefined,local-bounds"
        LIBTORRENT_SANITIZER_FLAGS="-g -O1 -fno-omit-frame-pointer -fsanitize=address,undefined,local-bounds -fsanitize-address-use-after-scope -fno-sanitize-recover=undefined,local-bounds"
        ;;
    thread)
        BORINGSSL_SANITIZER_FLAGS="-g -O1 -fno-omit-frame-pointer -fsanitize=thread,undefined,local-bounds -fno-sanitize-recover=undefined,local-bounds"
        LIBTORRENT_SANITIZER_FLAGS="-g -O1 -fno-omit-frame-pointer -fsanitize=thread,undefined,local-bounds -fno-sanitize-recover=undefined,local-bounds"
        ;;
esac
if [[ -n "$SANITIZER_PROFILE" ]]; then
    LIBCPP_HARDENING_MODE="_LIBCPP_HARDENING_MODE_DEBUG"
    FORTIFY_FLAGS="-U_FORTIFY_SOURCE"
fi
typeset -r HARDENED_COMMON_PREFIX="-Wformat -Wformat-security -Werror=format-security -fstack-protector-strong $FORTIFY_FLAGS -fPIE -ftrivial-auto-var-init=zero $RETAIN_NULL_POINTER_CHECKS_FLAG"
typeset -r HARDENED_COMMON_SUFFIX="$NO_STRICT_ALIASING_FLAG -fvisibility=hidden -faarch64-jump-table-hardening $STRICT_FLEX_ARRAYS_FLAG $BRANCH_TARGET_IDENTIFICATION_FLAG $SLS_HARDENING_FLAG $ZERO_CALL_USED_REGS_FLAG $PTRAUTH_C_FLAGS"
typeset -r BORINGSSL_HARDENED_COMMON_FLAGS="$HARDENED_COMMON_PREFIX $HARDENED_COMMON_SUFFIX"
typeset -r LIBTORRENT_HARDENED_COMMON_FLAGS="$HARDENED_COMMON_PREFIX $HARDENED_COMMON_SUFFIX"
typeset -r LIBTORRENT_HARDENED_C_FLAGS="$LIBTORRENT_HARDENED_COMMON_FLAGS $TYPED_ALLOCATOR_C_FLAGS"
typeset -r BORINGSSL_HARDENED_C_FLAGS="$BORINGSSL_HARDENED_COMMON_FLAGS $TYPED_ALLOCATOR_C_FLAGS"
typeset -r BORINGSSL_HARDENED_CXX_FLAGS="$BORINGSSL_HARDENED_COMMON_FLAGS $PTRAUTH_CXX_FLAGS $TYPED_ALLOCATOR_CXX_FLAGS -D_LIBCPP_HARDENING_MODE=$LIBCPP_HARDENING_MODE -fvisibility-inlines-hidden"
typeset -r LIBTORRENT_HARDENED_CXX_FLAGS="$LIBTORRENT_HARDENED_COMMON_FLAGS $PTRAUTH_CXX_FLAGS $TYPED_ALLOCATOR_CXX_FLAGS -D_LIBCPP_HARDENING_MODE=$LIBCPP_HARDENING_MODE -fvisibility-inlines-hidden"
typeset -r BORINGSSL_CFLAGS="$BORINGSSL_HARDENED_C_FLAGS $BORINGSSL_SANITIZER_FLAGS -isysroot $SDK_PATH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
typeset -r BORINGSSL_CXXFLAGS="$BORINGSSL_HARDENED_CXX_FLAGS $BORINGSSL_SANITIZER_FLAGS -isysroot $SDK_PATH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
typeset LIBTORRENT_C_FLAGS="$LIBTORRENT_HARDENED_C_FLAGS $LIBTORRENT_SANITIZER_FLAGS"
typeset LIBTORRENT_CXX_FLAGS="$LIBTORRENT_HARDENED_CXX_FLAGS $LIBTORRENT_SANITIZER_FLAGS"
LIBTORRENT_C_FLAGS="$LIBTORRENT_C_FLAGS $LIBTORRENT_EXTRA_DEFINES"
LIBTORRENT_CXX_FLAGS="$LIBTORRENT_CXX_FLAGS $LIBTORRENT_EXTRA_DEFINES $LIBTORRENT_UPSTREAM_WARNING_FLAGS"

require_tool() {
    local -r tool=$1
    [[ -n ${commands[$tool]:-} ]] || fail "Missing required tool: $tool"
}

require_path() {
    local -r required_path=$1
    local -r label=$2
    [[ -e $required_path ]] || fail "Missing $label: $required_path"
}

cleanup_temporary_files() {
    /bin/rm -f -- "${TEMPORARY_FILES[@]}"
}
trap cleanup_temporary_files EXIT

make_temporary_file() {
    local -r destination=$1
    local -r directory=${destination:h}

    mkdir -p -- "$directory"
    REPLY=$(/usr/bin/mktemp "$directory/.${destination:t}.tmp.XXXXXXXX") \
        || fail "Could not create temporary file for $destination"
    TEMPORARY_FILES+=("$REPLY")
}

remove_dependency_path() {
    local target="$1"
    local default_root=""
    local target_parent
    local within_default=0

    # A caller may choose a fresh external cache or build root. There is
    # nothing to authorize until an existing entry would actually be removed.
    # Check -L separately so a dangling symlink remains protected.
    if [[ ! -e "$target" && ! -L "$target" ]]; then
        return
    fi

    # Only the literal in-project cache is trusted implicitly. If either fixed
    # parent is a symlink, its physical destination is external and requires
    # the same explicit opt-in as any other external dependency location.
    if [[ ! -L "$ROOT_DIR/.build" && ! -L "$DEFAULT_DEPS_DIR" ]]; then
        mkdir -p -- "$DEFAULT_DEPS_DIR"
        default_root="$(cd "$DEFAULT_DEPS_DIR" && pwd -P)"
        [[ "$default_root" == "$DEFAULT_DEPS_DIR" ]] || default_root=""
    fi

    mkdir -p -- "$(dirname "$target")"
    target_parent="$(cd "$(dirname "$target")" && pwd -P)"

    if [[ -n "$default_root" ]]; then
        case "$target_parent/" in
            "$default_root"/*) within_default=1 ;;
        esac
    fi
    if [[ "$within_default" == "1" ]]; then
        rm -rf -- "$target"
    elif [[ "$ALLOW_EXTERNAL_DEPS_CLEAN" == "1" ]]; then
        rm -rf -- "$target"
    else
        print -ru2 -- "Refusing to remove external dependency path: $target"
        print -ru2 -- "Set ALLOW_EXTERNAL_DEPS_CLEAN=1 to allow cleanup outside $DEFAULT_DEPS_DIR."
        exit 1
    fi
}

is_exact_git_checkout() {
    local path="$1"
    local top_level

    [[ -d "$path" ]] || return 1
    top_level="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [[ "${top_level:A}" == "${path:A}" ]]
}

is_usable_git_mirror() {
    local path="$1"
    local expected_commit="${2:-}"
    local is_bare

    [[ -d "$path" ]] || return 1
    is_bare="$(git -C "$path" rev-parse --is-bare-repository 2>/dev/null)" \
        || return 1
    [[ "$is_bare" == "true" ]] || return 1
    [[ -z "$expected_commit" ]] \
        || git -C "$path" rev-parse --verify "$expected_commit^{commit}" >/dev/null 2>&1
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
    local -a candidates=()

    if [[ -n $SOURCE_CACHE_SEED_DIR ]]; then
        candidates+=("$SOURCE_CACHE_SEED_DIR/archives/$basename")
    fi
    candidates+=(
        "$DEPS_DIR/src/$basename"
        "$DEFAULT_DEPS_DIR/$TARGET_ARCH/src/$basename"
        "$DEFAULT_DEPS_DIR/$TARGET_ARCH-address/src/$basename"
        "$DEFAULT_DEPS_DIR/$TARGET_ARCH-thread/src/$basename"
    )

    for candidate in "${candidates[@]}"; do
        if [[ "$candidate" == "$output" || ! -f "$candidate" ]]; then
            continue
        fi

        make_temporary_file "$output"
        tmp=$REPLY
        /bin/cp "$candidate" "$tmp"
        verify_sha256 "$tmp" "$expected_sha256"
        /bin/mv -fh "$tmp" "$output"
        return 0
    done

    return 1
}

stamp_matches() {
    local stamp="$1"
    local generator="$2"
    local base="$3"
    local expected

    [[ -f "$stamp" && ! -L "$stamp" ]] || return 1
    prepare_stamp_directory "$base" "${stamp:h}"
    expected="$("$generator")"
    [[ "$(cat "$stamp")" == "$expected" ]]
}

prepare_stamp_directory() {
    local base="${1:a}"
    local directory="${2:a}"
    local relative
    local current
    local component
    local next
    local -a components

    [[ -d "$base" && ! -L "$base" ]] \
        || fail "Refusing stamp access through a symlinked dependency prefix: $base"
    case "$directory/" in
        "$base/"*) ;;
        *) fail "Refusing stamp path outside dependency prefix: $directory" ;;
    esac

    relative=${directory#"$base"}
    relative=${relative#/}
    if [[ -z "$relative" ]]; then
        return 0
    fi
    components=("${(@s:/:)relative}")
    current="$base"
    for component in "${components[@]}"; do
        [[ -n "$component" && "$component" != "." && "$component" != ".." ]] \
            || fail "Invalid dependency stamp path: $directory"
        next="$current/$component"
        [[ ! -L "$next" ]] \
            || fail "Refusing stamp access through a symlinked cache directory: $next"
        if [[ ! -e "$next" ]]; then
            mkdir -- "$next"
        fi
        [[ -d "$next" ]] || fail "Dependency stamp parent is not a directory: $next"
        current="$next"
    done
}

write_stamp() {
    local stamp="$1"
    local generator="$2"
    local base="$3"
    local directory="${stamp:h}"
    local temporary

    prepare_stamp_directory "$base" "$directory"
    temporary="$(/usr/bin/mktemp "$directory/.${stamp:t}.tmp.XXXXXXXX")" \
        || fail "Could not create temporary dependency stamp"
    if ! "$generator" >"$temporary"; then
        rm -f -- "$temporary"
        fail "Could not generate dependency stamp: $stamp"
    fi
    if ! /bin/mv -fh "$temporary" "$stamp"; then
        rm -f -- "$temporary"
        fail "Could not publish dependency stamp: $stamp"
    fi
}

boringssl_cmake_options_text() {
    print -r -- "${(j: :)BORINGSSL_CMAKE_OPTIONS}"
}

libtorrent_cmake_options_text() {
    print -r -- "${(j: :)LIBTORRENT_CMAKE_OPTIONS}"
}

boost_source_manifest() {
    cat <<EOF
boost-archive-sha256=$BOOST_SHA256
boost-url=$BOOST_TARBALL_URL
boost-patch-helper-sha256=$(file_sha256 "$BOOST_PATCH_HELPER")
$("$BOOST_PATCH_HELPER" manifest "$BOOST_SOURCE_DIR")
EOF
}

boost_headers_manifest() {
    cat <<EOF
$(boost_source_manifest)
boost-prefix=$BOOST_PREFIX
boost-source-stamp-sha256=$(file_sha256 "$BOOST_SOURCE_STAMP")
EOF
}

boringssl_build_manifest() {
    cat <<EOF
boringssl-repo=$BORINGSSL_REPO
boringssl-base-tree=$BORINGSSL_TREE
boringssl-archive-sha256=$BORINGSSL_ARCHIVE_SHA256
boringssl-patch-helper-sha256=$(file_sha256 "$BORINGSSL_PATCH_HELPER")
$("$BORINGSSL_PATCH_HELPER" manifest "$BORINGSSL_SOURCE_DIR")
target-arch=$TARGET_ARCH
target-triple=$TARGET_TRIPLE
deployment-target=$MACOSX_DEPLOYMENT_TARGET
sanitizer-profile=${SANITIZER_PROFILE:-none}
sdk=$SDK_PATH
cmake-options=$(boringssl_cmake_options_text)
compiler-c=$BORINGSSL_CC
compiler-c-sha256=$(file_sha256 "$BORINGSSL_CC")
compiler-cxx=$BORINGSSL_CXX
compiler-cxx-sha256=$(file_sha256 "$BORINGSSL_CXX")
ar=$BORINGSSL_AR
ar-sha256=$(file_sha256 "$BORINGSSL_AR")
ranlib=$BORINGSSL_RANLIB
ranlib-sha256=$(file_sha256 "$BORINGSSL_RANLIB")
cflags=$BORINGSSL_CFLAGS
cxxflags=$BORINGSSL_CXXFLAGS
EOF
}

libtorrent_build_manifest() {
    cat <<EOF
libtorrent-tag=$LIBTORRENT_TAG
libtorrent-patch-helper-sha256=$(file_sha256 "$LIBTORRENT_PATCH_HELPER")
$("$LIBTORRENT_PATCH_HELPER" manifest "$LIBTORRENT_SOURCE_DIR")
target-arch=$TARGET_ARCH
target-triple=$TARGET_TRIPLE
deployment-target=$MACOSX_DEPLOYMENT_TARGET
sanitizer-profile=${SANITIZER_PROFILE:-none}
cmake-build-type=$LIBTORRENT_CMAKE_BUILD_TYPE
sdk=$SDK_PATH
compiler-c=$LIBTORRENT_CC
compiler-c-sha256=$(file_sha256 "$LIBTORRENT_CC")
compiler-cxx=$LIBTORRENT_CXX
compiler-cxx-sha256=$(file_sha256 "$LIBTORRENT_CXX")
ar=$LIBTORRENT_AR
ar-sha256=$(file_sha256 "$LIBTORRENT_AR")
ranlib=$LIBTORRENT_RANLIB
ranlib-sha256=$(file_sha256 "$LIBTORRENT_RANLIB")
c-flags=$LIBTORRENT_C_FLAGS
cxx-flags=$LIBTORRENT_CXX_FLAGS
cmake-options=$(libtorrent_cmake_options_text)
boringssl-prefix=$DEPS_PREFIX
boringssl-build-stamp-sha256=$(file_sha256 "$BORINGSSL_BUILD_STAMP")
boringssl-cmake-options=$(boringssl_cmake_options_text)
boost-version=$BOOST_VERSION
boost-sha256=$BOOST_SHA256
boost-prefix=$BOOST_PREFIX
boost-patch-helper-sha256=$(file_sha256 "$BOOST_PATCH_HELPER")
$("$BOOST_PATCH_HELPER" manifest "$BOOST_SOURCE_DIR" | /usr/bin/sed '1d')
boost-headers-stamp-sha256=$(file_sha256 "$BOOST_HEADERS_STAMP")
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

    tmpdir="$(/usr/bin/mktemp -d)"
    (cd "$tmpdir" && /usr/bin/xcrun ar -x "$archive")
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

        if ! header="$(/usr/bin/xcrun otool -hv "$member" 2>/dev/null | tail -n 1)"; then
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

verify_libtorrent_typed_allocation_coverage() {
    local archive="$1"
    local symbols
    local raw_c_allocators
    local untyped_cpp_allocators

    require_path "$archive" "libtorrent static archive"
    symbols="$(/usr/bin/xcrun nm -u "$archive")"

    raw_c_allocators="$(
        print -r -- "$symbols" \
            | /usr/bin/awk '$NF ~ /^_(malloc|calloc|realloc|aligned_alloc|valloc|posix_memalign)$/ { print $NF }' \
            | /usr/bin/sort -u
    )"
    if [[ -n "$raw_c_allocators" ]]; then
        print -ru2 -- "libtorrent imports untyped C allocation functions:"
        print -ru2 -- "$raw_c_allocators"
        exit 1
    fi

    untyped_cpp_allocators="$(
        print -r -- "$symbols" \
            | /usr/bin/awk '$NF ~ /^__Zn[aw]m/ && $NF !~ /^__Zn[aw]mSt19__type_descriptor_t$/ { print $NF }' \
            | /usr/bin/sort -u
    )"
    if [[ -n "$untyped_cpp_allocators" ]]; then
        print -ru2 -- "libtorrent imports untyped global C++ allocation functions:"
        print -ru2 -- "$untyped_cpp_allocators"
        exit 1
    fi

    print -r -- "$symbols" | /usr/bin/awk '$NF == "_malloc_type_malloc" { found = 1 } END { exit !found }' \
        || fail "libtorrent has no typed malloc import: $archive"
    print -r -- "$symbols" | /usr/bin/awk '$NF == "_malloc_type_aligned_alloc" { found = 1 } END { exit !found }' \
        || fail "libtorrent has no typed aligned allocation import: $archive"
    print -r -- "$symbols" | /usr/bin/awk '$NF == "__ZnwmSt19__type_descriptor_t" { found = 1 } END { exit !found }' \
        || fail "libtorrent has no typed global operator new import: $archive"
    print -r -- "$symbols" | /usr/bin/awk '$NF == "__ZnamSt19__type_descriptor_t" { found = 1 } END { exit !found }' \
        || fail "libtorrent has no typed global operator new[] import: $archive"
}

verify_libtorrent_trap_only_ubsan() {
    local archive="$1"
    local disassembly
    local undefined_symbols

    [[ -z "$SANITIZER_PROFILE" ]] || return 0
    require_path "$archive" "libtorrent static archive"
    make_temporary_file "$DEPS_DIR/libtorrent-trap-only-ubsan.txt"
    disassembly=$REPLY
    /usr/bin/xcrun otool -tvV "$archive" >"$disassembly"
    /usr/bin/awk '$2 == "brk" && $3 ~ /^#0x55/ { found = 1 } END { exit !found }' "$disassembly" \
        || fail "libtorrent has no trap-only UBSan instrumentation: $archive"

    undefined_symbols="$(/usr/bin/xcrun nm -u "$archive")"
    if print -r -- "$undefined_symbols" | /usr/bin/grep -q '___ubsan_handle_'; then
        fail "Normal libtorrent archive unexpectedly depends on the UBSan runtime: $archive"
    fi
}

verify_libtorrent_indirect_operation_pac() {
    local archive="$1"
    local disassembly
    local discriminator
    local instruction
    local role_and_instruction

    require_path "$archive" "libtorrent static archive"
    make_temporary_file "$DEPS_DIR/libtorrent-indirect-operation-pac.txt"
    disassembly=$REPLY
    "$ARCH_LIPO" "$archive" -verify_arch arm64e \
        || fail "Boost.Asio PAC verification requires an arm64e libtorrent archive"
    /usr/bin/xcrun otool -tvV "$archive" >"$disassembly"

    # AppleClang's pinned 16-bit string discriminators for the active Asio
    # operation/executor slots and libtorrent's chained-buffer destructor.
    for discriminator in 0x8ab7 0xaf42 0x9890 0x4642 0x2a6 0x89ff; do
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
        ' "$disassembly" || fail \
            "libtorrent has no address-diversified indirect callback branch for role $discriminator"
    done

    for role_and_instruction in 0x8444:pacia 0x5f88:pacdb; do
        discriminator=${role_and_instruction%%:*}
        instruction=${role_and_instruction#*:}
        /usr/bin/awk -v discriminator="#$discriminator" \
            -v instruction="$instruction" '
        /movk[[:space:]]+x[0-9]+,/ && index($0, discriminator) {
            modifier = $3
            sub(/,$/, "", modifier)
            remaining = 4
        }
        remaining > 0 && index($0, "\t" instruction "\t") \
            && index($0, ", " modifier) { found = 1 }
        remaining > 0 { remaining-- }
        END { exit !found }
        ' "$disassembly" || fail \
            "libtorrent has no address-diversified executor-function-view $instruction for role $discriminator"
    done

    # Active Asio type-erasure carriers use the process-dependent data key,
    # with independent address-and-role discriminators for each stored role.
    for discriminator in 0xc4a3 0x8efa 0xeffa 0x380f 0xed97; do
        /usr/bin/awk -v discriminator="#$discriminator" '
            /movk[[:space:]]+x[0-9]+,/ && index($0, discriminator) {
                modifier = $3
                sub(/,$/, "", modifier)
                remaining = 4
            }
            remaining > 0 && /[[:space:]]autdb[[:space:]]/ \
                && index($0, ", " modifier) { found = 1 }
            remaining > 0 { remaining-- }
            END { exit !found }
        ' "$disassembly" || fail \
            "libtorrent has no address-diversified Asio carrier authentication for role $discriminator"
    done

    # heterogeneous_queue authenticates and re-signs the copied header before
    # the eventual move callback, so its modifier can be live for longer.
    /usr/bin/awk -v discriminator="#0xf073" '
        /movk[[:space:]]+x[0-9]+,/ && index($0, discriminator) {
            register = $3
            sub(/,$/, "", register)
            remaining[register] = 24
        }
        /[[:space:]](braa|blraa)[[:space:]]/ {
            for (register in remaining) {
                if (remaining[register] > 0 && index($0, ", " register))
                    found = 1
            }
        }
        {
            for (register in remaining) {
                if (remaining[register] > 0)
                    remaining[register]--
            }
        }
        END { exit !found }
    ' "$disassembly" || fail \
        "libtorrent has no address-diversified heterogeneous-queue move callback branch"
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

    local tmp
    make_temporary_file "$BOOST_TARBALL"
    tmp=$REPLY
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
    /bin/mv -fh "$tmp" "$BOOST_TARBALL"
}

extract_boost() {
    local legacy_stamp="$BOOST_SOURCE_DIR/.torrent-app-sha256"
    local actual_tree
    local recorded_tree
    local source_matches_archive=0

    if [[ -d "$BOOST_SOURCE_DIR" ]]; then
        if [[ -f "$legacy_stamp" && ! -L "$legacy_stamp" \
            && "$(cat "$legacy_stamp")" == "$BOOST_SHA256" ]]; then
            source_matches_archive=1
        elif [[ -f "$BOOST_SOURCE_STAMP" && ! -L "$BOOST_SOURCE_STAMP" ]] \
            && grep -qx "boost-archive-sha256=$BOOST_SHA256" "$BOOST_SOURCE_STAMP"; then
            source_matches_archive=1
        fi

        actual_tree="$("$BOOST_PATCH_HELPER" worktree-tree "$BOOST_SOURCE_DIR")" \
            || fail "Could not inspect cached Boost source"
        if [[ "$source_matches_archive" == "1" ]] \
            && "$BOOST_PATCH_HELPER" can-apply "$BOOST_SOURCE_DIR"; then
            "$BOOST_PATCH_HELPER" apply "$BOOST_SOURCE_DIR"
            write_stamp "$BOOST_SOURCE_STAMP" boost_source_manifest "$BOOST_SOURCE_DIR"
            rm -f -- "$legacy_stamp"
            return
        fi

        if [[ -f "$BOOST_SOURCE_STAMP" && ! -L "$BOOST_SOURCE_STAMP" ]]; then
            recorded_tree="$(awk -F= '$1 == "boost-patched-files-tree" { print $2 }' \
                "$BOOST_SOURCE_STAMP")"
        else
            recorded_tree=""
        fi
        [[ -n "$recorded_tree" && "$actual_tree" == "$recorded_tree" ]] \
            || fail "Refusing to replace cached Boost source with unexpected local changes: $BOOST_SOURCE_DIR"
    fi

    remove_dependency_path "$BOOST_SOURCE_DIR"
    mkdir -p "$BOOST_SOURCE_ROOT"
    tar -xzf "$BOOST_TARBALL" -C "$BOOST_SOURCE_ROOT"
    require_path "$BOOST_SOURCE_DIR/boost/version.hpp" "Boost headers"
    require_path "$BOOST_SOURCE_DIR/LICENSE_1_0.txt" "Boost license"
    "$BOOST_PATCH_HELPER" apply "$BOOST_SOURCE_DIR"
    write_stamp "$BOOST_SOURCE_STAMP" boost_source_manifest "$BOOST_SOURCE_DIR"
}

install_boost_headers() {
    if [[ -f "$BOOST_PREFIX/include/boost/version.hpp" ]] && stamp_matches "$BOOST_HEADERS_STAMP" boost_headers_manifest "$BOOST_PREFIX"; then
        "$BOOST_PATCH_HELPER" verify "$BOOST_PREFIX/include"
        return
    fi

    remove_dependency_path "$BOOST_PREFIX/include/boost"
    mkdir -p "$BOOST_PREFIX/include" "$BOOST_PREFIX/share/licenses/boost"
    cp -R "$BOOST_SOURCE_DIR/boost" "$BOOST_PREFIX/include/"
    cp "$BOOST_SOURCE_DIR/LICENSE_1_0.txt" "$BOOST_PREFIX/share/licenses/boost/LICENSE_1_0.txt"
    write_stamp "$BOOST_HEADERS_STAMP" boost_headers_manifest "$BOOST_PREFIX"
    "$BOOST_PATCH_HELPER" verify "$BOOST_PREFIX/include"
}

ensure_git_mirror() {
    local repo_url="$1"
    local mirror_dir="$2"
    local label="$3"
    local seed_checkout="${4:-}"
    local expected_commit="${5:-}"
    local seed_mirror="${6:-}"
    local shallow="${7:-0}"

    if [[ -e "$mirror_dir" ]] && ! git -C "$mirror_dir" rev-parse --is-bare-repository >/dev/null 2>&1; then
        remove_dependency_path "$mirror_dir"
    fi

    if [[ ! -d "$mirror_dir" ]]; then
        mkdir -p "$(dirname "$mirror_dir")"
        if [[ -n "$seed_mirror" ]] && is_usable_git_mirror "$seed_mirror" "$expected_commit"; then
            if [[ "$shallow" == "1" ]]; then
                git clone --bare --depth=1 --no-local "$seed_mirror" "$mirror_dir"
            else
                git clone --mirror --no-hardlinks "$seed_mirror" "$mirror_dir"
            fi
            git -C "$mirror_dir" fsck --full --strict
        elif [[ -n "$seed_checkout" ]] && is_exact_git_checkout "$seed_checkout"; then
            if [[ "$shallow" == "1" ]]; then
                git clone --bare --depth=1 --no-local "$seed_checkout" "$mirror_dir"
            else
                git clone --mirror "$seed_checkout" "$mirror_dir"
            fi
        elif [[ "$shallow" == "1" ]]; then
            git clone --bare --depth=1 "$repo_url" "$mirror_dir"
        else
            git clone --mirror "$repo_url" "$mirror_dir"
        fi
    fi

    git -C "$mirror_dir" remote set-url origin "$repo_url"

    if [[ -n "$expected_commit" ]] && ! git -C "$mirror_dir" rev-parse --verify "$expected_commit^{commit}" >/dev/null 2>&1; then
        if [[ "$shallow" == "1" ]]; then
            git -C "$mirror_dir" fetch --depth=1 origin "$expected_commit"
        else
            git -C "$mirror_dir" fetch --tags --prune origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
        fi
    fi

    if [[ -n "$expected_commit" ]] && ! git -C "$mirror_dir" rev-parse --verify "$expected_commit^{commit}" >/dev/null 2>&1; then
        fail "$label mirror does not contain expected commit: $expected_commit"
    fi
}

boringssl_checkout_status() {
    local source="$1"
    git -C "$source" status --porcelain=v1 --untracked-files=all
}

verify_pristine_boringssl_source() {
    local current_commit
    local current_tree
    local archive_sha256

    current_commit="$(git -C "$BORINGSSL_PRISTINE_DIR" rev-parse HEAD)"
    current_tree="$(git -C "$BORINGSSL_PRISTINE_DIR" rev-parse 'HEAD^{tree}')"
    archive_sha256="$(git -C "$BORINGSSL_PRISTINE_DIR" archive HEAD | shasum -a 256 | awk '{print $1}')"

    [[ "$current_commit" == "$BORINGSSL_COMMIT" ]] \
        || fail "BoringSSL checkout mismatch: expected $BORINGSSL_COMMIT, got $current_commit"
    [[ "$current_tree" == "$BORINGSSL_TREE" ]] \
        || fail "BoringSSL tree mismatch: expected $BORINGSSL_TREE, got $current_tree"
    [[ "$archive_sha256" == "$BORINGSSL_ARCHIVE_SHA256" ]] \
        || fail "BoringSSL source archive mismatch: expected $BORINGSSL_ARCHIVE_SHA256, got $archive_sha256"
    [[ -z "$(boringssl_checkout_status "$BORINGSSL_PRISTINE_DIR")" ]] \
        || fail "Pristine BoringSSL checkout has local changes: $BORINGSSL_PRISTINE_DIR"
    [[ ! -e "$BORINGSSL_PRISTINE_DIR/.gitmodules" ]] \
        || fail "Pinned BoringSSL unexpectedly contains submodules"
    require_path "$BORINGSSL_PRISTINE_DIR/CMakeLists.txt" "BoringSSL CMake project"
    require_path "$BORINGSSL_PRISTINE_DIR/LICENSE" "BoringSSL license"
}

prepare_boringssl_source() {
    local seed_mirror=""
    local current
    local checkout_status

    if [[ -n "$SOURCE_CACHE_SEED_DIR" ]]; then
        seed_mirror="$SOURCE_CACHE_SEED_DIR/git/boringssl.git"
    fi
    ensure_git_mirror "$BORINGSSL_REPO" "$BORINGSSL_MIRROR_DIR" "BoringSSL" \
        "$BORINGSSL_PRISTINE_DIR" "$BORINGSSL_COMMIT" "$seed_mirror" 1

    mkdir -p "$BORINGSSL_PRISTINE_ROOT"
    if [[ -d "$BORINGSSL_PRISTINE_DIR/.git" ]]; then
        current="$(git -C "$BORINGSSL_PRISTINE_DIR" rev-parse HEAD 2>/dev/null || true)"
        checkout_status="$(boringssl_checkout_status "$BORINGSSL_PRISTINE_DIR")"
        if [[ "$current" != "$BORINGSSL_COMMIT" ]]; then
            [[ -z "$checkout_status" ]] \
                || fail "Refusing to replace a pristine BoringSSL checkout with local changes: $BORINGSSL_PRISTINE_DIR"
            remove_dependency_path "$BORINGSSL_PRISTINE_DIR"
        elif [[ -n "$checkout_status" ]]; then
            fail "Pristine BoringSSL checkout has local changes: $BORINGSSL_PRISTINE_DIR"
        fi
    elif [[ -e "$BORINGSSL_PRISTINE_DIR" ]]; then
        remove_dependency_path "$BORINGSSL_PRISTINE_DIR"
    fi

    if [[ ! -d "$BORINGSSL_PRISTINE_DIR/.git" ]]; then
        git clone --no-checkout "$BORINGSSL_MIRROR_DIR" "$BORINGSSL_PRISTINE_DIR"
        git -C "$BORINGSSL_PRISTINE_DIR" remote set-url origin "$BORINGSSL_REPO"
        git -C "$BORINGSSL_PRISTINE_DIR" checkout --detach "$BORINGSSL_COMMIT"
    else
        git -C "$BORINGSSL_PRISTINE_DIR" remote set-url origin "$BORINGSSL_REPO"
    fi
    verify_pristine_boringssl_source

    mkdir -p "$SOURCE_ROOT"
    if [[ -d "$BORINGSSL_SOURCE_DIR/.git" ]]; then
        current="$(git -C "$BORINGSSL_SOURCE_DIR" rev-parse HEAD 2>/dev/null || true)"
        checkout_status="$(boringssl_checkout_status "$BORINGSSL_SOURCE_DIR")"
        if [[ "$current" != "$BORINGSSL_COMMIT" ]]; then
            [[ -z "$checkout_status" ]] \
                || fail "Refusing to replace a patched BoringSSL checkout with unexpected local changes: $BORINGSSL_SOURCE_DIR"
            remove_dependency_path "$BORINGSSL_SOURCE_DIR"
        fi
    elif [[ -e "$BORINGSSL_SOURCE_DIR" ]]; then
        remove_dependency_path "$BORINGSSL_SOURCE_DIR"
    fi

    if [[ ! -d "$BORINGSSL_SOURCE_DIR/.git" ]]; then
        git clone --no-checkout "$BORINGSSL_MIRROR_DIR" "$BORINGSSL_SOURCE_DIR"
        git -C "$BORINGSSL_SOURCE_DIR" remote set-url origin "$BORINGSSL_REPO"
        git -C "$BORINGSSL_SOURCE_DIR" checkout --detach "$BORINGSSL_COMMIT"
        [[ "$(git -C "$BORINGSSL_SOURCE_DIR" rev-parse 'HEAD^{tree}')" == "$BORINGSSL_TREE" ]] \
            || fail "BoringSSL build checkout does not match the authenticated base tree"
        [[ -z "$(boringssl_checkout_status "$BORINGSSL_SOURCE_DIR")" ]] \
            || fail "New BoringSSL build checkout is unexpectedly dirty"
    else
        git -C "$BORINGSSL_SOURCE_DIR" remote set-url origin "$BORINGSSL_REPO"
    fi

    "$BORINGSSL_PATCH_HELPER" apply "$BORINGSSL_SOURCE_DIR"
    "$BORINGSSL_PATCH_HELPER" verify "$BORINGSSL_SOURCE_DIR"
}

verify_boringssl_build() {
    local compile_commands="$BORINGSSL_BUILD_DIR/compile_commands.json"
    local compile_count
    local hardened_count
    local artifact

    require_path "$DEPS_PREFIX/include/openssl/base.h" "BoringSSL public headers"
    require_path "$DEPS_PREFIX/share/licenses/boringssl/LICENSE" "BoringSSL license"
    require_path "$compile_commands" "BoringSSL compile database"
    grep -q '^#define OPENSSL_IS_BORINGSSL' "$DEPS_PREFIX/include/openssl/base.h" \
        || fail "Installed TLS headers are not BoringSSL"
    grep -q '^OPENSSL_NO_ASM:.*=ON$' "$BORINGSSL_BUILD_DIR/CMakeCache.txt" \
        || fail "BoringSSL was not configured with OPENSSL_NO_ASM=ON"
    grep -q '^OPENSSL_SMALL:.*=ON$' "$BORINGSSL_BUILD_DIR/CMakeCache.txt" \
        || fail "BoringSSL was not configured with OPENSSL_SMALL=ON"
    grep -q '^BUILD_TESTING:BOOL=OFF$' "$BORINGSSL_BUILD_DIR/CMakeCache.txt" \
        || fail "BoringSSL tests were not disabled"
    if grep -Eq '"file": ".*\.(S|s|asm)"' "$compile_commands"; then
        fail "BoringSSL compile database contains assembly sources"
    fi
    compile_count="$(grep -c '"file":' "$compile_commands")"
    hardened_count="$(grep -c '"command":.*-DOPENSSL_NO_ASM.*-DOPENSSL_SMALL' "$compile_commands")"
    [[ "$compile_count" -gt 0 && "$hardened_count" == "$compile_count" ]] \
        || fail "BoringSSL compile commands do not consistently disable assembly and enable OPENSSL_SMALL"

    for artifact in \
        "$DEPS_PREFIX/lib/libdecrepit.a" \
        "$DEPS_PREFIX/lib/libpki.a" \
        "$DEPS_PREFIX/bin/bssl"; do
        [[ ! -e "$artifact" ]] || fail "Unexpected BoringSSL artifact was installed: $artifact"
    done

    verify_archive_arch "$DEPS_PREFIX/lib/libssl.a" "$TARGET_ARCH"
    verify_archive_arch "$DEPS_PREFIX/lib/libcrypto.a" "$TARGET_ARCH"
    "$BORINGSSL_PATCH_HELPER" verify "$BORINGSSL_SOURCE_DIR"
    "$BORINGSSL_HARDENING_VERIFIER" \
        "$BORINGSSL_SOURCE_DIR" \
        "$BORINGSSL_BUILD_DIR" \
        "$DEPS_PREFIX"
}

purge_superseded_tls_metadata() {
    remove_dependency_path "$DEPS_PREFIX/share/licenses/openssl"
    remove_dependency_path "$DEPS_PREFIX/ssl"
    remove_dependency_path "$DEPS_PREFIX/lib/ossl-modules"
    remove_dependency_path "$DEPS_PREFIX/lib/engines-3"
    remove_dependency_path "$DEPS_PREFIX/lib/cmake/OpenSSL"
    rm -f \
        "$DEPS_PREFIX/bin/openssl" \
        "$DEPS_PREFIX/lib/pkgconfig/openssl.pc" \
        "$DEPS_PREFIX/lib/pkgconfig/libssl.pc" \
        "$DEPS_PREFIX/lib/pkgconfig/libcrypto.pc" \
        "$DEPS_PREFIX/.torrent-app-openssl-build" \
        "$DEPS_PREFIX/.swiftui-torrent-openssl-build"
}

build_boringssl() {
    local -a cmake_generator_args=()

    purge_superseded_tls_metadata

    if [[ -f "$DEPS_PREFIX/lib/libssl.a" \
        && -f "$DEPS_PREFIX/lib/libcrypto.a" \
        && -f "$BORINGSSL_BUILD_DIR/compile_commands.json" ]] \
        && stamp_matches "$BORINGSSL_BUILD_STAMP" boringssl_build_manifest "$DEPS_PREFIX"; then
        verify_boringssl_build
        write_stamp "$BORINGSSL_PROVENANCE" boringssl_build_manifest "$DEPS_PREFIX"
        return
    fi

    remove_dependency_path "$BORINGSSL_BUILD_DIR"
    remove_dependency_path "$DEPS_PREFIX/include/openssl"
    remove_dependency_path "$DEPS_PREFIX/share/licenses/boringssl"
    rm -f \
        "$DEPS_PREFIX/lib/libssl.a" \
        "$DEPS_PREFIX/lib/libcrypto.a" \
        "$BORINGSSL_BUILD_STAMP" \
        "$BORINGSSL_PROVENANCE"
    mkdir -p \
        "$BORINGSSL_BUILD_DIR" \
        "$DEPS_PREFIX/include" \
        "$DEPS_PREFIX/lib" \
        "$DEPS_PREFIX/share/licenses/boringssl"

    if [[ -n ${CMAKE_GENERATOR:-} ]]; then
        cmake_generator_args=(-G "$CMAKE_GENERATOR")
    elif [[ -n ${commands[ninja]:-} ]]; then
        cmake_generator_args=(-G Ninja)
    fi

    cmake \
        -S "$BORINGSSL_SOURCE_DIR" \
        -B "$BORINGSSL_BUILD_DIR" \
        "${cmake_generator_args[@]}" \
        -Wno-author \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" \
        -DCMAKE_C_COMPILER="$BORINGSSL_CC" \
        -DCMAKE_CXX_COMPILER="$BORINGSSL_CXX" \
        -DCMAKE_AR="$BORINGSSL_AR" \
        -DCMAKE_RANLIB="$BORINGSSL_RANLIB" \
        -DCMAKE_OSX_ARCHITECTURES="$TARGET_ARCH" \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        -DCMAKE_C_COMPILER_TARGET="$TARGET_TRIPLE" \
        -DCMAKE_CXX_COMPILER_TARGET="$TARGET_TRIPLE" \
        -DCMAKE_C_FLAGS="$BORINGSSL_CFLAGS" \
        -DCMAKE_CXX_FLAGS="$BORINGSSL_CXXFLAGS" \
        -DCMAKE_C_VISIBILITY_PRESET=hidden \
        -DCMAKE_CXX_VISIBILITY_PRESET=hidden \
        -DCMAKE_VISIBILITY_INLINES_HIDDEN=ON \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        "${BORINGSSL_CMAKE_OPTIONS[@]}"

    cmake --build "$BORINGSSL_BUILD_DIR" \
        --target crypto ssl \
        --parallel "${JOBS:-$(sysctl -n hw.ncpu)}"

    cp -R "$BORINGSSL_SOURCE_DIR/include/openssl" "$DEPS_PREFIX/include/"
    cp "$BORINGSSL_BUILD_DIR/libssl.a" "$DEPS_PREFIX/lib/libssl.a"
    cp "$BORINGSSL_BUILD_DIR/libcrypto.a" "$DEPS_PREFIX/lib/libcrypto.a"
    cp "$BORINGSSL_SOURCE_DIR/LICENSE" "$DEPS_PREFIX/share/licenses/boringssl/LICENSE"

    verify_boringssl_build
    write_stamp "$BORINGSSL_BUILD_STAMP" boringssl_build_manifest "$DEPS_PREFIX"
    write_stamp "$BORINGSSL_PROVENANCE" boringssl_build_manifest "$DEPS_PREFIX"
}

setup_libtorrent_submodule_mirrors() {
    local key
    local url
    local name
    local submodule_path
    local mirror_dir
    local seed_mirror
    local expected_commit

    if [[ ! -f "$LIBTORRENT_SOURCE_DIR/.gitmodules" || ${#LIBTORRENT_REQUIRED_SUBMODULES[@]} -eq 0 ]]; then
        return
    fi

    for name in "${LIBTORRENT_REQUIRED_SUBMODULES[@]}"; do
        key="submodule.$name.url"
        url="$(git -C "$LIBTORRENT_SOURCE_DIR" config -f .gitmodules --get "$key")"
        submodule_path="$(git -C "$LIBTORRENT_SOURCE_DIR" config -f .gitmodules --get "submodule.$name.path")"
        [[ -n "$url" && -n "$submodule_path" ]] \
            || fail "Missing required libtorrent submodule: $name"

        git -C "$LIBTORRENT_SOURCE_DIR" submodule sync --recursive -- "$submodule_path"
        mirror_dir="$LIBTORRENT_SUBMODULE_MIRROR_ROOT/${submodule_path//\//__}.git"
        seed_mirror=""
        if [[ -n "$SOURCE_CACHE_SEED_DIR" ]]; then
            seed_mirror="$SOURCE_CACHE_SEED_DIR/git/libtorrent-submodules/${submodule_path//\//__}.git"
        fi
        expected_commit="$(git -C "$LIBTORRENT_SOURCE_DIR" ls-tree HEAD "$submodule_path" | awk '{print $3}')"

        ensure_git_mirror "$url" "$mirror_dir" "libtorrent submodule $submodule_path" "$LIBTORRENT_SOURCE_DIR/$submodule_path" "$expected_commit" "$seed_mirror"
        git -C "$LIBTORRENT_SOURCE_DIR" config "$key" "$mirror_dir"
        git -C "$LIBTORRENT_SOURCE_DIR" -c protocol.file.allow=always submodule update --init --recursive -- "$submodule_path"

        [[ "$(git -C "$LIBTORRENT_SOURCE_DIR/$submodule_path" rev-parse HEAD)" == "$expected_commit" ]] \
            || fail "libtorrent submodule checkout mismatch: $submodule_path"
        [[ -z "$(git -C "$LIBTORRENT_SOURCE_DIR/$submodule_path" status --porcelain=v1 --untracked-files=all)" ]] \
            || fail "libtorrent submodule checkout is dirty: $submodule_path"
    done
}

libtorrent_checkout_status() {
    git -C "$LIBTORRENT_SOURCE_DIR" status \
        --porcelain=v1 \
        --untracked-files=all \
        --ignore-submodules=none
}

apply_libtorrent_patches() {
    require_path "$LIBTORRENT_PATCH_HELPER" "libtorrent patch-series helper"
    "$LIBTORRENT_PATCH_HELPER" apply "$LIBTORRENT_SOURCE_DIR"
}

clone_libtorrent() {
    local seed_mirror=""
    if [[ -n "$SOURCE_CACHE_SEED_DIR" ]]; then
        seed_mirror="$SOURCE_CACHE_SEED_DIR/git/libtorrent.git"
    fi
    ensure_git_mirror "$LIBTORRENT_REPO" "$LIBTORRENT_MIRROR_DIR" "libtorrent" "$LIBTORRENT_SOURCE_DIR" "$LIBTORRENT_COMMIT" "$seed_mirror"

    mkdir -p "$SOURCE_ROOT"

    if [[ -d "$LIBTORRENT_SOURCE_DIR/.git" ]]; then
        local current
        current="$(git -C "$LIBTORRENT_SOURCE_DIR" rev-parse HEAD 2>/dev/null || true)"
        local checkout_status
        checkout_status="$(libtorrent_checkout_status)"
        if [[ "$current" != "$LIBTORRENT_COMMIT" ]]; then
            if [[ -n "$checkout_status" ]]; then
                fail "Refusing to replace a libtorrent checkout with unexpected local changes: $LIBTORRENT_SOURCE_DIR"
            fi
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

    apply_libtorrent_patches
    setup_libtorrent_submodule_mirrors

    local current
    current="$(git -C "$LIBTORRENT_SOURCE_DIR" rev-parse HEAD)"
    if [[ "$current" != "$LIBTORRENT_COMMIT" ]]; then
        fail "libtorrent checkout mismatch: expected $LIBTORRENT_COMMIT, got $current"
    fi
}

build_libtorrent() {
    local -a cmake_generator_args=()
    if [[ -f "$DEPS_PREFIX/lib/libtorrent-rasterbar.a" ]] && stamp_matches "$LIBTORRENT_BUILD_STAMP" libtorrent_build_manifest "$DEPS_PREFIX"; then
        verify_archive_arch "$DEPS_PREFIX/lib/libtorrent-rasterbar.a" "$TARGET_ARCH"
        verify_libtorrent_typed_allocation_coverage "$DEPS_PREFIX/lib/libtorrent-rasterbar.a"
        "$BOOST_RECYCLER_VERIFIER" "$DEPS_PREFIX/lib/libtorrent-rasterbar.a"
        verify_libtorrent_trap_only_ubsan "$DEPS_PREFIX/lib/libtorrent-rasterbar.a"
        verify_libtorrent_indirect_operation_pac "$DEPS_PREFIX/lib/libtorrent-rasterbar.a"
        "$LIBTORRENT_TLS_VERIFIER" "$DEPS_PREFIX/lib/libtorrent-rasterbar.a"
        write_stamp "$LIBTORRENT_PROVENANCE" libtorrent_build_manifest "$DEPS_PREFIX"
        return
    fi

    remove_dependency_path "$LIBTORRENT_BUILD_DIR"
    remove_dependency_path "$DEPS_PREFIX/include/libtorrent"
    remove_dependency_path "$DEPS_PREFIX/lib/cmake/LibtorrentRasterbar"
    rm -f \
        "$DEPS_PREFIX/lib/libtorrent-rasterbar.a" \
        "$DEPS_PREFIX/lib/pkgconfig/libtorrent-rasterbar.pc" \
        "$DEPS_PREFIX/share/cmake/Modules/FindLibtorrentRasterbar.cmake" \
        "$LIBTORRENT_BUILD_STAMP" \
        "$LIBTORRENT_PROVENANCE"

    if [[ -n ${CMAKE_GENERATOR:-} ]]; then
        cmake_generator_args=(-G "$CMAKE_GENERATOR")
    elif [[ -n ${commands[ninja]:-} ]]; then
        cmake_generator_args=(-G Ninja)
    fi

    # FindOpenSSL is also BoringSSL's supported CMake compatibility surface.
    cmake \
        -S "$LIBTORRENT_SOURCE_DIR" \
        -B "$LIBTORRENT_BUILD_DIR" \
        "${cmake_generator_args[@]}" \
        -Wno-policy \
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
    verify_libtorrent_typed_allocation_coverage "$DEPS_PREFIX/lib/libtorrent-rasterbar.a"
    "$BOOST_RECYCLER_VERIFIER" "$DEPS_PREFIX/lib/libtorrent-rasterbar.a"
    verify_libtorrent_trap_only_ubsan "$DEPS_PREFIX/lib/libtorrent-rasterbar.a"
    verify_libtorrent_indirect_operation_pac "$DEPS_PREFIX/lib/libtorrent-rasterbar.a"
    "$LIBTORRENT_TLS_VERIFIER" "$DEPS_PREFIX/lib/libtorrent-rasterbar.a"
    write_stamp "$LIBTORRENT_BUILD_STAMP" libtorrent_build_manifest "$DEPS_PREFIX"
    write_stamp "$LIBTORRENT_PROVENANCE" libtorrent_build_manifest "$DEPS_PREFIX"
}

require_tool cmake
require_tool curl
require_tool git
require_tool shasum
require_tool tar
require_path "$BOOST_PATCH_HELPER" "Boost patch-series helper"
require_path "$BOOST_RECYCLER_VERIFIER" "Boost.Asio recycler verifier"
require_path "$BORINGSSL_PATCH_HELPER" "BoringSSL patch-series helper"
require_path "$BORINGSSL_HARDENING_VERIFIER" "BoringSSL hardening verifier"
require_path "$LIBTORRENT_TLS_VERIFIER" "libtorrent BoringSSL TLS verifier"
[[ "$("$BOOST_PATCH_HELPER" version)" == "$BOOST_VERSION" ]] \
    || fail "Boost patch-series version does not match BOOST_VERSION=$BOOST_VERSION"
[[ "$("$BORINGSSL_PATCH_HELPER" commit)" == "$BORINGSSL_COMMIT" ]] \
    || fail "BoringSSL patch-series commit does not match BORINGSSL_COMMIT=$BORINGSSL_COMMIT"
require_path "$BORINGSSL_CC" "BoringSSL C compiler"
require_path "$BORINGSSL_CXX" "BoringSSL C++ compiler"
require_path "$BORINGSSL_AR" "BoringSSL archiver"
require_path "$BORINGSSL_RANLIB" "BoringSSL ranlib"
require_path "$LIBTORRENT_CC" "libtorrent C compiler"
require_path "$LIBTORRENT_CXX" "libtorrent C++ compiler"
require_path "$LIBTORRENT_AR" "libtorrent archiver"
require_path "$LIBTORRENT_RANLIB" "libtorrent ranlib"
require_path "$ARCH_LIPO" "architecture inspection tool"

download_boost
extract_boost
install_boost_headers
prepare_boringssl_source
build_boringssl
clone_libtorrent
build_libtorrent

print -r -- "$DEPS_PREFIX"
