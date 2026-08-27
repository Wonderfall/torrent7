import Darwin
import Dispatch
import Foundation
import TorrentBridge
import TorrentEngineCore

struct BenchmarkDistribution {
    let inputBytes: Int
    let medianNanoseconds: Double
    let p95Nanoseconds: Double
    let checksum: Int64

    private var medianMessagesPerSecond: Double {
        1_000_000_000 / medianNanoseconds
    }

    var json: String {
        "{"
            + "\"input_bytes\":\(inputBytes),"
            + "\"median_ns\":\(medianNanoseconds),"
            + "\"p95_ns\":\(p95Nanoseconds),"
            + "\"median_messages_per_second\":\(medianMessagesPerSecond)"
            + "}"
    }
}

private func benchmarkDistribution(
    message: Data,
    context: UnsafeMutableRawPointer,
    iterationCount: Int,
    warmupCount: Int,
    sampleCount: Int
) -> BenchmarkDistribution {
    for _ in 0..<warmupCount {
        _ = unsafe benchmarkBatch(
            message: message,
            context: context,
            iterationCount: iterationCount
        )
    }

    var measurements = [Double]()
    measurements.reserveCapacity(sampleCount)
    var checksum: Int64 = 0
    for _ in 0..<sampleCount {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        checksum &+= unsafe benchmarkBatch(
            message: message,
            context: context,
            iterationCount: iterationCount
        )
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
        measurements.append(Double(elapsed) / Double(iterationCount))
    }
    measurements.sort()
    let p95Index = ((95 * measurements.count + 99) / 100) - 1
    return BenchmarkDistribution(
        inputBytes: message.count,
        medianNanoseconds: measurements[measurements.count / 2],
        p95Nanoseconds: measurements[p95Index],
        checksum: checksum
    )
}

private func benchmarkBatch(
    message: Data,
    context: UnsafeMutableRawPointer,
    iterationCount: Int
) -> Int64 {
    var nodes = [TTorrentDHTNodeRecord](
        repeating: TTorrentDHTNodeRecord(),
        count: Int(TTORRENT_MAX_DHT_MESSAGE_NODES)
    )
    var peers = [TTorrentDHTPeerRecord](
        repeating: TTorrentDHTPeerRecord(),
        count: Int(TTORRENT_MAX_DHT_MESSAGE_PEERS)
    )
    var result = TTorrentDHTMessageResult()
    var checksum: Int64 = 0
    var callbacks = unsafe TTorrentDHTMessageParserCallbacks()
    unsafe callbacks.parse_message = torrentDHTMessageParseCallback
    guard let parseMessage = unsafe callbacks.parse_message else {
        fatalError("The DHT benchmark callback table is incomplete")
    }

    unsafe message.withUnsafeBytes { rawMessage in
        unsafe nodes.withUnsafeMutableBufferPointer { nodeBuffer in
            unsafe peers.withUnsafeMutableBufferPointer { peerBuffer in
                guard let body = unsafe rawMessage.bindMemory(to: CChar.self).baseAddress,
                      let nodeOutput = nodeBuffer.baseAddress,
                      let peerOutput = peerBuffer.baseAddress else {
                    fatalError("The DHT benchmark could not borrow its fixed buffers")
                }
                for _ in 0..<iterationCount {
                    let status = unsafe parseMessage(
                        context,
                        body,
                        Int32(rawMessage.count),
                        UInt8(TTORRENT_PEER_ADDRESS_IPV4),
                        nodeOutput,
                        Int32(nodeBuffer.count),
                        peerOutput,
                        Int32(peerBuffer.count),
                        &result
                    )
                    guard status == 0 else {
                        fatalError("The DHT benchmark message was rejected: \(status)")
                    }
                    checksum &+= Int64(result.message_kind)
                        + Int64(result.node_count)
                        + Int64(result.peer_count)
                }
            }
        }
    }
    return checksum
}

private func query() -> Data {
    dictionary([
        ("a", dictionary([
            ("id", string(Data(repeating: 1, count: 20))),
        ])),
        ("q", string(Data("ping".utf8))),
        ("t", string(Data([0, 1]))),
        ("y", string(Data("q".utf8))),
    ])
}

