#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
# Repeat only the bounded cancellation, deadline, reply-once, and shared-process
# suites. Stop on failure; this must never turn a flaky failure into a pass.
exec "$root_dir/Scripts/test-swift.zsh" \
    --filter 'TorrentEngineClientTests\.(TorrentEngineXPCTransportStateTests|TorrentXPCClientDeadlineTests|TorrentEngineProcessSingleFlightTests)/' \
    --maximum-repetitions 25 \
    --repeat-until fail \
    "$@"
