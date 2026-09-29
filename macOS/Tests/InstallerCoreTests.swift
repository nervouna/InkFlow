import Foundation
import Darwin
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
    @MainActor private final class ControlledProcess: IFTrialInstalledProcess {
        enum QuitBehavior { case exit, delayedExit, decline, keepRunning, exitAndDecline }
        private let child = Process()
        private let input = Pipe()
        private var exitTask: Task<Void, Never>?
        var processIdentifier: pid_t { child.processIdentifier }
        var isTerminated = false
        var executableURL: URL?
        var bundleURL: URL?
        var quitBehavior = QuitBehavior.exit
        var terminationRequests = 0

        init() throws {
            child.executableURL = URL(fileURLWithPath: "/bin/cat")
            child.standardInput = input
            child.standardOutput = FileHandle.nullDevice
            try child.run()
        }

        func finish() {
            exitTask?.cancel()
            exitTask = nil
            try? input.fileHandleForWriting.close()
            child.waitUntilExit()
        }

        func terminate() -> Bool {
            terminationRequests += 1
            switch quitBehavior {
            case .exit: finish(); return true
            case .delayedExit:
                exitTask = Task {
                    try? await Task.sleep(for: .milliseconds(5))
                    if !Task.isCancelled { finish() }
                }
                return true
            case .decline: return false
            case .keepRunning: return true
            case .exitAndDecline: finish(); return false
            }
        }
    }

    @MainActor static func trialExitObservationTest() async throws {
        let process = try ControlledProcess()
        defer { process.finish() }
        let processes = IFTrialSystemProcesses(application: { _ in process }, terminationTimeout: .milliseconds(20))
        try await processes.stop([process.processIdentifier], at: URL(fileURLWithPath: "/bin/cat"))
        try check(process.terminationRequests == 1 && !process.isTerminated,
                  "developer stop accepts actual child exit while AppKit observation stays stale")
        let unrelated = try ControlledProcess()
        defer { unrelated.finish() }
        let guarded = IFTrialSystemProcesses(application: { _ in unrelated })
        do {
            try await guarded.stop([unrelated.processIdentifier], at: URL(fileURLWithPath: "/tmp/unrelated/InkFlow.app"))
            throw IFInstallerError.invalid("changed executable identity must refuse termination")
        } catch is IFInputError {}
        try check(unrelated.terminationRequests == 0,
                  "ownership mismatch must not request termination of the live child")
        let missing = IFTrialSystemProcesses(application: { _ in nil })
        try await missing.stop([process.processIdentifier], at: URL(fileURLWithPath: "/bin/cat"))
        do {
            try await missing.stop([unrelated.processIdentifier], at: URL(fileURLWithPath: "/bin/cat"))
            throw IFInstallerError.invalid("unidentified live PID must refuse replacement")
        } catch is IFInputError {}
        print("PASS developer stop: stale exit, ownership mismatch and missing application identity")
    }

    @MainActor static func trialPrepareExitObservationTest() async throws {
        let process = try ControlledProcess()
        defer { process.finish() }
        let unrelated = URL(fileURLWithPath: "/tmp/installer-unrelated/InkFlow.app")
        process.executableURL = unrelated
        let processes = IFTrialSystemProcesses(application: { pid in
            pid == process.processIdentifier ? process : nil
        }, installedApplications: { [process] }, terminationTimeout: .milliseconds(20))
        try check(try processes.installedPIDs(at: unrelated).isEmpty,
                  "live executable path takes precedence over cached unrelated path")
        guard let path = IFTrialSystemProcesses.executablePath(process.processIdentifier) else {
            throw IFInstallerError.invalid("controlled child executable must be observable")
        }
        let target = URL(fileURLWithPath: path)
        process.executableURL = target
        let sources = TrialSources()
        let trial = IFTrialInstallation(sources: sources, processes: processes)
        let state = try await trial.prepare(target: target, build: "12")
        try check(state.oldPIDs == [process.processIdentifier] && process.terminationRequests == 1,
                  "prepare stops the live owned child through the system adapter")
        try check(!process.isTerminated && sources.selected == "ascii",
                  "stale cached target after child exit must not be reported as a restarted process")
        print("PASS developer prepare: live path ownership, stale cached target after real child exit (fake input sources)")
    }

    @MainActor private static func stopControlledProcesses(_ processes: [ControlledProcess], native: Bool,
                                                          timeout: Duration = .milliseconds(20)) async throws {
        if native {
            try await IFSystemLifecycle(applications: { processes }, terminationTimeout: timeout).terminateOld()
        } else {
            let system = IFTrialSystemProcesses(application: { pid in
                processes.first { $0.processIdentifier == pid }
            }, terminationTimeout: timeout)
            try await system.stop(processes.map(\.processIdentifier), at: URL(fileURLWithPath: "/bin/cat"))
        }
    }

    @MainActor static func systemTerminationTests() async throws {
        try check(IFInstallationProcessLifecycle.terminationTimeout == .seconds(10),
                  "production graceful-termination deadline remains ten seconds")
        for native in [true, false] {
            try await stopControlledProcesses([], native: native)
            for behavior: ControlledProcess.QuitBehavior in [.exit, .delayedExit, .exitAndDecline] {
                let process = try ControlledProcess()
                defer { process.finish() }
                process.quitBehavior = behavior
                try await stopControlledProcesses([process], native: native, timeout: .seconds(2))
                try check(process.terminationRequests == 1 && !process.isTerminated &&
                          IFInstallationProcessLifecycle.hasExited(applicationTerminated: false, processID: process.processIdentifier),
                          "both system adapters accept real exit despite stale AppKit state or an exit racing the request")
            }
            do {
                let process = try ControlledProcess()
                defer { process.finish() }
                process.finish()
                process.quitBehavior = .decline
                try await stopControlledProcesses([process], native: native)
                try check(process.terminationRequests == 0, "already-exited process needs no normal quit request")
            }
            for declined in [true, false] {
                let process = try ControlledProcess()
                defer { process.finish() }
                process.quitBehavior = declined ? .decline : .keepRunning
                let start = ContinuousClock.now
                do {
                    try await stopControlledProcesses([process], native: native)
                    throw IFInstallerError.invalid("live child must refuse replacement")
                } catch {
                    if native {
                        try check(error as? IFInstallerError == (declined ? .terminationDeclined : .terminationTimeout),
                                  "native installer preserves declined/timeout errors")
                    } else {
                        let message = declined ? "process \(process.processIdentifier) declined normal termination; installation unchanged"
                            : "normal termination timed out; installation unchanged"
                        try check(error as? IFInputError == .unavailable(message),
                                  "developer installer preserves declined/timeout errors")
                    }
                }
                let elapsed = start.duration(to: .now)
                try check(elapsed < .seconds(2) && (declined || elapsed >= .milliseconds(20)),
                          "injected short deadline is bounded and is not reported before expiry")
                try check(process.terminationRequests == 1 &&
                          !IFInstallationProcessLifecycle.hasExited(applicationTerminated: false, processID: process.processIdentifier),
                          "declined/timed-out child remains alive without force termination")
            }
        }
        print("PASS both system adapters: stale and delayed exit, pre-exited child, request race, live refusal, bounded timeout, exact errors, no force termination")
    }

    @MainActor static func exitPredicateTests() throws {
        let process = try ControlledProcess()
        defer { process.finish() }
        let pid = process.processIdentifier
        try check(!IFInstallationProcessLifecycle.hasExited(applicationTerminated: false, processID: pid), "live process must block replacement")
        process.finish()
        try check(IFInstallationProcessLifecycle.hasExited(applicationTerminated: false, processID: pid), "exited process must not time out when AppKit state is stale")
        for status: Int32 in [0, EPERM, EINVAL] {
            try check(!IFInstallationProcessLifecycle.hasExited(applicationTerminated: false, processID: pid, probe: { _ in status }), "unknown or live process status must block replacement")
        }
        for invalid: pid_t in [-1, 0] {
            try check(!IFInstallationProcessLifecycle.hasExited(applicationTerminated: false, processID: invalid, probe: { _ in fatalError("invalid PID must not be probed") }), "invalid PID cannot prove exit")
        }
        try check(IFInstallationProcessLifecycle.hasExited(applicationTerminated: true, processID: -1, probe: { _ in fatalError("confirmed exit needs no probe") }), "AppKit-confirmed exit remains sufficient")
        print("PASS shared exit observation: live child, exited child with stale AppKit state, permission/unknown errors, invalid PIDs")
    }

    @MainActor private final class TrialProcesses: IFTrialProcessOperations {
        var pids: [Int32] = [42]
        var failure = ""
        var launches = 0
        func installedPIDs(at target: URL) -> [Int32] { pids }
        func stop(_ pids: [Int32], at target: URL) throws {
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
        let child = Process()
        let input = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/cat")
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        try child.run()
        let childPID = child.processIdentifier
        try check(!IFInstallationProcessLifecycle.hasExited(applicationTerminated: false, processID: childPID), "trial lifecycle must keep waiting for a live PID")
        try input.fileHandleForWriting.close()
        child.waitUntilExit()
        try check(IFInstallationProcessLifecycle.hasExited(applicationTerminated: false, processID: childPID), "trial lifecycle must accept an exited PID when AppKit state is stale")
        for status: Int32 in [0, EPERM, EINVAL] {
            try check(!IFInstallationProcessLifecycle.hasExited(applicationTerminated: false, processID: childPID, probe: { _ in status }), "trial lifecycle must fail closed for live or unknown probe results")
        }
        for invalid: pid_t in [-1, 0] {
            try check(!IFInstallationProcessLifecycle.hasExited(applicationTerminated: false, processID: invalid, probe: { _ in fatalError("invalid PID must not be probed") }), "trial lifecycle cannot prove exit for an invalid PID")
        }
        try check(IFInstallationProcessLifecycle.hasExited(applicationTerminated: true, processID: -1, probe: { _ in fatalError("confirmed exit needs no probe") }), "trial lifecycle accepts AppKit-confirmed exit")
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
        try check(IFTrialSystemProcesses.ownsRunningProcess(executablePath: "/tmp/input methods/InkFlow.app/Contents/MacOS/InkFlow", cachedPath: nil, target: target) == true, "current target executable accepted before termination")
        try check(IFTrialSystemProcesses.ownsRunningProcess(executablePath: "/tmp/other.app/Contents/MacOS/other", cachedPath: target.path, target: target) == false, "current executable identity overrides stale cached target URL")
        try check(IFTrialSystemProcesses.ownsRunningProcess(executablePath: nil, cachedPath: target.path, target: target) == true, "target-bound cached URL remains the missing-image fallback")
        try check(IFTrialSystemProcesses.ownsRunningProcess(executablePath: nil, cachedPath: nil, target: target) == nil, "unknown process identity fails closed")
        print("PASS trial lifecycle: stale AppKit exit observation; declined/timeout/restarted block prepare; fresh process/state; postfailure; first install; scoped ownership (fake backends, no desktop mutation)")
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
        let oldIdentity = try fm.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber
        let newIdentity = try fm.attributesOfItem(atPath: source.path)[.systemFileNumber] as? NSNumber
        try IFAtomicAppReplacement.replace(candidate: source, target: target)
        try check(try fm.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber == newIdentity,
                  "atomic replacement publishes the candidate inode")
        try check(try fm.attributesOfItem(atPath: source.path)[.systemFileNumber] as? NSNumber == oldIdentity,
                  "atomic replacement retains the original inode in the staging slot")
        do {
            try IFAtomicAppReplacement.replace(candidate: root.appendingPathComponent("missing.app"), target: target)
            throw IFInstallerError.invalid("missing candidate must fail")
        } catch is IFInputError {}
        try check(try fm.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber == newIdentity,
                  "failed replacement leaves the installed app intact")
        print("PASS real filesystem: first install, replacement, failed partial copy preserves old, cleanup, no backup, no path/version gates")
    }
    @MainActor static func main() async throws {
        try await trialExitObservationTest()
        try await trialPrepareExitObservationTest()
        try await systemTerminationTests()
        try exitPredicateTests()
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
