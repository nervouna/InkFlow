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
    private let applications: () -> [any IFInstallationProcess]
    private let terminationTimeout: Duration

    init(applications: @escaping () -> [any IFInstallationProcess] = {
        NSRunningApplication.runningApplications(withBundleIdentifier: installerBundleID)
    }, terminationTimeout: Duration = IFInstallationProcessLifecycle.terminationTimeout) {
        self.applications = applications
        self.terminationTimeout = terminationTimeout
    }

    func terminateOld() async throws {
        do {
            try await IFInstallationProcessLifecycle.terminate(applications(), timeout: terminationTimeout)
        } catch IFInstallationTerminationError.declined {
            throw IFInstallerError.terminationDeclined
        } catch IFInstallationTerminationError.timeout {
            throw IFInstallerError.terminationTimeout
        }
    }
}
