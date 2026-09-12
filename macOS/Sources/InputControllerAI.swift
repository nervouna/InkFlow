@preconcurrency import InputMethodKit
import Carbon

/// AI-only controller state and behavior. The offline controller keeps only stable delegation seams.
@MainActor
final class IFInputControllerAI {
    private weak var controller: IFInputControllerShell?
    private let statisticsStore: AIStatisticsStore?
    private let service: any AISuggestionServing
    private var client: IMKTextInput?
    private(set) var isAccepting = false
    private var suggestions: AISuggestionCoordinator?
    private let diagnosticSession = UUID()
    private var gateReason: AIDiagnosticReason?
    private var statisticsAppBundleID: String?

    init(statisticsStore: AIStatisticsStore?, service: any AISuggestionServing = AIChatCompletionsClient()) {
        self.statisticsStore = statisticsStore
        self.service = service
    }

    func configure(_ controller: IFInputControllerShell) {
        self.controller = controller
        suggestions = AISuggestionCoordinator(settings: controller.settings.smart, service: service,
            diagnosticSession: diagnosticSession, statisticsStore: statisticsStore,
            statisticsAssociation: { [weak self] in
                guard let self, let controller = self.controller else { return .init() }
                let recorder = controller.engine?.qualityRecorder
                return .init(compositionID: recorder?.activeCompositionID, appBundleID: self.statisticsAppBundleID,
                    lastEditAt: recorder?.timingSnapshot?.lastEditAt, lastEditMonotonic: recorder?.lastEditMonotonicTime,
                    observedVisibleAfterEdit: recorder?.timingSnapshot?.observedVisibleDuration,
                    candidates: controller.strings, candidatePage: controller.engine?.snapshot().page)
            }, statisticsNow: { [weak self] in
                guard let controller = self?.controller else { return .now }
                return .init(utc: controller.qualityClock.utc(), monotonic: controller.qualityClock.monotonic())
            }, current: { [weak self] in self?.smartState() },
            candidatesVisible: { [weak self] in self?.controller?.candidatePresentation?.candidatesVisible ?? false },
            context: { [weak self] anchor in
                guard let self, let client = self.client, let controller = self.controller else {
                    AIDiagnostics.emit(.contextRejected, reason: .missingClient); return nil
                }
                return AISurroundingContext.read(client, anchor: anchor, secureInput: controller.secureInput)
            }, allows: { [weak self] input, text in
                self?.controller?.engine?.allowsAIRecommendation(input: input, text: text) ?? false
            }, present: { [weak self] text in self?.controller?.aiPresentation?.presentSuggestion(text) ?? false },
            visible: { [weak self] in self?.controller?.aiPresentation?.suggestionVisible ?? false },
            hide: { [weak self] in self?.controller?.aiPresentation?.hideSuggestion() })
    }

    func makePresentation(_ panel: IMKCandidates) -> any AISuggestionPresentation { NativeAIInputPresentation(panel: panel) }

    func addMenuItem(to menu: NSMenu, target: IFInputControllerShell, action: Selector) {
        guard let controller else { return }
        let available = controller.settings.smart.isAvailable
        let item = menu.addItem(withTitle: "智能预测", action: available ? action : nil, keyEquivalent: "")
        item.target = target
        item.isEnabled = available
        item.state = controller.settings.smart.isEnabled ? .on : .off
    }

    func toggle() {
        guard let settings = controller?.settings.smart, settings.isAvailable else { return }
        settings.isEnabled.toggle()
    }

    func beginRefresh(client: IMKTextInput?) { suggestions?.beginRefresh(); self.client = client }
    func endRefresh() { suggestions?.endRefresh() }
    func validate() { suggestions?.validate() }
    func associate(appBundleID: String?) { statisticsAppBundleID = appBundleID }
    func invalidate(_ reason: AIDiagnosticReason) { suggestions?.invalidate(reason: reason) }
    func settingsChanged() { invalidate(.settingsChanged); suggestions?.synchronize() }
    func teardown() { invalidate(.teardown); controller?.aiPresentation?.hideSuggestion() }

    func deactivateEntered() { AIDiagnostics.emit(.deactivateEntered, session: diagnosticSession) }
    func deactivateCommitted() { AIDiagnostics.emit(.deactivateCommitted, session: diagnosticSession) }
    func deactivateFinished() {
        AIDiagnostics.emit(.deactivateSuperReturned, session: diagnosticSession)
        invalidate(.deactivate)
        client = nil
        AIDiagnostics.emit(.deactivateFinished, session: diagnosticSession)
    }

