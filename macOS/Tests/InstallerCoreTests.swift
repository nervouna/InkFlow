import Foundation
#if SWIFT_PACKAGE
@testable import InkFlowInstallerCore
@testable import InkFlowInputSources
private typealias TestInputSourceOperations = IFPackageInputSourceOperations
private typealias TestInputSource = IFPackageInputSource
private typealias TestInputRoster = IFPackageInputRoster
private typealias TestInputIdentity = IFPackageInputIdentity
#else
private typealias TestInputSourceOperations = IFInputSourceOperations
private typealias TestInputSource = IFInputSource
private typealias TestInputRoster = IFInputRoster
private typealias TestInputIdentity = IFInputIdentity
#endif

private func check(_ value: Bool, _ message: String) throws {
    if !value { throw IFInstallerError.invalid("TEST: \(message)") }
}
private actor Files: IFInstallerFileOperations {
    nonisolated let target = URL(fileURLWithPath: "/tmp/arbitrary parent/InkFlow.app")
    var old = false
    var commits = 0
    var cleaned = 0
    func prepare() -> Bool { old }
    func commit() { commits += 1 }
    func clean() { cleaned += 1 }
    func counts() -> (Int, Int) { (commits, cleaned) }
}
@MainActor private final class Lifecycle: IFInstallerLifecycleOperations {
    var error: IFInstallerError?
    var stops = 0
    func terminateOld() throws { stops += 1; if let error { throw error } }
}
@MainActor private final class Sources: TestInputSourceOperations {
    var registered = false
    var enabled: Set<String> = []
    var selected = ""
    var calls: [String] = []
    var failure = ""
    var refuses = false
    func source(_ id: String) -> TestInputSource {
#if SWIFT_PACKAGE
        .init(id: id, bundleID: TestInputIdentity.bundleID, name: "Any localized name",
              enabled: enabled.contains(id), selectable: true, ascii: false)
#else
        .init(id: id, bundleID: TestInputIdentity.bundleID, name: "Any localized name",
              enabled: enabled.contains(id), selectable: true, keyboardMode: true, ascii: false)
#endif
    }
    func snapshot() throws -> TestInputRoster {
        if failure == "snapshot" { throw IFInputError.api("snapshot", -50) }
        let all = registered ? [source(TestInputIdentity.bundleID), source(TestInputIdentity.modeID)] : []
        return .init(installed: all, enabled: all.filter(\.enabled), selectedID: selected)
    }
    func record(_ operation: String) throws {
        calls.append(operation)
        if operation == failure { throw IFInputError.api(operation, -50) }
    }
    func register(at url: URL) throws { try record("register"); registered = true }
    func enable(_ id: String) throws { try record("enable"); if !refuses { enabled.insert(id) } }
    func select(_ id: String) throws { try record("select"); selected = id }
}

