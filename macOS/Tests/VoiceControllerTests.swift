@testable import InkFlowRime
@testable import InkFlowDomain
import InputMethodKit
#if SWIFT_PACKAGE
@testable import InkFlowCore
import InkFlowNativeTestSupport
import InkFlowTestSupport
#endif

@MainActor
private final class FakeVoice: VoiceRecognitionServing {
    var isReady = true
    var prepares = 0, starts = 0, stops = 0, cancels = 0
    var id: UUID?
    var snapshot: VoiceLexiconSnapshot?
    var callbacks: AppleVoiceRecognizer.Callbacks?
    var onCancel: (() -> Void)?
    func prepare(requestPermission: Bool) async throws { prepares += 1; isReady = true }
    func start(id: UUID, snapshot: VoiceLexiconSnapshot, callbacks: AppleVoiceRecognizer.Callbacks) {
        self.id = id; self.snapshot = snapshot; self.callbacks = callbacks; starts += 1
    }
    func stop(id: UUID) { if self.id == id { stops += 1 } }
    func cancel() { if id != nil { cancels += 1 }; id = nil; callbacks = nil; onCancel?() }
}

@MainActor
private final class VoiceStatus: InputStatusPresenting {
    var values: [InputStatus] = []
    var visible: InputStatus?
    func present(_ status: InputStatus, client: IMKTextInput?, characterIndex: Int) {
        values.append(status)
        visible = status
    }
    func hide() { visible = nil }
}

@MainActor
private final class VoiceHarness {
    let isolated = IsolatedSettings()
    let fake = FakeVoice()
    let client = RecordingClient(document: "前🙂")
    let status = VoiceStatus()
    let settings: IFSettings
    let controller: InkFlowInputController
    var focused: IMKTextInput?
    var app = VoiceForeground(bundleID: "inkflow.recording-client", pid: 77)
    var secure = false
    var now: TimeInterval = 1
    var timer: (@MainActor () -> Void)?
    init(voiceService: (any VoiceRecognitionServing)? = nil) {
        settings = IFSettings(defaults: isolated.defaults, voiceService: voiceService ?? fake)
        client.allowsExplicitMarkedReplacement = true
        client.caretRect = NSRect(x: 100, y: 200, width: 1, height: 20)
        focused = client
        controller = InkFlowInputController(server: nil, delegate: nil, client: client, settings: settings,
            settingsWindow: IFSettingsWindowController(settings: settings), statusPresentation: status)
        controller.voice.currentClient = { [weak self] in self?.focused }
        controller.voice.foreground = { [weak self] in self?.app }
        controller.voice.lexicon = { .init(generation: 1, revision: 1, availability: .available, entries: []) }
        controller.voice.gestureTime = { [weak self] in self?.now ?? 0 }
        controller.voice.scheduleHold = { [weak self] fire in
            self?.timer = fire
            return { [weak self] in self?.timer = nil }
        }
        controller.secureInput = { [weak self] in self?.secure ?? true }
    }
    func close() { controller.voice.cancel(); isolated.cleanup() }
    @discardableResult func rightShift(_ down: Bool) -> Bool {
        controller.handle(modifierEvent(60, down ? .shift : []), client: focused)
    }
    func tap() { check(rightShift(true)); now += 0.05; check(rightShift(false)); now += 0.05 }
    func toggle() { tap(); tap() }
    func hold() { check(rightShift(true)); now += 0.25; timer?() }
    func key(_ code: UInt16 = 9, _ flags: NSEvent.ModifierFlags = [.control, .option], repeat repeated: Bool = false) {
        if code == 9 && flags == [.control, .option] { toggle() }
        else if code == 15 && flags == [.control, .option] { hold() }
        else { check(controller.handle(keyEvent(code, "", flags, repeated: repeated), client: focused)) }
    }
    func start() async {
        key()
        // Poll instead of a fixed wait so a loaded machine doesn't fail the start.
        for _ in 0..<100 where fake.starts == 0 { try? await Task.sleep(for: .milliseconds(20)) }
        check(controller.voice.isActive && fake.starts == 1)
    }
}

@main
struct VoiceControllerTests {
    @MainActor static func main() async throws {
        try IFEngine.start(shared: CommandLine.arguments[1], user: CommandLine.arguments[2])
        defer { IFEngine.stop() }
        IFStubHeadlessControllerFramework()
        let gesture = VoiceHarness()
        for _ in 0..<2 {
            _ = gesture.controller.handle(modifierEvent(60, .shift), client: gesture.client)
            _ = gesture.controller.handle(modifierEvent(60), client: gesture.client)
        }
        check(gesture.controller.voice.isActive, "Right Shift double tap starts continuous voice")
        gesture.close()
        await fixtureBypassesCorrection()
        await unstableClientIdentifier()
        await inputMethodKitAbsentMark()
        await earlyRelease()
        await recordedVoiceChords()
        await recordedVoiceChordCancellation()
        await holdChordRelease()
        await stopDuringPreviewDelivery()
        await activationBeforeDeactivation()
        await activationDuringInitialCapture()
        try await applicationPolishRouting()
        await deliveryAndFallback()
        await cancellationAndIdentity()
        await reentrancy()
        await externalClientCommit()
        await synchronousDeactivation()
        await gatesAndSettings()
        await unknownLexiconFallback()
        await unknownLexiconInvalidation()
        await unknownLexiconQueuedCancellation()
        await selectedTextDelivery()
        await selectedTextRollback()
        await reportedSelectionMismatch()
        await selectedTextEscapeCancellation()
        await secureMarkedTextGuard()
        await secureSelectedRangeStart()
        await preeditClearRecovery()
        await selectedTextTargetLoss()
        await startRejectionDiagnostics()
        await correctingCancellation()
        postInsertionCorrectionObservation()
        evidencePrecheckAfterSecureCallback()
        await postInsertionControllerLearning()
        await learningCallbackReentrancy()
        await initialObservationCaptureReentrancy()
        await editAttributionPrecheckReentrancy()
        await editAttributionReentrancy()
        await postInsertionPersistenceReentrancy()
        await detectedCorrectionImmediateUndo()
        print("PASS voice controller: selected-text transactions, post-insertion learning, hold/toggle, UTF16 marks, exact-once fallback, target ownership, reentrancy and independent settings")
    }

