@preconcurrency import InputMethodKit
import Foundation

private func voiceLatinTokenRanges(_ text: String) -> [NSRange] {
    let value = text as NSString
    var result: [NSRange] = [], start: Int?
    for index in 0...value.length {
        let latin: Bool
        if index < value.length {
            let unit = value.character(at: index)
            latin = (65...90).contains(unit) || (97...122).contains(unit)
        } else {
            latin = false
        }
        if latin, start == nil { start = index }
        if !latin, let tokenStart = start {
            result.append(NSRange(location: tokenStart, length: index - tokenStart))
            start = nil
        }
    }
    return result
}

struct VoiceLearnedCorrection: Equatable, Sendable {
    let sourceCode: String
    let canonicalText: String
}

struct VoiceAliasSnapshot: Equatable, Sendable {
    enum Availability: Sendable { case available, unknown }
    struct Entry: Equatable, Sendable {
        let code: String
        let text: String
        let commits: Int
    }

    static let entryLimit = 512
    static let byteLimit = 64 * 1024
    let generation: UInt64
    let revision: UInt64
    let availability: Availability
    let entries: [Entry]

    static func unknown(generation: UInt64 = 0, revision: UInt64 = 0) -> Self {
        Self(generation: generation, revision: revision, availability: .unknown, entries: [])
    }

    init(generation: UInt64, revision: UInt64, availability: Availability, entries: [Entry]) {
        self.generation = generation
        self.revision = revision
        switch availability {
        case .available where entries.count <= Self.entryLimit:
            self.availability = .available
            self.entries = entries
        default:
            self.availability = .unknown
            self.entries = []
        }
    }

    init(payload: String, generation: UInt64, revision: UInt64) {
        guard payload.utf8.count <= Self.byteLimit, payload.hasPrefix("ok\n") else {
            self = .unknown(generation: generation, revision: revision); return
        }
        var parsed: [Entry] = []
        for row in payload.dropFirst(3).split(separator: "\n") {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, let commits = Int(fields[2]), commits > 0 else {
                self = .unknown(generation: generation, revision: revision); return
            }
            let code = String(fields[0]), text = String(fields[1])
            guard code.utf8.count <= 64, code.utf8.allSatisfy({ (97...122).contains($0) }),
                  text.utf16.count <= 64, !text.isEmpty,
                  text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else {
                self = .unknown(generation: generation, revision: revision); return
            }
            parsed.append(.init(code: code, text: text, commits: commits))
            guard parsed.count <= Self.entryLimit else {
                self = .unknown(generation: generation, revision: revision); return
            }
        }
        self.init(generation: generation, revision: revision, availability: .available, entries: parsed)
    }
}

enum VoiceAliasRewriter {
    struct Result: Equatable, Sendable {
        let text: String
        let matchedDisplays: [String]
        var hitCount: Int { matchedDisplays.count }

        func retainedHitCount(in insertedFinal: String) -> Int {
            var remaining: [String: Int] = [:]
            for display in matchedDisplays { remaining[display, default: 0] += 1 }
            let value = insertedFinal as NSString
            var retained = 0
            for range in voiceLatinTokenRanges(insertedFinal) {
                let token = value.substring(with: range)
                guard let count = remaining[token], count > 0 else { continue }
                retained += 1
                remaining[token] = count - 1
            }
            return retained
        }
    }

    private static let evidenceLimit = 64

    static func apply(_ transcript: String, snapshot: VoiceAliasSnapshot) -> String {
        result(transcript, snapshot: snapshot).text
    }

    static func result(_ transcript: String, snapshot: VoiceAliasSnapshot) -> Result {
        guard snapshot.availability == .available, !snapshot.entries.isEmpty else {
            return Result(text: transcript, matchedDisplays: [])
        }
        var grouped: [String: Set<String>] = [:]
        for entry in snapshot.entries { grouped[entry.code, default: []].insert(entry.text) }
        let mappings = grouped.compactMapValues { $0.count == 1 ? $0.first : nil }
        guard !mappings.isEmpty else { return Result(text: transcript, matchedDisplays: []) }
        let value = transcript as NSString
        var output = "", cursor = 0, matchedDisplays: [String] = []
        for range in voiceLatinTokenRanges(transcript) {
            output += value.substring(with: NSRange(location: cursor, length: range.location - cursor))
            let token = value.substring(with: range)
            if let replacement = mappings[token.lowercased()] {
                output += replacement
                if matchedDisplays.count < evidenceLimit { matchedDisplays.append(replacement) }
            } else { output += token }
            cursor = NSMaxRange(range)
        }
        output += value.substring(from: cursor)
        return Result(text: output, matchedDisplays: matchedDisplays)
    }
}

