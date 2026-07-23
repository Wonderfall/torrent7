#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
typeset -r sanitizer_profile=${SANITIZER_PROFILE:-}
case $sanitizer_profile in
    ""|address|thread) ;;
    *) print -ru2 -- "SANITIZER_PROFILE must be address or thread"; exit 2 ;;
esac
typeset -r enable_diagnostics=$(( ${#sanitizer_profile} > 0 ))
typeset -r signing_mode=${APP_SIGNING_MODE:-development}
typeset configuration
if (( enable_diagnostics )) && (( ${+CONFIGURATION} == 0 )); then
    configuration="debug"
else
    configuration=${CONFIGURATION:-release}
fi
typeset -r build_dir="$root_dir/.build"
typeset default_swift_build_dir=$build_dir
if (( enable_diagnostics )); then
    default_swift_build_dir="$build_dir/swift-app-$sanitizer_profile"
fi
typeset -r swift_build_dir=${SWIFT_BUILD_DIR:-$default_swift_build_dir}
typeset app_output_dir=${APP_OUTPUT_DIR:-$build_dir/App}
typeset app_bundle_name="Torrent 7"
typeset app_bundle_id=app.torrent7
typeset app_display_name="Torrent 7"
typeset app_url_identifier=app.torrent7.magnet
typeset engine_extension_product=TorrentEngineExtension
typeset engine_extension_bundle_id=app.torrent7.engine
typeset -r app_info_plist="$root_dir/Packaging/Info.plist"
typeset engine_extension_info_plist="$root_dir/Packaging/TorrentEngineExtension-Info.plist"
typeset extension_point_source="$root_dir/Packaging/TorrentApp.appexpt"
case $sanitizer_profile in
    address)
        [[ -n ${APP_OUTPUT_DIR:-} ]] || app_output_dir="$build_dir/App-Address"
        app_bundle_name="Torrent 7 (ASan)"
        app_bundle_id=app.torrent7.asan
        app_display_name="Torrent 7 (ASan)"
        app_url_identifier=app.torrent7.asan.magnet
        engine_extension_product=TorrentEngineDiagnosticsExtension
        engine_extension_bundle_id=app.torrent7.asan.engine
        engine_extension_info_plist="$root_dir/Packaging/Address/TorrentEngineExtension-Info.plist"
        extension_point_source="$root_dir/Packaging/Address/TorrentApp.appexpt"
        ;;
    thread)
        [[ -n ${APP_OUTPUT_DIR:-} ]] || app_output_dir="$build_dir/App-Thread"
        app_bundle_name="Torrent 7 (TSan)"
        app_bundle_id=app.torrent7.tsan
        app_display_name="Torrent 7 (TSan)"
        app_url_identifier=app.torrent7.tsan.magnet
        engine_extension_product=TorrentEngineDiagnosticsExtension
        engine_extension_bundle_id=app.torrent7.tsan.engine
        engine_extension_info_plist="$root_dir/Packaging/Thread/TorrentEngineExtension-Info.plist"
        extension_point_source="$root_dir/Packaging/Thread/TorrentApp.appexpt"
        ;;
esac
typeset -r app_dir="$app_output_dir/$app_bundle_name.app"
typeset -r contents_dir="$app_dir/Contents"
typeset -r macos_dir="$contents_dir/MacOS"
typeset -r resources_dir="$contents_dir/Resources"
typeset -r executable="$macos_dir/Torrent 7"
typeset -r plugins_dir="$contents_dir/PlugIns"
typeset -r engine_extension_dir="$plugins_dir/$engine_extension_bundle_id.appex"
typeset -r engine_extension_contents_dir="$engine_extension_dir/Contents"
typeset -r engine_extension_macos_dir="$engine_extension_contents_dir/MacOS"
typeset -r engine_extension_executable="$engine_extension_macos_dir/TorrentEngineExtension"
typeset -r extensions_dir="$contents_dir/Extensions"
typeset -r extension_point="$extensions_dir/TorrentApp.appexpt"
typeset -r app_icon="$root_dir/Packaging/AppIcon.icon"
typeset -r document_icon="$root_dir/Packaging/Torrent7Document.icns"
typeset -r third_party_notices="$root_dir/Packaging/ThirdPartyNotices.txt"
typeset -r app_icon_info_plist="$app_output_dir/AppIconInfo.plist"
typeset -r sign_identity=${SIGN_IDENTITY:--}
typeset -r sign_options="runtime,restrict,library"
typeset -r app_entitlements="$root_dir/Packaging/Torrent7.entitlements"
typeset -r engine_extension_entitlements="$root_dir/Packaging/Torrent7Engine.entitlements"
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
        (( ! enable_diagnostics )) \
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

typeset -r app_marketing_version=$(
    /usr/bin/plutil -extract CFBundleShortVersionString raw -expect string -o - \
        "$app_info_plist"
)
typeset -r app_build_version=$(
    /usr/bin/plutil -extract CFBundleVersion raw -expect string -o - \
        "$app_info_plist"
)

export CC="$(/usr/bin/xcrun --find clang)"
export CXX="$(/usr/bin/xcrun --find clang++)"

if (( enable_diagnostics )); then
    export DEPS_DIR="${DEPS_DIR:-$build_dir/deps/arm64e-$sanitizer_profile}"
    export DEPS_PREFIX="${DEPS_PREFIX:-$DEPS_DIR/prefix}"
fi

if [[ "${SKIP_BUILD_DEPS:-0}" != "1" ]]; then
    "$root_dir/Scripts/build-deps.zsh"
fi

typeset -a swift_build_args=(
    --configuration "$configuration"
    --triple arm64e-apple-macosx26.0
)
case $sanitizer_profile in
    address) swift_build_args+=(--sanitize address --sanitize undefined) ;;
    thread) swift_build_args+=(--sanitize thread --sanitize undefined) ;;
