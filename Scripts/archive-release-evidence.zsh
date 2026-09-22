#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
fail() { print -ru2 -- "$1"; exit 1; }
(( $# == 5 )) || fail "Usage: archive-release-evidence.zsh APP BIN_DIR DEPS_PREFIX SBOM_DIR OUTPUT_DIR"
typeset -r app_dir=${1:A} bin_dir=${2:A} deps_prefix=${3:A} sbom_dir=${4:A} output_dir=${5:A}
[[ -d $app_dir && -d $bin_dir && -d $deps_prefix && -d $sbom_dir ]] || fail "Missing release evidence input"
[[ ! -e $output_dir ]] || fail "Release evidence output already exists"
/bin/mkdir -m 700 -- "$output_dir"
typeset complete=0
trap '(( complete )) || /bin/rm -rf -- "$output_dir"' EXIT
/bin/mkdir -- "$output_dir/Symbols" "$output_dir/UnstrippedBinaries" "$output_dir/SBOM"

typeset -a products=(Torrent7 TorrentEngineExtension)
typeset -a executables=(
    "$app_dir/Contents/MacOS/Torrent 7"
    "$app_dir/Contents/PlugIns/app.torrent7.engine.appex/Contents/MacOS/TorrentEngineExtension"
)
typeset -i index
for (( index = 1; index <= ${#products}; index++ )); do
    product=${products[index]}
    binary=${executables[index]}
    symbols="$bin_dir/$product.dSYM"
    [[ -f $binary && ! -L $binary && -d $symbols && ! -L $symbols ]] || fail "Missing binary or dSYM: $product"
    binary_uuid=$(/usr/bin/xcrun dwarfdump --uuid "$binary" | /usr/bin/awk '/^UUID:/ {print $2 " " $3}')
    symbols_uuid=$(/usr/bin/xcrun dwarfdump --uuid "$symbols" | /usr/bin/awk '/^UUID:/ {print $2 " " $3}')
    print -r -- "$binary_uuid" | /usr/bin/grep -Eq '^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12} \(arm64e\)$' \
        || fail "Unexpected executable UUID or architecture: $product"
    [[ $binary_uuid == "$symbols_uuid" ]] || fail "dSYM UUID does not match the shipped executable: $product"
    "$root_dir/Scripts/package-executable.zsh" verify release none "$bin_dir/$product" "$binary"
    /usr/bin/ditto "$symbols" "$output_dir/Symbols/$product.dSYM"
    /bin/cp -- "$bin_dir/$product" "$output_dir/UnstrippedBinaries/$product"
    print -r -- "$product $binary_uuid" >> "$output_dir/symbol-uuids.txt"

    typeset -a sboms=("$sbom_dir/$product/"*.json(N))
    (( ${#sboms} == 1 )) || fail "Expected exactly one SwiftPM SBOM for $product"
    [[ -s ${sboms[1]} && ! -L ${sboms[1]} ]] || fail "Missing or linked SwiftPM SBOM: $product"
    [[ $(/usr/bin/plutil -extract bomFormat raw -o - "${sboms[1]}") == CycloneDX \
        && $(/usr/bin/plutil -extract specVersion raw -o - "${sboms[1]}") == 1.7 \
        && $(/usr/bin/plutil -extract metadata.component.name raw -o - "${sboms[1]}") == "$product" ]] \
        || fail "SwiftPM SBOM does not describe the expected product: $product"
    /bin/cp -- "${sboms[1]}" "$output_dir/SBOM/$product.cdx.json"
done

native_build_id=$(DEPS_PREFIX="$deps_prefix" BOOST_PREFIX="$deps_prefix" BORINGSSL_PREFIX="$deps_prefix" \
    SANITIZER_PROFILE= "$root_dir/Scripts/native-deps-build-id.zsh")
"$root_dir/Scripts/run-tool.zsh" write-native-sbom "$deps_prefix" "$output_dir/SBOM/native.cdx.json" "$native_build_id"
print -r -- "$native_build_id" > "$output_dir/native-build-id.txt"
{
    /usr/bin/xcodebuild -version
    /usr/bin/xcrun swift --version
    /usr/bin/xcrun --sdk macosx --show-sdk-version
} > "$output_dir/toolchain.txt"
/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$output_dir/Symbols" "$output_dir/Symbols.zip"
/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$output_dir/UnstrippedBinaries" "$output_dir/UnstrippedBinaries.zip"
/bin/rm -rf -- "$output_dir/Symbols" "$output_dir/UnstrippedBinaries"
complete=1
