import Foundation

package enum TorrentDHTMessageError: Error, Equatable, Sendable {
    case emptyMessage
    case messageTooLarge
    case malformedBencoding
    case workLimitExceeded
    case invalidEnvelope
    case tooManyNodes
    case tooManyPeers
}

package enum TorrentDHTMessageKind: UInt8, Equatable, Sendable {
    case query = 1
    case response = 2
    case error = 3
}

package enum TorrentDHTQueryKind: UInt8, Equatable, Sendable {
    case none = 0
    case ping = 1
    case findNode = 2
    case getPeers = 3
    case announcePeer = 4
    case sampleInfohashes = 5
    case getItem = 6
    case putItem = 7
    case unknown = 255
}

package struct TorrentDHTNode: Equatable, Sendable {
    package let idRange: Range<Int>
    package let address: TorrentPeerAddress
    package let port: UInt16
}

package struct TorrentDHTEndpoint: Equatable, Sendable {
    package let address: TorrentPeerAddress
    package let port: UInt16
}

/// A typed view of one inbound KRPC datagram. Ranges refer to `body`, which
/// owns the exact bytes scanned by the parser. Stateful routing, transaction,
/// token, endpoint, and admission decisions intentionally remain native.
package struct TorrentDHTMessage: Equatable, Sendable {
    package let body: Data
    package let kind: TorrentDHTMessageKind
    package let queryKind: TorrentDHTQueryKind
    package let queryIsValid: Bool
    package let transactionRange: Range<Int>?
    package let queryNameRange: Range<Int>?
    package let nodeIDRange: Range<Int>?
    package let targetRange: Range<Int>?
    package let tokenRange: Range<Int>?
    package let nameRange: Range<Int>?
    package let errorMessageRange: Range<Int>?
    package let errorCode: Int32?
    package let externalAddress: TorrentPeerAddress?
    package let port: UInt16?
    package let readOnly: Bool
    package let noseed: Bool
    package let scrape: Bool
    package let seed: Bool
    package let impliedPort: Bool
    package let wantsSpecified: Bool
    package let wantsIPv4: Bool
    package let wantsIPv6: Bool
    package let interval: Int32?
    package let totalInfoHashCount: Int32?
    package let sampleHashesRange: Range<Int>?
    package let sampleCount: Int
    package let nodes: [TorrentDHTNode]
    package let peersPresent: Bool
    package let peers: [TorrentDHTEndpoint]
}

