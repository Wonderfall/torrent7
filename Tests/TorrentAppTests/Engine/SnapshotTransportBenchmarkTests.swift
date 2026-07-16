import Darwin
import Dispatch
import Foundation
import Testing
import TorrentBridge
import TorrentEngineModel
@testable import TorrentApp

@Suite("Snapshot transport resource model", .serialized)
struct SnapshotTransportBenchmarkTests {
    @Test("Maximum snapshot transport stays within the reviewed resource model")
    func maximumSnapshotTransportStaysWithinReviewedResourceModel() {
        let maximumCount = Int(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT)
        let snapshotStride = MemoryLayout<TTorrentSnapshot>.stride
        let rawBatchBytes = maximumCount * snapshotStride
        let twoRawBatchBytes = 2 * rawBatchBytes

        let snapshot = TTorrentSnapshot()
        let fixedCStringFieldCount = 6
        let fixedCStringBytesPerSnapshot = MemoryLayout.size(ofValue: snapshot.id)
            + MemoryLayout.size(ofValue: snapshot.info_hash)
            + MemoryLayout.size(ofValue: snapshot.name)
            + MemoryLayout.size(ofValue: snapshot.save_path)
            + MemoryLayout.size(ofValue: snapshot.error)
            + MemoryLayout.size(ofValue: snapshot.comment)
        let fixedCStringScanBytes = maximumCount * fixedCStringBytesPerSnapshot
        let maximumDecodedStringBytes = maximumCount
            * (fixedCStringBytesPerSnapshot - fixedCStringFieldCount)
        let torrentItemArrayBytes = maximumCount * MemoryLayout<TorrentItem>.stride
        let modeledSwiftTransientBytes = rawBatchBytes
            + (2 * torrentItemArrayBytes)
            + maximumDecodedStringBytes

        #expect(maximumCount == 20_000)
        #expect(snapshotStride == 3_360)
        #expect(rawBatchBytes == 67_200_000)
        #expect(rawBatchBytes <= 65 * 1_024 * 1_024)
        #expect(twoRawBatchBytes == 134_400_000)
        #expect(twoRawBatchBytes <= 130 * 1_024 * 1_024)
        #expect(fixedCStringBytesPerSnapshot == 3_208)
        #expect(fixedCStringScanBytes == 64_160_000)
        #expect(fixedCStringScanBytes <= 62 * 1_024 * 1_024)
        #expect(maximumCount * fixedCStringFieldCount == 120_000)
        #expect(torrentItemArrayBytes <= 5 * 1_024 * 1_024)
        #expect(modeledSwiftTransientBytes <= 160 * 1_024 * 1_024)
    }

    @Test("Opt-in maximum snapshot mapping and sorting benchmark")
    func maximumSnapshotMappingAndSortingBenchmark() {
        guard ProcessInfo.processInfo.environment["RUN_SNAPSHOT_TRANSPORT_BENCHMARK"] == "1" else {
            return
        }

        let maximumCount = Int(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT)
        let warmupCount = 2
        let sampleCount = 7
        let snapshots = makeBenchmarkSnapshots(count: maximumCount)
        let incrementalFootprintBytes = measureIncrementalTransportFootprint(snapshots)
        var checksum: Int64 = 0

        let allocationAndCopy = benchmarkDistribution(
            warmupCount: warmupCount,
            sampleCount: sampleCount
        ) {
            let copied = copySnapshots(snapshots)
            checksum &+= copied[maximumCount / 2].total_done
        }

        let mapping = benchmarkDistribution(
            warmupCount: warmupCount,
            sampleCount: sampleCount
        ) {
            let mapped = snapshots.map { TorrentItem(snapshot: $0) }
            checksum &+= Int64(mapped[maximumCount / 2].id.utf8.count)
        }

        let endToEndDateSort = benchmarkDistribution(
            warmupCount: warmupCount,
            sampleCount: sampleCount
        ) {
            let copied = copySnapshots(snapshots)
            let mapped = copied.map { TorrentItem(snapshot: $0) }
            let sorted = TorrentSortOrder.dateAdded.sorted(mapped, direction: .ascending)
            checksum &+= sorted[maximumCount / 2].addedTime
        }

        let mapped = snapshots.map { TorrentItem(snapshot: $0) }
        #expect(mapped.count == maximumCount)

        let dateSort = benchmarkDistribution(
            warmupCount: warmupCount,
            sampleCount: sampleCount
        ) {
            let sorted = TorrentSortOrder.dateAdded.sorted(mapped, direction: .ascending)
            checksum &+= sorted[maximumCount / 2].addedTime
        }
        let nameSort = benchmarkDistribution(
            warmupCount: warmupCount,
            sampleCount: sampleCount
        ) {
            let sorted = TorrentSortOrder.name.sorted(mapped, direction: .ascending)
            checksum &+= Int64(sorted[maximumCount / 2].name.utf8.count)
        }

        #expect(checksum > 0)

        let footprintJSON = incrementalFootprintBytes.map { String($0) } ?? "null"
        print(
            "SNAPSHOT_TRANSPORT_SWIFT {"
                + "\"count\":\(maximumCount),"
                + "\"snapshot_stride\":\(MemoryLayout<TTorrentSnapshot>.stride),"
                + "\"samples\":\(sampleCount),"
                + "\"incremental_footprint_bytes\":\(footprintJSON),"
                + "\"allocation_copy\":\(allocationAndCopy.json),"
                + "\"mapping\":\(mapping.json),"
                + "\"date_sort\":\(dateSort.json),"
                + "\"name_sort\":\(nameSort.json),"
                + "\"end_to_end_date_sort\":\(endToEndDateSort.json)"
                + "}"
        )
    }
}

