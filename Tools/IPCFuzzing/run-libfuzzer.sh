#!/usr/bin/env bash
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$TOOLS_DIR/libfuzzer-build}"
SEED_CORPUS_DIR="${SEED_CORPUS_DIR:-$TOOLS_DIR/corpus/ipc_json_preflight}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$TOOLS_DIR/libfuzzer-artifacts}"
WORK_CORPUS_DIR="${WORK_CORPUS_DIR:-$ARTIFACTS_DIR/corpus/ipc_json_preflight}"
RUNS="${RUNS:-100000}"
MAX_LEN="${MAX_LEN:-2097152}"

"$TOOLS_DIR/build-libfuzzer.sh"

mkdir -p "$ARTIFACTS_DIR" "$WORK_CORPUS_DIR"
args=(
    -runs="$RUNS"
    -max_len="$MAX_LEN"
    -artifact_prefix="$ARTIFACTS_DIR/"
    -print_final_stats=1
)
if [[ -n "${LIBFUZZER_ARGS:-}" ]]; then
    read -r -a extra_args <<< "$LIBFUZZER_ARGS"
    args+=("${extra_args[@]}")
fi
args+=("$WORK_CORPUS_DIR" "$SEED_CORPUS_DIR")

"$BUILD_DIR/ipc_json_preflight" "${args[@]}"
