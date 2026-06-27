#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
typeset -r app_dir=${1:-$root_dir/.build/App/Torrent 7.app}
typeset -r info_plist="$app_dir/Contents/Info.plist"
typeset -r executable="$app_dir/Contents/MacOS/Torrent 7"
typeset -r resources_dir="$app_dir/Contents/Resources"
typeset -r homebrew_prefix=${HOMEBREW_PREFIX:-/opt/homebrew}
typeset -r entitlements_output=$(mktemp)
typeset -r signature_output=$(mktemp)
typeset -r arch_output=$(mktemp)
typeset -r text_output=$(mktemp)
typeset -r symbol_output=$(mktemp)
trap 'rm -f -- "$entitlements_output" "$signature_output" "$arch_output" "$text_output" "$symbol_output"' EXIT

fail() {
    print -ru2 -- "$1"
    exit 1
}

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

plist_value() {
    local -r key=$1
    /usr/libexec/PlistBuddy -c "Print :$key" "$entitlements_output"
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

typeset -a required_entitlements=(
    com.apple.security.hardened-process
    com.apple.security.hardened-process.enhanced-security-version-string
    com.apple.security.hardened-process.dyld-ro
    com.apple.security.hardened-process.hardened-heap
    com.apple.security.hardened-process.checked-allocations
    com.apple.security.hardened-process.platform-restrictions-string
)
for entitlement in "${required_entitlements[@]}"; do
    plist_value "$entitlement" >/dev/null 2>&1 || fail "Missing Enhanced Security entitlement: $entitlement"
done

[[ $(plist_value com.apple.security.hardened-process.enhanced-security-version-string) == "2" ]] \
    || fail "Enhanced Security version is not set to 2"
[[ $(plist_value com.apple.security.hardened-process.platform-restrictions-string) == "2" ]] \
    || fail "Enhanced Security platform restrictions are not set to 2"
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
