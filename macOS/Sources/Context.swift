@preconcurrency import InputMethodKit
import Carbon

/// A bounded, disposable prefix from the active document. All ranges are UTF-16.
enum IFPrecedingText {
    static let limit = 16

    @MainActor static func read(from client: IMKTextInput?, ownsMarkedText: Bool,
                                secureInput: Bool = IsSecureEventInputEnabled()) -> String {
        guard !secureInput, let client else { return "" }
        let selection = client.selectedRange()
        guard valid(selection) else { return "" }
        let mark = client.markedRange()
        let anchor: Int
        if ownsMarkedText {
            guard valid(mark), mark.length > 0, selection.location >= mark.location,
                  NSMaxRange(selection) <= NSMaxRange(mark) else { return "" }
            anchor = mark.location
        } else {
            // Another owner's composition is not committed surrounding text.
            guard !valid(mark) || mark.length == 0 else { return "" }
            anchor = selection.location
        }
        guard anchor > 0 else { return "" }
        let request = NSRange(location: max(0, anchor - limit), length: min(anchor, limit))
        var actual = request
        guard let text = client.string(from: request, actualRange: &actual), valid(actual),
              actual.length == text.utf16.count,
              actual.location >= max(0, request.location - 1), actual.location < anchor,
              NSMaxRange(actual) >= anchor, NSMaxRange(actual) - anchor <= 1
        else { return "" }
        // The client may expand a request to include a complete surrogate pair.
        // Only text strictly before the anchor is eligible, never selection/marked text.
        let units = text.utf16
        let end = units.index(units.startIndex, offsetBy: anchor - actual.location)
        guard end == units.endIndex || !(0xDC00...0xDFFF).contains(units[end]) else { return "" }
        return String(decoding: units[..<end], as: UTF16.self)
    }

    private static func valid(_ range: NSRange) -> Bool {
        range.location >= 0 && range.location != NSNotFound && range.length >= 0 &&
        range.length != NSNotFound && range.length <= Int.max - range.location
    }
}

/// Exact dictionary phrases crossing the prefix/candidate boundary, not a language model.
struct IFContextRanker: Sendable {
    private let frequencies: [String: Int]
    private let longestPhrase: Int

    init(dictionary: String) throws {
        let text = try String(contentsOfFile: dictionary, encoding: .utf8)
        var frequencies: [String: Int] = [:]
        var longest = 0
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 3, let frequency = Int(fields[2]), frequency >= 0 else { continue }
            let phrase = String(fields[0])
            guard (2...8).contains(phrase.count), phrase.allSatisfy(Self.isHan) else { continue }
            frequencies[phrase] = max(frequencies[phrase] ?? 0, frequency)
            longest = max(longest, phrase.count)
        }
        self.frequencies = frequencies
        longestPhrase = longest
    }

    func order(_ candidates: [String], precedingText: String) -> [Int] {
        let original = Array(candidates.indices)
        guard let first = candidates.first, longestPhrase > 1 else { return original }
        let prefix = Array(precedingText.suffix(longestPhrase - 1).reversed().prefix(while: Self.isHan).reversed())
        guard !prefix.isEmpty else { return original }
        let scores = candidates.map { candidate -> (length: Int, frequency: Int) in
            // Candidate APIs expose no consumed-input span. Keep shorter partial choices
            // in place by restricting promotion to the original first candidate's length.
            guard candidate.count == first.count, candidate.allSatisfy(Self.isHan) else { return (0, 0) }
            for count in stride(from: prefix.count, through: 1, by: -1) {
                if let frequency = frequencies[String(prefix.suffix(count)) + candidate] {
                    return (count, frequency)
                }
            }
            return (0, 0)
        }
        let eligible = original.filter {
            candidates[$0].count == first.count && candidates[$0].allSatisfy(Self.isHan)
        }
        let ranked = eligible.sorted {
            if scores[$0].length != scores[$1].length { return scores[$0].length > scores[$1].length }
            if scores[$0].frequency != scores[$1].frequency { return scores[$0].frequency > scores[$1].frequency }
            return $0 < $1
        }
        var result = original
        for (slot, candidate) in zip(eligible, ranked) { result[slot] = candidate }
        return result
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
