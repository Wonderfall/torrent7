#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
typeset -r build_dir="$root_dir/.build"
typeset -r sanitizer_profile=${SANITIZER_PROFILE:-}
typeset torrent_count=${ENHANCED_SECURITY_TORRENT_COUNT:-512}
typeset timeout_seconds=${ENHANCED_SECURITY_TIMEOUT_SECONDS:-600}
typeset mode=interactive
typeset recovery_spawn_attempts=1000

fail() {
    print -ru2 -- "$1"
    exit 1
}

verify_sanitizer_runtime() {
    local -r binary=$1
    local -r dependencies=$(/usr/bin/otool -L "$binary")
    local has_address=false
    local has_thread=false
    [[ $dependencies == *"@rpath/libclang_rt.asan_osx_dynamic.dylib"* ]] \
        && has_address=true
    [[ $dependencies == *"@rpath/libclang_rt.tsan_osx_dynamic.dylib"* ]] \
        && has_thread=true
    case $sanitizer_profile in
        "")
            [[ $has_address == false && $has_thread == false ]] \
                || fail "Production integration binary unexpectedly loads a sanitizer: $binary"
            ;;
        address)
            [[ $has_address == true && $has_thread == false ]] \
                || fail "Integration binary does not load exactly AddressSanitizer: $binary"
            ;;
        thread)
            [[ $has_address == false && $has_thread == true ]] \
                || fail "Integration binary does not load exactly ThreadSanitizer: $binary"
            ;;
    esac
}

case $sanitizer_profile in
    ""|address|thread) ;;
    *) fail "SANITIZER_PROFILE must be address or thread" ;;
esac

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
                timeout_seconds=${ENHANCED_SECURITY_TIMEOUT_SECONDS:-3600}
                ;;
            *)
                fail "Usage: Scripts/test-enhanced-security-extension.zsh [--automated|--build-only|--maximum]"
                ;;
        esac
        ;;
    *)
        fail "Usage: Scripts/test-enhanced-security-extension.zsh [--automated|--build-only|--maximum]"
        ;;
esac

if [[ -n $sanitizer_profile && $mode != automated && $mode != build-only ]]; then
    fail "Sanitizer Enhanced Security runs are correctness-only; use --automated or --build-only"
fi

typeset configuration=release
typeset default_swift_build_dir=$build_dir
typeset default_output_dir="$build_dir/EnhancedSecurityExtensionIntegration"
typeset host_bundle_id=app.torrent7.integration
typeset engine_bundle_id=app.torrent7.integration.engine
typeset extension_point_identifier=app.torrent7.integration.torrent-engine
typeset integration_packaging_dir="$root_dir/Packaging/Integration"
case $sanitizer_profile in
    address)
        configuration=debug
        default_swift_build_dir="$build_dir/swift-enhanced-security-address"
        default_output_dir="$build_dir/EnhancedSecurityExtensionIntegration-Address"
        host_bundle_id=app.torrent7.integration.asan
        engine_bundle_id=app.torrent7.integration.asan.engine
        extension_point_identifier=app.torrent7.integration.asan.torrent-engine
        integration_packaging_dir="$root_dir/Packaging/Integration/Address"
        timeout_seconds=${ENHANCED_SECURITY_TIMEOUT_SECONDS:-1200}
        recovery_spawn_attempts=30000
        ;;
    thread)
        configuration=debug
        default_swift_build_dir="$build_dir/swift-enhanced-security-thread"
        default_output_dir="$build_dir/EnhancedSecurityExtensionIntegration-Thread"
        host_bundle_id=app.torrent7.integration.tsan
        engine_bundle_id=app.torrent7.integration.tsan.engine
        extension_point_identifier=app.torrent7.integration.tsan.torrent-engine
        integration_packaging_dir="$root_dir/Packaging/Integration/Thread"
        timeout_seconds=${ENHANCED_SECURITY_TIMEOUT_SECONDS:-1200}
        recovery_spawn_attempts=30000
        ;;
esac

