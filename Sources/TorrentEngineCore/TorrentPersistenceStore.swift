import TorrentEngineModel

@safe package struct TorrentPersistenceStore: Sendable {
    package enum SaveMode: UInt8, Comparable, Sendable {
        case routine
        case policy
        case full

        package static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    package struct Attempt: Equatable, Sendable {
        package let nativeToken: UInt64
        package let generation: UInt64
        package let mode: SaveMode
        package let priorFailureCount: Int
    }

    package struct RemovalCleanup: Equatable, Sendable {
        package let tombstoneFilename: String
        package let resumeIDs: [String]
        package let resumeDataWasRemoved: Bool
    }

    private struct PendingSave: Equatable, Sendable {
        var generation: UInt64
        var mode: SaveMode
        var failureCount: Int
    }

    private var pendingByNativeToken = [UInt64: PendingSave]()
    private var removalCleanupsByFilename = [String: RemovalCleanup]()
    private var nativeRemovalRecoveryFailureCount: Int?
    private var nextGeneration: UInt64 = 1

    package var hasPendingWork: Bool {
        !pendingByNativeToken.isEmpty
            || !removalCleanupsByFilename.isEmpty
            || nativeRemovalRecoveryFailureCount != nil
    }

    @discardableResult
    package mutating func requestSave(
        nativeToken: UInt64,
        mode: SaveMode
    ) -> Bool {
        guard nativeToken != 0, let generation = allocateGeneration() else {
            return false
        }
        let existing = pendingByNativeToken[nativeToken]
        pendingByNativeToken[nativeToken] = PendingSave(
            generation: generation,
            mode: max(existing?.mode ?? mode, mode),
            failureCount: existing?.failureCount ?? 0
        )
        return true
    }

    package mutating func requestSave(
        nativeTokens: some Sequence<UInt64>,
        mode: SaveMode
    ) -> Bool {
        var accepted = true
        for nativeToken in nativeTokens {
            accepted = requestSave(nativeToken: nativeToken, mode: mode) && accepted
        }
        return accepted
    }

    package func pendingAttempts() -> [Attempt] {
        pendingByNativeToken
            .map { nativeToken, pending in
                Attempt(
                    nativeToken: nativeToken,
                    generation: pending.generation,
                    mode: pending.mode,
                    priorFailureCount: pending.failureCount
                )
            }
            .sorted { $0.nativeToken < $1.nativeToken }
    }

    package mutating func complete(
        _ attempt: Attempt,
        succeeded: Bool
    ) {
        guard var pending = pendingByNativeToken[attempt.nativeToken],
              pending.generation == attempt.generation else {
            return
        }
        if succeeded {
            pendingByNativeToken.removeValue(forKey: attempt.nativeToken)
        } else {
            pending.failureCount = min(pending.failureCount + 1, Int.max)
            pendingByNativeToken[attempt.nativeToken] = pending
        }
    }

    package mutating func remove(nativeToken: UInt64) {
        pendingByNativeToken.removeValue(forKey: nativeToken)
    }

    package mutating func retain(nativeTokens: Set<UInt64>) {
        pendingByNativeToken = pendingByNativeToken.filter {
            nativeTokens.contains($0.key)
        }
    }

    package mutating func registerRemovalTombstone(
        filename: String,
        resumeIDs: [String]
    ) -> Bool {
        guard Self.isValidRemovalTombstoneFilename(filename),
              filename.utf8.count < TorrentEngineLimits.removalTombstoneFilenameCapacity,
              !resumeIDs.isEmpty,
              resumeIDs.count <= TorrentEngineLimits.maximumResumeIDCount,
              Set(resumeIDs).count == resumeIDs.count,
              removalCleanupsByFilename[filename] == nil else {
            return false
        }
        removalCleanupsByFilename[filename] = RemovalCleanup(
            tombstoneFilename: filename,
            resumeIDs: resumeIDs,
            resumeDataWasRemoved: false
        )
        return true
    }

    package var pendingRemovalCleanups: [RemovalCleanup] {
        removalCleanupsByFilename.values.sorted {
            $0.tombstoneFilename < $1.tombstoneFilename
        }
    }

    package mutating func markResumeDataRemoved(tombstoneFilename: String) {
        guard let cleanup = removalCleanupsByFilename[tombstoneFilename] else {
            return
        }
        removalCleanupsByFilename[tombstoneFilename] = RemovalCleanup(
            tombstoneFilename: cleanup.tombstoneFilename,
            resumeIDs: cleanup.resumeIDs,
            resumeDataWasRemoved: true
        )
    }

    package mutating func completeRemovalCleanup(tombstoneFilename: String) {
        removalCleanupsByFilename.removeValue(forKey: tombstoneFilename)
    }

    package mutating func requestNativeRemovalRecovery() {
        if nativeRemovalRecoveryFailureCount == nil {
            nativeRemovalRecoveryFailureCount = 0
        }
    }

    package var shouldRecoverNativeRemovals: Bool {
        nativeRemovalRecoveryFailureCount != nil
    }

    package mutating func completeNativeRemovalRecovery(succeeded: Bool) {
        guard let failureCount = nativeRemovalRecoveryFailureCount else {
            return
        }
        if succeeded {
            nativeRemovalRecoveryFailureCount = nil
        } else {
            nativeRemovalRecoveryFailureCount = min(failureCount + 1, Int.max)
        }
    }

    private mutating func allocateGeneration() -> UInt64? {
        guard nextGeneration != 0 else {
            return nil
        }
        let generation = nextGeneration
        nextGeneration &+= 1
        return generation
    }

    private static func isValidRemovalTombstoneFilename(_ filename: String) -> Bool {
        let prefix = "removal-"
        let suffix = ".fastresume.remove"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else {
            return false
        }
        let nonceStart = filename.index(filename.startIndex, offsetBy: prefix.count)
        let nonceEnd = filename.index(filename.endIndex, offsetBy: -suffix.count)
        let nonce = filename[nonceStart..<nonceEnd]
        return nonce.utf8.count == 32
            && nonce.utf8.allSatisfy { byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            }
    }
}
