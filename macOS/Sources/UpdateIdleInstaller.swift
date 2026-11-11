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

        package init(secondsSinceLastInput: @escaping @MainActor () -> TimeInterval,
                     inputIdle: @escaping @MainActor () -> Bool) {
            self.secondsSinceLastInput = secondsSinceLastInput
            self.inputIdle = inputIdle
        }

        package static var live: Environment { Environment(
            secondsSinceLastInput: {
                // kCGAnyInputEventType
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            },
            inputIdle: {
                IFEngine.allSessionsIdle && !IFEngine.personalDataSuspended && IFInputControllerVoice.personalDataIdle
                    && !NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
            }) }
    }

    package static let quietPeriod: TimeInterval = 600
    package static let checkInterval: TimeInterval = 60

    private let environment: Environment
    private let checksPeriodically: Bool
    private var install: (@MainActor () -> Void)?
    private var timer: Timer?

    package init(environment: Environment = .live, checksPeriodically: Bool = true) {
        self.environment = environment
        self.checksPeriodically = checksPeriodically
    }

    package var isScheduled: Bool { install != nil }

    /// Holds Sparkle's immediate-install handler. A later handler replaces an earlier one.
    package func schedule(_ install: @escaping @MainActor () -> Void) {
        self.install = install
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
        timer?.invalidate()
        timer = nil
    }

    /// Invokes the handler once when the Mac has been idle for the quiet period and no input is in progress.
    /// Sparkle then terminates the app, installs the update and relaunches it.
    @discardableResult
    package func check() -> Bool {
        guard let install else { return false }
        guard environment.secondsSinceLastInput() >= Self.quietPeriod, environment.inputIdle() else { return false }
        cancel()
        install()
        return true
    }
}
