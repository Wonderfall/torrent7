import Dispatch
import Foundation
import TorrentMetainfo

struct Fixture {
  let name: String
  let bytes: Data
}

struct Measurement {
  let name: String
  let bytes: Int
  let iterations: Int
  let samples: Int
  let medianNS: Double
  let p95NS: Double
  let p99NS: Double
  let minimumNS: Double
  let maximumNS: Double
  let checksum: UInt64

  private var medianMessagesPerSecond: Double {
    1_000_000_000 / medianNS
  }

  private var medianBytesPerSecond: Double {
    Double(bytes) * medianMessagesPerSecond
  }

  var json: String {
    "{\"runtime\":\"swift\",\"name\":\"\(name)\",\"bytes\":\(bytes),"
      + "\"iterations\":\(iterations),\"samples\":\(samples),"
      + "\"median_ns\":\(medianNS),\"p95_ns\":\(p95NS),"
      + "\"p99_ns\":\(p99NS),"
      + "\"min_ns\":\(minimumNS),\"max_ns\":\(maximumNS),"
      + "\"median_messages_per_second\":\(medianMessagesPerSecond),"
      + "\"median_bytes_per_second\":\(medianBytesPerSecond),"
      + "\"checksum\":\(checksum)}"
  }
}

private func percentile(_ percentile: Int, in sortedValues: [Double]) -> Double {
  let index = ((percentile * sortedValues.count + 99) / 100) - 1
  return sortedValues[index]
}

@inline(never)
private func runBatch(
  iterations: Int,
  operation: () throws -> UInt64
) rethrows -> UInt64 {
  var checksum: UInt64 = 0
  for _ in 0..<iterations {
    checksum &+= try operation()
  }
  return checksum
}

private func measure(
  name: String,
  bytes: Int,
  iterations: Int,
  operation: () throws -> UInt64
) throws -> Measurement {
  let warmups = 3
  let samples = 20
  for _ in 0..<warmups {
    _ = try runBatch(iterations: iterations, operation: operation)
  }
  var values = [Double]()
  values.reserveCapacity(samples)
  var checksum: UInt64 = 0
  for _ in 0..<samples {
    let start = DispatchTime.now().uptimeNanoseconds
    checksum &+= try runBatch(iterations: iterations, operation: operation)
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    values.append(Double(elapsed) / Double(iterations))
  }
  values.sort()
  return Measurement(
    name: name,
    bytes: bytes,
    iterations: iterations,
    samples: samples,
    medianNS: values[values.count / 2],
    p95NS: percentile(95, in: values),
    p99NS: percentile(99, in: values),
    minimumNS: values[0],
    maximumNS: values[values.count - 1],
    checksum: checksum
  )
}

private func encodedString(_ value: Data) -> Data {
  Data("\(value.count):".utf8) + value
}

private func encodedString(_ value: String) -> Data {
  encodedString(Data(value.utf8))
}

private func encodedInteger(_ value: Int64) -> Data {
  Data("i\(value)e".utf8)
}

private func zeroPaddedDecimal(_ value: Int, width: Int) -> String {
  let digits = String(value)
  return String(repeating: "0", count: width - digits.count) + digits
}

private func encodedList(_ values: [Data]) -> Data {
  var result = Data([UInt8(ascii: "l")])
  for value in values {
    result.append(value)
  }
  result.append(UInt8(ascii: "e"))
  return result
}

private func encodedDictionary(_ fields: [(String, Data)]) -> Data {
  encodedDictionaryInOrder(
    fields.sorted {
      $0.0.utf8.lexicographicallyPrecedes($1.0.utf8)
    })
}

private func encodedDictionaryInOrder(_ fields: [(String, Data)]) -> Data {
  var result = Data([UInt8(ascii: "d")])
  for (key, value) in fields {
    result.append(encodedString(key))
    result.append(value)
  }
  result.append(UInt8(ascii: "e"))
  return result
}

private func pieceHashes(count: Int) -> Data {
  var result = Data(capacity: count * 20)
  for index in 0..<count {
    for offset in 0..<20 {
      result.append(UInt8(truncatingIfNeeded: index &+ offset &+ 1))
    }
  }
  return result
}

