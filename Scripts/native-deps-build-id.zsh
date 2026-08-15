#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
typeset -r sanitizer_profile=${SANITIZER_PROFILE:-}
case $sanitizer_profile in
    ""|address|thread) ;;
    *) print -ru2 -- "SANITIZER_PROFILE must be address or thread"; exit 2 ;;
esac

typeset deps_profile=arm64e
[[ -z $sanitizer_profile ]] || deps_profile="arm64e-$sanitizer_profile"
typeset -r deps_prefix=${DEPS_PREFIX:-$root_dir/.build/deps/$deps_profile/prefix}
typeset -r boost_prefix=${BOOST_PREFIX:-$deps_prefix}
typeset -r boringssl_prefix=${BORINGSSL_PREFIX:-$deps_prefix}

typeset -a labels=(
    boost-headers-stamp
    boringssl-build-stamp
    libtorrent-build-stamp
    libtorrent-archive
    boringssl-ssl-archive
    boringssl-crypto-archive
)
typeset -a paths=(
    "$boost_prefix/.torrent-app-boost-headers"
    "$deps_prefix/.torrent-app-boringssl-build"
    "$deps_prefix/.torrent-app-libtorrent-build"
    "$deps_prefix/lib/libtorrent-rasterbar.a"
    "$boringssl_prefix/lib/libssl.a"
    "$boringssl_prefix/lib/libcrypto.a"
)

typeset manifest=
typeset -i index
typeset input_path digest
for (( index = 1; index <= ${#paths}; index++ )); do
    input_path=${paths[index]}
    [[ -f $input_path && ! -L $input_path ]] || {
        print -ru2 -- "Missing or linked native dependency input: $input_path"
        exit 1
    }
    digest=$(/usr/bin/shasum -a 256 -- "$input_path" | /usr/bin/awk '{ print $1 }')
    [[ ${#digest} == 64 && $digest != *[^0-9a-f]* ]] || {
        print -ru2 -- "Could not hash native dependency input: $input_path"
        exit 1
    }
    manifest+="${labels[index]}=$digest"$'\n'
done

typeset -r build_id=$(print -rn -- "$manifest" | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }')
[[ ${#build_id} == 64 && $build_id != *[^0-9a-f]* ]] || {
    print -ru2 -- "Could not derive the native dependency build ID"
    exit 1
}
print -r -- "v_$build_id"
