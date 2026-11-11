import AppKit
import CoreGraphics
import InkFlowRime

/// Sparkle installs an automatically downloaded update when the app quits, and an input method runs until logout.
/// This installs a staged update once nobody has used the Mac for a while and no input is in progress.
/// It checks on a timer and adds nothing to the key-event path.
@MainActor
package final class IFUpdateIdleInstaller {
    package struct Environment {
        /// Seconds since the last keyboard, mouse or trackpad event in this login session.
        package var secondsSinceLastInput: @MainActor () -> TimeInterval
        /// No composition, undelivered commit, voice session, personal-data transaction or open InkFlow window.
        package var inputIdle: @MainActor () -> Bool
        package var uptime: @MainActor () -> TimeInterval

        package init(secondsSinceLastInput: @escaping @MainActor () -> TimeInterval,
                     inputIdle: @escaping @MainActor () -> Bool,
                     uptime: @escaping @MainActor () -> TimeInterval) {
            self.secondsSinceLastInput = secondsSinceLastInput
            self.inputIdle = inputIdle
            self.uptime = uptime
        }

        package static var live: Environment { Environment(
            secondsSinceLastInput: {
                // kCGAnyInputEventType
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            },
            inputIdle: {
                IFEngine.allSessionsIdle && !IFEngine.personalDataSuspended && IFInputControllerVoice.personalDataIdle
                    && !NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
            },
            uptime: { ProcessInfo.processInfo.systemUptime }) }
    }

    package static let quietPeriod: TimeInterval = 600
    package static let checkInterval: TimeInterval = 60

    private let environment: Environment
    private let checksPeriodically: Bool
    private var install: (@MainActor () -> Void)?
    private var attemptedAt: TimeInterval?
    private var timer: Timer?

    package init(environment: Environment = .live, checksPeriodically: Bool = true) {
        self.environment = environment
        self.checksPeriodically = checksPeriodically
    }

    package var isScheduled: Bool { install != nil }

    /// Holds Sparkle's immediate-install handler. A later handler replaces an earlier one.
    package func schedule(_ install: @escaping @MainActor () -> Void) {
        self.install = install
        attemptedAt = nil
        guard checksPeriodically, timer == nil else { return }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.check() }
        }
        timer.tolerance = Self.checkInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    package func cancel() {
        install = nil
        attemptedAt = nil
        timer?.invalidate()
        timer = nil
    }

    /// Invokes the handler when the Mac has been idle for the quiet period and no input is in progress.
    /// Sparkle then terminates the app, installs the update and relaunches it. Termination is denied when cleanup
    /// fails; Sparkle allows the handler again, so the next attempt waits for another quiet period.
    @discardableResult
    package func check() -> Bool {
        guard let install else { return false }
        let now = environment.uptime()
        if let attemptedAt, now - attemptedAt < Self.quietPeriod { return false }
        guard environment.secondsSinceLastInput() >= Self.quietPeriod, environment.inputIdle() else { return false }
        attemptedAt = now
        install()
        return true
    }
}
