import Foundation

func bencodeTestDictionary(
    _ fields: [(String, Data)],
    sortedKeys: Bool = false
) -> Data {
    let ordered = sortedKeys ? fields.sorted {
        $0.0.utf8.lexicographicallyPrecedes($1.0.utf8)
    } : fields
    var result = Data([UInt8(ascii: "d")])
    for (key, value) in ordered {
        result.append(Data("\(key.utf8.count):\(key)".utf8))
        result.append(value)
    }
    result.append(UInt8(ascii: "e"))
    return result
}

func bencodeTestString(_ value: Data) -> Data {
    Data("\(value.count):".utf8) + value
}

func bencodeTestInteger(_ value: Int64) -> Data {
    Data("i\(value)e".utf8)
}

func allPermutations<Element>(_ elements: [Element]) -> [[Element]] {
    guard elements.count > 1 else {
        return [elements]
    }
    return elements.indices.flatMap { index in
        var remainder = elements
        let selected = remainder.remove(at: index)
        return allPermutations(remainder).map { [selected] + $0 }
    }
}
