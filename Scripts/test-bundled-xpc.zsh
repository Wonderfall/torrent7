#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
typeset -r build_dir="$root_dir/.build"
typeset -r swift_build_dir=${SWIFT_BUILD_DIR:-$build_dir}
typeset -r output_dir=${BUNDLED_XPC_OUTPUT_DIR:-$build_dir/BundledXPCIntegration}
typeset -r configuration=release
typeset -r host_bundle_id=app.torrent7.integration
typeset -r service_bundle_id=app.torrent7.integration.engine
typeset -r host_app="$output_dir/TorrentEngineXPCIntegration.app"
typeset -r host_contents="$host_app/Contents"
typeset -r host_executable="$host_contents/MacOS/TorrentEngineXPCIntegrationHost"
typeset -r service_bundle="$host_contents/XPCServices/$service_bundle_id.xpc"
typeset -r service_contents="$service_bundle/Contents"
typeset -r service_executable="$service_contents/MacOS/TorrentEngineService"
typeset -r host_info="$root_dir/Packaging/Integration/TorrentEngineXPCIntegrationHost-Info.plist"
typeset -r service_info="$root_dir/Packaging/Integration/TorrentEngineXPCIntegrationService-Info.plist"
typeset -r host_entitlements="$root_dir/Packaging/Torrent7.entitlements"
typeset -r service_entitlements="$root_dir/Packaging/Torrent7Engine.entitlements"
typeset -r sign_options=runtime,restrict,library
typeset torrent_count=${BUNDLED_XPC_TORRENT_COUNT:-512}
typeset timeout_seconds=${BUNDLED_XPC_TIMEOUT_SECONDS:-600}
typeset -r host_output="$output_dir/host-output.log"
typeset -r host_stderr="$output_dir/host-stderr.log"
typeset -r memory_output="$output_dir/memory.log"
typeset -r timeout_marker="$output_dir/timeout.marker"
typeset -r powerbox_root="$output_dir/PowerboxRoot"
typeset -r user_temp_dir=${TMPDIR:-/tmp}
typeset -r invocation_lock="${user_temp_dir%/}/$host_bundle_id.test-bundled-xpc.lock"
typeset mode=interactive

fail() {
    print -ru2 -- "$1"
    exit 1
}

if [[ ${SANITIZER_DIAGNOSTICS:-0} == "1" ]]; then
    fail "Bundled XPC timings require the hardened release build, not sanitizer diagnostics."
fi

case $# in
    0)
        ;;
    1)
        case $1 in
            --build-only)
                mode=build-only
                ;;
            --automated)
                mode=automated
                torrent_count=0
                ;;
            --maximum)
                mode=maximum
                torrent_count=20000
                timeout_seconds=${BUNDLED_XPC_TIMEOUT_SECONDS:-3600}
                ;;
            *)
                fail "Usage: Scripts/test-bundled-xpc.zsh [--automated|--build-only|--maximum]"
                ;;
        esac
        ;;
    *)
        fail "Usage: Scripts/test-bundled-xpc.zsh [--automated|--build-only|--maximum]"
        ;;
esac

[[ $torrent_count == <-> ]] || fail "BUNDLED_XPC_TORRENT_COUNT must be an integer"
if [[ $mode == automated ]]; then
    (( torrent_count == 0 )) || fail "Automated integration must use an empty dataset"
else
    (( torrent_count >= 1 && torrent_count <= 20000 )) \
        || fail "BUNDLED_XPC_TORRENT_COUNT must be between 1 and 20000"
