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

package struct VoiceLearnedCorrection: Equatable, Sendable {
    package let sourceCode: String
    package let canonicalText: String
    package init(sourceCode: String,
        canonicalText: String) {
        self.sourceCode = sourceCode
        self.canonicalText = canonicalText
    }

}

package struct VoiceAliasSnapshot: Equatable, Sendable {
    package enum Availability: Sendable { case available, unknown }
    package struct Entry: Equatable, Sendable {
        let code: String
        package let text: String
        let commits: Int
    }

    package static let entryLimit = 512
    package static let byteLimit = 64 * 1024
    package let generation: UInt64
    package let revision: UInt64
    package let availability: Availability
    package let entries: [Entry]

    package static func unknown(generation: UInt64 = 0, revision: UInt64 = 0) -> Self {
        Self(generation: generation, revision: revision, availability: .unknown, entries: [])
    }

    package init(generation: UInt64, revision: UInt64, availability: Availability, entries: [Entry]) {
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

    package init(status: String, rows: String, generation: UInt64, revision: UInt64) {
        guard status == "ok", rows.utf8.count <= Self.byteLimit else {
            self = .unknown(generation: generation, revision: revision); return
        }
        var parsed: [Entry] = []
        for row in rows.split(separator: "\n") {
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

package enum VoiceAliasRewriter {
    package struct Result: Equatable, Sendable {
        package let text: String
        package let matchedDisplays: [String]
        package var hitCount: Int { matchedDisplays.count }

        package func retainedHitCount(in insertedFinal: String) -> Int {
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

    package static func apply(_ transcript: String, snapshot: VoiceAliasSnapshot) -> String {
        result(transcript, snapshot: snapshot).text
    }

    package static func result(_ transcript: String, snapshot: VoiceAliasSnapshot) -> Result {
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
package struct VoiceCorrectionObservation {
    package struct TargetEvidence {
        package let identity: ObjectIdentifier
        package let identifier: String?
        package let sessionRevision: UInt64
        package let secure: Bool

        package init(identity: ObjectIdentifier, identifier: String?, sessionRevision: UInt64, secure: Bool) {
            self.identity = identity; self.identifier = identifier
            self.sessionRevision = sessionRevision; self.secure = secure
        }
    }

    /// Facts collected by the adapter. Qualification is checked again on submission.
    package struct ReadEvidence {
        package let target: TargetEvidence
        package let mark: NSRange
        package let selection: NSRange
        package let currentLength: Int
        package let requestedRange: NSRange
        package let actualRange: NSRange
        package let current: String

        package init(target: TargetEvidence, mark: NSRange, selection: NSRange, currentLength: Int,
                     requestedRange: NSRange, actualRange: NSRange, current: String) {
            self.target = target; self.mark = mark; self.selection = selection
            self.currentLength = currentLength; self.requestedRange = requestedRange
            self.actualRange = actualRange; self.current = current
        }
    }

    package enum Decision: Equatable {
        case pending
        case learn(VoiceLearnedCorrection)
        case discard
    }

    package static let textLimit = 4_096
    package static let latinTokenLimit = 64
    package static let lifetime: Duration = .seconds(8)

    package let operationID: UUID
    private let clientIdentity: ObjectIdentifier
    private let clientIdentifier: String
    package let sessionRevision: UInt64
    package let insertionRange: NSRange
    package let rawFinal: String
    package let insertedFinal: String
    package let expiry: ContinuousClock.Instant
    private let documentLength: Int
    package var hasAttributedEdit: Bool { attributedTokenIndex != nil }
    private var attributedTokenIndex: Int?
    private var attributedTokenLength = 0
    private var allowsDocumentGrowth = false
    private var allowsTrailingExtension = false

    package static func capture(operationID: UUID, identity: ObjectIdentifier, identifier: String,
                        sessionRevision: UInt64, insertionRange: NSRange, rawFinal: String, insertedFinal: String,
                        selection: NSRange, documentLength: Int, readback: String, actualRange: NSRange,
                        now: ContinuousClock.Instant = .now) -> Self? {
        guard valid(insertionRange), insertionRange.length == insertedFinal.utf16.count,
              !insertedFinal.isEmpty, insertedFinal.utf16.count <= textLimit,
              rawFinal.utf16.count <= textLimit, !identifier.isEmpty,
              valid(selection), selection.length == 0, selection.location == NSMaxRange(insertionRange),
              documentLength != NSNotFound, documentLength >= NSMaxRange(insertionRange),
              actualRange == insertionRange, readback == insertedFinal else { return nil }
        return Self(operationID: operationID, clientIdentity: identity, clientIdentifier: identifier,
                    sessionRevision: sessionRevision, insertionRange: insertionRange,
                    rawFinal: rawFinal, insertedFinal: insertedFinal,
                    expiry: now.advanced(by: lifetime), documentLength: documentLength)
    }

    package mutating func attributeLocalEdit(selection: NSRange) -> Bool {
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

    package func matchesTarget(identity: ObjectIdentifier, identifier: String?, sessionRevision: UInt64) -> Bool {
        self.sessionRevision == sessionRevision && clientIdentity == identity && clientIdentifier == identifier
    }

    package func matchesTarget(_ evidence: TargetEvidence) -> Bool {
        !evidence.secure && matchesTarget(identity: evidence.identity, identifier: evidence.identifier,
                                          sessionRevision: evidence.sessionRevision)
    }

    /// Validate immutable document evidence before the adapter attempts an exact bounded read.
    package func readingRange(mark: NSRange, selection: NSRange, currentLength: Int, secure: Bool,
                      now: ContinuousClock.Instant = .now) -> NSRange? {
        guard attributedTokenIndex != nil, !secure, now < expiry,
              !Self.valid(mark) || mark.length == 0,
              Self.valid(selection), selection.length == 0,
              currentLength >= 0, currentLength != NSNotFound else { return nil }
        let delta = currentLength - documentLength
        guard delta >= -insertionRange.length,
              delta <= Self.textLimit - insertionRange.length,
              delta <= 0 || (allowsDocumentGrowth && delta <= Self.latinTokenLimit - attributedTokenLength) else { return nil }
        let range = NSRange(location: insertionRange.location, length: insertionRange.length + delta)
        guard Self.valid(range), NSMaxRange(range) <= currentLength,
              selection.location >= range.location, selection.location <= NSMaxRange(range) else { return nil }
        return range
    }

    package func observe(_ evidence: ReadEvidence, now: ContinuousClock.Instant = .now) -> Decision {
        guard matchesTarget(evidence.target),
              let range = readingRange(mark: evidence.mark, selection: evidence.selection,
                  currentLength: evidence.currentLength, secure: evidence.target.secure, now: now),
              range == evidence.requestedRange else { return .discard }
        return observe(current: evidence.current, actualRange: evidence.actualRange,
                       requestedRange: range, selection: evidence.selection)
    }

    private func observe(current: String, actualRange: NSRange, requestedRange: NSRange,
                         selection: NSRange) -> Decision {
        guard let attributedTokenIndex, actualRange == requestedRange,
              current.utf16.count == requestedRange.length else { return .discard }
        guard current != insertedFinal else { return .pending }
        // Automatic polish is not evidence of a user correction.
        guard rawFinal == insertedFinal,
              let substitution = Self.singleLatinSubstitution(from: insertedFinal, to: current),
              substitution.index == attributedTokenIndex else { return .discard }
        let changedRange = NSRange(location: requestedRange.location + substitution.range.location,
                                   length: substitution.range.length)
        guard selection.location >= changedRange.location,
              selection.location <= NSMaxRange(changedRange) else { return .discard }
        return .learn(substitution.correction)
    }

    package static func valid(_ range: NSRange) -> Bool {
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
