@preconcurrency import InputMethodKit
import Carbon

/// Audited offline IMK path. AI may consume only an explicitly recognized plain Tab;
/// presentation callbacks run after the offline state transition and cannot replace it.
@MainActor
@objc(InkFlowInputController)
final class InkFlowInputController: IFInputControllerShell, @unchecked Sendable {
    private var selectionKeyLayout: TISInputSource?

    override func applySettings() {
        engine?.setConfiguration(candidateCount: settings.candidateCount, customPhrases: settings.customPhrases,
                                 inputPreferences: settings.inputPreferences)
        if settings.inputSettingsError != engine?.configurationError {
            settings.inputSettingsError = engine?.configurationError
        }
        applyPresentationSettings()
        applySelectionKeys()
    }

    private func applySelectionKeys() {
        if selectionKeyLayout == nil {
            let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.US"] as CFDictionary
            selectionKeyLayout = (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first
        }
        // IMKCandidates borrows this source; retain it for the controller lifetime.
        if let selectionKeyLayout { panel?.setSelectionKeysKeylayout(selectionKeyLayout) }
        let keys = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        panel?.setSelectionKeys(Array(keys.prefix(engine?.candidateCount ?? 5)))
    }

    override func refresh(_ client: IMKTextInput?) {
        observeQualityVisibility()
        ai.beginRefresh(client: client)
        defer { ai.endRefresh() }
        let deliveringEngine = engine
        deliveringEngine?.beginDelivery()
        defer { deliveringEngine?.endDelivery() }
        associateQualityClient(client)
        let commit = engine?.takeCommit(recordQuality: false) ?? ""
        if !commit.isEmpty {
            ownsMarkedText = false
            qualityInsertionDepth += 1
            defer { qualityInsertionDepth -= 1 }
            client?.insertText(commit, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        if !commit.isEmpty || qualityInsertionDepth == 0 {
            engine?.qualityRecorder?.commitDrained(commit, insertionIssued: !commit.isEmpty && client != nil,
                                                  clientID: client?.uniqueClientIdentifierString())
        }
        IFInputRankingContext.refresh(engine, client: client, ownsMarkedText: ownsMarkedText)
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
        applySettings()
        updating = true
        candidatePresentation?.refreshCandidates(strings, highlight: state.highlight)
        updating = false
        didPresentCandidates()
    }

    // InputMethodKit's legacy callbacks are synchronous and main-thread-bound but lack actor annotations.
    nonisolated override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        nonisolated(unsafe) let callbackEvent = event
        nonisolated(unsafe) let callbackClient = sender
        return MainActor.assumeIsolated {
            guard !ai.isAccepting else { return false }
            let entered = qualityClock.monotonic()
            observeQualityVisibility(at: entered)
            ai.validate()
            if let callbackEvent, callbackEvent.type == .keyDown, callbackEvent.keyCode == 48,
               callbackEvent.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
               ai.acceptSuggestion(callbackEvent, client: callbackClient as? IMKTextInput, entered: entered) { return true }
            if engine == nil, IFEngine.ready {
                engine = IFEngine(qualityStore: injectedQualityStore, qualityClock: qualityClock)
                applySettings()
            }
            guard let engine, engine.available, let callbackEvent, callbackEvent.type == .keyDown else { return false }
            associateQualityClient(callbackClient as? IMKTextInput)
            engine.qualityRecorder?.setTimingCaptureEnabled(!secureInput())
            IFInputRankingContext.prepareForKey(engine, client: callbackClient as? IMKTextInput,
                                                ownsMarkedText: ownsMarkedText)
            let handled = engine.event(callbackEvent, capturedAt: entered)
            if !handled && !engine.snapshot().preedit.isEmpty { engine.commit(capturedAt: entered) }
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
            guard !ai.isAccepting, !updating, let text, let index = strings.firstIndex(of: text) else { return }
            let entered = qualityClock.monotonic()
            associateQualityClient(client())
            observeQualityVisibility(at: entered)
            engine?.select(index, trigger: .panel, ambiguousText: strings.filter { $0 == text }.count > 1,
                           capturedAt: entered)
            refresh(client())
        }
    }

    nonisolated override func candidateSelectionChanged(_ candidate: NSAttributedString!) {
        let text = candidate?.string
        MainActor.assumeIsolated {
            guard !ai.isAccepting, !updating, let text, let index = strings.firstIndex(of: text) else { return }
            observeQualityVisibility()
            engine?.highlight(index)
            refresh(client())
        }
    }

    nonisolated override func commitComposition(_ sender: Any!) {
        nonisolated(unsafe) let callbackClient = sender
        MainActor.assumeIsolated {
            guard !ai.isAccepting else { return }
            let entered = qualityClock.monotonic()
            ai.invalidate(.commit)
            let activeClient = (callbackClient as? IMKTextInput) ?? client()
            associateQualityClient(activeClient)
            observeQualityVisibility(at: entered)
            engine?.commit(capturedAt: entered)
            refresh(activeClient)
            candidatePresentation?.hideCandidates()
            observeQualityVisibility()
        }
    }
}
