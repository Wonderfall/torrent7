import Foundation

enum BencodeScanError: Error, Equatable, Sendable {
    case malformed
    case nestingLimitExceeded
    case valueLimitExceeded
    case stringLimitExceeded
    case containerLimitExceeded
    case dictionaryKeyByteLimitExceeded
    case integerDigitLimitExceeded
    case stringLengthDigitLimitExceeded
}

struct BencodeScanLimits: Equatable, Sendable {
    var maximumNestingDepth: Int
    var maximumValueCount: Int
    var maximumStringBytes: Int
    var maximumContainerCount: Int
    var maximumDictionaryKeyBytes: Int
    var maximumIntegerDigits: Int
    var maximumStringLengthDigits: Int

    init(
        maximumNestingDepth: Int,
        maximumValueCount: Int,
        maximumStringBytes: Int,
        maximumContainerCount: Int,
        maximumDictionaryKeyBytes: Int,
        maximumIntegerDigits: Int = 19,
        maximumStringLengthDigits: Int = 19
    ) {
        self.maximumNestingDepth = maximumNestingDepth
        self.maximumValueCount = maximumValueCount
        self.maximumStringBytes = maximumStringBytes
        self.maximumContainerCount = maximumContainerCount
        self.maximumDictionaryKeyBytes = maximumDictionaryKeyBytes
        self.maximumIntegerDigits = maximumIntegerDigits
        self.maximumStringLengthDigits = maximumStringLengthDigits
    }
}

enum BencodeValueKind: UInt8, Equatable, Sendable {
    case string
    case integer
    case list
    case dictionary
}

/// A flat, immutable view of canonical bencoding. Tokens retain only ranges and
/// sibling links into the original input; strings and dictionary keys are not
/// copied. Construction is iterative and validates the whole input, including
/// unknown values, before this value can exist.
struct BencodeRangeDocument: Sendable {
    private static let missingOffset = UInt32.max

    private struct Token: Sendable {
        let kind: BencodeValueKind
        let encodedOffset: UInt32
        var encodedSize: UInt32
        let payloadOffset: UInt32
        let payloadSize: UInt32
        let integer: Int64
        var firstChildIndex: Int32
        var nextSiblingIndex: Int32
        var dictionaryKeyOffset: UInt32
        var dictionaryKeySize: UInt32
        var childCount: UInt32
    }

    let data: Data
    let rootIndex: Int
    private let tokens: [Token]

    private init(data: Data, rootIndex: Int, tokens: [Token]) {
        self.data = data
        self.rootIndex = rootIndex
        self.tokens = tokens
    }

    func kind(at index: Int) -> BencodeValueKind {
        tokens[index].kind
    }

    func encodedRange(at index: Int) -> Range<Int> {
        Self.range(offset: tokens[index].encodedOffset, size: tokens[index].encodedSize)
    }

    func stringRange(at index: Int) -> Range<Int>? {
        guard tokens[index].kind == .string else {
            return nil
        }
        return Self.range(
            offset: tokens[index].payloadOffset,
            size: tokens[index].payloadSize
        )
    }

    func integer(at index: Int) -> Int64? {
        guard tokens[index].kind == .integer else {
            return nil
        }
        return tokens[index].integer
    }

    func firstChild(of index: Int) -> Int? {
        let child = tokens[index].firstChildIndex
        return child >= 0 ? Int(child) : nil
    }

    func nextSibling(of index: Int) -> Int? {
        let sibling = tokens[index].nextSiblingIndex
        return sibling >= 0 ? Int(sibling) : nil
    }

    func childCount(of index: Int) -> Int {
        Int(tokens[index].childCount)
    }

    func dictionaryKeyRange(forChild index: Int) -> Range<Int>? {
        let token = tokens[index]
        guard token.dictionaryKeyOffset != Self.missingOffset else {
            return nil
        }
        return Self.range(
            offset: token.dictionaryKeyOffset,
            size: token.dictionaryKeySize
        )
    }

    func value(
        named name: String,
        inDictionaryAt dictionaryIndex: Int
    ) -> Int? {
        guard kind(at: dictionaryIndex) == .dictionary else {
            return nil
        }
        let expected = name.utf8
        var child = firstChild(of: dictionaryIndex)
        while let index = child {
            if let keyRange = dictionaryKeyRange(forChild: index) {
                if bytes(in: keyRange, equalTo: expected) {
                    return index
                }
                // Canonical dictionaries are strictly sorted, so a key after
                // the requested one proves it is absent.
                if expected.lexicographicallyPrecedes(data[keyRange]) {
                    return nil
                }
            }
            child = nextSibling(of: index)
        }
        return nil
    }

