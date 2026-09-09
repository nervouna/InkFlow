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

struct AISurroundingContext {
    let precedingText: String
    let followingText: String
    // Availability is diagnostic metadata; missing text is a valid empty prompt.
    let precedingAvailable: Bool
    let followingAvailable: Bool

    static let limit = 256

    @MainActor static func read(_ client: IMKTextInput, anchor: AIClientAnchor,
                                secureInput: () -> Bool = { IsSecureEventInputEnabled() }) -> Self? {
        guard AIClientAnchor.read(client, ownsMarkedText: true, secureInput: secureInput()) == anchor else {
            AIDiagnostics.emit(.contextRejected, reason: .anchorChanged); return nil
        }
        let start = anchor.mark.location, end = NSMaxRange(anchor.mark)
        // Capture once per request. Length may be inconsistent with a valid owned
        // mark, so use it only when it can clip the suffix.
        let length = client.length()
        let knownLength = length != NSNotFound && length >= end
        let prefixRange = NSRange(location: max(0, start - limit), length: min(start, limit))
        let suffixRange = NSRange(location: end, length: knownLength ? min(limit, length - end) : min(limit, Int.max - end))
        let before = readSide(client, requested: prefixRange, preceding: true)
        let after = readSide(client, requested: suffixRange, preceding: false)
        guard AIClientAnchor.read(client, ownsMarkedText: true, secureInput: secureInput()) == anchor else {
            AIDiagnostics.emit(.contextRejected, reason: .anchorChanged); return nil
        }
        AIDiagnostics.write(AIDiagnosticRecord(event: .contextCaptured,
            reason: length != NSNotFound && length < end ? .documentShorterThanMark : .none,
            attempt: AIDiagnostics.attempt, session: AIDiagnostics.session,
            precedingAvailable: before != nil, followingAvailable: after != nil,
            reportedDocumentLength: length, markedEnd: end))
        return Self(precedingText: before ?? "", followingText: after ?? "",
                    precedingAvailable: before != nil, followingAvailable: after != nil)
    }

    @MainActor private static func readSide(_ client: IMKTextInput, requested: NSRange,
                                            preceding: Bool) -> String? {
        guard requested.length > 0 else { return "" }
        var actual = requested
        guard let text = client.string(from: requested, actualRange: &actual) else { return nil }
        return String(preceding ? text.suffix(limit) : text.prefix(limit))
    }
}
