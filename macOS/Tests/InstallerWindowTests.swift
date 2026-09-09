import AppKit
import Darwin

private let testApp = IFAppVersion(version: "0.2.0", build: "3")
private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw IFInstallerError.invalid("TEST: " + message) }
}
private actor WindowFiles: IFInstallerFileOperations {
    nonisolated let target = URL(fileURLWithPath: "/private/tmp/inkflow-window-fake/InkFlow.app")
    var prepares = 0
    var commits = 0
    var cancels = 0
    var failPrepare = false
    var old = false
    var delayCommit = false
    func configure(failPrepare: Bool = false, old: Bool = false, delayCommit: Bool = false) {
        self.failPrepare = failPrepare; self.old = old; self.delayCommit = delayCommit
    }
    func prepare() async throws -> Bool {
        prepares += 1
        try await Task.sleep(for: .milliseconds(80))
        if failPrepare { throw IFInstallerError.invalid(String(repeating: "A long diagnostic /path/value ", count: 500)) }
        return old
    }
    func commit() async throws {
        commits += 1
        if delayCommit { try await Task.sleep(for: .milliseconds(160)) }
    }
    func clean() { cancels += 1 }
    func counts() -> (Int, Int, Int) { (prepares, commits, cancels) }
}
@MainActor private final class WindowSources: IFInputSourceOperations {
    var registered = true
    var parentEnabled = true
    var childEnabled = true
    var refusal = false
    var registerError = false
    var selected = "ascii"
    var registrations = 0
    func snapshot() -> IFInputRoster {
        let parent = IFInputSource(id: IFInputIdentity.bundleID, bundleID: IFInputIdentity.bundleID, name: "InkFlow", enabled: parentEnabled, selectable: false, keyboardMode: false, ascii: false)
        let child = IFInputSource(id: IFInputIdentity.modeID, bundleID: IFInputIdentity.bundleID, name: "墨流拼音", enabled: childEnabled, selectable: true, keyboardMode: true, ascii: false)
        let ascii = IFInputSource(id: "ascii", bundleID: "system", name: "ABC", enabled: true, selectable: true, keyboardMode: false, ascii: true)
        let all = registered ? [parent, child] : []
        return .init(installed: all, enabled: [ascii] + all.filter(\.enabled), selectedID: selected)
    }
    func register(at url: URL) throws {
        registrations += 1
        if registerError { throw IFInputError.api("fake registration", -50) }
        registered = true
    }
    func enable(_ id: String) {
        if refusal { return }
        if id == IFInputIdentity.bundleID { parentEnabled = true } else { childEnabled = true }
    }
    func select(_ id: String) { selected = id }
}
@MainActor private final class WindowLifecycle: IFInstallerLifecycleOperations {
    var delayTermination = false
    func terminateOld() async throws {
        if delayTermination { try await Task.sleep(for: .milliseconds(160)) }
    }

}
@MainActor private final class WindowFixture {
    let files = WindowFiles()
    let sources = WindowSources()
    let lifecycle = WindowLifecycle()
    var loads = 0
    var cleanups = 0
    var settingsCalls = 0
    var loadDelay = false
    var failFirstLoad = false
    lazy var coordinator = makeCoordinator()
    private func makeCoordinator() -> IFInstallerCoordinator {
        IFInstallerCoordinator(files: files, sources: sources, lifecycle: lifecycle, pause: {
            try await Task.sleep(nanoseconds: 30_000_000)
        })
    }
    lazy var ui = makeUI()
    private func makeUI() -> IFInstallWindowController {
        IFInstallWindowController(version: testApp, installedVersion: nil, target: files.target,
        makeCoordinator: { [self] in
            loads += 1
            if failFirstLoad && loads == 1 { throw IFInstallerError.invalid("fake payload validation failure") }
            if loadDelay { try await Task.sleep(for: .milliseconds(150)) }
            return coordinator
        }, cleanup: { [self] in cleanups += 1 }, openSettings: { [self] in settingsCalls += 1 })
    }
    func show() { ui.showWindow(nil); NSApp.activate(ignoringOtherApps: true) }
}
@MainActor private func waitFor(_ predicate: () -> Bool) async throws {
    let end = ProcessInfo.processInfo.systemUptime + 3
    while !predicate() {
        try expect(ProcessInfo.processInfo.systemUptime < end, "state wait timeout")
        try await Task.sleep(for: .milliseconds(5))
    }
}
@MainActor private func screenshot(_ ui: IFInstallWindowController, _ name: String) async throws {
    let view = ui.window!.contentView!
    view.layoutSubtreeIfNeeded()
    try expect(!view.hasAmbiguousLayout && !ui.summary.hasAmbiguousLayout, "unambiguous layout")
    try expect(ui.window!.frame.height < 850, "compact bounded window")
    try expect(ui.primary.frame.width > 40 && ui.summary.frame.width > 450, "native controls laid out")
    try await Task.sleep(for: .milliseconds(80))
    let destination = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png")
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(ui.window!.windowNumber), destination.path]
    try capture.run(); capture.waitUntilExit()
    try expect(capture.terminationStatus == 0, "test-owned window capture")
}
@MainActor private func runTests() async throws {
    do {
        let f = WindowFixture(); f.show()
        try expect(f.ui.primary.title == "安装并启用" && f.ui.primary.keyEquivalent == "\r", "install default key")
        try expect(f.ui.secondary.keyEquivalent == "\u{1b}" && f.ui.pathLabel.isSelectable, "escape and selectable path")
        try await screenshot(f.ui, "ready")
        f.ui.primary.performClick(nil); f.ui.primary.performClick(nil)
        try await waitFor { f.ui.state == .preparing }
        try expect(!f.ui.progress.isHidden && !f.ui.primary.isEnabled, "progress and duplicate guard")
        try await waitFor { !f.ui.busy }
        try expect(f.loads == 1 && f.cleanups == 1, "one load and settled cleanup")
        try expect(f.ui.state == .installedEnabled && f.ui.primary.title == "完成", "ready done")
        try expect(await f.files.counts().0 == 1, "one preparation")
        try await screenshot(f.ui, "completed")
        var done = false; f.ui.requestExit = { done = true }; f.ui.primary.performClick(nil)
        try expect(done, "Done exits")
        f.ui.window?.orderOut(nil)
    }
    do {
        let f = WindowFixture(); f.failFirstLoad = true
        f.ui.primary.performClick(nil); try await waitFor { !f.ui.busy }
        try expect(f.ui.primary.title == "重试安装" && f.cleanups == 1, "payload failure releases resources")
        f.ui.primary.performClick(nil); try await waitFor { !f.ui.busy }
        try expect(f.loads == 2 && f.ui.state == .installedEnabled, "payload retry loads again")
    }
    do {
        let f = WindowFixture(); await f.files.configure(failPrepare: true); f.show()
        f.ui.primary.performClick(nil); try await waitFor { !f.ui.busy }
        try expect(f.ui.primary.title == "重试安装", "file failure retry")
        f.ui.diagnostics.performClick(nil)
        try expect(f.ui.details.isSelectable && !f.ui.details.isEditable && f.ui.details.string.count > 8000, "long selectable diagnostic")
        try await screenshot(f.ui, "long-error")
        await f.files.configure(); f.ui.primary.performClick(nil); try await waitFor { !f.ui.busy }
        try expect(f.loads == 2 && f.cleanups == 2 && f.ui.state == .installedEnabled, "file retry reload")
        f.ui.window?.orderOut(nil)
    }
    do {
        let f = WindowFixture(); f.sources.parentEnabled = false; f.sources.refusal = true; f.show()
        f.ui.primary.performClick(nil); try await waitFor { !f.ui.busy }
        try expect(f.ui.primary.title == "重试启用" && !f.ui.settings.isHidden, "approval recovery")
        f.ui.settings.performClick(nil); try expect(f.settingsCalls == 1, "injected settings only")
        try await screenshot(f.ui, "approval")
        f.sources.refusal = false; f.ui.primary.performClick(nil); try await waitFor { !f.ui.busy }
        try expect(f.loads == 1 && f.ui.state == .installedEnabled, "activation retry without reinstall")
        f.ui.window?.orderOut(nil)
    }
    do {
        let f = WindowFixture(); f.sources.registered = false; f.sources.registerError = true
        f.ui.primary.performClick(nil); try await waitFor { !f.ui.busy }
        try expect(f.ui.primary.title == "重试启用", "registration retry")
        f.sources.registerError = false; f.ui.primary.performClick(nil); try await waitFor { !f.ui.busy }
        try expect(f.sources.registrations == 2 && f.loads == 1, "registration stage retry")
    }
    for duringLoad in [false, true] {
        let f = WindowFixture(); f.loadDelay = duringLoad
        f.ui.primary.performClick(nil); try await waitFor { f.ui.state == .preparing }
        f.ui.secondary.performClick(nil)
        try await waitFor { !f.ui.busy }
        let counts = await f.files.counts()
        try expect(f.ui.state == .cancelled && counts.1 == 0 && f.cleanups == 1, "cancel preparation only")
    }
    for phase in [IFInstallerState.preparing, .stoppingOldVersion, .committing, .activating] {
        for windowClose in [false, true] {
            let f = WindowFixture()
            await f.files.configure(old: phase == .stoppingOldVersion, delayCommit: phase == .committing)
            f.lifecycle.delayTermination = phase == .stoppingOldVersion
            f.sources.refusal = phase == .activating; f.sources.parentEnabled = phase != .activating
            var replies = 0
            let delegate = IFInstallAppDelegate(controller: f.ui, reply: {
                if $0 { replies += 1 }
                // Exercise the real termination request, but keep the test executable alive.
                NSApp.reply(toApplicationShouldTerminate: false)
            })
            NSApp.delegate = delegate
            f.show(); f.ui.primary.performClick(nil); try await waitFor { f.ui.state == phase }
            // Deliver as an AppKit event, outside the async test's executor stack.
            Timer.scheduledTimer(withTimeInterval: 0.001, repeats: false) { _ in
                MainActor.assumeIsolated {
                    if windowClose {
                        f.ui.window!.performClose(nil)
                    } else {
                        let menu = NSMenu()
                        let quit = menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
                        quit.target = NSApp
                        menu.performActionForItem(at: 0)
                    }
                }
            }
            try await waitFor { delegate.terminationPending }
            try expect(delegate.terminationPending && f.ui.window!.isVisible, "close gate retains window")
            try expect(f.ui.owningTask?.isCancelled == false, "owning task never cancelled")
            try await waitFor { !f.ui.busy }
            try expect(replies == 1, "reply after settled exactly once")
            if phase != .preparing && phase != .activating { try expect(f.ui.state == .installedEnabled, "critical stage completes") }
            f.ui.window?.orderOut(nil)
            NSApp.delegate = nil
        }
    }
    print("PASS native window: buttons, layout, progress, long errors, retries, duplicate click, cancellation, 8 close/quit gates; fake backends only")
}

@main struct InstallerWindowTests {
    @MainActor static var started = false
    @MainActor static var result: Int32?
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 25)
        watchdog.setEventHandler { print("FAIL 25s hard watchdog"); fflush(stdout); exit(2) }
        watchdog.resume()
        let start = ProcessInfo.processInfo.systemUptime
        // Timer-driven AppKit termination, avoiding main-queue shutdown hangs.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !started {
                    started = true
                    Task { @MainActor in
                        do { try await runTests(); result = 0 }
                        catch { print("FAIL \(error)"); result = 1 }
                    }
                }
                if let result { fflush(stdout); exit(result) }
                if ProcessInfo.processInfo.systemUptime - start > 25 { print("FAIL 25s watchdog"); fflush(stdout); exit(2) }
            }
        }
        withExtendedLifetime((timer, watchdog)) { app.run() }
    }
}
