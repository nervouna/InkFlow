import InputMethodKit

package enum InkFlowApplicationBootstrap {
    @MainActor package static func run(updaterAccess: IFUpdaterAccess) -> Int32 {
        autoreleasepool {
            let user = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/InkFlow")
            LocalDiagnostics.shared.activate(directory: user.appendingPathComponent("Diagnostics"),
                buildMetadataURL: Bundle.main.url(forResource: "QualityBuild", withExtension: "json"))
            let startup = IFStartupDiagnostics.shared
            let processSpan = startup.begin(.process)
            _ = NSApplication.shared
            let bundle = Bundle.main
            let helper = bundle.bundleURL.appendingPathComponent("Contents/MacOS/InkFlowDictionaryWorker")
            let qualityStore = QualityStore(url: user.appendingPathComponent("quality.sqlite3"), engineVersion: IFEngine.version)
            let statisticsStore = AIStatisticsStore(url: user.appendingPathComponent("ai-statistics.sqlite3"),
                pricingURL: user.appendingPathComponent("ai-pricing.json"),
                buildIdentity: [bundle.bundleIdentifier, bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                                bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String].compactMap { $0 }.joined(separator: ":"))
            InkFlowInputController.statisticsStore = statisticsStore
            IFEngine.configureQualityRecording(qualityStore)
            let dictionaries = IFDictionaryCoordinator(backendFactory: {
                let store = try IFDictionaryStore(root: user.appendingPathComponent("Dictionaries"))
                let runtime = IFDictionaryRuntime.bundled(helper: helper)
                let worker = IFDictionaryWorkerRunner(runtime: runtime, protectedUserRoot: user,
                    candidatesRoot: store.root.appendingPathComponent("candidates"))
                return .init(store: store, runtime: runtime, user: user, services: .init(client: .init(), worker: worker))
            }, logger: IFDictionaryCoordinator.persistentLogger)
            dictionaries.bootstrapForServing(runtime: .bundled(helper: helper), user: user)
            let settingsWindow = IFSettingsWindowController.sharedController
            settingsWindow.dictionaries = dictionaries
            settingsWindow.updaterAccess = updaterAccess
            _ = IFSettings.sharedSettings.migrateLegacyAutomaticUpdateChecks(to: updaterAccess)
            updaterAccess.startUpdater()
            let lifecycle = IFApplicationLifecycle(stopDictionaries: { try await dictionaries.shutdown() },
                stopEngine: { IFEngine.stop() },
                closeStore: {
                    let closed = await qualityStore.close()
                    await statisticsStore.close()
                    IFEngine.configureQualityRecording(nil)
                    InkFlowInputController.statisticsStore = nil
                    return closed
                })
            NSApp.delegate = lifecycle
            let serverSpan = startup.begin(.server)
            guard let server = IMKServer(name: bundle.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
                                         bundleIdentifier: bundle.bundleIdentifier) else {
                startup.end(serverSpan, .failed)
                startup.end(processSpan, .failed)
                NSLog("InkFlow could not create its input method server.")
                IFEngine.stop()
                let drained = DispatchSemaphore(value: 0)
                Task.detached {
                    await qualityStore.close(); await statisticsStore.close()
                    await LocalDiagnostics.shared.store?.drain()
                    drained.signal()
                }
                drained.wait()
                IFEngine.configureQualityRecording(nil)
                InkFlowInputController.statisticsStore = nil
                return 1
            }
            let candidateLifetime = NativeCandidateLifetime(server: server)
            startup.end(serverSpan)
            startup.end(processSpan)
            let eventLoop = startup.begin(.eventLoop)
            DispatchQueue.main.async { startup.end(eventLoop) }
            withExtendedLifetime((server, candidateLifetime, dictionaries, lifecycle, statisticsStore, updaterAccess)) { NSApp.run() }
            return 0
        }
    }
}
