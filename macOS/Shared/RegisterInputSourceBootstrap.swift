import Foundation

package enum IFRegisterInputSourceBootstrap {
    @MainActor package static func run(arguments: [String]) {
        func fail(_ message: String, _ code: Int32) -> Never {
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            exit(code)
        }
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
            guard let mode = roster.source(IFInputIdentity.modeID) else {
                throw IFInputError.unavailable(IFInputIdentity.modeID)
            }
            print("mode_name=\(mode.name)\nmode_select_capable=\(mode.selectable ? 1 : 0)")
            if verify {
                let parent = roster.source(IFInputIdentity.bundleID)
                let parentEnabled = parent?.enabled == true && roster.isEnabled(IFInputIdentity.bundleID)
                let modeEnabled = mode.enabled && roster.isEnabled(IFInputIdentity.modeID)
                print("parent_enabled=\(parentEnabled ? 1 : 0)\nmode_enabled=\(modeEnabled ? 1 : 0)")
                guard parentEnabled && modeEnabled else { throw IFInputError.unavailable("enabled parent/mode") }
            } else {
                print("Registered only. Add InkFlow in System Settings, then run --verify-enabled. Registration does not enable or select it.")
            }
        } catch {
            fail("\(error)", 1)
        }
    }
}

package struct IFPackageInputSource: Sendable {
    package let id: String
    package let bundleID: String
    package let name: String
    package let enabled: Bool
    package let selectable: Bool
    package let ascii: Bool
}

package struct IFPackageInputRoster: Sendable {
    package let installed: [IFPackageInputSource]
    package let enabled: [IFPackageInputSource]
    package let selectedID: String

    package func source(_ id: String) -> IFPackageInputSource? { installed.first { $0.id == id } }
    package func isEnabled(_ id: String) -> Bool { enabled.contains { $0.id == id && $0.enabled } }
}

package enum IFPackageInputIdentity {
    package static let bundleID = IFInputIdentity.bundleID
    package static let modeID = IFInputIdentity.modeID
}

@MainActor package protocol IFPackageInputSourceOperations {
    func snapshot() throws -> IFPackageInputRoster
    func register(at url: URL) throws
    func enable(_ id: String) throws
    func select(_ id: String) throws
}

@MainActor package final class IFPackageSystemInputSources: IFPackageInputSourceOperations {
    private let base = IFSystemInputSources()

    package init() {}

    package func snapshot() throws -> IFPackageInputRoster {
        let roster = try base.snapshot()
        func convert(_ source: IFInputSource) -> IFPackageInputSource {
            IFPackageInputSource(id: source.id, bundleID: source.bundleID, name: source.name, enabled: source.enabled,
                                 selectable: source.selectable, ascii: source.ascii)
        }
        return IFPackageInputRoster(installed: roster.installed.map(convert), enabled: roster.enabled.map(convert),
                                    selectedID: roster.selectedID)
    }

    package func register(at url: URL) throws { try base.register(at: url) }
    package func enable(_ id: String) throws { try base.enable(id) }
    package func select(_ id: String) throws { try base.select(id) }
}
