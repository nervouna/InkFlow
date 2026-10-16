import Foundation
import Darwin
@testable import InkFlowInputSources

private struct TestFailure: Error { let message: String }
private func check(_ value: Bool, _ message: String) throws {
    if !value { throw TestFailure(message: "TEST: \(message)") }
}

@main struct InputSourceLifecycleTests {
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
            throw TestFailure(message: "changed executable identity must refuse termination")
        } catch is IFInputError {}
        try check(unrelated.terminationRequests == 0,
                  "ownership mismatch must not request termination of the live child")
        let missing = IFTrialSystemProcesses(application: { _ in nil })
        try await missing.stop([process.processIdentifier], at: URL(fileURLWithPath: "/bin/cat"))
        do {
            try await missing.stop([unrelated.processIdentifier], at: URL(fileURLWithPath: "/bin/cat"))
            throw TestFailure(message: "unidentified live PID must refuse replacement")
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
            throw TestFailure(message: "controlled child executable must be observable")
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

    @MainActor private static func stopControlledProcesses(_ processes: [ControlledProcess],
                                                          timeout: Duration = .milliseconds(20)) async throws {
        let system = IFTrialSystemProcesses(application: { pid in
            processes.first { $0.processIdentifier == pid }
        }, terminationTimeout: timeout)
        try await system.stop(processes.map(\.processIdentifier), at: URL(fileURLWithPath: "/bin/cat"))
    }

    @MainActor static func systemTerminationTests() async throws {
        try check(IFInstallationProcessLifecycle.terminationTimeout == .seconds(10),
                  "production graceful-termination deadline remains ten seconds")
        try await stopControlledProcesses([])
        for behavior: ControlledProcess.QuitBehavior in [.exit, .delayedExit, .exitAndDecline] {
            let process = try ControlledProcess()
            defer { process.finish() }
            process.quitBehavior = behavior
            try await stopControlledProcesses([process], timeout: .seconds(2))
            try check(process.terminationRequests == 1 && !process.isTerminated &&
                      IFInstallationProcessLifecycle.hasExited(applicationTerminated: false, processID: process.processIdentifier),
                      "real exit accepted despite stale AppKit state or an exit racing the request")
        }
        do {
            let process = try ControlledProcess()
            defer { process.finish() }
            process.finish()
            process.quitBehavior = .decline
            try await stopControlledProcesses([process])
            try check(process.terminationRequests == 0, "already-exited process needs no normal quit request")
        }
        for declined in [true, false] {
            let process = try ControlledProcess()
            defer { process.finish() }
            process.quitBehavior = declined ? .decline : .keepRunning
            let start = ContinuousClock.now
            do {
                try await stopControlledProcesses([process])
                throw TestFailure(message: "live child must refuse replacement")
            } catch {
                let message = declined ? "process \(process.processIdentifier) declined normal termination; installation unchanged"
                    : "normal termination timed out; installation unchanged"
                try check(error as? IFInputError == .unavailable(message),
                          "register-input-source preserves declined/timeout errors")
            }
            let elapsed = start.duration(to: .now)
            try check(elapsed < .seconds(2) && (declined || elapsed >= .milliseconds(20)),
                      "injected short deadline is bounded and is not reported before expiry")
            try check(process.terminationRequests == 1 &&
                      !IFInstallationProcessLifecycle.hasExited(applicationTerminated: false, processID: process.processIdentifier),
                      "declined/timed-out child remains alive without force termination")
        }
        print("PASS register-input-source stop: stale and delayed exit, pre-exited child, request race, live refusal, bounded timeout, exact errors, no force termination")
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
        var registered = true
        var ignoreEnable = false
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
            return IFInputRoster(installed: registered ? sources : [], enabled: sources.filter(\.enabled), selectedID: selected)
        }
        func register(at url: URL) throws {
            if failure == "register" { throw IFInputError.unavailable("register") }
            registered = true
        }
        func enable(_ id: String) {
            enabledCalls += 1
            if ignoreEnable { return }
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
                throw TestFailure(message: "prepare must refuse \(failure)")
            } catch is IFInputError {}
            try check(p.launches == 0 && s.selected == IFInputIdentity.modeID, "refused prepare restores selection without launch")
        }
        let s = TrialSources(), p = TrialProcesses()
        let lifecycle = IFTrialInstallation(sources: s, processes: p)
        let state = try await lifecycle.prepare(target: target, build: "12")
        try check(p.pids.isEmpty && s.selected == "ascii", "prepare returns only after old exit")
        let pid = try await lifecycle.finish(target: target, state: state, installedBuild: "12").pid
        try check(!state.firstInstall && pid == 99 && s.selected == IFInputIdentity.modeID && s.enabledCalls == 0, "fresh process and original selected/enabled state")
        for failure in ["register", "select", "launch", "build"] {
            s.failure = failure; p.failure = failure
            do {
                _ = try await lifecycle.finish(target: target, state: state, installedBuild: failure == "build" ? "11" : "12")
                throw TestFailure(message: "finish must refuse \(failure)")
            } catch is IFInputError {}
        }
        let firstSources = TrialSources(), firstProcesses = TrialProcesses()
        firstSources.selected = "ascii"; firstSources.enabled = ["ascii"]; firstProcesses.pids = []
        let first = IFTrialInstallation(sources: firstSources, processes: firstProcesses)
        let initial = try await first.prepare(target: target, build: "12")
        _ = try await first.finish(target: target, state: initial, installedBuild: "12")
        try check(firstSources.selected == "ascii" && firstSources.enabledCalls == 0, "upgrade of a registered but disabled InkFlow keeps it disabled")
        let delayedSources = TrialSources(), delayedProcesses = TrialProcesses()
        delayedSources.delayed = true
        let delayed = IFTrialInstallation(sources: delayedSources, processes: delayedProcesses, pause: { delayedSources.applyPending() })
        let delayedState = try await delayed.prepare(target: target, build: "12")
        delayedSources.enabled = ["ascii"]
        _ = try await delayed.finish(target: target, state: delayedState, installedBuild: "12")
        try check(delayedSources.selected == IFInputIdentity.modeID && delayedSources.enabledCalls == 2, "delayed enable and selection readback")
        // First install: nothing registered or running, so finish enables the parent and mode and selects the mode.
        let freshSources = TrialSources(), freshProcesses = TrialProcesses()
        freshSources.registered = false; freshSources.selected = "ascii"; freshSources.enabled = ["ascii"]; freshProcesses.pids = []
        let fresh = IFTrialInstallation(sources: freshSources, processes: freshProcesses)
        let freshState = try await fresh.prepare(target: target, build: "12")
        try check(freshState.firstInstall && freshState.enabledIDs.isEmpty, "unregistered InkFlow with no process is a first install")
        let freshResult = try await fresh.finish(target: target, state: freshState, installedBuild: "12")
        try check(freshResult.confirmed && freshResult.pid == 99 && freshProcesses.launches == 1 && freshSources.enabledCalls == 2 &&
                  freshSources.selected == IFInputIdentity.modeID &&
                  [IFInputIdentity.bundleID, IFInputIdentity.modeID].allSatisfy(freshSources.enabled.contains),
                  "first install registers, enables parent and mode, launches and selects the mode")
        let deniedSources = TrialSources(), deniedProcesses = TrialProcesses()
        deniedSources.registered = false; deniedSources.ignoreEnable = true; deniedSources.selected = "ascii"
        deniedSources.enabled = ["ascii"]; deniedProcesses.pids = []
        let denied = IFTrialInstallation(sources: deniedSources, processes: deniedProcesses)
        let deniedState = try await denied.prepare(target: target, build: "12")
        let deniedResult = try await denied.finish(target: target, state: deniedState, installedBuild: "12")
        try check(!deniedResult.confirmed && deniedProcesses.launches == 1 && deniedSources.selected == "ascii",
                  "unconfirmed first-install enablement reports it, still launches the new build and leaves the selection alone")
        let runningSources = TrialSources(), runningProcesses = TrialProcesses()
        runningSources.registered = false
        let running = IFTrialInstallation(sources: runningSources, processes: runningProcesses)
        let runningState = try await running.prepare(target: target, build: "12")
        try check(!runningState.firstInstall, "a running InkFlow process is never a first install")
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
    static func atomicReplacementTests() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("replacement-test-\(UUID().uuidString)")
        let target = root.appendingPathComponent("destination").appendingPathComponent("InkFlow.app")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func candidate(_ version: String) throws -> URL {
            let url = root.appendingPathComponent("arbitrary \(version).app")
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(version.utf8).write(to: url.appendingPathComponent("version"))
            return url
        }
        func installed() throws -> String {
            try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8)
        }
        func inode(_ url: URL) throws -> NSNumber? {
            try fm.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        }
        // First install: the exclusive rename publishes the candidate and never overwrites.
        let first = try candidate("99-preview")
        try IFAtomicAppReplacement.replace(candidate: first, target: target)
        try check(try installed() == "99-preview" && !fm.fileExists(atPath: first.path), "first installation")
        // Update: the swap keeps the target path present and leaves the old app in the candidate slot.
        let second = try candidate("1-old-build")
        let oldIdentity = try inode(target), newIdentity = try inode(second)
        try IFAtomicAppReplacement.replace(candidate: second, target: target)
        try check(try installed() == "1-old-build", "upgrade permits arbitrary versions and paths")
        try check(try inode(target) == newIdentity, "atomic replacement publishes the candidate inode")
        try check(try inode(second) == oldIdentity, "atomic replacement retains the original inode in the candidate slot")
        do {
            try IFAtomicAppReplacement.replace(candidate: root.appendingPathComponent("missing.app"), target: target)
            throw TestFailure(message: "missing candidate must fail")
        } catch is IFInputError {}
        try check(try inode(target) == newIdentity && (try installed()) == "1-old-build",
                  "failed replacement leaves the installed app intact")
        print("PASS atomic replacement: first install, swap keeps the old app in the candidate slot, failed replacement leaves the installed app intact")
    }
    @MainActor static func main() async throws {
        try await trialExitObservationTest()
        try await trialPrepareExitObservationTest()
        try await systemTerminationTests()
        try exitPredicateTests()
        try await trialTests()
        try atomicReplacementTests()
    }
}
