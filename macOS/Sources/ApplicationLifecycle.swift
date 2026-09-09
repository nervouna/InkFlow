import AppKit

/// AppKit exits directly after its termination notifications; main's defer is not a cleanup hook.
@MainActor final class IFApplicationLifecycle: NSObject, NSApplicationDelegate {
    private let stopDictionaries: () async throws -> Void
    private let stopEngine: () -> Void
    private let closeStore: () async -> Bool
    private let didTerminate: () -> Void
    private var cleanup: Task<Void, Never>?
    private var complete = false
    private var dictionariesStopped = false
    private var engineStopped = false
    private(set) var failure: String?

    init(stopDictionaries: @escaping () async throws -> Void, stopEngine: @escaping () -> Void,
         closeStore: @escaping () async -> Bool,
         didTerminate: @escaping () -> Void = {}) {
        self.stopDictionaries = stopDictionaries; self.stopEngine = stopEngine
        self.closeStore = closeStore; self.didTerminate = didTerminate
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if complete { return .terminateNow }
        guard cleanup == nil else { return .terminateLater }
        failure = nil
        cleanup = Task { [self] in
            do {
                if !dictionariesStopped {
                    try await stopDictionaries()
                    dictionariesStopped = true
                }
                // Interrupt recorders and destroy sessions before closing their destination store.
                if !engineStopped { stopEngine(); engineStopped = true }
                guard await closeStore() else { throw CocoaError(.fileWriteUnknown) }
                complete = true
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                failure = String(describing: error)
                NSLog("InkFlow termination cleanup failed: %@", String(describing: error))
                cleanup = nil
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) { didTerminate() }
}
