import InputMethodKit

let result: Int32 = autoreleasepool {
    _ = NSApplication.shared
    let bundle = Bundle.main
    let shared = (bundle.resourcePath! as NSString).appendingPathComponent("Rime")
    let user = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/InkFlow")
    do { try IFEngine.start(shared: shared, user: user) }
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