fi
[[ $timeout_seconds == <-> ]] || fail "BUNDLED_XPC_TIMEOUT_SECONDS must be an integer"
(( timeout_seconds >= 30 )) || fail "BUNDLED_XPC_TIMEOUT_SECONDS must be at least 30"
[[ $swift_build_dir == /* ]] || fail "SWIFT_BUILD_DIR must be an absolute path"
[[ $output_dir == /* ]] || fail "BUNDLED_XPC_OUTPUT_DIR must be an absolute path"

typeset -a integration_containers=(
    "$HOME/Library/Containers/$host_bundle_id"
    "$HOME/Library/Containers/$service_bundle_id"
)
typeset host_pid=0
typeset launcher_pid=0
typeset watchdog_pid=0
typeset sampler_pid=0
typeset owns_test_state=0
typeset owns_invocation_lock=0
typeset cleanup_started=0

exact_process_pids() {
    local executable=$1
    /bin/ps -ww -axo pid=,command= \
        | /usr/bin/awk -v executable="$executable" '
            {
                pid = $1
                command = $0
                sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", command)
                if (command == executable || index(command, executable " ") == 1) {
                    print pid
                }
            }
        '
}

preflight_exact_processes() {
    local executable
    local pids
    for executable in "$host_executable" "$service_executable"; do
        pids=$(exact_process_pids "$executable")
        [[ -z $pids ]] \
            || fail "An integration process using $executable is already running"
    done
}

cleanup_test_state() {
    local directory
    for directory in "${integration_containers[@]}"; do
        case ${directory:t} in
            $host_bundle_id|$service_bundle_id)
                /bin/rm -rf -- "$directory"
                ;;
            *)
                fail "Refusing to remove an unexpected integration container"
                ;;
        esac
    done
    case $powerbox_root in
        "$output_dir/PowerboxRoot")
            /bin/rm -rf -- "$powerbox_root"
            ;;
        *)
            fail "Refusing to remove an unexpected Powerbox test root"
            ;;
    esac
}

pid_matches_exact_executable() {
    local pid=$1
    local executable=$2
    /bin/ps -ww -o command= -p "$pid" 2>/dev/null \
        | /usr/bin/awk -v executable="$executable" '
            {
                command = $0
                sub(/^[[:space:]]+/, "", command)
                if (command == executable || index(command, executable " ") == 1) {
                    matched = 1
                }
            }
            END { exit matched ? 0 : 1 }
        '
}

terminate_exact_pid() {
    local pid=$1
    local executable=$2
    (( pid > 0 )) || return 0
    pid_matches_exact_executable "$pid" "$executable" || return 0
    if ! kill -TERM "$pid" 2>/dev/null; then
        if pid_matches_exact_executable "$pid" "$executable"; then
            return 1
        fi
        return 0
    fi
    local attempt
    for attempt in {1..20}; do
        pid_matches_exact_executable "$pid" "$executable" || return 0
        sleep 0.05
    done
    pid_matches_exact_executable "$pid" "$executable" || return 0
    if ! kill -KILL "$pid" 2>/dev/null; then
        if pid_matches_exact_executable "$pid" "$executable"; then
            return 1
        fi
        return 0
    fi
    for attempt in {1..20}; do
        pid_matches_exact_executable "$pid" "$executable" || return 0
        sleep 0.05
    done
    return 1
}

terminate_exact_executable() {
    local executable=$1
    local -a pids=(${(f)"$(exact_process_pids "$executable")"})
    local pid
    local termination_status=0
    for pid in "${pids[@]}"; do
        terminate_exact_pid "$pid" "$executable" || termination_status=1
    done
    return $termination_status
}

cleanup() {
    (( cleanup_started == 0 )) || return 0
    cleanup_started=1
    local safe_to_remove_state=1
    if (( watchdog_pid > 0 )); then
        kill -TERM "$watchdog_pid" 2>/dev/null || true
    fi
    if (( sampler_pid > 0 )); then
        kill -TERM "$sampler_pid" 2>/dev/null || true
    fi
    if (( launcher_pid > 0 )); then
        kill -TERM "$launcher_pid" 2>/dev/null || true
        wait "$launcher_pid" 2>/dev/null || true
    fi
    if (( owns_test_state == 1 )); then
        terminate_exact_executable "$host_executable" \
            || safe_to_remove_state=0
        terminate_exact_executable "$service_executable" \
            || safe_to_remove_state=0
        if (( safe_to_remove_state == 1 )); then
            cleanup_test_state
        else
            print -ru2 -- "Integration processes did not terminate; preserving their containers and Powerbox root"
        fi
    fi
    if (( owns_invocation_lock == 1 )); then
        if (( safe_to_remove_state == 1 )); then
            /bin/rmdir -- "$invocation_lock" 2>/dev/null || true
        else
            print -ru2 -- "Retaining integration lock $invocation_lock until the processes are resolved"
        fi
    fi
}

handle_signal() {
    local exit_status=$1
    trap - INT TERM HUP
    cleanup
    trap - EXIT
    exit "$exit_status"
}

/bin/mkdir -- "$invocation_lock" 2>/dev/null \
    || fail "Another bundled XPC integration invocation is active (or left the stale lock $invocation_lock)"
owns_invocation_lock=1
trap cleanup EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM
trap 'handle_signal 129' HUP
preflight_exact_processes

/bin/mkdir -p -- "$output_dir"

cd -- "$root_dir"
export CC="$(/usr/bin/xcrun --find clang)"
export CXX="$(/usr/bin/xcrun --find clang++)"
export LC_ALL=C
export LANG=C

if [[ ${SKIP_BUILD_DEPS:-0} != "1" ]]; then
    "$root_dir/Scripts/build-deps.zsh"
fi

typeset -a swift_build_args=(
    --scratch-path "$swift_build_dir"
    --configuration "$configuration"
    --triple arm64e-apple-macosx26.0
)
/usr/bin/swift build "${swift_build_args[@]}" --product TorrentEngineXPCIntegrationHost
/usr/bin/swift build "${swift_build_args[@]}" --product TorrentEngineService

/bin/rm -rf -- "$host_app"
/bin/mkdir -p -- "${host_executable:h}" "${service_executable:h}"
/bin/cp \
    "$swift_build_dir/arm64e-apple-macosx/$configuration/TorrentEngineXPCIntegrationHost" \
    "$host_executable"
/bin/cp \
    "$swift_build_dir/arm64e-apple-macosx/$configuration/TorrentEngineService" \
    "$service_executable"
/bin/cp "$host_info" "$host_contents/Info.plist"
/bin/cp "$service_info" "$service_contents/Info.plist"
/usr/bin/plutil -lint "$host_contents/Info.plist" "$service_contents/Info.plist" >/dev/null

/usr/bin/codesign \
    --force \
    --sign - \
    --options "$sign_options" \
    --entitlements "$service_entitlements" \
    --timestamp=none \
    "$service_bundle"
/usr/bin/codesign \
    --force \
    --sign - \
    --options "$sign_options" \
    --entitlements "$host_entitlements" \
    --timestamp=none \
    "$host_app"
/usr/bin/codesign --verify --strict --verbose=2 "$service_bundle"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$host_app"

preflight_exact_processes
owns_test_state=1
cleanup_test_state

if [[ $mode == build-only ]]; then
    print -- "Bundled XPC integration fixture assembled and signature-verified"
    exit 0
fi

typeset -a host_arguments
typeset canonical_powerbox_root=""
if [[ $mode == automated ]]; then
    host_arguments=(--automated)
else
    /bin/mkdir -p -- "$powerbox_root"
    canonical_powerbox_root=${powerbox_root:A}
    host_arguments=(
        --count "$torrent_count"
        --download-root "$canonical_powerbox_root"
    )
fi

print -- "Bundled XPC integration (ad-hoc release bundle; ContinuousClock timings)"
print -- "machine_model=$(sysctl -n hw.model)"
print -- "physical_memory_bytes=$(sysctl -n hw.memsize)"
print -- "system_version=$(sw_vers -productVersion)"
print -- "mode=$mode"
print -- "torrent_count=$torrent_count"
print -- "timeout_seconds=$timeout_seconds"
if [[ $mode != automated ]]; then
    print -- "powerbox_root=$canonical_powerbox_root"
    print -- "Approve that exact folder in the system Open panel to begin the integration run."
fi

/bin/rm -f -- "$host_output" "$host_stderr" "$memory_output" "$timeout_marker"
/usr/bin/open \
    -n \
    -W \
    --stdout "$host_output" \
    --stderr "$host_stderr" \
    "$host_app" \
    --args \
    "${host_arguments[@]}" &
launcher_pid=$!

typeset -a discovered_host_pids=()
typeset attempt
for attempt in {1..100}; do
    discovered_host_pids=(${(f)"$(exact_process_pids "$host_executable")"})
    (( ${#discovered_host_pids[@]} <= 1 )) \
        || fail "LaunchServices started more than one exact integration host"
    if (( ${#discovered_host_pids[@]} == 1 )); then
        host_pid=$discovered_host_pids[1]
        break
    fi
    kill -0 "$launcher_pid" 2>/dev/null \
        || fail "LaunchServices exited before starting the integration host"
    sleep 0.1
done
(( host_pid > 0 )) || fail "Could not locate the exact integration host executable"
(
    typeset host_peak_rss_kib=0
    typeset service_peak_rss_kib=0
    typeset service_was_observed=0
    while pid_matches_exact_executable "$host_pid" "$host_executable"; do
        typeset host_rss_kib=$(
            /bin/ps -o rss= -p "$host_pid" 2>/dev/null \
                | /usr/bin/awk 'NR == 1 { print $1 + 0 }' \
                || print 0
        )
        typeset service_sample=$(
            /bin/ps -ww -axo pid=,rss=,command= \
                | /usr/bin/awk -v executable="$service_executable" '
                    {
                        rss = $2
                        command = $0
                        sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", command)
                        if (command == executable || index(command, executable " ") == 1) {
                            total += rss
                            observed = 1
                        }
                    }
                    END { print total + 0, observed + 0 }
                '
        )
        typeset service_rss_kib=${service_sample%% *}
        typeset service_observed=${service_sample##* }
        (( host_rss_kib > host_peak_rss_kib )) \
            && host_peak_rss_kib=$host_rss_kib
        (( service_rss_kib > service_peak_rss_kib )) \
            && service_peak_rss_kib=$service_rss_kib
        (( service_observed == 1 )) && service_was_observed=1
        sleep 0.1
    done
    print -- "memory.sampling_interval_seconds=0.1"
    print -- "memory.host.sampled_peak_rss_kib=$host_peak_rss_kib"
    print -- "memory.service.sampled_peak_rss_kib=$service_peak_rss_kib"
    print -- "memory.service.observed=$service_was_observed"
) >"$memory_output" &
sampler_pid=$!
(
    sleep "$timeout_seconds"
    pid_matches_exact_executable "$host_pid" "$host_executable" || exit 0
    print -- "timeout" >"$timeout_marker"
    print -ru2 -- "Bundled XPC integration exceeded its $timeout_seconds-second hard timeout"
    kill -ALRM "$host_pid" 2>/dev/null || exit 0
    sleep 5
    pid_matches_exact_executable "$host_pid" "$host_executable" \
        && kill -KILL "$host_pid" 2>/dev/null || true
) &
watchdog_pid=$!

typeset launcher_status=0
if wait "$launcher_pid"; then
    launcher_status=0
else
    launcher_status=$?
fi
launcher_pid=0
kill -TERM "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=0
wait "$sampler_pid" 2>/dev/null || true
sampler_pid=0
host_pid=0

/bin/cat "$host_output"
/bin/cat "$host_stderr"
/bin/cat "$memory_output"

[[ ! -e $timeout_marker ]] || fail "Bundled XPC integration timed out"
(( launcher_status == 0 )) \
    || fail "LaunchServices integration wait failed with status $launcher_status"
/usr/bin/grep -qx 'integration.result=pass' "$host_output" \
    || fail "Bundled XPC integration exited without a pass marker"
/usr/bin/grep -qx 'memory.service.observed=1' "$memory_output" \
    || fail "Bundled XPC integration never observed the exact service executable"