private func singleFileInfo() -> Data {
  let length = 256 * 1_024
  let pieceLength = 16 * 1_024
  return encodedDictionary([
    ("length", encodedInteger(Int64(length))),
    ("name", encodedString("payload.bin")),
    ("piece length", encodedInteger(Int64(pieceLength))),
    ("pieces", encodedString(pieceHashes(count: length / pieceLength))),
  ])
}

private func multiFileInfo(fileCount: Int) -> Data {
  let fileLength = 16 * 1_024
  var files = [Data]()
  files.reserveCapacity(fileCount)
  for index in 0..<fileCount {
    let indexText = String(index)
    let padding = String(repeating: "0", count: max(0, 5 - indexText.count))
    let name = "file-\(padding)\(indexText).bin"
    files.append(
      encodedDictionary([
        ("length", encodedInteger(Int64(fileLength))),
        ("path", encodedList([encodedString(name)])),
      ]))
  }
  return encodedDictionary([
    ("files", encodedList(files)),
    ("name", encodedString("benchmark-bundle")),
    ("piece length", encodedInteger(Int64(fileLength))),
    ("pieces", encodedString(pieceHashes(count: fileCount))),
    ("private", encodedInteger(1)),
  ])
}

private func torrentFile(info: Data, richEnvelope: Bool) -> Data {
  if !richEnvelope {
    return encodedDictionary([("info", info)])
  }
  let primary = "https://tracker.example/announce"
  let alternate = "udp://tracker.example:6969/announce"
  return encodedDictionary([
    ("announce", encodedString(primary)),
    (
      "announce-list",
      encodedList([
        encodedList([encodedString(primary)]),
        encodedList([encodedString(alternate)]),
      ])
    ),
    ("comment", encodedString("parser benchmark fixture")),
    ("created by", encodedString("Torrent7 benchmark")),
    ("creation date", encodedInteger(1_787_865_600)),
    ("info", info),
    ("url-list", encodedString("https://seed.example/payload")),
  ])
}

private func extensionHandshake() -> Data {
  encodedDictionary([
    ("complete_ago", encodedInteger(17)),
    (
      "m",
      encodedDictionary([
        ("lt_donthave", encodedInteger(5)),
        ("upload_only", encodedInteger(3)),
        ("ut_holepunch", encodedInteger(4)),
        ("ut_metadata", encodedInteger(1)),
        ("ut_pex", encodedInteger(2)),
      ])
    ),
    ("metadata_size", encodedInteger(2 * 1_024 * 1_024)),
    ("p", encodedInteger(51_413)),
    ("reqq", encodedInteger(250)),
    ("upload_only", encodedInteger(1)),
    ("v", encodedString("Torrent7 benchmark peer/1.0")),
    ("yourip", encodedString(Data([203, 0, 113, 9]))),
  ])
}

private func extensionHandshakeUnorderedMaximumKeys() -> Data {
  let commonPrefix = String(repeating: "x", count: 112)
  var fields = [(String, Data)]()
  fields.reserveCapacity(512)
  for index in (0..<512).reversed() {
    fields.append((commonPrefix + zeroPaddedDecimal(index, width: 8), encodedString(Data())))
  }
  return encodedDictionaryInOrder(fields)
}

private func metadataMessage() -> Data {
  var result = encodedDictionary([
    ("msg_type", encodedInteger(1)),
    ("piece", encodedInteger(7)),
    ("total_size", encodedInteger(2 * 1_024 * 1_024)),
  ])
  result.append(Data(repeating: 0xa5, count: 16 * 1_024))
  return result
}

private func compactIPv4Peers(start: Int, count: Int) -> Data {
  var result = Data(capacity: count * 6)
  for index in start..<(start + count) {
    result.append(contentsOf: [
      198,
      51,
      UInt8(truncatingIfNeeded: index / 250 + 1),
      UInt8(truncatingIfNeeded: index % 250 + 1),
    ])
    let port = UInt16(10_000 + index)
    result.append(UInt8(port >> 8))
    result.append(UInt8(port & 0xff))
  }
  return result
}

private func peerExchange() -> Data {
  encodedDictionary([
    ("added", encodedString(compactIPv4Peers(start: 0, count: 100))),
    ("added.f", encodedString(Data((0..<100).map { UInt8(truncatingIfNeeded: $0) }))),
    ("dropped", encodedString(compactIPv4Peers(start: 100, count: 100))),
  ])
}

