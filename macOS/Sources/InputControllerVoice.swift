@preconcurrency import InputMethodKit
import Carbon
import Combine

struct VoiceForeground: Equatable {
    let bundleID: String
    let pid: pid_t
    @MainActor static func current() -> Self? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else { return nil }
        return Self(bundleID: bundle, pid: app.processIdentifier)
    }
}

/// Voice owns its mark separately from Rime. All client calls can reenter this object.
@MainActor
final class IFInputControllerVoice {
    private struct Target {
        let client: IMKTextInput
        let proxy: ObjectIdentifier
        let app: VoiceForeground
        func sameIdentity(_ other: Self) -> Bool {
            proxy == other.proxy && app == other.app
        }
    }
    private static weak var activeOwner: IFInputControllerVoice?
    private weak var controller: IFInputControllerShell?
    private var target: Target?
    private var cleanupPending: Target?
    private var epoch: UInt64 = 0
    private var token: UUID?
    private var session: VoiceSession?
    private var startTask: Task<Void, Never>?
    private var ownsVoiceMark = false
    private var held = false
    private var stopped = false
    private var pendingStop: UUID?
    private var starting = false
    private var deliveryDepth = 0
    private var deliveryEngine: IFEngine?
    private var nativeGeneration: UInt64 = 0
    private var rejectionLimiter = VoiceDiagnostics.StartRejectionLimiter()
    var reportStartRejection: (VoiceDiagnostics.StartRejection) -> Void = VoiceDiagnostics.rejectStart
    var foreground: @MainActor () -> VoiceForeground? = VoiceForeground.current
    var currentClient: (() -> IMKTextInput?)?
    var lexicon: () -> VoiceLexiconSnapshot = { IFEngine.voiceLexicon.snapshot }
    var correctionOverride: VoiceSession.Correction?
    var isActive: Bool { token != nil || starting }
    var isDelivering: Bool { deliveryDepth > 0 }
    var blocksRime: Bool { isActive || isDelivering }

