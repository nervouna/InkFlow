import Foundation
import InkFlowAppleEngine

@MainActor
final class KeyboardProxyMutationScope {
    private var depth = 0

    var isActive: Bool {
        depth > 0
    }

    func perform<Result>(_ mutation: () throws -> Result) rethrows -> Result {
        depth += 1
        defer { depth -= 1 }
        return try mutation()
    }
}

struct KeyboardContextGeneration: Sendable {
    private(set) var generation: UInt64 = 0
    private var isExternalCallbackBatchOpen = false

    mutating func beginExternalCallback() -> UInt64? {
        guard !isExternalCallbackBatchOpen else { return nil }
        isExternalCallbackBatchOpen = true
        generation &+= 1
        return generation
    }

    mutating func endExternalCallbackBatch() {
        isExternalCallbackBatchOpen = false
    }

    mutating func invalidateForLifecycleBoundary() {
        generation &+= 1
        isExternalCallbackBatchOpen = false
    }

    func accepts(_ capturedGeneration: UInt64) -> Bool {
        generation == capturedGeneration
    }
}

struct KeyboardVisibilityEpoch: Sendable {
    private enum Phase: Sendable {
        case hidden
        case visible
        case disappearing
    }

    private(set) var value: UInt64 = 0
    private var phase = Phase.hidden

    var allowsEngineInput: Bool {
        phase == .visible
    }

    var allowsFinish: Bool {
        phase != .hidden
    }

    mutating func beginAppearance() {
        value &+= 1
        phase = .visible
    }

    mutating func beginDisappearance() {
        value &+= 1
        phase = .disappearing
    }

    mutating func completeDisappearance() {
        value &+= 1
        phase = .hidden
    }
}

struct KeyboardResetBarrier: Sendable {
    struct Token: Equatable, Sendable {
        fileprivate let sequence: UInt64
        fileprivate let generation: UInt64
    }

    private var nextSequence: UInt64 = 0
    private var activeToken: Token?

    var isBlocking: Bool {
        activeToken != nil
    }

    mutating func begin(generation: UInt64) -> Token {
        nextSequence &+= 1
        let token = Token(sequence: nextSequence, generation: generation)
        activeToken = token
        return token
    }

    mutating func engineResetCompleted(
        _ token: Token,
        currentGeneration: UInt64
    ) -> Bool {
        guard activeToken == token,
              token.generation == currentGeneration else {
            return false
        }
        activeToken = nil
        return true
    }

    mutating func invalidate() {
        activeToken = nil
    }
}

struct KeyboardFinishGuard: Sendable {
    struct Token: Equatable, Sendable {
        fileprivate let sequence: UInt64
        fileprivate let visibilityEpoch: UInt64
    }

    private var nextSequence: UInt64 = 0
    private var activeToken: Token?

    var isFinishing: Bool {
        activeToken != nil
    }

    mutating func begin(visibilityEpoch: UInt64) -> Token? {
        guard activeToken == nil else { return nil }
        nextSequence &+= 1
        let token = Token(
            sequence: nextSequence,
            visibilityEpoch: visibilityEpoch
        )
        activeToken = token
        return token
    }

    mutating func invalidate() {
        activeToken = nil
    }

    mutating func complete(
        _ token: Token,
        currentVisibilityEpoch: UInt64
    ) -> Bool {
        guard activeToken == token,
              token.visibilityEpoch == currentVisibilityEpoch else {
            return false
        }
        activeToken = nil
        return true
    }
}

enum KeyboardUpdateRendering: Equatable, Sendable {
    case clearAfterCommit(String)
    case composition(preedit: String, candidates: [EngineCandidate])

    init(_ update: EngineUpdate) {
        if let commit = update.commitText, !commit.isEmpty {
            self = .clearAfterCommit(commit)
        } else {
            self = .composition(
                preedit: update.preedit,
                candidates: update.candidates
            )
        }
    }
}

struct KeyboardPipelineOutput: Sendable {
    enum Action: Sendable {
        case update(EngineUpdate)
        case insertText(String)
        case deleteBackward
        case noOp
    }

    let revision: UInt64
    let action: Action
}

final class KeyboardEnginePipeline: @unchecked Sendable {
    typealias Completion = @MainActor @Sendable (KeyboardPipelineOutput) -> Void

    private let queue = DispatchQueue(label: "io.inkflow.local.ios-keyboard-actions")
    private let session: EngineSession
    private var latestUpdate: EngineUpdate
    private var revision: UInt64 = 0

    init(session: EngineSession) throws {
        self.session = session
        latestUpdate = try session.currentSnapshot()
    }

    func process(_ event: EngineKeyEvent, completion: @escaping Completion) {
        submit({
            .update(try self.session.process(event))
        }, completion: completion)
    }

    func backspace(completion: @escaping Completion) {
        submit({
            let hadComposition = !self.latestUpdate.preedit.isEmpty
            let update = try self.session.process(EngineKeyEvent(key: EngineKey.backspace))
            if !update.handled && !hadComposition {
                self.latestUpdate = update
                return .deleteBackward
            }
            return .update(update)
        }, completion: completion)
    }

    func space(completion: @escaping Completion) {
        submit({
            if !self.latestUpdate.preedit.isEmpty {
                return .update(
                    try self.session.process(EngineKeyEvent(key: EngineKey.space))
                )
            }
            return .insertText(" ")
        }, completion: completion)
    }

    func enter(completion: @escaping Completion) {
        submit({
            if !self.latestUpdate.preedit.isEmpty {
                return .update(try self.session.commit())
            }
            return .insertText("\n")
        }, completion: completion)
    }

    func selectCandidate(
        at index: Int,
        expectedRevision: UInt64,
        completion: @escaping Completion
    ) {
        submit({
            guard self.revision == expectedRevision,
                  index >= 0,
                  index < self.latestUpdate.candidates.count else {
                return .noOp
            }
            return .update(try self.session.selectCandidate(at: index))
        }, completion: completion)
    }

    func cancel(completion: @escaping Completion) {
        submit({
            .update(try self.session.reset())
        }, completion: completion)
    }

    func finishComposition(completion: @escaping Completion) {
        submit({
            if !self.latestUpdate.preedit.isEmpty {
                return .update(try self.session.commit())
            }
            return .update(try self.session.reset())
        }, completion: completion)
    }

    private func submit(
        _ operation: @escaping @Sendable () throws -> KeyboardPipelineOutput.Action,
        completion: @escaping Completion
    ) {
        queue.async {
            let action: KeyboardPipelineOutput.Action
            do {
                action = try operation()
            } catch {
                if let reset = try? self.session.reset() {
                    action = .update(reset)
                } else {
                    action = .noOp
                }
            }
            if case let .update(update) = action {
                self.latestUpdate = update
                self.revision &+= 1
            }
            let output = KeyboardPipelineOutput(
                revision: self.revision,
                action: action
            )
            let delivered = DispatchSemaphore(value: 0)
            Task { @MainActor in
                completion(output)
                delivered.signal()
            }
            delivered.wait()
        }
    }
}