    @MainActor static func postInsertionCorrectionObservation() {
        let client = RecordingClient(document: "前：codux，后")
        let inserted = NSRange(location: 2, length: 5)
        client.selection = NSRange(location: NSMaxRange(inserted), length: 0)
        var observation = VoiceCorrectionObservation.capture(
            operationID: UUID(), client: client, sessionRevision: 7,
            insertionRange: inserted, rawFinal: "codux", insertedFinal: "codux")
        check(observation != nil, "A verified bounded insertion must create an observation")
        check(observation!.attributeLocalEdit(selection: inserted),
              "An exact selection inside the inserted range is attributable")
        client.document = "前：Codex，后"
        client.selection = NSRange(location: 7, length: 0)
        check(observation!.observe(client: client, sessionRevision: 7, secure: false) ==
              .learn(.init(sourceCode: "codux", canonicalText: "Codex")),
              "A bounded exact Latin token substitution must be observable")
        check(client.requests.last == NSRange(location: 2, length: 5),
              "Observation reads only the bounded inserted region")

        let outside = RecordingClient(document: "codux other")
        outside.selection = NSRange(location: 5, length: 0)
        var rejected = VoiceCorrectionObservation.capture(
            operationID: UUID(), client: outside, sessionRevision: 9,
            insertionRange: NSRange(location: 0, length: 5), rawFinal: "codux", insertedFinal: "codux")!
        check(!rejected.attributeLocalEdit(selection: NSRange(location: 6, length: 5)),
              "An edit outside the inserted range is not attributable")

        func decision(contextAvailable: Bool = true, adjusted: Bool = false,
                      secure: Bool = false, revision: UInt64 = 11,
                      clientOverride: RecordingClient? = nil) -> VoiceCorrectionObservation.Decision {
            let original = RecordingClient(document: "codux")
            original.selection = NSRange(location: 5, length: 0)
            var value = VoiceCorrectionObservation.capture(
                operationID: UUID(), client: original, sessionRevision: 11,
                insertionRange: NSRange(location: 0, length: 5), rawFinal: "codux", insertedFinal: "codux")!
            check(value.attributeLocalEdit(selection: NSRange(location: 0, length: 5)))
            let observed = clientOverride ?? original
            observed.document = "Codex"; observed.selection = NSRange(location: 5, length: 0)
            observed.contextAvailable = contextAvailable
            if adjusted { observed.substringResponse = { _ in ("Codex", NSRange(location: 0, length: 4)) } }
            return value.observe(client: observed, sessionRevision: revision, secure: secure)
        }
        check(decision(contextAvailable: false) == .discard, "Unreadable clients fail closed")
        check(decision(adjusted: true) == .discard, "Adjusted ranges fail closed")
        check(decision(secure: true) == .discard, "Secure input fails closed")
        check(decision(revision: 12) == .discard, "Session revision drift fails closed")
        check(decision(clientOverride: RecordingClient(document: "Codex")) == .discard,
              "Client identity drift fails closed")

        let polished = RecordingClient(document: "Codex")
        polished.selection = NSRange(location: 5, length: 0)
        var noAutomaticLearning = VoiceCorrectionObservation.capture(
            operationID: UUID(), client: polished, sessionRevision: 13,
            insertionRange: NSRange(location: 0, length: 5), rawFinal: "codux", insertedFinal: "Codex")!
        check(noAutomaticLearning.attributeLocalEdit(selection: NSRange(location: 0, length: 5)))
        polished.document = "CODEX"; polished.selection = NSRange(location: 5, length: 0)
        check(noAutomaticLearning.observe(client: polished, sessionRevision: 13, secure: false) == .discard,
              "Automatic polish alone cannot become learning evidence")

        let expired = RecordingClient(document: "codux")
        expired.selection = NSRange(location: 5, length: 0)
        let now = ContinuousClock.now
        var timeout = VoiceCorrectionObservation.capture(
            operationID: UUID(), client: expired, sessionRevision: 14,
            insertionRange: NSRange(location: 0, length: 5), rawFinal: "codux", insertedFinal: "codux", now: now)!
        check(timeout.attributeLocalEdit(selection: NSRange(location: 0, length: 5)))
        expired.document = "Codex"
        check(timeout.observe(client: expired, sessionRevision: 14, secure: false,
                              now: now.advanced(by: .seconds(9))) == .discard,
              "Expired observations fail closed")

        let sentence = RecordingClient(document: "use codux, now")
        sentence.selection = NSRange(location: 14, length: 0)
        var oneToken = VoiceCorrectionObservation.capture(
            operationID: UUID(), client: sentence, sessionRevision: 15,
            insertionRange: NSRange(location: 0, length: 14),
            rawFinal: "use codux, now", insertedFinal: "use codux, now")!
        check(oneToken.attributeLocalEdit(selection: NSRange(location: 4, length: 5)))
        sentence.document = "use Codex, now"; sentence.selection = NSRange(location: 9, length: 0)
        check(oneToken.observe(client: sentence, sessionRevision: 15, secure: false) ==
              .learn(.init(sourceCode: "codux", canonicalText: "Codex")),
              "One corrected Latin token preserves surrounding words and punctuation")
        sentence.selection = NSRange(location: 13, length: 0)
        check(oneToken.observe(client: sentence, sessionRevision: 15, secure: false) == .discard,
              "Selection drift to a different token fails closed")

        let ambiguous = RecordingClient(document: "use codux, now")
        ambiguous.selection = NSRange(location: 14, length: 0)
        var twoTokens = VoiceCorrectionObservation.capture(
            operationID: UUID(), client: ambiguous, sessionRevision: 16,
            insertionRange: NSRange(location: 0, length: 14),
            rawFinal: "use codux, now", insertedFinal: "use codux, now")!
        check(twoTokens.attributeLocalEdit(selection: NSRange(location: 4, length: 5)))
        ambiguous.document = "Use Codex, now"; ambiguous.selection = NSRange(location: 9, length: 0)
        check(twoTokens.observe(client: ambiguous, sessionRevision: 16, secure: false) == .discard,
              "Two changed tokens are ambiguous and fail closed")

        let appended = RecordingClient(document: "codux")
        appended.selection = NSRange(location: 5, length: 0)
        var appendedObservation = VoiceCorrectionObservation.capture(
            operationID: UUID(), client: appended, sessionRevision: 17,
            insertionRange: NSRange(location: 0, length: 5), rawFinal: "codux", insertedFinal: "codux")!
        check(appendedObservation.attributeLocalEdit(selection: NSRange(location: 5, length: 0)),
              "A direct edit at the final Latin token boundary remains attributable")
        appended.document = "coduxe"; appended.selection = NSRange(location: 6, length: 0)
        check(appendedObservation.observe(client: appended, sessionRevision: 17, secure: false) ==
              .learn(.init(sourceCode: "codux", canonicalText: "coduxe")),
              "A bounded suffix appended at the original token end is learned")

        let elongated = RecordingClient(document: "codux")
        elongated.selection = NSRange(location: 5, length: 0)
        var elongatedObservation = VoiceCorrectionObservation.capture(
            operationID: UUID(), client: elongated, sessionRevision: 18,
            insertionRange: NSRange(location: 0, length: 5), rawFinal: "codux", insertedFinal: "codux")!
        check(elongatedObservation.attributeLocalEdit(selection: NSRange(location: 5, length: 0)))
        elongated.document = "coduxp"; elongated.selection = NSRange(location: 6, length: 0)
        check(elongatedObservation.attributeLocalEdit(selection: NSRange(location: 6, length: 0)),
              "Successive direct keys may extend only the attributed final token")
        elongated.document = "coduxpro"; elongated.selection = NSRange(location: 8, length: 0)
        check(elongatedObservation.attributeLocalEdit(selection: NSRange(location: 8, length: 0)))
        check(elongatedObservation.observe(client: elongated, sessionRevision: 18, secure: false) ==
              .learn(.init(sourceCode: "codux", canonicalText: "coduxpro")),
              "A multi-key bounded final-token extension learns once")

        let crossed = RecordingClient(document: "codux")
        crossed.selection = NSRange(location: 5, length: 0)
        var crossedObservation = VoiceCorrectionObservation.capture(
            operationID: UUID(), client: crossed, sessionRevision: 19,
            insertionRange: NSRange(location: 0, length: 5), rawFinal: "codux", insertedFinal: "codux")!
        check(crossedObservation.attributeLocalEdit(selection: NSRange(location: 5, length: 0)))
        crossed.document = "codux pro"; crossed.selection = NSRange(location: 9, length: 0)
        check(crossedObservation.observe(client: crossed, sessionRevision: 19, secure: false) == .discard,
              "Extending across a token boundary is never learning evidence")

        let targetChanged = RecordingClient(document: "codux")
        targetChanged.selection = NSRange(location: 5, length: 0)
        var targetObservation = VoiceCorrectionObservation.capture(
            operationID: UUID(), client: targetChanged, sessionRevision: 20,
            insertionRange: NSRange(location: 0, length: 5), rawFinal: "codux", insertedFinal: "codux")!
        check(targetObservation.attributeLocalEdit(selection: NSRange(location: 0, length: 5)))
        targetChanged.testClientID = "another-editing-target"
        targetChanged.document = "Codex"; targetChanged.selection = NSRange(location: 5, length: 0)
        check(targetObservation.observe(client: targetChanged, sessionRevision: 20, secure: false) == .discard,
              "A changed native client identifier fails closed even when the proxy object is reused")
    }

    @MainActor static func postInsertionControllerLearning() async {
        func finish(_ h: VoiceHarness, raw: String) async {
            await h.start()
            let callbacks = h.fake.callbacks!
            callbacks.onFinal(raw)
            h.key()
            callbacks.onFinalized(raw)
            for _ in 0..<10 { await Task.yield() }
        }

        do {
            let h = VoiceHarness(); defer { h.close() }
            h.controller.voice.aliasLexicon = { .init(generation: 1, revision: 1, availability: .available, entries: []) }
            h.controller.voice.learningObservationDelay = .zero
            h.controller.voice.learningUndoGrace = .zero
            var learned: [VoiceLearnedCorrection] = []
            var events: [QualityEffectivenessEvent] = []
            h.controller.voice.learnCorrection = { learned.append($0); return true }
            h.controller.voice.recordEffectiveness = { events.append($0) }
            await finish(h, raw: "codux")
            check(h.client.document == "前🙂codux" && h.client.insertions.count == 1,
                  "Raw finalized voice text inserts exactly once before observation")
            let token = NSRange(location: 3, length: 5)
            h.client.selection = token
            check(!h.controller.handle(keyEvent(UInt16(kVK_ANSI_V), "v", .command), client: h.client),
                  "The observed paste remains a host application edit")
            h.client.document = "前🙂Codex"
            h.client.selection = NSRange(location: 8, length: 0)
            for _ in 0..<10 { await Task.yield() }
            check(learned == [.init(sourceCode: "codux", canonicalText: "Codex")],
                  "One attributable local Latin substitution learns once off the key event")
            check(events.contains { $0.source == .voiceSession && $0.event == .finalized } &&
                  events.contains { $0.source == .voiceCorrection && $0.event == .detected } &&
                  events.contains { $0.source == .voiceCorrection && $0.event == .learned },
                  "Finalization, detection and successful learning emit content-free evidence")
            check(h.client.insertions.count == 1, "Learning never inserts a second copy")
        }

        do {
            let h = VoiceHarness(); defer { h.close() }
            h.controller.voice.aliasLexicon = {
                .init(generation: 1, revision: 1, availability: .available,
                      entries: [.init(code: "codux", text: "Codex", commits: 1)])
            }
            var events: [QualityEffectivenessEvent] = []
            h.controller.voice.recordEffectiveness = { events.append($0) }
            await finish(h, raw: "用 codux。")
            check(h.client.document == "前🙂用 Codex。" && h.client.insertions.count == 1,
                  "Exact token-boundary voice aliases apply before insertion without duplication")
            check(events.contains { $0.source == .voiceAlias && $0.event == .hit && $0.count == 1 } &&
                  events.contains { $0.source == .voiceAlias && $0.event == .laterReuse && $0.count == 1 },
                  "Alias application emits numeric hit and later-reuse evidence without token content")
        }

        do {
            let h = VoiceHarness(); defer { h.close() }
            h.settings.voicePolishEnabled = true
            h.controller.voice.aliasLexicon = {
                .init(generation: 1, revision: 1, availability: .available,
                      entries: [.init(code: "codux", text: "Codex", commits: 1)])
            }
            h.controller.voice.correctionOverride = { text, _ in
                try await Task.sleep(for: .seconds(1))
                return text
            }
            var events: [QualityEffectivenessEvent] = []
            h.controller.voice.recordEffectiveness = { events.append($0) }
            await h.start()
            let callbacks = h.fake.callbacks!
            callbacks.onFinal("用 codux。")
            h.key()
            callbacks.onFinalized("用 codux。")
            for _ in 0..<10 { await Task.yield() }
            h.controller.voice.cancel(.cancellation)
            check(h.client.insertions.isEmpty &&
                  events.contains { $0.source == .voiceAlias && $0.event == .hit } &&
                  !events.contains { $0.source == .voiceAlias && $0.event == .laterReuse },
                  "A matched alias cancelled before insertion is a hit but not later reuse")
        }

        do {
            let h = VoiceHarness(); defer { h.close() }
            h.settings.voicePolishEnabled = true
            h.controller.voice.aliasLexicon = {
                .init(generation: 1, revision: 1, availability: .available,
                      entries: [.init(code: "codux", text: "Codex", commits: 1)])
            }
            h.controller.voice.correctionOverride = { _, _ in "用产品。" }
            var events: [QualityEffectivenessEvent] = []
            h.controller.voice.recordEffectiveness = { events.append($0) }
            await finish(h, raw: "用 codux。")
            check(h.client.document == "前🙂用产品。" &&
                  events.contains { $0.source == .voiceAlias && $0.event == .hit } &&
                  !events.contains { $0.source == .voiceAlias && $0.event == .laterReuse },
                  "AI polish that removes the alias cannot count as later reuse")
        }

        for interruption in ["undo", "deactivate", "focus", "ordinary"] {
            let h = VoiceHarness(); defer { h.close() }
            h.controller.voice.aliasLexicon = { .init(generation: 1, revision: 1, availability: .available, entries: []) }
            h.controller.voice.learningObservationDelay = .zero
            var learned: [VoiceLearnedCorrection] = []
            h.controller.voice.learnCorrection = { learned.append($0); return true }
            await finish(h, raw: "codux")
            switch interruption {
            case "undo":
                check(!h.controller.handle(keyEvent(UInt16(kVK_ANSI_Z), "z", .command), client: h.client))
            case "deactivate":
                h.client.selection = NSRange(location: 3, length: 5)
                _ = h.controller.handle(keyEvent(UInt16(kVK_ANSI_V), "v", .command), client: h.client)
                h.controller.deactivateServer(h.client)
                h.client.document = "前🙂Codex"; h.client.selection = NSRange(location: 8, length: 0)
            case "focus":
                h.client.selection = NSRange(location: 3, length: 5)
                _ = h.controller.handle(keyEvent(UInt16(kVK_ANSI_V), "v", .command), client: h.client)
                h.focused = RecordingClient(document: "another target")
                h.client.document = "前🙂Codex"; h.client.selection = NSRange(location: 8, length: 0)
            default:
                h.client.selection = NSRange(location: 8, length: 0)
                _ = h.controller.handle(keyEvent(0, "x"), client: h.client)
                h.client.document = "前🙂coduxx"; h.client.selection = NSRange(location: 9, length: 0)
            }
            for _ in 0..<10 { await Task.yield() }
            check(learned.isEmpty, "\(interruption) discards voice learning evidence")
        }
    }

