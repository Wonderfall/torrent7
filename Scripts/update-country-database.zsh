#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
typeset -r release=2026-10
typeset -r database_date=20261001
typeset -r expected_sha256=097426b8ddae89157d444a59ac1847e873f7943c32d52becc4371c8b0273af80
typeset -r temporary_dir=$(mktemp -d)
trap 'rm -rf -- "$temporary_dir"' EXIT

"$root_dir/Scripts/verify-xcode.zsh"
/usr/bin/curl --fail --location --proto '=https' --proto-redir '=https' \
    --max-time 120 --max-filesize 16777216 \
    "https://download.db-ip.com/free/dbip-country-lite-$release.csv.gz" \
    --output "$temporary_dir/countries.csv.gz"
typeset -r actual_sha256=$(/usr/bin/shasum -a 256 "$temporary_dir/countries.csv.gz")
[[ ${actual_sha256%% *} == $expected_sha256 ]] || {
    print -ru2 -- 'Country database checksum mismatch'
    exit 1
}
# Only the pinned, verified archive is decompressed. The converter validates all
# ranges and country codes and writes the resource atomically.
/usr/bin/gzip -dc "$temporary_dir/countries.csv.gz" > "$temporary_dir/countries.csv"
/usr/bin/xcrun swift run --package-path "$root_dir/Tools" \
    --scratch-path "$root_dir/.build/repository-tools" --configuration release \
    build-country-database "$temporary_dir/countries.csv" \
    "$root_dir/Packaging/PeerCountries.bin" "$database_date"
