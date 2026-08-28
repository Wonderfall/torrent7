import Foundation
import Testing
@testable import TorrentMetainfo

@Suite("Bencode range scanner")
struct BencodeRangeScannerTests {
    @Test("Canonical values retain exact ranges and flat sibling links")
    func retainsRangesAndLinks() throws {
        let data = Data("d1:ali1e3:twoe1:bd1:ci-2eee".utf8)
        let document = try BencodeRangeDocument.scan(data, limits: Self.limits())
        let root = document.rootIndex

        #expect(document.kind(at: root) == .dictionary)
        #expect(document.encodedRange(at: root) == data.indices)
        #expect(document.childCount(of: root) == 2)

        let list = try #require(document.value(named: "a", inDictionaryAt: root))
        #expect(document.kind(at: list) == .list)
        #expect(document.bytes(
            in: try #require(document.dictionaryKeyRange(forChild: list)),
            equalTo: "a".utf8
        ))
        let firstListValue = try #require(document.firstChild(of: list))
        #expect(document.integer(at: firstListValue) == 1)
        let secondListValue = try #require(document.nextSibling(of: firstListValue))
        let stringRange = try #require(document.stringRange(at: secondListValue))
        #expect(Data(document.data[stringRange]) == Data("two".utf8))
        #expect(document.nextSibling(of: secondListValue) == nil)

        let dictionary = try #require(document.value(named: "b", inDictionaryAt: root))
        let negative = try #require(document.value(named: "c", inDictionaryAt: dictionary))
        #expect(document.integer(at: negative) == -2)
        #expect(document.value(named: "aa", inDictionaryAt: root) == nil)
        #expect(document.value(named: "z", inDictionaryAt: root) == nil)
    }

    @Test("Nonzero-index Data slices are normalized before ranges are retained")
    func normalizesDataSlices() throws {
        let wrapped = Data("xxd1:ai1eeyy".utf8)
        let slice = wrapped[2..<(wrapped.count - 2)]
        #expect(slice.startIndex == 2)

        let document = try BencodeRangeDocument.scan(slice, limits: Self.limits())
        #expect(document.data.startIndex == 0)
        #expect(document.encodedRange(at: document.rootIndex) == document.data.indices)
        let integer = try #require(document.value(
            named: "a",
            inDictionaryAt: document.rootIndex
        ))
        #expect(document.integer(at: integer) == 1)
    }

    @Test("Prefix scanning retains but does not decode appended binary data")
    func scansOneLeadingValue() throws {
        let data = Data("d1:ai1ee\u{0}\u{1}payload".utf8)
        let document = try BencodeRangeDocument.scanPrefix(
            data,
            limits: Self.limits()
        )

        #expect(document.encodedRange(at: document.rootIndex) == 0..<8)
        #expect(document.data == data)
        #expect(throws: BencodeScanError.malformed) {
            _ = try BencodeRangeDocument.scan(data, limits: Self.limits())
        }
    }

    @Test("Deep values are scanned iteratively")
    func scansDeepValuesIteratively() throws {
        let depth = 5_000
        var data = Data(repeating: UInt8(ascii: "l"), count: depth)
        data.append(Data("0:".utf8))
        data.append(Data(repeating: UInt8(ascii: "e"), count: depth))

        let document = try BencodeRangeDocument.scan(
            data,
            limits: Self.limits(
                maximumNestingDepth: depth,
                maximumValueCount: depth + 1,
                maximumContainerCount: depth
            )
        )
        var token = document.rootIndex
        for _ in 0..<depth {
            #expect(document.kind(at: token) == .list)
            token = try #require(document.firstChild(of: token))
        }
        #expect(document.stringRange(at: token)?.isEmpty == true)

        #expect(throws: BencodeScanError.nestingLimitExceeded) {
            _ = try BencodeRangeDocument.scan(
                data,
                limits: Self.limits(
                    maximumNestingDepth: depth - 1,
                    maximumValueCount: depth + 1,
                    maximumContainerCount: depth
                )
            )
        }
    }

    @Test("Canonical encoding and independent work budgets fail closed", arguments: [
        ("d1:ai1e1:ai2ee", BencodeScanError.malformed),
        ("d1:bi1e1:ai2ee", BencodeScanError.malformed),
        ("i01e", BencodeScanError.malformed),
        ("i-0e", BencodeScanError.malformed),
        ("01:a", BencodeScanError.malformed),
        ("i1ee", BencodeScanError.malformed),
    ])
    func rejectsNoncanonicalInput(encoded: String, expected: BencodeScanError) {
        #expect(throws: expected) {
            _ = try BencodeRangeDocument.scan(
                Data(encoded.utf8),
                limits: Self.limits()
            )
        }
    }

    @Test("Unordered dictionaries remain unique and searchable at every depth")
    func acceptsOnlyUnorderedUniqueDictionaries() throws {
        let data = Data("d1:zi9e1:ad1:yi2e1:xi1ee1:mi4ee".utf8)
        let document = try BencodeRangeDocument.scan(
            data,
            limits: Self.limits(),
            dictionaryPolicy: .unorderedUnique
        )
        let root = document.rootIndex

        #expect(document.integer(
            at: try #require(document.value(named: "z", inDictionaryAt: root))
        ) == 9)
        #expect(document.integer(
            at: try #require(document.value(named: "m", inDictionaryAt: root))
        ) == 4)
        let nested = try #require(document.value(named: "a", inDictionaryAt: root))
        #expect(document.integer(
            at: try #require(document.value(named: "x", inDictionaryAt: nested))
        ) == 1)
        #expect(document.integer(
            at: try #require(document.value(named: "y", inDictionaryAt: nested))
        ) == 2)

        for duplicate in [
            "d1:ai1e1:ai2ee",
            "d1:ad1:xi1e1:xi2eee",
            "d7:unknowni1e7:unknowni2ee",
            "d0:i1e0:i2ee",
        ] {
            #expect(throws: BencodeScanError.malformed) {
                _ = try BencodeRangeDocument.scan(
                    Data(duplicate.utf8),
                    limits: Self.limits(),
                    dictionaryPolicy: .unorderedUnique
                )
            }
        }
    }

    @Test("Unordered prefix scanning keeps strict scalar syntax")
    func scansUnorderedPrefixWithCanonicalScalars() throws {
        let data = Data("d1:zi2e1:ai1ee\u{0}payload".utf8)
        let document = try BencodeRangeDocument.scanPrefix(
            data,
            limits: Self.limits(),
            dictionaryPolicy: .unorderedUnique
        )

        #expect(document.encodedRange(at: document.rootIndex) == 0..<14)
        #expect(document.integer(
            at: try #require(document.value(named: "a", inDictionaryAt: document.rootIndex))
        ) == 1)
        for malformed in ["d1:ai01ee", "d1:a01:xe"] {
            #expect(throws: BencodeScanError.malformed) {
                _ = try BencodeRangeDocument.scan(
                    Data(malformed.utf8),
                    limits: Self.limits(),
                    dictionaryPolicy: .unorderedUnique
                )
            }
        }
    }

    @Test("Each scanner resource ceiling is enforced")
    func enforcesResourceCeilings() {
        #expect(throws: BencodeScanError.valueLimitExceeded) {
            _ = try BencodeRangeDocument.scan(
                Data("d1:ai1ee".utf8),
                limits: Self.limits(maximumValueCount: 2)
            )
        }
        #expect(throws: BencodeScanError.containerLimitExceeded) {
            _ = try BencodeRangeDocument.scan(
                Data("llee".utf8),
                limits: Self.limits(maximumContainerCount: 1)
            )
        }
        #expect(throws: BencodeScanError.dictionaryKeyByteLimitExceeded) {
            _ = try BencodeRangeDocument.scan(
                Data("d3:keyi1ee".utf8),
                limits: Self.limits(maximumDictionaryKeyBytes: 2)
            )
        }
        #expect(throws: BencodeScanError.stringLimitExceeded) {
            _ = try BencodeRangeDocument.scan(
                Data("4:test".utf8),
                limits: Self.limits(maximumStringBytes: 3)
            )
        }
        #expect(throws: BencodeScanError.integerDigitLimitExceeded) {
            _ = try BencodeRangeDocument.scan(
                Data("i123e".utf8),
                limits: Self.limits(maximumIntegerDigits: 2)
            )
        }
        #expect(throws: BencodeScanError.stringLengthDigitLimitExceeded) {
            _ = try BencodeRangeDocument.scan(
                Data("10:0123456789".utf8),
                limits: Self.limits(maximumStringLengthDigits: 1)
            )
        }
    }

    @Test("Long scans observe synchronous cancellation")
    func observesCancellation() {
        enum Cancelled: Error {
            case requested
        }

        var data = Data([UInt8(ascii: "l")])
        for _ in 0..<300 {
            data.append(Data("0:".utf8))
        }
        data.append(UInt8(ascii: "e"))
        var checks = 0
        #expect(throws: Cancelled.requested) {
            _ = try BencodeRangeDocument.scan(data, limits: Self.limits()) {
                checks += 1
                if checks == 2 {
                    throw Cancelled.requested
                }
            }
        }
    }

    private static func limits(
        maximumNestingDepth: Int = 32,
        maximumValueCount: Int = 1_024,
        maximumStringBytes: Int = 1_024,
        maximumContainerCount: Int = 1_024,
        maximumDictionaryKeyBytes: Int = 1_024,
        maximumIntegerDigits: Int = 19,
        maximumStringLengthDigits: Int = 19
    ) -> BencodeScanLimits {
        BencodeScanLimits(
            maximumNestingDepth: maximumNestingDepth,
            maximumValueCount: maximumValueCount,
            maximumStringBytes: maximumStringBytes,
            maximumContainerCount: maximumContainerCount,
            maximumDictionaryKeyBytes: maximumDictionaryKeyBytes,
            maximumIntegerDigits: maximumIntegerDigits,
            maximumStringLengthDigits: maximumStringLengthDigits
        )
    }
}
