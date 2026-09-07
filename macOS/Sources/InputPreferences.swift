import Foundation

enum InputOption: String, CaseIterable, Sendable {
    case abbreviation, typoTolerance, fuzzyZ, fuzzyC, fuzzyS
    case emoji, bracketPaging, minusEqualPaging
    case englishPunctuation, cornerQuotes, middleDot, fullwidthPipe, ideographicComma
    case traditional

    var defaultValue: Bool {
        switch self {
        case .fuzzyZ, .fuzzyC, .fuzzyS, .englishPunctuation, .traditional: false
        default: true
        }
    }
}

/// A value snapshot belongs to one composition, even while persisted preferences change.
struct InputPreferences: Equatable, Sendable {
    private let values: [InputOption: Bool]
    init(_ values: [InputOption: Bool] = [:]) {
        self.values = Dictionary(uniqueKeysWithValues: InputOption.allCases.map { ($0, values[$0] ?? $0.defaultValue) })
    }
    subscript(_ option: InputOption) -> Bool { values[option]! }
    var recordedValues: [String: Bool] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }
    func setting(_ option: InputOption, to value: Bool) -> Self {
        var updated = values
        updated[option] = value
        return Self(updated)
    }
    var spellingProfile: String {
        let bits: [InputOption] = [.abbreviation, .typoTolerance, .fuzzyZ, .fuzzyC, .fuzzyS]
        let mask = bits.enumerated().reduce(0) { $0 | (self[$1.element] ? 1 << $1.offset : 0) }
        return Self.spellingProfile(mask)
    }
    static func spellingProfile(_ mask: Int) -> String { "inkflow_spelling_\(mask)" }
    static let compiledSpellingFiles = (0..<32).flatMap {
        [spellingProfile($0) + ".schema.yaml", spellingProfile($0) + ".prism.bin"]
    }

    /// Replace entire config nodes so Rime's existing components retain their own snapshots.
    var schemaPatch: String {
        var bindings: [String] = []
        if self[.bracketPaging] {
            bindings += ["{ when: has_menu, accept: bracketleft, send: Page_Up }",
                         "{ when: has_menu, accept: bracketright, send: Page_Down }"]
        }
        if self[.minusEqualPaging] {
            bindings += ["{ when: has_menu, accept: minus, send: Page_Up }",
                         "{ when: has_menu, accept: equal, send: Page_Down }"]
        }
        return """
        key_binder:
          bindings: [\(bindings.joined(separator: ", "))]
        punctuator:
          half_shape:
            ',': '，'
            '.': '。'
            '?': '？'
            '!': '！'
            ':': '：'
            ';': '；'
            '(': '（'
            ')': '）'
            '{': '\(self[.cornerQuotes] ? "「" : "{")'
            '}': '\(self[.cornerQuotes] ? "」" : "}")'
            '[': '【'
            ']': '】'
            '<': '《'
            '>': '》'
            '\\': '\(self[.ideographicComma] ? "、" : "\\")'
            '|': '\(self[.fullwidthPipe] ? "｜" : "|")'
            '`': '\(self[.middleDot] ? "·" : "`")'
            '~': '～'
            '$': '¥'
            '^': '……'
            '_': '——'
            '"': { pair: ['“', '”'] }
            "'": { pair: ['‘', '’'] }
        """
    }
}
