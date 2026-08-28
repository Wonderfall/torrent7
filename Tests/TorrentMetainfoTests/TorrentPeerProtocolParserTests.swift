import Foundation
import Testing
@testable import TorrentMetainfo

@Suite("Peer extension protocol parser")
struct TorrentPeerProtocolParserTests {
    private let parser = TorrentPeerProtocolParser()

    @Test("Extension handshake returns bounded typed additive fields")
    func parsesExtensionHandshake() throws {
        var message = Data(
            "d12:complete_agoi9e1:md11:lt_donthavei7e11:upload_onlyi3e12:ut_holepunchi4e11:ut_metadatai2e6:ut_pexi1ee13:metadata_sizei1234e1:pi6881e4:reqqi250e11:upload_onlyi1e1:v9:Torrent 76:yourip4:".utf8
        )
        message.append(contentsOf: [203, 0, 113, 8])
        message.append(UInt8(ascii: "e"))

        let update = try parser.parseExtensionHandshake(message)

        #expect(update.utMetadataID == 2)
        #expect(update.utPEXID == 1)
        #expect(update.uploadOnlyID == 3)
        #expect(update.holepunchID == 4)
        #expect(update.dontHaveID == 7)
        #expect(update.metadataSize == 1_234)
        #expect(update.listenPort == 6_881)
        #expect(update.lastSeenComplete == 9)
        #expect(update.requestQueueLimit == 250)
        #expect(update.clientVersionUTF8 == Data("Torrent 7".utf8))
        #expect(update.externalAddress == TorrentPeerAddress(
            family: .ipv4,
            high: 0,
            low: 0xcb00_7108
        ))
        #expect(update.uploadOnly == true)
    }

    @Test("Extension mapping omissions remain absent and zero disables")
    func preservesAdditiveExtensionUpdates() throws {
        let update = try parser.parseExtensionHandshake(
            Data("d1:md6:ut_pexi0eee".utf8)
        )

        #expect(update.utPEXID == 0)
        #expect(update.utMetadataID == nil)
        #expect(update.listenPort == nil)
        #expect(update.uploadOnly == nil)
    }

    @Test("Network dictionaries accept unordered unique keys recursively")
    func acceptsUnorderedUniqueNetworkDictionaries() throws {
        let handshake = Data(
            "d1:v9:Torrent 71:md6:ut_pexi1e11:ut_metadatai2eee".utf8
        )
        let update = try parser.parseExtensionHandshake(handshake)
        #expect(update.utMetadataID == 2)
        #expect(update.utPEXID == 1)
        #expect(update.clientVersionUTF8 == Data("Torrent 7".utf8))

        var metadata = Data(
            "d10:total_sizei4e5:piecei0e8:msg_typei1ee".utf8
        )
        metadata.append(contentsOf: [1, 2, 3, 4])
        let control = try parser.parseMetadataControlMessage(metadata)
        #expect(control.kind == .data)
        #expect(control.payloadSize == 4)

        #expect(throws: TorrentPeerProtocolError.malformedBencoding) {
            _ = try parser.parseExtensionHandshake(
                Data("d7:futurei1e1:md6:ut_pexi1ee7:futurei2ee".utf8)
            )
        }
    }

    @Test("Extension IDs must be unique bytes")
    func rejectsInvalidExtensionMappings() {
        #expect(throws: TorrentPeerProtocolError.invalidField) {
            _ = try parser.parseExtensionHandshake(
                Data("d1:md3:fooi1e6:ut_pexi1eee".utf8)
            )
        }
        #expect(throws: TorrentPeerProtocolError.invalidField) {
            _ = try parser.parseExtensionHandshake(
                Data("d1:md6:ut_pexi256eee".utf8)
            )
        }
        #expect(throws: TorrentPeerProtocolError.malformedBencoding) {
            _ = try parser.parseExtensionHandshake(
                Data("d1:md6:ut_pexi1ee1:ai0e1:ai1ee".utf8)
            )
        }
    }

    @Test("Metadata data messages split the dictionary from the exact block")
    func parsesMetadataDataMessage() throws {
        var message = Data(
            "d8:msg_typei1e5:piecei2e10:total_sizei40000ee".utf8
        )
        let dictionarySize = message.count
        message.append(Data(repeating: 0xa5, count: 16_384))

        let parsed = try parser.parseMetadataControlMessage(message)

        #expect(parsed.kind == .data)
        #expect(parsed.rawMessageType == 1)
        #expect(parsed.piece == 2)
        #expect(parsed.totalSize == 40_000)
        #expect(parsed.payloadOffset == Int32(dictionarySize))
        #expect(parsed.payloadSize == 16_384)
    }

    @Test("Known metadata controls reject invalid appended data")
    func validatesMetadataControlShape() throws {
        let request = try parser.parseMetadataControlMessage(
            Data("d8:msg_typei0e5:piecei3ee".utf8)
        )
        #expect(request.kind == .request)
        #expect(request.piece == 3)
        #expect(request.payloadSize == 0)

        #expect(throws: TorrentPeerProtocolError.invalidField) {
            _ = try parser.parseMetadataControlMessage(
                Data("d8:msg_typei0e5:piecei3eextra".utf8)
            )
        }
        #expect(throws: TorrentPeerProtocolError.invalidField) {
            _ = try parser.parseMetadataControlMessage(
                Data("d8:msg_typei1e5:piecei0eeX".utf8)
            )
        }
        #expect(throws: TorrentPeerProtocolError.invalidField) {
            _ = try parser.parseMetadataControlMessage(
                Data("d8:msg_typei2e5:piecei-1ee".utf8)
            )
        }
    }

    @Test("Unknown metadata message types are retained and ignored safely")
    func preservesUnknownMetadataType() throws {
        var message = Data("d8:msg_typei99e5:piecei4ee".utf8)
        let payloadOffset = message.count
        message.append(Data([1, 2, 3]))

        let parsed = try parser.parseMetadataControlMessage(message)

        #expect(parsed.kind == .unknown)
        #expect(parsed.rawMessageType == 99)
        #expect(parsed.piece == 4)
        #expect(parsed.payloadOffset == Int32(payloadOffset))
        #expect(parsed.payloadSize == 3)
    }

    @Test("PEX yields typed IPv4 and IPv6 contacts with optional flags")
    func parsesPeerExchange() throws {
        let added4 = Data([203, 0, 113, 9, 0x1a, 0xe1])
        let added6 = Data([
            0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 1,
            0x1a, 0xe2,
        ])
        let dropped4 = Data([198, 51, 100, 2, 0x1a, 0xe3])
        let message = pexMessage(
            added4: added4,
            added4Flags: Data([0xff]),
            added6: added6,
            added6Flags: nil,
            dropped4: dropped4,
            dropped6: nil
        )

        let parsed = try parser.parsePeerExchange(message)

        #expect(parsed.addedCount == 2)
        #expect(parsed.droppedCount == 1)
        #expect(parsed.contacts.count == 3)
        #expect(parsed.contacts[0] == TorrentPeerExchangeContact(
            address: TorrentPeerAddress(
                family: .ipv4,
                high: 0,
                low: 0xcb00_7109
            ),
            port: 6_881,
            action: .add,
            flags: 0x1f
        ))
        #expect(parsed.contacts[1].address.family == .ipv6)
        #expect(parsed.contacts[1].address.high == 0x2001_0db8_0000_0000)
        #expect(parsed.contacts[1].address.low == 1)
        #expect(parsed.contacts[1].port == 6_882)
        #expect(parsed.contacts[1].flags == 0)
        #expect(parsed.contacts[2].action == .drop)
    }

    @Test("PEX rejects malformed compact arrays and flag counts")
    func rejectsMalformedPeerExchangeArrays() {
        #expect(throws: TorrentPeerProtocolError.invalidField) {
            _ = try parser.parsePeerExchange(
                pexMessage(added4: Data([1, 2, 3]), added4Flags: nil)
            )
        }
        #expect(throws: TorrentPeerProtocolError.invalidField) {
            _ = try parser.parsePeerExchange(pexMessage(
                added4: Data([203, 0, 113, 9, 0x1a, 0xe1]),
                added4Flags: Data()
            ))
        }
        #expect(throws: TorrentPeerProtocolError.invalidField) {
            _ = try parser.parsePeerExchange(Data("de".utf8))
        }
    }

    @Test("PEX identity includes the address family, address, and port")
    func validatesPeerExchangeEndpointIdentity() throws {
        let first = Data([203, 0, 113, 9, 0x1a, 0xe1])
        let secondPort = Data([203, 0, 113, 9, 0x1a, 0xe2])

        let twoAdded = try parser.parsePeerExchange(pexMessage(
            added4: first + secondPort,
            added4Flags: nil
        ))
        #expect(twoAdded.addedCount == 2)
        #expect(twoAdded.contacts.map(\.port) == [6_881, 6_882])

        let addAndDrop = try parser.parsePeerExchange(pexMessage(
            added4: first,
            added4Flags: nil,
            dropped4: secondPort
        ))
        #expect(addAndDrop.addedCount == 1)
        #expect(addAndDrop.droppedCount == 1)

        #expect(throws: TorrentPeerProtocolError.duplicatePeerExchangeContact) {
            _ = try parser.parsePeerExchange(pexMessage(
                added4: first + first,
                added4Flags: nil
            ))
        }
        #expect(throws: TorrentPeerProtocolError.duplicatePeerExchangeContact) {
            _ = try parser.parsePeerExchange(pexMessage(
                added4: first,
                added4Flags: nil,
                dropped4: first
            ))
        }
    }

    @Test("PEX enforces independent bounded initial add and drop budgets")
    func enforcesPeerExchangeContactBudgets() {
        var peers = Data()
        for index in 0..<101 {
            peers.append(contentsOf: [
                203,
                0,
                UInt8(index / 254),
                UInt8(index % 254 + 1),
                0x1a,
                UInt8(index + 1),
            ])
        }

        #expect(throws: TorrentPeerProtocolError.tooManyPeerExchangeContacts) {
            _ = try parser.parsePeerExchange(
                pexMessage(added4: peers, added4Flags: nil)
            )
        }
    }
}

private func pexMessage(
    added4: Data? = nil,
    added4Flags: Data? = nil,
    added6: Data? = nil,
    added6Flags: Data? = nil,
    dropped4: Data? = nil,
    dropped6: Data? = nil
) -> Data {
    var result = Data([UInt8(ascii: "d")])
    appendBencodedField("added", value: added4, to: &result)
    appendBencodedField("added.f", value: added4Flags, to: &result)
    appendBencodedField("added6", value: added6, to: &result)
    appendBencodedField("added6.f", value: added6Flags, to: &result)
    appendBencodedField("dropped", value: dropped4, to: &result)
    appendBencodedField("dropped6", value: dropped6, to: &result)
    result.append(UInt8(ascii: "e"))
    return result
}

private func appendBencodedField(
    _ key: String,
    value: Data?,
    to result: inout Data
) {
    guard let value else {
        return
    }
    result.append(Data("\(key.utf8.count):\(key)\(value.count):".utf8))
    result.append(value)
}
