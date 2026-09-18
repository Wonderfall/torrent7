#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
typeset -r sign_identity=${SIGN_IDENTITY:-}
typeset -r expected_team_id=${EXPECTED_TEAM_ID:-}
typeset -r notarytool_profile=${NOTARYTOOL_PROFILE:-}
typeset -r release_dir="$root_dir/.build/Release"
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
/usr/bin/env DEVELOPER_DIR="$selected_developer_dir" \
    "$root_dir/Scripts/verify-xcode.zsh"

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
typeset -r evidence_dir="$publish_dir/Evidence"
typeset -r publish_archive="$publish_dir/Torrent 7.zip"
typeset -r release_deps_dir="$temporary_dir/deps"
typeset -r release_deps_prefix="$release_deps_dir/prefix"
typeset -r private_source_cache_dir="$temporary_dir/source-cache"
typeset -r swift_build_dir="$temporary_dir/swift"
typeset -r sbom_output_dir="$temporary_dir/sbom"
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
    "MACOSX_DEPLOYMENT_TARGET=27.0"
    "DEPS_DIR=$release_deps_dir"
    "DEPS_PREFIX=$release_deps_prefix"
    "BOOST_PREFIX=$release_deps_prefix"
    "BOOST_SOURCE_ROOT=$release_deps_dir/src"
    "BORINGSSL_PREFIX=$release_deps_prefix"
    "SOURCE_CACHE_DIR=$private_source_cache_dir"
    "SOURCE_CACHE_SEED_DIR=$shared_source_cache_dir"
    "SWIFT_BUILD_DIR=$swift_build_dir"
    "SBOM_OUTPUT_DIR=$sbom_output_dir"
    "APP_OUTPUT_DIR=$app_output_dir"
    "SIGN_IDENTITY=$sign_identity"
    "EXPECTED_TEAM_ID=$expected_team_id"
)

/usr/bin/env -i "${build_environment[@]}" "$root_dir/Scripts/build-app.zsh"

typeset -r bin_dir=$(/usr/bin/env -i "${build_environment[@]}" /usr/bin/xcrun swift build \
    --scratch-path "$swift_build_dir" --configuration release --arch arm64e --show-bin-path)
"$root_dir/Scripts/archive-release-evidence.zsh" \
    "$app_dir" "$bin_dir" "$release_deps_prefix" "$sbom_output_dir" "$evidence_dir"

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
    "DEPS_PREFIX=$release_deps_prefix" \
    "BOOST_PREFIX=$release_deps_prefix" \
    "BORINGSSL_PREFIX=$release_deps_prefix" \
    "$root_dir/Scripts/verify-app.zsh" \
    --mode distribution \
    --team-id "$expected_team_id" \
    "$app_dir"

/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$app_dir" "$publish_archive"
[[ -s $publish_archive ]] || fail "Release archive is empty"
typeset -r notarization_id=$(/usr/bin/plutil -extract id raw -o - "$notarization_result")
print -r -- "$notarization_id" | /usr/bin/grep -Eiq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
    || fail "Unexpected notarization submission ID"
typeset -r release_output="$release_dir/$notarization_id"
[[ ! -e $release_output ]] || fail "Release output already exists: $release_output"
/bin/cp -- "$notarization_result" "$publish_dir/notarization.plist"
(
    cd -- "$publish_dir"
    /usr/bin/shasum -a 256 -- "Torrent 7.zip" Evidence/Symbols.zip \
        Evidence/SBOM/*.json Evidence/symbol-uuids.txt Evidence/native-build-id.txt \
        Evidence/toolchain.txt notarization.plist > SHA256SUMS
)
# Publish the app, symbols, inventories, and their checksums as one directory.
/bin/mv -h -- "$publish_dir" "$release_output"

print -r -- "$release_output"