    @MainActor static func evidencePrecheckAfterSecureCallback() {
        let client = RecordingClient(document: "codux")
        client.selection = NSRange(location: 5, length: 0)
        var observation = VoiceCorrectionObservation.capture(operationID: UUID(), client: client,
            sessionRevision: 1, insertionRange: NSRange(location: 0, length: 5),
            rawFinal: "codux", insertedFinal: "codux")!
        check(observation.attributeLocalEdit(selection: NSRange(location: 0, length: 5)))
        var current = true
        func secureFact() -> Bool { current = false; return false }
        let reads = client.uniqueIdentifierReads
        let evidence = observation.readEvidence(client: client, sessionRevision: 1, secure: secureFact(),
                                                 validateTarget: { current })
        check(evidence == nil && client.uniqueIdentifierReads == reads,
              "A reentrant security callback revokes evidence before the first native getter")
    }

    @MainActor static func learningCallbackReentrancy() async {
        for callback in ["detected", "writer", "rejected"] {
            let h = VoiceHarness(); defer { h.close() }
            h.controller.voice.learningObservationDelay = .zero
            h.controller.voice.learningUndoGrace = callback == "rejected" ? .seconds(1) : .zero
            var writes = 0
            var restarted = false
            h.controller.voice.learnCorrection = { _ in
                writes += 1
                check(!h.controller.voice.hasLearningObservation && !h.controller.voice.hasPendingCorrection,
                      "Shared state is consumed before a reentrant writer")
                h.controller.voice.cancel()
                return false
            }
            h.controller.voice.recordEffectiveness = { event in
                if callback == "detected", event.source == .voiceCorrection, event.event == .detected {
                    h.controller.voice.cancel()
                }
                if callback == "rejected", !restarted, event.source == .voiceCorrection, event.event == .rejected {
                    restarted = true
                    h.toggle()
                }
            }
            await h.start()
            let callbacks = h.fake.callbacks!
            callbacks.onFinal("codux"); h.key(); callbacks.onFinalized("codux")
            for _ in 0..<10 { await Task.yield() }
            h.client.selection = NSRange(location: 3, length: 5)
            _ = h.controller.handle(keyEvent(UInt16(kVK_ANSI_V), "v", .command), client: h.client)
            h.client.document = "前🙂Codex"; h.client.selection = NSRange(location: 8, length: 0)
            for _ in 0..<30 { await Task.yield() }
            if callback == "rejected" {
                check(h.controller.voice.hasPendingCorrection)
                h.controller.voice.cancel()
                for _ in 0..<30 { await Task.yield() }
                check(restarted && h.controller.voice.isActive && h.fake.starts == 2,
                      "Rejection telemetry may start a new session without stale cancellation after it")
            }
            check(writes == (callback == "writer" ? 1 : 0),
                  "\(callback) reentrancy cannot schedule a stale write or retry failure")
            check(!h.controller.voice.hasLearningObservation && !h.controller.voice.hasPendingCorrection)
            check(h.client.insertions.count == 1, "Learning callbacks never insert text")
        }
    }

    @MainActor static func detectedCorrectionImmediateUndo() async {
        let h = VoiceHarness(); defer { h.close() }
        h.controller.voice.aliasLexicon = { .init(generation: 1, revision: 1, availability: .available, entries: []) }
        h.controller.voice.learningObservationDelay = .milliseconds(350)
        var learned: [VoiceLearnedCorrection] = []
        var events: [QualityEffectivenessEvent] = []
        h.controller.voice.learnCorrection = { learned.append($0); return true }
        h.controller.voice.recordEffectiveness = { events.append($0) }
        await h.start()
        let callbacks = h.fake.callbacks!
        callbacks.onFinal("codux")
        h.key()
        callbacks.onFinalized("codux")
        for _ in 0..<10 { await Task.yield() }
        h.client.selection = NSRange(location: 3, length: 5)
        _ = h.controller.handle(keyEvent(UInt16(kVK_ANSI_V), "v", .command), client: h.client)
        h.client.document = "前🙂Codex"; h.client.selection = NSRange(location: 8, length: 0)
        try? await Task.sleep(for: .milliseconds(420))
        check(h.client.requests.count >= 2, "The production-like delayed bounded readback must occur")
        check(h.controller.voice.hasPendingCorrection, "The exact correction must be detected before undo")
        check(learned.isEmpty, "A detected correction must remain pending during the immediate undo window")
        _ = h.controller.handle(keyEvent(UInt16(kVK_ANSI_Z), "z", .command), client: h.client)
        check(!h.controller.voice.hasPendingCorrection, "Command-Z discards the detected correction immediately")
        try? await Task.sleep(for: .milliseconds(1100))
        check(learned.isEmpty, "Command-Z after detection must prevent both Rime namespace updates")
        check(events.contains { $0.source == .voiceCorrection && $0.event == .detected } &&
              events.contains { $0.source == .voiceCorrection && $0.event == .rejected && $0.reason == .immediateUndo } &&
              !events.contains { $0.event == .learned },
              "Immediate undo records a bounded rejection reason and never a learned event")
    }

    @MainActor static func postInsertionPersistenceReentrancy() async {
        for transition in ["secure-mark", "focus-selection"] {
            let h = VoiceHarness(); defer { h.close() }
            h.controller.voice.aliasLexicon = {
                .init(generation: 1, revision: 1, availability: .available, entries: [])
            }
            h.controller.voice.learningObservationDelay = .zero
            h.controller.voice.learningUndoGrace = .milliseconds(50)
            var learned: [VoiceLearnedCorrection] = []
            var events: [QualityEffectivenessEvent] = []
            h.controller.voice.learnCorrection = { learned.append($0); return true }
            h.controller.voice.recordEffectiveness = { events.append($0) }

            await h.start()
            let callbacks = h.fake.callbacks!
            callbacks.onFinal("codux")
            h.key()
            callbacks.onFinalized("codux")
            for _ in 0..<10 { await Task.yield() }
            h.client.selection = NSRange(location: 3, length: 5)
            _ = h.controller.handle(keyEvent(UInt16(kVK_ANSI_V), "v", .command), client: h.client)
            h.client.document = "前🙂Codex"; h.client.selection = NSRange(location: 8, length: 0)
            for _ in 0..<20 where !h.controller.voice.hasPendingCorrection { await Task.yield() }
            check(h.controller.voice.hasPendingCorrection,
                  "The exact correction is pending before persistence revalidation")

            var readsAtTransition: (selected: Int, length: Int, strings: Int)?
            if transition == "secure-mark" {
                h.client.onMarkedRange = {
                    h.client.onMarkedRange = nil
                    readsAtTransition = (h.client.selectedRangeReads, h.client.lengthReads, h.client.requests.count)
                    h.secure = true
                }
            } else {
                h.client.onSelectedRange = {
                    h.client.onSelectedRange = nil
                    readsAtTransition = (h.client.selectedRangeReads, h.client.lengthReads, h.client.requests.count)
                    h.focused = RecordingClient(document: "another target")
                }
            }
            try? await Task.sleep(for: .milliseconds(100))

            check(learned.isEmpty && !events.contains { $0.source == .voiceCorrection && $0.event == .learned },
                  "A \(transition) transition during persistence readback must not learn")
            check(readsAtTransition != nil && h.client.lengthReads == readsAtTransition?.length &&
                  h.client.requests.count == readsAtTransition?.strings,
                  "No document-content read follows a \(transition) transition")
        }
    }

    @MainActor static func initialObservationCaptureReentrancy() async {
        for transition in ["secure-identifier", "focus-selection", "secure-length"] {
            let h = VoiceHarness(); defer { h.close() }
            h.controller.voice.aliasLexicon = {
                .init(generation: 1, revision: 1, availability: .available, entries: [])
            }
            var learned: [VoiceLearnedCorrection] = []
            h.controller.voice.learnCorrection = { learned.append($0); return true }
            var readsAtTransition: (selected: Int, length: Int, strings: Int)?
            h.client.insertionCallback = {
                if transition == "secure-identifier" {
                    h.client.testIdentifierProvider = {
                        h.client.testIdentifierProvider = nil
                        readsAtTransition = (h.client.selectedRangeReads, h.client.lengthReads, h.client.requests.count)
                        h.secure = true
                        return h.client.testClientID
                    }
                } else if transition == "focus-selection" {
                    h.client.onSelectedRange = {
                        h.client.onSelectedRange = nil
                        readsAtTransition = (h.client.selectedRangeReads, h.client.lengthReads, h.client.requests.count)
                        h.focused = RecordingClient(document: "another target")
                    }
                } else {
                    h.client.onLength = {
                        h.client.onLength = nil
                        readsAtTransition = (h.client.selectedRangeReads, h.client.lengthReads, h.client.requests.count)
                        h.secure = true
                    }
                }
            }

            await h.start()
            let callbacks = h.fake.callbacks!
            callbacks.onFinal("codux")
            h.key()
            callbacks.onFinalized("codux")
            for _ in 0..<10 { await Task.yield() }

            check(readsAtTransition != nil && !h.controller.voice.hasLearningObservation && learned.isEmpty,
                  "A \(transition) transition during initial capture leaves no learning observation")
            check(h.client.lengthReads == readsAtTransition?.length &&
                  h.client.requests.count == readsAtTransition?.strings,
                  "No document-content read follows a \(transition) transition during initial capture")
        }
    }

