#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
typeset -r enable_diagnostics=${SANITIZER_DIAGNOSTICS:-0}
typeset -r signing_mode=${APP_SIGNING_MODE:-development}
typeset configuration
if [[ $enable_diagnostics == "1" && ${+CONFIGURATION} == 0 ]]; then
    configuration="debug"
else
    configuration=${CONFIGURATION:-release}
fi
typeset -r build_dir="$root_dir/.build"
typeset -r swift_build_dir=${SWIFT_BUILD_DIR:-$build_dir}
typeset app_output_dir=${APP_OUTPUT_DIR:-$build_dir/App}
typeset app_bundle_name="Torrent 7"
if [[ $enable_diagnostics == "1" ]]; then
    if [[ -z ${APP_OUTPUT_DIR:-} ]]; then
        app_output_dir="$build_dir/App-Diagnostics"
    fi
    app_bundle_name="Torrent 7 (debug)"
fi
typeset -r app_dir="$app_output_dir/$app_bundle_name.app"
typeset -r contents_dir="$app_dir/Contents"
typeset -r macos_dir="$contents_dir/MacOS"
typeset -r resources_dir="$contents_dir/Resources"
typeset -r executable="$macos_dir/Torrent 7"
typeset -r xpc_services_dir="$contents_dir/XPCServices"
typeset -r engine_service_dir="$xpc_services_dir/app.torrent7.engine.xpc"
typeset -r engine_service_contents_dir="$engine_service_dir/Contents"
typeset -r engine_service_macos_dir="$engine_service_contents_dir/MacOS"
typeset -r engine_service_executable="$engine_service_macos_dir/TorrentEngineService"
typeset -r app_icon="$root_dir/Packaging/AppIcon.icon"
typeset -r document_icon="$root_dir/Packaging/Torrent7Document.icns"
typeset -r third_party_notices="$root_dir/Packaging/ThirdPartyNotices.txt"
typeset -r app_icon_info_plist="$app_output_dir/AppIconInfo.plist"
typeset -r sign_identity=${SIGN_IDENTITY:--}
typeset -r sign_options="runtime,restrict,library"
typeset -r app_entitlements="$root_dir/Packaging/Torrent7.entitlements"
typeset -r engine_service_entitlements="$root_dir/Packaging/Torrent7Engine.entitlements"
typeset -r engine_service_info_plist="$root_dir/Packaging/TorrentEngineService-Info.plist"
typeset -r expected_team_id=${EXPECTED_TEAM_ID:-}
typeset -a timestamp_flag=(--timestamp=none)

fail() {
    print -ru2 -- "$1"
    exit 1
}

