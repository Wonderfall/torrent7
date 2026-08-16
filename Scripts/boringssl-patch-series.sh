#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

readonly BORINGSSL_COMMIT="b0760837957bf86bd2014d258a948ee76f43c83f"
readonly -a BORINGSSL_PATCHES=(
    "$ROOT_DIR/Scripts/patches/boringssl-active-pointer-hardening.patch"
    "$ROOT_DIR/Scripts/patches/boringssl-typed-allocation.patch"
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

require_checkout() {
    local source="$1"
    [[ -d "$source/.git" || -f "$source/.git" ]] \
        || fail "Missing BoringSSL Git checkout: $source"

    local top_level
    top_level="$(git -C "$source" rev-parse --show-toplevel 2>/dev/null)" \
        || fail "Invalid BoringSSL Git checkout: $source"
    [[ "$(cd "$top_level" && pwd -P)" == "$(cd "$source" && pwd -P)" ]] \
        || fail "BoringSSL source is not a standalone checkout: $source"
}

require_patches() {
    local patch
    for patch in "${BORINGSSL_PATCHES[@]}"; do
        require_file "$patch" "BoringSSL patch"
    done
}

expected_tree() (
    local source="$1"
    local patch_count="${2:-${#BORINGSSL_PATCHES[@]}}"
    local patch
    local index
    local temporary_directory
    temporary_directory="$(mktemp -d)"
    export GIT_INDEX_FILE="$temporary_directory/index"
    trap 'rm -rf "$temporary_directory"' EXIT

    require_checkout "$source"
    require_patches
    git -C "$source" read-tree "$BORINGSSL_COMMIT"
    for ((index = 0; index < patch_count; index++)); do
        patch="${BORINGSSL_PATCHES[$index]}"
        git -C "$source" apply --cached --whitespace=error-all "$patch"
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
    git -C "$source" read-tree "$BORINGSSL_COMMIT"
    git -C "$source" add --all
    git -C "$source" write-tree
)

patch_prefix_count() {
    local source="$1"
    local actual
    local expected
    local count
    actual="$(worktree_tree "$source")"

    for ((count = ${#BORINGSSL_PATCHES[@]}; count >= 0; count--)); do
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
    local current_commit
    local expected
    local actual

    require_checkout "$source"
    require_patches
    current_commit="$(git -C "$source" rev-parse HEAD)"
    [[ "$current_commit" == "$BORINGSSL_COMMIT" ]] \
        || fail "BoringSSL checkout mismatch: expected $BORINGSSL_COMMIT, got $current_commit"
    expected="$(expected_tree "$source")"
    actual="$(worktree_tree "$source")"
    [[ "$actual" == "$expected" ]] \
        || fail "BoringSSL checkout does not match the ordered patch series"
}

apply_patches() {
    local source="$1"
    local patch
    local index
    local current_commit
    local applied_count

    require_checkout "$source"
    require_patches
    current_commit="$(git -C "$source" rev-parse HEAD)"
    [[ "$current_commit" == "$BORINGSSL_COMMIT" ]] \
        || fail "BoringSSL checkout mismatch: expected $BORINGSSL_COMMIT, got $current_commit"

    applied_count="$(patch_prefix_count "$source")" \
        || fail "Could not apply BoringSSL patches to a checkout with unexpected local changes"
    if [[ "$applied_count" -eq "${#BORINGSSL_PATCHES[@]}" ]]; then
        return
    fi

    # Replay every remaining patch in a temporary index before modifying the
    # build worktree. A malformed later patch cannot leave a partial series.
    expected_tree "$source" >/dev/null
    for ((index = applied_count; index < ${#BORINGSSL_PATCHES[@]}; index++)); do
        patch="${BORINGSSL_PATCHES[$index]}"
        git -C "$source" apply --check --whitespace=error-all "$patch" \
            || fail "Could not apply BoringSSL patch: $patch"
        git -C "$source" apply --whitespace=error-all "$patch"
    done
    verify_checkout "$source"
}

print_manifest() {
    local source="$1"
    local patch
    local index=0

    verify_checkout "$source"
    echo "boringssl-commit=$BORINGSSL_COMMIT"
    echo "boringssl-patch-count=${#BORINGSSL_PATCHES[@]}"
    for patch in "${BORINGSSL_PATCHES[@]}"; do
        index=$((index + 1))
        echo "boringssl-patch-$index=${patch##*/}"
        echo "boringssl-patch-$index-sha256=$(shasum -a 256 "$patch" | awk '{print $1}')"
    done
    echo "boringssl-patched-tree=$(expected_tree "$source")"
}

usage() {
    echo "Usage: ${0##*/} {apply|commit|expected-tree|manifest|verify|worktree-tree} [boringssl-source]" >&2
    exit 64
}

command_name="${1:-}"
case "$command_name" in
    commit)
        [[ $# -eq 1 ]] || usage
        echo "$BORINGSSL_COMMIT"
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
