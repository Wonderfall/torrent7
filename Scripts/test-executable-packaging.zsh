#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
fail() { print -ru2 -- "$1"; exit 1; }
(( $# == 1 )) || fail "Usage: test-executable-packaging.zsh RELEASE_BIN_DIR"
typeset -r bin_dir=${1:A}
typeset -r temporary_dir=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf -- "$temporary_dir"' EXIT
typeset -r packager="$root_dir/Scripts/package-executable.zsh"

expect_rejection() {
    local -r diagnostic=$1
    shift
    if "$@" > "$temporary_dir/rejection.log" 2>&1; then
        fail "Accepted invalid packaging: $diagnostic"
    fi
    /usr/bin/grep -Fq -- "$diagnostic" "$temporary_dir/rejection.log" \
        || { /bin/cat "$temporary_dir/rejection.log" >&2; fail "Unexpected rejection"; }
}

for product in Torrent7 TorrentEngineExtension; do
    original="$bin_dir/$product"
    packaged="$temporary_dir/$product"
    original_digest=$(/usr/bin/shasum -a 256 "$original")
    "$packager" prepare release none "$original" "$packaged"
    # Re-signing must preserve the comparison, while allowing final bundle
    # identifiers, entitlements and signing identities to differ from SwiftBuild.
    /usr/bin/codesign --sign - --identifier "app.torrent7.packaging-test.$product" \
        --options runtime,restrict,library --timestamp=none "$packaged"
    /usr/bin/codesign --verify --strict "$packaged"
    "$packager" verify release none "$original" "$packaged"
    [[ $(/usr/bin/stat -f %z "$packaged") -lt $(/usr/bin/stat -f %z "$original") ]] \
        || fail "Release executable did not shrink"
    [[ $(/usr/bin/shasum -a 256 "$original") == "$original_digest" ]] \
        || fail "Packaging modified the original executable"
    /bin/cp "$original" "$temporary_dir/unstripped"
    expect_rejection 'symbol policy' "$packager" verify release none "$original" "$temporary_dir/unstripped"
done

# Exercise all configuration/sanitizer policy combinations using one real
# executable as the fixture. Every diagnostic policy must preserve all symbols.
for configuration in debug release; do
    for sanitizer in none address thread; do
        [[ $configuration != release || $sanitizer != none ]] || continue
        "$packager" prepare "$configuration" "$sanitizer" "$bin_dir/Torrent7" "$temporary_dir/diagnostic"
        "$packager" verify "$configuration" "$sanitizer" "$bin_dir/Torrent7" "$temporary_dir/diagnostic"
        expect_rejection 'symbol policy' "$packager" verify "$configuration" "$sanitizer" \
            "$bin_dir/Torrent7" "$temporary_dir/Torrent7"
    done
done

expect_rejection 'Packaging must preserve the original' "$packager" prepare release none \
    "$bin_dir/Torrent7" "$bin_dir/Torrent7"
expect_rejection 'symbol policy' "$packager" verify release none \
    "$bin_dir/TorrentEngineExtension" "$temporary_dir/Torrent7"
expect_rejection 'Code audits require unstripped local function symbols' \
    "$root_dir/Scripts/verify-app-code.zsh" "$temporary_dir/Torrent7" "$bin_dir/TorrentEngineExtension" none

# Mutate both instruction bytes and runtime data without changing LC_UUID.
# Re-sign to demonstrate that matching UUIDs and valid signatures are insufficient.
/usr/bin/xcrun otool -l "$temporary_dir/Torrent7" > "$temporary_dir/load-commands"
for section in __text __const; do
    offset=$(/usr/bin/awk -v name="$section" '
        $1 == "sectname" { wanted = ($2 == name) }
        wanted && $1 == "segname" { wanted = ($2 == "__TEXT") }
        wanted && $1 == "offset" { print $2; exit }
    ' "$temporary_dir/load-commands")
    [[ -n $offset && $offset != *[^0-9]* && $offset -gt 0 ]] || fail "Missing fixture section"
    /bin/cp "$temporary_dir/Torrent7" "$temporary_dir/altered"
    /usr/bin/codesign --remove-signature "$temporary_dir/altered"
    byte=$(/usr/bin/od -An -tu1 -j "$offset" -N 1 "$temporary_dir/altered")
    if (( byte == 0 )); then replacement='\001'; else replacement='\000'; fi
    printf "$replacement" | /bin/dd of="$temporary_dir/altered" bs=1 seek="$offset" conv=notrunc 2>/dev/null
    /usr/bin/codesign --sign - --timestamp=none "$temporary_dir/altered"
    /usr/bin/codesign --verify --strict "$temporary_dir/altered"
    original_uuid=$(/usr/bin/xcrun dwarfdump --uuid "$bin_dir/Torrent7" | /usr/bin/awk '{ print $2, $3 }')
    altered_uuid=$(/usr/bin/xcrun dwarfdump --uuid "$temporary_dir/altered" | /usr/bin/awk '{ print $2, $3 }')
    [[ $original_uuid == "$altered_uuid" ]] || fail "Mutation changed the fixture UUID"
    expect_rejection 'symbol policy' "$packager" verify release none \
        "$bin_dir/Torrent7" "$temporary_dir/altered"
done

/bin/cp "$bin_dir/Torrent7" "$temporary_dir/original"
expect_rejection 'Missing or linked dSYM' "$packager" prepare release none \
    "$temporary_dir/original" "$temporary_dir/missing-symbols"
[[ ! -e "$temporary_dir/missing-symbols" ]] || fail "Published an executable without symbols"
/usr/bin/ditto "$bin_dir/TorrentEngineExtension.dSYM" "$temporary_dir/original.dSYM"
expect_rejection 'dSYM UUID does not match' "$packager" prepare release none \
    "$temporary_dir/original" "$temporary_dir/mismatched-symbols"
[[ ! -e "$temporary_dir/mismatched-symbols" ]] || fail "Published an executable with mismatched symbols"
/bin/ln -s "$bin_dir/Torrent7" "$temporary_dir/linked"
expect_rejection 'symbolic link' "$packager" prepare debug none \
    "$bin_dir/Torrent7" "$temporary_dir/linked"
/bin/ln "$temporary_dir/original" "$temporary_dir/hard-linked"
expect_rejection 'Packaging must preserve the original' "$packager" prepare debug none \
    "$temporary_dir/original" "$temporary_dir/hard-linked"

print -r -- 'Executable packaging: release signing and all diagnostic policies passed; altered code/data, wrong products, missing/mismatched symbols, stripped audit inputs and linked outputs rejected.'