private func denseResponse() -> (message: Data, nodeCount: Int) {
    var compactNodes = Data()
    var lastAccepted = (message: Data(), nodeCount: 0)
    for index in 0..<Int(TTORRENT_MAX_DHT_MESSAGE_NODES) {
        compactNodes.append(Data(repeating: UInt8(truncatingIfNeeded: index + 1), count: 20))
        compactNodes.append(contentsOf: [203, 0, 113, UInt8(truncatingIfNeeded: index + 1)])
        compactNodes.append(contentsOf: [0x1a, UInt8(truncatingIfNeeded: 0xe1 + index)])
        let candidate = response([
            ("id", string(Data(repeating: 2, count: 20))),
            ("nodes", string(compactNodes)),
        ])
        guard candidate.count <= Int(TTORRENT_MAX_DHT_MESSAGE_BYTES) else {
            break
        }
        lastAccepted = (candidate, index + 1)
    }
    return lastAccepted
}

private func maximumWorkResponse() -> Data {
    // The scanner counts the root, dictionary keys, values, and the list itself.
    // 489 empty list elements bring this valid envelope to exactly 500 values.
    response([
        ("id", string(Data(repeating: 3, count: 20))),
        ("z", list(Array(repeating: string(Data()), count: 489))),
    ])
}

private func response(_ fields: [(String, Data)]) -> Data {
    dictionary([
        ("r", dictionary(fields)),
        ("t", string(Data([0, 1]))),
        ("y", string(Data("r".utf8))),
    ])
}

private func string(_ value: Data) -> Data {
    Data("\(value.count):".utf8) + value
}

private func list(_ values: [Data]) -> Data {
    values.reduce(into: Data([UInt8(ascii: "l")])) { result, value in
        result.append(value)
    } + Data([UInt8(ascii: "e")])
}

private func dictionary(_ fields: [(String, Data)]) -> Data {
    let sorted = fields.sorted {
        $0.0.utf8.lexicographicallyPrecedes($1.0.utf8)
    }
    var result = Data([UInt8(ascii: "d")])
    for (key, value) in sorted {
        result.append(string(Data(key.utf8)))
        result.append(value)
    }
    result.append(UInt8(ascii: "e"))
    return result
}

private func mallocBytesInUse() -> UInt64? {
    guard let zone = unsafe malloc_default_zone() else {
        return nil
    }
    var statistics = malloc_statistics_t()
    unsafe malloc_zone_statistics(zone, &statistics)
    return UInt64(statistics.size_in_use)
}

let smallQuery = query()
let dense = denseResponse()
let maximumWork = maximumWorkResponse()
let iterationCount = 5_000
let warmupCount = 2
let sampleCount = 9
let retainedContext = unsafe Unmanaged.passRetained(TorrentDHTMessageBridgeContext())
defer {
    unsafe retainedContext.release()
}
let context = unsafe retainedContext.toOpaque()

precondition(smallQuery.count <= Int(TTORRENT_MAX_DHT_MESSAGE_BYTES))
precondition(dense.message.count <= Int(TTORRENT_MAX_DHT_MESSAGE_BYTES))
precondition(dense.nodeCount <= Int(TTORRENT_MAX_DHT_MESSAGE_NODES))
precondition(maximumWork.count <= Int(TTORRENT_MAX_DHT_MESSAGE_BYTES))

let smallResult = unsafe benchmarkDistribution(
    message: smallQuery,
    context: context,
    iterationCount: iterationCount,
    warmupCount: warmupCount,
    sampleCount: sampleCount
)
let denseResult = unsafe benchmarkDistribution(
    message: dense.message,
    context: context,
    iterationCount: iterationCount,
    warmupCount: warmupCount,
    sampleCount: sampleCount
)
let maximumWorkResult = unsafe benchmarkDistribution(
    message: maximumWork,
    context: context,
    iterationCount: iterationCount,
    warmupCount: warmupCount,
    sampleCount: sampleCount
)
let allocationBaseline = mallocBytesInUse()
_ = unsafe benchmarkBatch(
    message: maximumWork,
    context: context,
    iterationCount: iterationCount
)
let allocationAfter = mallocBytesInUse()
let retainedAllocationBytes = allocationBaseline.flatMap { baseline in
    allocationAfter.map { after in
        after >= baseline ? after - baseline : 0
    }
}
let retainedAllocationJSON = retainedAllocationBytes.map(String.init) ?? "null"
precondition(smallResult.checksum > 0)
precondition(denseResult.checksum > 0)
precondition(maximumWorkResult.checksum > 0)

print(
    "DHT_MESSAGE_CALLBACK {"
        + "\"iterations_per_sample\":\(iterationCount),"
        + "\"samples\":\(sampleCount),"
        + "\"dense_node_count\":\(dense.nodeCount),"
        + "\"maximum_work_value_count\":500,"
        + "\"retained_allocation_bytes\":\(retainedAllocationJSON),"
        + "\"small_query\":\(smallResult.json),"
        + "\"dense_response\":\(denseResult.json),"
        + "\"maximum_work_response\":\(maximumWorkResult.json)"
        + "}"
)