valid_team_identifier() {
    local -r value=$1
    [[ ${#value} == 10 && $value != *[^A-Z0-9]* ]]
}

code_signing_team_identifier() {
    local -r bundle=$1
    /usr/bin/codesign --display --verbose=4 "$bundle" 2>&1 \
        | /usr/bin/sed -n 's/^TeamIdentifier=//p'
}

[[ $app_output_dir == /* ]] || fail "APP_OUTPUT_DIR must be an absolute path"

case "$signing_mode" in
    development)
        if [[ $sign_identity != "-" ]]; then
            timestamp_flag=(--timestamp)
        fi
        ;;
    distribution)
        [[ $enable_diagnostics == "0" ]] \
            || fail "Distribution builds cannot enable sanitizer diagnostics"
        [[ $configuration == "release" ]] \
            || fail "Distribution builds require CONFIGURATION=release"
        [[ $sign_identity != "-" ]] \
            || fail "Distribution builds require SIGN_IDENTITY"
        [[ $sign_identity == "Developer ID Application: "* ]] \
            || fail "SIGN_IDENTITY must name a Developer ID Application certificate"
        [[ ${#expected_team_id} == 10 && $expected_team_id != *[^A-Z0-9]* ]] \
            || fail "Distribution builds require a 10-character EXPECTED_TEAM_ID"
        timestamp_flag=(--timestamp)
        ;;
    *)
        fail "APP_SIGNING_MODE must be development or distribution"
        ;;
esac

cd -- "$root_dir"

export CC="$(/usr/bin/xcrun --find clang)"
export CXX="$(/usr/bin/xcrun --find clang++)"

if [[ $enable_diagnostics == "1" ]]; then
    export SANITIZER_DIAGNOSTICS=1
    export DEPS_DIR="${DEPS_DIR:-$build_dir/deps/arm64e-diagnostics}"
    export DEPS_PREFIX="${DEPS_PREFIX:-$DEPS_DIR/prefix}"
fi

if [[ "${SKIP_BUILD_DEPS:-0}" != "1" ]]; then
    "$root_dir/Scripts/build-deps.zsh"
fi

typeset -a swift_build_args=(
    --configuration "$configuration"
    --triple arm64e-apple-macosx26.0
)
if [[ $enable_diagnostics == "1" ]]; then
    swift_build_args+=(--sanitize address --sanitize undefined)
fi

/usr/bin/swift build \
    --scratch-path "$swift_build_dir" \
    "${swift_build_args[@]}" \
    --product Torrent7
/usr/bin/swift build \
    --scratch-path "$swift_build_dir" \
    "${swift_build_args[@]}" \
    --product TorrentEngineService

rm -rf -- "$app_dir"
mkdir -p -- "$macos_dir" "$resources_dir" "$engine_service_macos_dir"

cp "$swift_build_dir/arm64e-apple-macosx/$configuration/Torrent7" "$executable"
cp \
    "$swift_build_dir/arm64e-apple-macosx/$configuration/TorrentEngineService" \
    "$engine_service_executable"
cp "$root_dir/Packaging/Info.plist" "$contents_dir/Info.plist"
cp "$engine_service_info_plist" "$engine_service_contents_dir/Info.plist"
if [[ $sign_identity == "-" ]]; then
    /usr/libexec/PlistBuddy \
        -c "Add :Torrent7AllowAdHocXPCPeer bool true" \
        "$contents_dir/Info.plist"
    /usr/libexec/PlistBuddy \
        -c "Add :Torrent7AllowAdHocXPCPeer bool true" \
        "$engine_service_contents_dir/Info.plist"
fi
if [[ $enable_diagnostics == "1" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.torrent7.debug" "$contents_dir/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Torrent 7 (debug)" "$contents_dir/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Torrent 7 (debug)" "$contents_dir/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName app.torrent7.debug.magnet" "$contents_dir/Info.plist"
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleIdentifier app.torrent7.debug.engine" \
        "$engine_service_contents_dir/Info.plist"
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleDisplayName Torrent 7 Engine (debug)" \
        "$engine_service_contents_dir/Info.plist"
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleName Torrent 7 Engine (debug)" \
        "$engine_service_contents_dir/Info.plist"
fi
cp "$document_icon" "$resources_dir/Torrent7Document.icns"
cp "$third_party_notices" "$resources_dir/ThirdPartyNotices.txt"

rm -f -- "$app_icon_info_plist"
/usr/bin/xcrun actool \
    --compile "$resources_dir" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$app_icon_info_plist" \
    "$app_icon"
/usr/libexec/PlistBuddy -c "Merge $app_icon_info_plist" "$contents_dir/Info.plist"
rm -f -- "$app_icon_info_plist"

/usr/bin/codesign \
    --force \
    --sign "$sign_identity" \
    --options "$sign_options" \
    --entitlements "$engine_service_entitlements" \
    "${timestamp_flag[@]}" \
    "$engine_service_dir"

/usr/bin/codesign \
    --force \
    --sign "$sign_identity" \
    --options "$sign_options" \
    --entitlements "$app_entitlements" \
    "${timestamp_flag[@]}" \
    "$app_dir"

/usr/bin/codesign --verify --strict --verbose=2 "$engine_service_dir"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_dir"

if [[ $sign_identity != "-" ]]; then
    typeset -r signed_app_team_id=$(code_signing_team_identifier "$app_dir")
    typeset -r signed_engine_team_id=$(
        code_signing_team_identifier "$engine_service_dir"
    )
    valid_team_identifier "$signed_app_team_id" \
        || fail "Identified app signature has a missing or invalid TeamIdentifier"
    valid_team_identifier "$signed_engine_team_id" \
        || fail "Identified engine signature has a missing or invalid TeamIdentifier"
    [[ $signed_app_team_id == "$signed_engine_team_id" ]] \
        || fail "App and engine service TeamIdentifiers do not match"
fi

if [[ $signing_mode == "distribution" ]]; then
    "$root_dir/Scripts/verify-app.zsh" \
        --mode distribution \
        --notarization pending \
        --team-id "$expected_team_id" \
        "$app_dir"
fi

echo "$app_dir"