    func bytes<C: Collection>(
        in range: Range<Int>,
        equalTo expected: C
    ) -> Bool where C.Element == UInt8 {
        guard range.count == expected.count else {
            return false
        }
        return zip(data[range], expected).allSatisfy(==)
    }

    static func scan(
        _ data: Data,
        limits: BencodeScanLimits,
        checkCancellation: () throws -> Void = {}
    ) throws -> Self {
        let ownedData = data.startIndex == 0 ? data : Data(data)
        guard ownedData.count < Int(missingOffset) else {
            throw BencodeScanError.stringLimitExceeded
        }
        var scanner = Scanner(data: ownedData, limits: limits)
        return try scanner.scan(checkCancellation: checkCancellation)
    }

    private static func range(offset: UInt32, size: UInt32) -> Range<Int> {
        let lowerBound = Int(offset)
        return lowerBound..<(lowerBound + Int(size))
    }

    private struct Scanner {
        private enum ContainerKind {
            case list
            case dictionary
        }

        private struct Frame {
            let tokenIndex: Int
            let startOffset: Int
            let kind: ContainerKind
            var lastChildIndex = -1
            var pendingDictionaryKey: Range<Int>?
            var previousDictionaryKey: Range<Int>?
        }

        private let data: Data
        private let limits: BencodeScanLimits
        private var offset = 0
        private var valueCount = 0
        private var containerCount = 0
        private var dictionaryKeyBytes = 0
        private var tokens = [Token]()
        private var frames = [Frame]()
        private var rootIndex: Int?

        init(data: Data, limits: BencodeScanLimits) {
            self.data = data
            self.limits = limits
            tokens.reserveCapacity(max(0, min(limits.maximumValueCount, data.count)))
            frames.reserveCapacity(max(0, min(limits.maximumNestingDepth, data.count)))
        }

        mutating func scan(
            checkCancellation: () throws -> Void
        ) throws -> BencodeRangeDocument {
            guard limits.maximumNestingDepth >= 0,
                  limits.maximumValueCount > 0,
                  limits.maximumStringBytes >= 0,
                  limits.maximumContainerCount >= 0,
                  limits.maximumDictionaryKeyBytes >= 0,
                  limits.maximumIntegerDigits > 0,
                  limits.maximumStringLengthDigits > 0 else {
                throw BencodeScanError.malformed
            }
            guard limits.maximumValueCount <= Int(Int32.max) else {
                throw BencodeScanError.valueLimitExceeded
            }

            try checkCancellation()
            while rootIndex == nil || !frames.isEmpty {
                guard offset < data.count else {
                    throw BencodeScanError.malformed
                }

                if let frame = frames.last {
                    if data[offset] == UInt8(ascii: "e") {
                        guard frame.pendingDictionaryKey == nil else {
                            throw BencodeScanError.malformed
                        }
                        try closeContainer()
                        continue
                    }
                    if frame.kind == .dictionary,
                       frame.pendingDictionaryKey == nil {
                        try parseDictionaryKey(
                            checkCancellation: checkCancellation
                        )
                        continue
                    }
                }

                try parseValue(checkCancellation: checkCancellation)
            }

            guard let rootIndex, offset == data.count else {
                throw BencodeScanError.malformed
            }
            try checkCancellation()
            return BencodeRangeDocument(
                data: data,
                rootIndex: rootIndex,
                tokens: tokens
            )
        }

        private mutating func parseValue(
            checkCancellation: () throws -> Void
        ) throws {
            guard frames.count <= limits.maximumNestingDepth else {
                throw BencodeScanError.nestingLimitExceeded
            }
            try recordValue(checkCancellation: checkCancellation)
            guard offset < data.count else {
                throw BencodeScanError.malformed
            }

            switch data[offset] {
            case UInt8(ascii: "i"):
                let start = offset
                let integer = try parseInteger()
                try appendScalar(
                    kind: .integer,
                    encodedRange: start..<offset,
                    payloadRange: nil,
                    integer: integer
                )
            case UInt8(ascii: "l"):
                try openContainer(kind: .list)
            case UInt8(ascii: "d"):
                try openContainer(kind: .dictionary)
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                let start = offset
                let payload = try parseStringRange()
                try appendScalar(
                    kind: .string,
                    encodedRange: start..<offset,
                    payloadRange: payload,
                    integer: 0
                )
            default:
                throw BencodeScanError.malformed
            }
        }

