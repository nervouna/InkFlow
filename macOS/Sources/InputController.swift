@preconcurrency import InputMethodKit
import Carbon
#if SWIFT_PACKAGE
import InkFlowNative
#endif

@MainActor
// The legacy superclass blocks inferred Sendable conformance. State stays on MainActor;
// callback arguments only enter synchronous assumeIsolated scopes, never tasks or queues.
class IFInputControllerShell: IMKInputController, @unchecked Sendable {
    static var statisticsStore: AIStatisticsStore?
    var engine: IFEngine?
    var panel: IMKCandidates?
    var strings: [String] = []
    var updating = false
    var ownsMarkedText = false
    var qualityInsertionDepth = 0
    var injectedQualityStore: QualityStore?
    let qualityClock: QualityClock
    var qualityVisibilityTimer: Timer?
    let settings: IFSettings
    let settingsWindow: IFSettingsWindowController
    var secureInput: () -> Bool = { IsSecureEventInputEnabled() }
    var candidatePresentation: (any CandidatePresentation)?
    var aiPresentation: (any AISuggestionPresentation)?
    let ai: IFInputControllerAI

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        settings = MainActor.assumeIsolated { .sharedSettings }
        settingsWindow = MainActor.assumeIsolated { .sharedController }
        qualityClock = MainActor.assumeIsolated { QualityClock() }
        ai = MainActor.assumeIsolated { IFInputControllerAI(statisticsStore: Self.statisticsStore) }
        super.init(server: server, delegate: delegate, client: inputClient)
        nonisolated(unsafe) let callbackServer = server
        MainActor.assumeIsolated { configure(server: callbackServer) }
    }

    init!(server: IMKServer!, delegate: Any!, client inputClient: Any!,
          settings: IFSettings, settingsWindow: IFSettingsWindowController, qualityStore: QualityStore? = nil,
          qualityClock: QualityClock = QualityClock(),
          aiStatisticsStore: AIStatisticsStore? = nil,
          smartService: any AISuggestionServing = AIChatCompletionsClient(),
          secureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() },
          presentation: (any AIInputPresentation)? = nil) {
        injectedQualityStore = qualityStore
        self.qualityClock = qualityClock
        self.settings = settings
        self.settingsWindow = settingsWindow
        ai = IFInputControllerAI(statisticsStore: aiStatisticsStore, service: smartService)
        self.secureInput = secureInput
        candidatePresentation = presentation
        aiPresentation = presentation
        super.init(server: server, delegate: delegate, client: inputClient)
        configure(server: server)
    }

    private func configure(server: IMKServer?) {
        engine = IFEngine(qualityStore: injectedQualityStore, qualityClock: qualityClock)
        if candidatePresentation == nil, let server {
            panel = IMKCandidates(server: server, panelType: kIMKSingleRowSteppingCandidatePanel)
            panel?.setDismissesAutomatically(false)
            if let panel {
                candidatePresentation = NativeCandidatePresentation(panel: panel)
                aiPresentation = ai.makePresentation(panel)
            }
        }
        ai.configure(self)
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
        qualityVisibilityTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        ai.teardown()
        candidatePresentation = nil
        aiPresentation = nil
        panel = nil
    }

    nonisolated override func menu() -> NSMenu! {
        // A synchronous legacy return value cannot cross assumeIsolated's Sendable result boundary.
        nonisolated(unsafe) var result: NSMenu?
        MainActor.assumeIsolated {
            let menu = NSMenu(title: "InkFlow")
            menu.autoenablesItems = false
            let ascii = engine?.requestedASCIIMode ?? false
            menu.addItem(withTitle: (ascii ? "切换到中文输入" : "切换到英文输入") + "（左 Shift）",
                         action: #selector(toggleInputMode(_:)), keyEquivalent: "").target = self
            let punctuation = menu.addItem(withTitle: "英文标点", action: #selector(toggleEnglishPunctuation(_:)), keyEquivalent: "")
            punctuation.target = self
            punctuation.state = settings.inputPreferences[.englishPunctuation] ? .on : .off
            let traditional = menu.addItem(withTitle: "繁体输入", action: #selector(toggleTraditional(_:)), keyEquivalent: "")
            traditional.target = self
            traditional.state = settings.inputPreferences[.traditional] ? .on : .off
            menu.addItem(.separator())
            menu.addItem(withTitle: "打开设置", action: #selector(showPreferences(_:)), keyEquivalent: "").target = self
            ai.addMenuItem(to: menu, target: self, action: #selector(toggleSmartPrediction(_:)))
            result = menu
        }
        return result
    }

    nonisolated override func showPreferences(_ sender: Any!) {
        // IMK dispatches an action dictionary, not an NSMenuItem.
        MainActor.assumeIsolated { settingsWindow.present() }
    }

    @objc nonisolated func toggleSmartPrediction(_ sender: Any!) {
        MainActor.assumeIsolated { ai.toggle() }
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

    func applySettings() {}

    func applyPresentationSettings() {
        engine?.setQualityPresentation(fontSize: settings.fontSize, vertical: settings.vertical)
        let wasUpdating = updating
        updating = true
        defer { updating = wasUpdating }
        guard let panel else { return }
        panel.setPanelType(settings.vertical ? kIMKSingleColumnScrollingCandidatePanel : kIMKSingleRowSteppingCandidatePanel)
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
        ai.invalidate(.engineChanged)
        if engine == nil, IFEngine.ready { engine = IFEngine(qualityStore: injectedQualityStore, qualityClock: qualityClock) }
        applySettings()
    }

    func refresh(_ client: IMKTextInput?) {}

    func didPresentCandidates() {
        if let engine {
            engine.qualityRecorder?.presented(engine.qualitySnapshot(), revision: engine.qualityRevision,
                                              panelShowIssued: candidatePresentation != nil && !strings.isEmpty)
        }
        observeQualityVisibility()
    }

    /// Native panel show is asynchronous. Observe only visibility during an active
    /// composition, even when AI is disabled; never read document content per tick.
    func observeQualityVisibility(at monotonicTime: TimeInterval? = nil) {
        guard let recorder = engine?.qualityRecorder else { return }
        recorder.setTimingCaptureEnabled(!secureInput())
        guard recorder.activeCompositionID != nil, recorder.timingSnapshot != nil else {
            qualityVisibilityTimer?.invalidate()
            qualityVisibilityTimer = nil
            return
        }
        if let candidatePresentation {
            recorder.observeCandidateVisibility(candidatePresentation.candidatesVisible, at: monotonicTime)
        }
        if qualityVisibilityTimer == nil, candidatePresentation != nil {
            let timer = Timer(timeInterval: QualityLimits.visibilityObservationInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.observeQualityVisibility() }
            }
            qualityVisibilityTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func associateQualityClient(_ client: IMKTextInput?) {
        let app = client?.bundleIdentifier()
        ai.associate(appBundleID: app)
        engine?.qualityRecorder?.associateClient(client.map { $0 as AnyObject },
            id: client?.uniqueClientIdentifierString(), app: app)
    }

    nonisolated override func activateServer(_ sender: Any!) {
        let span = IFStartupDiagnostics.shared.begin(.activation, source: .client)
        super.activateServer(sender)
        IFStartupDiagnostics.shared.end(span, MainActor.assumeIsolated { IFEngine.ready } ? .ready : .skipped)
    }

    nonisolated override func deactivateServer(_ sender: Any!) {
        let span = IFStartupDiagnostics.shared.begin(.deactivation, source: .client)
        defer { IFStartupDiagnostics.shared.end(span) }
        MainActor.assumeIsolated { ai.deactivateEntered() }
        commitComposition(sender)
        MainActor.assumeIsolated { ai.deactivateCommitted() }
        super.deactivateServer(sender)
        MainActor.assumeIsolated { ai.deactivateFinished() }
    }

    nonisolated override func hidePalettes() {
        MainActor.assumeIsolated {
            ai.invalidate(.hidePalettes)
            observeQualityVisibility()
            candidatePresentation?.hideCandidates()
            observeQualityVisibility()
        }
        super.hidePalettes()
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        ai.invalidate(.workspaceChanged)
        observeQualityVisibility()
    }

    @objc private func smartSettingsChanged(_ notification: Notification) {
        ai.settingsChanged()
    }

    static func candidateScreenFrame(_ panel: IMKCandidates) -> NSRect? {
        IFInputControllerAI.candidateScreenFrame(panel)
    }
}
