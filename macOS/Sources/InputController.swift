@preconcurrency import InputMethodKit
import Carbon

@MainActor
@objc(InkFlowInputController)
// The legacy superclass blocks inferred Sendable conformance. State stays on MainActor;
// callback arguments only enter synchronous assumeIsolated scopes, never tasks or queues.
final class InkFlowInputController: IMKInputController, @unchecked Sendable {
    private(set) var engine: IFEngine?
    var panel: IMKCandidates?
    private var selectionLayout: TISInputSource?
    private var strings: [String] = []
    private var updating = false
    private var ownsMarkedText = false
    private var qualityInsertionDepth = 0
    private var injectedQualityStore: QualityStore?
    private let settings: IFSettings
    private let settingsWindow: IFSettingsWindowController
    private var smartClient: IMKTextInput?
    private var acceptingAI = false
    private var smartService: any AISuggestionServing = AIChatCompletionsClient()
    private var secureInput: () -> Bool = { IsSecureEventInputEnabled() }
    private var presentation: (any AIInputPresentation)?
    private var smartSuggestions: AISuggestionCoordinator?
    private let smartDiagnosticSession = UUID()
    private var smartGateReason: AIDiagnosticReason?

    private func configureSmartSuggestions() {
        smartSuggestions = AISuggestionCoordinator(settings: settings.smart, service: smartService,
            diagnosticSession: smartDiagnosticSession,
            current: { [weak self] in self?.smartState() },
            candidatesVisible: { [weak self] in self?.presentation?.candidatesVisible ?? false },
            context: { [weak self] anchor in
                guard let self, let client = self.smartClient else {
                    AIDiagnostics.emit(.contextRejected, reason: .missingClient); return nil
                }
                return AISurroundingContext.read(client, anchor: anchor, secureInput: self.secureInput)
            }, allows: { [weak self] input, text in self?.engine?.allowsAIRecommendation(input: input, text: text) ?? false },
            present: { [weak self] text in self?.presentation?.presentSuggestion(text) ?? false },
            visible: { [weak self] in self?.presentation?.suggestionVisible ?? false },
            hide: { [weak self] in self?.presentation?.hideSuggestion() })
    }

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        settings = MainActor.assumeIsolated { .sharedSettings }
        settingsWindow = MainActor.assumeIsolated { .sharedController }
        super.init(server: server, delegate: delegate, client: inputClient)
        nonisolated(unsafe) let callbackServer = server
        MainActor.assumeIsolated { configure(server: callbackServer) }
    }

    init!(server: IMKServer!, delegate: Any!, client inputClient: Any!,
          settings: IFSettings, settingsWindow: IFSettingsWindowController, qualityStore: QualityStore? = nil,
          smartService: any AISuggestionServing = AIChatCompletionsClient(),
          secureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() },
          presentation: (any AIInputPresentation)? = nil) {
        injectedQualityStore = qualityStore
        self.settings = settings
        self.settingsWindow = settingsWindow
        self.smartService = smartService
        self.secureInput = secureInput
        self.presentation = presentation
        super.init(server: server, delegate: delegate, client: inputClient)
        configure(server: server)
    }

    private func configure(server: IMKServer?) {
        engine = IFEngine(qualityStore: injectedQualityStore)
        if presentation == nil, let server {
            panel = IMKCandidates(server: server, panelType: kIMKSingleRowSteppingCandidatePanel)
            let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.US"] as CFDictionary
            if let layouts = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
               let layout = layouts.first {
                // IMKCandidates borrows this source; retain it through panel teardown.
                selectionLayout = layout
                panel?.setSelectionKeysKeylayout(layout)
            }
            panel?.setDismissesAutomatically(false)
            if let panel { presentation = NativeAIInputPresentation(panel: panel) }
        }
        configureSmartSuggestions()
        applySettings()
        NotificationCenter.default.addObserver(self, selector: #selector(engineChanged(_:)),
                                               name: .engineAvailabilityDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)),
                                               name: .settingsDidChange, object: settings)
        NotificationCenter.default.addObserver(self, selector: #selector(smartSettingsChanged(_:)),
                                               name: .smartSettingsDidChange, object: settings.smart)
        for name in [NSWorkspace.didDeactivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceChanged(_:)), name: name, object: nil)
        }
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        smartSuggestions?.invalidate(reason: .teardown)
        presentation?.hideSuggestion()
        presentation = nil
        panel = nil
        selectionLayout = nil
    }

    nonisolated override func menu() -> NSMenu! {
        // A synchronous legacy return value cannot cross assumeIsolated's Sendable result boundary.
        nonisolated(unsafe) var result: NSMenu?
        MainActor.assumeIsolated {
            let menu = NSMenu(title: "InkFlow")
            menu.autoenablesItems = false
            let ascii = engine?.requestedASCIIMode ?? false
            menu.addItem(withTitle: ascii ? "切换到中文输入" : "切换到英文输入",
                         action: #selector(toggleInputMode(_:)), keyEquivalent: "").target = self
            let punctuation = menu.addItem(withTitle: "英文标点", action: #selector(toggleEnglishPunctuation(_:)), keyEquivalent: "")
            punctuation.target = self
            punctuation.state = settings.inputPreferences[.englishPunctuation] ? .on : .off
            let traditional = menu.addItem(withTitle: "繁体输入", action: #selector(toggleTraditional(_:)), keyEquivalent: "")
            traditional.target = self
            traditional.state = settings.inputPreferences[.traditional] ? .on : .off
            menu.addItem(.separator())
            menu.addItem(withTitle: "打开设置", action: #selector(showPreferences(_:)), keyEquivalent: "").target = self
            let available = settings.smart.isAvailable
            // IMK enables exported entries with an action, even when NSMenuItem is disabled.
            let smart = menu.addItem(withTitle: "智能预测", action: available ? #selector(toggleSmartPrediction(_:)) : nil, keyEquivalent: "")
            smart.target = self
            smart.isEnabled = available
            smart.state = settings.smart.isEnabled ? .on : .off
            result = menu
        }
        return result
    }

    nonisolated override func showPreferences(_ sender: Any!) {
        // IMK dispatches an action dictionary, not an NSMenuItem.
        MainActor.assumeIsolated { settingsWindow.present() }
    }

    @objc nonisolated func toggleSmartPrediction(_ sender: Any!) {
        MainActor.assumeIsolated {
            guard settings.smart.isAvailable else { return }
            settings.smart.isEnabled.toggle()
        }
    }

    @objc nonisolated func toggleInputMode(_ sender: Any?) {
        MainActor.assumeIsolated { engine?.asciiMode = !(engine?.requestedASCIIMode ?? false) }
    }

    @objc nonisolated func toggleEnglishPunctuation(_ sender: Any?) {
        MainActor.assumeIsolated {
            settings.setInputOption(.englishPunctuation, enabled: !settings.inputPreferences[.englishPunctuation])
        }
    }

    @objc nonisolated func toggleTraditional(_ sender: Any?) {
        MainActor.assumeIsolated {
            settings.setInputOption(.traditional, enabled: !settings.inputPreferences[.traditional])
        }
    }

    func applySettings() {
        engine?.setConfiguration(candidateCount: settings.candidateCount, customPhrases: settings.customPhrases,
                                 inputPreferences: settings.inputPreferences)
        if settings.inputSettingsError != engine?.configurationError {
            settings.inputSettingsError = engine?.configurationError
        }
        engine?.setQualityPresentation(fontSize: settings.fontSize, vertical: settings.vertical)
        let wasUpdating = updating
        updating = true
        defer { updating = wasUpdating }
        guard let panel else { return }
        panel.setPanelType(settings.vertical ? kIMKSingleColumnScrollingCandidatePanel : kIMKSingleRowSteppingCandidatePanel)
        let keys = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        panel.setSelectionKeys(Array(keys.prefix(engine?.candidateCount ?? 5)))
        panel.setAttributes([IMKCandidatesSendServerKeyEventFirst: true,
                             NSAttributedString.Key.font: NSFont.systemFont(ofSize: CGFloat(settings.fontSize))])
        IFApplyCandidateFont(panel, Double(settings.fontSize))
        // Direction/font changes rebuild native traits; apply minimum width afterward.
        IFApplyMinimumVerticalWidth(panel)
    }

    @objc private func settingsChanged(_ notification: Notification) {
        applySettings()
        if let engine, !engine.snapshot().preedit.isEmpty, let client = client() {
            refresh(client)
        }
    }

    @objc private func engineChanged(_ notification: Notification) {
        smartSuggestions?.invalidate(reason: .engineChanged)
        if engine == nil, IFEngine.ready { engine = IFEngine(qualityStore: injectedQualityStore) }
        applySettings()
    }

    func refresh(_ client: IMKTextInput?) {
        smartSuggestions?.beginRefresh()
        defer { smartSuggestions?.endRefresh() }
        smartClient = client
        let deliveringEngine = engine
        deliveringEngine?.beginDelivery()
        defer { deliveringEngine?.endDelivery() }
        associateQualityClient(client)
        let commit = engine?.takeCommit(recordQuality: false) ?? ""
        if !commit.isEmpty {
            // Insertion consumes our mark; never replace the resulting selection with an empty mark.
            ownsMarkedText = false
            qualityInsertionDepth += 1
            defer { qualityInsertionDepth -= 1 }
            client?.insertText(commit, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        // insertText can synchronously reenter IMK with an empty finish callback. Its empty
        // drain cannot close the outer record, including raw paths with no expected candidate.
        if !commit.isEmpty || qualityInsertionDepth == 0 {
            engine?.qualityRecorder?.commitDrained(commit, insertionIssued: !commit.isEmpty && client != nil,
                                                  clientID: client?.uniqueClientIdentifierString())
        }
        if let engine, !engine.snapshot().preedit.isEmpty {
            engine.setPrecedingText(IFPrecedingText.read(from: client, ownsMarkedText: ownsMarkedText))
        } else { engine?.setPrecedingText("") }
        let state = engine?.snapshot() ?? EngineSnapshot()
        if !state.preedit.isEmpty {
            ownsMarkedText = true
            client?.setMarkedText(state.preedit, selectionRange: NSRange(location: state.cursor, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        } else if ownsMarkedText {
            ownsMarkedText = false
            client?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        strings = state.candidates
        updating = true
        applySettings()
        presentation?.refreshCandidates(strings, highlight: state.highlight)
        updating = false
        if let engine {
            engine.qualityRecorder?.presented(engine.qualitySnapshot(), revision: engine.qualityRevision,
                                              panelShowIssued: presentation != nil && !strings.isEmpty)
        }
    }

    private func associateQualityClient(_ client: IMKTextInput?) {
        engine?.qualityRecorder?.associateClient(client.map { $0 as AnyObject },
            id: client?.uniqueClientIdentifierString(), app: client?.bundleIdentifier())
    }

    // InputMethodKit's legacy callbacks are synchronous and main-thread-bound but lack actor annotations.
    nonisolated override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        nonisolated(unsafe) let callbackEvent = event
        nonisolated(unsafe) let callbackClient = sender
        return MainActor.assumeIsolated {
            guard !acceptingAI else { return false }
            smartSuggestions?.validate()
            if let callbackEvent, acceptSuggestion(callbackEvent, client: callbackClient as? IMKTextInput) { return true }
            if engine == nil, IFEngine.ready { engine = IFEngine(qualityStore: injectedQualityStore); applySettings() }
            guard let engine, engine.available, let callbackEvent, callbackEvent.type == .keyDown else { return false }
            associateQualityClient(callbackClient as? IMKTextInput)
            // A selection/flush must use the order already shown, even if the client
            // stops exposing its document or moves the selection before that event.
            if engine.snapshot().preedit.isEmpty {
                engine.setPrecedingText(IFPrecedingText.read(from: callbackClient as? IMKTextInput,
                                                           ownsMarkedText: ownsMarkedText))
            }
            let handled = engine.event(callbackEvent)
            if !handled && !engine.snapshot().preedit.isEmpty { engine.commit() }
            refresh(callbackClient as? IMKTextInput)
            return handled
        }
    }

    nonisolated override func candidates(_ sender: Any!) -> [Any]! {
        MainActor.assumeIsolated { strings }
    }

    nonisolated override func candidateSelected(_ candidate: NSAttributedString!) {
        let text = candidate?.string
        MainActor.assumeIsolated {
            guard !acceptingAI, !updating, let text, let index = strings.firstIndex(of: text) else { return }
            associateQualityClient(client())
            engine?.select(index, trigger: .panel, ambiguousText: strings.filter { $0 == text }.count > 1)
            refresh(client())
        }
    }

    nonisolated override func candidateSelectionChanged(_ candidate: NSAttributedString!) {
        let text = candidate?.string
        MainActor.assumeIsolated {
            guard !acceptingAI, !updating, let text, let index = strings.firstIndex(of: text) else { return }
            engine?.highlight(index)
            refresh(client())
        }
    }

    nonisolated override func commitComposition(_ sender: Any!) {
        nonisolated(unsafe) let callbackClient = sender
        MainActor.assumeIsolated {
            guard !acceptingAI else { return }
            smartSuggestions?.invalidate(reason: .commit)
            let activeClient = (callbackClient as? IMKTextInput) ?? client()
            associateQualityClient(activeClient)
            engine?.commit()
            refresh(activeClient)
            presentation?.hideCandidates()
        }
    }

    nonisolated override func deactivateServer(_ sender: Any!) {
        MainActor.assumeIsolated { AIDiagnostics.emit(.deactivateEntered, session: smartDiagnosticSession) }
        commitComposition(sender)
        MainActor.assumeIsolated { AIDiagnostics.emit(.deactivateCommitted, session: smartDiagnosticSession) }
        super.deactivateServer(sender)
        MainActor.assumeIsolated {
            AIDiagnostics.emit(.deactivateSuperReturned, session: smartDiagnosticSession)
            smartSuggestions?.invalidate(reason: .deactivate); smartClient = nil
            AIDiagnostics.emit(.deactivateFinished, session: smartDiagnosticSession)
        }
    }

    nonisolated override func hidePalettes() {
        MainActor.assumeIsolated { smartSuggestions?.invalidate(reason: .hidePalettes); presentation?.hideCandidates() }
        super.hidePalettes()
    }

    @objc private func workspaceChanged(_ notification: Notification) { smartSuggestions?.invalidate(reason: .workspaceChanged) }

    @objc private func smartSettingsChanged(_ notification: Notification) {
        smartSuggestions?.invalidate(reason: .settingsChanged)
        smartSuggestions?.synchronize()
    }

    private func smartState() -> AISuggestionState? {
        guard !acceptingAI else { recordSmartGate(.accepting); return nil }
        guard !secureInput() else { recordSmartGate(.secureInput); return nil }
        guard let presentation else { recordSmartGate(.missingPanel); return nil }
        guard !strings.isEmpty else { recordSmartGate(.emptyCandidates); return nil }
        guard let engine else { recordSmartGate(.missingEngine); return nil }
        guard let input = engine.aiInputIdentity() else { recordSmartGate(.inputUnavailable); return nil }
        guard let anchor = AIClientAnchor.read(smartClient, ownsMarkedText: ownsMarkedText, secureInput: false,
                                              rejected: recordSmartGate) else { return nil }
        // Native show() can complete on a later run-loop turn. Composition identity
        // remains valid while the coordinator waits for actual window visibility.
        recordSmartGate(presentation.candidatesVisible ? .ready : .panelHidden)
        return AISuggestionState(input: input, anchor: anchor)
    }

    private func recordSmartGate(_ reason: AIDiagnosticReason) {
        guard smartGateReason != reason else { return }
        smartGateReason = reason
        AIDiagnostics.emit(.eligibility, reason: reason, session: smartDiagnosticSession)
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

    private func acceptSuggestion(_ event: NSEvent, client: IMKTextInput?) -> Bool {
        guard event.type == .keyDown, event.keyCode == 48,
              event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
              let client, ObjectIdentifier(client as AnyObject) == smartClient.map({ ObjectIdentifier($0 as AnyObject) }),
              let engine, !engine.snapshot().preedit.isEmpty,
              let input = engine.aiInputIdentity() else { return false }
        // A held Tab never accepts a suggestion that arrived after its initial keydown.
        if event.isARepeat { return presentation?.suggestionVisible ?? false }
        guard let adoption = smartSuggestions?.takeSuggestion() else { return false }
        acceptingAI = true
        engine.beginDelivery()
        qualityInsertionDepth += 1
        defer { qualityInsertionDepth -= 1; engine.endDelivery(); acceptingAI = false }
        let preferences = engine.inputPreferences
        let pronunciation = engine.aiPronunciation(input: input, text: adoption.text)
        engine.clear()
        engine.learnAIAdoption(input: input, text: adoption.text, preferences: preferences, pronunciation: pronunciation)
        // Match ordinary commits: insertion replaces the client's active mark. Clear
        // only our ownership first, so a reentrant refresh cannot erase that mark.
        ownsMarkedText = false
        AIDiagnostics.emit(.insertionIssued, attempt: adoption.attempt, session: smartDiagnosticSession)
        client.insertText(adoption.text, replacementRange: NSRange(location: NSNotFound, length: 0))
        AIDiagnostics.emit(.insertionReturned, attempt: adoption.attempt, session: smartDiagnosticSession)
        refresh(client)
        return true
    }
}
