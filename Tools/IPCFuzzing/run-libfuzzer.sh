#!/usr/bin/env bash
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$TOOLS_DIR/libfuzzer-build}"
SEED_CORPUS_DIR="${SEED_CORPUS_DIR:-$TOOLS_DIR/corpus}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$TOOLS_DIR/libfuzzer-artifacts}"
WORK_CORPUS_DIR="${WORK_CORPUS_DIR:-$ARTIFACTS_DIR/corpus}"
RUNS="${RUNS:-100000}"

all_targets=(
    ipc_json_preflight
    storage_broker_ipc
    storage_claim_validation
    storage_manifest
)

if [[ "$#" -gt 0 ]]; then
    targets=("$@")
else
    targets=("${all_targets[@]}")
fi

default_max_len() {
    case "$1" in
        ipc_json_preflight)
            printf '%s\n' 2097152
            ;;
        storage_broker_ipc)
            printf '%s\n' 65536
            ;;
        storage_claim_validation)
            printf '%s\n' 262144
            ;;
        storage_manifest)
            printf '%s\n' 1048576
            ;;
        *)
            echo "Unknown fuzz target: $1" >&2
            exit 1
            ;;
    esac
}

"$TOOLS_DIR/build-libfuzzer.sh" "${targets[@]}"

mkdir -p "$ARTIFACTS_DIR" "$WORK_CORPUS_DIR"

for target in "${targets[@]}"; do
    target_artifacts="$ARTIFACTS_DIR/$target"
    target_work_corpus="$WORK_CORPUS_DIR/$target"
    mkdir -p "$target_artifacts" "$target_work_corpus"
    max_len="${MAX_LEN:-$(default_max_len "$target")}"
    args=(
        -runs="$RUNS"
        -max_len="$max_len"
        -artifact_prefix="$target_artifacts/"
        -print_final_stats=1
    )
    if [[ -n "${LIBFUZZER_ARGS:-}" ]]; then
        # shellcheck disable=SC2206
        extra_args=($LIBFUZZER_ARGS)
        args+=("${extra_args[@]}")
    fi
    args+=("$target_work_corpus")
    if [[ -d "$SEED_CORPUS_DIR/$target" ]]; then
        args+=("$SEED_CORPUS_DIR/$target")
    fi

    echo "Running libFuzzer target $target"
    "$BUILD_DIR/$target" "${args[@]}"
done
