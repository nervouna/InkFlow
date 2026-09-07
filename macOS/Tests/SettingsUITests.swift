import InputMethodKit
import SwiftUI
import ApplicationServices

@main
struct SettingsUITests {
    @MainActor static func main() throws {
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
        check(SettingsSection.allCases.map(\.rawValue) == ["外观", "个性化", "词库", "关于"],
              "Dictionary category must be between personalization and about")
        try IFEngine.start(shared: CommandLine.arguments[1], user: CommandLine.arguments[2])
        runCases(settings: isolated.settings)
        IFEngine.stop()
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
        let item = controller.menu()!.items.first!
        check(item.action == #selector(InkFlowInputController.showPreferences(_:)))
        controller.doCommand(by: item.action, command: [kIMKCommandMenuItemName: item])
        let window = preferences.window!
        waitForFocus(window)
        check(window.styleMask.contains([.resizable, .fullSizeContentView]))
        check(window.titleVisibility == .visible && window.title == "外观", "SwiftUI navigation title must remain visible")
        check(window.contentViewController is NSHostingController<SettingsView>)
        initializeAccessibility()
        if CommandLine.arguments.contains("--dump-accessibility") {
            for element in IFAccessibilityTree(window) { print("AX \(element)") }
        }
        checkLayout(window)
        checkCustomPhrasesLayout(window, settings: settings)
        window.close()
        controller.doCommand(by: item.action, command: [kIMKCommandMenuItemName: item])
        waitForFocus(window)
        check(preferences.window === window)
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

    @MainActor static func checkCustomPhrasesLayout(_ window: NSWindow, settings: IFSettings) {
        // In-process SwiftUI sidebar children are AX proxies without selectable NSAccessibility
        // rows. Choose the initial section for layout checks; exercise navigation in CUA.
        window.contentViewController = NSHostingController(rootView: SettingsView(settings: settings, initialSection: .personalization))
        drainEvents()
        check(window.title == "个性化")
        for size in [NSSize(width: 700, height: 380), NSSize(width: 900, height: 560)] {
            window.setContentSize(size); drainEvents()
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
        window.contentViewController = NSHostingController(rootView: SettingsView(settings: settings))
        drainEvents()
        window.setContentSize(NSSize(width: 700, height: 450))
        print("PASS personalization layout: native table/buttons at minimum/enlarged sizes, empty state, edit/delete disabled without selection")
    }

    @MainActor static func checkLayout(_ window: NSWindow) {
        let initialFrame = window.frame
        for size in [NSSize(width: 700, height: 380), NSSize(width: 900, height: 560)] {
            window.setContentSize(size)
            drainEvents()
            window.contentView?.layoutSubtreeIfNeeded()
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