    @MainActor static func editAttributionReentrancy() async {
        for transition in ["secure-selection", "focus-selection"] {
            let h = VoiceHarness(); defer { h.close() }
            h.controller.voice.aliasLexicon = {
                .init(generation: 1, revision: 1, availability: .available, entries: [])
            }
            var learned: [VoiceLearnedCorrection] = []
            h.controller.voice.learnCorrection = { learned.append($0); return true }
            await h.start()
            let callbacks = h.fake.callbacks!
            callbacks.onFinal("codux")
            h.key()
            callbacks.onFinalized("codux")
            for _ in 0..<10 { await Task.yield() }
            check(h.controller.voice.hasLearningObservation,
                  "Ordinary insertion creates an observation before edit attribution")

            h.client.selection = NSRange(location: 3, length: 5)
            let stringsBefore = h.client.requests.count
            h.client.onSelectedRange = {
                h.client.onSelectedRange = nil
                if transition == "secure-selection" { h.secure = true }
                else { h.focused = RecordingClient(document: "another target") }
            }
            _ = h.controller.handle(keyEvent(UInt16(kVK_ANSI_V), "v", .command), client: h.client)

            check(!h.controller.voice.hasLearningObservation && learned.isEmpty,
                  "A \(transition) transition during edit attribution discards learning immediately")
            check(h.client.requests.count == stringsBefore,
                  "Edit attribution performs no document-content read after a \(transition) transition")
        }
    }

    @MainActor static func editAttributionPrecheckReentrancy() async {
        for transition in ["secure-current", "focus-current", "secure-bundle", "focus-bundle"] {
            let h = VoiceHarness(); defer { h.close() }
            h.controller.voice.aliasLexicon = {
                .init(generation: 1, revision: 1, availability: .available, entries: [])
            }
            var learned: [VoiceLearnedCorrection] = []
            h.controller.voice.learnCorrection = { learned.append($0); return true }
            await h.start()
            let callbacks = h.fake.callbacks!
            callbacks.onFinal("codux")
            h.key()
            callbacks.onFinalized("codux")
            for _ in 0..<10 { await Task.yield() }
            check(h.controller.voice.hasLearningObservation,
                  "Ordinary insertion creates an observation before target precheck")

            h.client.selection = NSRange(location: 3, length: 5)
            var readsAtTransition: (bundle: Int, identifier: Int, marked: Int,
                                    selected: Int, length: Int, strings: Int)?
            func recordTransition() {
                readsAtTransition = (h.client.bundleIdentifierReads, h.client.uniqueIdentifierReads,
                                     h.client.markedRangeReads, h.client.selectedRangeReads,
                                     h.client.lengthReads, h.client.requests.count)
                if transition.hasPrefix("secure") { h.secure = true }
                else { h.focused = RecordingClient(document: "another target") }
            }
            if transition.hasSuffix("current") {
                var first = true
                h.controller.voice.currentClient = {
                    if first { first = false; recordTransition(); return h.client }
                    return h.focused
                }
            } else {
                h.client.testBundleIdentifierProvider = {
                    h.client.testBundleIdentifierProvider = nil
                    recordTransition()
                    return h.client.testBundleID
                }
            }

            let handled = h.controller.handle(keyEvent(UInt16(kVK_ANSI_V), "v", .command), client: h.client)
            check(!handled, "A \(transition) transition still passes the host edit through")
            check(readsAtTransition != nil && !h.controller.voice.hasLearningObservation && learned.isEmpty,
                  "A \(transition) transition in target precheck discards learning")
            check(h.client.bundleIdentifierReads == readsAtTransition?.bundle &&
                  h.client.uniqueIdentifierReads == readsAtTransition?.identifier &&
                  h.client.markedRangeReads == readsAtTransition?.marked &&
                  h.client.selectedRangeReads == readsAtTransition?.selected &&
                  h.client.lengthReads == readsAtTransition?.length &&
                  h.client.requests.count == readsAtTransition?.strings,
                  "No stale client call follows a \(transition) transition in target precheck")
        }
    }

