import Foundation

package enum InputOption: String, CaseIterable, Sendable {
    case abbreviation, typoTolerance, fuzzyZ, fuzzyC, fuzzyS
    case emoji, bracketPaging, minusEqualPaging
    case englishPunctuation, cornerQuotes, middleDot, fullwidthPipe, ideographicComma
    case traditional

    package var defaultValue: Bool {
        switch self {
        case .fuzzyZ, .fuzzyC, .fuzzyS, .englishPunctuation, .traditional: false
        default: true
        }
    }
}

package struct InputPreferences: Equatable, Sendable {
    private let values: [InputOption: Bool]
    package init(_ values: [InputOption: Bool] = [:]) {
        self.values = Dictionary(uniqueKeysWithValues: InputOption.allCases.map { ($0, values[$0] ?? $0.defaultValue) })
    }
    package subscript(_ option: InputOption) -> Bool { values[option]! }
    package var recordedValues: [String: Bool] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }
    package func setting(_ option: InputOption, to value: Bool) -> Self {
        var updated = values
        updated[option] = value
        return Self(updated)
    }
    package var spellingProfile: String {
        let bits: [InputOption] = [.abbreviation, .typoTolerance, .fuzzyZ, .fuzzyC, .fuzzyS]
        let mask = bits.enumerated().reduce(0) { $0 | (self[$1.element] ? 1 << $1.offset : 0) }
        return Self.spellingProfile(mask)
    }
    package static func spellingProfile(_ mask: Int) -> String { "inkflow_spelling_\(mask)" }
    package static let compiledSpellingFiles = (0..<32).flatMap {
        [spellingProfile($0) + ".schema.yaml", spellingProfile($0) + ".prism.bin"]
    }
}
