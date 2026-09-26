import InkFlowRime
import Foundation
import os

/// Fixed labels and boolean delivery facts only. Never add key metadata, input text,
/// candidates, document values, identifiers from a client, paths or error descriptions.
enum InputDiagnosticEvent: String, DiagnosticLabel {
    case controllerCreated, controllerReleased
    case activationReady, activationSkipped
    case firstKeyEntered, firstKeyCheckpoint, firstKeyCompleted
    case deactivationEntered, deactivationBeforeSuper, deactivationAfterSuper, deactivationFinished
    case compositionBegan, compositionEnded, insertionIssued, insertionReturned, engineUnavailable
}

/// Bounded work sections inside one synchronous first-key callback. The labels never
/// identify the key, client, document, candidate, or result content.
enum InputDiagnosticOutcome: String, Sendable {
    case handled, passThrough, skipped
}

enum InputDiagnosticReason: String, DiagnosticLabel {
    case none, rime, engineMissing, engineUnavailable
    case voiceDeliveringHandled, voiceDeliveringPassThrough, voiceHandled
    case aiAccepting, controlShortcut, aiSuggestionAccepted
    case committed, cleared, deactivated, clientMissing, reactivated, teardown
}

struct InputDeliveryDiagnostic: Sendable {
    let clientPresent: Bool
    let commitInsertion: Bool
    let markedTextUpdate: Bool
    let markedTextClear: Bool
}

struct InputDiagnosticRecord: Sendable {
    let event: InputDiagnosticEvent
    let reason: InputDiagnosticReason
    let outcome: InputDiagnosticOutcome?
    let controller: UUID
    let activation: UUID?
    let key: UUID?
    var stage: InputDiagnosticStage? = nil
    var elapsedMilliseconds: Double? = nil
    var composition: UUID? = nil
    var engineAvailable: Bool? = nil
    var clientPresent: Bool? = nil
    var commitInsertion: Bool? = nil
    var markedTextUpdate: Bool? = nil
    var markedTextClear: Bool? = nil

    var message: String {
        var fields = ["event=\(event.rawValue)", "reason=\(reason.rawValue)",
                      "controller=\(controller.uuidString)"]
        if let activation { fields.append("activation=\(activation.uuidString)") }
        if let key { fields.append("key=\(key.uuidString)") }
        if let stage { fields.append("stage=\(stage.rawValue)") }
        if let elapsedMilliseconds { fields.append("elapsed_ms=\(String(format: "%.3f", elapsedMilliseconds))") }
        if let composition { fields.append("composition=\(composition.uuidString)") }
        if let outcome { fields.append("outcome=\(outcome.rawValue)") }
        if let engineAvailable { fields.append("engine_available=\(engineAvailable)") }
        if let clientPresent { fields.append("client_present=\(clientPresent)") }
        if let commitInsertion { fields.append("commit_insertion=\(commitInsertion)") }
        if let markedTextUpdate { fields.append("marked_text_update=\(markedTextUpdate)") }
        if let markedTextClear { fields.append("marked_text_clear=\(markedTextClear)") }
        return fields.joined(separator: " ")
    }
}

enum InputDiagnostics {
    private static let logger = Logger(subsystem: "io.damao.inputmethod.inkflow", category: "input")
    // Focused tests observe the exact allowlisted records written to the unified log.
    @TaskLocal static var observe: (@Sendable (InputDiagnosticRecord) -> Void)?

    static func write(_ record: InputDiagnosticRecord) {
        let outcome: LocalDiagnosticEvent.Outcome = record.outcome.flatMap { .init(rawValue: $0.rawValue) }
            ?? (record.event == .insertionIssued || record.event == .compositionBegan ? .begin : .completed)
        LocalDiagnostics.shared.submit(.init(module: .input, event: record.event, outcome: outcome,
            reason: record.reason, correlation: record.composition ?? record.key ?? record.activation,
            elapsedMilliseconds: record.elapsedMilliseconds,
            context: .init(controller: record.controller, activation: record.activation, key: record.key,
                composition: record.composition, inputStage: record.stage,
                engineAvailable: record.engineAvailable, clientPresent: record.clientPresent,
                commitInsertion: record.commitInsertion, markedTextUpdate: record.markedTextUpdate, markedTextClear: record.markedTextClear)))
        let message = record.message
        logger.notice("\(message, privacy: .public)")
        observe?(record)
    }
}

@MainActor
final class IFInputLifecycleDiagnostics {
    final class FirstKeyToken {
        fileprivate let activation: UUID
        fileprivate let key: UUID
        fileprivate let started: TimeInterval
        fileprivate var completed = false

        fileprivate init(activation: UUID, key: UUID, started: TimeInterval) {
            self.activation = activation
            self.key = key
            self.started = started
        }
    }
    let controller: UUID
    private var activation: UUID?
    private var recordedFirstKey = false
    private var created = false
    private var released = false
    private let clock: @Sendable () -> TimeInterval
    struct CompositionToken { let id: UUID; let activation: UUID? }
    private var composition: CompositionToken?
    private var unavailableReported = false

    init(controller: UUID = UUID(), clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.controller = controller
        self.clock = clock
    }

    func controllerCreated() {
        guard !created else { return }
        created = true
        emit(.controllerCreated)
    }

    func beginActivation() {
        endComposition(.reactivated)
        activation = UUID()
        recordedFirstKey = false
        unavailableReported = false
    }