        private mutating func recordValue(
            checkCancellation: () throws -> Void
        ) throws {
            let next = valueCount.addingReportingOverflow(1)
            guard !next.overflow,
                  next.partialValue <= limits.maximumValueCount else {
                throw BencodeScanError.valueLimitExceeded
            }
            valueCount = next.partialValue
            if valueCount.isMultiple(of: 256) {
                try checkCancellation()
            }
        }

        private mutating func parseDictionaryKey(
            checkCancellation: () throws -> Void
        ) throws {
            guard data[offset] >= UInt8(ascii: "0"),
                  data[offset] <= UInt8(ascii: "9") else {
                throw BencodeScanError.malformed
            }
            try recordValue(checkCancellation: checkCancellation)
            let key = try parseStringRange()
            let nextKeyBytes = dictionaryKeyBytes.addingReportingOverflow(key.count)
            guard !nextKeyBytes.overflow,
                  nextKeyBytes.partialValue <= limits.maximumDictionaryKeyBytes else {
                throw BencodeScanError.dictionaryKeyByteLimitExceeded
            }
            dictionaryKeyBytes = nextKeyBytes.partialValue

            let frameIndex = frames.index(before: frames.endIndex)
            if let previous = frames[frameIndex].previousDictionaryKey,
               !lexicographicallyPrecedes(previous, key) {
                throw BencodeScanError.malformed
            }
            frames[frameIndex].previousDictionaryKey = key
            frames[frameIndex].pendingDictionaryKey = key
        }

        private mutating func openContainer(kind: ContainerKind) throws {
            let next = containerCount.addingReportingOverflow(1)
            guard !next.overflow,
                  next.partialValue <= limits.maximumContainerCount else {
                throw BencodeScanError.containerLimitExceeded
            }
            containerCount = next.partialValue

            let start = offset
            offset += 1
            let tokenKind: BencodeValueKind = kind == .list ? .list : .dictionary
            let tokenIndex = tokens.count
            guard let token = token(
                kind: tokenKind,
                encodedRange: start..<start,
                payloadRange: nil,
                integer: 0
            ) else {
                throw BencodeScanError.malformed
            }
            tokens.append(token)
            try attach(tokenIndex)
            frames.append(Frame(
                tokenIndex: tokenIndex,
                startOffset: start,
                kind: kind
            ))
        }

        private mutating func closeContainer() throws {
            offset += 1
            let frame = frames.removeLast()
            guard let size = UInt32(exactly: offset - frame.startOffset) else {
                throw BencodeScanError.malformed
            }
            tokens[frame.tokenIndex].encodedSize = size
        }

        private mutating func appendScalar(
            kind: BencodeValueKind,
            encodedRange: Range<Int>,
            payloadRange: Range<Int>?,
            integer: Int64
        ) throws {
            let tokenIndex = tokens.count
            guard let token = token(
                kind: kind,
                encodedRange: encodedRange,
                payloadRange: payloadRange,
                integer: integer
            ) else {
                throw BencodeScanError.malformed
            }
            tokens.append(token)
            try attach(tokenIndex)
        }

        private mutating func attach(_ tokenIndex: Int) throws {
            guard !frames.isEmpty else {
                rootIndex = tokenIndex
                return
            }
            guard let compactTokenIndex = Int32(exactly: tokenIndex) else {
                throw BencodeScanError.valueLimitExceeded
            }

            let frameIndex = frames.index(before: frames.endIndex)
            let parentTokenIndex = frames[frameIndex].tokenIndex
            if frames[frameIndex].kind == .dictionary {
                guard let key = frames[frameIndex].pendingDictionaryKey,
                      let keyOffset = UInt32(exactly: key.lowerBound),
                      let keySize = UInt32(exactly: key.count) else {
                    throw BencodeScanError.malformed
                }
                tokens[tokenIndex].dictionaryKeyOffset = keyOffset
                tokens[tokenIndex].dictionaryKeySize = keySize
                frames[frameIndex].pendingDictionaryKey = nil
            }
            if frames[frameIndex].lastChildIndex >= 0 {
                tokens[frames[frameIndex].lastChildIndex].nextSiblingIndex = compactTokenIndex
            } else {
                tokens[parentTokenIndex].firstChildIndex = compactTokenIndex
            }
            frames[frameIndex].lastChildIndex = tokenIndex
            let nextCount = tokens[parentTokenIndex].childCount.addingReportingOverflow(1)
            guard !nextCount.overflow else {
                throw BencodeScanError.valueLimitExceeded
            }
            tokens[parentTokenIndex].childCount = nextCount.partialValue
        }

