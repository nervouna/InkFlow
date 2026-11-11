import Foundation
#if SWIFT_PACKAGE
@testable import InkFlowCore
import InkFlowTestSupport
#endif

enum UpdateTests {
    @MainActor static func run() {
        migrationRules()
        print("PASS update preferences: one-time legacy auto-check migration, explicit default-off automatic install, and Sparkle-only source")
        idleInstall()
        print("PASS update idle install: a staged update installs while the Mac is idle, retrying after a denied quit")
    }

    @MainActor private static func idleInstall() {
        let state = IdleInstallFixture()
        let installer = IFUpdateIdleInstaller(environment: .init(secondsSinceLastInput: { state.idleSeconds },
                                                                 inputIdle: { state.inputIdle },
                                                                 uptime: { state.uptime }),
                                              checksPeriodically: false)
        state.idleSeconds = IFUpdateIdleInstaller.quietPeriod
        check(!installer.check() && !installer.isScheduled, "Nothing is installed before Sparkle stages an update")

        installer.schedule { state.installs += 1 }
        state.idleSeconds = IFUpdateIdleInstaller.quietPeriod - 1
        check(!installer.check() && state.installs == 0, "Recent keyboard or mouse input postpones the install")
        state.idleSeconds = IFUpdateIdleInstaller.quietPeriod
        state.inputIdle = false
        check(!installer.check() && state.installs == 0,
              "A composition, voice session or open window postpones the install")
        state.inputIdle = true
        check(installer.check() && state.installs == 1, "An idle Mac installs the staged update")
        // The process is still running here, as after a termination that cleanup denied.
        state.uptime += IFUpdateIdleInstaller.quietPeriod - 1
        check(!installer.check() && state.installs == 1 && installer.isScheduled,
              "A denied termination keeps the handler without retrying at once")
        state.uptime += 1
        check(installer.check() && state.installs == 2, "The install is retried after another quiet period")

        installer.schedule { state.replaced += 1 }
        check(installer.check() && state.installs == 2 && state.replaced == 1,
              "A later Sparkle handler replaces the earlier one and may run at once")

        installer.cancel()
        state.uptime += IFUpdateIdleInstaller.quietPeriod
        check(!installer.check() && state.replaced == 1 && !installer.isScheduled,
              "An aborted update cycle cancels the idle install")

        let live = IFUpdateIdleInstaller.Environment.live.secondsSinceLastInput()
        check(live.isFinite && live >= 0, "The session idle time is readable without extra permissions")
    }

    @MainActor private static func migrationRules() {
        migrationCase(legacyCheck: 1, expectedChecks: true)
        migrationCase(legacyCheck: 0, expectedChecks: false)
        migrationCase(legacyCheck: nil, expectedChecks: false)
        migrationCase(legacyCheck: "yes", expectedChecks: false)
    }

    @MainActor private static func migrationCase(legacyCheck: Any?, expectedChecks: Bool) {
        let suite = temporarySuiteName("inkflow.update-migration")
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
private final class IdleInstallFixture {
    var idleSeconds: TimeInterval = 0
    var inputIdle = true
    var uptime: TimeInterval = 1_000
    var installs = 0
    var replaced = 0
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