/// Bounded, schema-directed parsing for one complete inbound DHT KRPC
/// datagram. The accepted dialect is canonical bencoding. BEP 44 item get/put
/// messages are identified but deliberately not decoded because Torrent7 uses
/// DHT only for peer discovery.
package struct TorrentDHTMessageParser: Sendable {
    package struct Limits: Equatable, Sendable {
        package var maximumMessageBytes = 1_500
        package var maximumNodeCount = 64
        package var maximumPeerCount = 256
        package var maximumSampleCount = 64
        package var maximumTransactionBytes = 64
        package var maximumQueryNameBytes = 32
        package var maximumTokenBytes = 64
        package var maximumAnnouncedNameBytes = 255
        package var maximumErrorMessageBytes = 256
        package var maximumNestingDepth = 10
        package var maximumValueCount = 500
        package var maximumContainerCount = 128
        package var maximumDictionaryKeyBytes = 1_500
        package var maximumIntegerDigits = 19
        package var maximumStringLengthDigits = 19

        package static let standard = Limits()
    }

    private struct QueryFields {
        var kind = TorrentDHTQueryKind.none
        var isValid = false
        var nameRange: Range<Int>?
        var nodeIDRange: Range<Int>?
        var targetRange: Range<Int>?
        var tokenRange: Range<Int>?
        var announcedNameRange: Range<Int>?
        var port: UInt16?
        var readOnly = false
        var noseed = false
        var scrape = false
        var seed = false
        var impliedPort = false
        var wantsSpecified = false
        var wantsIPv4 = false
        var wantsIPv6 = false
    }

    private struct ResponseFields {
        var nodeIDRange: Range<Int>?
        var tokenRange: Range<Int>?
        var interval: Int32?
        var totalInfoHashCount: Int32?
        var sampleHashesRange: Range<Int>?
        var sampleCount = 0
        var nodes = [TorrentDHTNode]()
        var peersPresent = false
        var peers = [TorrentDHTEndpoint]()
    }

    private struct ErrorFields {
        var code: Int32?
        var messageRange: Range<Int>?
    }

    private struct WantFields {
        var isValid = true
        var isSpecified = false
        var wantsIPv4 = false
        var wantsIPv6 = false
    }

    private let limits: Limits

    package init(limits: Limits = .standard) {
        self.limits = limits
    }

    package func parse(
        _ bytes: Data,
        sourceFamily: TorrentPeerAddressFamily
    ) throws -> TorrentDHTMessage {
        guard limitsAreValid else {
            throw TorrentDHTMessageError.workLimitExceeded
        }
        guard !bytes.isEmpty else {
            throw TorrentDHTMessageError.emptyMessage
        }
        guard bytes.count <= limits.maximumMessageBytes else {
            throw TorrentDHTMessageError.messageTooLarge
        }

        let document: BencodeRangeDocument
        do {
            document = try BencodeRangeDocument.scan(bytes, limits: scannerLimits)
        } catch let error as BencodeScanError {
            throw scanError(error)
        } catch {
            throw TorrentDHTMessageError.malformedBencoding
        }
        let root = document.rootIndex
        guard document.kind(at: root) == .dictionary,
              let kindValue = document.value(named: "y", inDictionaryAt: root),
              let kindRange = document.stringRange(at: kindValue),
              kindRange.count == 1 else {
            throw TorrentDHTMessageError.invalidEnvelope
        }

        let kind: TorrentDHTMessageKind
        switch document.data[kindRange.lowerBound] {
        case UInt8(ascii: "q"):
            kind = .query
        case UInt8(ascii: "r"):
            kind = .response
        case UInt8(ascii: "e"):
            kind = .error
        default:
            throw TorrentDHTMessageError.invalidEnvelope
        }

        let transactionRange = boundedOptionalString(
            named: "t",
            in: root,
            document: document,
            maximumBytes: limits.maximumTransactionBytes
        )
        let externalAddress = compactEndpoint(
            named: "ip",
            in: root,
            document: document
        )?.address

        var query = QueryFields()
        var response = ResponseFields()
        var krpcError = ErrorFields()
        switch kind {
        case .query:
            query = parseQuery(in: root, document: document)
        case .response:
            response = try parseResponse(
                in: root,
                sourceFamily: sourceFamily,
                document: document
            )
        case .error:
            krpcError = parseError(in: root, document: document)
        }

        return TorrentDHTMessage(
            body: document.data,
            kind: kind,
            queryKind: query.kind,
            queryIsValid: kind != .query || query.isValid,
            transactionRange: transactionRange,
            queryNameRange: query.nameRange,
            nodeIDRange: kind == .query ? query.nodeIDRange : response.nodeIDRange,
            targetRange: query.targetRange,
            tokenRange: kind == .query ? query.tokenRange : response.tokenRange,
            nameRange: query.announcedNameRange,
            errorMessageRange: krpcError.messageRange,
            errorCode: krpcError.code,
            externalAddress: externalAddress,
            port: query.port,
            readOnly: query.readOnly,
            noseed: query.noseed,
            scrape: query.scrape,
            seed: query.seed,
            impliedPort: query.impliedPort,
            wantsSpecified: query.wantsSpecified,
            wantsIPv4: query.wantsIPv4,
            wantsIPv6: query.wantsIPv6,
            interval: response.interval,
            totalInfoHashCount: response.totalInfoHashCount,
            sampleHashesRange: response.sampleHashesRange,
            sampleCount: response.sampleCount,
            nodes: response.nodes,
            peersPresent: response.peersPresent,
            peers: response.peers
        )
    }

    private var scannerLimits: BencodeScanLimits {
        BencodeScanLimits(
            maximumNestingDepth: limits.maximumNestingDepth,
            maximumValueCount: limits.maximumValueCount,
            maximumStringBytes: limits.maximumMessageBytes,
            maximumContainerCount: limits.maximumContainerCount,
            maximumDictionaryKeyBytes: limits.maximumDictionaryKeyBytes,
            maximumIntegerDigits: limits.maximumIntegerDigits,
            maximumStringLengthDigits: limits.maximumStringLengthDigits
        )
    }

    private var limitsAreValid: Bool {
        let maximum = Limits.standard
        return limits.maximumMessageBytes > 0
            && limits.maximumMessageBytes <= maximum.maximumMessageBytes
            && limits.maximumNodeCount >= 0
            && limits.maximumNodeCount <= maximum.maximumNodeCount
            && limits.maximumPeerCount >= 0
            && limits.maximumPeerCount <= maximum.maximumPeerCount
            && limits.maximumSampleCount >= 0
            && limits.maximumSampleCount <= maximum.maximumSampleCount
            && limits.maximumTransactionBytes >= 0
            && limits.maximumTransactionBytes <= maximum.maximumTransactionBytes
            && limits.maximumQueryNameBytes > 0
            && limits.maximumQueryNameBytes <= maximum.maximumQueryNameBytes
            && limits.maximumTokenBytes >= 0
            && limits.maximumTokenBytes <= maximum.maximumTokenBytes
            && limits.maximumAnnouncedNameBytes >= 0
            && limits.maximumAnnouncedNameBytes <= maximum.maximumAnnouncedNameBytes
            && limits.maximumErrorMessageBytes >= 0
            && limits.maximumErrorMessageBytes <= maximum.maximumErrorMessageBytes
            && limits.maximumNestingDepth >= 0
            && limits.maximumNestingDepth <= maximum.maximumNestingDepth
            && limits.maximumValueCount > 0
            && limits.maximumValueCount <= maximum.maximumValueCount
            && limits.maximumContainerCount >= 0
            && limits.maximumContainerCount <= maximum.maximumContainerCount
            && limits.maximumDictionaryKeyBytes >= 0
            && limits.maximumDictionaryKeyBytes <= maximum.maximumDictionaryKeyBytes
            && limits.maximumIntegerDigits > 0
            && limits.maximumIntegerDigits <= maximum.maximumIntegerDigits
            && limits.maximumStringLengthDigits > 0
            && limits.maximumStringLengthDigits <= maximum.maximumStringLengthDigits
    }

    private func parseQuery(
        in root: Int,
        document: BencodeRangeDocument
    ) -> QueryFields {
        var fields = QueryFields()
        guard let queryValue = document.value(named: "q", inDictionaryAt: root),
              let queryRange = document.stringRange(at: queryValue),
              !queryRange.isEmpty,
              queryRange.count <= limits.maximumQueryNameBytes else {
            return fields
        }
        fields.nameRange = queryRange
        fields.kind = queryKind(document.data[queryRange])

        guard let arguments = document.value(named: "a", inDictionaryAt: root),
              document.kind(at: arguments) == .dictionary else {
            return fields
        }

        var valid = true
        fields.nodeIDRange = exactString(
            named: "id",
            count: 20,
            in: arguments,
            document: document
        )
        valid = fields.nodeIDRange != nil

        let readOnly = optionalInteger(named: "ro", in: root, document: document)
        valid = valid && readOnly.isValid
        fields.readOnly = readOnly.value.map { $0 != 0 } ?? false

        switch fields.kind {
        case .ping:
            break
        case .findNode, .sampleInfohashes:
            fields.targetRange = exactString(
                named: "target",
                count: 20,
                in: arguments,
                document: document
            )
            valid = valid && fields.targetRange != nil
            let wants = parseWant(in: arguments, document: document)
            valid = valid && wants.isValid
            fields.wantsSpecified = wants.isSpecified
            fields.wantsIPv4 = wants.wantsIPv4
            fields.wantsIPv6 = wants.wantsIPv6
        case .getPeers:
            fields.targetRange = exactString(
                named: "info_hash",
                count: 20,
                in: arguments,
                document: document
            )
            valid = valid && fields.targetRange != nil
            let noseed = optionalInteger(
                named: "noseed",
                in: arguments,
                document: document
            )
            let scrape = optionalInteger(
                named: "scrape",
                in: arguments,
                document: document
            )
            valid = valid && noseed.isValid && scrape.isValid
            fields.noseed = noseed.value.map { $0 != 0 } ?? false
            fields.scrape = scrape.value.map { $0 != 0 } ?? false
            let wants = parseWant(in: arguments, document: document)
            valid = valid && wants.isValid
            fields.wantsSpecified = wants.isSpecified
            fields.wantsIPv4 = wants.wantsIPv4
            fields.wantsIPv6 = wants.wantsIPv6
        case .announcePeer:
            fields.targetRange = exactString(
                named: "info_hash",
                count: 20,
                in: arguments,
                document: document
            )
            valid = valid && fields.targetRange != nil
            if let portValue = document.value(named: "port", inDictionaryAt: arguments),
               let integer = document.integer(at: portValue),
               let port = UInt16(exactly: integer) {
                fields.port = port
            } else {
                valid = false
            }
            fields.tokenRange = boundedRequiredString(
                named: "token",
                in: arguments,
                document: document,
                maximumBytes: limits.maximumTokenBytes
            )
            valid = valid && fields.tokenRange != nil

            let name = boundedOptionalHumanString(
                named: "n",
                in: arguments,
                document: document,
                maximumBytes: limits.maximumAnnouncedNameBytes
            )
            valid = valid && name.isValid
            fields.announcedNameRange = name.range

            let seed = optionalInteger(named: "seed", in: arguments, document: document)
            let impliedPort = optionalInteger(
                named: "implied_port",
                in: arguments,
                document: document
            )
            valid = valid && seed.isValid && impliedPort.isValid
            fields.seed = seed.value.map { $0 != 0 } ?? false
            fields.impliedPort = impliedPort.value.map { $0 != 0 } ?? false
        case .unknown:
            fields.targetRange = exactString(
                named: "target",
                count: 20,
                in: arguments,
                document: document
            ) ?? exactString(
                named: "info_hash",
                count: 20,
                in: arguments,
                document: document
            )
            valid = valid && fields.targetRange != nil
            let wants = parseWant(in: arguments, document: document)
            valid = valid && wants.isValid
            fields.wantsSpecified = wants.isSpecified
            fields.wantsIPv4 = wants.wantsIPv4
            fields.wantsIPv6 = wants.wantsIPv6
        case .getItem, .putItem:
            // The envelope is still typed so native code can return a bounded
            // unsupported-method error without decoding the arbitrary item.
            break
        case .none:
            valid = false
        }
        fields.isValid = valid
        return fields
    }

    private func parseResponse(
        in root: Int,
        sourceFamily: TorrentPeerAddressFamily,
        document: BencodeRangeDocument
    ) throws -> ResponseFields {
        var fields = ResponseFields()
        guard let response = document.value(named: "r", inDictionaryAt: root),
              document.kind(at: response) == .dictionary else {
            return fields
        }
        fields.nodeIDRange = exactString(
            named: "id",
            count: 20,
            in: response,
            document: document
        )
        fields.tokenRange = boundedOptionalString(
            named: "token",
            in: response,
            document: document,
            maximumBytes: limits.maximumTokenBytes
        )
        try appendNodes(
            named: "nodes",
            family: .ipv4,
            stride: 26,
            in: response,
            document: document,
            nodes: &fields.nodes
        )
        try appendNodes(
            named: "nodes6",
            family: .ipv6,
            stride: 38,
            in: response,
            document: document,
            nodes: &fields.nodes
        )
        if let values = document.value(named: "values", inDictionaryAt: response),
           document.kind(at: values) == .list {
            fields.peersPresent = true
            fields.peers = try parsePeers(
                in: response,
                sourceFamily: sourceFamily,
                document: document
            )
        }
        fields.interval = nonnegativeInt32(
            named: "interval",
            in: response,
            document: document
        )
        fields.totalInfoHashCount = nonnegativeInt32(
            named: "num",
            in: response,
            document: document
        )
        if let samples = document.value(named: "samples", inDictionaryAt: response),
           let range = document.stringRange(at: samples),
           range.count.isMultiple(of: 20),
           range.count / 20 <= limits.maximumSampleCount {
            fields.sampleHashesRange = range
            fields.sampleCount = range.count / 20
        }
        return fields
    }

    private func parseError(
        in root: Int,
        document: BencodeRangeDocument
    ) -> ErrorFields {
        guard let errorValue = document.value(named: "e", inDictionaryAt: root),
              document.kind(at: errorValue) == .list,
              let codeValue = document.firstChild(of: errorValue),
              let messageValue = document.nextSibling(of: codeValue),
              let code = document.integer(at: codeValue),
              let exactCode = Int32(exactly: code),
              let messageRange = document.stringRange(at: messageValue),
              messageRange.count <= limits.maximumErrorMessageBytes,
              isHumanReadable(document.data[messageRange]) else {
            return ErrorFields()
        }
        return ErrorFields(code: exactCode, messageRange: messageRange)
    }

    private func parseWant(
        in arguments: Int,
        document: BencodeRangeDocument
    ) -> WantFields {
        guard let value = document.value(named: "want", inDictionaryAt: arguments) else {
            return WantFields()
        }
        guard document.kind(at: value) == .list else {
            return WantFields(isValid: false, isSpecified: true)
        }
        var fields = WantFields(isSpecified: true)
        var child = document.firstChild(of: value)
        while let index = child {
            if let range = document.stringRange(at: index) {
                if document.bytes(in: range, equalTo: "n4".utf8) {
                    fields.wantsIPv4 = true
                } else if document.bytes(in: range, equalTo: "n6".utf8) {
                    fields.wantsIPv6 = true
                }
            }
            child = document.nextSibling(of: index)
        }
        return fields
    }

    private func appendNodes(
        named name: String,
        family: TorrentPeerAddressFamily,
        stride: Int,
        in response: Int,
        document: BencodeRangeDocument,
        nodes: inout [TorrentDHTNode]
    ) throws {
        guard let value = document.value(named: name, inDictionaryAt: response),
              let range = document.stringRange(at: value) else {
            return
        }
        let completeCount = range.count / stride
        guard completeCount <= limits.maximumNodeCount - nodes.count else {
            throw TorrentDHTMessageError.tooManyNodes
        }
        nodes.reserveCapacity(nodes.count + completeCount)
        let addressSize = family == .ipv4 ? 4 : 16
        var offset = range.lowerBound
        for _ in 0..<completeCount {
            let idRange = offset..<(offset + 20)
            let addressOffset = idRange.upperBound
            let addressRange = addressOffset..<(addressOffset + addressSize)
            let portOffset = addressRange.upperBound
            nodes.append(TorrentDHTNode(
                idRange: idRange,
                address: decodeAddress(document.data[addressRange], family: family),
                port: decodePort(document.data, at: portOffset)
            ))
            offset += stride
        }
    }

    private func parsePeers(
        in response: Int,
        sourceFamily: TorrentPeerAddressFamily,
        document: BencodeRangeDocument
    ) throws -> [TorrentDHTEndpoint] {
        guard let value = document.value(named: "values", inDictionaryAt: response),
              document.kind(at: value) == .list else {
            return []
        }
        var peers = [TorrentDHTEndpoint]()
        let childCount = document.childCount(of: value)
        let first = document.firstChild(of: value)
        if sourceFamily == .ipv4,
           childCount == 1,
           let first,
           let range = document.stringRange(at: first) {
            peers.reserveCapacity(min(range.count / 6, limits.maximumPeerCount))
            var offset = range.lowerBound
            while range.upperBound - offset >= 6 {
                try appendEndpoint(
                    document.data[offset..<(offset + 6)],
                    family: .ipv4,
                    to: &peers
                )
                offset += 6
            }
            return peers
        }

        peers.reserveCapacity(min(childCount, limits.maximumPeerCount))
        var child = first
        while let index = child {
            guard let range = document.stringRange(at: index) else {
                return []
            }
            switch range.count {
            case 6:
                try appendEndpoint(document.data[range], family: .ipv4, to: &peers)
            case 18:
                try appendEndpoint(document.data[range], family: .ipv6, to: &peers)
            default:
                break
            }
            child = document.nextSibling(of: index)
        }
        return peers
    }

    private func appendEndpoint(
        _ bytes: Data.SubSequence,
        family: TorrentPeerAddressFamily,
        to peers: inout [TorrentDHTEndpoint]
    ) throws {
        guard peers.count < limits.maximumPeerCount else {
            throw TorrentDHTMessageError.tooManyPeers
        }
        let addressSize = family == .ipv4 ? 4 : 16
        let addressBytes = bytes.prefix(addressSize)
        peers.append(TorrentDHTEndpoint(
            address: decodeAddress(addressBytes, family: family),
            port: decodePort(bytes, at: bytes.startIndex + addressSize)
        ))
    }

    private func compactEndpoint(
        named name: String,
        in dictionary: Int,
        document: BencodeRangeDocument
    ) -> TorrentDHTEndpoint? {
        guard let value = document.value(named: name, inDictionaryAt: dictionary),
              let range = document.stringRange(at: value) else {
            return nil
        }
        let family: TorrentPeerAddressFamily
        switch range.count {
        case 6:
            family = .ipv4
        case 18:
            family = .ipv6
        default:
            return nil
        }
        let addressSize = family == .ipv4 ? 4 : 16
        return TorrentDHTEndpoint(
            address: decodeAddress(
                document.data[range.lowerBound..<(range.lowerBound + addressSize)],
                family: family
            ),
            port: decodePort(document.data, at: range.lowerBound + addressSize)
        )
    }

    private func queryKind(_ bytes: Data.SubSequence) -> TorrentDHTQueryKind {
        if bytes.elementsEqual("ping".utf8) {
            return .ping
        }
        if bytes.elementsEqual("find_node".utf8) {
            return .findNode
        }
        if bytes.elementsEqual("get_peers".utf8) {
            return .getPeers
        }
        if bytes.elementsEqual("announce_peer".utf8) {
            return .announcePeer
        }
        if bytes.elementsEqual("sample_infohashes".utf8) {
            return .sampleInfohashes
        }
        if bytes.elementsEqual("get".utf8) {
            return .getItem
        }
        if bytes.elementsEqual("put".utf8) {
            return .putItem
        }
        return .unknown
    }

    private func exactString(
        named name: String,
        count: Int,
        in dictionary: Int,
        document: BencodeRangeDocument
    ) -> Range<Int>? {
        guard let value = document.value(named: name, inDictionaryAt: dictionary),
              let range = document.stringRange(at: value),
              range.count == count else {
            return nil
        }
        return range
    }

    private func boundedRequiredString(
        named name: String,
        in dictionary: Int,
        document: BencodeRangeDocument,
        maximumBytes: Int
    ) -> Range<Int>? {
        guard let value = document.value(named: name, inDictionaryAt: dictionary),
              let range = document.stringRange(at: value),
              range.count <= maximumBytes else {
            return nil
        }
        return range
    }

    private func boundedOptionalString(
        named name: String,
        in dictionary: Int,
        document: BencodeRangeDocument,
        maximumBytes: Int
    ) -> Range<Int>? {
        guard let value = document.value(named: name, inDictionaryAt: dictionary),
              let range = document.stringRange(at: value),
              range.count <= maximumBytes else {
            return nil
        }
        return range
    }

    private func boundedOptionalHumanString(
        named name: String,
        in dictionary: Int,
        document: BencodeRangeDocument,
        maximumBytes: Int
    ) -> (range: Range<Int>?, isValid: Bool) {
        guard let value = document.value(named: name, inDictionaryAt: dictionary) else {
            return (nil, true)
        }
        guard let range = document.stringRange(at: value),
              range.count <= maximumBytes,
              isHumanReadable(document.data[range]) else {
            return (nil, false)
        }
        return (range, true)
    }

    private func optionalInteger(
        named name: String,
        in dictionary: Int,
        document: BencodeRangeDocument
    ) -> (value: Int64?, isValid: Bool) {
        guard let value = document.value(named: name, inDictionaryAt: dictionary) else {
            return (nil, true)
        }
        guard let integer = document.integer(at: value) else {
            return (nil, false)
        }
        return (integer, true)
    }

    private func nonnegativeInt32(
        named name: String,
        in dictionary: Int,
        document: BencodeRangeDocument
    ) -> Int32? {
        guard let value = document.value(named: name, inDictionaryAt: dictionary),
              let integer = document.integer(at: value),
              integer >= 0 else {
            return nil
        }
        return Int32(exactly: integer)
    }

    private func isHumanReadable(_ bytes: Data.SubSequence) -> Bool {
        !bytes.contains(0) && String(data: Data(bytes), encoding: .utf8) != nil
    }

    private func decodeAddress(
        _ bytes: Data.SubSequence,
        family: TorrentPeerAddressFamily
    ) -> TorrentPeerAddress {
        if family == .ipv4 {
            let low = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            return TorrentPeerAddress(family: .ipv4, high: 0, low: low)
        }
        var high: UInt64 = 0
        var low: UInt64 = 0
        for byte in bytes.prefix(8) {
            high = (high << 8) | UInt64(byte)
        }
        for byte in bytes.suffix(8) {
            low = (low << 8) | UInt64(byte)
        }
        return TorrentPeerAddress(family: .ipv6, high: high, low: low)
    }

    private func decodePort<C: Collection>(
        _ bytes: C,
        at offset: C.Index
    ) -> UInt16 where C.Element == UInt8 {
        let next = bytes.index(after: offset)
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[next])
    }

    private func scanError(_ error: BencodeScanError) -> TorrentDHTMessageError {
        switch error {
        case .malformed:
            .malformedBencoding
        case .nestingLimitExceeded,
             .valueLimitExceeded,
             .stringLimitExceeded,
             .containerLimitExceeded,
             .dictionaryKeyByteLimitExceeded,
             .integerDigitLimitExceeded,
             .stringLengthDigitLimitExceeded:
            .workLimitExceeded
        }
    }
}
