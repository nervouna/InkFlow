import Foundation
import Darwin

private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw IFInstallerError.invalid("TEST: " + message) }
}
private func mustFail(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw IFInstallerError.invalid("TEST: expected failure")
}
private func makeBundle(_ url: URL, _ value: String) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data(value.utf8).write(to: url.appendingPathComponent("identity"))
}
private func identity(_ url: URL) throws -> String {
    try String(contentsOf: url.appendingPathComponent("identity"), encoding: .utf8)
}
private func transaction(_ root: URL, archive: ((URL, URL) throws -> Void)? = nil) -> IFFileTransaction {
    IFFileTransaction(target: root.appendingPathComponent("Input Methods/InkFlow.app"),
                      state: root.appendingPathComponent("state"),
                      verify: { _ = try identity($0) },
                      archive: archive ?? { source, destination in try Data(identity(source).utf8).write(to: destination) })
}
private func freshRoot() throws -> URL {
    let root = URL(fileURLWithPath: "/private/tmp/inkflow-installer-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ item: String) { lock.lock(); defer { lock.unlock() }; entries.append(item) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return entries }
}
private let newApp = IFVerifiedApp(version: .init(version: "0.3.0", build: "3"), executable: "InkFlow", codeHash: Data([3]))
private let oldApp = IFVerifiedApp(version: .init(version: "0.1.0", build: "2"), executable: "InkFlow", codeHash: Data([2]))

private actor FakeFiles: IFInstallerFileOperations {
    nonisolated let target = URL(fileURLWithPath: "/private/tmp/never-installed/InkFlow.app")
    let trace: Trace
    let old: IFVerifiedApp?
    let replacement: Bool
    var archiveFailure = false
    var recoveryFailures = 0
    init(_ trace: Trace, old: IFVerifiedApp? = nil, replacement: Bool = true) {
        self.trace = trace; self.old = old; self.replacement = replacement
    }
    func prepare() -> IFInstallPreparation {
        trace.add("prepare"); return .init(installed: old, candidate: newApp, needsReplacement: replacement)
    }
    func injectArchiveFailure() { archiveFailure = true; recoveryFailures = 1 }
    func commit() throws {
        trace.add("commit")
        if archiveFailure { throw IFInstallerError.installedRecoveryRequired("injected archive failure after verified commit") }
    }
    func resumeRecovery() throws -> IFVerifiedApp {
        trace.add("recover")
        if recoveryFailures > 0 { recoveryFailures -= 1; throw IFInstallerError.invalid("archive still unavailable") }
        return newApp
    }

    func release(cancelPrepared: Bool) { trace.add(cancelPrepared ? "cancel-files" : "release") }
    func validateInstalled() -> IFVerifiedApp { trace.add("validate"); return newApp }
}

@MainActor private final class FakeSources: IFInputSourceOperations {
    let trace: Trace
    var registered = true
    var parentEnabled = false
    var modeEnabled = false
    var selection = "ascii"
    var duplicate = false
    var refuseEnable = false
    var refuseSelection = false
    var registerFailures = 0
    var delayRegistration = 0
    var registrationPending = false
    var apiFailure = false
    var refuseFallback = false
    var fallbackEnabled = true
    init(_ trace: Trace) { self.trace = trace }
    func snapshot() throws -> IFInputRoster {
        if apiFailure { throw IFInputError.unavailable("simulated API unavailable") }
        if registrationPending {
            if delayRegistration == 0 { registered = true; registrationPending = false }
            else { delayRegistration -= 1 }
        }
        let parent = IFInputSource(id: IFInputIdentity.bundleID, bundleID: IFInputIdentity.bundleID,
            name: "InkFlow", enabled: parentEnabled, selectable: false, keyboardMode: false, ascii: false)
        let mode = IFInputSource(id: IFInputIdentity.modeID, bundleID: IFInputIdentity.bundleID,
            name: "墨流拼音", enabled: modeEnabled, selectable: true, keyboardMode: true, ascii: false)
        let ascii = IFInputSource(id: "ascii", bundleID: "system", name: "ABC", enabled: fallbackEnabled,
            selectable: true, keyboardMode: false, ascii: true)
        var installed = registered ? [parent, mode] : []
        if duplicate { installed.append(mode) }
        return .init(installed: installed, enabled: (fallbackEnabled ? [ascii] : []) + installed.filter(\.enabled), selectedID: selection)
    }
    func register(at url: URL) throws {
        trace.add("register")
        if registerFailures > 0 { registerFailures -= 1; throw IFInputError.api("TISRegisterInputSource", -50) }
        registrationPending = true
    }
    func enable(_ id: String) throws {
        trace.add(id == IFInputIdentity.bundleID ? "enable-parent" : "enable-child")
        if refuseEnable { return }
        if id == IFInputIdentity.bundleID { parentEnabled = true }
        else {
            try check(parentEnabled, "child enabled before parent")
            modeEnabled = true
        }
    }
    func select(_ id: String) {
        trace.add(id == "ascii" ? "fallback" : "select")
        if !refuseSelection && !(id == "ascii" && refuseFallback) { selection = id }
    }
}
@MainActor private final class FakeLifecycle: IFInstallerLifecycleOperations {
    let trace: Trace
    var terminationFailure: IFInstallerError?
    var observation: IFRuntimeObservation = .waitingForSystemLaunch
    var observationFailure = false
    var onObservation: (() -> Void)?
    var initializationReads = 0
    init(_ trace: Trace) { self.trace = trace }
    func inspectForReplacement(_ app: IFVerifiedApp, at target: URL) { trace.add("inspect") }
    func terminateOld(_ app: IFVerifiedApp, at target: URL) throws {
        trace.add("terminate"); if let terminationFailure { throw terminationFailure }
    }
    func assertStopped(_ app: IFVerifiedApp?, at target: URL) { trace.add("stopped") }
    func observe(_ app: IFVerifiedApp, at target: URL) throws -> IFRuntimeObservation {
        trace.add("observe"); onObservation?()
        if observationFailure { throw IFInstallerError.invalid("injected observation failure") }
        if initializationReads > 0 { initializationReads -= 1; return .initializing }
        return observation
    }

}

@main private struct InstallerCoreTests {
    static func fileTests() throws {
        let root = try freshRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("payload.bundle")
        try makeBundle(source, "new")
        let tx = transaction(root)
        try tx.lock()
        let contender = transaction(root)
        try mustFail { try contender.lock() }
        try tx.prepare(source)
        try tx.commit()
        try check(identity(tx.target) == "new", "exclusive first install")
        tx.unlock()
        try contender.lock(); contender.unlock()
        print("PASS exclusive install and lock contention")

        try Data("old".utf8).write(to: tx.target.appendingPathComponent("identity"))
        try tx.lock(); defer { tx.unlock() }
        try tx.prepare(source)
        try tx.commit()
        try check(identity(tx.target) == "new", "real swap")
        let backups = try FileManager.default.contentsOfDirectory(at: tx.state, includingPropertiesForKeys: nil).filter { $0.pathExtension == "zip" }
        try check(backups.count == 1 && String(contentsOf: backups[0], encoding: .utf8) == "old", "old archived outside app")
        print("PASS real SWAP and old backup archive")

        try Data("old".utf8).write(to: tx.target.appendingPathComponent("identity"))
        try tx.prepare(source)
        try mustFail {
            try tx.commit { path in
                if path == tx.target { throw IFInstallerError.invalid("injected post-swap validation") }
            }
        }
        try check(identity(tx.target) == "old", "post-verification rollback")
        print("PASS rollback on post-swap validation failure")

        try tx.prepare(source)
        try check(tx.recover() == false, "prepared interruption")
        try check(identity(tx.target) == "old", "prepared recovery preserves old")
        try tx.prepare(source)
        let moved = root.appendingPathComponent("external-old.bundle")
        try FileManager.default.moveItem(at: tx.target, to: moved)
        try makeBundle(tx.target, "unknown")
        try mustFail { _ = try tx.recover() }
        try check(identity(tx.target) == "unknown", "recovery never overwrites unknown target")
        print("PASS prepared recovery and unknown-target refusal")

        let linkRoot = try freshRoot(); defer { try? FileManager.default.removeItem(at: linkRoot) }
        let link = linkRoot.appendingPathComponent("state")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        try mustFail { try IFFileSafety.privateDirectory(link) }
        try IFFileSafety.noLinks(URL(fileURLWithPath: "/tmp"))
        try check(IFFileSafety.canonicalTemporaryRoot(URL(fileURLWithPath: "/var/folders/test")).path == "/private/var/folders/test", "canonical Apple temporary root")
        print("PASS symlink refusal and canonical temporary root")
    }
    static func crashChild(_ root: URL) throws -> Never {
        let tx = transaction(root) { old, destination in
            try Data(identity(old).utf8).write(to: destination)
            // Simulate death after an earlier archive publication, before clearing the journal.
            let published = root.appendingPathComponent("state/backup-interrupted.zip")
            try FileManager.default.moveItem(at: destination, to: published)
            _exit(23)
        }
        try tx.lock(); try tx.prepare(root.appendingPathComponent("payload.bundle")); try tx.commit()
        throw IFInstallerError.invalid("crash injection did not execute")
    }
    static func crashTests() throws {
        let root = try freshRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle(root.appendingPathComponent("payload.bundle"), "new")
        try makeBundle(root.appendingPathComponent("Input Methods/InkFlow.app"), "old")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--crash", root.path]
        try child.run()
        let deadline = ContinuousClock.now + .seconds(5)
        while child.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if child.isRunning { child.terminate(); throw IFInstallerError.invalid("Crash test watchdog") }
        try check(child.terminationStatus == 23, "child terminated at crash window")
        let tx = transaction(root); try tx.lock(); defer { tx.unlock() }
        try check(tx.recover(), "recover after published archive")
        try check(identity(tx.target) == "new", "recovery retains committed new version")
        try check(!tx.recover(), "recovery idempotent")
        try check(FileManager.default.fileExists(atPath: root.appendingPathComponent("state/backup-interrupted.zip").path), "existing archive preserved")
        print("PASS real subprocess crash after SWAP/archive publication and idempotent recovery")
    }
    @MainActor static func coordinatorTests() async throws {
        for scenario in ["first", "upgrade", "same", "timeout", "declined", "denied-enable", "denied-select", "duplicates", "api-error", "register-failure", "missing-upgrade", "delayed-registration", "pending-registration"] {
            let trace = Trace()
            // One trace gives a single ordered record across actor and main-actor boundaries.
            let tis = FakeSources(trace), lifecycle = FakeLifecycle(trace)
            let old: IFVerifiedApp? = ["first", "register-failure", "delayed-registration", "pending-registration"].contains(scenario) ? nil : oldApp
            let files = FakeFiles(trace, old: old, replacement: scenario != "same")
            let coordinator = IFInstallerCoordinator(files: files, sources: tis, lifecycle: lifecycle, pause: {})
            tis.registered = old != nil
            if scenario == "delayed-registration" { tis.delayRegistration = 3 }
            if scenario == "pending-registration" { tis.delayRegistration = 100 }
            if scenario == "timeout" { lifecycle.terminationFailure = .terminationTimeout }
            if scenario == "declined" { lifecycle.terminationFailure = .terminationDeclined }
            if scenario == "denied-enable" { tis.refuseEnable = true }
            if scenario == "denied-select" { tis.refuseSelection = true }
            if scenario == "duplicates" { tis.duplicate = true }
            if scenario == "api-error" { tis.apiFailure = true }
            if scenario == "register-failure" { tis.registerFailures = 1 }
            if scenario == "missing-upgrade" { tis.registered = false }
            await coordinator.perform(.installAndEnable)
            let events = trace.values
            if ["timeout", "declined", "duplicates", "api-error"].contains(scenario) {
                try check(!events.contains("commit"), scenario + " must preserve old files")
                guard case .failed(installed: false, _) = coordinator.state else { throw IFInstallerError.invalid("expected preinstall failure") }
            } else if scenario == "register-failure" {
                guard case .installedRegistrationFailed = coordinator.state else { throw IFInstallerError.invalid("registration API error distinct") }
                await coordinator.perform(.repairMissingRegistration)
                try check(trace.values.filter { $0 == "register" }.count == 2, "explicit registration retry after API failure")
                try check(trace.values.filter { $0 == "commit" }.count == 1, "registration retry must not reinstall")
                try check(coordinator.state == .installedEnabled(.waitingForSystemLaunch), "registration repaired")
            } else if scenario == "missing-upgrade" {
                try check(coordinator.state == .installedMissingRegistration && !events.contains("register"), "upgrade missing source needs explicit repair")
                await coordinator.perform(.repairMissingRegistration)
                try check(trace.values.filter { $0 == "register" }.count == 1, "explicit missing registration branch")
            } else if scenario == "pending-registration" {
                await coordinator.perform(.repairMissingRegistration)
                try check(trace.values.filter { $0 == "register" }.count == 1, "successful pending registration not repeatedly registered")
            } else if ["denied-enable", "denied-select"].contains(scenario) {
                guard case .installedAwaitingApproval = coordinator.state else { throw IFInstallerError.invalid("declined activation not API error") }
                tis.refuseEnable = false; tis.refuseSelection = false
                await coordinator.perform(.retryActivation)
                try check(trace.values.filter { $0 == "prepare" }.count == 1, "activation retry cannot reinstall")
                try check(coordinator.state == .installedEnabled(.waitingForSystemLaunch), "activation resumed")
            } else {
                try check(coordinator.state == .installedEnabled(.waitingForSystemLaunch), scenario + " deferred launch is success waiting")
            }
            if scenario == "upgrade" {
                try check(!events.contains("register"), "normal upgrade never registers")
                for (before, after) in [("fallback", "terminate"), ("terminate", "commit"), ("commit", "select"), ("enable-parent", "enable-child")] {
                    try check(events.firstIndex(of: before)! < events.firstIndex(of: after)!, "branch ordering \(before) before \(after)")
                }
            }
            if scenario == "same" { try check(!events.contains("commit") && !events.contains("terminate"), "same signed version activation only") }
            print("PASS coordinator: \(scenario)")
        }
    }
    static func receiptTests() throws {
        let process = IFProcessIdentity(pid: 123, uid: getuid(), seconds: 50, microseconds: 60, executablePath: "/test/InkFlow")
        var receipt = IFRuntimeReceipt(pid: 123, startSeconds: 50, startMicroseconds: 60, executablePath: process.executablePath,
                                       version: newApp.version.version, build: newApp.version.build)
        try check(IFReceiptMatcher.matches(receipt, process: process, app: newApp), "exact receipt")
        receipt.schemaVersion = 2
        try check(!IFReceiptMatcher.matches(receipt, process: process, app: newApp), "unsupported receipt schema")
        receipt.schemaVersion = 1
        let reused = IFProcessIdentity(pid: 123, uid: getuid(), seconds: 51, microseconds: 60, executablePath: process.executablePath)
        try check(!IFReceiptMatcher.matches(receipt, process: reused, app: newApp), "PID reuse")
        try check(!IFReceiptMatcher.matches(receipt, process: process, app: oldApp), "stale version")
        let foreign = IFProcessIdentity(pid: 123, uid: getuid() + 1, seconds: 50, microseconds: 60, executablePath: process.executablePath)
        try check(!IFReceiptMatcher.matches(receipt, process: foreign, app: newApp), "foreign UID")
        receipt.engineReady = true; receipt.serverCreated = true
        try check(IFReceiptMatcher.observation(receipt) == .ready, "ready requires both initialized components")
        receipt.terminating = true
        try check(IFReceiptMatcher.observation(receipt) == .terminating, "terminating cannot be ready")
        print("PASS receipt identity/version/schema/UID/PID-reuse and terminating checks")

    }
    @MainActor static func main() async {
        do {
            if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--crash" {
                try crashChild(URL(fileURLWithPath: CommandLine.arguments[2]))
            }
            try fileTests(); try crashTests(); try receiptTests(); try archiveFailureTests()
            try await coordinatorTests()
            try await reviewRegressionTests()
            print("PASS installer focused tests; no real TIS or daily IME calls")
        } catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
    }
}

