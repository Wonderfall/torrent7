#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

fail() {
    print -ru2 -- "$1"
    exit 1
}

typeset -r expected_xcode_version="27.0"
typeset -r expected_xcode_build="27A266a"
typeset -r expected_macos_sdk="27.0"
typeset -r expected_swift_version="Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)"
typeset -r actual_macos_version=$(/usr/bin/sw_vers -productVersion)
autoload -Uz is-at-least
is-at-least 27.0 "$actual_macos_version" \
    || fail "Expected macOS 27 or later, got $actual_macos_version"
[[ $(/usr/bin/uname -m) == arm64 ]] \
    || fail "Run the toolchain natively on Apple silicon"
[[ ${MACOSX_DEPLOYMENT_TARGET:-27.0} == 27.0 ]] \
    || fail "MACOSX_DEPLOYMENT_TARGET must be 27.0"
typeset -r expected_xcode_output=$(
    print -r -- "Xcode $expected_xcode_version"
    print -r -- "Build version $expected_xcode_build"
)
typeset -r actual_xcode_output=$(/usr/bin/xcrun xcodebuild -version)
typeset -r actual_macos_sdk=$(
    /usr/bin/xcrun --sdk macosx --show-sdk-version
)
typeset -r actual_swift_output=$(/usr/bin/xcrun swift --version)

[[ $actual_xcode_output == "$expected_xcode_output" ]] \
    || fail "Expected Xcode $expected_xcode_version ($expected_xcode_build), got:\n$actual_xcode_output"
[[ $actual_macos_sdk == "$expected_macos_sdk" ]] \
    || fail "Expected macOS SDK $expected_macos_sdk, got $actual_macos_sdk"
[[ $actual_swift_output == *"$expected_swift_version"$'\n'* ]] \
    || fail "Expected $expected_swift_version, got:\n$actual_swift_output"

print -r -- "$actual_xcode_output"
print -r -- "macOS SDK $actual_macos_sdk"
print -r -- "$actual_swift_output"
