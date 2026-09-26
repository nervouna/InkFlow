import Foundation
import InkFlowDomain

@main
struct VoiceLearningCoordinatorTests {
    @MainActor static func main() {
        lifecycle()
        evidenceBoundaries()
        staleWork()
        print("PASS shared voice learning: immutable evidence, deadlines, undo, stale tickets and one-shot actions")
    }

    @MainActor final class Fixture {
        let owner = NSObject()
        let now = ContinuousClock.now
        let coordinator = VoiceLearningCoordinator()
        let correction = VoiceLearnedCorrection(sourceCode: "codux", canonicalText: "Codex")
        var target: VoiceCorrectionObservation.TargetEvidence {
            .init(identity: ObjectIdentifier(owner), identifier: "client", sessionRevision: 7, secure: false)
        }
        func begin(rawFinal: String = "codux") -> VoiceLearningCoordinator.Ticket {
            let observation = VoiceCorrectionObservation.capture(operationID: UUID(), identity: target.identity,
                identifier: "client", sessionRevision: 7, insertionRange: NSRange(location: 2, length: 5),
                rawFinal: rawFinal, insertedFinal: "codux", selection: NSRange(location: 7, length: 0),
                documentLength: 9, readback: "codux", actualRange: NSRange(location: 2, length: 5), now: now)!
            return coordinator.begin(observation)
        }
        func edit(at time: ContinuousClock.Instant? = nil) -> VoiceLearningCoordinator.Ticket {
            let time = time ?? now
            guard case .selection(let ticket) = coordinator.receiveKey(.edit, now: time),
                  case .read(let read) = coordinator.attribute(selection: NSRange(location: 2, length: 5),
                    target: target, ticket: ticket, now: time) else { fatalError("Expected an attributable edit") }
            return read
        }
        func evidence(target: VoiceCorrectionObservation.TargetEvidence? = nil, mark: NSRange? = nil,
                      selection: NSRange? = nil, length: Int = 9, requested: NSRange? = nil,
                      actual: NSRange? = nil, text: String = "Codex") -> VoiceCorrectionObservation.ReadEvidence {
            .init(target: target ?? self.target, mark: mark ?? NSRange(location: NSNotFound, length: 0),
                selection: selection ?? NSRange(location: 7, length: 0), currentLength: length,
                requestedRange: requested ?? NSRange(location: 2, length: 5),
                actualRange: actual ?? NSRange(location: 2, length: 5), current: text)
        }
        func detect() -> VoiceLearningCoordinator.Ticket {
            let ticket = edit()
            guard case .detected(let grace, _) = coordinator.completeRead(ticket, evidence: evidence(), now: ticket.deadline)
            else { fatalError("Expected a detected correction") }
            return grace
        }
    }

    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    @MainActor static func lifecycle() {
        let f = Fixture(); _ = f.begin()
        let grace = f.detect()
        check(f.coordinator.hasPendingCorrection, "Detection waits for undo grace")
        check(f.coordinator.observation(for: grace, now: grace.deadline.advanced(by: .nanoseconds(-1))) == nil,
              "An early grace wake cannot request evidence")
        guard case .ready(let action) = f.coordinator.completeRead(grace, evidence: f.evidence(), now: grace.deadline)
        else { fatalError("Fresh matching final evidence must authorize learning") }
        check(!f.coordinator.hasObservation && !f.coordinator.hasPendingCorrection,
              "Observation is gone before the writer can reenter")
        check(f.coordinator.takeLearningAction(action) == f.correction, "Consume the authorized correction")
        check(f.coordinator.takeLearningAction(action) == nil, "A storage action cannot replay or retry")

        let undo = Fixture(); _ = undo.begin(); let pending = undo.detect()
        guard case .ended(.immediateUndo) = undo.coordinator.receiveKey(.undo, now: pending.deadline.advanced(by: .milliseconds(-1)))
        else { fatalError("Undo must reject the pending correction") }
        check(undo.coordinator.observation(for: pending, now: pending.deadline) == nil, "Undo revokes late reads")

        let timeout = Fixture(); let expiry = timeout.begin(); _ = timeout.detect()
        guard case .ended(.timeout) = timeout.coordinator.expire(expiry, now: expiry.deadline)
        else { fatalError("Capture deadline cancels grace") }

        let other = Fixture(); _ = other.begin(); _ = other.detect()
        guard case .ended(.unrelatedEdit) = other.coordinator.receiveKey(.otherKey, now: other.now)
        else { fatalError("Every key-down after detection invalidates evidence") }

        let unchanged = Fixture(); _ = unchanged.begin(); let read = unchanged.edit()
        guard case .ignored = unchanged.coordinator.completeRead(read, evidence: unchanged.evidence(text: "codux"), now: read.deadline)
        else { fatalError("Unchanged text remains pending observation") }
        check(unchanged.coordinator.hasObservation && !unchanged.coordinator.hasPendingCorrection,
              "No correction is inferred from an unchanged read")
    }

