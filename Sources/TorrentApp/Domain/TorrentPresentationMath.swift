enum TorrentPresentationMath {
    static func estimatedRemainingSeconds(
        totalWanted: Int64,
        totalDone: Int64,
        downloadRate: Int64
    ) -> Int64? {
        guard totalWanted >= 0,
              totalDone >= 0,
              totalWanted > totalDone,
              downloadRate > 0 else {
            return nil
        }

        let remainingBytes = totalWanted - totalDone
        let wholeSeconds = remainingBytes / downloadRate
        guard remainingBytes % downloadRate != 0 else {
            return wholeSeconds
        }
        let (roundedSeconds, overflowed) = wholeSeconds.addingReportingOverflow(1)
        return overflowed ? Int64.max : roundedSeconds
    }

    static func saturatingNonnegativeSum<Values: Sequence>(
        _ values: Values
    ) -> Int64 where Values.Element == Int64 {
        var total: Int64 = 0
        for value in values {
            let (sum, overflowed) = total.addingReportingOverflow(max(0, value))
            guard !overflowed else {
                return Int64.max
            }
            total = sum
        }
        return total
    }
}