@main struct InstallerCoreTests {
    @MainActor private final class TrialProcesses: IFTrialProcessOperations {
        var pids: [Int32] = [42]
        var failure = ""
        var launches = 0
        func installedPIDs(at target: URL) -> [Int32] { pids }
        func stop(_ pids: [Int32]) throws {
            if failure == "declined" || failure == "timeout" { throw IFInputError.unavailable(failure) }
            self.pids = failure == "restarted" ? [43] : []
        }
        func launchAndVerify(at target: URL, excluding: [Int32]) throws -> Int32 {
            launches += 1
            if failure == "launch" { throw IFInputError.unavailable("launch") }
            pids = [99]; return 99
        }
    }
    @MainActor private final class TrialSources: IFInputSourceOperations {
        var selected = IFInputIdentity.modeID
        var enabled = [IFInputIdentity.bundleID, IFInputIdentity.modeID, "ascii"]
        var failure = ""
        var enabledCalls = 0
        var delayed = false
        var pendingIDs: [String] = []
        var pendingSelection: String?
        func applyPending() {
            enabled.append(contentsOf: pendingIDs); pendingIDs = []
            if let pendingSelection { selected = pendingSelection; self.pendingSelection = nil }
        }
        func snapshot() throws -> IFInputRoster {
            if failure == "snapshot" { throw IFInputError.unavailable("snapshot") }
            let sources = [IFInputIdentity.bundleID, IFInputIdentity.modeID, "ascii"].map { id in
                IFInputSource(id: id, bundleID: id == "ascii" ? "system" : IFInputIdentity.bundleID,
                    name: id, enabled: enabled.contains(id), selectable: true, keyboardMode: true, ascii: id == "ascii")
            }
            return IFInputRoster(installed: sources, enabled: sources.filter(\.enabled), selectedID: selected)
        }
        func register(at url: URL) throws {
            if failure == "register" { throw IFInputError.unavailable("register") }
        }
        func enable(_ id: String) {
            enabledCalls += 1
            if delayed { pendingIDs.append(id) } else { enabled.append(id) }
        }
        func select(_ id: String) throws {
            if failure == "select" { throw IFInputError.unavailable("select") }
            if delayed { pendingSelection = id } else { selected = id }
        }
    }
    @MainActor static func trialTests() async throws {
        let target = URL(fileURLWithPath: "/tmp/input methods/InkFlow.app")
        for failure in ["declined", "timeout", "restarted"] {
            let s = TrialSources(), p = TrialProcesses(); p.failure = failure
            let trial = IFTrialInstallation(sources: s, processes: p)
            do {
                _ = try await trial.prepare(target: target, build: "12")
                throw IFInstallerError.invalid("prepare must refuse \(failure)")
            } catch is IFInputError {}
            try check(p.launches == 0 && s.selected == IFInputIdentity.modeID, "refused prepare restores selection without launch")
        }
        let s = TrialSources(), p = TrialProcesses()
        let lifecycle = IFTrialInstallation(sources: s, processes: p)
        let state = try await lifecycle.prepare(target: target, build: "12")
        try check(p.pids.isEmpty && s.selected == "ascii", "prepare returns only after old exit")
        let pid = try await lifecycle.finish(target: target, state: state, installedBuild: "12")
        try check(pid == 99 && s.selected == IFInputIdentity.modeID && s.enabledCalls == 0, "fresh process and original selected/enabled state")
        for failure in ["register", "select", "launch", "build"] {
            s.failure = failure; p.failure = failure
            do {
                _ = try await lifecycle.finish(target: target, state: state, installedBuild: failure == "build" ? "11" : "12")
                throw IFInstallerError.invalid("finish must refuse \(failure)")
            } catch is IFInputError {}
        }
        let firstSources = TrialSources(), firstProcesses = TrialProcesses()
        firstSources.selected = "ascii"; firstSources.enabled = ["ascii"]; firstProcesses.pids = []
        let first = IFTrialInstallation(sources: firstSources, processes: firstProcesses)
        let initial = try await first.prepare(target: target, build: "12")
        _ = try await first.finish(target: target, state: initial, installedBuild: "12")
        try check(firstSources.selected == "ascii" && firstSources.enabledCalls == 0, "first install preserves disabled state")
        let delayedSources = TrialSources(), delayedProcesses = TrialProcesses()
        delayedSources.delayed = true
        let delayed = IFTrialInstallation(sources: delayedSources, processes: delayedProcesses, pause: { delayedSources.applyPending() })
        let delayedState = try await delayed.prepare(target: target, build: "12")
        delayedSources.enabled = ["ascii"]
        _ = try await delayed.finish(target: target, state: delayedState, installedBuild: "12")
        try check(delayedSources.selected == IFInputIdentity.modeID && delayedSources.enabledCalls == 2, "delayed enable and selection readback")
        try check(IFTrialSystemProcesses.owns(path: "/tmp/input methods/.inkflow-install.abc/previous/Contents/MacOS/InkFlow", target: target), "old staging path recognized")
        for path in ["/tmp/harness/InkFlow.app/Contents/MacOS/InkFlow", "/tmp/input methods/.inkflow-install.abc/other/Contents/MacOS/InkFlow", "/tmp/else/.inkflow-install.abc/previous/Contents/MacOS/InkFlow"] {
            try check(!IFTrialSystemProcesses.owns(path: path, target: target), "unrelated instance excluded")
        }
        print("PASS trial lifecycle: declined/timeout/restarted block prepare; fresh process/state; postfailure; first install; scoped ownership (fake backends, no desktop mutation)")
    }
    static func fileTests() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("installer-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("arbitrary source.app")
        let parent = root.appendingPathComponent("destination")
        let target = parent.appendingPathComponent("InkFlow.app")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let content = source.appendingPathComponent("version")
        try Data("99-preview".utf8).write(to: content)
        let transaction = IFFileTransaction(target: target)
        try transaction.prepare(source)
        try check(!fm.fileExists(atPath: target.path), "prepare does not publish")
        try transaction.commit(); try transaction.clean()
        try check(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8) == "99-preview", "first installation")
        try Data("1-old-build".utf8).write(to: content)
        try transaction.prepare(source)
        try check(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8) == "99-preview", "old intact until replacement")
        try transaction.commit(); try transaction.clean()
        try check(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8) == "1-old-build", "upgrade permits arbitrary versions and paths")
        let failure = IFFileTransaction(target: target, copy: { _, to in
            try fm.createDirectory(at: to, withIntermediateDirectories: false)
            throw CocoaError(.fileWriteOutOfSpace)
        })
        do { try failure.prepare(source); throw IFInstallerError.invalid("copy must fail") }
        catch let error as CocoaError { try check(error.code == .fileWriteOutOfSpace, "original copy error") }
        try check(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8) == "1-old-build", "failed copy preserves old")
        try check(try fm.contentsOfDirectory(atPath: parent.path) == ["InkFlow.app"], "no staging, journal or persistent backup")
        try transaction.prepare(source); try transaction.clean()
        try check(try fm.contentsOfDirectory(atPath: parent.path) == ["InkFlow.app"], "cancel cleans prepared app")
        print("PASS real filesystem: first install, replacement, failed partial copy preserves old, cleanup, no backup, no path/version gates")
    }
    @MainActor static func main() async throws {
        try await trialTests()
        try fileTests()
        let files = Files(), sources = Sources(), lifecycle = Lifecycle()
        let coordinator = IFInstallerCoordinator(files: files, sources: sources, lifecycle: lifecycle, pause: {})
        await coordinator.perform(.installAndEnable)
        try check(coordinator.state == .installedEnabled, "first install without ASCII source")
        try check(sources.calls == ["register", "enable", "enable", "select"], "register missing, enable parent+mode, select")
        await coordinator.perform(.retryActivation)
        try check(sources.calls.filter { $0 == "register" }.count == 1, "do not register existing source")
        try check(await files.counts().0 == 1, "retry does not reinstall")
        for operation in ["snapshot", "register", "enable", "select"] {
            let f = Files(), s = Sources(), l = Lifecycle(); s.failure = operation
            let c = IFInstallerCoordinator(files: f, sources: s, lifecycle: l, pause: {})
            await c.perform(.installAndEnable)
            guard case .failed(let installed, let message) = c.state else { throw IFInstallerError.invalid("API failure hidden") }
            try check(installed && message.contains(operation) && message.contains("-50"), "API error correctly reported")
            s.failure = ""; await c.perform(.retryActivation)
            try check(c.state == .installedEnabled, "API retry")
        }
        let stoppedFiles = Files(), stoppedSources = Sources(), stoppedLifecycle = Lifecycle()
        stoppedLifecycle.error = .terminationTimeout
        let stopped = IFInstallerCoordinator(files: stoppedFiles, sources: stoppedSources, lifecycle: stoppedLifecycle, pause: {})
        await stopped.perform(.installAndEnable)
        let counts = await stoppedFiles.counts()
        try check(counts.0 == 0 && counts.1 == 1, "termination failure preserves old and cleans staging")
        print("PASS fake backends: TIS result/errors/retry, no ASCII/name gates, bounded termination failure prevents commit; no system mutations")
    }
}
