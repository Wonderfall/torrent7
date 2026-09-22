#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail
export LC_ALL=C

fail() { print -ru2 -- "$1"; exit 1; }
(( $# == 5 )) || fail "Usage: package-executable.zsh prepare|verify debug|release none|address|thread ORIGINAL PACKAGED"
typeset -r operation=$1 configuration=$2 sanitizer=$3 original=$4 packaged=$5
[[ $operation == prepare || $operation == verify ]] || fail "Unexpected packaging operation"
[[ $configuration == debug || $configuration == release ]] || fail "Unexpected build configuration"
[[ $sanitizer == none || $sanitizer == address || $sanitizer == thread ]] || fail "Unexpected sanitizer profile"
[[ -f $original && ! -L $original ]] || fail "Missing or linked original executable: $original"
[[ ! -L $packaged ]] || fail "Packaged executable must not be a symbolic link"
[[ ${original:A} != ${packaged:A} && ! $original -ef $packaged ]] \
    || fail "Packaging must preserve the original executable"
typeset -r temporary_dir=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf -- "$temporary_dir"' EXIT
typeset -r expected="$temporary_dir/expected"
/bin/cp -- "$original" "$expected"
# SwiftBuild signs its output. Remove that signature only from our private copy;
# signing the bundle is the final step after packaging has been verified.
/usr/bin/codesign --remove-signature "$expected"

section_inventory() {
    /usr/bin/xcrun otool -l "$1" | /usr/bin/awk '
        /^Load command / { section = 0 }
        /^Section$/ { section = 1; count++ }
        section { print }
        END { if (count == 0) exit 1 }
    '
}

if [[ $configuration == release && $sanitizer == none ]]; then
    typeset -r symbols="$original.dSYM"
    [[ -d $symbols && ! -L $symbols ]] || fail "Missing or linked dSYM: $symbols"
    typeset original_uuid symbols_uuid
    original_uuid=$(/usr/bin/xcrun dwarfdump --uuid "$original" | /usr/bin/awk '/^UUID:/ { print $2 " " $3 }')
    symbols_uuid=$(/usr/bin/xcrun dwarfdump --uuid "$symbols" | /usr/bin/awk '/^UUID:/ { print $2 " " $3 }')
    [[ $original_uuid != *$'\n'* ]] || fail "Expected one executable UUID"
    print -r -- "$original_uuid" | /usr/bin/grep -Eq '^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12} \(arm64e\)$' \
        || fail "Unexpected executable UUID or architecture: $original"
    [[ $original_uuid == "$symbols_uuid" ]] || fail "dSYM UUID does not match the original executable: $original"

    /usr/bin/env -u STRIP_NLISTS /usr/bin/xcrun strip -S -x "$expected"
    # Use Apple's Mach-O reader instead of maintaining a binary parser. Compare
    # every section's layout and raw contents, including Swift/ObjC metadata and
    # unwind information. Only the symbol/link-edit bookkeeping may change.
    section_inventory "$original" > "$temporary_dir/original-sections"
    section_inventory "$expected" > "$temporary_dir/expected-sections"
    /usr/bin/cmp -s "$temporary_dir/original-sections" "$temporary_dir/expected-sections" \
        || fail "Stripping changed executable section layout: $original"
    /usr/bin/awk '
        $1 == "sectname" { section = $2 }
        $1 == "segname" { segment = $2 }
        $1 == "flags" { print segment, section, $2 }
    ' \
        "$temporary_dir/original-sections" > "$temporary_dir/sections"
    while read -r segment section flags; do
        # S_ZEROFILL, S_GB_ZEROFILL and S_THREAD_LOCAL_ZEROFILL have no file
        # contents. Their size, address and flags were checked in the inventory.
        case $(( flags & 0xff )) in 1|12|18) continue ;; esac
        /usr/bin/xcrun otool -s "$segment" "$section" "$original" \
            | /usr/bin/sed '1d' > "$temporary_dir/original-bytes"
        /usr/bin/xcrun otool -s "$segment" "$section" "$expected" \
            | /usr/bin/sed '1d' > "$temporary_dir/expected-bytes"
        /usr/bin/cmp -s "$temporary_dir/original-bytes" "$temporary_dir/expected-bytes" \
            || fail "Stripping changed executable section $segment,$section: $original"
    done < "$temporary_dir/sections"
    typeset packaged_uuid
    packaged_uuid=$(/usr/bin/xcrun dwarfdump --uuid "$expected" | /usr/bin/awk '/^UUID:/ { print $2 " " $3 }')
    [[ $packaged_uuid == "$original_uuid" ]] || fail "Stripping changed the executable UUID"
fi

case $operation in
    prepare)
        /bin/cp -- "$expected" "$packaged"
        ;;
    verify)
        [[ -f $packaged ]] || fail "Missing packaged executable: $packaged"
        /bin/cp -- "$packaged" "$temporary_dir/actual"
        /usr/bin/codesign --remove-signature "$temporary_dir/actual"
        # Removing a signature leaves its __LINKEDIT virtual allocation size.
        # Re-sign both temporary files identically to canonicalize that size and
        # LC_CODE_SIGNATURE, including when the real signature used Developer ID.
        for binary in "$expected" "$temporary_dir/actual"; do
            /usr/bin/codesign --sign - --identifier app.torrent7.packaging-comparison \
                --timestamp=none "$binary"
        done
        # Do not strip the actual payload here: that would accept an unstripped
        # release or silently discard unexpected local symbols before comparison.
        # Exact equality also covers load commands, exports and dyld fixups.
        /usr/bin/cmp -s "$expected" "$temporary_dir/actual" \
            || fail "Packaged executable does not match the audited output and symbol policy: $packaged"
        ;;
esac
