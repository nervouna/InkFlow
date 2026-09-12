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
    var callbacks: AppleVoiceRecognizer.Callbacks?
    var onCancel: (() -> Void)?
    func prepare(requestPermission: Bool) async throws { prepares += 1; isReady = true }
    func start(id: UUID, snapshot: VoiceLexiconSnapshot, callbacks: AppleVoiceRecognizer.Callbacks) {
        self.id = id; self.callbacks = callbacks; starts += 1
    }
    func stop(id: UUID) { if self.id == id { stops += 1 } }
    func cancel() { if id != nil { cancels += 1 }; id = nil; callbacks = nil; onCancel?() }
}

@MainActor
private final class VoiceStatus: InputStatusPresenting {
    var values: [InputStatus] = []
    func present(_ status: InputStatus, client: IMKTextInput?, characterIndex: Int) { values.append(status) }
    func hide() {}
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
        try? await Task.sleep(for: .milliseconds(20))
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
        await holdChordRelease()
        await stopDuringPreviewDelivery()
        await activationBeforeDeactivation()
        await activationDuringInitialCapture()
        await deliveryAndFallback()
        await cancellationAndIdentity()
        await reentrancy()
        await externalClientCommit()
        await synchronousDeactivation()
        await gatesAndSettings()
        await startRejectionDiagnostics()
        await correctingCancellation()
        print("PASS voice controller: hold/toggle, UTF16 marks, exact-once fallback, target ownership, reentrancy and independent settings")
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
        h.fake.callbacks?.onFinalized("")
        h.toggle()
        for _ in 0..<20 { await Task.yield() }
        check(h.status.values.last == .voiceRecordingToggle)
        let stops = h.fake.stops
        h.hold(); check(h.rightShift(false))
        check(h.fake.stops == stops, "Long hold during continuous recording does not change mode")
        h.toggle(); check(h.fake.stops == stops + 1, "Double tap ends continuous recording")
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
        h.controller.voice.correctionOverride = { _ in
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
        h.controller.voice.correctionOverride = { _ in throw VoiceCorrectionClient.Failure.network }
        await h.start()
        let callbacks = h.fake.callbacks!
        callbacks.onVolatile("你好🙂")
        check(h.client.mark == NSRange(location: 3, length: 4))
        check(h.client.selection == NSRange(location: 7, length: 0), "UTF16 selection includes emoji surrogate pair")
        h.controller.refresh(h.client)
        check(h.client.document == "前🙂你好🙂", "Rime refresh cannot erase voice mark")
        callbacks.onFinal("你好🙂")
        try? await Task.sleep(for: .milliseconds(20))
        h.key()
        callbacks.onFinalized("你好🙂")
        check(h.client.document == "前🙂你好🙂" && h.client.insertions.count == 1)
        check(h.client.insertions[0].replacementRange == NSRange(location: NSNotFound, length: 0))
        check(h.client.mark.location == NSNotFound && !h.controller.voice.isActive)
        callbacks.onFinalized("过期")
        check(h.client.insertions.count == 1 && h.status.values.contains(.voiceFallback))
        check(h.client.lengthReads == 0 && h.client.requests.isEmpty, "Voice never reads document content or length")
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
        h.controller.voice.lexicon = { .unknown() }; h.key()
        check(h.status.values.last == .voiceLexiconWaiting && !h.controller.voice.isActive)
        h.controller.voice.lexicon = { .init(generation: 1, revision: 0, availability: .available, entries: []) }
        h.client.selection = NSRange(location: 0, length: 1); h.key()
        check(h.status.values.last == .voiceSelectionUnsupported && h.client.document == "前🙂")
        h.client.selection = NSRange(location: 3, length: 0)
        check(h.controller.handle(keyEvent(0, "n"), client: h.client), "Ordinary offline key remains handled")
        h.key()
        check(!h.controller.voice.isActive && h.controller.engine?.snapshot().preedit.isEmpty == false)
        h.controller.engine?.clear()
    }

    @MainActor static func correctingCancellation() async {
        let h = VoiceHarness(); defer { h.close() }
        h.settings.voicePolishEnabled = true
        h.controller.voice.correctionOverride = { _ in
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
        check(h.client.requests.isEmpty && h.client.lengthReads == 0 && h.client.mutations.isEmpty,
              "Diagnostics never read content, mutate the client or open recognition")
        var limiter = VoiceDiagnostics.StartRejectionLimiter()
        let now = ContinuousClock.now
        check(limiter.admit(.selection, now: now))
        check(!limiter.admit(.selection, now: now.advanced(by: .seconds(4))))
        check(limiter.admit(.selection, now: now.advanced(by: .seconds(5))))
    }
}
