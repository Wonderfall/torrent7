#!/usr/bin/env bash
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$TOOLS_DIR/libfuzzer-build}"
SEED_CORPUS_DIR="${SEED_CORPUS_DIR:-${CORPUS_DIR:-$TOOLS_DIR/corpus}}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$TOOLS_DIR/libfuzzer-artifacts}"
WORK_CORPUS_DIR="${WORK_CORPUS_DIR:-$ARTIFACTS_DIR/corpus}"
RUNS="${RUNS:-100000}"

case ":${ASAN_OPTIONS:-}:" in
    *":detect_container_overflow="*)
        ;;
    *)
        ASAN_OPTIONS="detect_container_overflow=0${ASAN_OPTIONS:+:$ASAN_OPTIONS}"
        export ASAN_OPTIONS
        ;;
esac

all_targets=(
    bridge_magnet
    bridge_torrent_file
    bridge_resume_startup
    bridge_session_api
)

if [[ "$#" -gt 0 ]]; then
    targets=("$@")
else
    targets=("${all_targets[@]}")
fi

default_max_len() {
    case "$1" in
        bridge_torrent_file)
            printf '%s\n' 1048576
            ;;
        *)
            printf '%s\n' 65536
            ;;
    esac
}

missing=()
for target in "${targets[@]}"; do
    if [[ ! -x "$BUILD_DIR/$target" ]]; then
        missing+=("$target")
    fi
done

if [[ "${#missing[@]}" -gt 0 ]]; then
    "$TOOLS_DIR/build-libfuzzer.sh" "${missing[@]}"
fi

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
