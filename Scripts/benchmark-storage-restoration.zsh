#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
if [[ -n ${SANITIZER_PROFILE:-} ]]; then
    print -ru2 -- "Storage restoration timings require an unsanitized release build."
    exit 2
fi

cd -- "$root_dir"
export CONFIGURATION=release
export RUN_STORAGE_RESTORATION_BENCHMARK=1
export LC_ALL=C
export LANG=C

print -- "Storage restoration benchmark (release; diagnostic timings, no latency assertions)"
print -- "source_commit=$(git rev-parse HEAD)"
print -- "cpu=$(sysctl -n machdep.cpu.brand_string)"
print -- "logical_cpus=$(sysctl -n hw.logicalcpu)"
print -- "physical_memory_bytes=$(sysctl -n hw.memsize)"
print -- "system_version=$(sw_vers -productVersion)"
print -- "system_build=$(sw_vers -buildVersion)"

"$root_dir/Scripts/test-swift.zsh" --filter StorageRestorationBenchmarkTests
