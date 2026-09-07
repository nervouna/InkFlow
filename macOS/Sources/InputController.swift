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
    private var suggestionPanel: AISuggestionPanel?
    private var smartSuggestions: AISuggestionCoordinator?

    private func configureSmartSuggestions() {
        smartSuggestions = AISuggestionCoordinator(settings: settings.smart, service: smartService,
            current: { [weak self] in self?.smartState() },
            context: { [weak self] anchor in
                guard let client = self?.smartClient else { return nil }
                return AISurroundingContext.read(client, anchor: anchor)
            }, present: { [weak self] text in self?.presentSuggestion(text) ?? false },
            visible: { [weak self] in self?.suggestionPanel?.isVisible ?? false },
            hide: { [weak self] in self?.suggestionPanel?.hide() })
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
          secureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() }) {
        injectedQualityStore = qualityStore
        self.settings = settings
        self.settingsWindow = settingsWindow
        self.smartService = smartService
        self.secureInput = secureInput
        super.init(server: server, delegate: delegate, client: inputClient)
        configure(server: server)
    }

    private func configure(server: IMKServer?) {
        engine = IFEngine(qualityStore: injectedQualityStore)
        if let server {
            panel = IMKCandidates(server: server, panelType: kIMKSingleRowSteppingCandidatePanel)
            let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.US"] as CFDictionary
            if let layouts = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
               let layout = layouts.first {
                // IMKCandidates borrows this source; retain it through panel teardown.
                selectionLayout = layout
                panel?.setSelectionKeysKeylayout(layout)
            }
            panel?.setDismissesAutomatically(false)
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
        smartSuggestions?.invalidate()
        suggestionPanel?.hide()
        panel = nil
        selectionLayout = nil
    }

    nonisolated override func menu() -> NSMenu! {
        // A synchronous legacy return value cannot cross assumeIsolated's Sendable result boundary.
        nonisolated(unsafe) var result: NSMenu?
        MainActor.assumeIsolated {
            let menu = NSMenu(title: "InkFlow")
            menu.autoenablesItems = false
            menu.addItem(withTitle: "打开设置", action: #selector(showPreferences(_:)), keyEquivalent: "").target = self
            let smart = menu.addItem(withTitle: "智能预测", action: #selector(toggleSmartPrediction(_:)), keyEquivalent: "")
            smart.target = self
            smart.isEnabled = settings.smart.isAvailable
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

    func applySettings() {
        engine?.setConfiguration(candidateCount: settings.candidateCount, customPhrases: settings.customPhrases)
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
        smartSuggestions?.invalidate()
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
        panel?.update()
        if !strings.isEmpty, let panel {
            let index = min(max(0, state.highlight), strings.count - 1)
            panel.selectCandidate(withIdentifier: panel.candidateStringIdentifier(strings[index]))
            panel.show(kIMKLocateCandidatesBelowHint)
        } else { panel?.hide() }
        updating = false
        if let engine {
            engine.qualityRecorder?.presented(engine.qualitySnapshot(), revision: engine.qualityRevision,
                                              panelShowIssued: panel != nil && !strings.isEmpty)
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
            smartSuggestions?.invalidate()
            let activeClient = (callbackClient as? IMKTextInput) ?? client()
            associateQualityClient(activeClient)
            engine?.commit()
            refresh(activeClient)
            panel?.hide()
        }
    }

    nonisolated override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
        super.deactivateServer(sender)
        MainActor.assumeIsolated { smartSuggestions?.invalidate(); smartClient = nil }
    }

    nonisolated override func hidePalettes() {
        MainActor.assumeIsolated { smartSuggestions?.invalidate(); panel?.hide() }
        super.hidePalettes()
    }

    @objc private func workspaceChanged(_ notification: Notification) { smartSuggestions?.invalidate() }

    @objc private func smartSettingsChanged(_ notification: Notification) {
        smartSuggestions?.invalidate()
        smartSuggestions?.synchronize()
    }

    private func smartState() -> AISuggestionState? {
        guard !acceptingAI, !secureInput(), panel?.isVisible() == true, !strings.isEmpty,
              let input = engine?.aiInputIdentity(),
              let anchor = AIClientAnchor.read(smartClient, ownsMarkedText: ownsMarkedText, secureInput: false) else { return nil }
        return AISuggestionState(input: input, anchor: anchor)
    }

    private func presentSuggestion(_ text: String) -> Bool {
        guard let panel, panel.isVisible(), let frame = Self.candidateScreenFrame(panel) else { return false }
        if suggestionPanel == nil { suggestionPanel = AISuggestionPanel() }
        guard let suggestionPanel else { return false }
        suggestionPanel.setSuggestion(text)
        suggestionPanel.show(relativeTo: frame)
        return suggestionPanel.isVisible
    }

    static func candidateScreenFrame(_ panel: IMKCandidates) -> NSRect? {
        let size = panel.candidateFrame().size
        guard size.width > 0, size.height > 0 else { return nil }
        let matches = NSApp.windows.filter {
            $0.isVisible && !AISuggestionPanel.isSuggestionWindow($0) &&
                abs($0.frame.width - size.width) < 1 && abs($0.frame.height - size.height) < 1
        }
        return matches.count == 1 ? matches[0].frame : nil
    }

    private func acceptSuggestion(_ event: NSEvent, client: IMKTextInput?) -> Bool {
        guard event.type == .keyDown, event.keyCode == 48,
              event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
              let client, ObjectIdentifier(client as AnyObject) == smartClient.map({ ObjectIdentifier($0 as AnyObject) }),
              let engine, !engine.snapshot().preedit.isEmpty else { return false }
        // A held Tab never accepts a suggestion that arrived after its initial keydown.
        if event.isARepeat { return suggestionPanel?.isVisible ?? false }
        guard let accepted = smartSuggestions?.takeSuggestion() else { return false }
        acceptingAI = true
        engine.beginDelivery()
        qualityInsertionDepth += 1
        defer { qualityInsertionDepth -= 1; engine.endDelivery(); acceptingAI = false }
        engine.clear()
        refresh(client)
        client.insertText(accepted.text, replacementRange: NSRange(location: accepted.anchor.mark.location, length: 0))
        return true
    }
}
