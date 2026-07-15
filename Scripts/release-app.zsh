#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
typeset -r sign_identity=${SIGN_IDENTITY:-}
typeset -r expected_team_id=${EXPECTED_TEAM_ID:-}
typeset -r notarytool_profile=${NOTARYTOOL_PROFILE:-}
typeset -r app_dir="$root_dir/.build/App/Torrent 7.app"
typeset -r release_dir="$root_dir/.build/Release"
typeset -r release_archive="$release_dir/Torrent 7.zip"
typeset -r temporary_dir=$(mktemp -d)
typeset -r submission_archive="$temporary_dir/Torrent 7.zip"
typeset -r notarization_result="$temporary_dir/notarization.plist"
trap 'rm -rf -- "$temporary_dir"' EXIT

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

typeset -r canonical_deps_dir="$root_dir/.build/deps/arm64e"
typeset -r canonical_deps_prefix="$canonical_deps_dir/prefix"
typeset -a build_environment=(
    "HOME=$HOME"
    "PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    "TMPDIR=${TMPDIR:-/tmp}"
    "LC_ALL=C"
    "APP_SIGNING_MODE=distribution"
    "CONFIGURATION=release"
    "SANITIZER_DIAGNOSTICS=0"
    "SKIP_BUILD_DEPS=0"
    "TARGET_ARCH=arm64e"
    "MACOSX_DEPLOYMENT_TARGET=26.0"
    "DEPS_DIR=$canonical_deps_dir"
    "DEPS_PREFIX=$canonical_deps_prefix"
    "BOOST_PREFIX=$canonical_deps_prefix"
    "OPENSSL_PREFIX=$canonical_deps_prefix"
    "SIGN_IDENTITY=$sign_identity"
    "EXPECTED_TEAM_ID=$expected_team_id"
)
if (( ${+DEVELOPER_DIR} )); then
    build_environment+=("DEVELOPER_DIR=$DEVELOPER_DIR")
fi
if (( ${+SOURCE_CACHE_DIR} )); then
    build_environment+=("SOURCE_CACHE_DIR=$SOURCE_CACHE_DIR")
fi

/usr/bin/env -i "${build_environment[@]}" "$root_dir/Scripts/build-app.zsh"

ditto -c -k --keepParent --sequesterRsrc "$app_dir" "$submission_archive"
xcrun notarytool submit "$submission_archive" \
    --keychain-profile "$notarytool_profile" \
    --wait \
    --timeout 30m \
    --output-format plist \
    >"$notarization_result"
cat "$notarization_result"

typeset -r notarization_status=$(plutil -extract status raw -o - "$notarization_result")
[[ $notarization_status == "Accepted" ]] \
    || fail "Apple notarization did not accept the app"

xcrun stapler staple "$app_dir"
"$root_dir/Scripts/verify-app.zsh" \
    --mode distribution \
    --team-id "$expected_team_id" \
    "$app_dir"

mkdir -p -- "$release_dir"
rm -f -- "$release_archive"
ditto -c -k --keepParent --sequesterRsrc "$app_dir" "$release_archive"

print -r -- "$release_archive"
