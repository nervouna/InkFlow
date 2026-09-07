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

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        settings = MainActor.assumeIsolated { .sharedSettings }
        settingsWindow = MainActor.assumeIsolated { .sharedController }
        super.init(server: server, delegate: delegate, client: inputClient)
        nonisolated(unsafe) let callbackServer = server
        MainActor.assumeIsolated { configure(server: callbackServer) }
    }

    init!(server: IMKServer!, delegate: Any!, client inputClient: Any!,
          settings: IFSettings, settingsWindow: IFSettingsWindowController, qualityStore: QualityStore? = nil) {
        injectedQualityStore = qualityStore
        self.settings = settings
        self.settingsWindow = settingsWindow
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
        applySettings()
        NotificationCenter.default.addObserver(self, selector: #selector(engineChanged(_:)),
                                               name: .engineAvailabilityDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)),
                                               name: .settingsDidChange, object: settings)
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        panel = nil
        selectionLayout = nil
    }

    nonisolated override func menu() -> NSMenu! {
        // A synchronous legacy return value cannot cross assumeIsolated's Sendable result boundary.
        nonisolated(unsafe) var result: NSMenu?
        MainActor.assumeIsolated {
            let menu = NSMenu(title: "InkFlow")
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
            result = menu
        }
        return result
    }

    nonisolated override func showPreferences(_ sender: Any!) {
        // IMK dispatches an action dictionary, not an NSMenuItem.
        MainActor.assumeIsolated { settingsWindow.present() }
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
        if engine == nil, IFEngine.ready { engine = IFEngine(qualityStore: injectedQualityStore) }
        applySettings()
    }

    func refresh(_ client: IMKTextInput?) {
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
            guard !updating, let text, let index = strings.firstIndex(of: text) else { return }
            associateQualityClient(client())
            engine?.select(index, trigger: .panel, ambiguousText: strings.filter { $0 == text }.count > 1)
            refresh(client())
        }
    }

    nonisolated override func candidateSelectionChanged(_ candidate: NSAttributedString!) {
        let text = candidate?.string
        MainActor.assumeIsolated {
            guard !updating, let text, let index = strings.firstIndex(of: text) else { return }
            engine?.highlight(index)
            refresh(client())
        }
    }

    nonisolated override func commitComposition(_ sender: Any!) {
        nonisolated(unsafe) let callbackClient = sender
        MainActor.assumeIsolated {
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
    }
}
