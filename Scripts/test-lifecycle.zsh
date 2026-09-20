#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -r root_dir=${0:A:h:h}
# Repeat only the bounded cancellation, deadline, reply-once, and shared-process
# suites and IPC wait-queue tests. Stop on failure; this must never turn a flaky
# failure into a pass.
typeset -r suites='TorrentEngineXPCTransportStateTests|TorrentXPCClientDeadlineTests|TorrentEngineProcessSingleFlightTests'
typeset -r queue_tests='cancelledQueuedPollReleasesPipelineWaiter|queuedCancellationIsLocal|terminationDrainsWaitingQueues'
exec "$root_dir/Scripts/test-swift.zsh" \
    --filter "TorrentEngineClientTests\.(($suites)/|TorrentXPCClientSecurityTests/($queue_tests))" \
    --maximum-repetitions 25 \
    --repeat-until fail \
    "$@"