typeset -r swift_build_dir=${SWIFT_BUILD_DIR:-$default_swift_build_dir}
typeset -r output_dir=${ENHANCED_SECURITY_OUTPUT_DIR:-$default_output_dir}
typeset -r host_app="$output_dir/TorrentEngineXPCIntegration.app"
typeset -r host_contents="$host_app/Contents"
typeset -r host_executable="$host_contents/MacOS/TorrentEngineXPCIntegrationHost"
typeset -r engine_extension="$host_contents/PlugIns/$engine_bundle_id.appex"
typeset -r engine_contents="$engine_extension/Contents"
typeset -r engine_executable="$engine_contents/MacOS/TorrentEngineExtension"
typeset -r extension_point="$host_contents/Extensions/TorrentEngineXPCIntegrationHost.appexpt"
typeset -r host_info="$integration_packaging_dir/TorrentEngineXPCIntegrationHost-Info.plist"
typeset -r engine_info="$integration_packaging_dir/TorrentEngineExtension-Info.plist"
typeset -r extension_point_source="$integration_packaging_dir/TorrentEngineXPCIntegrationHost.appexpt"
typeset -r host_entitlements="$root_dir/Packaging/Torrent7.entitlements"
typeset -r engine_entitlements="$root_dir/Packaging/Torrent7Engine.entitlements"
typeset -r launch_services_register=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
typeset -r sign_options=runtime,restrict,library
typeset -r host_output="$output_dir/host-output.log"
typeset -r host_stderr="$output_dir/host-stderr.log"
typeset -r memory_output="$output_dir/memory.log"
typeset -r recovery_output="$output_dir/recovery.log"
typeset -r timeout_marker="$output_dir/timeout.marker"
typeset -r powerbox_root="$output_dir/PowerboxRoot"
typeset -r user_temp_dir=${TMPDIR:-/tmp}
typeset -r invocation_lock="${user_temp_dir%/}/$host_bundle_id.test-enhanced-security.lock"
typeset -r recovery_marker_dir="$HOME/Library/Containers/$host_bundle_id/Data/Library/Application Support/Torrent7EnhancedSecurityIntegration"
typeset -r recovery_ready_marker="$recovery_marker_dir/ready"
typeset -r recovery_killed_marker="$recovery_marker_dir/killed"

[[ $torrent_count == <-> ]] || fail "ENHANCED_SECURITY_TORRENT_COUNT must be an integer"
if [[ $mode == automated ]]; then
    (( torrent_count == 0 )) || fail "Automated integration must use an empty dataset"
else
    (( torrent_count >= 1 && torrent_count <= 20000 )) \
        || fail "ENHANCED_SECURITY_TORRENT_COUNT must be between 1 and 20000"
