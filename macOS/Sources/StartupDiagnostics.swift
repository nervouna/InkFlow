import Foundation
import os

/// Content-free, constant-size events. Run ID and PID separate cold starts from client switches.
struct IFStartupDiagnostics: Sendable {
    enum Stage: String, Sendable {
        case process, bootstrap, backend, journal, fingerprint, cacheValidation, indexes, rebuild
        case worker, engine, initialization, maintenance, server, eventLoop, activation, deactivation
    }
    enum Source: String, Sendable { case process, bundled, downloaded, prepared, client }
    enum Status: String, Sendable { case begin, ready, failed, skipped, cancelled, timeout }
    struct Span: Sendable {
        let id: UUID
        let stage: Stage
        let source: Source
        let started: TimeInterval
    }
    static let shared = IFStartupDiagnostics()
    private static let logger = Logger(subsystem: "io.damao.inputmethod.inkflow", category: "startup")
    let run: UUID
    let pid: Int32
    private let clock: @Sendable () -> TimeInterval
    private let sink: @Sendable (String) -> Void

    init(run: UUID = UUID(), pid: Int32 = ProcessInfo.processInfo.processIdentifier,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sink: @escaping @Sendable (String) -> Void = { message in
             IFStartupDiagnostics.logger.notice("\(message, privacy: .public)")
         }) {
        self.run = run; self.pid = pid; self.clock = clock; self.sink = sink
    }
    func begin(_ stage: Stage, source: Source = .process) -> Span {
        let span = Span(id: UUID(), stage: stage, source: source, started: clock())
        emit(span, .begin)
        return span
    }
    func end(_ span: Span, _ status: Status = .ready) { emit(span, status) }
    private func emit(_ span: Span, _ status: Status) {
        let elapsed = max(0, clock() - span.started) * 1000
        sink("run=\(run) pid=\(pid) span=\(span.id) stage=\(span.stage.rawValue) source=\(span.source.rawValue) status=\(status.rawValue) elapsed_ms=\(String(format: "%.3f", elapsed))")
    }
    func measure<T>(_ stage: Stage, source: Source = .process, _ body: () throws -> T) rethrows -> T {
        let span = begin(stage, source: source)
        do { let value = try body(); end(span); return value }
        catch { end(span, .failed); throw error }
    }
}

/// Fixed labels and boolean delivery facts only. Never add key metadata, input text,
/// candidates, document values, identifiers from a client, paths or error descriptions.
enum InputDiagnosticEvent: String, Sendable {
    case controllerCreated, controllerReleased
    case activationReady, activationSkipped
    case firstKeyEntered, firstKeyCompleted
    case deactivationEntered, deactivationBeforeSuper, deactivationAfterSuper, deactivationFinished
}

enum InputDiagnosticOutcome: String, Sendable {
    case handled, passThrough, skipped
}

enum InputDiagnosticReason: String, Sendable {
    case none, rime, engineMissing, engineUnavailable
    case voiceDeliveringHandled, voiceDeliveringPassThrough, voiceHandled
    case aiAccepting, controlShortcut, aiSuggestionAccepted
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
        fileprivate var completed = false

        fileprivate init(activation: UUID, key: UUID) {
            self.activation = activation
            self.key = key
        }
    }
    let controller: UUID
    private var activation: UUID?
    private var recordedFirstKey = false
    private var created = false
    private var released = false

    init(controller: UUID = UUID()) {
        self.controller = controller
    }

    func controllerCreated() {
        guard !created else { return }
        created = true
        emit(.controllerCreated)
    }

    func beginActivation() {
        activation = UUID()
        recordedFirstKey = false
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
        let token = FirstKeyToken(activation: current, key: UUID())
        emit(.firstKeyEntered, activationID: token.activation, key: token.key)
        return token
    }

    func finishFirstKey(_ token: FirstKeyToken?, outcome: InputDiagnosticOutcome,
                        reason: InputDiagnosticReason, delivery: InputDeliveryDiagnostic? = nil) {
        guard let token, !token.completed else { return }
        token.completed = true
        emit(.firstKeyCompleted, reason: reason, outcome: outcome,
             activationID: token.activation, key: token.key,
             clientPresent: delivery?.clientPresent,
             commitInsertion: delivery?.commitInsertion,
             markedTextUpdate: delivery?.markedTextUpdate,
             markedTextClear: delivery?.markedTextClear)
    }

    func deactivationEntered() { emit(.deactivationEntered) }
    func deactivationBeforeSuper() { emit(.deactivationBeforeSuper) }
    func deactivationAfterSuper() { emit(.deactivationAfterSuper) }
    func deactivationFinished() { emit(.deactivationFinished) }

    func controllerReleased() {
        guard !released else { return }
        released = true
        emit(.controllerReleased)
    }

    private func emit(_ event: InputDiagnosticEvent, reason: InputDiagnosticReason = .none,
                      outcome: InputDiagnosticOutcome? = nil, engineAvailable: Bool? = nil,
                      activationID: UUID? = nil, key: UUID? = nil,
                      clientPresent: Bool? = nil, commitInsertion: Bool? = nil,
                      markedTextUpdate: Bool? = nil, markedTextClear: Bool? = nil) {
        InputDiagnostics.write(InputDiagnosticRecord(event: event, reason: reason, outcome: outcome,
            controller: controller, activation: activationID ?? activation, key: key,
            engineAvailable: engineAvailable,
            clientPresent: clientPresent, commitInsertion: commitInsertion,
            markedTextUpdate: markedTextUpdate, markedTextClear: markedTextClear))
    }
}