@MainActor
struct VoiceCorrectionObservation {
    enum Decision: Equatable {
        case pending
        case learn(VoiceLearnedCorrection)
        case discard
    }

    static let textLimit = 4_096
    static let latinTokenLimit = 64
    static let lifetime: Duration = .seconds(8)

    let operationID: UUID
    private let clientIdentity: ObjectIdentifier
    private let clientIdentifier: String
    let sessionRevision: UInt64
    let insertionRange: NSRange
    let rawFinal: String
    let insertedFinal: String
    let expiry: ContinuousClock.Instant
    private let documentLength: Int
    private var attributedTokenIndex: Int?
    private var attributedTokenLength = 0
    private var allowsDocumentGrowth = false
    private var allowsTrailingExtension = false

    static func capture(operationID: UUID, client: IMKTextInput, sessionRevision: UInt64,
                        insertionRange: NSRange, rawFinal: String, insertedFinal: String,
                        now: ContinuousClock.Instant = .now,
                        validateTarget: () -> Bool = { true }) -> Self? {
        guard valid(insertionRange), insertionRange.length == insertedFinal.utf16.count,
              !insertedFinal.isEmpty, insertedFinal.utf16.count <= textLimit,
              rawFinal.utf16.count <= textLimit, validateTarget() else { return nil }
        guard let identifier = client.uniqueClientIdentifierString(), !identifier.isEmpty,
              validateTarget() else { return nil }
        let selection = client.selectedRange()
        guard validateTarget(), valid(selection), selection.length == 0,
              selection.location == NSMaxRange(insertionRange) else { return nil }
        guard client.uniqueClientIdentifierString() == identifier, validateTarget() else { return nil }
        let length = client.length()
        guard validateTarget(), length != NSNotFound, length >= NSMaxRange(insertionRange) else { return nil }
        guard client.uniqueClientIdentifierString() == identifier, validateTarget() else { return nil }
        var actual = insertionRange
        guard let readback = client.string(from: insertionRange, actualRange: &actual),
              validateTarget(), actual == insertionRange, readback == insertedFinal,
              client.uniqueClientIdentifierString() == identifier,
              validateTarget() else { return nil }
        return Self(operationID: operationID, clientIdentity: ObjectIdentifier(client as AnyObject),
                    clientIdentifier: identifier,
                    sessionRevision: sessionRevision, insertionRange: insertionRange,
                    rawFinal: rawFinal, insertedFinal: insertedFinal,
                    expiry: now.advanced(by: lifetime), documentLength: length)
    }

    mutating func attributeLocalEdit(selection: NSRange) -> Bool {
        guard Self.valid(selection), selection.location >= insertionRange.location else { return false }
        if selection.length == 0, allowsTrailingExtension,
           selection.location >= NSMaxRange(insertionRange),
           selection.location - NSMaxRange(insertionRange) <= Self.latinTokenLimit - attributedTokenLength {
            return true
        }
        guard NSMaxRange(selection) <= NSMaxRange(insertionRange) else { return false }
        let local = NSRange(location: selection.location - insertionRange.location, length: selection.length)
        let token = voiceLatinTokenRanges(insertedFinal).enumerated().first { _, range in
            if local.length > 0 { return local == range }
            return local.location > range.location && local.location <= NSMaxRange(range)
        }
        attributedTokenIndex = token?.offset
        attributedTokenLength = token?.element.length ?? 0
        allowsDocumentGrowth = token.map { local == $0.element ||
            (local.length == 0 && local.location == NSMaxRange($0.element)) } ?? false
        allowsTrailingExtension = token.map { local.length == 0 &&
            local.location == insertedFinal.utf16.count && NSMaxRange($0.element) == insertedFinal.utf16.count } ?? false
        return attributedTokenIndex != nil
    }

