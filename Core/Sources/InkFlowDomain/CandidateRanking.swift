import Foundation

package struct IFCandidateRankingMetadata: Equatable, Sendable {
    package enum CandidateClass: String, Sendable { case nonASCII = "n", ascii = "a", mixed = "m", other = "o" }
    package enum Source: String, Sendable { case native = "n", english = "e", mixed = "m", custom = "c" }

    package let coverage: Range<Int>
    package let candidateClass: CandidateClass
    package let exact: Bool
    package let personalBucket: Int
    package let source: Source
    package init(coverage: Range<Int>,
        candidateClass: CandidateClass,
        exact: Bool,
        personalBucket: Int,
        source: Source) {
        self.coverage = coverage
        self.candidateClass = candidateClass
        self.exact = exact
        self.personalBucket = personalBucket
        self.source = source
    }

}

/// Exact dictionary phrases plus bounded, content-free Rime evidence, not a language model.
///
/// Phrases live in a sorted, fixed-width index built once at dictionary preparation and read
/// whole into memory when the ranker loads, so no key-event path parses, maps or faults in
/// the dictionary.
package struct IFContextRanker: Sendable {
    package static let contextLimit = 16
    private static let magic = Array("IFCX".utf8)
    private static let version: UInt32 = 1
    private static let phraseLimit = 8
    private static let headerSize = 12 + (phraseLimit - 1) * 4
    private let index: Data
    private let longestPhrase: Int
    /// One sorted, fixed-width table per phrase length, so a lookup knows its table from its key.
    private let tables: [(offset: Int, count: Int)]

    package init(index path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count >= Self.headerSize, Array(data.prefix(4)) == Self.magic else {
            throw IFDictionaryError("context-index", "Expected an InkFlow context index")
        }
        func field(_ position: Int) -> Int {
            Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4 * position, as: UInt32.self)) })
        }
        var tables: [(offset: Int, count: Int)] = []
        var offset = Self.headerSize
        for length in 2...Self.phraseLimit {
            tables.append((offset, field(length + 1)))
            offset += tables.last!.count * Self.recordSize(length: length)
        }
        guard field(1) == Int(Self.version), field(2) <= Self.phraseLimit, offset == data.count else {
            throw IFDictionaryError("context-index", "Unsupported or truncated context index")
        }
        index = data
        longestPhrase = field(2)
        self.tables = tables
    }

    /// Builds the index the preparation worker and build scripts ship beside the dictionary.
    package static func buildIndex(dictionary: Data) throws -> Data {
        guard let text = String(data: dictionary, encoding: .utf8) else {
            throw IFDictionaryError("context-index", "Expected a UTF-8 dictionary")
        }
        var frequencies: [String: Int] = [:]
        var longest = 0
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 3, let frequency = Int(fields[2]), frequency >= 0 else { continue }
            let phrase = String(fields[0])
            guard (2...phraseLimit).contains(phrase.count), phrase.allSatisfy(Self.isHan) else { continue }
            frequencies[phrase] = max(frequencies[phrase] ?? 0, frequency)
            longest = max(longest, phrase.count)
        }
        var tables = Array(repeating: [(key: [UInt8], frequency: UInt64)](), count: phraseLimit - 1)
        for (phrase, frequency) in frequencies {
            let key = encode(phrase)
            tables[key.count / 3 - 2].append((key, UInt64(frequency)))
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

    private static func recordSize(length: Int) -> Int { length * 3 + 8 }

    /// Three bytes per scalar in canonical form, so byte order is the table order.
    private static func encode(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            bytes.append(contentsOf: [UInt8(truncatingIfNeeded: scalar.value >> 16),
                                      UInt8(truncatingIfNeeded: scalar.value >> 8), UInt8(truncatingIfNeeded: scalar.value)])
        }
        return bytes
    }

    private func frequency(of key: [UInt8]) -> Int? {
        let length = key.count / 3
        guard (2...Self.phraseLimit).contains(length) else { return nil }
        let table = tables[length - 2], recordSize = Self.recordSize(length: length)
        return key.withUnsafeBytes { wanted in
            index.withUnsafeBytes { raw -> Int? in
                var low = 0, high = table.count
                while low < high {
                    let mid = (low + high) / 2
                    let offset = table.offset + mid * recordSize
                    let order = memcmp(raw.baseAddress! + offset, wanted.baseAddress!, key.count)
                    if order < 0 { low = mid + 1 }
                    else if order > 0 { high = mid }
                    else {
                        return Int(truncatingIfNeeded: UInt64(littleEndian:
                            raw.loadUnaligned(fromByteOffset: offset + key.count, as: UInt64.self)))
                    }
                }
                return nil
            }
        }
    }

    package func order(_ candidates: [String], precedingText: String,
               metadata: [IFCandidateRankingMetadata]? = nil) -> [Int] {
        let original = Array(candidates.indices)
        guard !candidates.isEmpty, let metadata, metadata.count == candidates.count,
              metadata.allSatisfy({ $0.coverage.lowerBound >= 0 && !$0.coverage.isEmpty &&
                  (0...3).contains($0.personalBucket) }),
              zip(candidates, metadata).allSatisfy({ Self.consistent(candidate: $0, metadata: $1) })
        else { return original }
        let eligible = original.filter { metadata[$0].coverage == metadata[0].coverage }
        guard !eligible.isEmpty else { return original }

        let prefix = Array(precedingText.suffix(max(0, longestPhrase - 1))
            .reversed().prefix(while: Self.isHan).reversed())
        let prefixKey = Self.encode(String(prefix))
        let scores = candidates.enumerated().map { index, candidate -> (length: Int, frequency: Int) in
            guard eligible.contains(index), !prefix.isEmpty, candidate.count == candidates[0].count,
                  candidate.allSatisfy(Self.isHan) else { return (0, 0) }
            let candidateKey = Self.encode(candidate)
            for count in stride(from: prefix.count, through: 1, by: -1) where count + candidate.count <= Self.phraseLimit {
                if let frequency = frequency(of: prefixKey.suffix(count * 3) + candidateKey) {
                    return (count, frequency)
                }
            }
            return (0, 0)
        }
        let han = eligible.filter { candidates[$0].allSatisfy(Self.isHan) }
        let leadingHan = han.sorted {
            if scores[$0].length != scores[$1].length { return scores[$0].length > scores[$1].length }
            if scores[$0].frequency != scores[$1].frequency { return scores[$0].frequency > scores[$1].frequency }
            return $0 < $1
        }.first
        let technical = Self.hasTechnicalContext(precedingText)
        func evidencePromotes(_ index: Int) -> Bool {
            let row = metadata[index]
            return technical && row.exact && row.personalBucket > 0 &&
                row.source == .english
        }
        func tier(_ index: Int) -> Int {
            let row = metadata[index]
            if row.source == .custom { return 0 }
            if evidencePromotes(index) { return 1 }
            if index == leadingHan { return 2 }
            if row.exact && (row.source == .english || row.source == .mixed) { return 3 }
            if row.exact { return 4 }
            return 5
        }
        let ranked = eligible.sorted {
            let leftTier = tier($0), rightTier = tier($1)
            if leftTier != rightTier { return leftTier < rightTier }
            let left = metadata[$0], right = metadata[$1]
            if left.personalBucket != right.personalBucket { return left.personalBucket > right.personalBucket }
            if scores[$0].length != scores[$1].length { return scores[$0].length > scores[$1].length }
            if scores[$0].frequency != scores[$1].frequency { return scores[$0].frequency > scores[$1].frequency }
            return $0 < $1
        }
        var result = original
        for (slot, candidate) in zip(eligible, ranked) { result[slot] = candidate }
        return result
    }

    /// The ephemeral bridge returns a page identity followed by bounded metadata.
    package static func parseMetadata(_ value: String, offset: Int, count: Int,
                              inputLength: Int) -> [IFCandidateRankingMetadata]? {
        guard offset >= 0, (1...9).contains(count), inputLength > 0 else { return nil }
        let rows = value.split(separator: ";", omittingEmptySubsequences: false)
        guard rows.count == count + 1, rows[0] == "\(offset),\(count)" else { return nil }
        var metadata: [IFCandidateRankingMetadata] = []
        for row in rows.dropFirst() {
            let fields = row.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 6,
                  fields[0...1].allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
                  let start = Int(fields[0]), let end = Int(fields[1]), start < end, end <= inputLength,
                  let candidateClass = IFCandidateRankingMetadata.CandidateClass(rawValue: String(fields[2])),
                  fields[3] == "0" || fields[3] == "1",
                  fields[4].count == 1, let personal = Int(fields[4]), (0...3).contains(personal),
                  let source = IFCandidateRankingMetadata.Source(rawValue: String(fields[5]))
            else { return nil }
            let exact = fields[3] == "1"
            guard personal == 0 || exact && (source == .english || source == .mixed) else { return nil }
            metadata.append(.init(coverage: start..<end, candidateClass: candidateClass,
                                  exact: exact, personalBucket: personal, source: source))
        }
        return metadata
    }

    private static func consistent(candidate: String, metadata: IFCandidateRankingMetadata) -> Bool {
        let hasLetter = candidate.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
        let hasNonASCII = candidate.utf8.contains { $0 >= 0x80 }
        switch metadata.candidateClass {
        case .ascii where !hasLetter || hasNonASCII: return false
        case .mixed where !hasLetter || !hasNonASCII: return false
        case .nonASCII where hasLetter || !hasNonASCII: return false
        case .other where hasLetter || hasNonASCII: return false
        default: break
        }
        switch metadata.source {
        case .english: return metadata.candidateClass == .ascii
        case .mixed: return metadata.candidateClass == .mixed
        case .native: return metadata.personalBucket == 0
        case .custom: return metadata.personalBucket == 0
        }
    }

    private static func hasTechnicalContext(_ text: String) -> Bool {
        let bounded = String(text.suffix(IFContextRanker.contextLimit))
        var run = 0
        for scalar in bounded.unicodeScalars {
            if (65...90).contains(scalar.value) || (97...122).contains(scalar.value) || (48...57).contains(scalar.value) {
                run += 1
                if run >= 2 { return true }
            } else {
                run = 0
            }
        }
        return ["代码", "编程", "开发", "命令", "终端", "接口", "版本"].contains { bounded.hasSuffix($0) }
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
