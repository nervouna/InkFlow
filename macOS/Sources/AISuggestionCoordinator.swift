import AppKit

struct AISuggestionState: Equatable {
    let input: AIInputIdentity
    let anchor: AIClientAnchor
}

/// Owns one request attempt per unchanged composition, including failures. All document
/// and UI callbacks are synchronous on MainActor; only the service runs asynchronously.
@MainActor
final class AISuggestionCoordinator {
    private let settings: IFSmartSettings
    private let service: any AISuggestionServing
    private let current: () -> AISuggestionState?
    private let candidatesVisible: () -> Bool
    private let context: (AIClientAnchor) -> AISurroundingContext?
    private let present: (String) -> Bool
    private let visible: () -> Bool
    private let hide: () -> Void
    private let delay: Duration
    private let diagnosticSession: UUID
    private var attemptID: UUID?
    private var settingsGate: AIDiagnosticReason?
    private var state: AISuggestionState?
    private var configuration: AISuggestionConfiguration?
    private var revision: UInt64 = 0
    private var request: Task<Void, Never>?
    private var tracker: Timer?
    private var preview: String?
    private var requiresVisibleCandidates = false
    private var refreshDepth = 0
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    init(settings: IFSmartSettings, service: any AISuggestionServing,
         delay: Duration = .milliseconds(500), diagnosticSession: UUID = UUID(),
         current: @escaping () -> AISuggestionState?,
         candidatesVisible: @escaping () -> Bool = { true },
         context: @escaping (AIClientAnchor) -> AISurroundingContext?,
         present: @escaping (String) -> Bool, visible: @escaping () -> Bool, hide: @escaping () -> Void) {
        self.settings = settings; self.service = service; self.delay = delay
        self.diagnosticSession = diagnosticSession
        self.current = current; self.candidatesVisible = candidatesVisible; self.context = context
        self.present = present; self.visible = visible; self.hide = hide
    }

    isolated deinit {
        if attemptID != nil { log(.invalidated, reason: .teardown) }
        request?.cancel(); tracker?.invalidate(); hide()
    }

    private func log(_ event: AIDiagnosticEvent, reason: AIDiagnosticReason = .none) {
        AIDiagnostics.emit(event, reason: reason, attempt: attemptID, session: diagnosticSession)
    }

    private func traced<T>(_ body: () -> T) -> T {
        AIDiagnostics.$session.withValue(diagnosticSession) {
            AIDiagnostics.$attempt.withValue(attemptID, operation: body)
        }
    }

    func invalidate(reason: AIDiagnosticReason = .explicit) {
        if attemptID != nil { log(.invalidated, reason: reason) }
        attemptID = nil
        revision &+= 1
        request?.cancel(); request = nil
        state = nil; configuration = nil; preview = nil
        requiresVisibleCandidates = false
        tracker?.invalidate(); tracker = nil
        hide()
    }

    /// Called before any controller-owned document mutation, and by a cheap UI tracker.
    /// This never reads surrounding document text or starts inference.
    func validate() {
        guard refreshDepth == 0 else { return }
        guard let state else { return }
        guard settings.isEnabled else { invalidate(reason: .disabled); return }
        guard settings.configuration == configuration else { invalidate(reason: .configurationChanged); return }
        guard traced({ current() }) == state else { invalidate(reason: .stateChanged); return }
        guard !requiresVisibleCandidates || candidatesVisible() else { invalidate(reason: .panelHidden); return }
        if let preview, !traced({ present(preview) }) { invalidate(reason: .presentation) }
    }