    private var shortcutChanges: AnyCancellable?
    func configure(_ controller: IFInputControllerShell) {
        self.controller = controller
        shortcutChanges = controller.settings.shortcuts.$revision.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel(.editing) }
        }
    }


    func controllerActivated() {
        // InputMethodKit may activate a new controller before deactivating the old one.
        if let owner = Self.activeOwner, owner !== self { owner.cancel(.deactivated) }
        cancel(.deactivated)
    }

    func controllerDeactivated(_ sender: IMKTextInput?) {
        guard !isDelivering, ownsVoiceMark, let target, let sender,
              target.proxy == ObjectIdentifier(sender as AnyObject), controller?.secureInput() == false else {
            cancel(.deactivated); return
        }
        // Only this synchronous notification addresses the original client. Never
        // retain the sender for cleanup after activation of another input context.
        let capturedEpoch = epoch
        beginDelivery()
        defer { endDelivery() }
        guard epoch == capturedEpoch else { return }
        cancel(.deactivated)
        guard epoch == capturedEpoch &+ 1, controller?.secureInput() == false else { return }
        sender.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private var pressedModifiers: Set<UInt16> = []
    private var gestureBinding: ShortcutBinding?
    private var firstTapBinding: ShortcutBinding?
    private var gestureGeneration: UInt64 = 0
    private var rightDownAt: TimeInterval?
    private var firstTapDown: TimeInterval?
    private var secondTap = false
    private var cancelHold: (() -> Void)?
    var gestureTime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var scheduleHold: (@escaping @MainActor () -> Void) -> (() -> Void) = { fire in
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            fire()
        }
        return { task.cancel() }
    }

    private func resetGesture() {
        gestureGeneration &+= 1
        cancelHold?(); cancelHold = nil
        rightDownAt = nil; firstTapDown = nil; secondTap = false
        gestureBinding = nil; firstTapBinding = nil
    }

    private func gestureDown(_ binding: ShortcutBinding, holdBinding: ShortcutBinding,
                             toggleBinding: ShortcutBinding, client: IMKTextInput?) -> Bool {
        if rightDownAt != nil { return gestureBinding == binding }
        guard !isDelivering || token != nil else { return false }
        let now = gestureTime()
        secondTap = binding == toggleBinding && firstTapBinding == binding && (firstTapDown.map { now - $0 <= 0.350 } ?? false)
        rightDownAt = now; gestureBinding = binding
        gestureGeneration &+= 1
        let generation = gestureGeneration, expected = epoch, app = foreground()
        if !isActive {
            if let owner = Self.activeOwner, owner !== self { owner.cancel(.deactivated) }
            Self.activeOwner = self
        }
        if binding == holdBinding {
            cancelHold = scheduleHold { [weak self] in
                guard let self, self.epoch == expected, self.gestureGeneration == generation,
                      self.rightDownAt == now, self.controller?.settings.shortcuts.binding(for: .voiceHold) == binding else { return }
                self.firstTapDown = nil; self.firstTapBinding = nil; self.secondTap = false
                guard !self.isActive, !self.isDelivering else { return }
                let current = self.currentClient.map { $0() } ?? self.controller?.client()
                guard let client, let current, ObjectIdentifier(client as AnyObject) == ObjectIdentifier(current as AnyObject),
                      self.foreground() == app else { self.resetGesture(); return }
                self.held = true; self.start(client: client)
                if !self.isActive { self.held = false }
            }
        }
        return true
    }

    private func gestureUp(_ binding: ShortcutBinding, toggleBinding: ShortcutBinding, client: IMKTextInput?) -> Bool {
        guard gestureBinding == binding, let down = rightDownAt else { return false }
        cancelHold?(); cancelHold = nil; rightDownAt = nil; gestureBinding = nil
        if held {
            firstTapDown = nil; firstTapBinding = nil; secondTap = false; held = false; stop(); return true
        }
        guard gestureTime() - down < 0.250 else { firstTapDown = nil; firstTapBinding = nil; secondTap = false; return true }
        if secondTap && binding == toggleBinding {
            firstTapDown = nil; firstTapBinding = nil; secondTap = false
            if isActive { stop() }
            else if !isDelivering { start(client: client) }
        } else if binding == toggleBinding { firstTapDown = down; firstTapBinding = binding }
        return true
    }

    func handle(_ event: NSEvent, client: IMKTextInput?) -> Bool {
        let flags = event.modifierFlags.intersection(ShortcutBinding.relevantFlags)
        let holdBinding = controller?.settings.shortcuts.binding(for: .voiceHold) ?? .rightShift
        let toggleBinding = controller?.settings.shortcuts.binding(for: .voiceToggle) ?? .rightShift
        if event.type == .flagsChanged {
            if flags.isEmpty { pressedModifiers.removeAll() }
            if let changed = ShortcutBinding.allCases.first(where: { $0.keyCode == event.keyCode }) {
                if changed.modifierIsDown(event) { pressedModifiers.insert(event.keyCode) }
                else { pressedModifiers.remove(event.keyCode) }
            }
            if let binding = gestureBinding, !binding.isModifier {
                if flags == binding.flags { return false }
                if !flags.isSubset(of: binding.flags) {
                    cancel(.editing)
                    return false
                }
                // Releasing a chord modifier finishes held dictation but never counts as a tap.
                let wasHeld = held
                held = false; resetGesture()
                if wasHeld { stop() }
                return false
            }
            if let binding = [holdBinding,toggleBinding].first(where: { $0.isModifier && $0.keyCode == event.keyCode }),
               pressedModifiers.count <= 1, !event.modifierFlags.contains(.function), flags.isSubset(of: binding.flags) {
                if binding.modifierIsDown(event) {
                    return gestureDown(binding, holdBinding: holdBinding, toggleBinding: toggleBinding, client: client)
                }
                return gestureUp(binding, toggleBinding: toggleBinding, client: client)
            }
            // Chord taps may release their modifiers between the two presses.
            if let binding = firstTapBinding, !binding.isModifier, flags.isSubset(of: binding.flags) { return false }
            resetGesture()
            if held { cancel(.editing) }
            return false
        }
        if event.type == .keyUp, let binding = gestureBinding, !binding.isModifier, event.keyCode == binding.keyCode {
            return gestureUp(binding, toggleBinding: toggleBinding, client: client)
        }
        if event.type == .keyDown {
            if let binding = [holdBinding,toggleBinding].first(where: { $0.matches(event) }) {
                if event.isARepeat { return gestureBinding == binding }
                if gestureBinding != nil && gestureBinding != binding {
                    resetGesture()
                    if held { cancel(.editing) }
                }
                return gestureDown(binding, holdBinding: holdBinding, toggleBinding: toggleBinding, client: client)
            }
            // A reentrant edit is passed through; retain the held key's release edge.
            if !isDelivering || !held { resetGesture() }
            guard isActive else { return false }
            if event.keyCode == UInt16(kVK_Escape) { cancel(.escape); return true }
            if !isDelivering { cancel(.editing) }
        }
        return false
    }

    private func start(client: IMKTextInput?) {
        func reject(_ reason: VoiceDiagnostics.StartRejection) {
            if rejectionLimiter.admit(reason) { reportStartRejection(reason) }
        }
        guard let controller, let engine = controller.engine, engine.available else {
            reject(.engine); show(.voiceTargetUnavailable, client: client); return
        }
        guard engine.snapshot().preedit.isEmpty, !controller.ownsMarkedText else {
            reject(.busy); show(.voiceTargetUnavailable, client: client); return
        }
        guard !controller.secureInput() else {
            reject(.secure); show(.voiceTargetUnavailable, client: client); return
        }
        guard IFEngine.allSessionsIdle else {
            reject(.busy)
            show(.voiceTargetUnavailable, client: client); return
        }
        guard controller.settings.voice.service.isReady else { show(.voiceNotReady, client: client); return }
        let snapshot = lexicon()
        guard snapshot.availability == .available else { show(.voiceLexiconWaiting, client: client); return }
        guard Self.activeOwner?.isDelivering != true else { reject(.busy); return }
        if let owner = Self.activeOwner, owner !== self { owner.cancel(.deactivated) }
        epoch &+= 1; let expected = epoch
        starting = true; beginDelivery()
        // Client reads can activate another controller before capture completes.
        Self.activeOwner = self
        defer { starting = false; endDelivery() }
        guard let captured = readTarget(epoch: expected, onReject: reject) else {
            guard epoch == expected else { return }
            show(.voiceTargetUnavailable, client: client); return
        }
        guard let client else { reject(.client); show(.voiceTargetUnavailable); return }
        guard captured.proxy == ObjectIdentifier(client as AnyObject) else {
            reject(.proxy); show(.voiceTargetUnavailable, client: client); return
        }
        // TSMDocumentAccess is optional. Unknown selection is not an inability to type.
        let selection = captured.client.selectedRange()
        guard epoch == expected else { reject(.stale); return }
        let unknownSelection = selection.location == NSNotFound && (selection.length == NSNotFound || selection.length == 0)
        guard unknownSelection || AIClientAnchor.valid(selection) else {
            reject(.selection)
            show(.voiceTargetUnavailable, client: client); return
        }
        guard unknownSelection || selection.length == 0 else { reject(.selection); show(.voiceSelectionUnsupported, client: client); return }
        guard epoch == expected else { reject(.stale); return }
        target = captured; nativeGeneration = snapshot.generation; stopped = false; ownsVoiceMark = false
        let configuration = controller.settings.smart.configuration
        let polish = controller.settings.voicePolishEnabled && !(controller.settings.voice.service is VoiceRecognitionFixture)
        var sequence = 0
        var correct: VoiceSession.Correction?
        if polish { correct = { [weak self] text in
            guard let self, self.epoch == expected, let id = self.token else { throw CancellationError() }
            sequence += 1
            let index = sequence, started = ContinuousClock.now
            VoiceDiagnostics.emit(.correcting, id: id, sequence: index)
            do {
                let result: String
                if let injected = self.correctionOverride { result = try await injected(text) }
                else { result = try await VoiceCorrectionClient().correct(text: text, configuration: configuration) }
                try Task.checkCancellation()
                let duration = started.duration(to: .now).components
                VoiceDiagnostics.emit(.corrected, id: id, milliseconds: Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000), sequence: index)
                return result
            } catch {
                if !Task.isCancelled { VoiceDiagnostics.emit(.fallback, id: id, reason: .correction, sequence: index) }
                throw error
            }
        } }
        let model = VoiceSession(correct: correct,
            onPreview: { [weak self] text in self?.preview(text, epoch: expected) },
            onRequestFinalize: { [weak self] id in
                guard let self, self.epoch == expected else { return }
                self.stopped = true
                VoiceDiagnostics.emit(.tail, id: id)
                self.show(.voiceTail)
                self.controller?.settings.voice.service.stop(id: id)
            }, onFinish: { [weak self] outcome in self?.finish(outcome, epoch: expected) })
        session = model
        let id = model.start(); token = id
        controller.ai.invalidate(.commit)
        controller.candidatePresentation?.hideCandidates()
        show(held ? .voiceRecordingHold : .voiceRecordingToggle)
        guard token == id, epoch == expected else { return }
        let phrases = controller.settings.customPhrases
        startTask = Task { @MainActor [weak self] in
            guard let self, self.epoch == expected, self.validate() else { return }
            let callbacks = AppleVoiceRecognizer.Callbacks(
                onFinal: { [weak self] text in
                    guard let self, self.epoch == expected, self.validate() else { return }
                    self.session?.receiveFinal(text, id: id)
                }, onVolatile: { [weak self] text in
                    guard let self, self.epoch == expected, self.validate() else { return }
                    self.session?.receiveVolatile(text, id: id)
                }, onFinalized: { [weak self] text in
                    guard let self, self.epoch == expected, self.validate() else { return }
                    if polish { self.show(.voiceCorrecting) }
                    self.session?.finalized(transcript: text, id: id)
                }, onFailure: { [weak self] in
                    guard let self, self.epoch == expected else { return }
                    self.session?.recognitionFailed(id: id)
                })
            self.controller?.settings.voice.service.start(id: id, snapshot: snapshot.includingCustomPhrases(phrases), callbacks: callbacks)
            if self.epoch == expected, self.stopped { self.controller?.settings.voice.service.stop(id: id) }
        }
    }

    func stop() {
        guard let token, !stopped else { return }
        if isDelivering { pendingStop = token; return }
        stopped = true; session?.stop(id: token)
    }

    func clientRequestedCommit(_ sender: IMKTextInput?) {
        guard isActive else { return }
        VoiceDiagnostics.clientCommit()
        guard !isDelivering else { return }
        guard let sender, let target, target.proxy == ObjectIdentifier(sender as AnyObject) else {
            cancel(.deactivated); return
        }
        cancel(.editing)
    }

    @discardableResult func validate() -> Bool {
        guard let expected = target, token != nil else { return false }
        guard controller?.engine?.available == true, lexicon().generation == nativeGeneration,
              let actual = readTarget(epoch: epoch), expected.sameIdentity(actual) else {
            cancel(controller?.secureInput() == true ? .secureInput : .targetChanged); return false
        }
        return true
    }

    private func preview(_ text: String, epoch expected: UInt64) {
        guard epoch == expected, !isDelivering, validate(), let owned = target else { return }
        let count = text.utf16.count
        guard count <= 16_000 else { cancel(.invalidRange); return }
        beginDelivery()
        defer { endDelivery() }
        ownsVoiceMark = count > 0
        owned.client.setMarkedText(text, selectionRange: NSRange(location: count, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
        guard epoch == expected else { return }
        _ = validate()
    }

    func cancel(_ reason: VoiceDiagnostics.Reason = .deactivated) {
        if reason == .deactivated { pressedModifiers.removeAll() }
        resetGesture()
        held = false
        guard isActive || isDelivering else {
            // A lifecycle callback can arrive inside service.cancel after token removal.
            if reason == .deactivated { epoch &+= 1; cleanupPending = nil }
            return
        }
        let oldToken = token, oldModel = session, oldTarget = ownsVoiceMark ? target : nil
        epoch &+= 1; token = nil; session = nil; target = nil; starting = false; held = false
        let cancellationEpoch = epoch
        ownsVoiceMark = false
        pendingStop = nil
        startTask?.cancel(); startTask = nil
        let lostTarget = reason == .deactivated || reason == .targetChanged || reason == .secureInput
        if lostTarget { cleanupPending = nil }
        if let oldToken {
            oldModel?.cancel(id: oldToken)
            controller?.settings.voice.service.cancel()
            VoiceDiagnostics.emit(.cancelled, id: oldToken, reason: reason)
        }
        if !isDelivering, token == nil, Self.activeOwner === self { Self.activeOwner = nil }
        guard epoch == cancellationEpoch else { return }
        controller?.statusPresentation?.hide()
        if !lostTarget, epoch == cancellationEpoch, let oldTarget {
            if isDelivering { cleanupPending = oldTarget }
            else { clearMark(oldTarget) }
        }
    }

    private func finish(_ outcome: VoiceSession.Outcome, epoch expected: UInt64) {
        guard epoch == expected, let id = token else { return }
        switch outcome {
        case .cancelled: cancel(.deactivated)
        case .failed:
            cancel(.recognition); show(.voiceFailed)
        case .completed(let text, let fallback):
            guard validate(), let owned = target else { return }
            if text.isEmpty { cancel(.none); return }
            beginDelivery()
            defer { endDelivery() }
            cleanupPending = ownsVoiceMark ? owned : nil
            resetGesture()
            epoch &+= 1; token = nil; session = nil; target = nil; held = false
            ownsVoiceMark = false
            pendingStop = nil
            startTask?.cancel(); startTask = nil
            let deliveryEpoch = epoch
            controller?.settings.voice.service.cancel()
            guard epoch == deliveryEpoch else { return }
            guard let actual = readTarget(epoch: deliveryEpoch), owned.sameIdentity(actual) else {
                cleanupPending = nil
                controller?.statusPresentation?.hide()
                return
            }
            cleanupPending = nil
            // Model ownership is gone before the client callback; nested commit/finish cannot insert twice.
            VoiceDiagnostics.emit(.submitted, id: id)
            owned.client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            guard epoch == deliveryEpoch else { return }
            controller?.statusPresentation?.hide()
            if fallback { show(.voiceFallback, client: owned.client) }
        }
    }

    private func beginDelivery() {
        if deliveryDepth == 0 { deliveryEngine = controller?.engine; deliveryEngine?.beginDelivery() }
        deliveryDepth += 1
    }

    private func endDelivery() {
        deliveryDepth = max(0, deliveryDepth - 1)
        if deliveryDepth == 0 { deliveryEngine?.endDelivery(); deliveryEngine = nil }
        if deliveryDepth == 0, let pending = cleanupPending {
            cleanupPending = nil; clearMark(pending)
        }
        if deliveryDepth == 0, let pending = pendingStop {
            pendingStop = nil
            if token == pending { stop() }
        }
        if deliveryDepth == 0, token == nil, Self.activeOwner === self { Self.activeOwner = nil }
    }

    private func clearMark(_ owned: Target) {
        guard let actual = readTarget(epoch: epoch), owned.sameIdentity(actual) else { return }
        beginDelivery()
        defer { endDelivery() }
        owned.client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func readTarget(epoch expected: UInt64,
                            onReject: ((VoiceDiagnostics.StartRejection) -> Void)? = nil) -> Target? {
        func accept(_ valid: @autoclosure () -> Bool, _ reason: VoiceDiagnostics.StartRejection) -> Bool {
            guard epoch == expected else { onReject?(.stale); return false }
            let accepted = valid()
            guard epoch == expected else { onReject?(.stale); return false }
            guard accepted else { onReject?(reason); return false }
            return true
        }
        guard let controller else { onReject?(.engine); return nil }
        guard accept(!controller.secureInput(), .secure) else { return nil }
        let client = currentClient.map { $0() } ?? controller.client()
        guard accept(client != nil, .client), let client else { return nil }
        let bundle = client.bundleIdentifier()
        guard accept(bundle?.isEmpty == false, .bundle), let bundle else { return nil }
        let app = foreground()
        guard accept(app?.bundleID == bundle && (app?.pid ?? 0) > 0, .foreground), let app else { return nil }
        let finalBundle = client.bundleIdentifier()
        guard accept(finalBundle == bundle, .bundle) else { return nil }
        let finalClient = currentClient.map { $0() } ?? controller.client()
        guard accept(finalClient != nil, .client), let finalClient,
              accept(ObjectIdentifier(finalClient as AnyObject) == ObjectIdentifier(client as AnyObject), .proxy) else { return nil }
        let finalApp = foreground()
        guard accept(finalApp == app, .foreground), accept(!controller.secureInput(), .secure) else { return nil }
        return Target(client: client, proxy: ObjectIdentifier(client as AnyObject), app: app)
    }

    private func show(_ status: InputStatus, client: IMKTextInput? = nil) {
        let expected = epoch
        controller?.statusPresentation?.present(status, client: client ?? target?.client ?? controller?.client(),
                                                characterIndex: 0)
        if epoch != expected { controller?.statusPresentation?.hide() }
    }
}
