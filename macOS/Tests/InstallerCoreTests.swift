import Foundation

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
@MainActor private final class Sources: IFInputSourceOperations {
    var registered = false
    var enabled: Set<String> = []
    var selected = ""
    var calls: [String] = []
    var failure = ""
    var refuses = false
    func source(_ id: String) -> IFInputSource {
        .init(id: id, bundleID: IFInputIdentity.bundleID, name: "Any localized name", enabled: enabled.contains(id), selectable: true, keyboardMode: true, ascii: false)
    }
    func snapshot() throws -> IFInputRoster {
        if failure == "snapshot" { throw IFInputError.api("snapshot", -50) }
        let all = registered ? [source(IFInputIdentity.bundleID), source(IFInputIdentity.modeID)] : []
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