    @MainActor static func voiceChordEvent(_ down: Bool, flags: NSEvent.ModifierFlags = [.control, .option],
                                          repeated: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k",
                         isARepeat: repeated, keyCode: 40)!
    }

    @MainActor static func recordedVoiceChords() async {
        do {
            let h = VoiceHarness(); defer { h.close() }
            let binding = ShortcutBinding.recorded(from: voiceChordEvent(true))!
            check(h.settings.shortcuts.set(binding, for: .voiceHold))
            check(h.controller.handle(voiceChordEvent(true), client: h.client))
            check(!h.controller.voice.isActive && h.timer != nil, "A recorded hold chord waits for its hold threshold")
            h.now += 0.25; h.timer?()
            for _ in 0..<20 { await Task.yield() }
            check(h.controller.voice.isActive && h.fake.starts == 1)
            check(h.controller.handle(voiceChordEvent(true, repeated: true), client: h.client))
            check(h.fake.starts == 1, "Key repeat cannot restart held dictation")
            check(h.controller.handle(voiceChordEvent(false), client: h.client))
            check(h.fake.stops == 1 && h.fake.cancels == 0, "Releasing the recorded key finishes held dictation once")
            h.fake.callbacks?.onFinalized("")
        }
        do {
            let h = VoiceHarness(); defer { h.close() }
            let binding = ShortcutBinding.recorded(from: voiceChordEvent(true))!
            check(h.settings.shortcuts.set(binding, for: .voiceHold))
            check(h.settings.shortcuts.set(binding, for: .voiceToggle))
            func tap() {
                check(h.controller.handle(voiceChordEvent(true), client: h.client)); h.now += 0.05
                check(h.controller.handle(voiceChordEvent(false), client: h.client)); h.now += 0.05
                _ = h.controller.handle(modifierEvent(59), client: h.client)
                _ = h.controller.handle(modifierEvent(59, .control), client: h.client)
                _ = h.controller.handle(modifierEvent(58, [.control, .option]), client: h.client)
            }
            tap()
            check(!h.controller.voice.isActive && h.timer == nil, "A short chord tap does not start held or continuous dictation")
            tap()
            for _ in 0..<20 { await Task.yield() }
            check(h.controller.voice.isActive && h.fake.starts == 1,
                  "Two recorded chord taps start continuous dictation even when modifiers are released between taps")
            h.now += 0.5
            tap(); tap()
            check(h.fake.stops == 1 && h.fake.starts == 1, "Another double tap stops the existing continuous session once")
            h.fake.callbacks?.onFinalized("")
        }
        do {
            let h = VoiceHarness(); defer { h.close() }
            check(h.settings.shortcuts.set(ShortcutBinding.recorded(from: voiceChordEvent(true))!, for: .voiceHold))
            check(h.controller.handle(voiceChordEvent(true), client: h.client))
            h.now += 0.25; h.timer?()
            for _ in 0..<20 { await Task.yield() }
            _ = h.controller.handle(modifierEvent(58, .control), client: h.client)
            check(h.fake.stops == 1 && h.fake.cancels == 0,
                  "Releasing a required chord modifier finishes held dictation")
            h.fake.callbacks?.onFinalized("")
        }
    }

    @MainActor static func recordedVoiceChordCancellation() async {
        for active in [false, true] {
            for interruption in ["extraModifier", "restoreDefaults", "reassign", "deactivate"] {
                let h = VoiceHarness(); defer { h.close() }
                check(h.settings.shortcuts.set(ShortcutBinding.recorded(from: voiceChordEvent(true))!, for: .voiceHold))
                check(h.controller.handle(voiceChordEvent(true), client: h.client))
                let stale = h.timer!
                if active {
                    h.now += 0.25; stale()
                    for _ in 0..<20 { await Task.yield() }
                    check(h.fake.starts == 1)
                }
                switch interruption {
                case "extraModifier": _ = h.controller.handle(modifierEvent(56, [.control, .option, .shift]), client: h.client)
                case "restoreDefaults": h.settings.shortcuts.restoreDefaults()
                case "reassign": check(h.settings.shortcuts.set(.none, for: .voiceHold))
                default: h.controller.deactivateServer(h.client)
                }
                h.now += 0.25; stale()
                for _ in 0..<20 { await Task.yield() }
                check(!h.controller.voice.isActive && h.timer == nil && h.fake.stops == 0,
                      "\(interruption) cancels rather than finalizes \(active ? "active" : "pending") recorded hold")
                check(h.fake.starts == (active ? 1 : 0) && h.fake.cancels == (active ? 1 : 0),
                      "Cancelled hold callbacks cannot start a replacement capture")
            }
        }
        print("PASS recorded voice chords: hold, double tap, repeats, required release, added modifiers, settings reset and deactivation")
    }

    @MainActor static func earlyRelease() async {
        let h = VoiceHarness(); defer { h.close() }
        h.tap()
        check(!h.controller.voice.isActive && h.fake.starts == 0, "Single short tap has no action")
        h.now += 0.4; h.tap()
        check(!h.controller.voice.isActive, "Late second tap is not a double tap")
        h.controller.voice.cancel()
        h.hold(); check(h.rightShift(false))
        for _ in 0..<20 { await Task.yield() }
        check(h.fake.starts == 1 && h.fake.stops == 1, "Early release queues finalization before service start")
        h.fake.callbacks?.onFinalized("")
        check(h.client.document == "前🙂" && h.client.insertions.isEmpty)
    }

    @MainActor static func holdChordRelease() async {
        for interruption in ["escape", "key", "left", "deactivate", "activate", "proxy"] {
            let h = VoiceHarness(); defer { h.close() }
            check(h.rightShift(true))
            let stale = h.timer!
            switch interruption {
            case "escape": _ = h.controller.handle(keyEvent(53, ""), client: h.client)
            case "key": _ = h.controller.handle(keyEvent(0, "a", .shift), client: h.client)
            case "left": _ = h.controller.handle(modifierEvent(56, NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x6)), client: h.client)
            case "deactivate": h.controller.deactivateServer(h.client)
            case "activate": h.controller.voice.controllerActivated()
            default: h.focused = RecordingClient(document: "邻文")
            }
            h.now += 0.25; stale()
            check(!h.controller.voice.isActive && h.fake.starts == 0, "Pending hold cancelled by \(interruption)")
            h.controller.engine?.clear() // Ordinary Shift-key input may leave a real Rime composition.
        }
        do {
            let h = VoiceHarness(); defer { h.close() }
            let asciiBefore = h.controller.engine!.requestedASCIIMode
            _ = h.controller.handle(modifierEvent(56, .shift), client: h.client)
            check(!h.controller.voice.isActive && h.timer == nil, "Left Shift does not schedule voice")
            _ = h.rightShift(true)
            check(!h.controller.voice.isActive && h.timer == nil, "Normalized left then right Shift cannot arm voice")
            _ = h.rightShift(false)
            _ = h.controller.handle(modifierEvent(56, .shift), client: h.client)
            _ = h.controller.handle(modifierEvent(56), client: h.client)
            check(h.controller.engine!.requestedASCIIMode != asciiBefore, "Left Shift retains its mode toggle")
            _ = h.controller.handle(modifierEvent(61, NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)), client: h.client)
            check(!h.controller.voice.isActive && h.timer == nil, "Right Option no longer schedules voice")
            _ = h.controller.handle(modifierEvent(61), client: h.client)
            _ = h.controller.handle(keyEvent(9, "v", [.control, .option]), client: h.client)
            _ = h.controller.handle(keyEvent(15, "r", [.control, .option]), client: h.client)
            check(!h.controller.voice.isActive, "Old shortcuts no longer start voice")
            h.controller.engine?.clear()
        }
        let h = VoiceHarness(); defer { h.close() }
        var startRejections: [VoiceDiagnostics.StartRejection] = []
        h.controller.voice.reportStartRejection = { startRejections.append($0) }
        check(h.rightShift(true)); let stale = h.timer!
        _ = h.controller.handle(keyEvent(53, ""), client: h.client)
        check(h.rightShift(true)); let current = h.timer!
        stale(); check(!h.controller.voice.isActive, "Cancelled callback cannot trigger replacement gesture")
        h.now += 0.25; current()
        check(h.controller.voice.isActive && h.status.values.last == .voiceRecordingHold, "Hold rejection: \(startRejections); idle: \(IFEngine.allSessionsIdle)")
        check(h.rightShift(true)); check(h.controller.voice.isActive, "Duplicate flags do not retrigger")
        check(h.rightShift(false))
        for _ in 0..<20 { await Task.yield() }
        check(h.fake.stops == 1)
        check(h.controller.voice.isActive && h.status.visible == nil,
              "Releasing hold hides the overlay while recognition finalizes")
        h.fake.callbacks?.onFinalized("")
        h.toggle()
        for _ in 0..<20 { await Task.yield() }
        check(h.status.values.last == .voiceRecordingToggle)
        let stops = h.fake.stops
        h.hold(); check(h.rightShift(false))
        check(h.fake.stops == stops, "Long hold during continuous recording does not change mode")
        h.toggle(); check(h.fake.stops == stops + 1, "Double tap ends continuous recording")
        check(h.controller.voice.isActive && h.status.visible == nil,
              "Ending continuous recording hides the overlay while recognition finalizes")
        h.fake.callbacks?.onFinalized("")
        h.hold()
        for _ in 0..<20 { await Task.yield() }
        check(!h.controller.voice.handle(keyEvent(0, "a", .shift), client: h.client))
        check(!h.controller.voice.isActive, "Shift plus another key cancels voice and passes through")
    }

    @MainActor static func stopDuringPreviewDelivery() async {
        let device = VoiceHarness(); defer { device.close() }
        check(device.controller.handle(modifierEvent(60, NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x4)), client: device.client))
        device.now += 0.25; device.timer?()
        check(device.controller.voice.isActive, "Preserved device bits also start hold")
        check(device.rightShift(false))
        for _ in 0..<20 { await Task.yield() }
        device.fake.callbacks?.onFinalized("")
        let interruptedHold = VoiceHarness(); defer { interruptedHold.close() }
        interruptedHold.hold()
        for _ in 0..<20 { await Task.yield() }
        interruptedHold.client.onMutation = {
            interruptedHold.client.onMutation = nil
            check(!interruptedHold.controller.handle(keyEvent(0, "a", .shift), client: interruptedHold.client))
        }
        interruptedHold.fake.callbacks?.onVolatile("预览")
        check(interruptedHold.rightShift(false), "Reentrant ordinary key must not lose held Shift release")
        check(interruptedHold.fake.stops == 1, "Held release still requests finalization after reentrant key")
        interruptedHold.fake.callbacks?.onFinalized("预览")

        for hold in [false, true] {
            let h = VoiceHarness(); defer { h.close() }
            if hold { h.hold() } else { h.toggle() }
            for _ in 0..<20 { await Task.yield() }
            check(h.fake.starts == 1)
            let callbacks = h.fake.callbacks!
            h.client.onMutation = {
                h.client.onMutation = nil
                if hold { check(h.rightShift(false)) } else { h.toggle() }
                check(h.fake.stops == 0, "Stop waits until marked-text write returns")
                check(!h.controller.handle(keyEvent(0, "a"), client: h.client), "Ordinary reentrant input passes through")
            }
            callbacks.onVolatile("预览")
            check(h.fake.stops == 1 && h.controller.voice.isActive)
            callbacks.onFinalized("预览")
            check(h.client.document == "前🙂预览" && h.client.insertions.count == 1)
        }
        let cancelled = VoiceHarness(); defer { cancelled.close() }
        await cancelled.start()
        cancelled.client.onMutation = {
            cancelled.client.onMutation = nil
            cancelled.toggle()
            cancelled.controller.voice.cancel(.escape)
        }
        cancelled.fake.callbacks?.onVolatile("取消")
        check(cancelled.fake.stops == 0 && cancelled.client.document == "前🙂" && !cancelled.controller.voice.isActive)
    }

    @MainActor static func fixtureBypassesCorrection() async {
        let h = VoiceHarness(voiceService: VoiceRecognitionFixture(mode: .final)); defer { h.close() }
        h.settings.voicePolishEnabled = true
        h.controller.voice.correctionOverride = { _, _ in
            preconditionFailure("Fixture must never invoke correction or network transport")
        }
        h.key()
        for _ in 0..<20 { await Task.yield() }
        check(h.controller.voice.isActive)
        h.key()
        check(!h.controller.voice.isActive && h.client.insertions.count == 1 && h.client.document == "前🙂语音测试")
        check(h.client.mutations.count == 1, "Final-only fixture inserts once without marked-text preview")
    }

    @MainActor static func inputMethodKitAbsentMark() async {
        for finish in [false, true] {
            let h = VoiceHarness(); defer { h.close() }
            h.client.allowsExplicitMarkedReplacement = false
            h.client.caretRect = .zero
            h.client.reportedSelection = NSRange(location: NSNotFound, length: NSNotFound)
            await h.start()
            let callbacks = h.fake.callbacks!
            callbacks.onVolatile("语音测")
            h.client.reportedSelection = NSRange(location: 0, length: 0)
            callbacks.onVolatile("语音测试")
            check(h.controller.voice.isActive && h.client.document == "前🙂语音测试")
            if finish {
                h.key(); callbacks.onFinalized("语音测试")
                check(h.client.insertions.count == 1 && h.client.document == "前🙂语音测试")
            } else {
                h.key(53, [])
                check(h.client.insertions.isEmpty && h.client.document == "前🙂")
            }
            check(!h.controller.voice.isActive && h.client.attributeIndexes.isEmpty,
                  "Optional selection and caret reporting does not gate default replacement delivery")
        }
    }

    @MainActor static func unstableClientIdentifier() async {
        for missing in [false, true] {
            for finish in [false, true] {
                let h = VoiceHarness(); defer { h.close() }
                h.client.testIdentifierProvider = { missing ? nil : UUID().uuidString }
                await h.start()
                let callbacks = h.fake.callbacks!
                callbacks.onVolatile("草稿")
                check(h.client.mark == NSRange(location: 3, length: 2))
                if finish {
                    h.key(); callbacks.onFinalized("草稿")
                    check(h.client.document == "前🙂草稿" && h.client.insertions.count == 1)
                } else {
                    h.controller.voice.cancel(.escape)
                    check(h.client.document == "前🙂" && h.client.insertions.isEmpty)
                }
                check(!h.controller.voice.isActive)
            }
        }
    }

    @MainActor static func activationBeforeDeactivation() async {
        let old = VoiceHarness(); defer { old.close() }
        await old.start()
        let callbacks = old.fake.callbacks!
        callbacks.onFinal("旧字段草稿")
        old.key() // ASR tail may finish while InputMethodKit activates the replacement controller.
        let replacement = VoiceHarness(); defer { replacement.close() }
        replacement.controller.activateServer(replacement.client)
        check(!old.controller.voice.isActive, "New controller activation cancels process-wide owner before old deactivation")
        callbacks.onFinalized("旧字段草稿")
        check(old.client.document == "前🙂旧字段草稿" && old.client.insertions.isEmpty,
              "Lifecycle loss cannot clear a possibly different field or insert a stale final")
        check(replacement.client.document == "前🙂" && replacement.client.mutations.isEmpty,
              "Same-app replacement controller remains untouched")
    }

    @MainActor static func activationDuringInitialCapture() async {
        let old = VoiceHarness(); defer { old.close() }
        let replacement = VoiceHarness(); defer { replacement.close() }
        old.controller.voice.currentClient = {
            old.controller.voice.currentClient = { old.focused }
            replacement.controller.activateServer(replacement.client)
            return old.focused
        }
        old.key()
        try? await Task.sleep(for: .milliseconds(20))
        check(!old.controller.voice.isActive && old.fake.starts == 0,
              "Activation during initial target capture invalidates the pending voice start")
        check(old.client.document == "前🙂" && old.client.insertions.isEmpty)
        check(replacement.client.document == "前🙂" && replacement.client.mutations.isEmpty)
    }

    @MainActor static func deliveryAndFallback() async {
        let h = VoiceHarness(); defer { h.close() }
        h.settings.voicePolishEnabled = true
        var correctionRequests: [(String, VoicePolishPrompt.Style)] = []
        h.controller.voice.correctionOverride = { text, style in
            correctionRequests.append((text, style))
            throw VoiceCorrectionClient.Failure.network
        }
        await h.start()
        let callbacks = h.fake.callbacks!
        callbacks.onVolatile("你好🙂")
        check(h.client.mark == NSRange(location: 3, length: 4))
        check(h.client.selection == NSRange(location: 7, length: 0), "UTF16 selection includes emoji surrogate pair")
        h.controller.refresh(h.client)
        check(h.client.document == "前🙂你好🙂", "Rime refresh cannot erase voice mark")
        callbacks.onFinal("你好")
        callbacks.onFinal("🙂")
        try? await Task.sleep(for: .milliseconds(20))
        check(correctionRequests.isEmpty, "Final ASR fragments do not start polishing before finalization")
        h.key()
        callbacks.onFinalized("你好🙂")
        try? await Task.sleep(for: .milliseconds(20))
        check(correctionRequests.count == 1 && correctionRequests[0].0 == "你好🙂"
              && correctionRequests[0].1 == .defaultStyle,
              "The complete finalized transcript is polished exactly once with the default style")
        check(h.client.document == "前🙂你好🙂" && h.client.insertions.count == 1)
        check(h.client.insertions[0].replacementRange == NSRange(location: NSNotFound, length: 0))
        check(h.client.mark.location == NSNotFound && !h.controller.voice.isActive)
        callbacks.onFinalized("过期")
        check(h.client.insertions.count == 1 && h.status.values.contains(.voiceFallback))
        check(h.client.lengthReads == 1 && h.client.requests == [NSRange(location: 3, length: 4)],
              "Voice reads back only the bounded inserted range for correction observation")
    }

    @MainActor static func applicationPolishRouting() async throws {
        func configuredHarness(appBundleID: String = "inkflow.recording-client",
                               ruleBundleID: String = "inkflow.recording-client",
                               enabled: Bool = true, prompt: String = "Custom style") throws -> VoiceHarness {
            let h = VoiceHarness()
            h.app = .init(bundleID: appBundleID, pid: 77)
            h.client.testBundleID = appBundleID
            h.settings.voicePolishEnabled = true
            _ = try h.settings.saveVoicePolishRule(bundleIdentifier: ruleBundleID, displayName: "Target App",
                                                   isEnabled: enabled, prompt: prompt)
            return h
        }

        for scenario in ["enabled", "disabled", "unmatched", "caseMismatch"] {
            let h: VoiceHarness
            switch scenario {
            case "disabled": h = try configuredHarness(enabled: false)
            case "unmatched": h = try configuredHarness(ruleBundleID: "other.app")
            case "caseMismatch": h = try configuredHarness(appBundleID: "INKFLOW.RECORDING-CLIENT")
            default: h = try configuredHarness()
            }
            defer { h.close() }
            var requests: [(String, VoicePolishPrompt.Style)] = []
            h.controller.voice.correctionOverride = { text, style in requests.append((text, style)); return text }
            await h.start()
            h.key(); h.fake.callbacks?.onFinalized("完整转写")
            try? await Task.sleep(for: .milliseconds(20))
            let expected: VoicePolishPrompt.Style = scenario == "enabled" ? .custom("Custom style") : .defaultStyle
            check(requests.count == 1 && requests[0].0 == "完整转写" && requests[0].1 == expected,
                  "\(scenario) resolves one exact session style")
        }

        let snapshot = try configuredHarness(prompt: "Style at start"); defer { snapshot.close() }
        var snapshotRequests: [(String, VoicePolishPrompt.Style)] = []
        snapshot.controller.voice.correctionOverride = { text, style in
            snapshotRequests.append((text, style)); return text
        }
        await snapshot.start()
        // Isolate the closure snapshot from the controller's existing policy of cancelling
        // every active voice session on a general settings-change notification.
        NotificationCenter.default.removeObserver(snapshot.controller, name: .settingsDidChange,
                                                  object: snapshot.settings)
        _ = try snapshot.settings.saveVoicePolishRule(originalBundleIdentifier: "inkflow.recording-client",
            bundleIdentifier: "inkflow.recording-client", displayName: "Target App", isEnabled: true,
            prompt: "Style changed later")
        snapshot.key(); snapshot.fake.callbacks?.onFinalized("快照转写")
        try? await Task.sleep(for: .milliseconds(20))
        check(snapshotRequests.count == 1 && snapshotRequests[0].1 == .custom("Style at start"),
              "A running voice session retains the style resolved from its captured starting target")

        let disabled = VoiceHarness(); defer { disabled.close() }
        var disabledRequests = 0
        disabled.controller.voice.correctionOverride = { _, _ in disabledRequests += 1; return "unexpected" }
        await disabled.start()
        disabled.key(); disabled.fake.callbacks?.onFinalized("离线原文")
        try? await Task.sleep(for: .milliseconds(20))
        check(disabledRequests == 0 && disabled.client.document == "前🙂离线原文",
              "Global polishing off makes no correction request and commits the full raw transcript")
    }

    @MainActor static func cancellationAndIdentity() async {
        for mode in 0..<6 {
            let h = VoiceHarness(); defer { h.close() }
            await h.start()
            let callbacks = h.fake.callbacks!
            callbacks.onVolatile("草稿")
            let other = RecordingClient(document: "保留")
            other.caretRect = h.client.caretRect
            switch mode {
            case 0: h.focused = other
            case 1: h.client.testBundleID = "different-app"
            case 2: h.app = .init(bundleID: "other.app", pid: 88)
            case 3: h.secure = true
            case 4: h.controller.deactivateServer(h.client)
            default: h.settings.voicePolishEnabled = true
            }
            if h.controller.voice.isActive { _ = h.controller.voice.validate() }
            check(!h.controller.voice.isActive)
            callbacks.onFinal("迟到"); callbacks.onFinalized("迟到")
            check(h.client.insertions.isEmpty && other.document == "保留")
            if [4, 5].contains(mode) { check(h.client.document == "前🙂") }
            else { check(h.client.document == "前🙂草稿", "Lost target is never cleared without lifecycle ownership") }
        }
        let h = VoiceHarness(); defer { h.close() }
        await h.start(); h.fake.callbacks?.onVolatile("取消")
        h.key(53, [])
        check(h.client.document == "前🙂" && h.client.insertions.isEmpty)
    }

    @MainActor static func reentrancy() async {
        let h = VoiceHarness(); defer { h.close() }
        await h.start()
        let callbacks = h.fake.callbacks!
        h.client.onMutation = {
            h.client.onMutation = nil
            h.client.caretRect.origin.x += 10 // Our new marked text moved the caret.
            h.controller.voice.cancel(.escape)
        }
        callbacks.onVolatile("重入")
        check(h.client.document == "前🙂" && !h.controller.voice.isActive, "Reentrant cancellation cleans mark after write returns")
        let lost = VoiceHarness(); defer { lost.close() }
        await lost.start()
        lost.fake.callbacks?.onVolatile("旧草稿")
        lost.fake.onCancel = {
            lost.fake.onCancel = nil
            lost.controller.deactivateServer(lost.client)
        }
        lost.controller.voice.cancel(.escape)
        check(lost.client.mutations.count == 1 && lost.client.document == "前🙂旧草稿",
              "Lifecycle loss during cancellation prevents clearing a potentially reused client")
        let final = VoiceHarness(); defer { final.close() }
        await final.start()
        let done = final.fake.callbacks!
        done.onFinal("一次")
        final.key()
        final.client.onMutation = {
            final.client.onMutation = nil
            final.controller.commitComposition(final.client)
            check(!final.rightShift(true), "Final insertion cannot reenter a new gesture")
            check(!final.rightShift(false))
            done.onFinalized("重复")
        }
        done.onFinalized("一次")
        check(final.client.insertions.count == 1 && final.client.document == "前🙂一次")
        let read = VoiceHarness(); defer { read.close() }
        await read.start()
        read.controller.voice.currentClient = {
            read.controller.voice.currentClient = { read.focused }
            read.controller.deactivateServer(read.client)
            return read.focused
        }
        read.fake.callbacks?.onVolatile("不能写")
        check(!read.controller.voice.isActive && read.client.document == "前🙂")
        let finish = VoiceHarness(); defer { finish.close() }
        await finish.start()
        let finishCallbacks = finish.fake.callbacks!
        finishCallbacks.onFinal("不能提交")
        finish.key()
        finish.fake.onCancel = {
            finish.fake.onCancel = nil
            finish.controller.voice.cancel(.escape)
        }
        finishCallbacks.onFinalized("不能提交")
        check(finish.client.insertions.isEmpty && finish.client.document == "前🙂", "Cancellation during final service callback wins")
    }

    @MainActor static func externalClientCommit() async {
        let nested = VoiceHarness(); defer { nested.close() }
        await nested.start()
        let nestedCallbacks = nested.fake.callbacks!
        nested.client.onMutation = {
            nested.client.onMutation = nil
            nested.controller.commitComposition(nested.client)
        }
        nestedCallbacks.onVolatile("保留")
        check(nested.controller.voice.isActive && nested.client.document == "前🙂保留",
              "Nested commit during our marked-text delivery cannot cancel that delivery")
        nested.key(); nestedCallbacks.onFinalized("保留")
        check(nested.client.insertions.count == 1)
        for matching in [true, false] {
            let h = VoiceHarness(); defer { h.close() }
            await h.start()
            let callbacks = h.fake.callbacks!
            callbacks.onVolatile("取消草稿")
            let other = RecordingClient(document: "保留")
            h.controller.commitComposition(matching ? h.client : other)
            check(!h.controller.voice.isActive, "Client commit ends the voice composition")
            check(h.client.document == (matching ? "前🙂" : "前🙂取消草稿"))
            check(other.document == "保留" && other.mutations.isEmpty)
            callbacks.onFinal("迟到"); callbacks.onFinalized("迟到")
            check(h.client.insertions.isEmpty && other.insertions.isEmpty)
        }
        let h = VoiceHarness(); defer { h.close() }
        await h.start()
        h.fake.callbacks?.onVolatile("旧草稿")
        h.controller.deactivateServer(h.client)
        let mutations = h.client.mutations.count
        h.controller.commitComposition(h.client)
        check(h.client.mutations.count == mutations && h.client.document == "前🙂",
              "A commit after lifecycle loss cannot clear a reused field")
    }

    @MainActor static func synchronousDeactivation() async {
        for matching in [false, true] {
            let h = VoiceHarness(); defer { h.close() }
            await h.start()
            let callbacks = h.fake.callbacks!
            callbacks.onVolatile("旧草稿")
            let other = RecordingClient(document: "邻文保留")
            h.focused = other
            h.controller.deactivateServer(matching ? h.client : other)
            check(!h.controller.voice.isActive)
            check(h.client.document == (matching ? "前🙂" : "前🙂旧草稿"),
                  "Only the synchronous matching original sender may clear its voice mark")
            check(other.document == "邻文保留" && other.mutations.isEmpty)
            callbacks.onFinalized("迟到")
            check(h.client.insertions.isEmpty && other.insertions.isEmpty)
        }
        let nested = VoiceHarness(); defer { nested.close() }
        await nested.start()
        nested.client.onMutation = {
            nested.client.onMutation = nil
            nested.controller.deactivateServer(nested.client)
        }
        nested.fake.callbacks?.onVolatile("旧草稿")
        check(!nested.controller.voice.isActive && nested.client.mutations.count == 1,
              "Deactivation inside delivery cannot perform a nested cleanup write")
    }

    @MainActor static func gatesAndSettings() async {
        let h = VoiceHarness(); defer { h.close() }
        check(!h.settings.voicePolishEnabled && !h.settings.smart.isEnabled)
        h.settings.voicePolishEnabled = true
        check(!h.settings.smart.isEnabled && IFSettings(defaults: h.isolated.defaults).voicePolishEnabled)
        h.settings.voicePolishEnabled = false
        h.fake.isReady = false; h.key()
        check(!h.controller.voice.isActive && h.status.values.last == .voiceNotReady && h.fake.prepares == 0)
        h.fake.isReady = true
        h.controller.voice.lexicon = { .unknown(generation: 17, revision: 3) }; h.key()
        check(h.controller.voice.isActive && h.status.values.last == .voiceRecordingToggle,
              "Unknown learned lexicon readiness must not block a ready recognition service")
        h.controller.voice.cancel(.escape)
        h.controller.voice.lexicon = { .init(generation: 1, revision: 0, availability: .available, entries: []) }
        check(h.controller.handle(keyEvent(0, "n"), client: h.client), "Ordinary offline key remains handled")
        h.key()
        check(!h.controller.voice.isActive && h.controller.engine?.snapshot().preedit.isEmpty == false)
        h.controller.engine?.clear()
    }

    @MainActor static func unknownLexiconFallback() async {
        let h = VoiceHarness(); defer { h.close() }
        let unknown = VoiceLexiconSnapshot.unknown(generation: 41, revision: 7)
        var current = unknown
        h.controller.voice.lexicon = { current }
        h.controller.voice.aliasLexicon = { .unknown() }
        let alternatives = [["张伟", "张玮"], ["使用 Swift。"]]
        h.key()
        check(h.controller.voice.isActive && h.fake.starts == 0)
        // Preparation can finish after target capture but before queued service startup.
        current = .init(generation: 41, revision: 8, availability: .available,
                        entries: [.init(text: "张玮", code: "zhang wei ", commits: 3)])
        for _ in 0..<20 { await Task.yield() }
        check(h.fake.starts == 1 && h.fake.snapshot == unknown && h.fake.prepares == 0,
              "Recognition receives the real unknown generation and revision without preparation")
        let callbacks = h.fake.callbacks!
        check(h.controller.voice.validate() && h.controller.voice.isActive && h.fake.snapshot == unknown,
              "Same-generation readiness preserves the active session and its captured snapshot")
        let raw = VoiceAlternativeReranker.select(alternatives, snapshot: h.fake.snapshot!)
        check(raw == "张伟使用 Swift。", "An empty unknown snapshot preserves the primary ASR transcript")
        callbacks.onFinal(raw)
        h.controller.voice.stop()
        callbacks.onFinalized(raw)
        callbacks.onFinalized("重复")
        check(h.client.document == "前🙂" + raw && h.client.insertions.count == 1 && !h.controller.voice.isActive,
              "Unknown lexicon fallback inserts the production reranker's raw result exactly once")

        h.key()
        for _ in 0..<20 { await Task.yield() }
        check(h.controller.voice.isActive && h.fake.starts == 2 && h.fake.snapshot == current,
              "The next session captures the now-ready learned entries")
        callbacks.onFinalized("旧会话")
        check(h.controller.voice.isActive && h.client.insertions.count == 1,
              "Late callbacks from the fallback session cannot finish the next session")
        let personalized = VoiceAlternativeReranker.select(alternatives, snapshot: h.fake.snapshot!)
        check(personalized == "张玮使用 Swift。", "Ready entries restore production ASR personalization")
        h.controller.voice.stop()
        h.fake.callbacks?.onFinalized(personalized)
        check(h.client.document == "前🙂" + raw + personalized && h.client.insertions.count == 2,
              "The ready session inserts its personalized result once")
    }

    @MainActor static func unknownLexiconInvalidation() async {
        for mode in 0..<4 {
            let h = VoiceHarness(); defer { h.close() }
            var current = VoiceLexiconSnapshot.unknown(generation: 51, revision: 9)
            h.controller.voice.lexicon = { current }
            h.controller.voice.aliasLexicon = { .unknown() }
            await h.start()
            let callbacks = h.fake.callbacks!
            switch mode {
            case 0: current = .unknown(generation: 52)
            case 1: current = .init(generation: 52, revision: 1, availability: .available, entries: [])
            case 2: h.controller.voice.cancel(.escape)
            default: h.controller.deactivateServer(h.client)
            }
            callbacks.onVolatile("迟到草稿")
            callbacks.onFinal("迟到")
            callbacks.onFinalized("迟到")
            check(!h.controller.voice.isActive && h.fake.cancels == 1,
                  "Generation reset, reload, cancellation and deactivation invalidate unknown sessions")
            check(h.client.document == "前🙂" && h.client.mutations.isEmpty && h.client.insertions.isEmpty,
                  "Invalidated unknown sessions reject all late recognition writes")
        }
    }

    @MainActor static func unknownLexiconQueuedCancellation() async {
        for mode in 0..<3 {
            let h = VoiceHarness(); defer { h.close() }
            var current = VoiceLexiconSnapshot.unknown(generation: 61, revision: 2)
            h.controller.voice.lexicon = { current }
            h.key()
            check(h.controller.voice.isActive && h.fake.starts == 0,
                  "Unknown fallback queues recognition startup after target capture")
            switch mode {
            case 0: h.controller.voice.cancel(.escape)
            case 1: current = .unknown(generation: 62)
            default: current = .init(generation: 62, revision: 1, availability: .available, entries: [])
            }
            for _ in 0..<20 { await Task.yield() }
            check(!h.controller.voice.isActive && h.fake.starts == 0 && h.fake.prepares == 0,
                  "Cancellation or generation change before queued startup prevents recognition and preparation")
            check(h.client.document == "前🙂" && h.client.mutations.isEmpty)
        }
    }

    @MainActor static func selectedTextDelivery() async {
        let h = VoiceHarness(); defer { h.close() }
        h.client.document = "A😀BC"
        h.client.selection = NSRange(location: 1, length: 3)
        await h.start()
        let callbacks = h.fake.callbacks!
        check(h.client.requests.isEmpty, "Selected text is not read before preview delivery")
        callbacks.onVolatile("一")
        callbacks.onVolatile("二😀")
        check(h.client.document == "A二😀C" && h.client.mark == NSRange(location: 1, length: 3),
              "Successive previews replace the same selected UTF-16 span")
        h.key(); callbacks.onFinalized("完成")
        check(h.client.document == "A完成C" && h.client.insertions.count == 1,
              "The final transcript replaces the selected text exactly once")
        check(h.client.insertions[0].replacementRange == NSRange(location: NSNotFound, length: 0))
        check(h.client.requests.isEmpty && h.client.lengthReads == 0,
              "Selected text is never read for success delivery")
    }

    @MainActor static func selectedTextRollback() async {
        for outcome in 0..<5 {
            let h = VoiceHarness(); defer { h.close() }
            h.client.document = "A😀BC"
            h.client.selection = NSRange(location: 1, length: 3)
            await h.start()
            let callbacks = h.fake.callbacks!
            callbacks.onVolatile("草稿")
            var preview = h.client.document
            var selection = h.client.selection
            var mark = h.client.mark
            var mutations = h.client.mutations.count
            switch outcome {
            case 0: h.controller.voice.cancel(.escape)
            case 1: callbacks.onFailure()
            case 2: h.key(); callbacks.onFinalized("")
            case 3: h.controller.commitComposition(h.client)
            default:
                callbacks.onFinal("最终")
                preview = h.client.document
                selection = h.client.selection
                mark = h.client.mark
                mutations = h.client.mutations.count
                h.key()
                h.fake.onCancel = {
                    h.fake.onCancel = nil
                    h.controller.voice.cancel(.escape)
                }
                callbacks.onFinalized("最终")
            }
            try? await Task.sleep(for: .milliseconds(20))
            check(h.client.document == preview && h.client.selection == selection && h.client.mark == mark,
                  "Unbound selected-text cancellation preserves the host preview for outcome \(outcome)")
            check(h.client.mutations.count == mutations && h.client.insertions.isEmpty,
                  "Unbound selected-text cancellation performs no second write for outcome \(outcome)")
            check(h.client.requests.isEmpty && h.client.lengthReads == 0)
            check(!h.controller.voice.isActive)
        }
    }

    @MainActor static func reportedSelectionMismatch() async {
        let h = VoiceHarness(); defer { h.close() }
        h.client.document = "浮层"
        h.client.selection = NSRange(location: 2, length: 0)
        h.client.reportedSelection = NSRange(location: 0, length: 1)
        await h.start()
        check(h.client.requests.isEmpty, "Cross-surface reported text is never read")
        let callbacks = h.fake.callbacks!
        callbacks.onVolatile("实时")
        check(h.client.document == "浮层实时", "Host-reported selection does not redirect focused preview delivery")
        h.key(); callbacks.onFinalized("提交")
        check(h.client.document == "浮层提交" && h.client.insertions.count == 1,
              "Focused target receives one final insertion despite a cross-surface reported selection")
    }

    @MainActor static func selectedTextEscapeCancellation() async {
        do {
            let plain = VoiceHarness(); defer { plain.close() }
            await plain.start()
            plain.fake.callbacks?.onVolatile("草稿")
            check(plain.controller.handle(keyEvent(53, ""), client: plain.client),
                  "Escape remains consumed for a voice mark that did not replace selected text")
            check(!plain.controller.voice.isActive)
        }
        do {
            let selected = VoiceHarness(); defer { selected.close() }
            selected.client.selection = NSRange(location: 0, length: 1)
            await selected.start()
            let mutations = selected.client.mutations.count
            check(!selected.controller.handle(keyEvent(53, ""), client: selected.client),
                  "Escape passes to the host for selected-text voice before the first preview")
            check(!selected.controller.voice.isActive && selected.client.mutations.count == mutations,
                  "Pre-preview selected-text Escape cancels without a client write")
            check(selected.controller.engine?.snapshot().preedit.isEmpty == true)
        }
        let h = VoiceHarness(); defer { h.close() }
        h.client.document = "A😀BC"
        h.client.selection = NSRange(location: 1, length: 3)
        await h.start()
        h.fake.callbacks?.onVolatile("保留")
        let mutationsBeforeEscape = h.client.mutations.count
        check(!h.controller.handle(keyEvent(53, ""), client: h.client),
              "Escape passes through to the host after cancelling a selected-text voice mark")
        check(!h.controller.voice.isActive && h.client.mutations.count == mutationsBeforeEscape,
              "Escape cancellation performs no second mutation")
        check(h.controller.engine?.snapshot().preedit.isEmpty == true,
              "Rime remains idle while selected-text Escape is handed to the host")
    }

    @MainActor static func secureMarkedTextGuard() async {
        do {
            let h = VoiceHarness(); defer { h.close() }
            h.client.mark = NSRange(location: 1, length: 1)
            h.secure = true
            _ = h.controller.handle(keyEvent(0, "n"), client: h.client)
            h.key()
            try? await Task.sleep(for: .milliseconds(20))
            check(h.client.markedRangeReads == 0,
                  "Secure ordinary input and voice shortcuts never read markedRange")
            check(!h.controller.voice.isActive && h.fake.starts == 0)
            h.controller.engine?.clear()
        }
        do {
            let h = VoiceHarness(); defer { h.close() }
            var readsAtTransition: (selected: Int, marked: Int, strings: Int)?
            h.client.testBundleIdentifierProvider = {
                h.client.testBundleIdentifierProvider = nil
                readsAtTransition = (h.client.selectedRangeReads, h.client.markedRangeReads, h.client.requests.count)
                h.secure = true
                return h.client.testBundleID
            }
            _ = h.controller.handle(keyEvent(0, "n"), client: h.client)
            check(readsAtTransition != nil && h.client.selectedRangeReads == readsAtTransition?.selected &&
                  h.client.markedRangeReads == readsAtTransition?.marked &&
                  h.client.requests.count == readsAtTransition?.strings,
                  "A secure transition inside client identity lookup blocks later context reads")
            h.controller.engine?.clear()
        }
    }

    @MainActor static func secureSelectedRangeStart() async {
        let h = VoiceHarness(); defer { h.close() }
        var reasons: [VoiceDiagnostics.StartRejection] = []
        var readsAtTransition: (marked: Int, bundle: Int, identifier: Int, strings: Int)?
        h.controller.voice.reportStartRejection = { reasons.append($0) }
        h.client.onSelectedRange = {
            h.client.onSelectedRange = nil
            readsAtTransition = (h.client.markedRangeReads, h.client.bundleIdentifierReads,
                                 h.client.uniqueIdentifierReads, h.client.requests.count)
            h.secure = true
        }
        h.key()
        try? await Task.sleep(for: .milliseconds(20))
        check(reasons.last == .secure && !h.controller.voice.isActive && h.fake.starts == 0,
              "Secure activation inside selectedRange rejects voice start before ownership")
        check(h.status.visible == nil && !h.status.values.contains(.voiceRecordingToggle) &&
              !h.status.values.contains(.voiceRecordingHold),
              "Reentrant secure rejection never presents recording status")
        check(readsAtTransition != nil && h.client.markedRangeReads == readsAtTransition?.marked &&
              h.client.bundleIdentifierReads == readsAtTransition?.bundle &&
              h.client.uniqueIdentifierReads == readsAtTransition?.identifier &&
              h.client.requests.count == readsAtTransition?.strings,
              "No client read follows a selectedRange callback that activates secure input")
    }

    @MainActor static func preeditClearRecovery() async {
        let h = VoiceHarness(); defer { h.close() }
        check(h.controller.handle(keyEvent(0, "n"), client: h.client),
              "Initial Chinese key creates an InkFlow preedit")
        check(h.controller.engine?.snapshot().preedit.isEmpty == false)

        h.controller.engine?.clear()
        h.controller.refresh(h.client)
        h.client.mark = NSRange(location: h.client.selection.location, length: 0)

        check(h.controller.handle(keyEvent(0, "n"), client: h.client),
              "Chinese input resumes after the client clears InkFlow preedit")
        check(h.controller.engine?.snapshot().preedit.isEmpty == false,
              "A stale finite zero-length marked range does not block Rime")

        h.controller.engine?.clear()
        h.controller.refresh(h.client)
        h.client.mark = NSRange(location: h.client.selection.location, length: 0)
        let asciiBefore = h.controller.engine!.requestedASCIIMode
        check(h.controller.handle(modifierEvent(56, .shift), client: h.client))
        check(h.controller.handle(modifierEvent(56), client: h.client))
        check(h.controller.engine!.requestedASCIIMode != asciiBefore,
              "Standalone Left Shift resumes after the client clears InkFlow preedit")

        h.client.mark = NSRange(location: h.client.selection.location, length: 0)
        h.key()
        try? await Task.sleep(for: .milliseconds(20))
        check(h.controller.voice.isActive && h.fake.starts == 1,
              "Right Shift voice resumes after the client clears InkFlow preedit")

        h.controller.voice.cancel()
        h.client.mark = NSRange(location: h.client.selection.location, length: 0)
        h.hold()
        try? await Task.sleep(for: .milliseconds(20))
        check(h.controller.voice.isActive && h.fake.starts == 2,
              "Right Shift hold resumes after the client clears InkFlow preedit")
    }

    @MainActor static func selectedTextTargetLoss() async {
        let h = VoiceHarness(); defer { h.close() }
        h.client.document = "A😀BC"
        h.client.selection = NSRange(location: 1, length: 3)
        await h.start()
        let callbacks = h.fake.callbacks!
        callbacks.onVolatile("旧草稿")
        let oldPreview = h.client.document
        let other = RecordingClient(document: "新字段")
        other.testBundleID = h.client.testBundleID
        h.focused = other
        _ = h.controller.voice.validate()
        callbacks.onFinalized("迟到")
        check(h.client.document == oldPreview && other.document == "新字段",
              "Target loss never restores or submits text into either stale or newly focused clients")
        check(h.client.insertions.isEmpty && other.mutations.isEmpty)

        let deactivated = VoiceHarness(); defer { deactivated.close() }
        deactivated.client.document = "A😀BC"
        deactivated.client.selection = NSRange(location: 1, length: 3)
        await deactivated.start()
        deactivated.fake.callbacks?.onVolatile("旧草稿")
        let deactivatedPreview = deactivated.client.document
        let mutationCount = deactivated.client.mutations.count
        deactivated.controller.deactivateServer(deactivated.client)
        check(deactivated.client.document == deactivatedPreview && deactivated.client.mutations.count == mutationCount,
              "Lifecycle loss does not restore or clear a selected-text preview in the stale client")
    }

    @MainActor static func correctingCancellation() async {
        let h = VoiceHarness(); defer { h.close() }
        h.settings.voicePolishEnabled = true
        h.controller.voice.correctionOverride = { _, _ in
            try await Task.sleep(for: .seconds(30)); return "迟到润色"
        }
        await h.start()
        let callbacks = h.fake.callbacks!
        callbacks.onFinal("未提交")
        h.key(); callbacks.onFinalized("未提交")
        check(h.controller.voice.isActive && h.status.values.last == .voiceCorrecting)
        h.key(53, [])
        try? await Task.sleep(for: .milliseconds(20))
        check(h.client.document == "前🙂" && h.client.insertions.isEmpty)
    }

    @MainActor static func startRejectionDiagnostics() async {
        let h = VoiceHarness(); defer { h.close() }
        var reasons: [VoiceDiagnostics.StartRejection] = []
        h.controller.voice.reportStartRejection = { reasons.append($0) }
        h.secure = true
        h.key(); h.key()
        check(reasons == [.secure], "Repeated preflight rejection is suppressed")
        h.secure = false
        h.client.testBundleID = nil
        h.key(); h.key()
        check(reasons == [.secure, .bundle], "Initial target failure reports only its fixed reason")
        h.client.testBundleID = "inkflow.recording-client"
        h.client.selection = NSRange(location: -1, length: 0)
        h.key()
        check(reasons.last == .selection && h.fake.starts == 0 && h.fake.prepares == 0)
        check(h.status.values.isEmpty && h.status.visible == nil,
              "Rejected voice starts retain diagnostics without presenting a generic target warning")
        check(h.client.requests.isEmpty && h.client.lengthReads == 0 && h.client.mutations.isEmpty,
              "Diagnostics never read content, mutate the client or open recognition")
        var limiter = VoiceDiagnostics.StartRejectionLimiter()
        let now = ContinuousClock.now
        check(limiter.admit(.selection, now: now))
        check(!limiter.admit(.selection, now: now.advanced(by: .seconds(4))))
        check(limiter.admit(.selection, now: now.advanced(by: .seconds(5))))
    }
}
