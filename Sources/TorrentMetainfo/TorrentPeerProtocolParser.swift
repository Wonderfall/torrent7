package import Foundation

package enum TorrentPeerProtocolError: Error, Equatable, Sendable {
    case emptyMessage
    case messageTooLarge
    case malformedBencoding
    case workLimitExceeded
    case invalidField
    case tooManyPeerExchangeContacts
    case duplicatePeerExchangeContact
}

package enum TorrentPeerAddressFamily: UInt8, Equatable, Hashable, Sendable {
    case ipv4 = 4
    case ipv6 = 6
}

package struct TorrentPeerAddress: Equatable, Hashable, Sendable {
    package let family: TorrentPeerAddressFamily
    package let high: UInt64
    package let low: UInt64

    package init(family: TorrentPeerAddressFamily, high: UInt64, low: UInt64) {
        self.family = family
        self.high = high
        self.low = low
    }
}

package struct TorrentExtensionHandshakeUpdate: Equatable, Sendable {
    package let utMetadataID: UInt8?
    package let utPEXID: UInt8?
    package let uploadOnlyID: UInt8?
    package let holepunchID: UInt8?
    package let dontHaveID: UInt8?
    package let metadataSize: Int32?
    package let listenPort: UInt16?
    package let lastSeenComplete: Int32?
    package let requestQueueLimit: UInt16?
    package let clientVersionUTF8: Data?
    package let externalAddress: TorrentPeerAddress?
    package let uploadOnly: Bool?
}

package enum TorrentMetadataMessageKind: UInt8, Equatable, Sendable {
    case request = 0
    case data = 1
    case reject = 2
    case unknown = 255
}

package struct TorrentMetadataControlMessage: Equatable, Sendable {
    package let kind: TorrentMetadataMessageKind
    package let rawMessageType: Int64
    package let piece: Int32
    package let totalSize: Int32?
    package let payloadOffset: Int32
    package let payloadSize: Int32
}

package enum TorrentPeerExchangeAction: UInt8, Equatable, Sendable {
    case add = 1
    case drop = 2
}

package struct TorrentPeerExchangeContact: Equatable, Sendable {
    package let address: TorrentPeerAddress
    package let port: UInt16
    package let action: TorrentPeerExchangeAction
    package let flags: UInt8
}

package struct TorrentPeerExchangeMessage: Equatable, Sendable {
    package let contacts: [TorrentPeerExchangeContact]
    package let addedCount: Int
    package let droppedCount: Int
}