    func engineAvailability(_ available: Bool, reason: InputDiagnosticReason = .engineUnavailable) {
        if available { unavailableReported = false; return }
        guard !unavailableReported else { return }
        unavailableReported = true
        emit(.engineUnavailable, reason: reason, outcome: .skipped, engineAvailable: false)
    }

    @discardableResult func beginComposition() -> CompositionToken {
        if let composition { return composition }
        let token = CompositionToken(id: UUID(), activation: activation)
        composition = token
        emitComposition(.compositionBegan, token: token, reason: .none)
        return token
    }

    func endComposition(_ reason: InputDiagnosticReason) {
        guard let token = composition else { return }
        composition = nil
        emitComposition(.compositionEnded, token: token, reason: reason)
    }

    func insertionBegan(clientPresent: Bool) -> CompositionToken {
        let token = beginComposition()
        // Reserve/end current composition before client delivery may synchronously activate another.
        composition = nil
        emitComposition(.insertionIssued, token: token, reason: clientPresent ? .none : .clientMissing,
                        outcome: clientPresent ? .handled : .skipped, clientPresent: clientPresent)
        return token
    }

    func insertionFinished(_ token: CompositionToken, clientPresent: Bool) {
        emitComposition(.insertionReturned, token: token, reason: clientPresent ? .none : .clientMissing,
                        outcome: clientPresent ? .handled : .skipped, clientPresent: clientPresent)
        emitComposition(.compositionEnded, token: token, reason: clientPresent ? .committed : .clientMissing)
    }

    private func emitComposition(_ event: InputDiagnosticEvent, token: CompositionToken,
                                 reason: InputDiagnosticReason, outcome: InputDiagnosticOutcome? = nil,
                                 clientPresent: Bool? = nil) {
        InputDiagnostics.write(.init(event: event, reason: reason, outcome: outcome, controller: controller,
            activation: token.activation, key: nil, composition: token.id, clientPresent: clientPresent))
    }

    func finishActivation(engineAvailable: Bool) {
        emit(engineAvailable ? .activationReady : .activationSkipped,
             reason: engineAvailable ? .none : .engineUnavailable,
             engineAvailable: engineAvailable)
    }

    func recordFirstKey(outcome: InputDiagnosticOutcome, reason: InputDiagnosticReason,
                        delivery: InputDeliveryDiagnostic? = nil) {
        guard let token = beginFirstKey() else { return }
        finishFirstKey(token, outcome: outcome, reason: reason, delivery: delivery)
    }

    func beginFirstKey() -> FirstKeyToken? {
        guard !recordedFirstKey else { return nil }
        let current = activation ?? UUID()
        activation = current
        // Reserve before editor delivery, which can synchronously reenter the controller.
        recordedFirstKey = true
        let token = FirstKeyToken(activation: current, key: UUID(), started: clock())
        emit(.firstKeyEntered, activationID: token.activation, key: token.key)
        return token
    }

    /// Emits only after a synchronous section returns, so it never changes input flow.
    func checkpointFirstKey(_ token: FirstKeyToken?, stage: InputDiagnosticStage) {
        guard let token, !token.completed else { return }
        emit(.firstKeyCheckpoint, activationID: token.activation, key: token.key,
             stage: stage, elapsedMilliseconds: max(0, clock() - token.started) * 1000)
    }

    func finishFirstKey(_ token: FirstKeyToken?, outcome: InputDiagnosticOutcome,
                        reason: InputDiagnosticReason, delivery: InputDeliveryDiagnostic? = nil) {
        guard let token, !token.completed else { return }
        token.completed = true
        emit(.firstKeyCompleted, reason: reason, outcome: outcome,
             activationID: token.activation, key: token.key,
             elapsedMilliseconds: max(0, clock() - token.started) * 1000,
             clientPresent: delivery?.clientPresent,
             commitInsertion: delivery?.commitInsertion,
             markedTextUpdate: delivery?.markedTextUpdate,
             markedTextClear: delivery?.markedTextClear)
    }

    func deactivationEntered() { endComposition(.deactivated); emit(.deactivationEntered) }
    func deactivationBeforeSuper() { emit(.deactivationBeforeSuper) }
    func deactivationAfterSuper() { emit(.deactivationAfterSuper) }
    func deactivationFinished() { emit(.deactivationFinished) }

    func controllerReleased() {
        guard !released else { return }
        released = true
        endComposition(.teardown)
        emit(.controllerReleased)
    }

    private func emit(_ event: InputDiagnosticEvent, reason: InputDiagnosticReason = .none,
                      outcome: InputDiagnosticOutcome? = nil, engineAvailable: Bool? = nil,
                      activationID: UUID? = nil, key: UUID? = nil,
                      stage: InputDiagnosticStage? = nil, elapsedMilliseconds: Double? = nil,
                      clientPresent: Bool? = nil, commitInsertion: Bool? = nil,
                      markedTextUpdate: Bool? = nil, markedTextClear: Bool? = nil) {
        InputDiagnostics.write(InputDiagnosticRecord(event: event, reason: reason, outcome: outcome,
            controller: controller, activation: activationID ?? activation, key: key,
            stage: stage, elapsedMilliseconds: elapsedMilliseconds,
            engineAvailable: engineAvailable,
            clientPresent: clientPresent, commitInsertion: commitInsertion,
            markedTextUpdate: markedTextUpdate, markedTextClear: markedTextClear))
    }
}