private func trackerResponse(peerCount: Int) -> Data {
  encodedDictionary([
    ("complete", encodedInteger(812)),
    ("downloaded", encodedInteger(9_001)),
    ("incomplete", encodedInteger(117)),
    ("interval", encodedInteger(1_800)),
    ("min interval", encodedInteger(30)),
    ("peers", encodedString(compactIPv4Peers(start: 0, count: peerCount))),
    ("tracker id", encodedString("benchmark-tracker")),
    ("warning message", encodedString("scheduled maintenance")),
  ])
}

private func trackerUnorderedMaximumKeys() -> Data {
  let commonPrefix = String(repeating: "x", count: 952)
  var fields = [(String, Data)]()
  fields.reserveCapacity(512)
  for index in (0..<512).reversed() {
    let suffix = zeroPaddedDecimal(index, width: 8)
    fields.append((commonPrefix + suffix, encodedString(Data())))
  }
  return encodedDictionaryInOrder(fields)
}

private func dhtPing() -> Data {
  encodedDictionary([
    (
      "a",
      encodedDictionary([
        ("id", encodedString(Data(repeating: 1, count: 20)))
      ])
    ),
    ("q", encodedString("ping")),
    ("t", encodedString(Data([0, 1]))),
    ("y", encodedString("q")),
  ])
}

private func dhtDenseResponse() -> Data {
  var compactNodes = Data()
  var accepted = Data()
  for index in 0..<64 {
    compactNodes.append(Data(repeating: UInt8(truncatingIfNeeded: index + 1), count: 20))
    compactNodes.append(contentsOf: [203, 0, 113, UInt8(truncatingIfNeeded: index + 1)])
    compactNodes.append(contentsOf: [0x1a, UInt8(truncatingIfNeeded: 0xe1 + index)])
    let candidate = encodedDictionary([
      (
        "r",
        encodedDictionary([
          ("id", encodedString(Data(repeating: 2, count: 20))),
          ("nodes", encodedString(compactNodes)),
        ])
      ),
      ("t", encodedString(Data([0, 1]))),
      ("y", encodedString("r")),
    ])
    if candidate.count > 1_500 {
      break
    }
    accepted = candidate
  }
  return accepted
}

private func dhtMaximumWorkResponse() -> Data {
  encodedDictionary([
    (
      "r",
      encodedDictionary([
        ("id", encodedString(Data(repeating: 3, count: 20))),
        ("z", encodedList(Array(repeating: encodedString(Data()), count: 489))),
      ])
    ),
    ("t", encodedString(Data([0, 1]))),
    ("y", encodedString("r")),
  ])
}

private func dhtUnorderedMaximumKeys() -> Data {
  let commonPrefix = String(repeating: "x", count: 10)
  var fields = [(String, Data)]()
  fields.reserveCapacity(75)
  for index in (0..<72).reversed() {
    fields.append((commonPrefix + zeroPaddedDecimal(index, width: 4), encodedString(Data())))
  }
  fields.append(("y", encodedString("r")))
  fields.append(("t", encodedString(Data([0, 1]))))
  fields.append(
    (
      "r",
      encodedDictionary([("id", encodedString(Data(repeating: 4, count: 20)))])
    ))
  return encodedDictionaryInOrder(fields)
}

private func writeFixture(_ fixture: Fixture, to directory: URL) throws {
  try fixture.bytes.write(to: directory.appending(path: fixture.name), options: .atomic)
}

