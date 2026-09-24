import AppKit
import Darwin
#if SWIFT_PACKAGE
import InkFlowInputSources
private let installerBundleID = IFPackageInputIdentity.bundleID
#else
private let installerBundleID = IFInputIdentity.bundleID
#endif

@MainActor protocol IFInstallerLifecycleOperations {
    func terminateOld() async throws
}

@MainActor final class IFSystemLifecycle: IFInstallerLifecycleOperations {
    static func hasExited(applicationTerminated: Bool, processID: pid_t,
                          probe: (pid_t) -> Int32 = { pid in
                              Darwin.kill(pid, 0) == 0 ? 0 : errno
                          }) -> Bool {
        if applicationTerminated { return true }
        // AppKit's observable state can lag behind process exit. Signal zero
        // only queries existence; ESRCH is the sole fallback proof of exit.
        guard processID > 0 else { return false }
        return probe(processID) == ESRCH
    }

    func terminateOld() async throws {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: installerBundleID)
        for app in applications where !app.isTerminated {
            guard app.terminate() else { throw IFInstallerError.terminationDeclined }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while applications.contains(where: { !Self.hasExited(applicationTerminated: $0.isTerminated, processID: $0.processIdentifier) }) {
            guard ContinuousClock.now < deadline else { throw IFInstallerError.terminationTimeout }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
