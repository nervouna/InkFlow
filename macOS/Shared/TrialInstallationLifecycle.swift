import AppKit
import Darwin

struct IFTrialInstallationState: Codable {
    let target: String
    let build: String
    let enabledIDs: [String]
    let selectedID: String
    let oldPIDs: [Int32]
}

@MainActor protocol IFTrialProcessOperations {
    func installedPIDs(at target: URL) throws -> [Int32]
    func stop(_ pids: [Int32]) async throws
    func launchAndVerify(at target: URL, excluding: [Int32]) async throws -> Int32
}

@MainActor final class IFTrialInstallation {
    let sources: any IFInputSourceOperations
    let processes: any IFTrialProcessOperations
    let pause: @MainActor () async throws -> Void
    init(sources: any IFInputSourceOperations, processes: any IFTrialProcessOperations,
         pause: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }) {
        self.sources = sources; self.processes = processes
        self.pause = pause
    }

    private func waitForState(_ predicate: (IFInputRoster) -> Bool) async throws {
        for attempt in 0..<8 {
            if predicate(try sources.snapshot()) { return }
            if attempt < 7 { try await pause() }
        }
        throw IFInputError.unavailable("input-source state not confirmed after bounded retry")
    }

    func prepare(target: URL, build: String) async throws -> IFTrialInstallationState {
        let roster = try sources.snapshot()
        let ids = [IFInputIdentity.bundleID, IFInputIdentity.modeID]
        let pids = try processes.installedPIDs(at: target)
        let state = IFTrialInstallationState(target: target.path, build: build,
            enabledIDs: ids.filter { roster.isEnabled($0) }, selectedID: roster.selectedID, oldPIDs: pids)
        do {
            if ids.contains(roster.selectedID) {
                guard let fallback = roster.enabled.first(where: {
                    $0.bundleID != IFInputIdentity.bundleID && $0.enabled && $0.selectable && $0.ascii
                }) else { throw IFInputError.unavailable("enabled ASCII fallback; installation not changed") }
                try sources.select(fallback.id)
                try await waitForState { $0.selectedID == fallback.id }
            }
            try await processes.stop(pids)
            guard try processes.installedPIDs(at: target).isEmpty else {
                throw IFInputError.unavailable("old process restarted before replacement")
            }
            return state
        } catch {
            try? sources.select(roster.selectedID)
            throw error
        }
    }

    func finish(target: URL, state: IFTrialInstallationState, installedBuild: String) async throws -> Int32 {
        guard state.target == target.path, state.build == installedBuild else {
            throw IFInputError.unavailable("installed target/build differs from prepared candidate")
        }
        try sources.register(at: target)
        try await waitForState { $0.source(IFInputIdentity.modeID) != nil }
        let registered = try sources.snapshot()
        for id in state.enabledIDs where !registered.isEnabled(id) { try sources.enable(id) }
        try await waitForState { roster in state.enabledIDs.allSatisfy { roster.isEnabled($0) } }
        let pid = try await processes.launchAndVerify(at: target, excluding: state.oldPIDs)
        try sources.select(state.selectedID)
        try await waitForState { roster in
            state.enabledIDs.allSatisfy { roster.isEnabled($0) } && roster.selectedID == state.selectedID
        }
        guard try processes.installedPIDs(at: target).contains(pid) else {
            throw IFInputError.unavailable("new process exited before verification")
        }
        return pid
    }
}

@MainActor final class IFTrialSystemProcesses: IFTrialProcessOperations {
    static func executablePath(_ pid: Int32) -> String? {
        // SDK's PROC_PIDPATHINFO_MAXSIZE is (4 * MAXPATHLEN), unavailable as a Swift macro.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func owns(path: String, target: URL) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        if normalized == targetPath || normalized == targetPath + "/Contents/MacOS/InkFlow" { return true }
        let parent = target.deletingLastPathComponent().standardizedFileURL.path + "/"
        guard normalized.hasPrefix(parent) else { return false }
        let parts = normalized.dropFirst(parent.count).split(separator: "/").map(String.init)
        guard let stage = parts.first, stage.hasPrefix(".inkflow-install."), stage.count > ".inkflow-install.".count else { return false }
        return Array(parts.dropFirst()) == ["previous"] || Array(parts.dropFirst()) == ["previous", "Contents", "MacOS", "InkFlow"]
    }

    func installedPIDs(at target: URL) throws -> [Int32] {
        var pids: [Int32] = []
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: IFInputIdentity.bundleID) where !app.isTerminated {
                if let path = Self.executablePath(app.processIdentifier) {
                    if Self.owns(path: path, target: target) { pids.append(app.processIdentifier) }
                    continue
                }
                // A prior installer may already have removed the old image. Launch Services
                // still identifies its original installed URL, allowing a graceful quit only.
                guard let cached = app.executableURL ?? app.bundleURL else {
                    throw IFInputError.unavailable("cannot identify InkFlow process \(app.processIdentifier); installation unchanged")
                }
                if Self.owns(path: cached.path, target: target) { pids.append(app.processIdentifier) }
        }
        return pids
    }

    func stop(_ pids: [Int32]) async throws {
        let apps = pids.compactMap { NSRunningApplication(processIdentifier: $0) }
        for app in apps where !app.isTerminated {
            guard app.terminate() else { throw IFInputError.unavailable("process \(app.processIdentifier) declined normal termination; installation unchanged") }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while apps.contains(where: { !$0.isTerminated }) {
            guard ContinuousClock.now < deadline else { throw IFInputError.unavailable("normal termination timed out; installation unchanged") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func launchAndVerify(at target: URL, excluding: [Int32]) async throws -> Int32 {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let app = try await NSWorkspace.shared.openApplication(at: target, configuration: configuration)
        try await Task.sleep(for: .milliseconds(500))
        let expected = target.appendingPathComponent("Contents/MacOS/InkFlow").standardizedFileURL.path
        guard !app.isTerminated, !excluding.contains(app.processIdentifier),
              Self.executablePath(app.processIdentifier) == expected else {
            throw IFInputError.unavailable("fresh installed executable could not be verified")
        }
        return app.processIdentifier
    }
}
