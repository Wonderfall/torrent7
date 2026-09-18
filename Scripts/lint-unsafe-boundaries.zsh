#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
"$root_dir/Scripts/verify-xcode.zsh"
typeset -r package_dir="$root_dir/Tools/UnsafeBoundaryLint"
typeset -r scratch_path=${UNSAFE_BOUNDARY_LINT_SCRATCH_PATH:-"$root_dir/.build/unsafe-boundary-lint"}
typeset -r configuration=${CONFIGURATION:-debug}
typeset -a swift_files

cd -- "$root_dir"

while IFS= read -r -d $'\0' swift_file; do
    if [[ -L $swift_file ]]; then
        print -ru2 -- "Refusing to lint a linked Swift source: $swift_file"
        exit 1
    fi
    [[ -f $swift_file ]] && swift_files+=("$swift_file")
done < <(
    git ls-files -z --cached --others --exclude-standard -- '*.swift'
)

(( ${#swift_files} > 0 )) || {
    print -ru2 -- "No repository-owned Swift files were found"
    exit 1
}

/usr/bin/xcrun swift run \
    --package-path "$package_dir" \
    --scratch-path "$scratch_path" \
    --configuration "$configuration" \
    --only-use-versions-from-resolved-file \
    unsafe-boundary-lint \
    "${swift_files[@]}"
