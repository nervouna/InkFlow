import Foundation
@testable import InkFlowCore
import InkFlowTestSupport

enum UpdateTests {
    @MainActor static func run() {
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
}

@MainActor
private final class IdleInstallFixture {
    var idleSeconds: TimeInterval = 0
    var inputIdle = true
    var uptime: TimeInterval = 1_000
    var installs = 0
    var replaced = 0
}

