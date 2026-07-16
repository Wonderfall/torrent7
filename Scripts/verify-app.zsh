#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
typeset mode=development
typeset notarization=
typeset expected_team_id=${EXPECTED_TEAM_ID:-}
typeset app_argument=

fail() {
    print -ru2 -- "$1"
    exit 1
}

while (( $# > 0 )); do
    case "$1" in
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
typeset -r xpc_services_dir="$app_dir/Contents/XPCServices"
typeset -r engine_service_dir="$xpc_services_dir/app.torrent7.engine.xpc"
typeset -r engine_service_info_plist="$engine_service_dir/Contents/Info.plist"
typeset -r engine_service_executable="$engine_service_dir/Contents/MacOS/TorrentEngineService"
typeset -r expected_app_entitlements="$root_dir/Packaging/Torrent7.entitlements"
typeset -r expected_engine_entitlements="$root_dir/Packaging/Torrent7Engine.entitlements"
typeset -r expected_third_party_notices="$root_dir/Packaging/ThirdPartyNotices.txt"
typeset -r temporary_dir=$(/usr/bin/mktemp -d)
typeset -r app_entitlements_output="$temporary_dir/app-entitlements.plist"
typeset -r app_signature_output="$temporary_dir/app-signature.txt"
typeset -r app_arch_output="$temporary_dir/app-arch.txt"
typeset -r app_text_output="$temporary_dir/app-text.txt"
typeset -r app_symbol_output="$temporary_dir/app-symbols.txt"
typeset -r engine_entitlements_output="$temporary_dir/engine-entitlements.plist"
typeset -r engine_signature_output="$temporary_dir/engine-signature.txt"
typeset -r engine_arch_output="$temporary_dir/engine-arch.txt"
typeset -r engine_text_output="$temporary_dir/engine-text.txt"
typeset -r engine_symbol_output="$temporary_dir/engine-symbols.txt"
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

verify_binary_hardening() {
    local -r label=$1
    local -r signature_file=$2
    local -r entitlements_file=$3
    local -r arch_file=$4
    local -r text_file=$5
    local -r requires_bti=$6

    require_match "architecture: arm64e" "$arch_file" "$label executable is not arm64e"
    require_match "pacibsp|retab|autd|braa|blraa" "$text_file" \
        "$label executable has no expected PAC instructions"
    if [[ $requires_bti == true ]]; then
        require_match "[[:space:]]bti[[:space:]]+[cj]" "$text_file" \
            "$label executable has no expected BTI landing-pad instructions"
    fi
    require_match "flags=.*runtime" "$signature_file" \
        "$label signature is missing the hardened runtime flag"
    require_match "flags=.*restrict" "$signature_file" \
        "$label signature is missing the restrict flag"
    require_match "flags=.*library-validation" "$signature_file" \
        "$label signature is missing the library validation flag"
    reject_match "com.apple.security.cs.disable-library-validation" "$entitlements_file" \
        "$label disables library validation"
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
    local -r allows_diagnostic_runtime=$2
    local dependencies load_command_output load_command_name load_path line
    dependencies=$(/usr/bin/otool -L "$binary")
    print -r -- "$dependencies"
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
                    [[ $mode == "development" && $allows_diagnostic_runtime == true ]] \
                        || fail "Diagnostic Xcode runtime path is forbidden in $binary"
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
                [[ $mode == "development" && $allows_diagnostic_runtime == true ]] \
                    || fail "Diagnostic sanitizer runtime is forbidden in $binary"
                ;;
            *)
                fail "Found non-system Mach-O load command in $binary: $load_path"
                ;;
        esac
    done
}

[[ -d "$xpc_services_dir" ]] || fail "Missing Contents/XPCServices"
typeset -a embedded_service_entries=()
while IFS= read -r -d $'\0' entry; do
    embedded_service_entries+=("$entry")
done < <(/usr/bin/find "$xpc_services_dir" -mindepth 1 -maxdepth 1 -print0)
(( ${#embedded_service_entries} == 1 )) \
    || fail "Contents/XPCServices must contain exactly one embedded service"
[[ ${embedded_service_entries[1]} == "$engine_service_dir" ]] \
    || fail "Unexpected embedded service: ${embedded_service_entries[1]}"
[[ ! -L "$engine_service_dir" ]] || fail "Engine service bundle must not be a symbolic link"
[[ -f "$engine_service_info_plist" && ! -L "$engine_service_info_plist" ]] \
    || fail "Missing or linked engine service Info.plist"
[[ -f "$executable" && -x "$executable" && ! -L "$executable" ]] \
    || fail "Missing or linked app executable"
[[ -f "$engine_service_executable" && -x "$engine_service_executable" \
    && ! -L "$engine_service_executable" ]] \
    || fail "Missing or linked engine service executable"

typeset -r app_bundle_id=$(info_plist_value "$info_plist" CFBundleIdentifier)
typeset expected_engine_bundle_id
case "$app_bundle_id" in
    app.torrent7)
        expected_engine_bundle_id=app.torrent7.engine
        ;;
    app.torrent7.debug)
        [[ $mode == "development" ]] \
            || fail "Distribution verification does not allow the debug bundle identifier"
        expected_engine_bundle_id=app.torrent7.debug.engine
        ;;
    *)
        fail "Unexpected app bundle identifier: $app_bundle_id"
        ;;
esac
typeset -r engine_bundle_id=$(info_plist_value "$engine_service_info_plist" CFBundleIdentifier)
[[ $engine_bundle_id == "$expected_engine_bundle_id" ]] \
    || fail "Unexpected engine service bundle identifier: $engine_bundle_id"
[[ $(info_plist_value "$info_plist" CFBundlePackageType) == "APPL" ]] \
    || fail "App CFBundlePackageType is not APPL"
[[ $(info_plist_value "$info_plist" CFBundleExecutable) == "Torrent 7" ]] \
    || fail "App CFBundleExecutable is unexpected"
[[ $(info_plist_value "$engine_service_info_plist" CFBundlePackageType) == "XPC!" ]] \
    || fail "Engine service CFBundlePackageType is not XPC!"
[[ $(info_plist_value "$engine_service_info_plist" CFBundleExecutable) == "TorrentEngineService" ]] \
    || fail "Engine service CFBundleExecutable is unexpected"
[[ $(info_plist_value "$engine_service_info_plist" XPCService:ServiceType) == "Application" ]] \
    || fail "Engine service is not application-scoped"
[[ $(info_plist_value "$engine_service_info_plist" LSMinimumSystemVersion) == "26.0" ]] \
    || fail "Engine service minimum system version is not 26.0"
[[ $(info_plist_boolean_value "$engine_service_info_plist" LSFileQuarantineEnabled) \
    == "true" ]] || fail "Engine service LSFileQuarantineEnabled is not true"
[[ $(info_plist_value "$engine_service_info_plist" CFBundleVersion) \
    == $(info_plist_value "$info_plist" CFBundleVersion) ]] \
    || fail "App and engine service build versions do not match"
[[ $(info_plist_value "$engine_service_info_plist" CFBundleShortVersionString) \
    == $(info_plist_value "$info_plist" CFBundleShortVersionString) ]] \
    || fail "App and engine service release versions do not match"

/usr/bin/codesign --verify --strict --verbose=2 "$engine_service_dir"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_dir"
/usr/bin/codesign --display --verbose=4 "$app_dir" >"$app_signature_output" 2>&1
/usr/bin/codesign --display --verbose=4 "$engine_service_dir" >"$engine_signature_output" 2>&1
/bin/cat "$app_signature_output"
/bin/cat "$engine_signature_output"

typeset app_allows_ad_hoc_peer=false
typeset engine_allows_ad_hoc_peer=false
typeset app_is_ad_hoc=false
typeset engine_is_ad_hoc=false
if /usr/libexec/PlistBuddy -c "Print :Torrent7AllowAdHocXPCPeer" "$info_plist" \
    >/dev/null 2>&1; then
    app_allows_ad_hoc_peer=true
fi
if /usr/libexec/PlistBuddy -c "Print :Torrent7AllowAdHocXPCPeer" \
    "$engine_service_info_plist" >/dev/null 2>&1; then
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
        || fail "App and engine service must use the same signing mode"
    [[ $app_allows_ad_hoc_peer == true && $engine_allows_ad_hoc_peer == true ]] \
        || fail "Ad-hoc development signatures require explicit reduced-assurance peer mode"
    [[ $(info_plist_boolean_value "$info_plist" Torrent7AllowAdHocXPCPeer) == "true" ]] \
        || fail "App reduced-assurance peer mode is not true"
    [[ $(info_plist_boolean_value \
        "$engine_service_info_plist" \
        Torrent7AllowAdHocXPCPeer) == "true" ]] \
        || fail "Engine reduced-assurance peer mode is not true"
else
    [[ $app_allows_ad_hoc_peer == false && $engine_allows_ad_hoc_peer == false ]] \
        || fail "Reduced-assurance peer mode is forbidden for identified signatures"
fi

/usr/bin/codesign --display --xml --entitlements - "$app_dir" \
    >"$app_entitlements_output" 2>/dev/null
/usr/bin/codesign --display --xml --entitlements - "$engine_service_dir" \
    >"$engine_entitlements_output" 2>/dev/null
/bin/cat "$app_entitlements_output"
/bin/cat "$engine_entitlements_output"
/usr/bin/plutil -lint "$app_entitlements_output" >/dev/null
/usr/bin/plutil -lint "$engine_entitlements_output" >/dev/null
/usr/bin/xcrun swift "$root_dir/Scripts/compare-entitlements.swift" \
    "$expected_app_entitlements" \
    "$app_entitlements_output" \
    || fail "App entitlements do not exactly match Packaging/Torrent7.entitlements"
/usr/bin/xcrun swift "$root_dir/Scripts/compare-entitlements.swift" \
    "$expected_engine_entitlements" \
    "$engine_entitlements_output" \
    || fail "Engine entitlements do not exactly match Packaging/Torrent7Engine.entitlements"

reject_match "com\\.apple\\.security\\.network\\.(client|server)" "$app_entitlements_output" \
    "GUI process unexpectedly has network entitlements"
require_match "com\\.apple\\.security\\.network\\.client" "$engine_entitlements_output" \
    "Engine service is missing the network client entitlement"
require_match "com\\.apple\\.security\\.network\\.server" "$engine_entitlements_output" \
    "Engine service is missing the network server entitlement"
reject_match "com\\.apple\\.security\\.files\\.(bookmarks|user-selected)" "$engine_entitlements_output" \
    "Engine service unexpectedly has bookmark or user-selected-file authority"

/usr/bin/xcrun lipo -info "$executable" >"$app_arch_output"
/usr/bin/xcrun lipo -info "$engine_service_executable" >"$engine_arch_output"
/bin/cat "$app_arch_output"
/bin/cat "$engine_arch_output"
/usr/bin/xcrun otool -tvV "$executable" >"$app_text_output"
/usr/bin/xcrun otool -tvV "$engine_service_executable" >"$engine_text_output"
/usr/bin/xcrun nm -m "$executable" >"$app_symbol_output"
/usr/bin/xcrun nm -m "$engine_service_executable" >"$engine_symbol_output"

# The GUI is now pure Swift. Swift arm64e emits PAC but has no BTI codegen
# switch; the native engine remains the executable where BTI is applicable.
verify_binary_hardening \
    "App" \
    "$app_signature_output" \
    "$app_entitlements_output" \
    "$app_arch_output" \
    "$app_text_output" \
    false
verify_binary_hardening \
    "Engine service" \
    "$engine_signature_output" \
    "$engine_entitlements_output" \
    "$engine_arch_output" \
    "$engine_text_output" \
    true
require_match "_malloc_type_malloc" "$engine_symbol_output" \
    "Engine service has no typed malloc symbol"
require_match "__ZnwmSt19__type_descriptor_t" "$engine_symbol_output" \
    "Engine service has no typed C++ operator new symbol"
reject_match "[[:space:]]_Torrent(Client|Bridge)|__ZN10libtorrent|libtorrent-rasterbar" \
    "$app_symbol_output" \
    "GUI executable still contains native torrent-engine symbols"

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
        || fail "App and engine service TeamIdentifiers do not match"
fi

if [[ $mode == "distribution" ]]; then
    [[ $app_bundle_id == "app.torrent7" ]] \
        || fail "Distribution app has an unexpected bundle identifier"
    verify_distribution_signature "Distribution app" "$app_signature_output"
    verify_distribution_signature "Distribution engine service" "$engine_signature_output"

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
    || fail "App bundle must contain exactly the GUI and engine service Mach-O executables"
typeset found_app_executable=false
typeset found_engine_executable=false
for entry in "${mach_o_entries[@]}"; do
    case "$entry" in
        "$executable")
            found_app_executable=true
            ;;
        "$engine_service_executable")
            found_engine_executable=true
            ;;
        *)
            fail "Found unexpected Mach-O code in app bundle: $entry"
            ;;
    esac
done
[[ $found_app_executable == true && $found_engine_executable == true ]] \
    || fail "App bundle Mach-O inventory is missing an expected executable"

typeset allows_diagnostic_runtime=false
if [[ $app_bundle_id == "app.torrent7.debug" ]]; then
    allows_diagnostic_runtime=true
fi
verify_mach_o_load_commands "$executable" "$allows_diagnostic_runtime"
verify_mach_o_load_commands "$engine_service_executable" "$allows_diagnostic_runtime"
