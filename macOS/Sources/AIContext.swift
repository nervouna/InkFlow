@preconcurrency import InputMethodKit
import Carbon

/// Request identity deliberately excludes candidate paging, highlighting and display preedit.
struct AIInputIdentity: Equatable, Sendable {
    let rawInput: String
    let caret: Int
    let selectedPrefix: String
}

struct AIClientAnchor: Equatable {
    let client: ObjectIdentifier
    let mark: NSRange
    let selection: NSRange

    @MainActor static func read(_ client: IMKTextInput?, ownsMarkedText: Bool,
                                secureInput: Bool = IsSecureEventInputEnabled(),
                                rejected: (AIDiagnosticReason) -> Void = {
                                    AIDiagnostics.emit(.anchorRejected, reason: $0)
                                }) -> Self? {
        guard !secureInput else { rejected(.secureInput); return nil }
        guard ownsMarkedText else { rejected(.unownedMark); return nil }
        guard let client else { rejected(.missingClient); return nil }
        let mark = client.markedRange(), selection = client.selectedRange()
        guard valid(mark), NSMaxRange(mark) != NSNotFound else { rejected(.invalidMark); return nil }
        guard mark.length > 0 else { rejected(.emptyMark); return nil }
        guard valid(selection) else { rejected(.invalidSelection); return nil }
        guard selection.location >= mark.location, NSMaxRange(selection) <= NSMaxRange(mark) else {
            rejected(.selectionOutsideMark); return nil
        }
        return Self(client: ObjectIdentifier(client as AnyObject), mark: mark, selection: selection)
    }

    static func valid(_ range: NSRange) -> Bool {
        range.location >= 0 && range.location != NSNotFound && range.length >= 0 &&
            range.length != NSNotFound && range.length <= Int.max - range.location
    }
}

struct AISurroundingContext: Equatable {
    let precedingText: String
    let followingText: String
    // Missing text is a valid empty prompt, but must not equal formerly readable text.
    let precedingAvailable: Bool
    let followingAvailable: Bool

    static let limit = 256

    @MainActor static func read(_ client: IMKTextInput, anchor: AIClientAnchor) -> Self? {
        guard AIClientAnchor.read(client, ownsMarkedText: true) == anchor else {
            AIDiagnostics.emit(.contextRejected, reason: .anchorChanged); return nil
        }
        let start = anchor.mark.location, end = NSMaxRange(anchor.mark)
        // IMK documents length() as potentially expensive. Call only at request/response/acceptance,
        // and clip the suffix ourselves because some clients reject oversized substring requests.
        let length = client.length()
        guard length == NSNotFound || (length >= 0 && length >= end) else {
            AIDiagnostics.emit(.contextRejected, reason: .documentShorterThanMark); return nil
        }
        let knownLength = length != NSNotFound
        let prefixRange = NSRange(location: max(0, start - limit), length: min(start, limit))
        let suffixRange = NSRange(location: end, length: knownLength ? min(limit, length - end) : min(limit, Int.max - end))
        let before = readSide(client, requested: prefixRange, anchor: start, preceding: true)
        let after = readSide(client, requested: suffixRange, anchor: end, preceding: false)
        guard AIClientAnchor.read(client, ownsMarkedText: true) == anchor else {
            AIDiagnostics.emit(.contextRejected, reason: .anchorChanged); return nil
        }
        AIDiagnostics.write(AIDiagnosticRecord(event: .contextCaptured, reason: .none,
            attempt: AIDiagnostics.attempt, session: AIDiagnostics.session,
            precedingAvailable: before != nil, followingAvailable: after != nil))
        return Self(precedingText: before ?? "", followingText: after ?? "",
                    precedingAvailable: before != nil, followingAvailable: after != nil)
    }

    @MainActor private static func readSide(_ client: IMKTextInput, requested: NSRange,
                                            anchor: Int, preceding: Bool) -> String? {
        guard requested.length > 0 else { return "" }
        var actual = requested
        guard let text = client.string(from: requested, actualRange: &actual), AIClientAnchor.valid(actual),
              actual.length == text.utf16.count,
              actual.location >= max(0, requested.location - 1),
              NSMaxRange(actual) <= NSMaxRange(requested) + (NSMaxRange(requested) < Int.max ? 1 : 0) else { return nil }
        let units = Array(text.utf16)
        let offset = anchor - actual.location
        guard offset >= 0, offset <= units.count,
              offset == units.count || !(0xDC00...0xDFFF).contains(units[offset]) else { return nil }
        let slice = preceding ? units[..<offset] : units[offset...]
        guard slice.first.map({ !(0xDC00...0xDFFF).contains($0) }) ?? true,
              slice.last.map({ !(0xD800...0xDBFF).contains($0) }) ?? true else { return nil }
        return String(decoding: slice, as: UTF16.self)
    }
}
