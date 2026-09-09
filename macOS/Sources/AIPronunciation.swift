import Foundation

/// Disposable readings from the active generated dictionary, never a second user dictionary.
struct AIPronunciation: Sendable {
    private let phrases: [String: Set<String>]
    private let characters: [Character: Set<String>]

    init(phrases: [String: Set<String>], characters: [Character: Set<String>]) {
        self.phrases = phrases
        self.characters = characters
    }

    /// One recommendation's native readings; no corpus scan or persistent index.
    init(text: String, nativeReadings: String) {
        var phrases: [String: Set<String>] = [:], characters: [Character: Set<String>] = [:]
        for line in nativeReadings.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if fields.count == 2, fields[0] == "P" {
                let code = String(fields[1])
                if code.split(separator: " ").count == text.count { phrases[text, default: []].insert(code) }
            } else if fields.count == 3, fields[0] == "C", fields[1].count == 1, let character = fields[1].first {
                let codes = Set(fields[2].split(separator: " ").map(String.init))
                if !codes.isEmpty { characters[character] = codes }
            }
        }
        self.init(phrases: phrases, characters: characters)
    }

    private func phraseReadings(_ text: String) -> Set<String> { phrases[text] ?? [] }

    /// Returns one supported reading only. Equal-cost alternatives remain ambiguous.
    func resolve(input: String, text: String, preferences: InputPreferences = .init()) -> String? {
        let codes = matchingCodes(input: input, text: text, preferences: preferences)
        return codes.count == 1 ? codes.first : nil
    }

    private func matchingCodes(input: String, text: String, preferences: InputPreferences) -> Set<String> {
        let raw = input.lowercased().replacingOccurrences(of: "ü", with: "v")
        guard raw.utf8.allSatisfy({ (97...122).contains($0) || $0 == 39 || $0 == 32 }),
              !raw.isEmpty, !text.isEmpty else { return [] }
        let units = Array(raw.utf8)
        let exact = phraseReadings(text).map { $0.split(separator: " ").map { [String($0)] } }
        let readings = text.map { Array(characters[$0] ?? []).sorted() }
        let alternatives = exact + (readings.allSatisfy({ !$0.isEmpty }) ? [readings] : [])
        guard !alternatives.isEmpty else { return [] }
        // Learning permits isolated edits, not a rewrite. This never gates recommendation display.
        let budget = preferences[.typoTolerance] ? min(2, max(1, units.count / 8)) : 0
        var best = Int.max, winners = Set<String>()
        for (alternativeIndex, readings) in alternatives.enumerated() {
            var states: [Int: (cost: Int, codes: Set<String>)] = [0: (0, [""])]
            for (index, options) in readings.enumerated() {
                var next: [Int: (cost: Int, codes: Set<String>)] = [:]
                for (position, state) in states {
                    var start = position
                    while start < units.count && (units[start] == 39 || units[start] == 32) { start += 1 }
                    guard start < units.count else { continue }
                    let end = (start..<units.count).first { units[$0] == 39 || units[$0] == 32 } ?? units.count
                    for syllable in options {
                        let aliases = Self.aliases(syllable, preferences: preferences)
                        for length in 1...min(end - start, max(syllable.utf8.count + 1, 2)) {
                            let typed = String(decoding: units[start..<start + length], as: UTF8.self)
                            var cost: Int?
                            if aliases.contains(typed) { cost = 0 }
                            if preferences[.abbreviation], aliases.contains(where: { Self.initial($0) == typed || String($0.prefix(1)) == typed }) { cost = 0 }
                            if index == readings.count - 1, start + length == units.count,
                               aliases.contains(where: { $0.hasPrefix(typed) }) { cost = 0 }
                            if cost == nil, budget > 0, typed.count >= 2,
                               aliases.contains(where: { Self.oneEdit(typed, $0) }) { cost = 1 }
                            guard let cost, state.cost + cost <= budget else { continue }
                            let total = state.cost + cost, target = start + length
                            let codes = Set(state.codes.map { $0 + syllable + " " })
                            if next[target] == nil || total < next[target]!.cost {
                                next[target] = (total, codes)
                            } else if total == next[target]!.cost {
                                next[target]!.codes.formUnion(codes)
                            }
                            // Two distinct paths suffice to preserve ambiguity without exponential storage.
                            if next[target]!.codes.count > 2 { next[target]!.codes = Set(next[target]!.codes.sorted().prefix(2)) }
                        }
                    }
                }
                states = next
            }
            for (position, state) in states where units[position...].allSatisfy({ $0 == 39 || $0 == 32 }) {
                if state.cost < best { best = state.cost; winners = state.codes }
                else if state.cost == best { winners.formUnion(state.codes) }
            }
            // A dictionary phrase can disambiguate abbreviation, but cannot replace an
            // explicitly typed alternative reading with a corrected dictionary reading.
            if alternativeIndex == exact.count - 1 && best == 0 { return winners }
        }
        return winners
    }

    /// Reject only positive evidence of continuation: a proper output prefix already
    /// exactly consumes the full spelling, and the complete output has no alignment.
    func isClearExpansion(input: String, text: String, preferences: InputPreferences = .init()) -> Bool {
        let content = text.filter { character in
            !character.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.whitespaces.contains($0) }
        }
        guard content.count > 1, content.allSatisfy({ characters[$0] != nil }),
              matchingCodes(input: input, text: content, preferences: preferences).isEmpty else { return false }
        let spelling = input.lowercased().filter { $0 != "'" && $0 != " " }
        let strict = preferences.setting(.abbreviation, to: false).setting(.typoTolerance, to: false)
        for count in 1..<content.count {
            if let code = resolve(input: input, text: String(content.prefix(count)), preferences: strict),
               code.replacingOccurrences(of: " ", with: "") == spelling { return true }
        }
        return false
    }

    private static func aliases(_ syllable: String, preferences: InputPreferences) -> Set<String> {
        var result: Set<String> = [syllable]
        if syllable.hasPrefix("nue") || syllable.hasPrefix("lue") { result.insert(syllable.replacingOccurrences(of: "ue", with: "ve")) }
        if ["j", "q", "x", "y"].contains(String(syllable.prefix(1))) { result.insert(syllable.replacingOccurrences(of: "u", with: "v")) }
        for (prefix, option) in [("z", InputOption.fuzzyZ), ("c", .fuzzyC), ("s", .fuzzyS)] where preferences[option] {
            for value in Array(result) where value.hasPrefix(prefix) {
                result.insert(value.hasPrefix(prefix + "h") ? prefix + value.dropFirst(2) : prefix + "h" + value.dropFirst())
            }
        }
        return result
    }

    private static func initial(_ syllable: String) -> String {
        ["zh", "ch", "sh"].first(where: { syllable.hasPrefix($0) }) ?? String(syllable.prefix(1))
    }

    private static func oneEdit(_ left: String, _ right: String) -> Bool {
        let a = Array(left), b = Array(right)
        if a.count == b.count {
            let differences = a.indices.filter { a[$0] != b[$0] }
            if differences.count == 1 { return true }
            return differences.count == 2 && differences[1] == differences[0] + 1 &&
                a[differences[0]] == b[differences[1]] && a[differences[1]] == b[differences[0]]
        }
        guard abs(a.count - b.count) == 1 else { return false }
        let shorter = a.count < b.count ? a : b, longer = a.count < b.count ? b : a
        var index = 0
        while index < shorter.count && shorter[index] == longer[index] { index += 1 }
        return Array(shorter.dropFirst(index)) == Array(longer.dropFirst(index + 1))
    }

}
