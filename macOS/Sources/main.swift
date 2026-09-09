import InputMethodKit

let result: Int32 = autoreleasepool {
    _ = NSApplication.shared
    let bundle = Bundle.main
    let helper = bundle.bundleURL.appendingPathComponent("Contents/MacOS/InkFlowDictionaryWorker")
    let user = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/InkFlow")
    let qualityStore = QualityStore(url: user.appendingPathComponent("quality.sqlite3"), engineVersion: IFEngine.version)
    let statisticsStore = AIStatisticsStore(url: user.appendingPathComponent("ai-statistics.sqlite3"),
        pricingURL: user.appendingPathComponent("ai-pricing.json"),
        buildIdentity: [bundle.bundleIdentifier, bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String].compactMap { $0 }.joined(separator: ":"))
    InkFlowInputController.statisticsStore = statisticsStore
    IFEngine.configureQualityRecording(qualityStore)
    defer {
        let drained = DispatchSemaphore(value: 0)
        Task.detached { await qualityStore.close(); await statisticsStore.close(); drained.signal() }
        drained.wait()
        IFEngine.configureQualityRecording(nil)
        InkFlowInputController.statisticsStore = nil
    }
    // Only the production entry point supplies a real root. Factory failure is retryable from Settings.
    let dictionaries = IFDictionaryCoordinator(backendFactory: {
        let store = try IFDictionaryStore(root: user.appendingPathComponent("Dictionaries"))
        let runtime = IFDictionaryRuntime.bundled(helper: helper)
        let worker = IFDictionaryWorkerRunner(runtime: runtime, protectedUserRoot: user, candidatesRoot: store.root.appendingPathComponent("candidates"))
        return .init(store: store, runtime: runtime, user: user, services: .init(client: .init(), worker: worker))
    }, logger: IFDictionaryCoordinator.persistentLogger)
    dictionaries.bootstrap()
    IFSettingsWindowController.sharedController.dictionaries = dictionaries
    defer { IFEngine.stop() }
    // Even failed recovery must leave the server/menu/Settings reachable for diagnostics and retry.
    guard let server = IMKServer(name: bundle.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
                                 bundleIdentifier: bundle.bundleIdentifier) else {
        NSLog("InkFlow could not create its input method server.")
        return 1
    }
    withExtendedLifetime((server, dictionaries)) { NSApp.run() }
    return 0
}
exit(result)
