import AppKit
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
    func terminateOld() async throws {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: installerBundleID)
        for app in applications where !app.isTerminated {
            guard app.terminate() else { throw IFInstallerError.terminationDeclined }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while applications.contains(where: { !$0.isTerminated }) {
            guard ContinuousClock.now < deadline else { throw IFInstallerError.terminationTimeout }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
