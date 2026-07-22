#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
typeset -r sign_identity=${SIGN_IDENTITY:-}
typeset -r expected_team_id=${EXPECTED_TEAM_ID:-}
typeset -r notarytool_profile=${NOTARYTOOL_PROFILE:-}
typeset -r release_dir="$root_dir/.build/Release"
typeset -r release_archive="$release_dir/Torrent 7.zip"
typeset -r default_source_cache_dir="$root_dir/.build/deps/source-cache"

fail() {
    print -ru2 -- "$1"
    exit 1
}

[[ $sign_identity == "Developer ID Application: "* ]] \
    || fail "SIGN_IDENTITY must name a Developer ID Application certificate"
[[ ${#expected_team_id} == 10 && $expected_team_id != *[^A-Z0-9]* ]] \
    || fail "EXPECTED_TEAM_ID must be a 10-character Apple Developer Team ID"
[[ -n $notarytool_profile ]] \
    || fail "NOTARYTOOL_PROFILE must name credentials stored by notarytool"
[[ -n ${HOME:-} ]] \
    || fail "HOME is required for signing and build state"

cd -- "$root_dir"

typeset selected_developer_dir
selected_developer_dir=$(/usr/bin/env -u DEVELOPER_DIR \
    /usr/bin/xcode-select --print-path) \
    || fail "Could not resolve the system-selected Xcode developer directory"
selected_developer_dir=${selected_developer_dir:A}
[[ -d $selected_developer_dir ]] \
    || fail "System-selected Xcode developer directory does not exist: $selected_developer_dir"
case "$selected_developer_dir" in
    /Applications/Xcode*.app/Contents/Developer) ;;
    *) fail "Distribution releases require a system-selected Xcode installation in /Applications" ;;
esac
if (( ${+DEVELOPER_DIR} )); then
    [[ -n $DEVELOPER_DIR ]] || fail "DEVELOPER_DIR cannot be empty"
    [[ ${DEVELOPER_DIR:A} == "$selected_developer_dir" ]] \
        || fail "DEVELOPER_DIR must match the system-selected Xcode developer directory"
fi

typeset shared_source_cache_dir=${SOURCE_CACHE_DIR:-$default_source_cache_dir}
shared_source_cache_dir=${shared_source_cache_dir:a}
typeset -r shared_source_cache_dir

/bin/mkdir -p -- "$root_dir/.build/deps" "$release_dir"
typeset -r temporary_dir=$(/usr/bin/mktemp -d "$root_dir/.build/deps/release.XXXXXXXX")
/bin/chmod 700 "$temporary_dir"
typeset publish_dir=
trap '/bin/rm -rf -- "$temporary_dir"; [[ -z $publish_dir ]] || /bin/rm -rf -- "$publish_dir"' EXIT
publish_dir=$(/usr/bin/mktemp -d "$release_dir/.publish.XXXXXXXX")
typeset -r publish_dir
typeset -r submission_archive="$temporary_dir/Torrent 7.zip"
typeset -r notarization_result="$temporary_dir/notarization.plist"
typeset -r publish_archive="$publish_dir/Torrent 7.zip"
typeset -r release_deps_dir="$temporary_dir/deps"
typeset -r release_deps_prefix="$release_deps_dir/prefix"
typeset -r private_source_cache_dir="$temporary_dir/source-cache"
typeset -r swift_build_dir="$temporary_dir/swift"
typeset -r app_output_dir="$temporary_dir/App"
typeset -r app_dir="$app_output_dir/Torrent 7.app"
/bin/mkdir -m 700 -- "$private_source_cache_dir"

typeset -a build_environment=(
    "HOME=$HOME"
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
    "TMPDIR=${TMPDIR:-/tmp}"
    "LC_ALL=C"
    "DEVELOPER_DIR=$selected_developer_dir"
    "APP_SIGNING_MODE=distribution"
    "CONFIGURATION=release"
    "SKIP_BUILD_DEPS=0"
    "TARGET_ARCH=arm64e"
    "MACOSX_DEPLOYMENT_TARGET=26.0"
    "DEPS_DIR=$release_deps_dir"
    "DEPS_PREFIX=$release_deps_prefix"
    "BOOST_PREFIX=$release_deps_prefix"
    "BOOST_SOURCE_ROOT=$release_deps_dir/src"
    "OPENSSL_PREFIX=$release_deps_prefix"
    "SOURCE_CACHE_DIR=$private_source_cache_dir"
    "SOURCE_CACHE_SEED_DIR=$shared_source_cache_dir"
    "SWIFT_BUILD_DIR=$swift_build_dir"
    "APP_OUTPUT_DIR=$app_output_dir"
    "SIGN_IDENTITY=$sign_identity"
    "EXPECTED_TEAM_ID=$expected_team_id"
)

/bin/rm -f -- "$release_archive"
/usr/bin/env -i "${build_environment[@]}" "$root_dir/Scripts/build-app.zsh"

/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$app_dir" "$submission_archive"
/usr/bin/xcrun notarytool submit "$submission_archive" \
    --keychain-profile "$notarytool_profile" \
    --wait \
    --timeout 30m \
    --output-format plist \
    >"$notarization_result"
/bin/cat "$notarization_result"

typeset -r notarization_status=$(/usr/bin/plutil -extract status raw -o - "$notarization_result")
[[ $notarization_status == "Accepted" ]] \
    || fail "Apple notarization did not accept the app"

/usr/bin/xcrun stapler staple "$app_dir"
/usr/bin/env -i \
    "HOME=$HOME" \
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    "TMPDIR=${TMPDIR:-/tmp}" \
    "LC_ALL=C" \
    "DEVELOPER_DIR=$selected_developer_dir" \
    "$root_dir/Scripts/verify-app.zsh" \
    --mode distribution \
    --team-id "$expected_team_id" \
    "$app_dir"

/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$app_dir" "$publish_archive"
[[ -s $publish_archive ]] || fail "Release archive is empty"
/bin/mv -fh -- "$publish_archive" "$release_archive"

print -r -- "$release_archive"
