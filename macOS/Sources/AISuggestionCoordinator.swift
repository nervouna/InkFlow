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
    private let context: (AIClientAnchor) -> AISurroundingContext?
    private let present: (String) -> Bool
    private let visible: () -> Bool
    private let hide: () -> Void
    private let delay: Duration
    private var state: AISuggestionState?
    private var configuration: AISuggestionConfiguration?
    private var revision: UInt64 = 0
    private var request: Task<Void, Never>?
    private var tracker: Timer?
    private var preview: (text: String, context: AISurroundingContext)?
    private var refreshDepth = 0
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    init(settings: IFSmartSettings, service: any AISuggestionServing,
         delay: Duration = .milliseconds(500), current: @escaping () -> AISuggestionState?,
         context: @escaping (AIClientAnchor) -> AISurroundingContext?,
         present: @escaping (String) -> Bool, visible: @escaping () -> Bool, hide: @escaping () -> Void) {
        self.settings = settings; self.service = service; self.delay = delay
        self.current = current; self.context = context
        self.present = present; self.visible = visible; self.hide = hide
    }

    isolated deinit { request?.cancel(); tracker?.invalidate(); hide() }

    func invalidate() {
        revision &+= 1
        request?.cancel(); request = nil
        state = nil; configuration = nil; preview = nil
        tracker?.invalidate(); tracker = nil
        hide()
    }

    /// Called before any controller-owned document mutation, and by a cheap UI tracker.
    /// This never reads surrounding document text or starts inference.
    func validate() {
        guard refreshDepth == 0 else { return }
        guard let state else { return }
        guard settings.isEnabled, settings.configuration == configuration, current() == state else {
            invalidate(); return
        }
        if let preview, !present(preview.text) { invalidate() }
    }

    func synchronize(ownedRefresh: Bool = false) {
        guard refreshDepth == 0 else { return }
        guard settings.isEnabled, let next = current() else { invalidate(); return }
        let sameComposition = state.map {
            $0.input == next.input && $0.anchor.client == next.anchor.client &&
                $0.anchor.mark.location == next.anchor.mark.location
        } ?? false
        if (state == next || (ownedRefresh && sameComposition)), configuration == settings.configuration {
            // validate() ran before this controller-authored mark update. Rebind only
            // its display ranges, preserving the original input deadline and request.
            state = next
            if let preview, !present(preview.text) { invalidate() }
            return
        }
        invalidate()
        state = next; configuration = settings.configuration
        let token = revision, configuration = settings.configuration
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.validate() }
        }
        tracker = timer; RunLoop.main.add(timer, forMode: .common)
        let service = service, delay = delay
        request = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                await self?.waitForRefresh()
                guard let self, let captured = self.capture(token, input: next.input, configuration: configuration) else { return }
                let context = captured.context
                let input = AISuggestionInput(precedingText: context.precedingText, followingText: context.followingText,
                                              pinyin: next.input.rawInput, selectedPrefix: next.input.selectedPrefix)
                let text = try await service.suggest(input: input, configuration: configuration)
                await self.waitForRefresh()
                guard let latest = self.capture(token, input: next.input, configuration: configuration),
                      latest.context == context else { return }
                self.settings.setRequestError(nil)
                guard self.matches(token, input: next.input, configuration: configuration), self.present(text),
                      self.matches(token, input: next.input, configuration: configuration) else { self.invalidate(); return }
                self.preview = (text, context)
            } catch {
                guard let self, self.matches(token, input: next.input, configuration: configuration),
                      !(error is CancellationError) else { return }
                self.settings.setRequestError(error as? AIServiceError ?? .network)
            }
        }
    }

    private func matches(_ token: UInt64, input: AIInputIdentity,
                         configuration: AISuggestionConfiguration) -> Bool {
        guard refreshDepth == 0, revision == token, let state, state.input == input, settings.isEnabled,
              settings.configuration == configuration else { return false }
        let observed = current()
        // Even range getters may synchronously reenter the controller.
        return revision == token && self.state == state && settings.isEnabled &&
            settings.configuration == configuration && observed == state
    }

    private func capture(_ token: UInt64, input: AIInputIdentity,
                         configuration: AISuggestionConfiguration) -> (state: AISuggestionState, context: AISurroundingContext)? {
        guard matches(token, input: input, configuration: configuration), let state,
              let context = context(state.anchor), self.state == state,
              matches(token, input: input, configuration: configuration) else { return nil }
        return (state, context)
    }

    func takeSuggestion() -> (text: String, anchor: AIClientAnchor)? {
        guard refreshDepth == 0 else { return nil }
        guard let state, let preview, let configuration, visible(),
              let captured = capture(revision, input: state.input, configuration: configuration),
              captured.context == preview.context, visible() else { invalidate(); return nil }
        let accepted = (preview.text, captured.state.anchor)
        invalidate()
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