        private func token(
            kind: BencodeValueKind,
            encodedRange: Range<Int>,
            payloadRange: Range<Int>?,
            integer: Int64
        ) -> Token? {
            guard let encodedOffset = UInt32(exactly: encodedRange.lowerBound),
                  let encodedSize = UInt32(exactly: encodedRange.count) else {
                return nil
            }
            let payloadOffset: UInt32
            let payloadSize: UInt32
            if let payloadRange {
                guard let offset = UInt32(exactly: payloadRange.lowerBound),
                      let size = UInt32(exactly: payloadRange.count) else {
                    return nil
                }
                payloadOffset = offset
                payloadSize = size
            } else {
                payloadOffset = BencodeRangeDocument.missingOffset
                payloadSize = 0
            }
            return Token(
                kind: kind,
                encodedOffset: encodedOffset,
                encodedSize: encodedSize,
                payloadOffset: payloadOffset,
                payloadSize: payloadSize,
                integer: integer,
                firstChildIndex: -1,
                nextSiblingIndex: -1,
                dictionaryKeyOffset: BencodeRangeDocument.missingOffset,
                dictionaryKeySize: 0,
                childCount: 0
            )
        }

        private mutating func parseInteger() throws -> Int64 {
            offset += 1
            guard offset < data.count else {
                throw BencodeScanError.malformed
            }
            let isNegative = data[offset] == UInt8(ascii: "-")
            if isNegative {
                offset += 1
            }
            let digitStart = offset
            guard offset < data.count,
                  isDigit(data[offset]) else {
                throw BencodeScanError.malformed
            }

            var magnitude: UInt64 = 0
            var digitCount = 0
            while offset < data.count,
                  data[offset] != UInt8(ascii: "e") {
                guard isDigit(data[offset]) else {
                    throw BencodeScanError.malformed
                }
                digitCount += 1
                guard digitCount <= limits.maximumIntegerDigits else {
                    throw BencodeScanError.integerDigitLimitExceeded
                }
                let multiplied = magnitude.multipliedReportingOverflow(by: 10)
                let added = multiplied.partialValue.addingReportingOverflow(
                    UInt64(data[offset] - UInt8(ascii: "0"))
                )
                guard !multiplied.overflow, !added.overflow else {
                    throw BencodeScanError.malformed
                }
                magnitude = added.partialValue
                offset += 1
            }
            guard offset < data.count,
                  digitCount > 0,
                  !(data[digitStart] == UInt8(ascii: "0") && digitCount > 1),
                  !(isNegative && magnitude == 0) else {
                throw BencodeScanError.malformed
            }
            offset += 1

            if isNegative {
                let minimumMagnitude = UInt64(Int64.max) + 1
                guard magnitude <= minimumMagnitude else {
                    throw BencodeScanError.malformed
                }
                return magnitude == minimumMagnitude
                    ? Int64.min
                    : -Int64(magnitude)
            }
            guard magnitude <= UInt64(Int64.max) else {
                throw BencodeScanError.malformed
            }
            return Int64(magnitude)
        }

        private mutating func parseStringRange() throws -> Range<Int> {
            let lengthStart = offset
            var length = 0
            var digitCount = 0
            while offset < data.count,
                  data[offset] != UInt8(ascii: ":") {
                guard isDigit(data[offset]) else {
                    throw BencodeScanError.malformed
                }
                digitCount += 1
                guard digitCount <= limits.maximumStringLengthDigits else {
                    throw BencodeScanError.stringLengthDigitLimitExceeded
                }
                let multiplied = length.multipliedReportingOverflow(by: 10)
                let added = multiplied.partialValue.addingReportingOverflow(
                    Int(data[offset] - UInt8(ascii: "0"))
                )
                guard !multiplied.overflow, !added.overflow else {
                    throw BencodeScanError.malformed
                }
                length = added.partialValue
                offset += 1
            }
            guard offset < data.count,
                  digitCount > 0,
                  !(data[lengthStart] == UInt8(ascii: "0") && digitCount > 1) else {
                throw BencodeScanError.malformed
            }
            guard length <= limits.maximumStringBytes else {
                throw BencodeScanError.stringLimitExceeded
            }
            offset += 1
            guard length <= data.count - offset else {
                throw BencodeScanError.malformed
            }
            let payload = offset..<(offset + length)
            offset += length
            return payload
        }

        private func lexicographicallyPrecedes(
            _ left: Range<Int>,
            _ right: Range<Int>
        ) -> Bool {
            data[left].lexicographicallyPrecedes(data[right])
        }

        private func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }
    }
}
