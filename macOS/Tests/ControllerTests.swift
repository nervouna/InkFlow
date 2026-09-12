import InputMethodKit
#if SWIFT_PACKAGE
@testable import InkFlowCore
import InkFlowNativeTestSupport
import InkFlowTestSupport
#endif

@MainActor
private final class RecordingInputStatusPresentation: InputStatusPresenting {
    private(set) var records: [(InputStatus, ObjectIdentifier?, Int)] = []
    private(set) var hideCount = 0

    func present(_ status: InputStatus, client: IMKTextInput?, characterIndex: Int) {
        records.append((status, client.map { ObjectIdentifier($0 as AnyObject) }, characterIndex))
    }

    func hide() { hideCount += 1 }
}

@MainActor
private final class RecordingThunderPresentation: ThunderPresenting {
    private(set) var records: [(ThunderBurst, ObjectIdentifier?, Int)] = []
    private(set) var hideCount = 0

    func burst(_ burst: ThunderBurst, client: IMKTextInput?, characterIndex: Int) {
        records.append((burst, client.map { ObjectIdentifier($0 as AnyObject) }, characterIndex))
    }

    func hide() { hideCount += 1 }
}

@MainActor
private final class RecordingThunderPanel: ThunderPanelPresenting {
    private(set) var bursts: [ThunderBurst] = []
    private(set) var caretRects: [NSRect] = []
    private(set) var hideCount = 0

    func burst(_ burst: ThunderBurst, at caretRect: NSRect) {
        bursts.append(burst)
        caretRects.append(caretRect)
    }

    func hide() { hideCount += 1 }
}

@main
struct ControllerTests {
    @MainActor static func main() throws {
        check(CommandLine.arguments.count == 3)
        let isolated = IsolatedSettings()
        defer { isolated.cleanup() }
        try IFEngine.start(shared: CommandLine.arguments[1], user: CommandLine.arguments[2])
        IFStubHeadlessControllerFramework()
        contextReading()
        runCases(settings: isolated.settings)
        inputSettings(settings: isolated.settings)
        leftShiftSwitching(settings: isolated.settings)
        controlShortcuts(settings: isolated.settings)
        thunderMode(settings: isolated.settings)
        statusPanelPositioning()
        outsideCompositionClick(settings: isolated.settings)
        rawProtection(settings: isolated.settings)
        try customPhrases(settings: isolated.settings)
        try customPhraseFailure(settings: isolated.settings, user: CommandLine.arguments[2])
        contextReranking(settings: isolated.settings)
        try deliveryAndRecovery(settings: isolated.settings, shared: CommandLine.arguments[1], user: CommandLine.arguments[2])
        IFEngine.stop()
        print("PASS controller: idle client unchanged, Escape clears owned mark once, commit inserts once without empty replacement, consecutive quotes and shifted punctuation")
    }

