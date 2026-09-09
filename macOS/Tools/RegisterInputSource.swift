import Foundation

@main struct RegisterInputSource {
    @MainActor static func main() {
        func fail(_ message: String, _ code: Int32) -> Never {
            FileHandle.standardError.write(Data("\(message)\n".utf8)); exit(code)
        }
        let arguments = CommandLine.arguments
        let verify = arguments.count == 3 && arguments[2] == "--verify-enabled"
        guard arguments.count == 2 || verify else {
            fail("Usage: register-input-source /path/to/InkFlow.app [--verify-enabled]", 2)
        }
        let url = URL(fileURLWithPath: arguments[1], isDirectory: true)
        guard Bundle(url: url)?.bundleIdentifier == IFInputIdentity.bundleID else {
            fail("Unexpected input method bundle identifier.", 2)
        }
        do {
            let system = IFSystemInputSources()
            if !verify {
                try system.register(at: url)
                print("launch_services_status=0\nregistration_status=0")
            }
            let roster = try system.snapshot()
            print("registered_mode_count=\(roster.installed.filter { $0.id == IFInputIdentity.modeID }.count)")
            guard let mode = try roster.mode() else { throw IFInputError.invalidMode }
            print("mode_name=\(mode.name)\nmode_select_capable=\(mode.selectable ? 1 : 0)")
            if verify {
                let parent = try roster.unique(IFInputIdentity.bundleID)
                let parentEnabled = parent?.enabled == true && roster.isEnabled(IFInputIdentity.bundleID)
                let modeEnabled = mode.enabled && roster.isEnabled(IFInputIdentity.modeID)
                print("parent_enabled=\(parentEnabled ? 1 : 0)\nmode_enabled=\(modeEnabled ? 1 : 0)")
                guard parentEnabled && modeEnabled else { throw IFInputError.unavailable("enabled parent/mode") }
            } else {
                print("Registered only. Add InkFlow in System Settings, then run --verify-enabled. Registration does not enable or select it.")
            }
        } catch { fail("\(error)", 1) }
    }
}
