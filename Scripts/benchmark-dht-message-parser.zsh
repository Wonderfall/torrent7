#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}

if [[ -n ${SANITIZER_PROFILE:-} ]]; then
    print -u2 -- "DHT parser timings must use the hardened release build, not a sanitizer profile."
    exit 2
fi

cd -- "$root_dir"

export LC_ALL=C
export LANG=C
export TORRENT7_NATIVE_DEPS_BUILD_ID=$("$root_dir/Scripts/native-deps-build-id.zsh")

print -- "DHT message callback benchmark (release; timings are diagnostic, not test assertions)"
print -- "machine_model=$(sysctl -n hw.model)"
print -- "physical_memory_bytes=$(sysctl -n hw.memsize)"
print -- "system_version=$(sw_vers -productVersion)"

swift run \
    --scratch-path "$root_dir/.build/dht-message-benchmark" \
    --configuration release \
    --triple arm64e-apple-macosx26.0 \
    DHTMessageParserBenchmark
