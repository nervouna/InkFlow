import Foundation
#if SWIFT_PACKAGE
@testable import InkFlowCore
import InkFlowTestSupport
#endif

enum UpdateTests {
    @MainActor static func run() {
        migrationRules()
        print("PASS update preferences: one-time legacy auto-check migration, explicit default-off automatic install, and Sparkle-only source")
    }

    @MainActor private static func migrationRules() {
        migrationCase(legacyCheck: 1, expectedChecks: true)
        migrationCase(legacyCheck: 0, expectedChecks: false)
        migrationCase(legacyCheck: nil, expectedChecks: false)
        migrationCase(legacyCheck: "yes", expectedChecks: false)
    }

    @MainActor private static func migrationCase(legacyCheck: Any?, expectedChecks: Bool) {
        let suite = "inkflow.update-migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        if let legacyCheck { defaults.set(legacyCheck, forKey: "automaticUpdateChecksEnabled") }
        defaults.set(true, forKey: "automaticUpdateDownloadsEnabled")
        let oldCheckTime = Date(timeIntervalSince1970: 1_234_567)
        defaults.set(oldCheckTime, forKey: "lastAutomaticUpdateCheck")

        let state = UpdaterAccessFixture(automaticChecks: !expectedChecks, automaticDownloads: true)
        let settings = IFSettings(defaults: defaults)
        let migrated = settings.migrateLegacyAutomaticUpdateChecks(to: state.access)
        check(migrated == expectedChecks, "Legacy auto-check maps to the expected Sparkle setting")
        check(state.access.automaticallyChecksForUpdates == expectedChecks,
              "The Sparkle public auto-check property receives the one-time choice")
        check(!state.access.automaticallyDownloadsUpdates,
              "The old download choice never grants automatic-install consent")
        check(defaults.object(forKey: "sparkleAutomaticChecksMigrationCompleted") as? Bool == true,
              "The preference migration completes exactly once")
        check(defaults.object(forKey: "lastAutomaticUpdateCheck") as? Date == oldCheckTime,
              "The old custom scheduler timestamp is left untouched")

        state.access.automaticallyChecksForUpdates = !expectedChecks
        state.access.automaticallyDownloadsUpdates = true
        check(settings.migrateLegacyAutomaticUpdateChecks(to: state.access) == nil,
              "A completed migration is not repeated")
        check(state.access.automaticallyChecksForUpdates == !expectedChecks
              && state.access.automaticallyDownloadsUpdates,
              "A later Sparkle user choice remains the sole source of truth")
    }
}

@MainActor
private final class UpdaterAccessFixture {
    var automaticChecks: Bool
    var automaticDownloads: Bool

    init(automaticChecks: Bool, automaticDownloads: Bool) {
        self.automaticChecks = automaticChecks
        self.automaticDownloads = automaticDownloads
    }

    lazy var access = IFUpdaterAccess(
        readAutomaticChecks: { [weak self] in self?.automaticChecks ?? false },
        writeAutomaticChecks: { [weak self] in self?.automaticChecks = $0 },
        readAutomaticDownloads: { [weak self] in self?.automaticDownloads ?? false },
        writeAutomaticDownloads: { [weak self] in self?.automaticDownloads = $0 },
        readAllowsAutomaticUpdates: { [weak self] in self?.automaticChecks ?? false },
        readCanCheckForUpdates: { true },
        performCheckForUpdates: {},
        performStartUpdater: {}
    )
}
