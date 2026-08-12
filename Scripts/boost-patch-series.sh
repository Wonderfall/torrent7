#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

readonly BOOST_VERSION="1.91.0"
readonly BOOST_BASE_TREE="5361be71183447ba73da19e42233771725d7a6a4d056e8978f55893355ede04e"
readonly BOOST_PATCHED_TREE="81b71313db567209a1b591dc5b910f54cc6873d8a7b5abafe5c6f369b6e08d3b"
readonly -a BOOST_PATCHED_FILES=(
    "boost/asio/detail/reactor_op.hpp"
    "boost/asio/detail/scheduler_operation.hpp"
)
readonly -a BOOST_PATCHES=(
    "$ROOT_DIR/Scripts/patches/boost-1.91.0-asio-operation-pac.patch"
)

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

validate_series() (
    local source="$1"
    local temporary_directory
    local relative
    local patch
    local actual

    temporary_directory="$(mktemp -d)"
    trap 'rm -rf "$temporary_directory"' EXIT
    for relative in "${BOOST_PATCHED_FILES[@]}"; do
        mkdir -p "$temporary_directory/${relative%/*}"
        cp "$source/$relative" "$temporary_directory/$relative"
    done
    for patch in "${BOOST_PATCHES[@]}"; do
        git -C "$temporary_directory" apply --check --whitespace=error-all "$patch"
        git -C "$temporary_directory" apply --whitespace=error-all "$patch"
    done
    actual="$(worktree_tree "$temporary_directory")"
    [[ "$actual" == "$BOOST_PATCHED_TREE" ]] \
        || fail "Boost patch series does not produce the pinned patched tree"
)

apply_patches() {
    local source="$1"
    local actual
    local patch

    require_source "$source"
    require_patches
    actual="$(worktree_tree "$source")"
    if [[ "$actual" == "$BOOST_PATCHED_TREE" ]]; then
        return
    fi
    [[ "$actual" == "$BOOST_BASE_TREE" ]] \
        || fail "Could not apply Boost patch series to source with unexpected local changes"

    # Validate the complete ordered series against the pinned base before
    # changing the shared header cache.
    validate_series "$source"
    for patch in "${BOOST_PATCHES[@]}"; do
        git -C "$source" apply --check --whitespace=error-all "$patch"
        git -C "$source" apply --whitespace=error-all "$patch"
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
    echo "Usage: ${0##*/} {apply|base-tree|expected-tree|manifest|verify|version|worktree-tree} [boost-source]" >&2
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
    apply|manifest|verify|worktree-tree)
        [[ $# -eq 2 ]] || usage
        case "$command_name" in
            apply) apply_patches "$2" ;;
            manifest) print_manifest "$2" ;;
            verify) verify_source "$2" ;;
            worktree-tree) worktree_tree "$2" ;;
        esac
        ;;
    *)
        usage
        ;;
esac
