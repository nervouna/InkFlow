@preconcurrency import InputMethodKit
import Carbon

/// Audited offline IMK path. AI may consume only plain Tab;
/// presentation callbacks run after the offline state transition and cannot replace it.
@MainActor
@objc(InkFlowInputController)
final class InkFlowInputController: IFInputControllerShell, @unchecked Sendable {
    // IMKCandidates borrows this source. The latest panel can outlive its controller,
    // so retain the single immutable selection layout for the process lifetime.
    private static let selectionKeyLayout: TISInputSource? = {
        let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.US"] as CFDictionary
        return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first
    }()
    private var modeModifierArmed: ShortcutBinding?

    nonisolated override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask(arrayLiteral: .keyDown, .keyUp, .flagsChanged).rawValue)
    }

    nonisolated override func mouseDown(onCharacterIndex index: Int, coordinate point: NSPoint,
                                        withModifier flags: Int,
                                        continueTracking keepTracking: UnsafeMutablePointer<ObjCBool>!,
                                        client sender: Any!) -> Bool {
        keepTracking?.pointee = false
        nonisolated(unsafe) let callbackClient = sender
        let shouldCommit = MainActor.assumeIsolated {
            voice.cancel(.editing)
            modeModifierArmed = nil
            guard !ai.isAccepting, ownsMarkedText, index >= 0, index != NSNotFound,
                  let activeClient = callbackClient as? IMKTextInput else { return false }
            let markedRange = activeClient.markedRange()
            guard markedRange.location >= 0, markedRange.location != NSNotFound, markedRange.length > 0,
                  markedRange.location <= Int.max - markedRange.length else { return false }
            return index < markedRange.location || index >= markedRange.location + markedRange.length
        }
        if shouldCommit { commitComposition(callbackClient) }
        return false
    }

    private func toggleConfiguredMode(client: IMKTextInput?, capturedAt: TimeInterval) {
        if let engine, engine.toggleASCIIMode(capturedAt: capturedAt) {
            let state = engine.snapshot()
            statusPresentation?.present(engine.requestedASCIIMode ? .english : .chinese, client: client,
                                        characterIndex: state.preedit.isEmpty ? 0 : state.cursor)
        }
    }

    private func handleModeShift(_ event: NSEvent, client: IMKTextInput?, capturedAt: TimeInterval) -> Bool {
        let binding = settings.shortcuts.binding(for: .inputMode)
        guard binding.isModifier, event.type == .flagsChanged, event.keyCode == binding.keyCode,
              !event.modifierFlags.contains(.function) else {
            modeModifierArmed = nil
            return false
        }
        if binding.modifierIsDown(event) {
            let alone = event.modifierFlags.intersection(ShortcutBinding.relevantFlags) == binding.flags
            modeModifierArmed = alone ? binding : nil
            return alone
        }
        let shouldToggle = modeModifierArmed == binding && event.modifierFlags.intersection(ShortcutBinding.relevantFlags).isEmpty
        modeModifierArmed = nil
        guard shouldToggle else { return false }
        toggleConfiguredMode(client: client, capturedAt: capturedAt)
        return true
    }

    private func handleControlShortcut(_ event: NSEvent, client: IMKTextInput?, capturedAt: TimeInterval) -> Bool {
        guard let action = [ShortcutAction.inputMode, .punctuation, .script].first(where: {
            settings.shortcuts.binding(for: $0).matches(event)
        }) else { return false }
        if event.isARepeat { return true }
        switch action {
        case .inputMode: toggleConfiguredMode(client: client, capturedAt: capturedAt)
        case .script:
            toggleInputOption(.traditional, enabledStatus: .traditional,
                              disabledStatus: .simplified, client: client)
        case .punctuation:
            toggleInputOption(.englishPunctuation, enabledStatus: .englishPunctuation,
                              disabledStatus: .chinesePunctuation, client: client)
        default: return false
        }
        return true
    }

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
        if let selectionKeyLayout = Self.selectionKeyLayout { panel?.setSelectionKeysKeylayout(selectionKeyLayout) }
        let keys = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        panel?.setSelectionKeys(Array(keys.prefix(engine?.candidateCount ?? 5)))
    }

    override func refresh(_ client: IMKTextInput?) {
        _ = refreshWithInputDiagnostics(client)
    }

    private func refreshWithInputDiagnostics(_ client: IMKTextInput?) -> InputDeliveryDiagnostic {
        var delivery = InputDeliveryDiagnostic(clientPresent: client != nil, commitInsertion: false,
                                               markedTextUpdate: false, markedTextClear: false)
        guard !voice.blocksRime else { return delivery }
        let previousPreeditCount = deliveredPreedit.count
        observeQualityVisibility()
        ai.beginRefresh(client: client)
        defer { ai.endRefresh() }
        let deliveringEngine = engine
        deliveringEngine?.beginDelivery()
        defer { deliveringEngine?.endDelivery() }
        associateQualityClient(client)
        let commit = engine?.takeCommit(recordQuality: false) ?? ""
        if !commit.isEmpty {
            let insertion = inputDiagnostics.insertionBegan(clientPresent: client != nil)
            ownsMarkedText = false
            qualityInsertionDepth += 1
            defer { qualityInsertionDepth -= 1 }
            delivery = InputDeliveryDiagnostic(clientPresent: client != nil, commitInsertion: client != nil,
                                               markedTextUpdate: false, markedTextClear: false)
            client?.insertText(commit, replacementRange: NSRange(location: NSNotFound, length: 0))
            inputDiagnostics.insertionFinished(insertion, clientPresent: client != nil)
        }
        if !commit.isEmpty || qualityInsertionDepth == 0 {
            engine?.qualityRecorder?.commitDrained(commit, insertionIssued: !commit.isEmpty && client != nil,
                                                  clientID: client?.uniqueClientIdentifierString())
        }
        IFInputRankingContext.refresh(engine, client: client, ownsMarkedText: ownsMarkedText)
        let state = engine?.snapshot() ?? EngineSnapshot()
        if !state.preedit.isEmpty {
            inputDiagnostics.beginComposition()
            ownsMarkedText = true
            delivery = InputDeliveryDiagnostic(clientPresent: client != nil,
                                               commitInsertion: delivery.commitInsertion,
                                               markedTextUpdate: client != nil, markedTextClear: false)
            client?.setMarkedText(state.preedit, selectionRange: NSRange(location: state.cursor, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        } else if ownsMarkedText {
            inputDiagnostics.endComposition(.cleared)
            ownsMarkedText = false
            delivery = InputDeliveryDiagnostic(clientPresent: client != nil,
                                               commitInsertion: delivery.commitInsertion,
                                               markedTextUpdate: false, markedTextClear: client != nil)
            client?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        if settings.thunderMode {
            if !commit.isEmpty {
                thunderPresentation?.burst(.commit, client: client, characterIndex: 0)
            } else if state.preedit.count > previousPreeditCount {
                thunderPresentation?.burst(.preedit, client: client, characterIndex: max(state.cursor - 1, 0))
            }
        }
        deliveredPreedit = state.preedit
        strings = state.candidates
        applySettings()
        updating = true
        candidatePresentation?.refreshCandidates(strings, highlight: state.highlight)
        updating = false
        didPresentCandidates()
        return delivery
    }

    // InputMethodKit's legacy callbacks are synchronous and main-thread-bound but lack actor annotations.
    nonisolated override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        nonisolated(unsafe) let callbackEvent = event
        nonisolated(unsafe) let callbackClient = sender
        return MainActor.assumeIsolated {
            let firstKey = callbackEvent?.type == .keyDown ? inputDiagnostics.beginFirstKey() : nil
            @MainActor func finishFirstKey(_ handled: Bool, _ reason: InputDiagnosticReason,
                                           delivery: InputDeliveryDiagnostic? = nil) -> Bool {
                inputDiagnostics.finishFirstKey(firstKey, outcome: handled ? .handled : .passThrough,
                                                reason: reason, delivery: delivery)
                return handled
            }
            if let event = callbackEvent, event.type == .flagsChanged {
                VoiceDiagnostics.modifierArrival(keyCode: event.keyCode, flags: event.modifierFlags.rawValue)
            }
            if voice.isDelivering {
                let handled = callbackEvent.map { voice.handle($0, client: callbackClient as? IMKTextInput) } ?? false
                return finishFirstKey(handled, handled ? .voiceDeliveringHandled : .voiceDeliveringPassThrough)
            }
            guard !ai.isAccepting else {
                modeModifierArmed = nil
                return finishFirstKey(false, .aiAccepting)
            }
            if let callbackEvent, voice.handle(callbackEvent, client: callbackClient as? IMKTextInput) {
                modeModifierArmed = nil
                return finishFirstKey(true, .voiceHandled)
            }
            let entered = qualityClock.monotonic()
            if let callbackEvent, callbackEvent.type == .flagsChanged {
                associateQualityClient(callbackClient as? IMKTextInput)
                engine?.qualityRecorder?.setTimingCaptureEnabled(!secureInput())
                return handleModeShift(callbackEvent, client: callbackClient as? IMKTextInput, capturedAt: entered)
            }
            modeModifierArmed = nil
            observeQualityVisibility(at: entered)
            ai.validate()
            if let callbackEvent, handleControlShortcut(callbackEvent, client: callbackClient as? IMKTextInput, capturedAt: entered) {
                return finishFirstKey(true, .controlShortcut)
            }
            if let callbackEvent, callbackEvent.type == .keyDown, callbackEvent.keyCode == 48, callbackEvent.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
               ai.acceptSuggestion(callbackEvent, client: callbackClient as? IMKTextInput, entered: entered) {
                return finishFirstKey(true, .aiSuggestionAccepted)
            }
            if engine == nil, IFEngine.ready {
                engine = IFEngine(qualityStore: injectedQualityStore, qualityClock: qualityClock)
                applySettings()
            }
            guard let engine else {
                inputDiagnostics.engineAvailability(false, reason: .engineMissing)
                inputDiagnostics.finishFirstKey(firstKey, outcome: .skipped, reason: .engineMissing)
                return false
            }
            guard engine.available else {
                inputDiagnostics.engineAvailability(false)
                inputDiagnostics.finishFirstKey(firstKey, outcome: .skipped, reason: .engineUnavailable)
                return false
            }
            guard let callbackEvent, callbackEvent.type == .keyDown else { return false }
            inputDiagnostics.checkpointFirstKey(firstKey, stage: .routing)
            inputDiagnostics.engineAvailability(true)
            associateQualityClient(callbackClient as? IMKTextInput)
            engine.qualityRecorder?.setTimingCaptureEnabled(!secureInput())
            IFInputRankingContext.prepareForKey(engine, client: callbackClient as? IMKTextInput,
                                                ownsMarkedText: ownsMarkedText)
            inputDiagnostics.checkpointFirstKey(firstKey, stage: .context)
            let handled = engine.event(callbackEvent, capturedAt: entered)
            inputDiagnostics.checkpointFirstKey(firstKey, stage: .rime)
            if !handled && !engine.snapshot().preedit.isEmpty { engine.commit(capturedAt: entered) }
            inputDiagnostics.checkpointFirstKey(firstKey, stage: .commit)
            let delivery = refreshWithInputDiagnostics(callbackClient as? IMKTextInput)
            inputDiagnostics.checkpointFirstKey(firstKey, stage: .refresh)
            return finishFirstKey(handled, .rime, delivery: delivery)
        }
    }

    nonisolated override func deactivateServer(_ sender: Any!) {
        MainActor.assumeIsolated { modeModifierArmed = nil }
        super.deactivateServer(sender)
    }

    nonisolated override func candidates(_ sender: Any!) -> [Any]! {
        MainActor.assumeIsolated { strings }
    }

    nonisolated override func candidateSelected(_ candidate: NSAttributedString!) {
        let text = candidate?.string
        MainActor.assumeIsolated {
            guard !voice.blocksRime, !ai.isAccepting, !updating, let text, let index = strings.firstIndex(of: text) else { return }
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
            guard !voice.blocksRime, !ai.isAccepting, !updating, let text, let index = strings.firstIndex(of: text) else { return }
            observeQualityVisibility()
            engine?.highlight(index)
            refresh(client())
        }
    }

    nonisolated override func commitComposition(_ sender: Any!) {
        nonisolated(unsafe) let callbackClient = sender
        MainActor.assumeIsolated {
            if voice.blocksRime {
                voice.clientRequestedCommit(callbackClient as? IMKTextInput)
                return
            }
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
