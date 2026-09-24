import InputMethodKit
import Sparkle
#if SWIFT_PACKAGE
import InkFlowCore
#endif

@MainActor
private final class InkFlowSparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private var activeCorrelation: UUID?
    private var activeStartedAt: TimeInterval?
    private var currentUpdateCorrelation: UUID?
    private var scheduledInstallCorrelation: UUID?
    private var reportedTerminalOutcome = false

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        activeCorrelation = UUID()
        activeStartedAt = ProcessInfo.processInfo.systemUptime
        reportedTerminalOutcome = false
        record("sparkleCheck", outcome: .begin)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        currentUpdateCorrelation = activeCorrelation
        scheduledInstallCorrelation = nil
        record("sparkleUpdate", outcome: .ready, reason: "available")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        record("sparkleCheck", outcome: .completed, reason: "noUpdate")
        reportedTerminalOutcome = true
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem,
                 with request: NSMutableURLRequest) {
        currentUpdateCorrelation = activeCorrelation
        record("sparkleDownload", outcome: .begin)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        currentUpdateCorrelation = activeCorrelation
        record("sparkleDownload", outcome: .completed)
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        record("sparkleDownload", outcome: .failed, error: error)
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        record("sparkleDownload", outcome: .cancelled, reason: "userCancelled")
        reportedTerminalOutcome = true
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        record("sparkleExtract", outcome: .begin)
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        record("sparkleExtract", outcome: .completed)
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        switch choice {
        case .install:
            scheduledInstallCorrelation = activeCorrelation ?? currentUpdateCorrelation
            record("sparkleChoice", outcome: .handled, reason: "install")
        case .dismiss:
            record("sparkleChoice", outcome: .cancelled, reason: "dismiss")
            currentUpdateCorrelation = nil
        case .skip:
            record("sparkleChoice", outcome: .skipped, reason: "skip")
            currentUpdateCorrelation = nil
        @unknown default:
            record("sparkleChoice", outcome: .handled, reason: "unknown")
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let knownCorrelation = currentUpdateCorrelation ?? activeCorrelation
        let correlation = knownCorrelation ?? UUID()
        scheduledInstallCorrelation = correlation
        record("sparkleInstall", outcome: .ready,
               reason: knownCorrelation == nil ? "correlationUnknown" : "scheduledOnQuit",
               correlation: correlation)
        return false
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let knownCorrelation = scheduledInstallCorrelation ?? currentUpdateCorrelation ?? activeCorrelation
        let correlation = knownCorrelation ?? UUID()
        scheduledInstallCorrelation = correlation
        currentUpdateCorrelation = nil
        record("sparkleInstall", outcome: .begin,
               reason: knownCorrelation == nil ? "correlationUnknown" : nil,
               correlation: correlation)
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        let knownCorrelation = scheduledInstallCorrelation ?? currentUpdateCorrelation ?? activeCorrelation
        let correlation = knownCorrelation ?? UUID()
        record("sparkleRelaunch", outcome: .begin,
               reason: knownCorrelation == nil ? "correlationUnknown" : nil,
               correlation: correlation)
        scheduledInstallCorrelation = nil
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        record("sparkleCheck", outcome: .failed, error: error)
        reportedTerminalOutcome = true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        if !reportedTerminalOutcome {
            record("sparkleCheck", outcome: error == nil ? .completed : .failed, error: error)
        }
        activeCorrelation = nil
        activeStartedAt = nil
        reportedTerminalOutcome = false
    }

    private func record(_ event: StaticString, outcome: IFUpdateDiagnosticOutcome,
                        reason: StaticString? = nil, correlation: UUID? = nil,
                        error: (any Error)? = nil) {
        let knownCorrelation = correlation ?? activeCorrelation ?? currentUpdateCorrelation ?? scheduledInstallCorrelation
        let resolvedCorrelation = knownCorrelation ?? UUID()
        if knownCorrelation == nil && currentUpdateCorrelation == nil {
            currentUpdateCorrelation = resolvedCorrelation
        }
        let elapsedMilliseconds = activeStartedAt.map { (ProcessInfo.processInfo.systemUptime - $0) * 1_000 }
        IFUpdateDiagnostics.record(event: event, outcome: outcome,
            reason: reason ?? (knownCorrelation == nil ? "correlationUnknown" : nil),
            correlation: resolvedCorrelation, elapsedMilliseconds: elapsedMilliseconds, error: error)
    }
}

@MainActor
private final class InkFlowSparkleUpdaterHost {
    let controller: SPUStandardUpdaterController
    private let updaterDelegate: InkFlowSparkleUpdaterDelegate

    init() {
        let updaterDelegate = InkFlowSparkleUpdaterDelegate()
        self.updaterDelegate = updaterDelegate
        controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: updaterDelegate, userDriverDelegate: nil)
    }
}

@MainActor
private func makeSparkleUpdaterAccess() -> IFUpdaterAccess {
    let host = InkFlowSparkleUpdaterHost()
    let sparkleUpdater = host.controller.updater
    let access = IFUpdaterAccess(
        readAutomaticChecks: { [host] in host.controller.updater.automaticallyChecksForUpdates },
        writeAutomaticChecks: { [host] in host.controller.updater.automaticallyChecksForUpdates = $0 },
        readAutomaticDownloads: { [host] in host.controller.updater.automaticallyDownloadsUpdates },
        writeAutomaticDownloads: { [host] in host.controller.updater.automaticallyDownloadsUpdates = $0 },
        readAllowsAutomaticUpdates: { [host] in host.controller.updater.allowsAutomaticUpdates },
        readCanCheckForUpdates: { [host] in host.controller.updater.canCheckForUpdates },
        performCheckForUpdates: { [host] in
            guard host.controller.updater.canCheckForUpdates else { return }
            host.controller.updater.checkForUpdates()
        },
        performStartUpdater: { [host] in
            guard let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
                  !publicKey.isEmpty else { return }
            host.controller.startUpdater()
        }
    )
    for observation in [
        sparkleUpdater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak access] _, _ in
            Task { @MainActor [weak access] in access?.updaterPreferencesDidChange() }
        },
        sparkleUpdater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak access] _, _ in
            Task { @MainActor [weak access] in access?.updaterPreferencesDidChange() }
        },
        sparkleUpdater.observe(\.allowsAutomaticUpdates, options: [.new]) { [weak access] _, _ in
            Task { @MainActor [weak access] in access?.updaterPreferencesDidChange() }
        },
        sparkleUpdater.observe(\.canCheckForUpdates, options: [.new]) { [weak access] _, _ in
            Task { @MainActor [weak access] in access?.updaterPreferencesDidChange() }
        },
    ] {
        access.retainObservation(observation)
    }
    return access
}

exit(InkFlowApplicationBootstrap.run(updaterAccess: makeSparkleUpdaterAccess()))
