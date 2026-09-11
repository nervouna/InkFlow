import AppKit
import SQLite3
#if SWIFT_PACKAGE
@testable import InkFlowCore
import InkFlowTestSupport
#endif

@main struct TerminationTests {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let mode = CommandLine.arguments[2]
        let trace = root.appendingPathComponent("trace")
        let record: @MainActor @Sendable (String) -> Void = { event in
            let old = (try? String(contentsOf: trace, encoding: .utf8)) ?? ""
            try! (old + event + "\n").write(to: trace, atomically: true, encoding: .utf8)
        }
        // Exits only this synthetic subprocess if either AppKit or the test driver stalls.
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { exit(99) }
        let app = NSApplication.shared
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        @Sendable func factoryHasStarted() -> Bool { started.wait(timeout: .now()) == .success }
        let coordinator = IFDictionaryCoordinator(backendFactory: {
            started.signal()
            gate.wait()
            throw CocoaError(.fileReadUnknown)
        })
        coordinator.recordUnavailable(CocoaError(.fileReadUnknown))
        coordinator.retry() // A real owned detached factory is in flight when termination begins.
        let storeURL = root.appendingPathComponent("quality.sqlite3")
        if mode == "disabled" { try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true) }
        let store = QualityStore(url: storeURL, engineVersion: "test", buildMetadata: .unknown)
        var engine: IFEngine?
        if mode == "success" {
            try IFEngine.start(shared: CommandLine.arguments[3], user: root.appendingPathComponent("rime-user").path, qualityStore: store)
            engine = IFEngine()
            check(engine != nil && IFEngine.ready)
            type(engine!, "nihao")
        }
        var drainAttempts = 0, closeAttempts = 0
        let delegate = IFApplicationLifecycle(stopDictionaries: {
            drainAttempts += 1
            record("drain-start")
            if mode == "dictionary-failure" && drainAttempts == 1 { throw CocoaError(.fileWriteUnknown) }
            while !factoryHasStarted() { try await Task.sleep(for: .milliseconds(5)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { gate.signal() }
            try await coordinator.shutdown()
            check(coordinator.isShuttingDown && !coordinator.isBusy && !coordinator.canRetry && !coordinator.canCheck)
            record("drain-end")
        }, stopEngine: {
            IFEngine.stop()
            check(!IFEngine.ready && engine?.available != true)
            record("engine-stop")
        }, closeStore: {
            closeAttempts += 1
            if mode == "store-failure" && closeAttempts == 1 { record("store-failed"); return false }
            let closed = await store.close()
            check(closed, "Unavailable recording with no pending data must allow termination")
            record("store-close")
            return closed
        }, didTerminate: { record("will-terminate") })
        app.delegate = delegate
        _ = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated { app.terminate(nil) }
        }
        // A second actual termination while draining must not create another cleanup task.
        _ = Timer.scheduledTimer(withTimeInterval: 0.13, repeats: false) { _ in
            MainActor.assumeIsolated {
                if mode == "success" { app.terminate(nil) }
            }
        }
        if mode == "dictionary-failure" || mode == "store-failure" {
            _ = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                MainActor.assumeIsolated {
                    check(delegate.failure != nil, "Failed cleanup must deny the first native quit")
                    check(!IFEngine.ready)
                    record("denied-retry")
                    app.terminate(nil)
                }
            }
        }
        withExtendedLifetime((delegate, engine)) { app.run() }
        record("run-returned")
        exit(2)
    }
}
