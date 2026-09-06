import InputMethodKit

let result: Int32 = autoreleasepool {
    _ = NSApplication.shared
    let bundle = Bundle.main
    let shared = (bundle.resourcePath! as NSString).appendingPathComponent("Rime")
    let user = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/InkFlow")
    let qualityStore = QualityStore(url: URL(fileURLWithPath: user).appendingPathComponent("quality.sqlite3"),
                                    engineVersion: IFEngine.version)
    defer {
        // The run loop has stopped; drain on the worker outside input-method callbacks.
        let drained = DispatchSemaphore(value: 0)
        Task.detached { await qualityStore.close(); drained.signal() }
        drained.wait()
    }
    do { try IFEngine.start(shared: shared, user: user, qualityStore: qualityStore) }
    catch {
        NSLog("InkFlow initialization failed: %@", error.localizedDescription)
        return 1
    }
    defer { IFEngine.stop() }
    guard let server = IMKServer(name: bundle.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
                                 bundleIdentifier: bundle.bundleIdentifier) else {
        NSLog("InkFlow could not create its input method server.")
        return 1
    }
    withExtendedLifetime(server) { NSApp.run() }
    return 0
}
exit(result)
