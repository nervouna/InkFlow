import AppKit
import CoreGraphics
import InkFlowRime

@MainActor
package final class IFUpdateIdleInstaller {
    package struct Environment {
        package var secondsSinceLastInput: @MainActor () -> TimeInterval
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
