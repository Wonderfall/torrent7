#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

readonly LIBTORRENT_COMMIT="578e06824c3546f3371ab43967ab288a7e253eca"
readonly -a LIBTORRENT_PATCHES=(
    "$ROOT_DIR/Scripts/patches/libtorrent-2.1.0-xcode-26.patch"
    "$ROOT_DIR/Scripts/patches/libtorrent-2.1.0-network-security.patch"
    "$ROOT_DIR/Scripts/patches/libtorrent-2.1.0-storage-confinement.patch"
    "$ROOT_DIR/Scripts/patches/libtorrent-2.1.0-tracker-endpoint-security.patch"
    "$ROOT_DIR/Scripts/patches/libtorrent-2.1.0-root-authority.patch"
)

fail() {
    echo "$1" >&2
    exit 1
}

require_file() {
    local path="$1"
    local label="$2"
    [[ -f "$path" ]] || fail "Missing $label: $path"
}

require_checkout() {
    local source="$1"
    [[ -d "$source/.git" ]] || fail "Missing libtorrent Git checkout: $source"

    local top_level
    top_level="$(git -C "$source" rev-parse --show-toplevel 2>/dev/null)" \
        || fail "Invalid libtorrent Git checkout: $source"
    [[ "$(cd "$top_level" && pwd -P)" == "$(cd "$source" && pwd -P)" ]] \
        || fail "libtorrent source is not a standalone checkout: $source"
}

require_patches() {
    local patch
    for patch in "${LIBTORRENT_PATCHES[@]}"; do
        require_file "$patch" "libtorrent patch"
    done
}

expected_tree() (
    local source="$1"
    local patch_count="${2:-${#LIBTORRENT_PATCHES[@]}}"
    local patch
    local index
    local temporary_directory
    temporary_directory="$(mktemp -d)"
    export GIT_INDEX_FILE="$temporary_directory/index"
    trap 'rm -rf "$temporary_directory"' EXIT

    require_checkout "$source"
    require_patches
    git -C "$source" read-tree "$LIBTORRENT_COMMIT"
    for ((index = 0; index < patch_count; index++)); do
        patch="${LIBTORRENT_PATCHES[$index]}"
        git -C "$source" apply --cached "$patch"
    done
    git -C "$source" write-tree
)

worktree_tree() (
    local source="$1"
    local temporary_directory
    temporary_directory="$(mktemp -d)"
    export GIT_INDEX_FILE="$temporary_directory/index"
    trap 'rm -rf "$temporary_directory"' EXIT

    require_checkout "$source"
    git -C "$source" read-tree "$LIBTORRENT_COMMIT"
    git -C "$source" add --all
    git -C "$source" write-tree
)

checkout_matches() {
    local source="$1"
    local current_commit
    current_commit="$(git -C "$source" rev-parse HEAD)"
    [[ "$current_commit" == "$LIBTORRENT_COMMIT" ]] || return 1

    local expected
    local actual
    expected="$(expected_tree "$source")"
    actual="$(worktree_tree "$source")"
    [[ "$actual" == "$expected" ]]
}

patch_prefix_count() {
    local source="$1"
    local actual
    local expected
    local count
    actual="$(worktree_tree "$source")"

    for ((count = ${#LIBTORRENT_PATCHES[@]}; count >= 0; count--)); do
        expected="$(expected_tree "$source" "$count")"
        if [[ "$actual" == "$expected" ]]; then
            echo "$count"
            return
        fi
    done
    return 1
}

verify_checkout() {
    local source="$1"
    require_checkout "$source"
    require_patches

    local current_commit
    current_commit="$(git -C "$source" rev-parse HEAD)"
    [[ "$current_commit" == "$LIBTORRENT_COMMIT" ]] \
        || fail "libtorrent checkout mismatch: expected $LIBTORRENT_COMMIT, got $current_commit"
    checkout_matches "$source" \
        || fail "libtorrent checkout does not match the ordered patch series"
}

apply_patches() {
    local source="$1"
    local patch
    local index
    require_checkout "$source"
    require_patches

    local current_commit
    current_commit="$(git -C "$source" rev-parse HEAD)"
    [[ "$current_commit" == "$LIBTORRENT_COMMIT" ]] \
        || fail "libtorrent checkout mismatch: expected $LIBTORRENT_COMMIT, got $current_commit"

    local applied_count
    if ! applied_count="$(patch_prefix_count "$source")"; then
        fail "Could not apply libtorrent patch series to a checkout with unexpected local changes"
    fi
    if [[ "$applied_count" -eq "${#LIBTORRENT_PATCHES[@]}" ]]; then
        return
    fi

    # Validate the complete ordered series against the pinned base before
    # changing the checkout, so a malformed later patch cannot leave a partial
    # application behind.
    expected_tree "$source" >/dev/null
    for ((index = applied_count; index < ${#LIBTORRENT_PATCHES[@]}; index++)); do
        patch="${LIBTORRENT_PATCHES[$index]}"
        git -C "$source" apply --check "$patch" \
            || fail "Could not apply libtorrent patch: $patch"
        git -C "$source" apply "$patch"
    done
    verify_checkout "$source"
}

print_manifest() {
    local source="$1"
    local patch
    local index=0
    require_checkout "$source"
    require_patches

    echo "libtorrent-commit=$LIBTORRENT_COMMIT"
    echo "libtorrent-patch-count=${#LIBTORRENT_PATCHES[@]}"
    for patch in "${LIBTORRENT_PATCHES[@]}"; do
        index=$((index + 1))
        echo "libtorrent-patch-$index=${patch##*/}"
        echo "libtorrent-patch-$index-sha256=$(shasum -a 256 "$patch" | awk '{print $1}')"
    done
    echo "libtorrent-patched-tree=$(expected_tree "$source")"
}

usage() {
    echo "Usage: ${0##*/} {apply|commit|expected-tree|manifest|verify|worktree-tree} [libtorrent-source]" >&2
    exit 64
}

command_name="${1:-}"
case "$command_name" in
    commit)
        [[ $# -eq 1 ]] || usage
        echo "$LIBTORRENT_COMMIT"
        ;;
    apply|expected-tree|manifest|verify|worktree-tree)
        [[ $# -eq 2 ]] || usage
        case "$command_name" in
            apply) apply_patches "$2" ;;
            expected-tree) expected_tree "$2" ;;
            manifest) print_manifest "$2" ;;
            verify) verify_checkout "$2" ;;
            worktree-tree) worktree_tree "$2" ;;
        esac
        ;;
    *)
        usage
        ;;
esac
