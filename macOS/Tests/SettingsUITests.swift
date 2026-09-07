import InputMethodKit
import SwiftUI
import ApplicationServices

@main
struct SettingsUITests {
    @MainActor static func main() throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--press-accessibility" {
            let application = AXUIElementCreateApplication(Int32(CommandLine.arguments[2])!)
            AXUIElementSetMessagingTimeout(application, 2)
            func find(_ element: AXUIElement) -> AXUIElement? {
                var identifier: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifier)
                if identifier as? String == CommandLine.arguments[3] { return element }
                var children: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                for child in children as? [AXUIElement] ?? [] {
                    if let found = find(child) { return found }
                }
                return nil
            }
            guard let element = find(application) else { check(false, "Native AX action target missing"); return }
            check(AXUIElementPerformAction(element, kAXPressAction as CFString) == .success,
                  "System Accessibility press: \(CommandLine.arguments[3])")
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--initialize-accessibility" {
            let application = AXUIElementCreateApplication(Int32(CommandLine.arguments[2])!)
            AXUIElementSetMessagingTimeout(application, 2)
            var windows: CFTypeRef?
            check(AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows) == .success,
                  "Native UI tests require the test runner's existing Accessibility access")
            return
        }
        check(CommandLine.arguments.count >= 3)
        let isolated = IsolatedSettings()
        defer { isolated.cleanup() }
        _ = NSApplication.shared
        NSApp.finishLaunching()
        check(SettingsSection.allCases.map(\.rawValue) == ["外观", "输入", "个性化", "词库", "关于"],
              "Input category follows appearance while existing categories retain their order")
        try IFEngine.start(shared: CommandLine.arguments[1], user: CommandLine.arguments[2])
        runCases(settings: isolated.settings)
        IFEngine.stop()
        if CommandLine.arguments.contains("--input-only") { return }
        // Keep existing GUI cases intact; drive asynchronous service scenarios with AppKit's event loop.
        var testError: Error?
        Task { @MainActor in
            do {
                try await DictionarySettingsUITests.run(settings: isolated.settings,
                    shared: URL(fileURLWithPath: CommandLine.arguments[1]),
                    root: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("dictionary-ui"))
            } catch { testError = error }
            NSApp.stop(nil)
            NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
        }
        NSApp.run()
        if let testError { throw testError }
    }

    @MainActor static func runCases(settings: IFSettings) {
        let name = "inkflow.settings-ui.\(UUID().uuidString)"
        let server = IMKServer(name: name, bundleIdentifier: name)!
        let preferences = IFSettingsWindowController(settings: settings)
        let controller = InkFlowInputController(server: server, delegate: nil, client: nil,
                                                settings: settings, settingsWindow: preferences)!
        let item = controller.menu()!.items.first { $0.action == #selector(InkFlowInputController.showPreferences(_:)) }!
        check(item.action == #selector(InkFlowInputController.showPreferences(_:)))
        controller.doCommand(by: item.action, command: [kIMKCommandMenuItemName: item])
        let window = preferences.window!
        waitForFocus(window)
        checkMinimumSize(window)
        check(window.styleMask.contains([.resizable, .fullSizeContentView]))
        check(window.titleVisibility == .visible && window.title == "外观", "SwiftUI navigation title must remain visible")
        check(window.contentViewController is SettingsHostingController)
        initializeAccessibility()
        if CommandLine.arguments.contains("--input-only") {
            checkInputLayout(window, settings: settings)
            window.close()
            return
        }
        if CommandLine.arguments.contains("--dump-accessibility") {
            for element in IFAccessibilityTree(window) { print("AX \(element)") }
        }
        checkLayout(window)
        checkCustomPhrasesLayout(window, settings: settings)
        checkInputLayout(window, settings: settings)
        window.close()
        controller.doCommand(by: item.action, command: [kIMKCommandMenuItemName: item])
        waitForFocus(window)
        check(preferences.window === window)
        checkMinimumSize(window)
        let panel = controller.panel!, engine = controller.engine!
        type(engine, "shi")
        let before = engine.snapshot()
        check(!before.preedit.isEmpty && before.candidates.count == 5)
        panel.setCandidateData(before.candidates)
        var fontFailures = 0
        for vertical in [false, true] {
            settings.vertical = vertical
            for size in [14, 36, 14, 16, 18, 24, 36] {
                settings.fontSize = size
                if !checkFont(panel, engine: engine, composition: before, size: size, vertical: vertical, phase: "resize") { fontFailures += 1 }
            }
        }
        for size in [36, 14] {
            settings.fontSize = size
            for vertical in [false, true, false] {
                settings.vertical = vertical
                if !checkFont(panel, engine: engine, composition: before, size: size, vertical: vertical, phase: "direction switch") { fontFailures += 1 }
            }
        }
        let publicPanel = PublicFontOnlyCandidates(server: server, panelType: UInt(kIMKSingleRowSteppingCandidatePanel))!
        controller.panel = publicPanel
        settings.fontSize = 36
        check(publicPanel.privateFontCalls == 0)
        check((publicPanel.attributes()?[NSAttributedString.Key.font] as? NSFont)?.pointSize == 36)
        check(engine.snapshot() == before && engine.takeCommit().isEmpty)
        controller.panel = panel
        publicPanel.hide()
        print("PASS private selector unavailable: documented attributes applied, private setter skipped, composition preserved")
        settings.vertical = true; settings.fontSize = 36; settings.candidateCount = 9
        check(engine.snapshot() == before)
        check(panel.panelType() == kIMKSingleColumnScrollingCandidatePanel)
        check(panel.selectionKeys()?.count == 5)
        check((panel.attributes()?[NSAttributedString.Key.font] as? NSFont)?.pointSize == 36)
        engine.clear(); type(engine, "shi")
        settings.vertical = false
        check(panel.panelType() == kIMKSingleRowSteppingCandidatePanel)
        check(panel.selectionKeys() as? [Int] == [18, 19, 20, 21, 23, 22, 26, 28, 25])
        check(engine.snapshot().candidates.count == 9)
        panel.setCandidateData(engine.snapshot().candidates); panel.hide()
        checkSizes(controller, panel: panel, settings: settings)
        engine.clear(); settings.candidateCount = 5; settings.fontSize = 14
        check(fontFailures == 0, "\(fontFailures) native candidate font checks failed")
        print("PASS settings UI: actual IMK dictionary dispatch, SwiftUI settings, singleton reopen/focus, native direction/font/digit keys, composition preserved, deferred count")
        fflush(stdout)
        if CommandLine.arguments.contains("--hold") {
            print("HOLD: isolated SwiftUI settings window ready for CUA; close the window to finish and clean up")
            fflush(stdout)
            while window.isVisible { drainEvents(seconds: 0.25) }
        }
        window.close()
    }

    @MainActor static func checkInputLayout(_ window: NSWindow, settings: IFSettings) {
        window.contentViewController = SettingsHostingController(rootView: SettingsView(settings: settings, initialSection: .input))
        checkMinimumSize(window)
        window.setContentSize(NSSize(width: 700, height: 560))
        drainEvents()
        if CommandLine.arguments.contains("--dump-accessibility") {
            for element in IFAccessibilityTree(window) { print("AX input initial \(element)") }
        }

        func control(_ identifier: String) -> [String: Any] {
            let elements = IFAccessibilityTree(window)
            let matches = elements.filter { $0["id"] as? String == identifier }
            if matches.count != 1 { for element in elements { print("AX input \(element)") } }
            check(matches.count == 1, "One native Input control: \(identifier)")
            return matches[0]
        }
        func press(_ identifier: String) {
            // SwiftUI checkbox proxies do not implement the in-process press selector.
            // A child sends the system AX action while this process services its event loop.
            let action = Process()
            action.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            action.arguments = ["--press-accessibility", String(ProcessInfo.processInfo.processIdentifier), identifier]
            try! action.run()
            let deadline = Date().addingTimeInterval(5)
            while action.isRunning && Date() < deadline { drainEvents(seconds: 0.02) }
            if action.isRunning { action.terminate(); check(false, "Native Input action timed out: \(identifier)") }
            check(action.terminationStatus == 0, "Native Input action: \(identifier)")
            drainEvents()
        }
        func checkTitle(_ title: String, beside control: [String: Any]) {
            // Native grouped Forms expose control labels as adjacent static text.
            let labels = IFAccessibilityTree(window).filter {
                $0["role"] as? String == "AXStaticText" && ($0["value"] as? String == title || $0["label"] as? String == title)
            }
            check(labels.count == 1, "One exact compact Input label: \(title)")
            let labelFrame = (labels[0]["frame"] as! NSValue).rectValue
            let controlFrame = (control["frame"] as! NSValue).rectValue
            check(abs(labelFrame.midY - controlFrame.midY) < 3 && labelFrame.maxX <= controlFrame.minX,
                  "Meaningful label accompanies its native control: \(title)")
        }
        let toggles = ["abbreviation": "简拼", "typoTolerance": "自动纠错", "fuzzy": "模糊音",
                       "emoji": "显示 Emoji 候选", "englishPunctuation": "英文标点", "traditional": "繁体输入"]
        for (key, title) in toggles {
            let element = control("settings.input.\(key)")
            check(element["role"] as? String == "AXCheckBox")
            checkTitle(title, beside: element)
        }
        let elements = IFAccessibilityTree(window)
        check(elements.filter { $0["role"] as? String == "AXCheckBox" }.count == toggles.count,
              "Only six Input toggles, including one unified fuzzy switch")
        let removed = ["拼音输入", "候选与按键", "标点符号", "简拼与全简混输", "常见拼写容错",
                       "例如 hzidao", "仅影响中文", "自定义短语保留原文"]
        for element in elements {
            let text = [element["label"], element["value"]].compactMap { $0 as? String }.joined()
            check(!removed.contains { text.contains($0) }, "Input has no small headings or explanatory copy: \(text)")
        }
        check(!settings.fuzzyEnabled)
        press("settings.input.fuzzy")
        check([InputOption.fuzzyZ, .fuzzyC, .fuzzyS].allSatisfy { settings.inputPreferences[$0] })
        press("settings.input.fuzzy")
        check(!settings.fuzzyEnabled)

        func checkPaging(_ selection: IFSettings.PagingKeys) {
            let radios = IFAccessibilityTree(window).filter { $0["role"] as? String == "AXRadioButton" }
            check(radios.count == 2, "Exactly two mutually exclusive paging radios")
            for keys in IFSettings.PagingKeys.allCases {
                let key = keys == .brackets ? "brackets" : "minusEqual"
                let radio = control("settings.input.paging.\(key)")
                check(radio["label"] as? String == keys.rawValue && radio["value"] as? Int == (keys == selection ? 1 : 0),
                      "Exact paging title and mutual exclusion: \(keys.rawValue)")
            }
            let frames = radios.map { ($0["frame"] as! NSValue).rectValue }.sorted { $0.minX < $1.minX }
            check(abs(frames[0].midY - frames[1].midY) < 2 && frames[0].maxX <= frames[1].minX,
                  "Native paging radio choices are horizontal")
            let toggleFrame = (control("settings.input.emoji")["frame"] as! NSValue).rectValue
            check(abs(frames[1].maxX - toggleFrame.maxX) < 3,
                  "Paging radio choices align with the right-side controls")
            checkTitle("翻页", beside: control("settings.input.paging.brackets"))
            check(settings.pagingKeys == selection)
        }
        checkPaging(.brackets)
        press("settings.input.paging.minusEqual"); checkPaging(.minusEqual)
        press("settings.input.paging.brackets"); checkPaging(.brackets)

        let mappings: [(InputOption, String, String)] = [(.cornerQuotes, "{}", "「」"), (.middleDot, "`", "·"),
                                                        (.fullwidthPipe, "|", "｜"), (.ideographicComma, "\\", "、")]
        for (option, key, mapped) in mappings {
            let identifier = "settings.input.\(option.rawValue)"
            let popup = control(identifier)
            check(popup["role"] as? String == "AXPopUpButton")
            checkTitle("按下 \(key) 时输入", beside: popup)
            check(popup["value"] as? String == "输入 \(mapped)")
            // Drive the real popup's menu with native key events, including both available choices.
            for enabled in [false, true, false] {
                let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        NSApp.postEvent(keyEvent(enabled ? 125 : 126, enabled ? "\u{f701}" : "\u{f700}"), atStart: false)
                        NSApp.postEvent(keyEvent(36, "\r"), atStart: false)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                press(identifier)
                drainEvents(seconds: 0.3)
                check(settings.inputPreferences[option] == enabled, "Popup selection persists: \(option) = \(enabled)")
                check(control(identifier)["value"] as? String == (enabled ? "输入 \(mapped)" : "原样输入"))
            }
        }
        for english in [true, false] {
            press("settings.input.englishPunctuation")
            check(settings.inputPreferences[.englishPunctuation] == english)
            for (option, _, _) in mappings {
                let popup = control("settings.input.\(option.rawValue)")
                check(popup["enabled"] as? Bool == !english && popup["value"] as? String == "原样输入")
                check(!settings.inputPreferences[option], "Disabled dropdown preserves its selection")
            }
        }
        settings.inputSettingsError = "输入设置测试错误"
        drainEvents()
        check(IFAccessibilityTree(window).contains { $0["value"] as? String == "输入设置测试错误" || $0["label"] as? String == "输入设置测试错误" },
              "Actual input errors remain visible")
        settings.inputSettingsError = nil
        for (option, _, _) in mappings { settings.setInputOption(option, enabled: true) }
        drainEvents()
        check(window.title == "输入")
        if CommandLine.arguments.contains("--dump-accessibility") {
            for element in IFAccessibilityTree(window) { print("AX input final \(element)") }
        }
        window.contentViewController = SettingsHostingController(rootView: SettingsView(settings: settings))
        drainEvents()
        print("PASS input settings layout: exact compact labels, no headings/copy, unified fuzzy action, horizontal exclusive radios, native popup choices/actions, preserved disabled mappings and actual error")
    }

    @MainActor static func checkCustomPhrasesLayout(_ window: NSWindow, settings: IFSettings) {
        // In-process SwiftUI sidebar children are AX proxies without selectable NSAccessibility
        // rows. Choose the initial section for layout checks; exercise navigation in CUA.
        window.contentViewController = SettingsHostingController(rootView: SettingsView(settings: settings, initialSection: .personalization))
        checkMinimumSize(window)
        drainEvents()
        check(window.title == "个性化")
        for size in [NSSize(width: 700, height: 380), NSSize(width: 700, height: 560)] {
            window.setContentSize(size); drainEvents()
            checkMinimumSize(window)
            let elements = IFAccessibilityTree(window)
            let identifiers = ["phrases.list", "phrases.add", "phrases.edit", "phrases.delete"]
            let controls = elements.filter { identifiers.contains($0["id"] as? String ?? "") }
            if controls.count != identifiers.count {
                for element in elements { print("AX personalization \(element)") }
            }
            check(controls.count == identifiers.count, "Native phrase table and CRUD controls must be accessible")
            for control in controls {
                let frame = (control["frame"] as! NSValue).rectValue
                check(frame.width > 0 && frame.height > 0 && window.convertToScreen(window.contentLayoutRect).contains(frame))
                if ["phrases.edit", "phrases.delete"].contains(control["id"] as! String) {
                    check(control["enabled"] as? Bool == false)
                }
            }
            check(elements.contains { $0["id"] as? String == "phrases.empty" })
        }
        window.contentViewController = SettingsHostingController(rootView: SettingsView(settings: settings))
        checkMinimumSize(window)
        drainEvents()
        window.setContentSize(NSSize(width: 700, height: 450))
        print("PASS personalization layout: native table/buttons at minimum/enlarged sizes, empty state, edit/delete disabled without selection")
    }

    @MainActor static func checkMinimumSize(_ window: NSWindow) {
        let original = window.frame
        for requested in [NSSize(width: 500, height: 200), NSSize(width: 900, height: 560)] {
            window.setContentSize(requested)
            drainEvents()
            let expected = NSSize(width: 700, height: max(380, requested.height))
            check(window.contentView!.frame.size == expected,
                  "Requested \(requested), expected \(expected), actual \(window.contentView!.frame.size)")
        }
        window.setFrame(original, display: true)
        drainEvents()
    }

    @MainActor static func checkLayout(_ window: NSWindow) {
        let initialFrame = window.frame
        for size in [NSSize(width: 700, height: 380), NSSize(width: 700, height: 560)] {
            window.setContentSize(size)
            drainEvents()
            window.contentView?.layoutSubtreeIfNeeded()
            checkMinimumSize(window)
            check(window.contentView!.frame.size == size, "Settings must resize vertically to \(size)")
            let elements = IFAccessibilityTree(window)
            let controls = elements.filter { ["settings.direction", "settings.count", "settings.fontSize"].contains($0["id"] as? String ?? "") }
            check(controls.count == 3, "All SwiftUI pickers must be accessible")
            let contentFrame = window.convertToScreen(window.contentLayoutRect)
            let defaults = ["settings.direction": "水平", "settings.count": "5", "settings.fontSize": "14"]
            for control in controls {
                let frame = (control["frame"] as! NSValue).rectValue
                check(frame.width > 0 && frame.height > 0 && contentFrame.contains(frame), "Picker must fit within content layout")
                check(String(describing: control["value"]!) == defaults[control["id"] as! String], "Picker must display its persisted setting")
            }
            check(elements.contains { $0["id"] as? String == "settings.sidebar" }, "SwiftUI sidebar must be accessible")
            let close = window.standardWindowButton(.closeButton)!
            let closeFrame = window.convertToScreen(close.convert(close.bounds, to: nil))
            check(elements.contains { element in
                guard element["role"] as? String == "AXGroup", let frame = (element["frame"] as? NSValue)?.rectValue else { return false }
                return (160...210).contains(frame.width) && frame.contains(closeFrame) && frame.maxY > contentFrame.maxY + 1
            }, "Native sidebar must extend behind the traffic lights")
        }
        window.setFrame(initialFrame, display: true)
        print("PASS settings layout: full-height SwiftUI sidebar behind traffic lights, three native pickers/defaults accessible, controls within content layout at minimum/enlarged sizes")
    }

    @MainActor static func waitForFocus(_ window: NSWindow) {
        // Activation is asynchronous. Keep the focus requirement and bound the wait.
        let deadline = Date().addingTimeInterval(5)
        while !(window.isVisible && window.isKeyWindow && NSApp.isActive), Date() < deadline {
            drainEvents(seconds: 0.05)
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let frontmost = NSWorkspace.shared.frontmostApplication
        check(window.isVisible && window.isKeyWindow && NSApp.isActive,
              "Settings focus timed out after 5s: visible=\(window.isVisible) key=\(window.isKeyWindow) active=\(NSApp.isActive) " +
              "frontmost=\(frontmost?.bundleIdentifier ?? "unknown") pid=\(frontmost?.processIdentifier ?? -1) " +
              "onConsole=\(session?[kCGSessionOnConsoleKey as String] ?? "unknown") " +
              "loginComplete=\(session?[kCGSessionLoginDoneKey as String] ?? "unknown"). " +
              "Native UI checks require an unlocked desktop that can give the harness focus.")
    }

    @MainActor static func initializeAccessibility() {
        // SwiftUI initializes its accessibility tree lazily when an assistive client connects.
        // Use a bounded public read from a child process; never change system accessibility settings.
        let reader = Process()
        reader.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        reader.arguments = ["--initialize-accessibility", String(ProcessInfo.processInfo.processIdentifier)]
        try! reader.run()
        let deadline = Date().addingTimeInterval(5)
        while reader.isRunning && Date() < deadline { drainEvents(seconds: 0.02) }
        if reader.isRunning { reader.terminate(); check(false, "Accessibility reader timed out") }
        check(reader.terminationStatus == 0, "Accessibility reader failed")
        drainEvents()
    }

    @MainActor static func checkFont(_ panel: IMKCandidates, engine: IFEngine, composition: EngineSnapshot,
                                      size: Int, vertical: Bool, phase: String) -> Bool {
        let font = IFNativeCandidateFont(panel)
        let preserved = engine.snapshot() == composition && engine.takeCommit().isEmpty
        let keys = panel.selectionKeys() as? [Int] == [18, 19, 20, 21, 23]
        let configured = panel.panelType() == (vertical ? kIMKSingleColumnScrollingCandidatePanel : kIMKSingleRowSteppingCandidatePanel)
            && (panel.attributes()?[NSAttributedString.Key.font] as? NSFont)?.pointSize == CGFloat(size)
        let passed = font?.pointSize == CGFloat(size) && configured && preserved && keys
        print("\(passed ? "PASS" : "FAIL") native font: \(phase) \(vertical ? "vertical" : "horizontal") requested=\(size) itemLayout.title=\(font?.pointSize ?? 0) composition=\(preserved) digitKeys=\(keys)")
        return passed
    }

    @MainActor static func checkSizes(_ controller: InkFlowInputController, panel: IMKCandidates, settings: IFSettings) {
        let shortWords = ["你", "好", "世", "界", "字", "号", "候", "选", "词"]
        let keys = panel.selectionKeys() as? [Int]
        for fontSize in [14, 36, 14, 16, 18, 24] {
            settings.fontSize = fontSize; settings.vertical = true
            var fixedHeight: CGFloat = 0
            for count in [1, 3, 5, 9, 3, 1] {
                let words = Array(shortWords.prefix(count))
                controller.applySettings(); panel.setCandidateData(words); panel.show(kIMKLocateCandidatesBelowHint)
                let size = panel.candidateFrame().size
                if fixedHeight == 0 { fixedHeight = size.height }
                check(panel.isVisible() && size.width >= 150 && size.height > 0 && abs(size.height - fixedHeight) < 1)
                check(panel.selectionKeys() as? [Int] == keys)
                for (index, word) in words.enumerated() {
                    check(panel.candidateIdentifier(atLineNumber: index) == panel.candidateStringIdentifier(word))
                }
                print("PASS vertical size: font=\(fontSize) count=\(count) actual=\(size.width)x\(size.height)")
            }
        }
        controller.applySettings()
        panel.setCandidateData(["候选面板根据实际内容调整"]); panel.show(kIMKLocateCandidatesBelowHint)
        check(panel.candidateFrame().width > 150)
        settings.fontSize = 14
        for vertical in [false, true, false, true] {
            settings.vertical = vertical; controller.applySettings()
            panel.setCandidateData(["你"]); panel.show(kIMKLocateCandidatesBelowHint)
            let width = panel.candidateFrame().width
            check(vertical ? width >= 150 : width < 150)
        }
        panel.hide()
        print("PASS native sizes: minimum vertical width 150, stable height, wider content expands, direction switches preserve horizontal sizing and digit keys")
    }
}
