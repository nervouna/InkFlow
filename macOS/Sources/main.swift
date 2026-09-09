import InputMethodKit

let result: Int32 = autoreleasepool {
    _ = NSApplication.shared
    let bundle = Bundle.main
    let helper = bundle.bundleURL.appendingPathComponent("Contents/MacOS/InkFlowDictionaryWorker")
    let user = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/InkFlow")
    let status: IFRuntimeStatus?
    do { status = try IFRuntimeStatus(directory: user.appendingPathComponent("Runtime"), bundle: bundle) }
    catch { NSLog("InkFlow runtime receipt unavailable: %@", String(describing: error)); status = nil }
    let qualityStore = QualityStore(url: user.appendingPathComponent("quality.sqlite3"), engineVersion: IFEngine.version)
    IFEngine.configureQualityRecording(qualityStore)
    // Only the production entry point supplies a real root. Factory failure is retryable from Settings.
    let dictionaries = IFDictionaryCoordinator(backendFactory: {
        let store = try IFDictionaryStore(root: user.appendingPathComponent("Dictionaries"))
        let runtime = IFDictionaryRuntime.bundled(helper: helper)
        let worker = IFDictionaryWorkerRunner(runtime: runtime, protectedUserRoot: user, candidatesRoot: store.root.appendingPathComponent("candidates"))
        return .init(store: store, runtime: runtime, user: user, services: .init(client: .init(), worker: worker))
    }, logger: IFDictionaryCoordinator.persistentLogger)
    dictionaries.bootstrap()
    IFSettingsWindowController.sharedController.dictionaries = dictionaries
    let publishStatus: @MainActor @Sendable () -> Void = {
        do { try status?.publish(engineReady: IFEngine.ready) }
        catch { NSLog("InkFlow runtime receipt write failed: %@", String(describing: error)) }
    }
    let lifecycle = IFApplicationLifecycle(stopDictionaries: { try await dictionaries.shutdown() },
        stopEngine: { IFEngine.stop(); publishStatus() },
        closeStore: {
            let closed = await qualityStore.close()
            IFEngine.configureQualityRecording(nil)
            return closed
        }, stateChanged: { status?.terminating = $0; publishStatus() })
    NSApp.delegate = lifecycle
    let observer = NotificationCenter.default.addObserver(forName: .engineAvailabilityDidChange, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { publishStatus() }
    }
    publishStatus()

    // Even failed recovery must leave the server/menu/Settings reachable for diagnostics and retry.
    guard let server = IMKServer(name: bundle.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
                                 bundleIdentifier: bundle.bundleIdentifier) else {
        NSLog("InkFlow could not create its input method server.")
        IFEngine.stop()
        let drained = DispatchSemaphore(value: 0)
        Task.detached { await qualityStore.close(); drained.signal() }
        drained.wait()
        IFEngine.configureQualityRecording(nil)
        publishStatus()
        return 1

    }
    status?.serverCreated = true
    publishStatus()
    withExtendedLifetime((server, dictionaries, lifecycle, observer)) { NSApp.run() }
    return 0
}
exit(result)
