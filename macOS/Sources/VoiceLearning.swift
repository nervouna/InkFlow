@preconcurrency import InputMethodKit
import InkFlowDomain

@MainActor
extension VoiceCorrectionObservation {
    static func capture(operationID: UUID, client: IMKTextInput, sessionRevision: UInt64,
                        insertionRange: NSRange, rawFinal: String, insertedFinal: String,
                        now: ContinuousClock.Instant = .now,
                        validateTarget: () -> Bool = { true }) -> Self? {
        guard valid(insertionRange), insertionRange.length == insertedFinal.utf16.count,
              !insertedFinal.isEmpty, insertedFinal.utf16.count <= textLimit,
              rawFinal.utf16.count <= textLimit, validateTarget() else { return nil }
        guard let identifier = client.uniqueClientIdentifierString(), !identifier.isEmpty else { return nil }
        let selection = client.selectedRange()
        guard valid(selection), selection.length == 0,
              selection.location == NSMaxRange(insertionRange) else { return nil }
        guard validateTarget() else { return nil }
        let length = client.length()
        guard length != NSNotFound, length >= NSMaxRange(insertionRange) else { return nil }
        var actual = insertionRange
        guard validateTarget() else { return nil }
        guard let readback = client.string(from: insertionRange, actualRange: &actual),
              actual == insertionRange, readback == insertedFinal,
              client.uniqueClientIdentifierString() == identifier,
              validateTarget() else { return nil }
        return capture(operationID: operationID, identity: ObjectIdentifier(client as AnyObject),
                       identifier: identifier, sessionRevision: sessionRevision, insertionRange: insertionRange,
                       rawFinal: rawFinal, insertedFinal: insertedFinal, selection: selection,
                       documentLength: length, readback: readback, actualRange: actual, now: now)
    }

    func matchesTarget(client: IMKTextInput, sessionRevision: UInt64) -> Bool {
        matchesTarget(identity: ObjectIdentifier(client as AnyObject),
                      identifier: client.uniqueClientIdentifierString(), sessionRevision: sessionRevision)
    }

    func readEvidence(client: IMKTextInput, sessionRevision: UInt64, secure: Bool,
                      now: ContinuousClock.Instant = .now,
                      validateTarget: () -> Bool = { true }) -> ReadEvidence? {
        guard !secure, now < expiry, hasAttributedEdit, validateTarget(),
              matchesTarget(client: client, sessionRevision: sessionRevision) else { return nil }
        let mark = client.markedRange()
        guard !Self.valid(mark) || mark.length == 0 else { return nil }
        let selection = client.selectedRange()
        guard Self.valid(selection), selection.length == 0 else { return nil }
        guard validateTarget() else { return nil }
        let length = client.length()
        guard let range = readingRange(mark: mark, selection: selection,
                    currentLength: length, secure: secure, now: now) else { return nil }
        var actual = range
        guard validateTarget() else { return nil }
        guard let current = client.string(from: range, actualRange: &actual),
              actual == range, current.utf16.count == range.length else { return nil }
        let identifier = client.uniqueClientIdentifierString()
        guard matchesTarget(identity: ObjectIdentifier(client as AnyObject),
                  identifier: identifier, sessionRevision: sessionRevision), validateTarget() else { return nil }
        return ReadEvidence(target: .init(identity: ObjectIdentifier(client as AnyObject), identifier: identifier,
                sessionRevision: sessionRevision, secure: secure), mark: mark, selection: selection,
            currentLength: length, requestedRange: range, actualRange: actual, current: current)
    }

    func editEvidence(client: IMKTextInput, sessionRevision: UInt64, secure: Bool,
                      validateTarget: () -> Bool) -> (selection: NSRange, target: TargetEvidence)? {
        guard !secure, validateTarget() else { return nil }
        let selection = client.selectedRange()
        let identifier = client.uniqueClientIdentifierString()
        guard matchesTarget(identity: ObjectIdentifier(client as AnyObject),
            identifier: identifier, sessionRevision: sessionRevision), validateTarget() else { return nil }
        return (selection, .init(identity: ObjectIdentifier(client as AnyObject), identifier: identifier,
                                sessionRevision: sessionRevision, secure: secure))
    }

    /// Native regression convenience; production coordination consumes the raw evidence.
    func observe(client: IMKTextInput, sessionRevision: UInt64, secure: Bool,
                 now: ContinuousClock.Instant = .now,
                 validateTarget: () -> Bool = { true }) -> Decision {
        guard let evidence = readEvidence(client: client, sessionRevision: sessionRevision,
            secure: secure, now: now, validateTarget: validateTarget) else { return .discard }
        return observe(evidence, now: now)
    }
}
