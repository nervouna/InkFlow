import Foundation

/// Owns correction policy and deadlines. Adapters execute only ticketed reads and effects.
@MainActor
package final class VoiceLearningCoordinator {
    package enum Key { case undo, edit, otherKey }
    package enum Reason {
        case immediateUndo, unrelatedEdit, timeout, unavailable, clientDrift
        case cancelled, deactivated, secure, invalidRange
    }
    package struct Ticket: Equatable {
        fileprivate enum Kind { case selection, read, persistence, expiry }
        fileprivate let generation: UInt64
        fileprivate let serial: UInt64
        fileprivate let kind: Kind
        package let operationID: UUID
        package let deadline: ContinuousClock.Instant
    }
    package struct LearningAction: Equatable {
        fileprivate let generation: UInt64
        fileprivate let correction: VoiceLearnedCorrection
    }
    package enum Transition {
        case ignored
        case selection(Ticket)
        case read(Ticket)
        case detected(Ticket, milliseconds: Int)
        case ended(Reason?)
        case ready(LearningAction)
    }

    package var observationDelay: Duration = .milliseconds(350)
    package var undoGrace: Duration = .seconds(1)
    package private(set) var observation: VoiceCorrectionObservation?
    package var hasObservation: Bool { observation != nil }
    package var hasPendingCorrection: Bool { pending != nil }
    private var pending: VoiceLearnedCorrection?
    private var generation: UInt64 = 0
    private var serial: UInt64 = 0
    private var work: Ticket?
    private var ready: LearningAction?

    package init() {}

    package func begin(_ observation: VoiceCorrectionObservation) -> Ticket {
        reset()
        self.observation = observation
        return ticket(.expiry, deadline: observation.expiry)
    }

    package func receiveKey(_ key: Key, now: ContinuousClock.Instant = .now) -> Transition {
        guard let observation else { return .ignored }
        if key == .undo { return cancel(reason: .immediateUndo) }
        if pending != nil { return cancel(reason: .unrelatedEdit) }
        guard now < observation.expiry else { return cancel(reason: .timeout) }
        guard key == .edit else { return .ignored }
        let next = ticket(.selection, deadline: now)
        work = next
        return .selection(next)
    }

    package func attribute(selection: NSRange, target: VoiceCorrectionObservation.TargetEvidence,
                           ticket: Ticket, now: ContinuousClock.Instant = .now) -> Transition {
        guard isCurrent(ticket), ticket.kind == .selection, var observation else { return .ignored }
        guard now < observation.expiry else { return cancel(reason: .timeout) }
        guard observation.matchesTarget(target), observation.attributeLocalEdit(selection: selection) else {
            return cancel(reason: .unrelatedEdit)
        }
        self.observation = observation
        let next = self.ticket(.read, deadline: now.advanced(by: max(.zero, observationDelay)))
        work = next
        return .read(next)
    }

    /// A stale or early callback must not even touch the native client.
    package func observation(for ticket: Ticket, now: ContinuousClock.Instant = .now) -> VoiceCorrectionObservation? {
        guard isCurrent(ticket), let observation, now >= ticket.deadline, now < observation.expiry else { return nil }
        return observation
    }

    package func isCurrent(_ ticket: Ticket) -> Bool {
        guard let observation, ticket.generation == generation,
              ticket.operationID == observation.operationID else { return false }
        return ticket.kind == .expiry || work == ticket
    }

    package func completeRead(_ ticket: Ticket, evidence: VoiceCorrectionObservation.ReadEvidence?,
                              now: ContinuousClock.Instant = .now) -> Transition {
        guard isCurrent(ticket), ticket.kind == .read || ticket.kind == .persistence,
              let observation, now >= ticket.deadline else { return .ignored }
        guard now < observation.expiry else { return cancel(reason: .timeout) }
        let decision = evidence.map { observation.observe($0, now: now) } ?? .discard
        if ticket.kind == .persistence {
            guard let pending, decision == .learn(pending) else { return cancel(reason: .unavailable) }
            // Revoke all old reads before the storage callback or any adapter callback.
            let action = LearningAction(generation: generation, correction: pending)
            reset()
            ready = action
            return .ready(action)
        }
        switch decision {
        case .pending:
            work = nil
            return .ignored
        case .discard:
            return cancel()
        case .learn(let correction):
            pending = correction
            let next = self.ticket(.persistence, deadline: now.advanced(by: max(.zero, undoGrace)))
            work = next
            let duration = observationDelay.components
            let milliseconds = Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
            return .detected(next, milliseconds: milliseconds)
        }
    }

    package func expire(_ ticket: Ticket, now: ContinuousClock.Instant = .now) -> Transition {
        guard isCurrent(ticket), ticket.kind == .expiry, now >= ticket.deadline else { return .ignored }
        return cancel(reason: .timeout)
    }

    package func cancel(reason: Reason? = nil) -> Transition {
        let rejection = pending == nil ? nil : reason
        reset()
        return .ended(rejection)
    }

    /// Consume before invoking storage. Neither repeated effects nor a failed write may retry.
    package func takeLearningAction(_ action: LearningAction) -> VoiceLearnedCorrection? {
        guard ready == action else { return nil }
        ready = nil
        return action.correction
    }

    private func ticket(_ kind: Ticket.Kind, deadline: ContinuousClock.Instant) -> Ticket {
        serial &+= 1
        return Ticket(generation: generation, serial: serial, kind: kind,
                      operationID: observation!.operationID, deadline: deadline)
    }

    private func reset() {
        generation &+= 1
        observation = nil; pending = nil; work = nil; ready = nil
    }
}
