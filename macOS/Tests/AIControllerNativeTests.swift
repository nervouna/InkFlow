import AppKit
@preconcurrency import InputMethodKit

private struct FixedAIService: AISuggestionServing {
    func suggest(input: AISuggestionInput, configuration: AISuggestionConfiguration) async throws -> String { "你好吗" }
}

@main
struct AIControllerNativeTests {
    @MainActor static var suggestion: NSWindow? {
        NSApp.windows.first { AISuggestionPanel.isSuggestionWindow($0) && $0.isVisible }
    }
    @MainActor static func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
    @MainActor static func until(_ predicate: () -> Bool, seconds: Double = 3) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !predicate() && ContinuousClock.now < deadline { await wait(0.025) }
        check(predicate(), "Timed out waiting for native AI state")
    }

    @MainActor static func prepare(server: IMKServer, settings: IFSettings,
                                    service: any AISuggestionServing = FixedAIService(),
                                    input: String = "nihao", secure: @escaping () -> Bool = { false }) -> (InkFlowInputController, RecordingClient) {
        let client = RecordingClient(document: "前文😀【】后文")
        client.selection = NSRange(location: "前文😀【".utf16.count, length: 0)
        let controller = InkFlowInputController(server: server, delegate: nil, client: client,
            settings: settings, settingsWindow: IFSettingsWindowController(settings: settings), smartService: service,
            secureInput: secure)!
        for letter in input { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
        let state = controller.engine!.snapshot()
        controller.panel!.setCandidateData(state.candidates)
        controller.panel!.setCandidateFrameTopLeft(NSPoint(x: 240, y: 430))
        controller.refresh(client)
        check(controller.panel!.isVisible(), "Real native candidate window is open")
        return (controller, client)
    }

    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await runChecks(); fflush(stdout); exit(0) }
            catch { print("FAIL native harness: \((error as? AIServiceError)?.localizedDescription ?? "fixture setup failed")"); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func runChecks() async throws {
        print("BEGIN native AI harness"); fflush(stdout)
        check(CommandLine.arguments.count == 3 || CommandLine.arguments.count == 5)
        let host = NSWindow(contentRect: NSRect(x: 160, y: 220, width: 620, height: 260),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.title = "墨流 AI 独立验证"; host.isReleasedWhenClosed = false
        let field = NSTextView(frame: NSRect(x: 24, y: 24, width: 540, height: 180))
        host.contentView?.addSubview(field)
        host.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); host.makeFirstResponder(field)
        await until { host.isKeyWindow }
        print("PASS native host focus"); fflush(stdout)
        defer { host.orderOut(nil) }
        let isolated = IsolatedSettings(); defer { isolated.cleanup() }
        let settings = isolated.settings
        try settings.smart.save(baseURL: "https://example.invalid", apiKey: "synthetic", model: "fixture")
        settings.smart.isEnabled = true
        try IFEngine.start(shared: CommandLine.arguments[1], user: CommandLine.arguments[2], qualityStore: nil)
        defer { IFEngine.stop() }
        let server = IMKServer(name: "inkflow.ai-native.\(UUID().uuidString)", bundleIdentifier: Bundle.main.bundleIdentifier)!
        // IMK's initializer accepts only its cross-process proxy class. Reuse the existing
        // test shim for the recording client; production controller and native panels remain real.
        IFStubHeadlessControllerFramework()

        // No event, lazy coordinator access, or window allocation should be required for teardown.
        weak var released: InkFlowInputController?
        let windowsBefore = NSApp.windows.filter(AISuggestionPanel.isSuggestionWindow).count
        autoreleasepool {
            let untouched = InkFlowInputController(server: server, delegate: nil, client: nil,
                settings: settings, settingsWindow: IFSettingsWindowController(settings: settings))!
            released = untouched
        }
        check(released == nil && NSApp.windows.filter(AISuggestionPanel.isSuggestionWindow).count == windowsBefore,
              "Untouched controller releases without constructing a suggestion panel")

        placementChecks()
        print("PASS untouched controller teardown and placement"); fflush(stdout)
        try await acceptance(server: server, settings: settings, host: host, field: field)
        try await staleChecks(server: server, settings: settings)
        if CommandLine.arguments.count == 5 {
            check(CommandLine.arguments[3] == "--live")
            try await live(server: server, settings: settings, path: CommandLine.arguments[4])
        }
        print("PASS native AI: real Rime/IMK/AppKit, focus/pass-through/geometry, 0.5s, navigation, exact-once Tab, stale lifecycle and ordinary controls")
    }

    @MainActor static func acceptance(server: IMKServer, settings: IFSettings, host: NSWindow, field: NSTextView) async throws {
        for action in ["tab", "space", "digit", "click", "partial"] {
            print("CHECK native action \(action)"); fflush(stdout)
            let (controller, client) = prepare(server: server, settings: settings)
            defer { controller.engine?.clear(); controller.refresh(client); controller.panel?.hide() }
            let initialInput = controller.engine!.aiInputIdentity()!
            let initialPage = controller.engine!.snapshot().page
            check(controller.handle(keyEvent(121, ""), client: client))
            check(controller.engine!.snapshot().page != initialPage && controller.engine!.aiInputIdentity() == initialInput,
                  "Real candidate paging preserves raw request identity")
            check(controller.handle(keyEvent(116, ""), client: client))
            if action == "partial" {
                let index = controller.engine!.snapshot().candidates.firstIndex(of: "你")!
                controller.engine!.select(index); controller.refresh(client)
                check(controller.engine!.aiInputIdentity()?.selectedPrefix == "你")
            }
            await wait(0.1)
            let originalKeyWindow = NSApp.keyWindow
            let originalResponder = host.firstResponder
            await until { suggestion != nil }
            check(NSApp.keyWindow === originalKeyWindow && host.firstResponder === originalResponder,
                  "Suggestion preserves the native candidate setup's existing keyboard focus")
            let window = suggestion!
            check(!window.canBecomeKey && !window.canBecomeMain && window.ignoresMouseEvents)
            let anchor = InkFlowInputController.candidateScreenFrame(controller.panel!)!
            check(!window.frame.intersects(anchor), "Sidecar never covers native candidates")
            let requests = client.requests.count, lengths = client.lengthReads
            await wait(0.22)
            check(client.requests.count == requests && client.lengthReads == lengths, "Position tracker never reads full context")
            check(controller.handle(keyEvent(125, ""), client: client))
            check(suggestion != nil, "Highlighting keeps a ready suggestion")
            client.mutations.removeAll()
            let ordinary = controller.engine!.snapshot().candidates
            if action == "tab" || action == "partial" {
                var callbacks = 0
                client.onMutation = {
                    callbacks += 1
                    check(!IFEngine.allSessionsIdle, "AI clear/insert holds dictionary delivery lease")
                    controller.commitComposition(client)
                    _ = controller.handle(keyEvent(48, "\t"), client: client)
                }
                check(controller.handle(keyEvent(48, "\t"), client: client))
                client.onMutation = nil
                check(callbacks == 2, "AI emits one owned mark clear and one direct insertion")
                check(client.document == "前文😀【你好吗】后文", "Tab preserves both committed sides and selected prefix")
                check(client.mutations == ["mark:", "insert:你好吗"], "No Rime default commit or duplicate AI insertion")
                let repeated = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: true, keyCode: 48)!
                _ = controller.handle(repeated, client: client); _ = controller.handle(keyEvent(48, "\t"), client: client)
                controller.commitComposition(client)
                check(client.mutations.filter { $0.hasPrefix("insert:") } == ["insert:你好吗"])
            } else {
                let selected = action == "space" ? controller.engine!.snapshot().highlight : 1
                if action == "click" { controller.candidateSelected(NSAttributedString(string: ordinary[selected])) }
                else { check(controller.handle(keyEvent(action == "space" ? 49 : 19, action == "space" ? " " : "2"), client: client)) }
                check(client.document == "前文😀【" + ordinary[selected] + "】后文", "Ordinary \(action) keeps native selection")
                check(client.mutations == ["insert:" + ordinary[selected]])
            }
            check(suggestion == nil && !controller.panel!.isVisible() && controller.engine!.snapshot().preedit.isEmpty)
            check(client.mark.location == NSNotFound)
        }
        let long = AISuggestionPanel()
        long.setSuggestion(String(repeating: "较长的完整建议内容。", count: 100))
        long.show(relativeTo: NSRect(x: 200, y: 400, width: 350, height: 30))
        check(long.isVisible && long.frame.height <= 212)
        let labels = NSApp.windows.first { AISuggestionPanel.isSuggestionWindow($0) && $0.isVisible }?.contentView?.subviews.compactMap { $0 as? NSTextField } ?? []
        check(labels.contains { $0.stringValue == "AI 建议（部分显示）" }, "Long response clipping is explicitly disclosed")
        long.hide()
        host.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); host.makeFirstResponder(field)
        await until { host.isKeyWindow && host.firstResponder === field }
        let passive = AISuggestionPanel()
        passive.setSuggestion("独立焦点验证")
        passive.show(relativeTo: NSRect(x: host.frame.minX + 30, y: host.frame.midY, width: 350, height: 30))
        await wait(0.1)
        check(passive.isVisible && host.isKeyWindow && host.firstResponder === field,
              "The suggestion panel independently preserves a text view's established focus")
        passive.hide()
    }

    @MainActor static func staleChecks(server: IMKServer, settings: IFSettings) async throws {
        let blocked = DelayedAIService()
        let (secureController, secureClient) = prepare(server: server, settings: settings, service: blocked, secure: { true })
        await wait(0.58)
        let secureCalls = await blocked.count()
        check(secureCalls == 0 && suggestion == nil, "Secure input never dispatches a suggestion request")
        secureController.engine?.clear(); secureController.refresh(secureClient)
        for action in ["escape", "hide", "selection", "context", "secure", "off", "deactivate", "space-change", "repeat-tab"] {
            let service = DelayedAIService()
            var secure = false
            let (controller, client) = prepare(server: server, settings: settings, service: service, secure: { secure })
            await wait(0.58)
            let count = await service.count(); check(count == 1)
            switch action {
            case "escape": check(controller.handle(keyEvent(53, ""), client: client))
            case "hide": controller.hidePalettes()
            case "selection": client.selection = NSRange(location: 0, length: 0)
            case "context": client.document = client.document!.replacingOccurrences(of: "前文", with: "改文")
            case "secure": secure = true
            case "off": settings.smart.isEnabled = false
            case "deactivate": controller.deactivateServer(client)
            case "space-change": NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            default: break
            }
            await service.resolve(0); await wait(0.08)
            if action == "repeat-tab" {
                check(suggestion != nil)
                let repeated = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: true, keyCode: 48)!
                let old = client.document
                check(controller.handle(repeated, client: client) && old == client.document, "A held Tab cannot accept a newly arrived suggestion")
            } else { check(suggestion == nil, "Late result suppressed after \(action)") }
            controller.engine?.clear(); controller.refresh(client); controller.panel?.hide()
            settings.smart.isEnabled = true
        }
    }

    @MainActor static func live(server: IMKServer, settings: IFSettings, path: String) async throws {
        let configuration = try AILiveConfiguration.loadConfiguration(path: path)
        check(URLComponents(string: configuration.baseURL)?.host?.lowercased() == "api.deepseek.com" && configuration.model.lowercased() == "deepseek-v4-flash")
        try settings.smart.save(baseURL: configuration.baseURL, apiKey: configuration.apiKey, model: configuration.model)
        settings.smart.isEnabled = true
        let started = ContinuousClock.now
        let (controller, client) = prepare(server: server, settings: settings, service: AIChatCompletionsClient(), input: "nihao")
        await until({ suggestion != nil || settings.smart.requestError != nil }, seconds: 25)
        check(settings.smart.requestError == nil, settings.smart.requestError ?? "")
        let text = suggestion?.accessibilityValue() as? String
        check(text?.isEmpty == false)
        check(controller.handle(keyEvent(48, "\t"), client: client))
        check(client.document == "前文😀【" + text! + "】后文" && suggestion == nil)
        let seconds = started.duration(to: .now)
        print("PASS live production API→panel→Tab: complete synthetic suggestion, exact insertion, preserved sides; elapsed=\(seconds)")
    }

    @MainActor static func placementChecks() {
        let size = NSSize(width: 310, height: 60), screen = NSRect(x: 0, y: 0, width: 1000, height: 700)
        func placed(_ candidate: NSRect, screens: [NSRect] = [screen]) -> NSRect? {
            AISuggestionPanel.position(candidateFrame: candidate, panelSize: size, screens: screens)
        }
        check(placed(NSRect(x: 100, y: 200, width: 400, height: 30)) == NSRect(x: 100, y: 134, width: 310, height: 60))
        check(placed(NSRect(x: 100, y: 5, width: 400, height: 30))?.minY == 41)
        check(placed(NSRect(x: 920, y: 300, width: 80, height: 30))?.maxX == screen.maxX)
        let left = NSRect(x: -1280, y: 0, width: 1280, height: 800)
        check(left.contains(placed(NSRect(x: -1200, y: 500, width: 400, height: 28), screens: [screen, left])!))
        check(placed(.zero) == nil)
        let narrow = NSRect(x: 0, y: 0, width: 1000, height: 100), candidate = NSRect(x: 100, y: 5, width: 200, height: 90)
        check(!placed(candidate, screens: [narrow])!.intersects(candidate))
    }
}