/// Bounded, schema-directed parsing for the peer-controlled bencoded messages
/// still carried by libtorrent's extension protocol. Connection state and all
/// admission policy remain native; these values contain syntax only.
package struct TorrentPeerProtocolParser: Sendable {
    private struct PeerExchangeEndpointKey: Hashable {
        let address: TorrentPeerAddress
        let port: UInt16
    }

    package struct Limits: Equatable, Sendable {
        package var maximumHandshakeBytes = 64 * 1_024
        package var maximumMetadataMessageBytes = 17 * 1_024
        package var maximumPeerExchangeBytes = 500 * 1_024
        package var maximumClientVersionBytes = 256
        package var maximumMetadataBytes = 4 * 1_024 * 1_024
        package var maximumInitialAddedContacts = 100
        package var maximumInitialDroppedContacts = 100
        package var maximumNestingDepth = 8
        package var maximumValueCount = 2_048
        package var maximumContainerCount = 512
        package var maximumDictionaryKeyBytes = 64 * 1_024
        package var maximumIntegerDigits = 19
        package var maximumStringLengthDigits = 19

        package static let standard = Limits()
    }

    private let limits: Limits

    package init(limits: Limits = .standard) {
        self.limits = limits
    }

    package func parseExtensionHandshake(
        _ bytes: Data
    ) throws -> TorrentExtensionHandshakeUpdate {
        let document = try scanComplete(
            bytes,
            maximumBytes: limits.maximumHandshakeBytes
        )
        let root = try dictionaryRoot(document)

        var utMetadataID: UInt8?
        var utPEXID: UInt8?
        var uploadOnlyID: UInt8?
        var holepunchID: UInt8?
        var dontHaveID: UInt8?
        if let messages = document.value(named: "m", inDictionaryAt: root) {
            guard document.kind(at: messages) == .dictionary else {
                throw TorrentPeerProtocolError.invalidField
            }
            var assignedIDs = Set<UInt8>()
            var child = document.firstChild(of: messages)
            while let index = child {
                guard let key = document.dictionaryKeyRange(forChild: index),
                      let value = document.integer(at: index),
                      value >= 0,
                      value <= Int64(UInt8.max) else {
                    throw TorrentPeerProtocolError.invalidField
                }
                let identifier = UInt8(value)
                if identifier != 0,
                   !assignedIDs.insert(identifier).inserted {
                    throw TorrentPeerProtocolError.invalidField
                }
                if document.bytes(in: key, equalTo: "ut_metadata".utf8) {
                    utMetadataID = identifier
                } else if document.bytes(in: key, equalTo: "ut_pex".utf8) {
                    utPEXID = identifier
                } else if document.bytes(in: key, equalTo: "upload_only".utf8) {
                    uploadOnlyID = identifier
                } else if document.bytes(in: key, equalTo: "ut_holepunch".utf8) {
                    holepunchID = identifier
                } else if document.bytes(in: key, equalTo: "lt_donthave".utf8) {
                    dontHaveID = identifier
                }
                child = document.nextSibling(of: index)
            }
        }

        let metadataSize = try boundedInt32(
            named: "metadata_size",
            in: root,
            document: document,
            range: 0...Int64(limits.maximumMetadataBytes)
        )
        let listenPortValue = try boundedInt32(
            named: "p",
            in: root,
            document: document,
            range: 1...Int64(UInt16.max)
        )
        // Libtorrent sends -1 when completion history is unknown. Keep the
        // typed age absent in that case while retaining the rest of the update.
        let lastSeenComplete = try boundedInt32(
            named: "complete_ago",
            in: root,
            document: document,
            range: -1...Int64(Int32.max)
        ).flatMap { $0 == -1 ? nil : $0 }
        let requestQueueValue = try boundedInt32(
            named: "reqq",
            in: root,
            document: document,
            range: 0...Int64(UInt16.max)
        )

        let clientVersion = try optionalString(
            named: "v",
            in: root,
            document: document,
            maximumBytes: limits.maximumClientVersionBytes,
            requiresUTF8: true
        )
        let yourIP = try optionalString(
            named: "yourip",
            in: root,
            document: document,
            maximumBytes: 16,
            requiresUTF8: false
        )
        let externalAddress: TorrentPeerAddress?
        if let yourIP, !yourIP.isEmpty {
            guard yourIP.count == 4 || yourIP.count == 16 else {
                throw TorrentPeerProtocolError.invalidField
            }
            externalAddress = try decodeAddress(yourIP)
        } else {
            externalAddress = nil
        }

        let uploadOnlyValue = try optionalInteger(
            named: "upload_only",
            in: root,
            document: document
        )

        return TorrentExtensionHandshakeUpdate(
            utMetadataID: utMetadataID,
            utPEXID: utPEXID,
            uploadOnlyID: uploadOnlyID,
            holepunchID: holepunchID,
            dontHaveID: dontHaveID,
            metadataSize: metadataSize,
            listenPort: listenPortValue.map(UInt16.init),
            lastSeenComplete: lastSeenComplete,
            requestQueueLimit: requestQueueValue.map(UInt16.init),
            clientVersionUTF8: clientVersion?.isEmpty == false ? clientVersion : nil,
            externalAddress: externalAddress,
            uploadOnly: uploadOnlyValue.map { $0 != 0 }
        )
    }

    package func parseMetadataControlMessage(
        _ bytes: Data
    ) throws -> TorrentMetadataControlMessage {
        guard !bytes.isEmpty else {
            throw TorrentPeerProtocolError.emptyMessage
        }
        guard bytes.count <= limits.maximumMetadataMessageBytes else {
            throw TorrentPeerProtocolError.messageTooLarge
        }
        let document: BencodeRangeDocument
        do {
            document = try BencodeRangeDocument.scanPrefix(
                bytes,
                limits: scannerLimits(maximumStringBytes: bytes.count),
                dictionaryPolicy: .unorderedUnique
            )
        } catch {
            throw scanError(error)
        }
        let root = try dictionaryRoot(document)
        guard let rawType = try optionalInteger(
            named: "msg_type",
            in: root,
            document: document
        ),
        let pieceValue = try optionalInteger(
            named: "piece",
            in: root,
            document: document
        ),
        pieceValue >= 0,
        pieceValue <= Int64(Int32.max) else {
            throw TorrentPeerProtocolError.invalidField
        }
        let totalSize = try boundedInt32(
            named: "total_size",
            in: root,
            document: document,
            range: 0...Int64(limits.maximumMetadataBytes)
        )
        let payloadOffset = document.encodedRange(at: root).upperBound
        let payloadSize = bytes.count - payloadOffset
        guard let compactOffset = Int32(exactly: payloadOffset),
              let compactSize = Int32(exactly: payloadSize) else {
            throw TorrentPeerProtocolError.invalidField
        }

        let kind: TorrentMetadataMessageKind
        switch rawType {
        case 0:
            kind = .request
            guard payloadSize == 0 else {
                throw TorrentPeerProtocolError.invalidField
            }
        case 1:
            kind = .data
            guard let totalSize,
                  totalSize > 0,
                  payloadSize > 0,
                  payloadSize <= 16 * 1_024 else {
                throw TorrentPeerProtocolError.invalidField
            }
        case 2:
            kind = .reject
            guard payloadSize == 0 else {
                throw TorrentPeerProtocolError.invalidField
            }
        default:
            kind = .unknown
        }

        return TorrentMetadataControlMessage(
            kind: kind,
            rawMessageType: rawType,
            piece: Int32(pieceValue),
            totalSize: totalSize,
            payloadOffset: compactOffset,
            payloadSize: compactSize
        )
    }

    package func parsePeerExchange(
        _ bytes: Data
    ) throws -> TorrentPeerExchangeMessage {
        let document = try scanComplete(
            bytes,
            maximumBytes: limits.maximumPeerExchangeBytes
        )
        let root = try dictionaryRoot(document)

        let added4 = try optionalStringRange(
            named: "added",
            in: root,
            document: document,
            maximumBytes: limits.maximumPeerExchangeBytes
        )
        let added4Flags = try optionalStringRange(
            named: "added.f",
            in: root,
            document: document,
            maximumBytes: limits.maximumInitialAddedContacts
        )
        let added6 = try optionalStringRange(
            named: "added6",
            in: root,
            document: document,
            maximumBytes: limits.maximumPeerExchangeBytes
        )
        let added6Flags = try optionalStringRange(
            named: "added6.f",
            in: root,
            document: document,
            maximumBytes: limits.maximumInitialAddedContacts
        )
        let dropped4 = try optionalStringRange(
            named: "dropped",
            in: root,
            document: document,
            maximumBytes: limits.maximumPeerExchangeBytes
        )
        let dropped6 = try optionalStringRange(
            named: "dropped6",
            in: root,
            document: document,
            maximumBytes: limits.maximumPeerExchangeBytes
        )

        let added4Count = try contactCount(added4, stride: 6)
        let added6Count = try contactCount(added6, stride: 18)
        let dropped4Count = try contactCount(dropped4, stride: 6)
        let dropped6Count = try contactCount(dropped6, stride: 18)
        try validateFlags(added4Flags, contactCount: added4Count, contacts: added4)
        try validateFlags(added6Flags, contactCount: added6Count, contacts: added6)

        let addedCount = try checkedSum(added4Count, added6Count)
        let droppedCount = try checkedSum(dropped4Count, dropped6Count)
        guard addedCount <= limits.maximumInitialAddedContacts,
              droppedCount <= limits.maximumInitialDroppedContacts else {
            throw TorrentPeerProtocolError.tooManyPeerExchangeContacts
        }
        guard addedCount > 0 || droppedCount > 0 else {
            throw TorrentPeerProtocolError.invalidField
        }

        var contacts = [TorrentPeerExchangeContact]()
        let contactCount = try checkedSum(addedCount, droppedCount)
        contacts.reserveCapacity(contactCount)
        var seenEndpoints = Set<PeerExchangeEndpointKey>()
        seenEndpoints.reserveCapacity(contactCount)
        try appendContacts(
            added4,
            flags: added4Flags,
            family: .ipv4,
            action: .add,
            stride: 6,
            document: document,
            to: &contacts,
            seenEndpoints: &seenEndpoints
        )
        try appendContacts(
            added6,
            flags: added6Flags,
            family: .ipv6,
            action: .add,
            stride: 18,
            document: document,
            to: &contacts,
            seenEndpoints: &seenEndpoints
        )
        try appendContacts(
            dropped4,
            flags: nil,
            family: .ipv4,
            action: .drop,
            stride: 6,
            document: document,
            to: &contacts,
            seenEndpoints: &seenEndpoints
        )
        try appendContacts(
            dropped6,
            flags: nil,
            family: .ipv6,
            action: .drop,
            stride: 18,
            document: document,
            to: &contacts,
            seenEndpoints: &seenEndpoints
        )
        return TorrentPeerExchangeMessage(
            contacts: contacts,
            addedCount: addedCount,
            droppedCount: droppedCount
        )
    }

    private func scanComplete(
        _ bytes: Data,
        maximumBytes: Int
    ) throws -> BencodeRangeDocument {
        guard !bytes.isEmpty else {
            throw TorrentPeerProtocolError.emptyMessage
        }
        guard maximumBytes > 0,
              bytes.count <= maximumBytes else {
            throw TorrentPeerProtocolError.messageTooLarge
        }
        do {
            return try BencodeRangeDocument.scan(
                bytes,
                limits: scannerLimits(maximumStringBytes: maximumBytes),
                dictionaryPolicy: .unorderedUnique
            )
        } catch {
            throw scanError(error)
        }
    }

    private func scannerLimits(maximumStringBytes: Int) -> BencodeScanLimits {
        BencodeScanLimits(
            maximumNestingDepth: limits.maximumNestingDepth,
            maximumValueCount: limits.maximumValueCount,
            maximumStringBytes: maximumStringBytes,
            maximumContainerCount: limits.maximumContainerCount,
            maximumDictionaryKeyBytes: limits.maximumDictionaryKeyBytes,
            maximumIntegerDigits: limits.maximumIntegerDigits,
            maximumStringLengthDigits: limits.maximumStringLengthDigits
        )
    }

    private func dictionaryRoot(
        _ document: BencodeRangeDocument
    ) throws -> Int {
        guard document.kind(at: document.rootIndex) == .dictionary else {
            throw TorrentPeerProtocolError.invalidField
        }
        return document.rootIndex
    }

    private func optionalInteger(
        named name: String,
        in dictionary: Int,
        document: BencodeRangeDocument
    ) throws -> Int64? {
        guard let value = document.value(named: name, inDictionaryAt: dictionary) else {
            return nil
        }
        guard let integer = document.integer(at: value) else {
            throw TorrentPeerProtocolError.invalidField
        }
        return integer
    }

    private func boundedInt32(
        named name: String,
        in dictionary: Int,
        document: BencodeRangeDocument,
        range: ClosedRange<Int64>
    ) throws -> Int32? {
        guard let integer = try optionalInteger(
            named: name,
            in: dictionary,
            document: document
        ) else {
            return nil
        }
        guard range.contains(integer),
              let compact = Int32(exactly: integer) else {
            throw TorrentPeerProtocolError.invalidField
        }
        return compact
    }

    private func optionalString(
        named name: String,
        in dictionary: Int,
        document: BencodeRangeDocument,
        maximumBytes: Int,
        requiresUTF8: Bool
    ) throws -> Data? {
        guard let range = try optionalStringRange(
            named: name,
            in: dictionary,
            document: document,
            maximumBytes: maximumBytes
        ) else {
            return nil
        }
        let bytes = Data(document.data[range])
        if requiresUTF8,
           String(data: bytes, encoding: .utf8) == nil {
            throw TorrentPeerProtocolError.invalidField
        }
        return bytes
    }

    private func optionalStringRange(
        named name: String,
        in dictionary: Int,
        document: BencodeRangeDocument,
        maximumBytes: Int
    ) throws -> Range<Int>? {
        guard let value = document.value(named: name, inDictionaryAt: dictionary) else {
            return nil
        }
        guard let range = document.stringRange(at: value),
              range.count <= maximumBytes else {
            throw TorrentPeerProtocolError.invalidField
        }
        return range
    }

    private func contactCount(_ range: Range<Int>?, stride: Int) throws -> Int {
        guard let range else {
            return 0
        }
        guard range.count.isMultiple(of: stride) else {
            throw TorrentPeerProtocolError.invalidField
        }
        return range.count / stride
    }

    private func validateFlags(
        _ flags: Range<Int>?,
        contactCount: Int,
        contacts: Range<Int>?
    ) throws {
        guard let flags else {
            return
        }
        guard contacts != nil,
              flags.count == contactCount else {
            throw TorrentPeerProtocolError.invalidField
        }
    }

    private func appendContacts(
        _ encoded: Range<Int>?,
        flags: Range<Int>?,
        family: TorrentPeerAddressFamily,
        action: TorrentPeerExchangeAction,
        stride: Int,
        document: BencodeRangeDocument,
        to contacts: inout [TorrentPeerExchangeContact],
        seenEndpoints: inout Set<PeerExchangeEndpointKey>
    ) throws {
        guard let encoded else {
            return
        }
        let addressSize = stride - 2
        var offset = encoded.lowerBound
        var contactIndex = 0
        while offset < encoded.upperBound {
            let address = try decodeAddress(document.data[offset..<(offset + addressSize)])
            let port = UInt16(document.data[offset + addressSize]) << 8
                | UInt16(document.data[offset + addressSize + 1])
            guard port != 0 else {
                throw TorrentPeerProtocolError.invalidField
            }
            guard seenEndpoints.insert(PeerExchangeEndpointKey(
                address: address,
                port: port
            )).inserted else {
                throw TorrentPeerProtocolError.duplicatePeerExchangeContact
            }
            let rawFlags = flags.map {
                document.data[$0.lowerBound + contactIndex]
            } ?? 0
            contacts.append(TorrentPeerExchangeContact(
                address: address,
                port: port,
                action: action,
                // Bits 5-7 are reserved or libtorrent-internal and never gain
                // meaning merely because a peer supplied them.
                flags: rawFlags & 0x1f
            ))
            offset += stride
            contactIndex += 1
        }
    }

    private func decodeAddress(_ bytes: Data.SubSequence) throws -> TorrentPeerAddress {
        switch bytes.count {
        case 4:
            let low = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let first = bytes[bytes.startIndex]
            guard low != 0,
                  first < 224,
                  low != UInt64(UInt32.max) else {
                throw TorrentPeerProtocolError.invalidField
            }
            return TorrentPeerAddress(family: .ipv4, high: 0, low: low)
        case 16:
            var high: UInt64 = 0
            var low: UInt64 = 0
            for byte in bytes.prefix(8) {
                high = (high << 8) | UInt64(byte)
            }
            for byte in bytes.suffix(8) {
                low = (low << 8) | UInt64(byte)
            }
            let isIPv4Mapped = high == 0 && (low >> 32) == 0xffff
            guard (high != 0 || low != 0),
                  bytes[bytes.startIndex] != 0xff,
                  !isIPv4Mapped else {
                throw TorrentPeerProtocolError.invalidField
            }
            return TorrentPeerAddress(family: .ipv6, high: high, low: low)
        default:
            throw TorrentPeerProtocolError.invalidField
        }
    }

    private func checkedSum(_ left: Int, _ right: Int) throws -> Int {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else {
            throw TorrentPeerProtocolError.workLimitExceeded
        }
        return result.partialValue
    }

    private func scanError(_ error: any Error) -> TorrentPeerProtocolError {
        guard let error = error as? BencodeScanError else {
            return .malformedBencoding
        }
        switch error {
        case .malformed:
            return .malformedBencoding
        case .nestingLimitExceeded,
             .valueLimitExceeded,
             .stringLimitExceeded,
             .containerLimitExceeded,
             .dictionaryKeyByteLimitExceeded,
             .integerDigitLimitExceeded,
             .stringLengthDigitLimitExceeded:
            return .workLimitExceeded
        }
    }
}
