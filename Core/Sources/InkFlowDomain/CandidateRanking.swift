import Foundation

/// The context index builder and the preceding-text limit. The Rust core does the ranking: it
/// reads this index (`Core/Portable/src/ranking.rs`), and tests compare its output with this
/// builder's bytes.
package enum IFContextRanker {
    package static let contextLimit = 16
    private static let magic = Array("IFCX".utf8)
    private static let version: UInt32 = 2
    private static let phraseLimit = 8

    /// Builds the index the preparation worker and build scripts ship beside the dictionary.
    package static func buildIndex(dictionary: Data) throws -> Data {
        guard let text = String(data: dictionary, encoding: .utf8) else {
            throw IFDictionaryError("context-index", "Expected a UTF-8 dictionary")
        }
        var frequencies: [Data: Int] = [:]
        var longest = 0
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 3, let frequency = Int(fields[2]), frequency >= 0 else { continue }
            let phrase = String(fields[0])
            guard (2...phraseLimit).contains(phrase.count), phrase.allSatisfy(Self.isHan) else { continue }
            let syllables = fields[1].split(whereSeparator: { $0.isWhitespace })
            var terminal = Array((syllables.last ?? "").utf8)
            if syllables.count != phrase.count || terminal.count > 6
                || !terminal.allSatisfy({ (97...122).contains($0) }) {
                terminal = []
            }
            let key = Data(encode(phrase) + terminal + Array(repeating: 0, count: 6 - terminal.count))
            frequencies[key] = max(frequencies[key] ?? 0, frequency)
            longest = max(longest, phrase.count)
        }
        var tables = Array(repeating: [(key: [UInt8], frequency: UInt64)](), count: phraseLimit - 1)
        for (key, frequency) in frequencies {
            tables[(key.count - 6) / 3 - 2].append((Array(key), UInt64(frequency)))
        }
        var data = Data()
        data.append(contentsOf: magic)
        for value in [version, UInt32(longest)] + tables.map({ UInt32($0.count) }) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        for table in tables {
            for record in table.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
                data.append(contentsOf: record.key)
                withUnsafeBytes(of: record.frequency.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    /// Three bytes per scalar in canonical form, so byte order is the table order.
    private static func encode(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            bytes.append(contentsOf: [UInt8(truncatingIfNeeded: scalar.value >> 16),
                                      UInt8(truncatingIfNeeded: scalar.value >> 8), UInt8(truncatingIfNeeded: scalar.value)])
        }
        return bytes
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1 && character.unicodeScalars.allSatisfy {
            switch $0.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x20000...0x2FA1F, 0x30000...0x323AF: true
            default: false
            }
        }
    }
}
