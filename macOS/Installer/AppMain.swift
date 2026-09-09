import AppKit

@main struct IFInstallerMain {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst() == ["--check-payload"] {
            // Release assembly probe: extract the embedded app before creating NSApplication.
            Task.detached {
                let payload = IFShippedPayload()
                do {
                    let candidate = try await payload.load()
                    try await payload.clean()
                    print("PASS shipped payload \(candidate.expectedVersion.version) build \(candidate.expectedVersion.build)")
                    exit(0)
                } catch {
                    print("FAIL shipped payload: \(error)")
                    do { try await payload.clean() }
                    catch { print("FAIL payload cleanup: \(error)") }
                    exit(1)
                }
            }
            dispatchMain()
        }
        guard CommandLine.arguments.count == 1 else {
            print("Usage: InkFlowInstaller [--check-payload]")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let item = NSMenuItem()
        menu.addItem(item)
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "退出墨流安装器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = applicationMenu
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu; menu.addItem(edit); app.mainMenu = menu
        let info = Bundle.main.infoDictionary ?? [:]
        let version = IFAppVersion(version: info["CFBundleShortVersionString"] as? String ?? "未知",
                                   build: info["CFBundleVersion"] as? String ?? "未知")
        let target = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/InkFlow.app")
        // Display-only metadata; versions do not restrict installation.
        var existing: IFAppVersion?
        if let data = try? Data(contentsOf: target.appendingPathComponent("Contents/Info.plist")),
           let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let short = values["CFBundleShortVersionString"] as? String, let build = values["CFBundleVersion"] as? String {
            existing = .init(version: short, build: build)
        }
        let payload = IFShippedPayload()
        let controller = IFInstallWindowController(version: version, installedVersion: existing, target: target,
            makeCoordinator: { .production(candidate: try await payload.load()) }, cleanup: { try await payload.clean() })
        let delegate = IFInstallAppDelegate(controller: controller)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
