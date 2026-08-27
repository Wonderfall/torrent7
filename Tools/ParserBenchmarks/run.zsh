#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h:h}
typeset -r scratch_path=${PARSER_BENCHMARK_SCRATCH_PATH:-"$root_dir/.build/parser-benchmarks"}
typeset -r fixtures_dir="$scratch_path/fixtures"
typeset -r results_dir="$scratch_path/results"

if [[ -n ${SANITIZER_PROFILE:-} ]]; then
    print -ru2 -- "Parser timings must use the unsanitized release configuration"
    exit 2
fi

cd -- "$root_dir"
mkdir -p -- "$fixtures_dir" "$results_dir"

export CC="${CC:-$(xcrun --find clang)}"
export CXX="${CXX:-$(xcrun --find clang++)}"
export TORRENT7_NATIVE_DEPS_BUILD_ID=$("$root_dir/Scripts/native-deps-build-id.zsh")

typeset -a build_args=(
    --scratch-path "$scratch_path"
    --configuration release
    --triple arm64e-apple-macosx26.0
)

swift build "${build_args[@]}" --product SwiftParserBenchmark
swift build "${build_args[@]}" --product LibtorrentParserBenchmark
typeset -r bin_dir=$(swift build "${build_args[@]}" --show-bin-path)
typeset -r swift_benchmark="$bin_dir/SwiftParserBenchmark"
typeset -r native_benchmark="$bin_dir/LibtorrentParserBenchmark"

"$swift_benchmark" "$fixtures_dir" --fixtures-only

print -ru2 -- "Running native/Swift/Swift/native passes..."
"$native_benchmark" "$fixtures_dir" >"$results_dir/native-1.jsonl"
"$swift_benchmark" "$fixtures_dir" >"$results_dir/swift-1.jsonl"
"$swift_benchmark" "$fixtures_dir" >"$results_dir/swift-2.jsonl"
"$native_benchmark" "$fixtures_dir" >"$results_dir/native-2.jsonl"

typeset -r commit=$(git rev-parse --short=7 HEAD)
print -- ""
print -- "HEAD: \`$commit\` (working-tree changes are included)"
print -- "Mean of the two per-pass medians (nanoseconds per parse):"
print -- ""
awk -f "$root_dir/Tools/ParserBenchmarks/summarize.awk" \
    "$results_dir/native-1.jsonl" \
    "$results_dir/swift-1.jsonl" \
    "$results_dir/swift-2.jsonl" \
    "$results_dir/native-2.jsonl"
print -- ""
print -- "Raw JSONL: $results_dir"