    func synchronize(ownedRefresh: Bool = false) {
        guard refreshDepth == 0 else { return }
        guard settings.isEnabled else {
            let reason: AIDiagnosticReason = settings.isAvailable ? .disabled : .incompleteConfiguration
            if settingsGate != reason { settingsGate = reason; log(.eligibility, reason: reason) }
            invalidate(reason: reason); return
        }
        settingsGate = nil
        guard let next = traced({ current() }) else { invalidate(reason: .stateChanged); return }
        let sameComposition = state.map {
            $0.input == next.input && $0.anchor.client == next.anchor.client &&
                $0.anchor.mark.location == next.anchor.mark.location
        } ?? false
        if (state == next || (ownedRefresh && sameComposition)), configuration == settings.configuration {
            // validate() ran before this controller-authored mark update. Rebind only
            // its display ranges, preserving the original input deadline and request.
            state = next
            if let preview, !traced({ present(preview) }) { invalidate(reason: .presentation) }
            return
        }
        invalidate(reason: .inputChanged)
        let attempt = UUID(), diagnosticSession = diagnosticSession
        attemptID = attempt
        state = next; configuration = settings.configuration
        log(.scheduled)
        let token = revision, configuration = settings.configuration
        let observer = AIDiagnostics.observe
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            AIDiagnostics.$observe.withValue(observer) {
                MainActor.assumeIsolated { self?.validate() }
            }
        }
        tracker = timer; RunLoop.main.add(timer, forMode: .common)
        let service = service, delay = delay
        request = Task { [weak self] in
          await AIDiagnostics.$session.withValue(diagnosticSession) {
           await AIDiagnostics.$attempt.withValue(attempt) {
            do {
                try await Task.sleep(for: delay)
                await self?.waitForRefresh()
                // show() is asynchronous for some native clients. Keep the original
                // input deadline and wait without capturing document text. A weak
                // reference across each wait permits untouched sessions to deallocate.
                while true {
                    guard self?.matches(token, input: next.input, configuration: configuration) == true else {
                        AIDiagnostics.emit(.discarded, reason: .staleState); return
                    }
                    if self?.candidatesVisible() == true { break }
                    try await Task.sleep(for: .milliseconds(100))
                    await self?.waitForRefresh()
                }
                self?.requiresVisibleCandidates = true
                guard let self, let context = self.capture(token, input: next.input, configuration: configuration) else { return }
                let input = AISuggestionInput(precedingText: context.precedingText, followingText: context.followingText,
                                              pinyin: next.input.rawInput, selectedPrefix: next.input.selectedPrefix)
                AIDiagnostics.emit(.dispatched)
                let text = try await service.suggest(input: input, configuration: configuration)
                await self.waitForRefresh()
                guard self.matches(token, input: next.input, configuration: configuration) else {
                    AIDiagnostics.emit(.discarded, reason: .staleState); return
                }
                self.settings.setRequestError(nil)
                guard self.matches(token, input: next.input, configuration: configuration) else {
                    AIDiagnostics.emit(.discarded, reason: .staleState)
                    self.invalidate(reason: .stateChanged); return
                }
                guard self.present(text) else {
                    AIDiagnostics.emit(.discarded, reason: .presentation)
                    self.invalidate(reason: .presentation); return
                }
                guard self.matches(token, input: next.input, configuration: configuration) else {
                    AIDiagnostics.emit(.discarded, reason: .staleState)
                    self.invalidate(reason: .stateChanged); return
                }
                self.preview = text
                AIDiagnostics.emit(.shown)
            } catch {
                guard !(error is CancellationError) else { AIDiagnostics.emit(.cancelled); return }
                guard let self, self.matches(token, input: next.input, configuration: configuration) else {
                    AIDiagnostics.emit(.discarded, reason: .staleState); return
                }
                AIDiagnostics.emit(.failed, reason: AIDiagnostics.reason(for: error))
                self.settings.setRequestError(error as? AIServiceError ?? .network)
            }
           }
          }
        }
    }

    private func matches(_ token: UInt64, input: AIInputIdentity,
                         configuration: AISuggestionConfiguration) -> Bool {
        guard refreshDepth == 0, revision == token, let state, state.input == input, settings.isEnabled,
              !requiresVisibleCandidates || candidatesVisible(),
              settings.configuration == configuration else { return false }
        let observed = traced { current() }
        // Even range getters may synchronously reenter the controller.
        return revision == token && self.state == state && settings.isEnabled &&
            (!requiresVisibleCandidates || candidatesVisible()) &&
            settings.configuration == configuration && observed == state
    }

    private func capture(_ token: UInt64, input: AIInputIdentity,
                         configuration: AISuggestionConfiguration) -> AISurroundingContext? {
        guard matches(token, input: input, configuration: configuration), let state else {
            AIDiagnostics.emit(.discarded, reason: .staleState); return nil
        }
        guard let context = traced({ context(state.anchor) }) else {
            AIDiagnostics.emit(.discarded, reason: .contextUnavailable); return nil
        }
        guard self.state == state, matches(token, input: input, configuration: configuration) else {
            AIDiagnostics.emit(.discarded, reason: .staleState); return nil
        }
        return context
    }

    func takeSuggestion() -> (text: String, anchor: AIClientAnchor)? {
        guard refreshDepth == 0 else { return nil }
        let token = revision
        guard let state, let preview, let configuration, visible(),
              matches(token, input: state.input, configuration: configuration), visible(),
              revision == token, let currentState = self.state else { invalidate(reason: .acceptanceUnavailable); return nil }
        let accepted = (preview, currentState.anchor)
        log(.accepted)
        invalidate(reason: .accepted)
        return accepted
    }

    func beginRefresh() {
        validate()
        refreshDepth += 1
    }

    func endRefresh() {
        refreshDepth -= 1
        guard refreshDepth == 0 else { return }
        synchronize(ownedRefresh: true)
        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForRefresh() async {
        if refreshDepth > 0 { await withCheckedContinuation { refreshWaiters.append($0) } }
    }
}