    @MainActor static func inputSettings(settings: IFSettings) {
        let client = RecordingClient()
        let controller = InkFlowInputController(server: nil, delegate: nil, client: client,
            settings: settings, settingsWindow: IFSettingsWindowController(settings: settings))!
        let other = InkFlowInputController(server: nil, delegate: nil, client: RecordingClient(),
            settings: settings, settingsWindow: IFSettingsWindowController(settings: settings))!
        let engine = controller.engine!
        for letter in "hulianwang" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
        let before = engine.snapshot()
        client.mutations.removeAll()
        controller.toggleTraditional(nil)
        controller.toggleEnglishPunctuation(nil)
        controller.toggleInputMode(nil)
        check(engine.snapshot() == before && !engine.asciiMode && engine.requestedASCIIMode)
        check(!client.mutations.contains { $0.hasPrefix("insert:") }, "Menu changes must not commit live composition")
        check(other.engine!.inputPreferences?[.traditional] == true && !other.engine!.asciiMode,
              "Traditional and punctuation are global; ASCII remains per session")
        let menu = controller.menu()!
        guard let modeItem = menu.items.first(where: { $0.title == "切换到中文输入" }) else {
            check(false, "Input menu must expose the mode toggle")
            return
        }
        let punctuationItem = menu.items.first { $0.title == "英文标点" }!
        let traditionalItem = menu.items.first { $0.title == "繁体输入" }!
        check(modeItem.keyEquivalent == "⇧" && modeItem.keyEquivalentModifierMask.isEmpty &&
              !modeItem.allowsAutomaticKeyEquivalentLocalization,
              "Modifier-only left Shift must use a separate right-side annotation")
        check(traditionalItem.keyEquivalent == "f" &&
              traditionalItem.keyEquivalentModifierMask == [.control, .shift],
              "Traditional toggle must expose Control-Shift-F in the native shortcut column")
        check(punctuationItem.keyEquivalent == "." && punctuationItem.keyEquivalentModifierMask == .control,
              "Punctuation toggle must expose Control-period in the native shortcut column")
        check(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.indentationLevel == 0 },
              "Every menu item must stay at the menu's root indentation level")
        check(menu.index(of: punctuationItem) < menu.index(of: traditionalItem),
              "Adding shortcut annotations must preserve the existing state-item order")
        check(punctuationItem.state == .on)
        check(traditionalItem.state == .on)
        client.mutations.removeAll()
        check(controller.handle(keyEvent(49, " "), client: client))
        check(client.mutations == ["insert:互联网"] && engine.asciiMode)
        check(!controller.handle(keyEvent(33, "{", .shift), client: client))
        controller.toggleInputMode(nil)
        for letter in "hulianwang" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
        check(engine.snapshot().candidates.first == "互聯網")
        client.mutations.removeAll()
        check(controller.handle(modifierEvent(56, .shift), client: client))
        check(controller.handle(modifierEvent(56), client: client))
        check(client.mutations.allSatisfy { !$0.hasPrefix("insert:") } && !engine.asciiMode)
        check(controller.handle(keyEvent(53, ""), client: client))
        check(engine.asciiMode)
        controller.toggleInputMode(nil)
        settings.setInputOption(.traditional, enabled: false)
        settings.setInputOption(.englishPunctuation, enabled: false)
        check(controller.menu()!.items.first { $0.title == "繁体输入" }?.state == .off)
        print("PASS controller input preferences: menu/UI global synchronization, session ASCII scope, deferred menu and shortcut, one old commit and cancellation")
    }

    @MainActor static func leftShiftSwitching(settings: IFSettings) {
        let client = RecordingClient(document: "")
        let status = RecordingInputStatusPresentation()
        let controller = InkFlowInputController(server: nil, delegate: nil, client: client,
            settings: settings, settingsWindow: IFSettingsWindowController(settings: settings),
            statusPresentation: status)!
        let engine = controller.engine!
        let masks = NSEvent.EventTypeMask(rawValue: UInt64(controller.recognizedEvents(client)))
        check(masks.contains(.keyDown) && masks.contains(.flagsChanged),
              "Input controller must request key-down and modifier-change events")

        check(controller.handle(modifierEvent(56, .shift), client: client))
        check(!engine.requestedASCIIMode, "Left Shift press arms without switching early")
        check(controller.handle(modifierEvent(56), client: client))
        check(engine.asciiMode, "A standalone left Shift press-release toggles English mode")
        check(status.records.map(\.0) == [.english] && status.records[0].1 == ObjectIdentifier(client) &&
              status.records[0].2 == 0,
              "Left Shift must present the resulting English state for the active client")
        controller.hidePalettes()
        check(status.hideCount == 1, "Hiding input palettes must immediately dismiss status feedback")

        check(!controller.handle(modifierEvent(60, .shift), client: client))
        check(!controller.handle(modifierEvent(60), client: client))
        check(engine.asciiMode, "Right Shift does not toggle input mode")

        check(!controller.handle(modifierEvent(56, [.shift, .function]), client: client))
        check(!controller.handle(modifierEvent(56, .function), client: client))
        check(engine.asciiMode, "Function-modified left Shift does not toggle input mode")

        check(!controller.handle(keyEvent(49, " ", [.control, .shift]), client: client))
        check(engine.asciiMode, "The replaced Control-Shift-Space shortcut no longer toggles")

        controller.toggleInputMode(nil)
        check(controller.handle(modifierEvent(56, .shift), client: client))
        check(controller.handle(keyEvent(0, "A", .shift), client: client))
        check(!controller.handle(modifierEvent(56), client: client))
        check(!engine.requestedASCIIMode && engine.qualitySnapshot().rawInput == "A",
              "Left Shift used as a letter modifier preserves uppercase input without toggling")
        engine.clear()
        controller.refresh(client)

        for letter in "nihao" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
        let composing = engine.snapshot()
        check(controller.handle(modifierEvent(56, .shift), client: client))
        check(controller.handle(modifierEvent(56), client: client))
        check(engine.requestedASCIIMode && !engine.asciiMode && engine.snapshot() == composing,
              "Left Shift defers mode changes until the current composition finishes")
        check(status.records.map(\.0) == [.english, .english] && status.records[1].2 == composing.cursor,
              "Deferred left Shift must present the requested state at the active composition cursor")
        check(controller.handle(keyEvent(49, " "), client: client))
        check(client.document == "你好" && engine.asciiMode,
              "Deferred left Shift commits the old composition once before switching: \(String(describing: client.document)), ascii=\(engine.asciiMode)")
        check(controller.handle(modifierEvent(56, .shift), client: client))
        check(controller.handle(modifierEvent(56), client: client))
        check(!engine.asciiMode && status.records.map(\.0) == [.english, .english, .chinese] &&
              status.records[2].2 == 0,
              "Left Shift must also present the resulting Chinese state at the idle insertion point")
        print("PASS left Shift switching: recognized events, left-only toggle, right/modified/legacy exclusions, deferred composition")
    }

    @MainActor static func controlShortcuts(settings: IFSettings) {
        settings.setInputOption(.traditional, enabled: false)
        settings.setInputOption(.englishPunctuation, enabled: false)
        let client = RecordingClient(document: "")
        let status = RecordingInputStatusPresentation()
        let controller = InkFlowInputController(server: nil, delegate: nil, client: client,
            settings: settings, settingsWindow: IFSettingsWindowController(settings: settings),
            statusPresentation: status)!

        check(!controller.handle(keyEvent(3, "f", .control), client: client) &&
              !settings.inputPreferences[.traditional] && status.records.isEmpty,
              "Control-F must pass through without toggling or presenting status")
        for letter in "ni" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
        let composing = controller.engine!.snapshot()
        check(controller.handle(keyEvent(3, "f", [.control, .shift]), client: client))
        check(settings.inputPreferences[.traditional] && controller.engine?.inputPreferences?[.traditional] == false &&
              controller.engine?.snapshot() == composing,
              "Control-Shift-F must be consumed and defer the requested traditional state while composing")
        check(status.records.map(\.0) == [.traditional] && status.records[0].2 == composing.cursor,
              "Control-Shift-F must present the requested traditional state at the composition cursor")
        check(controller.handle(keyEvent(3, "f", [.control, .shift], repeated: true), client: client))
        check(settings.inputPreferences[.traditional] && status.records.map(\.0) == [.traditional],
              "A repeated Control-Shift-F event must be consumed without toggling or presenting again")

        check(controller.handle(keyEvent(47, ".", .control), client: client))
        check(settings.inputPreferences[.englishPunctuation] && controller.engine?.inputPreferences?[.englishPunctuation] == false &&
              controller.engine?.snapshot() == composing,
              "Control-period must be consumed and defer application of the requested punctuation state while composing")
        check(status.records.map(\.0) == [.traditional, .englishPunctuation] && status.records[1].2 == composing.cursor,
              "Control-period must present the requested punctuation state at the composition cursor")
        let requestedMenu = controller.menu()!
        check(requestedMenu.items.first { $0.title == "繁体输入" }?.state == .on &&
              requestedMenu.items.first { $0.title == "英文标点" }?.state == .on,
              "Menu state must follow the requested shortcut state while engine application is deferred")
        check(controller.handle(keyEvent(53, ""), client: client))
        check(controller.engine?.inputPreferences?[.traditional] == true &&
              controller.engine?.inputPreferences?[.englishPunctuation] == true,
              "Deferred Control shortcut states must apply when composition becomes idle")

        check(!controller.handle(keyEvent(3, "f", [.control, .shift, .option]), client: client))
        check(!controller.handle(keyEvent(47, ".", [.control, .option]), client: client))
        check(settings.inputPreferences[.traditional] && settings.inputPreferences[.englishPunctuation],
              "Control shortcuts with additional modifiers must pass through without changing state")

        check(controller.handle(keyEvent(3, "f", [.control, .shift, .capsLock]), client: client))
        check(controller.handle(keyEvent(47, ".", [.control, .capsLock]), client: client))
        check(!settings.inputPreferences[.traditional] && !settings.inputPreferences[.englishPunctuation] &&
              status.records.map(\.0) == [.traditional, .englishPunctuation, .simplified, .chinesePunctuation],
              "Caps Lock must not prevent exact Control shortcuts from toggling to the resulting states")

        controller.toggleTraditional(nil)
        controller.toggleEnglishPunctuation(nil)
        check(status.records.suffix(2).map(\.0) == [.traditional, .englishPunctuation] &&
              status.records.suffix(2).allSatisfy {
                  $0.1 == ObjectIdentifier(client) && $0.2 == 0
              },
              "Menu-dispatched Control shortcuts must present their resulting states at the active caret")
        settings.setInputOption(.traditional, enabled: false)
        settings.setInputOption(.englishPunctuation, enabled: false)

        print("PASS Control shortcuts: consumed exact chords, synchronized requested settings and status presentation, rejected extra modifiers")
    }

    @MainActor static func statusPanelPositioning() {
        check(InputStatusLayout.fontSize == 10 && InputStatusLayout.padding == 4,
              "Status panel typography and padding must match the compact UI specification")
        check(InputStatusLayout.panelSize(for: NSSize(width: 20.25, height: 11.5)) ==
              NSSize(width: 29, height: 20) &&
              InputStatusLayout.panelSize(for: NSSize(width: 40.25, height: 15.5)) ==
              NSSize(width: 49, height: 24),
              "Status panel width and height must adapt to the measured label size")
        check(InputStatusLayout.contentFrame(in: NSSize(width: 29, height: 20)) ==
              NSRect(x: 4, y: 4, width: 21, height: 12),
              "Status panel must apply four points of padding on every edge")
        let screen = NSRect(x: 0, y: 0, width: 600, height: 400)
        let size = NSSize(width: 100, height: 40)
        check(InputStatusPanel.position(caretRect: NSRect(x: 250, y: 180, width: 2, height: 20),
                                        panelSize: size, screens: [screen]) ==
              NSRect(x: 201, y: 208, width: 100, height: 40),
              "Status panel must center above the insertion caret")
        check(InputStatusPanel.position(caretRect: NSRect(x: 2, y: 360, width: 2, height: 20),
                                        panelSize: size, screens: [screen]) ==
              NSRect(x: 0, y: 312, width: 100, height: 40),
              "Status panel must fall below the caret and clamp to the visible screen when above does not fit")
        check(InputStatusPanel.position(caretRect: .zero, panelSize: size, screens: [screen]) == nil,
              "Invalid caret geometry must suppress status presentation")
        let client = RecordingClient()
        client.caretRect = NSRect(x: 80, y: 90, width: 1, height: 18)
        check(NativeInputStatusPresentation.caretRect(for: client, characterIndex: 4) == client.caretRect &&
              client.attributeIndexes == [4],
              "Caret resolution must query the controller-provided composition cursor index")
        client.caretRect = .zero
        check(NativeInputStatusPresentation.caretRect(for: client, characterIndex: 0) == nil,
              "Caret resolution must reject an invalid client rectangle")
        let leftScreen = NSRect(x: -600, y: 0, width: 600, height: 400)
        check(ThunderPanel.screen(for: NSRect(x: -120, y: 90, width: 1, height: 18),
                                  screens: [screen, leftScreen]) == leftScreen,
              "Thunder overlay must select the screen containing the caret")
        check(ThunderPanel.screen(for: .zero, screens: [screen]) == nil,
              "Thunder overlay must reject invalid caret geometry")
        let reducedMotionClient = RecordingClient()
        let reducedMotion = NativeThunderPresentation(reduceMotion: { true })
        reducedMotion.burst(.commit, client: reducedMotionClient, characterIndex: 0)
        check(reducedMotionClient.attributeIndexes.isEmpty,
              "Reduce Motion must suppress decorative work before querying caret geometry")
        let thunderPanel = RecordingThunderPanel()
        var deferred: [@MainActor () -> Void] = []
        let uninterrupted = NativeThunderPresentation(reduceMotion: { false },
            scheduleAfterClientLayout: { deferred.append($0) }, panelFactory: { thunderPanel })
        reducedMotionClient.caretRect = NSRect(x: 20, y: 90, width: 1, height: 18)
        uninterrupted.burst(.commit, client: reducedMotionClient, characterIndex: 0)
        check(thunderPanel.bursts.isEmpty && reducedMotionClient.attributeIndexes.isEmpty && deferred.count == 1,
              "Commit feedback must wait for the client to finish its text layout")
        reducedMotionClient.caretRect = NSRect(x: 80, y: 90, width: 1, height: 18)
        deferred.removeFirst()()
        reducedMotionClient.caretRect = .zero
        uninterrupted.burst(.preedit, client: reducedMotionClient, characterIndex: 0)
        check(thunderPanel.bursts == [.commit] && thunderPanel.caretRects == [NSRect(x: 80, y: 90, width: 1, height: 18)] &&
              thunderPanel.hideCount == 0,
              "Commit feedback must use the post-layout caret and a later failed lookup must not interrupt it")
        let cancelledPanel = RecordingThunderPanel()
        var cancelledDeferred: [@MainActor () -> Void] = []
        let cancelled = NativeThunderPresentation(reduceMotion: { false },
            scheduleAfterClientLayout: { cancelledDeferred.append($0) }, panelFactory: { cancelledPanel })
        reducedMotionClient.caretRect = NSRect(x: 100, y: 90, width: 1, height: 18)
        cancelled.burst(.commit, client: reducedMotionClient, characterIndex: 0)
        cancelled.hide()
        cancelledDeferred.removeFirst()()
        check(cancelledPanel.bursts.isEmpty,
              "Hiding feedback must cancel a commit burst that is still waiting for client layout")
        print("PASS status panel positioning: above-caret placement, visible-screen fallback and invalid-caret suppression")
    }

    @MainActor static func thunderMode(settings: IFSettings) {
        settings.thunderMode = false
        let client = RecordingClient(document: "")
        let thunder = RecordingThunderPresentation()
        let controller = InkFlowInputController(server: nil, delegate: nil, client: client,
            settings: settings, settingsWindow: IFSettingsWindowController(settings: settings),
            thunderPresentation: thunder)!

        check(controller.handle(keyEvent(45, "n"), client: client))
        check(thunder.records.isEmpty, "Thunder mode must remain inert by default")
        settings.thunderMode = true
        check(controller.handle(keyEvent(34, "i"), client: client))
        check(thunder.records.map(\.0) == [.preedit] && thunder.records[0].1 == ObjectIdentifier(client) &&
              thunder.records[0].2 == 1,
              "Adding preedit text must query the last valid character before the composition cursor")
        check(controller.handle(keyEvent(51, "\u{8}"), client: client))
        check(thunder.records.count == 1, "Deleting preedit text must not burst")
        check(controller.handle(keyEvent(0, "a"), client: client))
        check(thunder.records.map(\.0) == [.preedit, .preedit])
        check(controller.handle(keyEvent(49, " "), client: client))
        check(thunder.records.map(\.0) == [.preedit, .preedit, .commit] && thunder.records.last?.2 == 0,
              "A composition commit must request the post-layout current selection")
        check(controller.handle(keyEvent(39, "\"", .shift), client: client))
        check(thunder.records.map(\.0).suffix(2) == [.commit, .commit],
              "Direct punctuation insertion must count as text reaching the client")

        settings.thunderMode = false
        check(controller.handle(keyEvent(45, "n"), client: client))
        check(thunder.records.count == 4, "Disabling Thunder mode must take effect immediately")
        settings.thunderMode = false
        print("PASS Thunder mode triggers: default-off, preedit growth and commit bursts, deletion suppression, live disable")
    }

    @MainActor static func outsideCompositionClick(settings: IFSettings) {
        let client = RecordingClient(document: "前")
        let controller = InkFlowInputController(server: nil, delegate: nil, client: client,
            settings: settings, settingsWindow: IFSettingsWindowController(settings: settings))!
        for letter in "nihao" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
        let originalMark = client.markedRange()
        var tracking = ObjCBool(true)
        check(!IFSendMouseDown(controller, 0, client, &tracking))
        check(!tracking.boolValue && client.document == "前你好" && client.markedRange().location == NSNotFound,
              "Clicking outside the marked range must commit once and leave click handling to the client")
        check(client.insertions.count == 1 && client.insertions[0].markedRange == originalMark,
              "The outside click must commit at the original marked range exactly once")

        client.selection = NSRange(location: 0, length: 0)
        for letter in "wo" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
        check(controller.handle(keyEvent(49, " "), client: client))
        check(client.document == "我前你好", "Input after the click must start at the client's new insertion point")

        for letter in "ni" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
        let insideMark = client.markedRange(), before = client.document
        tracking = true
        check(!IFSendMouseDown(controller, UInt(insideMark.location), client, &tracking))
        check(!tracking.boolValue && client.document == before && client.markedRange() == insideMark,
              "Clicking inside the marked range must preserve the active composition")
        print("PASS native IMKMouseHandling callback: outside commit, original-range insertion, subsequent clicked input, inside preservation")
    }

    @MainActor static func rawProtection(settings: IFSettings) {
        for (raw, mustBeUnknown) in [("getUserName", false), ("InkFlowQuasar", true)] {
            let client = RecordingClient(document: "")
            let controller = InkFlowInputController(server: nil, delegate: nil, client: client,
                settings: settings, settingsWindow: IFSettingsWindowController(settings: settings))!
            for character in raw {
                let text = String(character)
                let flags: NSEvent.ModifierFlags = character.isUppercase ? .shift : []
                check(controller.handle(keyEvent(0, text, flags), client: client), "Compose raw alphabetic input \(raw)")
            }
            check(controller.engine?.qualitySnapshot().rawInput == raw, "Raw identity must retain typed case for \(raw)")
            if mustBeUnknown {
                check(!(controller.candidates(nil) as? [String] ?? []).contains(raw), "Project word fixture must stay outside dictionaries")
            }
            client.mutations.removeAll()
            check(controller.handle(keyEvent(36, "\r"), client: client), "Return must commit raw input \(raw)")
            check(client.document == raw && client.mutations == ["insert:" + raw],
                  "Return must insert the original alphabetic bytes exactly once for \(raw)")
        }
        print("PASS raw protection: Return commits camel-case identifier and unknown project word exactly")
    }

    @MainActor static func deliveryAndRecovery(settings: IFSettings, shared: String, user: String) throws {
        // Earlier headless IMK fixtures can remain autoreleased with deliberate test compositions.
        for engine in IFEngine.liveSessions { engine.clear(); _ = engine.takeCommit() }
        check(IFEngine.allSessionsIdle, "Delivery fixture has no other composing or pending session")
        let client = RecordingClient()
        var controller: InkFlowInputController? = InkFlowInputController(server: nil, delegate: nil, client: client,
            settings: settings, settingsWindow: IFSettingsWindowController(settings: settings))!
        var callbacks = 0
        client.onMutation = {
            callbacks += 1
            check(!IFEngine.allSessionsIdle, "Delivery lease blocks activation inside insert/mark callback")
            // Native clients may pump a nested event loop before returning the commit callback.
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            check(!IFEngine.allSessionsIdle, "Lease remains owned across nested client run loop")
        }
        type(controller!.engine!, "nihao"); controller!.refresh(client)
        controller!.engine!.commit(); controller!.refresh(client)
        check(callbacks >= 2 && IFEngine.allSessionsIdle, "Lease ends after all client callbacks return")
        client.onMutation = nil; controller = nil
        IFEngine.stop()
        controller = InkFlowInputController(server: nil, delegate: nil, client: client,
            settings: settings, settingsWindow: IFSettingsWindowController(settings: settings))!
        check(controller!.engine == nil, "Controller can be constructed while engine is unavailable")
        settings.candidateCount = 7
        _ = try settings.saveCustomPhrase(code: "hft", text: "恢复隔离短语")
        try IFEngine.start(shared: shared, user: user)
        check(controller!.engine?.available == true && controller!.engine?.candidateCount == 7, "Existing controller reacquires restored session and count")
        type(controller!.engine!, "hft")
        check(controller!.engine!.snapshot().candidates.first == "恢复隔离短语", "Reacquired session receives current custom phrases")
        controller!.engine!.clear()
        print("PASS controller activation: insert/mark nested-runloop delivery lease and unavailable-controller reacquisition")
    }

    @MainActor static func customPhraseFailure(settings: IFSettings, user: String) throws {
        let client = RecordingClient()
        let controller = InkFlowInputController(server: nil, delegate: nil, client: client,
                                                settings: settings, settingsWindow: IFSettingsWindowController(settings: settings))!
        let engine = controller.engine!
        let files = FileManager.default
        let permissions = try files.attributesOfItem(atPath: user)[.posixPermissions]!
        let phrase: CustomPhrase, warning: String?, handled: Bool, retained: Bool
        do {
            try files.setAttributes([.posixPermissions: 0o500], ofItemAtPath: user)
            defer {
                do { try files.setAttributes([.posixPermissions: permissions], ofItemAtPath: user) }
                catch { check(false, "Cannot restore temporary directory permissions: \(error)") }
            }
            phrase = try settings.saveCustomPhrase(code: "dz", text: "警告恢复后的地址")
            warning = settings.inputSettingsError
            handled = controller.handle(keyEvent(0, "d"), client: client)
            retained = settings.inputSettingsError == warning && engine.configurationError == warning
        }
        // Check after the defer restored permissions, including on the expected RED run.
        check(warning != nil, "An unwritable phrase directory must produce a settings warning")
        check(handled && !engine.snapshot().preedit.isEmpty)
        check(retained, "CP-001: typing must retain the warning while failed settings remain deferred")
        check(controller.handle(keyEvent(0, "z"), client: client))
        check(settings.inputSettingsError == warning, "Restored permissions alone must not clear a deferred warning")
        check(controller.handle(keyEvent(53, ""), client: client))
        check(settings.inputSettingsError == nil && engine.configurationError == nil)
        for letter in "dz" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
        check(engine.snapshot().candidates.first == phrase.text)
        check(controller.handle(keyEvent(53, ""), client: client))

        let failedAgain: Bool, reverted: Bool
        do {
            try files.setAttributes([.posixPermissions: 0o500], ofItemAtPath: user)
            defer {
                do { try files.setAttributes([.posixPermissions: permissions], ofItemAtPath: user) }
                catch { check(false, "Cannot restore temporary directory permissions: \(error)") }
            }
            try settings.saveCustomPhrase(id: phrase.id, code: phrase.code, text: "尚未载入的修改")
            failedAgain = settings.inputSettingsError != nil
            try settings.saveCustomPhrase(id: phrase.id, code: phrase.code, text: phrase.text)
            reverted = settings.inputSettingsError == nil && engine.configurationError == nil
        }
        check(failedAgain && reverted, "Returning to the already-applied configuration must clear the warning")
        try settings.deleteCustomPhrase(id: phrase.id)
        print("PASS CP-001: write failure warning survives typing/deferred reload, clears after successful idle retry or return to applied settings")
    }

    @MainActor static func customPhrases(settings: IFSettings) throws {
        let client = RecordingClient()
        let controller = InkFlowInputController(server: nil, delegate: nil, client: client,
                                                settings: settings, settingsWindow: IFSettingsWindowController(settings: settings))!
        let engine = controller.engine!
        let phrase = try settings.saveCustomPhrase(code: "dz", text: "原地址")
        for letter in "dz" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
        check(controller.candidates(nil) as? [String] == engine.snapshot().candidates)
        check(engine.snapshot().candidates.first == "原地址")
        let old = engine.snapshot()
        client.mutations.removeAll()
        try settings.saveCustomPhrase(id: phrase.id, code: "dz", text: "新地址")
        settings.candidateCount = 3
        check(engine.snapshot() == old && engine.candidateCount == 5)
        check(!client.mutations.contains { $0.hasPrefix("insert:") }, "Settings must not commit composition")
        client.mutations.removeAll()
        check(controller.handle(keyEvent(18, "1"), client: client))
        check(client.mutations == ["insert:原地址"])
        check(engine.candidateCount == 3 && settings.inputSettingsError == nil)
        for letter in "dz" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
        check(engine.snapshot().candidates.first == "新地址")
        client.mutations.removeAll()
        controller.candidateSelected(NSAttributedString(string: "新地址"))
        check(client.mutations == ["insert:新地址"], "Native candidate callback inserts custom phrase exactly once")
        controller.commitComposition(client)
        check(client.mutations == ["insert:新地址"])
        try settings.deleteCustomPhrase(id: phrase.id)
        for letter in "dz" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
        check(!engine.snapshot().candidates.contains("新地址"))
        check(controller.handle(keyEvent(53, ""), client: client))
        settings.candidateCount = 5
        print("PASS custom phrase controller: settings notifications, deferred phrase/count reload, old composition commits once, updated next input, native click callback, deletion")
    }

    @MainActor static func contextReading() {
        func read(_ client: RecordingClient, owned: Bool = false) -> String {
            IFPrecedingText.read(from: client, ownsMarkedText: owned, secureInput: false)
        }
        let client = RecordingClient(document: "😀准备午被选中后文")
        client.selection = NSRange(location: 5, length: 3)
        check(read(client) == "😀准备午")
        check(client.requests.last == NSRange(location: 0, length: 5))
        client.updatesActualRange = false
        check(read(client) == "😀准备午", "Exact requests need no adjusted actualRange")
        client.mark = NSRange(location: 5, length: 3)
        client.selection = NSRange(location: 7, length: 0)
        check(read(client, owned: true) == "😀准备午")
        check(read(client).isEmpty, "A foreign mark is not preceding committed text")
        client.selection = NSRange(location: 9, length: 0)
        check(read(client, owned: true).isEmpty)
        client.mark = NSRange(location: NSNotFound, length: 0)
        for invalid in [NSRange(location: NSNotFound, length: 0), NSRange(location: 0, length: NSNotFound),
                        NSRange(location: -1, length: 0), NSRange(location: Int.max - 1, length: 4)] {
            client.selection = invalid; check(read(client).isEmpty)
        }
        let bounded = RecordingClient(document: "😀" + String(repeating: "前", count: 12) + "准备午")
        bounded.substringResponse = { request in
            check(request == NSRange(location: 1, length: 16))
            return (bounded.document, NSRange(location: 0, length: 17))
        }
        check(read(bounded) == bounded.document, "Expanded surrogate pair at the prefix start")
        bounded.substringResponse = { _ in ("准备午", NSRange(location: 14, length: 3)) }
        check(read(bounded) == "准备午", "Shorter available prefix ending exactly at the caret")
        for response in [("准备午", NSRange(location: 14, length: 2)),
                         ("准备午", NSRange(location: 13, length: 3)),
                         ("准备午", NSRange(location: NSNotFound, length: 3)),
                         ("准备午", NSRange(location: Int.max - 1, length: 3))] {
            bounded.substringResponse = { _ in response }; check(read(bounded).isEmpty)
        }
        let split = RecordingClient(document: "前😀")
        split.selection = NSRange(location: 2, length: 0)
        split.substringResponse = { _ in ("前😀", NSRange(location: 0, length: 3)) }
        check(read(split).isEmpty, "Never cut a surrogate pair at the caret")
        let requests = client.requests.count
        check(IFPrecedingText.read(from: client, ownsMarkedText: false, secureInput: true).isEmpty)
        check(client.requests.count == requests, "Secure event input must not request document text")
        check(IFPrecedingText.read(from: nil, ownsMarkedText: false, secureInput: false).isEmpty)
        client.contextAvailable = false; client.selection = NSRange(location: 5, length: 0)
        check(read(client).isEmpty)
        print("PASS context reading: bounded UTF-16, emoji, selection, owned/foreign marks, adjusted/unmodified/malformed ranges, nil/unavailable/secure clients")
    }

    @MainActor static func contextReranking(settings: IFSettings) {
        func prepared(_ prefix: String = "准备午") -> (InkFlowInputController, RecordingClient) {
            let client = RecordingClient(document: prefix)
            let controller = InkFlowInputController(server: nil, delegate: nil, client: client,
                                                    settings: settings, settingsWindow: IFSettingsWindowController(settings: settings))!
            for character in "can" { check(controller.handle(keyEvent(0, String(character)), client: client)) }
            return (controller, client)
        }
        for action in ["space", "digit", "click", "arrow", "panel-highlight", "comma", "return", "shortcut", "toggle", "commit", "deactivate"] {
            let (controller, client) = prepared()
            let candidates = controller.candidates(nil) as! [String]
            check(candidates.first == "餐")
            check(client.mark.location == 3 && client.document == "准备午can")
            client.mutations.removeAll()
            var expected = "餐"
            switch action {
            case "space": check(controller.handle(keyEvent(49, " "), client: client))
            case "digit": check(controller.handle(keyEvent(18, "1"), client: client))
            case "click": controller.candidateSelected(NSAttributedString(string: candidates[1])); expected = candidates[1]
            case "arrow":
                check(controller.handle(keyEvent(125, ""), client: client))
                check(controller.engine?.snapshot().highlight == 1)
                check(controller.handle(keyEvent(49, " "), client: client)); expected = candidates[1]
            case "panel-highlight":
                controller.candidateSelectionChanged(NSAttributedString(string: candidates[1]))
                check(controller.engine?.snapshot().highlight == 1)
                check(controller.handle(keyEvent(49, " "), client: client)); expected = candidates[1]
            case "comma": check(controller.handle(keyEvent(43, ","), client: client)); expected = "餐，"
            case "return": check(controller.handle(keyEvent(36, "\r"), client: client)); expected = "can"
            case "shortcut": check(!controller.handle(keyEvent(0, "a", .command), client: client))
            case "toggle":
                let before = controller.engine!.snapshot()
                check(controller.handle(modifierEvent(56, .shift), client: client))
                check(controller.handle(modifierEvent(56), client: client))
                check(controller.engine!.snapshot() == before && controller.candidates(nil) as! [String] == candidates)
                check(client.document == "准备午can" && !client.mutations.contains { $0.hasPrefix("insert:") },
                      "A deferred mode toggle preserves the context-ranked composition")
                check(controller.handle(keyEvent(49, " "), client: client))
            case "commit": controller.commitComposition(client)
            default: controller.deactivateServer(client)
            }
            check(client.document == "准备午" + expected, action)
            check(client.mutations.filter { $0.hasPrefix("insert:") } == ["insert:" + expected], action)
            check(!client.mutations.contains("mark:"), "No empty replacement after committing")
            controller.commitComposition(client); controller.deactivateServer(client)
            check(client.document == "准备午" + expected)
        }
        for action in ["space", "digit", "commit"] {
            for moveSelection in [false, true] {
                let (controller, client) = prepared()
                if moveSelection { client.selection = NSRange(location: 0, length: 0) }
                else { client.contextAvailable = false }
                switch action {
                case "space": check(controller.handle(keyEvent(49, " "), client: client))
                case "digit": check(controller.handle(keyEvent(18, "1"), client: client))
                default: controller.commitComposition(client)
                }
                check(client.document == "准备午餐", "A changed/unreadable client must not silently change the displayed selection")
            }
        }
        let (controller, client) = prepared()
        check(controller.handle(keyEvent(125, ""), client: client))
        let before = controller.engine!.snapshot()
        settings.fontSize = 18; settings.vertical = true; settings.candidateCount = 9
        check(controller.engine!.snapshot() == before)
        controller.commitComposition(client)
        check(client.document == "准备午" + before.candidates[before.highlight])
        settings.fontSize = 14; settings.vertical = false; settings.candidateCount = 5
        let (unrelated, _) = prepared("完全无关")
        let baseline = IFEngine()!; type(baseline, "can")
        check(unrelated.engine?.snapshot().candidates == baseline.snapshot().candidates, "Controllers must not share document context")
        print("PASS context controller: actual marked-document edits, digits/click/arrows/panel highlight/default/flush, raw Return, unreadable/moved selection, settings and client isolation")
    }

    @MainActor static func runCases(settings: IFSettings) {
        let controller = InkFlowInputController(server: nil, delegate: nil, client: nil,
                                                settings: settings, settingsWindow: IFSettingsWindowController(settings: settings))!
        check(controller.engine != nil)
        let client = RecordingClient()
        check(!controller.handle(keyEvent(123, ""), client: client)); check(client.mutations.isEmpty)
        check(!controller.handle(keyEvent(0, "a", .command), client: client)); check(client.mutations.isEmpty)
        check(controller.handle(modifierEvent(56, .shift), client: client))
        check(controller.handle(modifierEvent(56), client: client)); check(client.mutations.isEmpty)
        check(!controller.handle(keyEvent(0, "a"), client: client))
        controller.commitComposition(client); controller.deactivateServer(client); check(client.mutations.isEmpty)
        check(controller.handle(modifierEvent(56, .shift), client: client))
        check(controller.handle(modifierEvent(56), client: client))
        check(controller.handle(keyEvent(45, "n"), client: client)); check(client.mutations == ["mark:n"])
        check(controller.handle(keyEvent(53, ""), client: client)); check(client.mutations == ["mark:n", "mark:"])
        controller.commitComposition(client); controller.deactivateServer(client); check(client.mutations.count == 2)
        client.mutations.removeAll()
        for letter in "nihao" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
        client.mutations.removeAll()
        check(controller.handle(keyEvent(49, " "), client: client)); check(client.mutations == ["insert:你好"])
        controller.commitComposition(client); controller.deactivateServer(client); check(client.mutations == ["insert:你好"])
        for (input, expected) in [("hello", "hello"), ("comput", "computer"),
                                  ("compute", "computer"), ("comm", "community"),
                                  ("zhefenoffer", "这份offer"), ("wofaleemail", "我发了email")] {
            for letter in input { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
            let candidates = controller.candidates(nil) as! [String]
            guard let index = candidates.firstIndex(of: expected) else {
                check(false, "English word missing from controller candidates"); return
            }
            client.mutations.removeAll()
            let digitCodes: [UInt16] = [18, 19, 20, 21, 23]
            check(controller.handle(keyEvent(digitCodes[index], String(index + 1)), client: client))
            check(client.mutations == ["insert:\(expected)"])
            controller.commitComposition(client); controller.deactivateServer(client)
            check(client.mutations == ["insert:\(expected)"], "Commit English exactly once")
        }
        client.mutations.removeAll()
        for _ in 0..<4 { check(controller.handle(keyEvent(39, "\"", .shift), client: client)) }
        let quotes = ["insert:“", "insert:”", "insert:“", "insert:”"]
        check(client.mutations == quotes)
        controller.commitComposition(client); controller.deactivateServer(client); check(client.mutations == quotes)
        let punctuation: [(UInt16, String, String)] = [(39, "\"", "“"), (33, "{", "「"), (30, "}", "」"), (22, "^", "……"), (27, "_", "——")]
        for (code, input, output) in punctuation {
            for letter in "nihao" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
            client.mutations.removeAll()
            check(controller.handle(keyEvent(code, input, .shift), client: client))
            let expected = ["insert:你好\(output)"]
            check(client.mutations == expected)
            controller.commitComposition(client); controller.deactivateServer(client); check(client.mutations == expected)
        }
        for (input, emoji) in [("aixin", "❤️"), ("zhongguo", "🇨🇳"), ("yisheng", "👨‍⚕️")] {
            for letter in input { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
            var selected = false
            for _ in 0..<10 {
                let candidates = controller.candidates(nil) as! [String]
                if let index = candidates.firstIndex(of: emoji) {
                    client.mutations.removeAll()
                    let keys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
                    check(controller.handle(keyEvent(keys[index], String(index + 1)), client: client))
                    check(client.mutations == ["insert:\(emoji)"], "Insert whole emoji once: \(input)")
                    check(controller.candidates(nil).isEmpty)
                    controller.commitComposition(client); controller.deactivateServer(client)
                    check(client.mutations == ["insert:\(emoji)"])
                    selected = true
                    break
                }
                let page = controller.engine!.snapshot().page
                check(controller.handle(keyEvent(121, ""), client: client))
                if controller.engine!.snapshot().page == page { break }
            }
            check(selected, "Controller must expose \(emoji)")
        }
        print("PASS controller emoji: candidate bridge, paging, variation selector / flag / ZWJ sequences inserted once, composition cleared")

        for (input, expected) in [("hzidao", "知道"), ("nnihao", "你好")] {
            client.mutations.removeAll()
            for letter in input { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
            check(client.mutations.allSatisfy { $0.hasPrefix("mark:") }, "Typing must only update marked text")
            check((controller.candidates(nil) as? [String])?.first == expected)
            client.mutations.removeAll()
            check(controller.handle(keyEvent(18, "1"), client: client))
            check(client.mutations == ["insert:\(expected)"])
            controller.commitComposition(client)
            check(client.mutations == ["insert:\(expected)"])
        }
        print("PASS controller spelling correction: preedit-only updates, corrected candidates, single digit-key commit")
    }
}
