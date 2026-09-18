import Darwin
import ProcessRunner
import Synchronization
import Testing

@Suite struct ProcessRunnerTests {
    @Test func isolatesTheChildAndItsHelpersInOneProcessGroup() async throws {
        let identifier = Mutex<Int32?>(nil)
        let result = try await ProcessRunner.run(
            "/bin/zsh",
            arguments: ["-c", "/bin/ps -o pid=,pgid= -p $$; /bin/zsh -c '/bin/ps -o pid=,pgid= -p $$' & wait"]
        ) { pid in
            identifier.withLock { $0 = pid }
        }
        let pid = try #require(identifier.withLock { $0 })
        #expect(result.status == 0)
        let identifiers = result.stdout.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        try #require(identifiers.count == 4)
        #expect(identifiers[0] == pid)
        #expect(identifiers[1] == pid)
        #expect(identifiers[2] != pid)
        #expect(identifiers[3] == pid)
        #expect(pid != getpgrp())
    }

    @Test func drainsBothPipesBeyondTheirCapacity() async throws {
        let result = try await ProcessRunner.run("/bin/zsh", arguments: ["-c", "for ((i=0; i<12000; i++)); do print -r -- abcdefghijklmnop; print -ru2 -- qrstuvwxyz012345; done"])
        #expect(result.status == 0)
        #expect(result.stdout.utf8.count == 17 * 12000)
        #expect(result.stderr.utf8.count == 17 * 12000)
    }

    @Test func preservesArgumentsAndNonzeroExit() async throws {
        let value = "a b;$(not-a-command)"
        let result = try await ProcessRunner.run("/bin/zsh", arguments: ["-c", "print -rn -- $1; exit 7", "probe", value])
        #expect(result.stdout == value)
        #expect(result.status == 7)
    }

    @Test func reportsSignalTermination() async {
        await #expect(throws: ProcessRunError.signaled(SIGTERM)) {
            try await ProcessRunner.run("/bin/zsh", arguments: ["-c", "kill -TERM $$"])
        }
    }

    @Test func enforcesOutputLimitAndEncoding() async throws {
        let exact = try await ProcessRunner.run("/usr/bin/printf", arguments: ["1234"], maximumOutputBytes: 4)
        #expect(exact.stdout == "1234")
        await #expect(throws: ProcessRunError.outputLimitExceeded) {
            try await ProcessRunner.run("/usr/bin/printf", arguments: ["12345"], maximumOutputBytes: 4)
        }
        await #expect(throws: ProcessRunError.invalidUTF8) {
            try await ProcessRunner.run("/usr/bin/printf", arguments: ["\\377"])
        }
    }

    @Test func deadlineTerminatesAndReapsChild() async throws {
        let identifiers = AsyncStream<Int32>.makeStream()
        // This is a real process deadline integration test. The child ignores TERM
        // to exercise the bounded escalation to KILL, without polling or sleeps here.
        let task = Task {
            defer { identifiers.continuation.finish() }
            return try await ProcessRunner.run("/bin/zsh", arguments: ["-c", "trap '' TERM; while true; do :; done"], timeout: .milliseconds(200)) {
                identifiers.continuation.yield($0)
                identifiers.continuation.finish()
            }
        }
        defer { task.cancel() }
        var iterator = identifiers.stream.makeAsyncIterator()
        let pid = try #require(await iterator.next())
        await #expect(throws: ProcessRunError.timedOut) { try await task.value }
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func cancellationTerminatesAndReapsChild() async throws {
        let identifiers = AsyncStream<Int32>.makeStream()
        let task = Task {
            defer { identifiers.continuation.finish() }
            return try await ProcessRunner.run("/bin/sleep", arguments: ["60"]) {
                identifiers.continuation.yield($0)
                identifiers.continuation.finish()
            }
        }
        defer { task.cancel() }
        var iterator = identifiers.stream.makeAsyncIterator()
        let pid = try #require(await iterator.next())
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func rejectsMissingExecutableAndInvalidLimits() async {
        await #expect(throws: ProcessRunError.missingExecutable("/missing/repository-tool")) {
            try await ProcessRunner.run("/missing/repository-tool", arguments: [])
        }
        await #expect(throws: ProcessRunError.invalidLimits) {
            try await ProcessRunner.run("/usr/bin/true", arguments: [], maximumOutputBytes: 0)
        }
    }
}