private struct BenchmarkDistribution {
    let medianMilliseconds: Double
    let p95Milliseconds: Double

    var json: String {
        "{\"median_ms\":\(medianMilliseconds),\"p95_ms\":\(p95Milliseconds)}"
    }
}

private func benchmarkDistribution(
    warmupCount: Int,
    sampleCount: Int,
    operation: () -> Void
) -> BenchmarkDistribution {
    for _ in 0..<warmupCount {
        autoreleasepool(invoking: operation)
    }

    var measurements: [Double] = []
    measurements.reserveCapacity(sampleCount)
    for _ in 0..<sampleCount {
        measurements.append(measureMilliseconds {
            autoreleasepool(invoking: operation)
        })
    }
    measurements.sort()

    let p95Index = ((95 * measurements.count + 99) / 100) - 1
    return BenchmarkDistribution(
        medianMilliseconds: measurements[measurements.count / 2],
        p95Milliseconds: measurements[p95Index]
    )
}

private func measureMilliseconds(operation: () -> Void) -> Double {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    operation()
    let finishedAt = DispatchTime.now().uptimeNanoseconds
    return Double(finishedAt - startedAt) / 1_000_000
}

private func makeBenchmarkSnapshots(count: Int) -> [TTorrentSnapshot] {
    let infoHash = maximumLengthASCII(label: "hash", capacity: 68)
    let savePath = maximumLengthASCII(label: "/save", capacity: 1_024)
    let error = maximumLengthASCII(label: "error", capacity: 512)
    let comment = maximumLengthASCII(label: "comment", capacity: 1_024)
    var snapshots: [TTorrentSnapshot] = []
    snapshots.reserveCapacity(count)

    for index in 0..<count {
        var snapshot = TTorrentSnapshot()
        writeBenchmarkCString(indexedMaximumLengthASCII(label: "id", index: index, capacity: 68), to: &snapshot.id)
        writeBenchmarkCString(infoHash, to: &snapshot.info_hash)
        writeBenchmarkCString(indexedMaximumLengthASCII(label: "name", index: index, capacity: 512), to: &snapshot.name)
        writeBenchmarkCString(savePath, to: &snapshot.save_path)
        writeBenchmarkCString(error, to: &snapshot.error)
        writeBenchmarkCString(comment, to: &snapshot.comment)
        snapshot.total_done = Int64(index)
        snapshot.total_wanted = Int64(count)
        snapshot.added_time = Int64((index * 7_919) % count)
        snapshot.state = Int32(TTORRENT_BRIDGE_STATE_DOWNLOADING)
        snapshot.has_metadata = 1
        snapshots.append(snapshot)
    }
    return snapshots
}

private func maximumLengthASCII(label: String, capacity: Int) -> String {
    let prefix = "\(label)-"
    return prefix + String(repeating: "x", count: capacity - 1 - prefix.utf8.count)
}

private func indexedMaximumLengthASCII(label: String, index: Int, capacity: Int) -> String {
    let prefix = "\(label)-"
    let unpaddedIndex = String(index)
    let paddedIndex = String(repeating: "0", count: max(0, 5 - unpaddedIndex.count)) + unpaddedIndex
    let suffix = "-\(paddedIndex)"
    let fillerCount = capacity - 1 - prefix.utf8.count - suffix.utf8.count
    return prefix + String(repeating: "x", count: fillerCount) + suffix
}

private func writeBenchmarkCString<T>(_ string: String, to tuple: inout T) {
    unsafe withUnsafeMutableBytes(of: &tuple) { bytes in
        for index in bytes.indices {
            unsafe bytes[index] = 0
        }
        for (index, byte) in string.utf8.prefix(max(0, bytes.count - 1)).enumerated() {
            unsafe bytes[index] = byte
        }
    }
}

private func copySnapshots(_ snapshots: [TTorrentSnapshot]) -> [TTorrentSnapshot] {
    var copied = Array(repeating: TTorrentSnapshot(), count: snapshots.count)
    let byteCount = snapshots.count * MemoryLayout<TTorrentSnapshot>.stride
    unsafe snapshots.withUnsafeBufferPointer { source in
        unsafe copied.withUnsafeMutableBufferPointer { destination in
            guard let sourceAddress = source.baseAddress,
                  let destinationAddress = destination.baseAddress else {
                return
            }
            unsafe memcpy(destinationAddress, sourceAddress, byteCount)
        }
    }
    return copied
}

private func measureIncrementalTransportFootprint(_ snapshots: [TTorrentSnapshot]) -> UInt64? {
    guard let baselineBytes = physicalFootprintBytes() else {
        return nil
    }

    let copied = copySnapshots(snapshots)
    let mapped = copied.map { TorrentItem(snapshot: $0) }
    let sorted = TorrentSortOrder.dateAdded.sorted(mapped, direction: .ascending)
    guard let retainedBytes = physicalFootprintBytes() else {
        return nil
    }

    withExtendedLifetime(copied) {}
    withExtendedLifetime(mapped) {}
    withExtendedLifetime(sorted) {}
    return retainedBytes >= baselineBytes ? retainedBytes - baselineBytes : 0
}

private func physicalFootprintBytes() -> UInt64? {
    var information = task_vm_info_data_t()
    var informationCount = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let result = unsafe withUnsafeMutablePointer(to: &information) { pointer in
        unsafe pointer.withMemoryRebound(to: integer_t.self, capacity: Int(informationCount)) { rebound in
            unsafe task_info(
                mach_task_self_,
                task_flavor_t(TASK_VM_INFO),
                rebound,
                &informationCount
            )
        }
    }
    guard result == KERN_SUCCESS else {
        return nil
    }
    return information.phys_footprint
}