if CommandLine.arguments.count != 2
  && !(CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--fixtures-only")
{
  fatalError("usage: SwiftParserBenchmark FIXTURE_DIRECTORY [--fixtures-only]")
}
let fixturesOnly = CommandLine.arguments.count == 3
let outputDirectory = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let basicMagnet = "magnet:?xt=urn:btih:cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"
let richMagnet =
  "magnet:?xt=urn%3Abtih%3Acdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd&xt=urn%3Abtmh%3A1220abababababababababababababababababababababababababababababababab&dn=Torrent7%20benchmark&tr=https%3A%2F%2Ftracker.example%2Fannounce&tr=udp%3A%2F%2Ftracker.example%3A6969%2Fannounce&ws=https%3A%2F%2Fseed.example%2Fpayload&so=0-3,7,12-15"
let smallInfo = singleFileInfo()
let mediumInfo = multiFileInfo(fileCount: 128)
let stressInfo = multiFileInfo(fileCount: 4_096)
let smallTorrent = torrentFile(info: smallInfo, richEnvelope: false)
let mediumTorrent = torrentFile(info: mediumInfo, richEnvelope: true)
let stressTorrent = torrentFile(info: stressInfo, richEnvelope: true)
let handshake = extensionHandshake()
let unorderedHandshake = extensionHandshakeUnorderedMaximumKeys()
let metadata = metadataMessage()
let pex = peerExchange()
let tracker512 = trackerResponse(peerCount: 512)
let tracker3000 = trackerResponse(peerCount: 3_000)
let trackerUnordered = trackerUnorderedMaximumKeys()
let ping = dhtPing()
let denseDHT = dhtDenseResponse()
let maximumWorkDHT = dhtMaximumWorkResponse()
let unorderedDHT = dhtUnorderedMaximumKeys()

let fixtures = [
  Fixture(name: "magnet_basic.txt", bytes: Data(basicMagnet.utf8)),
  Fixture(name: "magnet_rich.txt", bytes: Data(richMagnet.utf8)),
  Fixture(name: "torrent_small.bin", bytes: smallTorrent),
  Fixture(name: "torrent_128.bin", bytes: mediumTorrent),
  Fixture(name: "torrent_4096.bin", bytes: stressTorrent),
  Fixture(name: "info_128.bin", bytes: mediumInfo),
  Fixture(name: "info_4096.bin", bytes: stressInfo),
  Fixture(name: "extension_handshake.bin", bytes: handshake),
  Fixture(name: "extension_unordered_maxkeys.bin", bytes: unorderedHandshake),
  Fixture(name: "ut_metadata.bin", bytes: metadata),
  Fixture(name: "ut_pex.bin", bytes: pex),
  Fixture(name: "tracker_512.bin", bytes: tracker512),
  Fixture(name: "tracker_3000.bin", bytes: tracker3000),
  Fixture(name: "tracker_unordered_maxkeys.bin", bytes: trackerUnordered),
  Fixture(name: "dht_ping.bin", bytes: ping),
  Fixture(name: "dht_dense.bin", bytes: denseDHT),
  Fixture(name: "dht_maxwork.bin", bytes: maximumWorkDHT),
  Fixture(name: "dht_unordered_maxkeys.bin", bytes: unorderedDHT),
]
for fixture in fixtures {
  try writeFixture(fixture, to: outputDirectory)
}

if !fixturesOnly {
  let metainfoParser = TorrentMetainfoParser()
  let peerParser = TorrentPeerProtocolParser()
  let trackerParser = TorrentHTTPTrackerResponseParser()
  let dhtParser = TorrentDHTMessageParser()

  var measurements = [Measurement]()
  measurements.append(
    try measure(name: "magnet_basic", bytes: basicMagnet.utf8.count, iterations: 50_000) {
      let value = try ParsedMagnet.parse(basicMagnet)
      return UInt64(value.v1InfoHash?.count ?? 0) + UInt64(value.trackers.count)
    })
  measurements.append(
    try measure(name: "magnet_rich", bytes: richMagnet.utf8.count, iterations: 20_000) {
      let value = try ParsedMagnet.parse(richMagnet)
      return UInt64(value.v1InfoHash?.count ?? 0)
        + UInt64(value.v2InfoHash?.count ?? 0)
        + UInt64(value.trackers.count)
        + UInt64(value.webSeeds.count)
        + UInt64(value.fileSelections?.count ?? 0)
    })
  measurements.append(
    try measure(name: "torrent_small", bytes: smallTorrent.count, iterations: 5_000) {
      let value = try metainfoParser.parse(smallTorrent)
      return UInt64(value.infoCore.files.count) + UInt64(value.infoCore.totalSize)
    })
  measurements.append(
    try measure(name: "torrent_128", bytes: mediumTorrent.count, iterations: 500) {
      let value = try metainfoParser.parse(mediumTorrent)
      return UInt64(value.infoCore.files.count)
        + UInt64(value.infoCore.totalSize)
        + UInt64(value.envelope.trackers.count)
    })
  measurements.append(
    try measure(name: "torrent_4096", bytes: stressTorrent.count, iterations: 20) {
      let value = try metainfoParser.parse(stressTorrent)
      return UInt64(value.infoCore.files.count)
        + UInt64(value.infoCore.totalSize)
        + UInt64(value.envelope.trackers.count)
    })
  measurements.append(
    try measure(name: "info_128", bytes: mediumInfo.count, iterations: 500) {
      let value = try metainfoParser.parseInfoDictionary(mediumInfo)
      return UInt64(value.infoCore.files.count) + UInt64(value.infoCore.totalSize)
    })
  measurements.append(
    try measure(name: "info_4096", bytes: stressInfo.count, iterations: 20) {
      let value = try metainfoParser.parseInfoDictionary(stressInfo)
      return UInt64(value.infoCore.files.count) + UInt64(value.infoCore.totalSize)
    })
  measurements.append(
    try measure(name: "extension_handshake", bytes: handshake.count, iterations: 30_000) {
      let value = try peerParser.parseExtensionHandshake(handshake)
      return UInt64(value.utMetadataID ?? 0)
        + UInt64(value.utPEXID ?? 0)
        + UInt64(value.clientVersionUTF8?.count ?? 0)
        + UInt64(value.listenPort ?? 0)
    })
  measurements.append(
    try measure(
      name: "extension_unordered_maxkeys",
      bytes: unorderedHandshake.count,
      iterations: 200
    ) {
      let value = try peerParser.parseExtensionHandshake(unorderedHandshake)
      return UInt64(value.utMetadataID ?? 0) + UInt64(value.clientVersionUTF8?.count ?? 0)
    })
  measurements.append(
    try measure(name: "ut_metadata", bytes: metadata.count, iterations: 30_000) {
      let value = try peerParser.parseMetadataControlMessage(metadata)
      return UInt64(value.piece) + UInt64(value.payloadOffset) + UInt64(value.payloadSize)
    })
  measurements.append(
    try measure(name: "ut_pex", bytes: pex.count, iterations: 3_000) {
      let value = try peerParser.parsePeerExchange(pex)
      return UInt64(value.contacts.count)
        + UInt64(value.addedCount)
        + UInt64(value.droppedCount)
        + UInt64(value.contacts.last?.port ?? 0)
    })
  measurements.append(
    try measure(name: "tracker_512", bytes: tracker512.count, iterations: 3_000) {
      let value = try trackerParser.parse(tracker512)
      return UInt64(value.peers.count) + UInt64(value.interval) + UInt64(value.complete)
    })
  measurements.append(
    try measure(name: "tracker_3000", bytes: tracker3000.count, iterations: 500) {
      let value = try trackerParser.parse(tracker3000)
      return UInt64(value.peers.count) + UInt64(value.interval) + UInt64(value.complete)
    })
  measurements.append(
    try measure(
      name: "tracker_unordered_maxkeys",
      bytes: trackerUnordered.count,
      iterations: 20
    ) {
      let value = try trackerParser.parse(trackerUnordered)
      return UInt64(value.peers.count) + UInt64(value.interval)
    })
  measurements.append(
    try measure(name: "dht_ping", bytes: ping.count, iterations: 50_000) {
      let value = try dhtParser.parse(ping, sourceFamily: .ipv4)
      return UInt64(value.kind.rawValue) + UInt64(value.queryKind.rawValue)
    })
  measurements.append(
    try measure(name: "dht_dense", bytes: denseDHT.count, iterations: 5_000) {
      let value = try dhtParser.parse(denseDHT, sourceFamily: .ipv4)
      return UInt64(value.kind.rawValue)
        + UInt64(value.nodes.count)
        + UInt64(value.nodes.last?.port ?? 0)
    })
  measurements.append(
    try measure(name: "dht_maxwork", bytes: maximumWorkDHT.count, iterations: 2_000) {
      let value = try dhtParser.parse(maximumWorkDHT, sourceFamily: .ipv4)
      return UInt64(value.kind.rawValue) + UInt64(value.nodeIDRange?.count ?? 0)
    })
  measurements.append(
    try measure(name: "dht_unordered_maxkeys", bytes: unorderedDHT.count, iterations: 1_000) {
      let value = try dhtParser.parse(unorderedDHT, sourceFamily: .ipv4)
      return UInt64(value.kind.rawValue) + UInt64(value.nodeIDRange?.count ?? 0)
    })

  for measurement in measurements {
    print(measurement.json)
  }
}
