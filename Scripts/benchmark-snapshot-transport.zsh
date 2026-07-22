#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}

if [[ -n ${SANITIZER_PROFILE:-} ]]; then
    print -u2 -- "Snapshot transport timings must use the hardened release build, not a sanitizer profile."
    exit 2
fi

cd -- "$root_dir"

export CONFIGURATION=release
export RUN_SNAPSHOT_TRANSPORT_BENCHMARK=1
export LC_ALL=C
export LANG=C

print -- "Snapshot transport benchmark (release; timings are diagnostic, not test assertions)"
print -- "machine_model=$(sysctl -n hw.model)"
print -- "physical_memory_bytes=$(sysctl -n hw.memsize)"
print -- "system_version=$(sw_vers -productVersion)"

"$root_dir/Scripts/test-bridge.zsh" \
    '--test-case=maximum snapshot batch copy benchmark is opt-in'
"$root_dir/Scripts/test-swift.zsh" \
    --filter SnapshotTransportBenchmarkTests
