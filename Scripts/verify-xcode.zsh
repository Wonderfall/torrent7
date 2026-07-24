#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

fail() {
    print -ru2 -- "$1"
    exit 1
}

typeset -r expected_xcode_version="26.6"
typeset -r expected_xcode_build="17F113"
typeset -r expected_macos_sdk="26.5"
typeset -r expected_xcode_output=$(
    print -r -- "Xcode $expected_xcode_version"
    print -r -- "Build version $expected_xcode_build"
)
typeset -r actual_xcode_output=$(/usr/bin/xcrun xcodebuild -version)
typeset -r actual_macos_sdk=$(
    /usr/bin/xcrun --sdk macosx --show-sdk-version
)

[[ $actual_xcode_output == "$expected_xcode_output" ]] \
    || fail "Expected Xcode $expected_xcode_version ($expected_xcode_build), got:\n$actual_xcode_output"
[[ $actual_macos_sdk == "$expected_macos_sdk" ]] \
    || fail "Expected macOS SDK $expected_macos_sdk, got $actual_macos_sdk"

print -r -- "$actual_xcode_output"
print -r -- "macOS SDK $actual_macos_sdk"
/usr/bin/xcrun swift --version
