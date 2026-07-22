#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}

print -- "Building regular app"
SANITIZER_PROFILE= "$root_dir/Scripts/build-app.zsh"

print -- "Building AddressSanitizer app"
SANITIZER_PROFILE=address "$root_dir/Scripts/build-app.zsh"

print -- "Building ThreadSanitizer app"
SANITIZER_PROFILE=thread "$root_dir/Scripts/build-app.zsh"