    func matchesTarget(client: IMKTextInput, sessionRevision: UInt64) -> Bool {
        self.sessionRevision == sessionRevision &&
            clientIdentity == ObjectIdentifier(client as AnyObject) &&
            client.uniqueClientIdentifierString() == clientIdentifier
    }

    func observe(client: IMKTextInput, sessionRevision: UInt64, secure: Bool,
                 now: ContinuousClock.Instant = .now,
                 validateTarget: () -> Bool = { true }) -> Decision {
        guard let attributedTokenIndex, !secure, now < expiry,
              matchesTarget(client: client, sessionRevision: sessionRevision),
              validateTarget() else { return .discard }
        let mark = client.markedRange()
        guard validateTarget(), !Self.valid(mark) || mark.length == 0 else { return .discard }
        let selection = client.selectedRange()
        guard validateTarget(), Self.valid(selection), selection.length == 0 else { return .discard }
        let currentLength = client.length()
        guard validateTarget(), currentLength != NSNotFound else { return .discard }
        let delta = currentLength - documentLength
        guard delta >= -insertionRange.length,
              delta <= Self.textLimit - insertionRange.length,
              delta <= 0 || (allowsDocumentGrowth && delta <= Self.latinTokenLimit - attributedTokenLength) else {
            return .discard
        }
        let currentRange = NSRange(location: insertionRange.location, length: insertionRange.length + delta)
        guard Self.valid(currentRange), NSMaxRange(currentRange) <= currentLength,
              selection.location >= currentRange.location, selection.location <= NSMaxRange(currentRange) else {
            return .discard
        }
        var actual = currentRange
        guard let current = client.string(from: currentRange, actualRange: &actual),
              validateTarget(),
              actual == currentRange, current.utf16.count == currentRange.length,
              matchesTarget(client: client, sessionRevision: sessionRevision),
              validateTarget() else { return .discard }
        guard current != insertedFinal else { return .pending }
        // An automatic polish result is not learning evidence. This first slice
        // only attributes a user edit when raw ASR was inserted unchanged.
        guard rawFinal == insertedFinal,
              let substitution = Self.singleLatinSubstitution(from: insertedFinal, to: current),
              substitution.index == attributedTokenIndex else {
            return .discard
        }
        let changedRange = NSRange(location: currentRange.location + substitution.range.location,
                                   length: substitution.range.length)
        guard selection.location >= changedRange.location,
              selection.location <= NSMaxRange(changedRange) else { return .discard }
        return .learn(substitution.correction)
    }

    private static func valid(_ range: NSRange) -> Bool {
        range.location >= 0 && range.location != NSNotFound && range.length >= 0 &&
            range.length != NSNotFound && range.length <= Int.max - range.location
    }

    private static func singleLatinSubstitution(from original: String, to corrected: String)
        -> (index: Int, range: NSRange, correction: VoiceLearnedCorrection)? {
        let oldValue = original as NSString, newValue = corrected as NSString
        let oldTokens = voiceLatinTokenRanges(original), newTokens = voiceLatinTokenRanges(corrected)
        guard oldTokens.count == newTokens.count else { return nil }
        var changed: Int?
        for index in oldTokens.indices {
            if oldValue.substring(with: oldTokens[index]) != newValue.substring(with: newTokens[index]) {
                guard changed == nil else { return nil }
                changed = index
            }
        }
        guard let index = changed else { return nil }
        let oldRange = oldTokens[index], newRange = newTokens[index]
        guard oldValue.substring(to: oldRange.location) == newValue.substring(to: newRange.location),
              oldValue.substring(from: NSMaxRange(oldRange)) == newValue.substring(from: NSMaxRange(newRange)) else {
            return nil
        }
        let source = oldValue.substring(with: oldRange)
        let replacement = newValue.substring(with: newRange)
        guard (2...64).contains(source.utf16.count), (2...64).contains(replacement.utf16.count) else { return nil }
        return (index, newRange,
                VoiceLearnedCorrection(sourceCode: source.lowercased(), canonicalText: replacement))
    }
}