private extension InstallerCoreTests {
    static func archiveFailureTests() throws {
        let root = try freshRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle(root.appendingPathComponent("payload.bundle"), "new")
        try makeBundle(root.appendingPathComponent("Input Methods/InkFlow.app"), "old")
        let tx = transaction(root) { _, _ in throw IFInstallerError.invalid("injected archive failure") }
        try tx.lock(); try tx.prepare(root.appendingPathComponent("payload.bundle"))
        do {
            try tx.commit()
            throw IFInstallerError.invalid("expected committed archive failure")
        } catch IFInstallerError.installedRecoveryRequired { }
        try check(identity(tx.target) == "new", "archive failure preserves verified installed code")
        try check(FileManager.default.fileExists(atPath: tx.state.appendingPathComponent("transaction.json").path), "archive failure preserves journal")
        tx.unlock()
        let recovery = transaction(root); try recovery.lock(); defer { recovery.unlock() }
        try check(recovery.recover(), "archive-only recovery resumes committed transaction")
        try check(identity(tx.target) == "new" && !recovery.recover(), "recovery never reinstalls and is idempotent")
        print("PASS verified commit archive failure preserves journal and resumes recovery")
    }
    @MainActor static func reviewRegressionTests() async throws {
        for scenario in ["initializing", "terminating", "unverified", "observation-error", "fallback-refused", "fallback-disabled", "vanished", "cold-ready", "deferred"] {
            for firstInstall in [true, false] {
                let trace = Trace()
                let sources = FakeSources(trace), lifecycle = FakeLifecycle(trace)
                let files = FakeFiles(trace, old: firstInstall ? nil : oldApp)
                let coordinator = IFInstallerCoordinator(files: files, sources: sources, lifecycle: lifecycle, pause: {})
                sources.registered = !firstInstall
                switch scenario {
                case "initializing": lifecycle.observation = .initializing
                case "terminating": lifecycle.observation = .terminating
                case "unverified": lifecycle.observation = .unverifiedReceipt
                case "observation-error": lifecycle.observationFailure = true
                case "fallback-refused":
                    lifecycle.observation = .terminating
                    lifecycle.onObservation = { sources.refuseFallback = true }
                case "fallback-disabled":
                    lifecycle.observation = .terminating
                    lifecycle.onObservation = { sources.fallbackEnabled = false }
                case "vanished": lifecycle.initializationReads = 1
                case "cold-ready": lifecycle.initializationReads = 20; lifecycle.observation = .ready
                default: break
                }
                await coordinator.perform(.installAndEnable)
                if ["cold-ready", "deferred"].contains(scenario) {
                    try check(coordinator.state == .installedEnabled(scenario == "deferred" ? .waitingForSystemLaunch : .ready), "usable or genuinely deferred launch retained")
                    try check(sources.selection == IFInputIdentity.modeID, "successful path keeps Hans selected")
                    if scenario == "deferred" { try check(trace.values.filter { $0 == "observe" }.count == 1, "deferred launch returns early") }
                } else {
                    let restorationFails = scenario.hasPrefix("fallback-")
                    guard case .installedRuntimeFailed(let reason, let restored) = coordinator.state else {
                        throw IFInstallerError.invalid("runtime failure must have explicit installed state")
                    }
                    try check(!reason.isEmpty && restored == !restorationFails, "restoration result is honest")
                    try check(sources.selection == (restorationFails ? IFInputIdentity.modeID : "ascii"), "fallback selection verified")
                    if scenario == "initializing" { try check(trace.values.filter { $0 == "observe" }.count == 41, "cold bootstrap gets 40 polling intervals") }
                    if scenario == "vanished" { try check(reason.contains("exited during startup"), "live process disappearance is not deferred launch") }
                    let registrations = trace.values.filter { $0 == "register" }.count
                    let commits = trace.values.filter { $0 == "commit" }.count
                    lifecycle.observation = .ready; lifecycle.observationFailure = false; lifecycle.onObservation = nil
                    sources.refuseFallback = false; sources.fallbackEnabled = true
                    await coordinator.perform(.retryActivation)
                    try check(coordinator.state == .installedEnabled(.ready), "runtime retry succeeds with fresh fallback")
                    try check(trace.values.filter { $0 == "register" }.count == registrations && trace.values.filter { $0 == "commit" }.count == commits, "runtime retry never registers or reinstalls")
                }
                print("PASS runtime fallback: \(scenario), first=\(firstInstall)")
            }
        }
        let trace = Trace()
        let sources = FakeSources(trace)
        let files = FakeFiles(trace, old: oldApp), lifecycle = FakeLifecycle(trace)
        let coordinator = IFInstallerCoordinator(files: files, sources: sources, lifecycle: lifecycle, pause: {})
        await files.injectArchiveFailure()
        await coordinator.perform(.installAndEnable)
        guard case .installedRecoveryRequired = coordinator.state else { throw IFInstallerError.invalid("archive failure must report installed recovery state") }
        try check(coordinator.state.actions == [.resumeRecovery], "recovery state cannot reinstall or activate prematurely")
        try check(!trace.values.contains("cancel-files") && trace.values.contains("release"), "committed journal is not cancelled")
        await coordinator.perform(.resumeRecovery)
        guard case .installedRecoveryRequired = coordinator.state else { throw IFInstallerError.invalid("failed recovery remains resumable") }
        await coordinator.perform(.resumeRecovery)
        try check(coordinator.state == .installedEnabled(.waitingForSystemLaunch), "recovery continues to activation")
        try check(trace.values.filter { $0 == "prepare" }.count == 1 && trace.values.filter { $0 == "commit" }.count == 1 && !trace.values.contains("register"), "recovery does not reinstall or register upgrade")
        print("PASS coordinator installed recovery state and retry without reinstall")
    }
}