fi
[[ $timeout_seconds == <-> ]] || fail "ENHANCED_SECURITY_TIMEOUT_SECONDS must be an integer"
(( timeout_seconds >= 30 )) || fail "ENHANCED_SECURITY_TIMEOUT_SECONDS must be at least 30"
[[ $swift_build_dir == /* ]] || fail "SWIFT_BUILD_DIR must be an absolute path"
[[ $output_dir == /* ]] || fail "ENHANCED_SECURITY_OUTPUT_DIR must be an absolute path"

typeset -a integration_containers=(
    "$HOME/Library/Containers/$host_bundle_id"
    "$HOME/Library/Containers/$engine_bundle_id"
)
typeset host_pid=0
typeset launcher_pid=0
typeset watchdog_pid=0
typeset sampler_pid=0
typeset recovery_coordinator_pid=0
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
    for executable in "$host_executable" "$engine_executable"; do
        pids=$(exact_process_pids "$executable")
        [[ -z $pids ]] \
            || fail "An integration process using $executable is already running"
    done
}

cleanup_test_state() {
    local directory
    for directory in "${integration_containers[@]}"; do
        case ${directory:t} in
            $host_bundle_id|$engine_bundle_id)
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
    if (( recovery_coordinator_pid > 0 )); then
        kill -TERM "$recovery_coordinator_pid" 2>/dev/null || true
        wait "$recovery_coordinator_pid" 2>/dev/null || true
    fi
    if (( launcher_pid > 0 )); then
        kill -TERM "$launcher_pid" 2>/dev/null || true
        wait "$launcher_pid" 2>/dev/null || true
    fi
    if (( owns_test_state == 1 )); then
        terminate_exact_executable "$host_executable" \
            || safe_to_remove_state=0
        terminate_exact_executable "$engine_executable" \
            || safe_to_remove_state=0
        if (( safe_to_remove_state == 1 )); then
            cleanup_test_state
        else
            print -ru2 -- "Integration processes did not terminate; preserving their containers and Powerbox root"
        fi
    fi
    if [[ -x "$launch_services_register" && -d "$host_app" ]]; then
        "$launch_services_register" -u "$host_app" >/dev/null 2>&1 || true
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
    || fail "Another Enhanced Security integration invocation is active (or left the stale lock $invocation_lock)"
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
case $sanitizer_profile in
    address) swift_build_args+=(--sanitize address --sanitize undefined) ;;
    thread) swift_build_args+=(--sanitize thread --sanitize undefined) ;;
esac
/usr/bin/swift build "${swift_build_args[@]}" --product TorrentEngineXPCIntegrationHost
/usr/bin/swift build "${swift_build_args[@]}" --product TorrentEngineIntegrationExtension

if [[ -x "$launch_services_register" && -d "$host_app" ]]; then
    "$launch_services_register" -u "$host_app" >/dev/null 2>&1 || true
fi
/bin/rm -rf -- "$host_app"
/bin/mkdir -p -- \
    "${host_executable:h}" \
    "${engine_executable:h}" \
    "${extension_point:h}"
/bin/cp \
    "$swift_build_dir/arm64e-apple-macosx/$configuration/TorrentEngineXPCIntegrationHost" \
    "$host_executable"
/bin/cp \
    "$swift_build_dir/arm64e-apple-macosx/$configuration/TorrentEngineIntegrationExtension" \
    "$engine_executable"
verify_sanitizer_runtime "$host_executable"
verify_sanitizer_runtime "$engine_executable"
/bin/cp "$host_info" "$host_contents/Info.plist"
/bin/cp "$engine_info" "$engine_contents/Info.plist"
/bin/cp "$extension_point_source" "$extension_point"
/usr/bin/plutil -lint \
    "$host_contents/Info.plist" \
    "$engine_contents/Info.plist" \
    "$extension_point" \
    >/dev/null
/usr/bin/xcrun swift "$root_dir/Scripts/verify-enhanced-security-metadata.swift" \
    "$extension_point" \
    "$engine_contents/Info.plist" \
    "$extension_point_identifier"

/usr/bin/codesign \
    --force \
    --sign - \
    --options "$sign_options" \
    --entitlements "$engine_entitlements" \
    --timestamp=none \
    "$engine_extension"
/usr/bin/codesign \
    --force \
    --sign - \
    --options "$sign_options" \
    --entitlements "$host_entitlements" \
    --timestamp=none \
    "$host_app"
/usr/bin/codesign --verify --strict --verbose=2 "$engine_extension"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$host_app"
[[ -x "$launch_services_register" ]] \
    || fail "Could not locate the LaunchServices registration tool"
"$launch_services_register" -f -R -trusted "$host_app" >/dev/null

preflight_exact_processes
owns_test_state=1
cleanup_test_state

if [[ $mode == build-only ]]; then
    print -- "Enhanced Security extension fixture assembled and signature-verified"
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

print -- "Enhanced Security extension integration (ad-hoc $configuration bundle; correctness gate)"
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

/bin/rm -f -- \
    "$host_output" \
    "$host_stderr" \
    "$memory_output" \
    "$recovery_output" \
    "$timeout_marker"
typeset -a sanitizer_environment_args=()
case $sanitizer_profile in
    address)
        sanitizer_environment_args=(
            --env "ASAN_OPTIONS=${ASAN_OPTIONS:-halt_on_error=1:abort_on_error=1}"
            --env "UBSAN_OPTIONS=${UBSAN_OPTIONS:-halt_on_error=1:print_stacktrace=1}"
        )
        ;;
    thread)
        sanitizer_environment_args=(
            --env "TSAN_OPTIONS=${TSAN_OPTIONS:-halt_on_error=1:exitcode=66:print_full_thread_history=1}"
            --env "UBSAN_OPTIONS=${UBSAN_OPTIONS:-halt_on_error=1:print_stacktrace=1}"
        )
        ;;
esac
/usr/bin/open \
    -n \
    -W \
    --stdout "$host_output" \
    --stderr "$host_stderr" \
    "${sanitizer_environment_args[@]}" \
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
if [[ $mode == automated ]]; then
    (
        typeset marker_attempt
        for (( marker_attempt = 1; marker_attempt <= recovery_spawn_attempts; marker_attempt++ )); do
            [[ -f "$recovery_ready_marker" ]] && break
            pid_matches_exact_executable "$host_pid" "$host_executable" || exit 10
            sleep 0.02
        done
        [[ -f "$recovery_ready_marker" ]] || exit 11

        typeset -a old_engine_pids=(${(f)"$(exact_process_pids "$engine_executable")"})
        (( ${#old_engine_pids[@]} == 1 )) || exit 12
        typeset -r old_engine_pid=$old_engine_pids[1]
        pid_matches_exact_executable "$old_engine_pid" "$engine_executable" || exit 13
        kill -KILL "$old_engine_pid" || exit 14

        for marker_attempt in {1..250}; do
            pid_matches_exact_executable "$old_engine_pid" "$engine_executable" || break
            sleep 0.02
        done
        pid_matches_exact_executable "$old_engine_pid" "$engine_executable" && exit 15
        /usr/bin/touch "$recovery_killed_marker" || exit 16

        typeset new_engine_pid=0
        typeset -a new_engine_pids=()
        for (( marker_attempt = 1; marker_attempt <= recovery_spawn_attempts; marker_attempt++ )); do
            new_engine_pids=(${(f)"$(exact_process_pids "$engine_executable")"})
            if (( ${#new_engine_pids[@]} == 1 \
                && new_engine_pids[1] != old_engine_pid )); then
                new_engine_pid=$new_engine_pids[1]
                break
            fi
            pid_matches_exact_executable "$host_pid" "$host_executable" || exit 17
            sleep 0.02
        done
        (( new_engine_pid > 0 )) || exit 18
        print -- "recovery.old_helper_pid=$old_engine_pid"
        print -- "recovery.new_helper_pid=$new_engine_pid"
        print -- "recovery.helper_pid_changed=1"
    ) >"$recovery_output" 2>&1 &
    recovery_coordinator_pid=$!
fi
(
    typeset host_peak_rss_kib=0
    typeset helper_peak_rss_kib=0
    typeset helper_was_observed=0
    while pid_matches_exact_executable "$host_pid" "$host_executable"; do
        typeset host_rss_kib=$(
            /bin/ps -o rss= -p "$host_pid" 2>/dev/null \
                | /usr/bin/awk 'NR == 1 { print $1 + 0 }' \
                || print 0
        )
        typeset helper_sample=$(
            /bin/ps -ww -axo pid=,rss=,command= \
                | /usr/bin/awk -v executable="$engine_executable" '
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
        typeset helper_rss_kib=${helper_sample%% *}
        typeset helper_observed=${helper_sample##* }
        (( host_rss_kib > host_peak_rss_kib )) \
            && host_peak_rss_kib=$host_rss_kib
        (( helper_rss_kib > helper_peak_rss_kib )) \
            && helper_peak_rss_kib=$helper_rss_kib
        (( helper_observed == 1 )) && helper_was_observed=1
        sleep 0.1
    done
    print -- "memory.sampling_interval_seconds=0.1"
    print -- "memory.host.sampled_peak_rss_kib=$host_peak_rss_kib"
    print -- "memory.helper.sampled_peak_rss_kib=$helper_peak_rss_kib"
    print -- "memory.helper.observed=$helper_was_observed"
) >"$memory_output" &
sampler_pid=$!
(
    sleep "$timeout_seconds"
    pid_matches_exact_executable "$host_pid" "$host_executable" || exit 0
    print -- "timeout" >"$timeout_marker"
    print -ru2 -- "Enhanced Security extension integration exceeded its $timeout_seconds-second hard timeout"
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
typeset recovery_status=0
if (( recovery_coordinator_pid > 0 )); then
    if wait "$recovery_coordinator_pid"; then
        recovery_status=0
    else
        recovery_status=$?
    fi
    recovery_coordinator_pid=0
fi
kill -TERM "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=0
wait "$sampler_pid" 2>/dev/null || true
sampler_pid=0
host_pid=0

/bin/cat "$host_output"
/bin/cat "$host_stderr"
/bin/cat "$memory_output"
[[ ! -f "$recovery_output" ]] || /bin/cat "$recovery_output"

[[ ! -e $timeout_marker ]] || fail "Enhanced Security extension integration timed out"
(( launcher_status == 0 )) \
    || fail "LaunchServices integration wait failed with status $launcher_status"
if [[ $mode == automated ]]; then
    (( recovery_status == 0 )) \
        || fail "Forced helper-exit coordination failed with status $recovery_status"
    /usr/bin/grep -qx 'recovery.helper_pid_changed=1' "$recovery_output" \
        || fail "Forced helper exit did not produce a distinct replacement process"
    /usr/bin/grep -qx 'integration.forced_helper_exit=observed' "$host_output" \
        || fail "The client did not observe the forced helper exit"
fi
/usr/bin/grep -qx 'integration.result=pass' "$host_output" \
    || fail "Enhanced Security extension integration exited without a pass marker"
/usr/bin/grep -qx 'memory.helper.observed=1' "$memory_output" \
    || fail "Enhanced Security extension integration never observed the exact helper executable"
