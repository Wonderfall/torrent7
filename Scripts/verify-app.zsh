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
typeset -r expected_entitlements="$root_dir/Packaging/Torrent7.entitlements"
typeset -r homebrew_prefix=/opt/homebrew
typeset -r entitlements_output=$(mktemp)
typeset -r signature_output=$(mktemp)
typeset -r arch_output=$(mktemp)
typeset -r text_output=$(mktemp)
typeset -r symbol_output=$(mktemp)
trap 'rm -f -- "$entitlements_output" "$signature_output" "$arch_output" "$text_output" "$symbol_output"' EXIT

require_match() {
    local -r pattern=$1
    local -r file=$2
    local -r message=$3

    grep -Eq -- "$pattern" "$file" || fail "$message"
}

reject_match() {
    local -r pattern=$1
    local -r file=$2
    local -r message=$3

    if grep -Eq -- "$pattern" "$file"; then
        fail "$message"
    fi
}

info_plist_value() {
    local -r key=$1
    /usr/libexec/PlistBuddy -c "Print :$key" "$info_plist"
}

codesign --verify --deep --strict --verbose=2 "$app_dir"
codesign --display --verbose=4 "$app_dir" >"$signature_output" 2>&1
cat "$signature_output"
codesign --display --xml --entitlements - "$app_dir" >"$entitlements_output" 2>/dev/null
cat "$entitlements_output"
plutil -lint "$entitlements_output" >/dev/null
xcrun swift "$root_dir/Scripts/compare-entitlements.swift" \
    "$expected_entitlements" \
    "$entitlements_output" \
    || fail "Signed entitlements do not exactly match Packaging/Torrent7.entitlements"
xcrun lipo -info "$executable" >"$arch_output"
cat "$arch_output"
xcrun otool -tvV "$executable" >"$text_output"
xcrun nm -m "$executable" >"$symbol_output"

require_match "architecture: arm64e" "$arch_output" "Executable is not arm64e"
require_match "pacibsp|retab|autd|braa|blraa" "$text_output" "Could not find expected PAC instructions in executable"
require_match "[[:space:]]bti[[:space:]]+[cj]" "$text_output" "Could not find expected BTI landing-pad instructions in executable"
require_match "_malloc_type_malloc" "$symbol_output" "Could not find typed malloc symbol in executable"
require_match "__ZnwmSt19__type_descriptor_t" "$symbol_output" "Could not find typed C++ operator new symbol in executable"
require_match "flags=.*runtime" "$signature_output" "Missing hardened runtime code-signing flag"
require_match "flags=.*restrict" "$signature_output" "Missing restrict code-signing flag"
require_match "flags=.*library-validation" "$signature_output" "Missing library validation code-signing flag"
reject_match "com.apple.security.cs.disable-library-validation" "$entitlements_output" "Found disabled library validation entitlement"

if [[ $mode == "distribution" ]]; then
    reject_match "^Signature=adhoc$" "$signature_output" "Distribution app is ad-hoc signed"
    require_match "^Authority=Developer ID Application:" "$signature_output" \
        "Distribution app is not signed with a Developer ID Application certificate"
    require_match "^Authority=Developer ID Certification Authority$" "$signature_output" \
        "Distribution signature does not chain through the Developer ID Certification Authority"
    require_match "^TeamIdentifier=${expected_team_id}$" "$signature_output" \
        "Distribution signature has an unexpected TeamIdentifier"
    require_match "^Timestamp=.+$" "$signature_output" "Distribution signature has no trusted timestamp"
    reject_match "^Timestamp=none$" "$signature_output" "Distribution signature has no trusted timestamp"

    if [[ $notarization == "required" ]]; then
        xcrun stapler validate "$app_dir"
        spctl --assess --type execute --verbose=4 "$app_dir"
    fi
fi

[[ $(info_plist_value LSFileQuarantineEnabled) == "true" ]] \
    || fail "LSFileQuarantineEnabled is not true"
[[ $(info_plist_value CFBundleIconFile) == "AppIcon" ]] \
    || fail "CFBundleIconFile is not AppIcon"
[[ $(info_plist_value CFBundleIconName) == "AppIcon" ]] \
    || fail "CFBundleIconName is not AppIcon"
[[ -f "$resources_dir/AppIcon.icns" ]] \
    || fail "Missing compiled AppIcon.icns"
[[ -f "$resources_dir/Assets.car" ]] \
    || fail "Missing compiled Assets.car"

typeset -a bundled_dylibs=()
while IFS= read -r dylib; do
    bundled_dylibs+=("$dylib")
done < <(find "$app_dir" -type f -name "*.dylib")
if (( ${#bundled_dylibs} > 0 )); then
    print -ru2 -- "Found bundled dylibs; third-party libraries should be statically linked"
    printf '%s\n' "${bundled_dylibs[@]}" >&2
    exit 1
fi

while IFS= read -r binary; do
    otool -L "$binary"
    if otool -L "$binary" | grep -q -- "$homebrew_prefix"; then
        fail "Found non-contained Homebrew load path in $binary"
    fi
    if otool -L "$binary" | grep -E "libtorrent-rasterbar|libssl\\.3|libcrypto\\.3" >/dev/null; then
        fail "Found dynamically linked third-party dependency in $binary"
    fi
done < <(find "$app_dir" -type f -perm -111)
