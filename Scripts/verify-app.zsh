#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
typeset mode=development
typeset notarization=
typeset expected_team_id=${EXPECTED_TEAM_ID:-}
typeset app_argument=
typeset build_products=
typeset configuration=${CONFIGURATION:-}

fail() {
    print -ru2 -- "$1"
    exit 1
}

while (( $# > 0 )); do
    case "$1" in
        --build-products)
            (( $# >= 2 )) || fail "--build-products requires a directory"
            build_products=$2
            shift 2
            ;;
        --configuration)
            (( $# >= 2 )) || fail "--configuration requires debug or release"
            configuration=$2
            shift 2
            ;;
        --mode)
            (( $# >= 2 )) || fail "--mode requires a value"
            mode=$2
            shift 2
            ;;
        --notarization)
            (( $# >= 2 )) || fail "--notarization requires a value"
            notarization=$2
            shift 2
            ;;
        --team-id)
            (( $# >= 2 )) || fail "--team-id requires a value"
            expected_team_id=$2
            shift 2
            ;;
        --)
            shift
            if (( $# > 0 )); then
                [[ -z $app_argument && $# == 1 ]] || fail "Only one app bundle may be verified"
                app_argument=$1
                shift
            fi
            break
            ;;
        -*)
            fail "Unknown option: $1"
            ;;
        *)
            [[ -z $app_argument ]] || fail "Only one app bundle may be verified"
            app_argument=$1
            shift
            ;;
    esac
done
(( $# == 0 )) || fail "Only one app bundle may be verified"

case "$mode" in
    development)
        [[ -z $notarization ]] || fail "--notarization applies only to distribution verification"
        ;;
    distribution)
        notarization=${notarization:-required}
        [[ $notarization == "pending" || $notarization == "required" ]] \
            || fail "--notarization must be pending or required"
        [[ ${#expected_team_id} == 10 && $expected_team_id != *[^A-Z0-9]* ]] \
            || fail "Distribution verification requires a 10-character --team-id or EXPECTED_TEAM_ID"
        ;;
    *)
        fail "--mode must be development or distribution"
        ;;
esac

typeset -r app_dir=${app_argument:-$root_dir/.build/App/Torrent 7.app}
typeset -r info_plist="$app_dir/Contents/Info.plist"
typeset -r executable="$app_dir/Contents/MacOS/Torrent 7"
typeset -r resources_dir="$app_dir/Contents/Resources"
typeset -r plugins_dir="$app_dir/Contents/PlugIns"
typeset -r extension_points_dir="$app_dir/Contents/Extensions"
typeset -r expected_app_entitlements="$root_dir/Packaging/Torrent7.entitlements"
typeset -r expected_engine_entitlements="$root_dir/Packaging/Torrent7Engine.entitlements"
typeset -r expected_third_party_notices="$root_dir/Packaging/ThirdPartyNotices.txt"
typeset -r temporary_dir=$(/usr/bin/mktemp -d)
typeset -r app_entitlements_output="$temporary_dir/app-entitlements.plist"
typeset -r app_signature_output="$temporary_dir/app-signature.txt"
typeset -r engine_entitlements_output="$temporary_dir/engine-entitlements.plist"
typeset -r engine_signature_output="$temporary_dir/engine-signature.txt"
trap '/bin/rm -rf -- "$temporary_dir"' EXIT

require_match() {
    local -r pattern=$1
    local -r file=$2
    local -r message=$3

    /usr/bin/grep -Eq -- "$pattern" "$file" || fail "$message"
}

reject_match() {
    local -r pattern=$1
    local -r file=$2
    local -r message=$3

    if /usr/bin/grep -Eq -- "$pattern" "$file"; then
        fail "$message"
    fi
}

require_literal_line() {
    local -r value=$1
    local -r file=$2
    local -r message=$3

    /usr/bin/grep -Fqx -- "$value" "$file" || fail "$message"
}

info_plist_value() {
    local -r plist=$1
    local -r key=$2
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist"
}

info_plist_boolean_value() {
    local -r plist=$1
    local -r key=$2
    /usr/bin/plutil -extract "$key" raw -expect bool -o - "$plist"
}

valid_team_identifier() {
    local -r value=$1
    [[ ${#value} == 10 && $value != *[^A-Z0-9]* ]]
}

verify_signature_hardening() {
    local -r label=$1
    local -r signature_file=$2
    local -r entitlements_file=$3
    require_match "flags=.*runtime" "$signature_file" \
        "$label signature is missing the hardened runtime flag"
    require_match "flags=.*restrict" "$signature_file" \
        "$label signature is missing the restrict flag"
    require_match "flags=.*library-validation" "$signature_file" \
        "$label signature is missing the library validation flag"
    reject_match "com.apple.security.cs.disable-library-validation" "$entitlements_file" \
        "$label disables library validation"
    [[ $(/usr/libexec/PlistBuddy -c \
        "Print :com.apple.security.hardened-process.checked-allocations.enable-pure-data" \
        "$entitlements_file") == "true" ]] \
        || fail "$label does not enable pure-data checked allocations"
}

verify_distribution_signature() {
    local -r label=$1
    local -r signature_file=$2

    reject_match "^Signature=adhoc$" "$signature_file" "$label is ad-hoc signed"
    require_match "^Authority=Developer ID Application:" "$signature_file" \
        "$label is not signed with a Developer ID Application certificate"
    require_match "^Authority=Developer ID Certification Authority$" "$signature_file" \
        "$label signature does not chain through the Developer ID Certification Authority"
    require_match "^TeamIdentifier=${expected_team_id}$" "$signature_file" \
        "$label signature has an unexpected TeamIdentifier"
    require_match "^Timestamp=.+$" "$signature_file" "$label signature has no trusted timestamp"
    reject_match "^Timestamp=none$" "$signature_file" "$label signature has no trusted timestamp"
}

verify_mach_o_load_commands() {
    local -r binary=$1
    local -r expected_sanitizer=$2
    /usr/bin/xcrun vtool -show-build "$binary" | /usr/bin/awk '
        $1 == "platform" && $2 == "MACOS" { platform++ }
        $1 == "minos" && $2 == "27.0" { minimum++ }
        $1 == "sdk" && $2 == "27.0" { sdk++ }
        END { exit !(platform == 1 && minimum == 1 && sdk == 1) }
    ' || fail "Expected a macOS 27.0 deployment target and SDK in $binary"
    local expected_runtime=
    case $expected_sanitizer in
        none)
            ;;
        address)
            expected_runtime=@rpath/libclang_rt.asan_osx_dynamic.dylib
            ;;
        thread)
            expected_runtime=@rpath/libclang_rt.tsan_osx_dynamic.dylib
            ;;
        *)
            fail "Internal error: unexpected sanitizer profile $expected_sanitizer"
            ;;
    esac
    local saw_expected_runtime=false
    local saw_diagnostic_rpath=false
    local dependencies load_command_output load_command_name load_path line
    dependencies=$(/usr/bin/otool -L "$binary")
    load_command_output=$(
        /usr/bin/otool -l "$binary" | /usr/bin/awk '
            $1 == "cmd" {
                if ($2 == "LC_DYLD_ENVIRONMENT") {
                    print $2
                    current = ""
                    next
                }
                if ($2 ~ /^LC_LOAD_/ ||
                    $2 == "LC_REEXPORT_DYLIB" ||
                    $2 == "LC_LAZY_LOAD_DYLIB" ||
                    $2 == "LC_RPATH") {
                    current = $2
                } else {
                    current = ""
                }
                next
            }
            current == "LC_RPATH" && $1 == "path" {
                print current "\t" $2
                current = ""
                next
            }
            current != "" && $1 == "name" {
                print current "\t" $2
                current = ""
            }
        '
    )
    [[ -n $load_command_output ]] || fail "Could not inspect Mach-O load commands in $binary"
    for line in "${(@f)load_command_output}"; do
        [[ $line != "LC_DYLD_ENVIRONMENT" ]] \
            || fail "Found forbidden LC_DYLD_ENVIRONMENT in $binary"
        load_command_name=${line%%$'\t'*}
        load_path=${line#*$'\t'}
        if [[ $load_command_name == "LC_RPATH" ]]; then
            case "$load_path" in
                @loader_path|@executable_path)
                    ;;
                /Applications/Xcode*.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/*/lib/darwin)
                    [[ $mode == "development" && $expected_sanitizer != none ]] \
                        || fail "Diagnostic Xcode runtime path is forbidden in $binary"
                    saw_diagnostic_rpath=true
                    ;;
                *)
                    fail "Found unexpected LC_RPATH in $binary: $load_path"
                    ;;
            esac
            continue
        fi
        case "$load_path" in
            /System/Library/*|/usr/lib/*)
                ;;
            @rpath/libclang_rt.asan_osx_dynamic.dylib)
                [[ $mode == "development" && $expected_runtime == "$load_path" ]] \
                    || fail "Unexpected AddressSanitizer runtime in $binary"
                saw_expected_runtime=true
                ;;
            @rpath/libclang_rt.tsan_osx_dynamic.dylib)
                [[ $mode == "development" && $expected_runtime == "$load_path" ]] \
                    || fail "Unexpected ThreadSanitizer runtime in $binary"
                saw_expected_runtime=true
                ;;
            *)
                fail "Found non-system Mach-O load command in $binary: $load_path"
                ;;
        esac
    done
    if [[ $expected_sanitizer != none ]]; then
        [[ $saw_expected_runtime == true ]] \
            || fail "$binary is missing its required $expected_sanitizer sanitizer runtime"
        [[ $saw_diagnostic_rpath == true ]] \
            || fail "$binary is missing the Xcode sanitizer runtime search path"
    fi
}

[[ -f "$info_plist" && ! -L "$info_plist" ]] \
    || fail "Missing or linked app Info.plist"
[[ -f "$executable" && -x "$executable" && ! -L "$executable" ]] \
    || fail "Missing or linked app executable"

typeset -r app_bundle_id=$(info_plist_value "$info_plist" CFBundleIdentifier)
typeset expected_engine_bundle_id
typeset expected_extension_point_identifier
typeset expected_engine_info_plist
typeset expected_extension_point
typeset expected_sanitizer=none
case "$app_bundle_id" in
    app.torrent7)
        expected_engine_bundle_id=app.torrent7.engine
        expected_extension_point_identifier=app.torrent7.torrent-engine
        expected_engine_info_plist="$root_dir/Packaging/TorrentEngineExtension-Info.plist"
        expected_extension_point="$root_dir/Packaging/TorrentApp.appexpt"
        ;;
    app.torrent7.asan)
        [[ $mode == "development" ]] \
            || fail "Distribution verification does not allow the ASan bundle identifier"
        expected_engine_bundle_id=app.torrent7.asan.engine
        expected_extension_point_identifier=app.torrent7.asan.torrent-engine
        expected_engine_info_plist="$root_dir/Packaging/Address/TorrentEngineExtension-Info.plist"
        expected_extension_point="$root_dir/Packaging/Address/TorrentApp.appexpt"
        expected_sanitizer=address
        ;;
    app.torrent7.tsan)
        [[ $mode == "development" ]] \
            || fail "Distribution verification does not allow the TSan bundle identifier"
        expected_engine_bundle_id=app.torrent7.tsan.engine
        expected_extension_point_identifier=app.torrent7.tsan.torrent-engine
        expected_engine_info_plist="$root_dir/Packaging/Thread/TorrentEngineExtension-Info.plist"
        expected_extension_point="$root_dir/Packaging/Thread/TorrentApp.appexpt"
        expected_sanitizer=thread
        ;;
    *)
        fail "Unexpected app bundle identifier: $app_bundle_id"
        ;;
esac

if [[ -z $configuration ]]; then
    configuration=release
    [[ $expected_sanitizer == none ]] || configuration=debug
fi
[[ $configuration == release || $configuration == debug ]] \
    || fail "--configuration must be debug or release"
[[ $mode != distribution || $configuration == release ]] \
    || fail "Distribution verification requires release binaries"

typeset -r engine_extension_dir="$plugins_dir/$expected_engine_bundle_id.appex"
typeset -r engine_extension_info_plist="$engine_extension_dir/Contents/Info.plist"
typeset -r engine_extension_executable="$engine_extension_dir/Contents/MacOS/TorrentEngineExtension"
typeset -r installed_extension_point="$extension_points_dir/TorrentApp.appexpt"

[[ ! -e "$app_dir/Contents/XPCServices" ]] \
    || fail "Legacy Contents/XPCServices must be absent"
[[ -d "$plugins_dir" && ! -L "$plugins_dir" ]] || fail "Missing or linked Contents/PlugIns"
typeset -a embedded_extension_entries=()
while IFS= read -r -d $'\0' entry; do
    embedded_extension_entries+=("$entry")
done < <(/usr/bin/find "$plugins_dir" -mindepth 1 -maxdepth 1 -print0)
(( ${#embedded_extension_entries} == 1 )) \
    || fail "Contents/PlugIns must contain exactly one engine extension"
[[ ${embedded_extension_entries[1]} == "$engine_extension_dir" ]] \
    || fail "Unexpected embedded extension: ${embedded_extension_entries[1]}"
[[ ! -L "$engine_extension_dir" ]] \
    || fail "Engine extension bundle must not be a symbolic link"
[[ -f "$engine_extension_info_plist" && ! -L "$engine_extension_info_plist" ]] \
    || fail "Missing or linked engine extension Info.plist"
[[ -f "$engine_extension_executable" && -x "$engine_extension_executable" \
    && ! -L "$engine_extension_executable" ]] \
    || fail "Missing or linked engine extension executable"

[[ -d "$extension_points_dir" && ! -L "$extension_points_dir" ]] \
    || fail "Missing or linked Contents/Extensions"
typeset -a extension_point_entries=()
while IFS= read -r -d $'\0' entry; do
    extension_point_entries+=("$entry")
done < <(/usr/bin/find "$extension_points_dir" -mindepth 1 -maxdepth 1 -print0)
(( ${#extension_point_entries} == 1 )) \
    || fail "Contents/Extensions must contain exactly one extension point"
[[ ${extension_point_entries[1]} == "$installed_extension_point" ]] \
    || fail "Unexpected extension point: ${extension_point_entries[1]}"
[[ -f "$installed_extension_point" && ! -L "$installed_extension_point" ]] \
    || fail "Missing or linked engine extension-point metadata"

/usr/bin/plutil -lint \
    "$expected_engine_info_plist" \
    "$expected_extension_point" \
    "$engine_extension_info_plist" \
    "$installed_extension_point" \
    >/dev/null
/usr/bin/cmp -s "$expected_extension_point" "$installed_extension_point" \
    || fail "Installed extension-point metadata differs from its reviewed packaging source"
"$root_dir/Scripts/run-tool.zsh" verify-enhanced-security-metadata \
    "$installed_extension_point" \
    "$engine_extension_info_plist" \
    "$expected_extension_point_identifier"

typeset -r engine_bundle_id=$(info_plist_value "$engine_extension_info_plist" CFBundleIdentifier)
[[ $engine_bundle_id == "$expected_engine_bundle_id" ]] \
    || fail "Unexpected engine extension bundle identifier: $engine_bundle_id"
[[ $(info_plist_value "$info_plist" CFBundlePackageType) == "APPL" ]] \
    || fail "App CFBundlePackageType is not APPL"
[[ $(info_plist_value "$info_plist" CFBundleExecutable) == "Torrent 7" ]] \
    || fail "App CFBundleExecutable is unexpected"
[[ $(info_plist_value "$engine_extension_info_plist" CFBundlePackageType) == "XPC!" ]] \
    || fail "Engine extension CFBundlePackageType is not XPC!"
[[ $(info_plist_value "$engine_extension_info_plist" CFBundleExecutable) == "TorrentEngineExtension" ]] \
    || fail "Engine extension CFBundleExecutable is unexpected"
[[ $(info_plist_value \
    "$engine_extension_info_plist" \
    EXAppExtensionAttributes:EXExtensionPointIdentifier) \
    == "$expected_extension_point_identifier" ]] \
    || fail "Engine extension identifier does not match its extension point"
if /usr/libexec/PlistBuddy -c "Print :XPCService" \
    "$engine_extension_info_plist" >/dev/null 2>&1; then
    fail "Engine extension retains legacy XPCService metadata"
fi
if /usr/libexec/PlistBuddy -c "Print :NSExtension" \
    "$engine_extension_info_plist" >/dev/null 2>&1; then
    fail "Engine extension unexpectedly declares NSExtension metadata"
fi
[[ $(info_plist_value "$installed_extension_point" EXVersion) == "2" ]] \
    || fail "Extension-point metadata version is not 2"
[[ $(info_plist_value \
    "$installed_extension_point" \
    "$expected_extension_point_identifier:EXExtensionPointName") \
    == "torrent-engine" ]] || fail "Extension-point name is unexpected"
[[ $(info_plist_value \
    "$installed_extension_point" \
    "$expected_extension_point_identifier:_EXScopeRestriction") \
    == "application" ]] || fail "Engine extension point is not application-scoped"
[[ $(info_plist_value \
    "$installed_extension_point" \
    "$expected_extension_point_identifier:EXPresentsUserInterface") == "false" ]] \
    || fail "Engine extension point unexpectedly presents UI"
[[ $(info_plist_value \
    "$installed_extension_point" \
    "$expected_extension_point_identifier:EXRequiresEnhancedSecurity") == "true" ]] \
    || fail "Engine extension point does not require Enhanced Security"
[[ $(info_plist_value "$engine_extension_info_plist" LSMinimumSystemVersion) == "27.0" ]] \
    || fail "Engine extension minimum system version is not 27.0"
[[ $(info_plist_value "$info_plist" LSMinimumSystemVersion) == "27.0" ]] \
    || fail "App minimum system version is not 27.0"
[[ $(info_plist_boolean_value "$engine_extension_info_plist" LSFileQuarantineEnabled) \
    == "true" ]] || fail "Engine extension LSFileQuarantineEnabled is not true"
[[ $(info_plist_value "$engine_extension_info_plist" CFBundleVersion) \
    == $(info_plist_value "$info_plist" CFBundleVersion) ]] \
    || fail "App and engine extension build versions do not match"
[[ $(info_plist_value "$engine_extension_info_plist" CFBundleShortVersionString) \
    == $(info_plist_value "$info_plist" CFBundleShortVersionString) ]] \
    || fail "App and engine extension release versions do not match"

/usr/bin/codesign --verify --strict --verbose=2 "$engine_extension_dir"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_dir"
/usr/bin/codesign --display --verbose=4 "$app_dir" >"$app_signature_output" 2>&1
/usr/bin/codesign --display --verbose=4 "$engine_extension_dir" >"$engine_signature_output" 2>&1

typeset app_allows_ad_hoc_peer=false
typeset engine_allows_ad_hoc_peer=false
typeset app_is_ad_hoc=false
typeset engine_is_ad_hoc=false
if /usr/libexec/PlistBuddy -c "Print :Torrent7AllowAdHocXPCPeer" "$info_plist" \
    >/dev/null 2>&1; then
    app_allows_ad_hoc_peer=true
fi
if /usr/libexec/PlistBuddy -c "Print :Torrent7AllowAdHocXPCPeer" \
    "$engine_extension_info_plist" >/dev/null 2>&1; then
    engine_allows_ad_hoc_peer=true
fi
if /usr/bin/grep -Eq "^Signature=adhoc$" "$app_signature_output"; then
    app_is_ad_hoc=true
fi
if /usr/bin/grep -Eq "^Signature=adhoc$" "$engine_signature_output"; then
    engine_is_ad_hoc=true
fi

if [[ $app_is_ad_hoc == true || $engine_is_ad_hoc == true ]]; then
    [[ $mode == "development" ]] \
        || fail "Ad-hoc peer mode is forbidden outside development verification"
    [[ $app_is_ad_hoc == true && $engine_is_ad_hoc == true ]] \
        || fail "App and engine extension must use the same signing mode"
    [[ $app_allows_ad_hoc_peer == true && $engine_allows_ad_hoc_peer == true ]] \
        || fail "Ad-hoc development signatures require explicit reduced-assurance peer mode"
    [[ $(info_plist_boolean_value "$info_plist" Torrent7AllowAdHocXPCPeer) == "true" ]] \
        || fail "App reduced-assurance peer mode is not true"
    [[ $(info_plist_boolean_value \
        "$engine_extension_info_plist" \
        Torrent7AllowAdHocXPCPeer) == "true" ]] \
        || fail "Engine reduced-assurance peer mode is not true"
else
    [[ $app_allows_ad_hoc_peer == false && $engine_allows_ad_hoc_peer == false ]] \
        || fail "Reduced-assurance peer mode is forbidden for identified signatures"
fi

/usr/bin/codesign --display --xml --entitlements - "$app_dir" \
    >"$app_entitlements_output" 2>/dev/null
/usr/bin/codesign --display --xml --entitlements - "$engine_extension_dir" \
    >"$engine_entitlements_output" 2>/dev/null
/usr/bin/plutil -lint "$app_entitlements_output" >/dev/null
/usr/bin/plutil -lint "$engine_entitlements_output" >/dev/null
"$root_dir/Scripts/run-tool.zsh" compare-entitlements \
    "$expected_app_entitlements" \
    "$app_entitlements_output" \
    || fail "App entitlements do not exactly match Packaging/Torrent7.entitlements"
"$root_dir/Scripts/run-tool.zsh" compare-entitlements \
    "$expected_engine_entitlements" \
    "$engine_entitlements_output" \
    || fail "Engine entitlements do not exactly match Packaging/Torrent7Engine.entitlements"

reject_match "com\\.apple\\.security\\.network\\.(client|server)" "$app_entitlements_output" \
    "GUI process unexpectedly has network entitlements"
require_match "com\\.apple\\.security\\.network\\.client" "$engine_entitlements_output" \
    "Engine extension is missing the network client entitlement"
require_match "com\\.apple\\.security\\.network\\.server" "$engine_entitlements_output" \
    "Engine extension is missing the network server entitlement"
reject_match "com\\.apple\\.security\\.files\\.(bookmarks|user-selected)" "$engine_entitlements_output" \
    "Engine extension unexpectedly has bookmark or user-selected-file authority"

# Audit the original symbols, then bind the signed payload to that exact output.
# This remains fail-closed when local/debug symbols are absent from the bundle.
typeset swift_build_dir=${SWIFT_BUILD_DIR:-$root_dir/.build}
if [[ -z ${SWIFT_BUILD_DIR:-} && $expected_sanitizer != none ]]; then
    swift_build_dir="$root_dir/.build/swift-app-$expected_sanitizer"
fi
typeset -r bin_dir=${build_products:-$swift_build_dir/out/Products/${(C)configuration}}
typeset engine_product=TorrentEngineExtension
[[ $expected_sanitizer == none ]] || engine_product=TorrentEngineDiagnosticsExtension
"$root_dir/Scripts/verify-app-code.zsh" \
    "$bin_dir/Torrent7" "$bin_dir/$engine_product" "$expected_sanitizer"
"$root_dir/Scripts/package-executable.zsh" verify "$configuration" "$expected_sanitizer" \
    "$bin_dir/Torrent7" "$executable"
"$root_dir/Scripts/package-executable.zsh" verify "$configuration" "$expected_sanitizer" \
    "$bin_dir/$engine_product" "$engine_extension_executable"
verify_signature_hardening "App" "$app_signature_output" "$app_entitlements_output"
verify_signature_hardening "Engine extension" "$engine_signature_output" "$engine_entitlements_output"

require_literal_line "Identifier=$app_bundle_id" "$app_signature_output" \
    "App signature identifier does not match its bundle identifier"
require_literal_line "Identifier=$engine_bundle_id" "$engine_signature_output" \
    "Engine signature identifier does not match its bundle identifier"
typeset -r app_team_identifier=$(
    /usr/bin/sed -n 's/^TeamIdentifier=//p' "$app_signature_output"
)
typeset -r engine_team_identifier=$(
    /usr/bin/sed -n 's/^TeamIdentifier=//p' "$engine_signature_output"
)
if [[ $app_is_ad_hoc == false ]]; then
    valid_team_identifier "$app_team_identifier" \
        || fail "Identified app signature has a missing or invalid TeamIdentifier"
    valid_team_identifier "$engine_team_identifier" \
        || fail "Identified engine signature has a missing or invalid TeamIdentifier"
    [[ $app_team_identifier == "$engine_team_identifier" ]] \
        || fail "App and engine extension TeamIdentifiers do not match"
fi

if [[ $mode == "distribution" ]]; then
    [[ $app_bundle_id == "app.torrent7" ]] \
        || fail "Distribution app has an unexpected bundle identifier"
    verify_distribution_signature "Distribution app" "$app_signature_output"
    verify_distribution_signature "Distribution engine extension" "$engine_signature_output"

    if [[ $notarization == "required" ]]; then
        /usr/bin/xcrun stapler validate "$app_dir"
        /usr/sbin/spctl --assess --type execute --verbose=4 "$app_dir"
    fi
fi

[[ $(info_plist_boolean_value "$info_plist" LSFileQuarantineEnabled) == "true" ]] \
    || fail "App LSFileQuarantineEnabled is not true"
[[ $(info_plist_value "$info_plist" CFBundleIconFile) == "AppIcon" ]] \
    || fail "CFBundleIconFile is not AppIcon"
[[ $(info_plist_value "$info_plist" CFBundleIconName) == "AppIcon" ]] \
    || fail "CFBundleIconName is not AppIcon"
[[ -f "$resources_dir/AppIcon.icns" ]] \
    || fail "Missing compiled AppIcon.icns"
[[ -f "$resources_dir/Assets.car" ]] \
    || fail "Missing compiled Assets.car"
[[ -f "$resources_dir/ThirdPartyNotices.txt" ]] \
    || fail "Missing bundled third-party notices"
/usr/bin/cmp -s "$expected_third_party_notices" "$resources_dir/ThirdPartyNotices.txt" \
    || fail "Bundled third-party notices do not match Packaging/ThirdPartyNotices.txt"

typeset -a symlink_entries=()
while IFS= read -r -d $'\0' entry; do
    symlink_entries+=("$entry")
done < <(/usr/bin/find "$app_dir" -type l -print0)
if (( ${#symlink_entries} > 0 )); then
    print -ru2 -- "App bundle must not contain symbolic links"
    printf '%s\n' "${symlink_entries[@]}" >&2
    exit 1
fi

typeset -a mach_o_entries=()
typeset file_description
while IFS= read -r -d $'\0' entry; do
    file_description=$(LC_ALL=C /usr/bin/file -b -- "$entry")
    if [[ $file_description == Mach-O* ]]; then
        mach_o_entries+=("$entry")
    fi
done < <(/usr/bin/find "$app_dir" -type f -print0)

(( ${#mach_o_entries} == 2 )) \
    || fail "App bundle must contain exactly the GUI and engine extension Mach-O executables"
typeset found_app_executable=false
typeset found_engine_executable=false
for entry in "${mach_o_entries[@]}"; do
    case "$entry" in
        "$executable")
            found_app_executable=true
            ;;
        "$engine_extension_executable")
            found_engine_executable=true
            ;;
        *)
            fail "Found unexpected Mach-O code in app bundle: $entry"
            ;;
    esac
done
[[ $found_app_executable == true && $found_engine_executable == true ]] \
    || fail "App bundle Mach-O inventory is missing an expected executable"

verify_mach_o_load_commands "$executable" "$expected_sanitizer"
verify_mach_o_load_commands "$engine_extension_executable" "$expected_sanitizer"
