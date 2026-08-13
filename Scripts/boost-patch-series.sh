#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

readonly BOOST_VERSION="1.92.0"
readonly -a BOOST_PATCHED_FILES=(
    "boost/asio/detail/reactor_op.hpp"
    "boost/asio/detail/scheduler_operation.hpp"
    "boost/asio/detail/executor_function.hpp"
)
readonly -a BOOST_PATCHES=(
    "$ROOT_DIR/Scripts/patches/boost-1.92.0-asio-operation-pac.patch"
    "$ROOT_DIR/Scripts/patches/boost-1.92.0-asio-executor-function-pac.patch"
)
# One exact tree per ordered patch-series stage. Recognizing intermediate
# stages lets an existing verified header cache receive only newly appended
# patches without weakening the unexpected-change guard.
readonly -a BOOST_PATCH_TREES=(
    "b05b431f6b5e1dba5d56d37b1fda33737411844edc1f7c568c89954c075cd41b"
    "601ccf950bd8cb2cc8b00094e643f616745466805fb83b0eabc1152a3e1e5df4"
    "7acf3c857b2872d3ee1a72087aa88357823ceae7c504d173f18e505840a4b45f"
)
readonly BOOST_BASE_TREE="${BOOST_PATCH_TREES[0]}"
readonly BOOST_PATCHED_TREE="${BOOST_PATCH_TREES[${#BOOST_PATCH_TREES[@]} - 1]}"

fail() {
    echo "$1" >&2
    exit 1
}

require_file() {
    local path="$1"
    local label="$2"
    [[ -f "$path" && ! -L "$path" ]] || fail "Missing or unsafe $label: $path"
}

require_source() {
    local source="$1"
    local relative

    [[ -d "$source" && ! -L "$source" ]] || fail "Missing or unsafe Boost source: $source"
    for relative in "${BOOST_PATCHED_FILES[@]}"; do
        require_file "$source/$relative" "Boost source file"
    done
}

require_patches() {
    local patch
    (( ${#BOOST_PATCH_TREES[@]} == ${#BOOST_PATCHES[@]} + 1 )) \
        || fail "Boost patch-stage manifest is inconsistent"
    for patch in "${BOOST_PATCHES[@]}"; do
        require_file "$patch" "Boost patch"
    done
}

worktree_tree() {
    local source="$1"
    local relative

    require_source "$source"
    for relative in "${BOOST_PATCHED_FILES[@]}"; do
        printf '%s=%s\n' \
            "$relative" \
            "$(shasum -a 256 "$source/$relative" | awk '{print $1}')"
    done | shasum -a 256 | awk '{print $1}'
}

verify_source() {
    local source="$1"
    local actual

    require_patches
    actual="$(worktree_tree "$source")"
    [[ "$actual" == "$BOOST_PATCHED_TREE" ]] \
        || fail "Boost source does not match the ordered patch series"
}

patch_stage() {
    local source="$1"
    local actual
    local index

    actual="$(worktree_tree "$source")"
    for ((index = 0; index < ${#BOOST_PATCH_TREES[@]}; index++)); do
        if [[ "$actual" == "${BOOST_PATCH_TREES[$index]}" ]]; then
            echo "$index"
            return
        fi
    done
    return 1
}

validate_series() (
    local source="$1"
    local start_index="$2"
    local temporary_directory
    local relative
    local index
    local actual

    temporary_directory="$(mktemp -d)"
    trap 'rm -rf "$temporary_directory"' EXIT
    for relative in "${BOOST_PATCHED_FILES[@]}"; do
        mkdir -p "$temporary_directory/${relative%/*}"
        cp "$source/$relative" "$temporary_directory/$relative"
    done
    for ((index = start_index; index < ${#BOOST_PATCHES[@]}; index++)); do
        apply_boost_patch "$temporary_directory" "${BOOST_PATCHES[$index]}" check
        apply_boost_patch "$temporary_directory" "${BOOST_PATCHES[$index]}"
    done
    actual="$(worktree_tree "$temporary_directory")"
    [[ "$actual" == "$BOOST_PATCHED_TREE" ]] \
        || fail "Boost patch series does not produce the pinned patched tree"
)

apply_boost_patch() {
    local source="$1"
    local patch="$2"
    local mode="${3:-apply}"
    local physical_source
    local source_parent
    local -a arguments=(--whitespace=error-all)

    physical_source="$(cd "$source" && pwd -P)"
    source_parent="$(dirname "$physical_source")"
    if [[ "$mode" == "check" ]]; then
        arguments=(--check "${arguments[@]}")
    elif [[ "$mode" != "apply" ]]; then
        fail "Unknown Boost patch operation: $mode"
    fi

    # Boost is normally extracted below the project's ignored .build tree.
    # Prevent Git from discovering that enclosing repository, otherwise
    # git-apply silently skips the ignored dependency headers.
    GIT_CEILING_DIRECTORIES="$source_parent" \
        git -C "$physical_source" apply "${arguments[@]}" "$patch"
}

apply_patches() {
    local source="$1"
    local stage
    local index

    require_source "$source"
    require_patches
    stage="$(patch_stage "$source")" \
        || fail "Could not apply Boost patch series to source with unexpected local changes"
    if (( stage == ${#BOOST_PATCHES[@]} )); then
        return
    fi

    # Validate every remaining patch against the exact recognized stage before
    # changing the shared header cache.
    validate_series "$source" "$stage"
    for ((index = stage; index < ${#BOOST_PATCHES[@]}; index++)); do
        apply_boost_patch "$source" "${BOOST_PATCHES[$index]}" check
        apply_boost_patch "$source" "${BOOST_PATCHES[$index]}"
    done
    verify_source "$source"
}

print_manifest() {
    local source="$1"
    local patch
    local index=0

    verify_source "$source"
    echo "boost-version=$BOOST_VERSION"
    echo "boost-patch-count=${#BOOST_PATCHES[@]}"
    for patch in "${BOOST_PATCHES[@]}"; do
        index=$((index + 1))
        echo "boost-patch-$index=${patch##*/}"
        echo "boost-patch-$index-sha256=$(shasum -a 256 "$patch" | awk '{print $1}')"
    done
    echo "boost-patched-files-tree=$BOOST_PATCHED_TREE"
}

usage() {
    echo "Usage: ${0##*/} {apply|base-tree|can-apply|expected-tree|manifest|verify|version|worktree-tree} [boost-source]" >&2
    exit 64
}

command_name="${1:-}"
case "$command_name" in
    base-tree)
        [[ $# -eq 1 ]] || usage
        echo "$BOOST_BASE_TREE"
        ;;
    expected-tree)
        [[ $# -eq 1 ]] || usage
        echo "$BOOST_PATCHED_TREE"
        ;;
    version)
        [[ $# -eq 1 ]] || usage
        echo "$BOOST_VERSION"
        ;;
    apply|can-apply|manifest|verify|worktree-tree)
        [[ $# -eq 2 ]] || usage
        case "$command_name" in
            apply) apply_patches "$2" ;;
            can-apply) patch_stage "$2" >/dev/null ;;
            manifest) print_manifest "$2" ;;
            verify) verify_source "$2" ;;
            worktree-tree) worktree_tree "$2" ;;
        esac
        ;;
    *)
        usage
        ;;
esac
