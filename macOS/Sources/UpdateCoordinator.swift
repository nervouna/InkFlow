import Foundation

@MainActor
final class IFUpdateCoordinator: NSObject {
    private let settings: IFSettings
    private let checkForUpdate: @Sendable () async throws -> IFAvailableUpdate?
    private let download: @Sendable (IFAvailableUpdate) async throws -> URL
    private let openInstaller: @Sendable (URL, IFSemanticVersion) async throws -> Void
    private var task: Task<Void, Never>?
    private var observing = false
    private var automaticChecksEnabled = false
    private var automaticDownloadsEnabled = false

    init(settings: IFSettings, currentVersion: IFSemanticVersion) {
        self.settings = settings
        let service = IFUpdateService(currentVersion: currentVersion)
        let launcher = IFUpdateInstallerLauncher()
        checkForUpdate = { try await service.checkForUpdate() }
        download = { try await service.download($0) }
        openInstaller = { try await launcher.openInstaller(from: $0, version: $1) }
        super.init()
    }

    init(settings: IFSettings,
         checkForUpdate: @escaping @Sendable () async throws -> IFAvailableUpdate?,
         download: @escaping @Sendable (IFAvailableUpdate) async throws -> URL,
         openInstaller: @escaping @Sendable (URL, IFSemanticVersion) async throws -> Void) {
        self.settings = settings
        self.checkForUpdate = checkForUpdate
        self.download = download
        self.openInstaller = openInstaller
        super.init()
    }

    func start() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: .settingsDidChange, object: settings)
        refreshPreferences()
    }

    func stop() {
        guard observing else { return }
        observing = false
        NotificationCenter.default.removeObserver(self)
        task?.cancel()
        task = nil
    }

    @objc private func settingsChanged() {
        guard settings.automaticUpdateChecksEnabled != automaticChecksEnabled
                || settings.automaticUpdateDownloadsEnabled != automaticDownloadsEnabled else { return }
        refreshPreferences()
    }

    private func refreshPreferences() {
        automaticChecksEnabled = settings.automaticUpdateChecksEnabled
        automaticDownloadsEnabled = settings.automaticUpdateDownloadsEnabled
        task?.cancel()
        task = nil
        guard automaticChecksEnabled else { return }
        task = Task(priority: .utility) { [weak self] in await self?.runChecks() }
    }

    private func runChecks() async {
        while !Task.isCancelled, settings.automaticUpdateChecksEnabled {
            let delay = IFUpdateCheckSchedule.delay(lastCheck: settings.lastAutomaticUpdateCheck, now: .now)
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            let automaticDownload = settings.automaticUpdateDownloadsEnabled
            do {
                if let update = try await checkForUpdate(), automaticDownload {
                    let image = try await download(update)
                    try await openInstaller(image, update.version)
                }
            } catch is CancellationError {
                return
            } catch {
                NSLog("InkFlow automatic update check failed: %@", String(describing: error))
            }
            settings.recordAutomaticUpdateCheck(at: .now)
        }
    }
}