    @MainActor static func evidenceBoundaries() {
        let invalid: [(Fixture) -> VoiceCorrectionObservation.ReadEvidence] = [
            { f in f.evidence(target: .init(identity: f.target.identity, identifier: nil, sessionRevision: 7, secure: false)) },
            { f in f.evidence(target: .init(identity: f.target.identity, identifier: "other", sessionRevision: 7, secure: false)) },
            { f in f.evidence(target: .init(identity: ObjectIdentifier(NSObject()), identifier: "client", sessionRevision: 7, secure: false)) },
            { f in f.evidence(target: .init(identity: f.target.identity, identifier: "client", sessionRevision: 8, secure: false)) },
            { f in f.evidence(target: .init(identity: f.target.identity, identifier: "client", sessionRevision: 7, secure: true)) },
            { $0.evidence(mark: NSRange(location: 2, length: 1)) },
            { $0.evidence(selection: NSRange(location: 7, length: 1)) },
            { $0.evidence(selection: NSRange(location: 1, length: 0)) },
            { $0.evidence(length: Int.min) },
            { $0.evidence(length: NSNotFound) },
            { $0.evidence(requested: NSRange(location: 1, length: 5), actual: NSRange(location: 1, length: 5)) },
            { $0.evidence(actual: NSRange(location: 2, length: 4)) },
            { $0.evidence(text: "Codex extra") }
        ]
        for (index, make) in invalid.enumerated() {
            let f = Fixture(); _ = f.begin(); let grace = f.detect()
            guard case .ended(.unavailable) = f.coordinator.completeRead(grace, evidence: make(f), now: grace.deadline)
            else { fatalError("Invalid final evidence \(index) must fail closed") }
            check(!f.coordinator.hasObservation, "Rejected final evidence ends observation")
        }
        let expired = Fixture(); let expiry = expired.begin(); let grace = expired.detect()
        guard case .ended(.timeout) = expired.coordinator.completeRead(grace, evidence: expired.evidence(), now: expiry.deadline)
        else { fatalError("Submission rechecks time even if the read started before expiry") }
        let changed = Fixture(); _ = changed.begin(); let grace2 = changed.detect()
        guard case .ended(.unavailable) = changed.coordinator.completeRead(grace2, evidence: changed.evidence(text: "CODEX"), now: grace2.deadline)
        else { fatalError("Final evidence must equal the pending correction") }

        let unavailable = Fixture(); _ = unavailable.begin(); let grace3 = unavailable.detect()
        guard case .ended(.unavailable) = unavailable.coordinator.completeRead(grace3, evidence: nil, now: grace3.deadline)
        else { fatalError("Unavailable evidence cannot be replaced by an empty successful read") }
        let polished = Fixture(); _ = polished.begin(rawFinal: "original ASR"); let read = polished.edit()
        guard case .ended(nil) = polished.coordinator.completeRead(read, evidence: polished.evidence(), now: read.deadline)
        else { fatalError("Automatic polish cannot supply user-correction evidence") }
        let invalidEdit = Fixture(); _ = invalidEdit.begin()
        guard case .selection(let selection) = invalidEdit.coordinator.receiveKey(.edit, now: invalidEdit.now),
              case .ended(nil) = invalidEdit.coordinator.attribute(selection: NSRange(location: 2, length: 5),
                target: .init(identity: invalidEdit.target.identity, identifier: nil, sessionRevision: 7, secure: false),
                ticket: selection, now: invalidEdit.now) else { fatalError("Unknown edit identity cannot request a document read") }
    }

    @MainActor static func staleWork() {
        let f = Fixture(); let oldExpiry = f.begin(); let old = f.edit(); let replacement = f.edit()
        guard case .ignored = f.coordinator.completeRead(old, evidence: f.evidence(), now: old.deadline)
        else { fatalError("Superseded reads cannot detect a correction") }
        check(f.coordinator.observation(for: replacement, now: replacement.deadline) != nil, "Latest read remains valid")
        _ = f.begin(); let supersededGrace = f.detect()
        _ = f.begin(); let grace = f.detect()
        guard case .ignored = f.coordinator.completeRead(supersededGrace, evidence: f.evidence(), now: supersededGrace.deadline)
        else { fatalError("Equal correction text cannot authorize a stale operation") }
        guard case .ignored = f.coordinator.expire(oldExpiry, now: oldExpiry.deadline)
        else { fatalError("An old expiry cannot cancel a replacement observation") }
        guard case .ready(let action) = f.coordinator.completeRead(grace, evidence: f.evidence(), now: grace.deadline)
        else { fatalError("Replacement operation remains learnable") }
        _ = f.coordinator.cancel(reason: .cancelled)
        check(f.coordinator.takeLearningAction(action) == nil, "Reentrant cancellation revokes an untaken action")
        _ = f.begin(); _ = f.detect()
        check(f.coordinator.takeLearningAction(action) == nil, "Equal corrections in another operation do not revive an action")
    }
}