    private func smartState() -> AISuggestionState? {
        guard !isAccepting else { recordGate(.accepting); return nil }
        guard let controller else { recordGate(.missingEngine); return nil }
        guard !controller.secureInput() else { recordGate(.secureInput); return nil }
        guard let candidatePresentation = controller.candidatePresentation else { recordGate(.missingPanel); return nil }
        guard !controller.strings.isEmpty else { recordGate(.emptyCandidates); return nil }
        guard let engine = controller.engine else { recordGate(.missingEngine); return nil }
        guard let input = engine.aiInputIdentity() else { recordGate(.inputUnavailable); return nil }
        guard let anchor = AIClientAnchor.read(client, ownsMarkedText: controller.ownsMarkedText, secureInput: false,
                                              rejected: recordGate) else { return nil }
        recordGate(candidatePresentation.candidatesVisible ? .ready : .panelHidden)
        return AISuggestionState(input: input, anchor: anchor)
    }

    private func recordGate(_ reason: AIDiagnosticReason) {
        guard gateReason != reason else { return }
        gateReason = reason
        AIDiagnostics.emit(.eligibility, reason: reason, session: diagnosticSession)
    }

    static func candidateScreenFrame(_ panel: IMKCandidates) -> NSRect? {
        let size = panel.candidateFrame().size
        guard size.width > 0, size.height > 0 else {
            AIDiagnostics.emit(.presentationFailed, reason: .invalidCandidateFrame); return nil
        }
        let matches = NSApp.windows.filter {
            $0.isVisible && !AISuggestionPanel.isSuggestionWindow($0) &&
                abs($0.frame.width - size.width) < 1 && abs($0.frame.height - size.height) < 1
        }
        guard matches.count == 1 else {
            AIDiagnostics.emit(.presentationFailed, reason: matches.isEmpty ? .noCandidateWindow : .ambiguousCandidateWindow)
            return nil
        }
        return matches[0].frame
    }

    func acceptSuggestion(_ event: NSEvent, client eventClient: IMKTextInput?, entered: TimeInterval) -> Bool {
        guard let controller, event.type == .keyDown, event.keyCode == 48,
              event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
              let eventClient, ObjectIdentifier(eventClient as AnyObject) == client.map({ ObjectIdentifier($0 as AnyObject) }),
              let engine = controller.engine, !engine.snapshot().preedit.isEmpty,
              let input = engine.aiInputIdentity() else { return false }
        if event.isARepeat, controller.aiPresentation?.suggestionVisible == true {
            engine.qualityRecorder?.recordExternalKey(.tab, isRepeat: true, at: entered)
            return true
        }
        if event.isARepeat { return false }
        let stamp = AIStatisticsStamp(utc: controller.qualityClock.utc().addingTimeInterval(
            entered - controller.qualityClock.monotonic()), monotonic: entered)
        guard let adoption = suggestions?.takeSuggestion(at: stamp) else { return false }
        isAccepting = true
        engine.beginDelivery()
        controller.qualityInsertionDepth += 1
        defer { controller.qualityInsertionDepth -= 1; engine.endDelivery(); isAccepting = false }
        engine.qualityRecorder?.recordExternalKey(.aiTab, isRepeat: false, at: entered)
        engine.qualityRecorder?.finishExternalSelection(reason: "ai_adopted", at: entered)
        let preferences = engine.inputPreferences
        let pronunciation = engine.aiPronunciation(input: input, text: adoption.text)
        engine.clear(recordQuality: false)
        engine.learnAIAdoption(input: input, text: adoption.text, preferences: preferences, pronunciation: pronunciation)
        controller.ownsMarkedText = false
        adoption.statistics?.record(.insertionIssued,
            at: .init(utc: controller.qualityClock.utc(), monotonic: controller.qualityClock.monotonic()))
        AIDiagnostics.emit(.insertionIssued, attempt: adoption.attempt, session: diagnosticSession)
        eventClient.insertText(adoption.text, replacementRange: NSRange(location: NSNotFound, length: 0))
        adoption.statistics?.record(.insertionReturned,
            at: .init(utc: controller.qualityClock.utc(), monotonic: controller.qualityClock.monotonic()))
        AIDiagnostics.emit(.insertionReturned, attempt: adoption.attempt, session: diagnosticSession)
        if controller.settings.thunderMode {
            controller.thunderPresentation?.burst(.commit, client: eventClient, characterIndex: 0)
        }
        controller.refresh(eventClient)
        return true
    }
}
