import Foundation
import Subprocess
import System

package struct ProcessResult: Sendable {
    package let stdout: String
    package let stderr: String
    package let status: Int32
}

package enum ProcessRunError: Error, Equatable {
    case invalidLimits
    case missingExecutable(String)
    case timedOut
    case signaled(Int32)
    case invalidUTF8
    case outputLimitExceeded
}

package enum ProcessRunner {
    package static func run(
        _ executable: String,
        arguments: [String],
        timeout: Duration = .seconds(30),
        maximumOutputBytes: Int = 1_048_576,
        didStart: @escaping @Sendable (Int32) -> Void = { _ in }
    ) async throws -> ProcessResult {
        guard timeout > .zero, maximumOutputBytes > 0 else { throw ProcessRunError.invalidLimits }
        try Task.checkCancellation()
        let path = try executablePath(executable)
        return try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            group.addTask {
                do {
                    var options = PlatformOptions()
                    // Git may spawn transport helpers. A separate session lets
                    // teardown signal their group without reaching this tool.
                    options.createSession = true
                    options.teardownSequence = [
                        .gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: .seconds(1))
                    ]
                    let result = try await Subprocess.run(
                        .path(FilePath(path)),
                        arguments: Arguments(arguments),
                        platformOptions: options,
                        input: .none,
                        output: .bytes(limit: maximumOutputBytes),
                        error: .bytes(limit: maximumOutputBytes)
                    ) { execution in
                        didStart(execution.processIdentifier.value)
                    }
                    try Task.checkCancellation()
                    let status: Int32
                    switch result.terminationStatus {
                    case .exited(let code): status = code
                    case .signaled(let signal): throw ProcessRunError.signaled(signal)
                    }
                    guard let stdout = String(validating: result.standardOutput, as: UTF8.self),
                          let stderr = String(validating: result.standardError, as: UTF8.self) else {
                        throw ProcessRunError.invalidUTF8
                    }
                    return ProcessResult(stdout: stdout, stderr: stderr, status: status)
                } catch {
                    try Task.checkCancellation()
                    if let error = error as? SubprocessError, error.code == .outputLimitExceeded {
                        throw ProcessRunError.outputLimitExceeded
                    }
                    throw error
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProcessRunError.timedOut
            }
            // Scope exit waits for Subprocess to terminate and reap its child. The
            // losing deadline task is cancelled, and process teardown has a one-second
            // grace period before the library escalates to forced termination.
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }

    private static func executablePath(_ name: String) throws -> String {
        let candidates = name.contains("/") ? [name] :
            ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":").map { "\($0)/\(name)" }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ProcessRunError.missingExecutable(name)
        }
        return path
    }
}