esac

/usr/bin/swift build \
    --scratch-path "$swift_build_dir" \
    "${swift_build_args[@]}" \
    --product Torrent7
/usr/bin/swift build \
    --scratch-path "$swift_build_dir" \
    "${swift_build_args[@]}" \
    --product "$engine_extension_product"

rm -rf -- "$app_dir"
mkdir -p -- \
    "$macos_dir" \
    "$resources_dir" \
    "$engine_extension_macos_dir" \
    "$extensions_dir"

cp "$swift_build_dir/arm64e-apple-macosx/$configuration/Torrent7" "$executable"
cp \
    "$swift_build_dir/arm64e-apple-macosx/$configuration/$engine_extension_product" \
    "$engine_extension_executable"
cp "$app_info_plist" "$contents_dir/Info.plist"
cp "$engine_extension_info_plist" "$engine_extension_contents_dir/Info.plist"
cp "$extension_point_source" "$extension_point"
/usr/bin/plutil -insert CFBundleShortVersionString \
    -string "$app_marketing_version" \
    "$engine_extension_contents_dir/Info.plist"
/usr/bin/plutil -insert CFBundleVersion \
    -string "$app_build_version" \
    "$engine_extension_contents_dir/Info.plist"
/usr/bin/plutil -lint \
    "$app_info_plist" \
    "$engine_extension_info_plist" \
    "$extension_point_source" \
    "$contents_dir/Info.plist" \
    "$engine_extension_contents_dir/Info.plist" \
    "$extension_point" \
    >/dev/null
if [[ $sign_identity == "-" ]]; then
    /usr/libexec/PlistBuddy \
        -c "Add :Torrent7AllowAdHocXPCPeer bool true" \
        "$contents_dir/Info.plist"
    /usr/libexec/PlistBuddy \
        -c "Add :Torrent7AllowAdHocXPCPeer bool true" \
        "$engine_extension_contents_dir/Info.plist"
fi
if (( enable_diagnostics )); then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $app_bundle_id" "$contents_dir/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_display_name" "$contents_dir/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $app_display_name" "$contents_dir/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName $app_url_identifier" "$contents_dir/Info.plist"
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
    --entitlements "$engine_extension_entitlements" \
    "${timestamp_flag[@]}" \
    "$engine_extension_dir"

/usr/bin/codesign \
    --force \
    --sign "$sign_identity" \
    --options "$sign_options" \
    --entitlements "$app_entitlements" \
    "${timestamp_flag[@]}" \
    "$app_dir"

/usr/bin/codesign --verify --strict --verbose=2 "$engine_extension_dir"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_dir"

if [[ $sign_identity != "-" ]]; then
    typeset -r signed_app_team_id=$(code_signing_team_identifier "$app_dir")
    typeset -r signed_engine_team_id=$(
        code_signing_team_identifier "$engine_extension_dir"
    )
    valid_team_identifier "$signed_app_team_id" \
        || fail "Identified app signature has a missing or invalid TeamIdentifier"
    valid_team_identifier "$signed_engine_team_id" \
        || fail "Identified engine signature has a missing or invalid TeamIdentifier"
    [[ $signed_app_team_id == "$signed_engine_team_id" ]] \
        || fail "App and engine extension TeamIdentifiers do not match"
fi

if [[ $signing_mode == "distribution" ]]; then
    "$root_dir/Scripts/verify-app.zsh" \
        --mode distribution \
        --notarization pending \
        --team-id "$expected_team_id" \
        "$app_dir"
else
    "$root_dir/Scripts/verify-app.zsh" --mode development "$app_dir"
fi

echo "$app_dir"
