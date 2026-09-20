import Foundation

package enum IFRegisterInputSourceBootstrap {
    @MainActor package static func run(arguments: [String]) async {
        func fail(_ message: String, _ code: Int32) -> Never {
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            exit(code)
        }
        if arguments.count >= 3, ["--prepare-update", "--finish-update"].contains(arguments[2]) {
            do { try await trialUpdate(arguments) }
            catch { fail("Installation lifecycle failed: \(error)", 1) }
            return
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
                print("parent_enabled=\(parentEnabled ? "1" : "unconfirmed")\nmode_enabled=\(modeEnabled ? "1" : "unconfirmed")")
                guard parentEnabled && modeEnabled else { throw IFInputError.unavailable("enabled parent/mode") }
            } else {
                print("Registered only. Add InkFlow in System Settings, then run --verify-enabled. Registration does not enable or select it.")
            }
        } catch {
            fail("\(error)", 1)
        }
    }

    @MainActor private static func trialUpdate(_ arguments: [String]) async throws {
        let prepare = arguments[2] == "--prepare-update"
        guard arguments.count == (prepare ? 5 : 4) else {
            throw IFInputError.unavailable("Usage: register-input-source target --prepare-update state.json staged.app | target --finish-update state.json")
        }
        let target = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let allowed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/InkFlow.app")
        guard target == allowed else { throw IFInputError.unavailable("trial install must target current user's installed InkFlow.app") }
        let stateURL = URL(fileURLWithPath: arguments[3])
        let lifecycle = IFTrialInstallation(sources: IFSystemInputSources(), processes: IFTrialSystemProcesses())
        if prepare {
            let staged = URL(fileURLWithPath: arguments[4])
            guard let bundle = Bundle(url: staged), bundle.bundleIdentifier == IFInputIdentity.bundleID,
                  let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
                throw IFInputError.unavailable("staged candidate identity")
            }
            let state = try await lifecycle.prepare(target: target, build: build)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
            print("old_processes_stopped=\(state.oldPIDs.map(String.init).joined(separator: ","))")
        } else {
            let state = try JSONDecoder().decode(IFTrialInstallationState.self, from: Data(contentsOf: stateURL))
            guard let bundle = Bundle(url: target), bundle.bundleIdentifier == IFInputIdentity.bundleID,
                  let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
                throw IFInputError.unavailable("installed candidate identity")
            }
            let pid = try await lifecycle.finish(target: target, state: state, installedBuild: build)
            print("running_pid=\(pid)\nrunning_executable=\(target.path)/Contents/MacOS/InkFlow\ninstalled_build=\(build)\ninput_source_state_restored=1")
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
