import AppKit
import Foundation
import Security
import Darwin

struct IFProcessIdentity: Equatable, Sendable {
    let pid: Int32
    let uid: UInt32
    let seconds: UInt64
    let microseconds: UInt64
    let executablePath: String
}

/// A parent-reviewed historical version can use observed normal exit without claiming schema-1 cleanup.
struct IFLegacyTerminationEvidence: Sendable {
    let version: String
    let evidence: String
}

enum IFRuntimeObservation: Equatable, Sendable {
    case ready
    case waitingForSystemLaunch
    case initializing
    case unverifiedReceipt
    case terminating
}

@MainActor protocol IFInstallerLifecycleOperations {
    func inspectForReplacement(_ app: IFVerifiedApp, at target: URL) async throws
    func terminateOld(_ app: IFVerifiedApp, at target: URL) async throws
    func assertStopped(_ app: IFVerifiedApp?, at target: URL) async throws
    func observe(_ app: IFVerifiedApp, at target: URL) async throws -> IFRuntimeObservation
}

/// Receipt comparison is value-only and exercised without querying the user's daily input method.
enum IFReceiptMatcher {
    static func observation(_ receipt: IFRuntimeReceipt) -> IFRuntimeObservation {
        if receipt.terminating { return .terminating }
        return receipt.engineReady && receipt.serverCreated ? .ready : .initializing
    }
    static func matches(_ receipt: IFRuntimeReceipt, process: IFProcessIdentity, app: IFVerifiedApp) -> Bool {
        receipt.schemaVersion == 1 && receipt.pid == process.pid && process.uid == getuid()
            && receipt.startSeconds == process.seconds && receipt.startMicroseconds == process.microseconds
            && receipt.executablePath == process.executablePath
            && receipt.version == app.version.version && receipt.build == app.version.build
            && receipt.version != "unknown" && receipt.build != "unknown"
    }
}

@MainActor final class IFSystemLifecycle: IFInstallerLifecycleOperations {
    private let legacyEvidence: [IFLegacyTerminationEvidence]
    private var inspected: [IFProcessIdentity] = []
    private let receiptDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/InkFlow/Runtime")

    init(legacyEvidence: [IFLegacyTerminationEvidence] = [
        .init(version: "0.1.0", evidence: "Inspected librime 1.17.0 Service and UserDictionary destruction commits pending LevelDB transaction on normal exit; old statistics remain best effort"),
        .init(version: "0.2.0", evidence: "Same inspected legacy normal-exit contract; real old-app deactivation acceptance is separate")
    ]) { self.legacyEvidence = legacyEvidence }

    nonisolated private static func identity(_ pid: Int32) -> IFProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return .init(pid: pid, uid: info.pbi_uid, seconds: info.pbi_start_tvsec,
                     microseconds: info.pbi_start_tvusec, executablePath: path)
    }
    nonisolated private static func verifyDynamic(_ process: IFProcessIdentity, app: IFVerifiedApp) throws {
        guard process.uid == getuid(), identity(process.pid) == process else {
            throw IFInstallerError.conflict("Process identity changed")
        }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: process.pid)] as CFDictionary
        let result = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard result == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], try IFAppVerifier.requirement(identifier: IFInputIdentity.bundleID)) == errSecSuccess else {
            throw IFInstallerError.invalid("Running input method signature could not be verified")
        }
        var exactCode: SecRequirement?
        let hash = app.codeHash.map { String(format: "%02x", $0) }.joined()
        guard SecRequirementCreateWithString("cdhash H\"\(hash)\"" as CFString, [], &exactCode) == errSecSuccess,
              let exactCode, SecCodeCheckValidity(code, [], exactCode) == errSecSuccess,
              identity(process.pid) == process else {
            throw IFInstallerError.conflict("Running code does not match installed code")
        }
    }
    private func processes(executable: String, target: URL) async throws -> [IFProcessIdentity] {
        let known = Set(NSRunningApplication.runningApplications(withBundleIdentifier: IFInputIdentity.bundleID).map(\.processIdentifier))
        return try await Task.detached {
            let count = proc_listallpids(nil, 0)
            guard count > 0 else { throw IFInstallerError.invalid("Unable to enumerate live processes") }
            var pids = [Int32](repeating: 0, count: Int(count) + 128)
            let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
            guard actual > 0, actual < pids.count else { throw IFInstallerError.invalid("Process enumeration overflow; retry") }
            let expected = target.appendingPathComponent("Contents/MacOS/" + executable).path
            var matches: [IFProcessIdentity] = []
            for pid in pids.prefix(Int(actual)) where pid > 0 {
                guard let process = Self.identity(pid) else {
                    if known.contains(pid) { throw IFInstallerError.conflict("Unable to inspect InkFlow process") }
                    continue
                }
                guard process.uid == getuid() else { continue }
                if known.contains(pid) || process.executablePath.hasSuffix("/Contents/MacOS/" + executable) {
                    guard process.executablePath == expected else {
                        throw IFInstallerError.conflict("InkFlow is running from another path: \(process.executablePath)")
                    }
                    matches.append(process)
                }
            }
            return matches
        }.value
    }
    nonisolated private static func receipt(at directory: URL, pid: Int32) throws -> IFRuntimeReceipt? {
        try IFFileSafety.noLinks(directory)
        let url = directory.appendingPathComponent("\(pid).json")
        guard let info = try IFFileSafety.info(url) else { return nil }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= 16_384,
              info.st_mode & 0o077 == 0 else { throw IFInstallerError.invalid("Invalid runtime receipt file") }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw IFInstallerError.filesystem("read runtime receipt", errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try handle.read(upToCount: 16_385), data.count <= 16_384 else {
            throw IFInstallerError.invalid("Oversized runtime receipt")
        }
        return try JSONDecoder().decode(IFRuntimeReceipt.self, from: data)
    }
    private func checkedReceipt(_ process: IFProcessIdentity, app: IFVerifiedApp) async throws -> IFRuntimeReceipt? {
        let directory = receiptDirectory
        return try await Task.detached {
            try Self.verifyDynamic(process, app: app)
            let receipt = try Self.receipt(at: directory, pid: process.pid)
            if let receipt, !IFReceiptMatcher.matches(receipt, process: process, app: app) {
                throw IFInstallerError.conflict("Stale or mismatched live-process receipt")
            }
            return receipt
        }.value
    }
    func inspectForReplacement(_ app: IFVerifiedApp, at target: URL) async throws {
        let processes = try await processes(executable: app.executable, target: target)
        for process in processes {
            let receipt = try await checkedReceipt(process, app: app)
            if receipt == nil && !legacyEvidence.contains(where: {
                $0.version == app.version.version && !$0.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) { throw IFInstallerError.legacyEvidenceRequired(app.version) }
            // A terminating receipt may represent denied cleanup; normal terminate retries that stage.
        }
        inspected = processes
    }
    func terminateOld(_ app: IFVerifiedApp, at target: URL) async throws {
        let current = try await processes(executable: app.executable, target: target)
        guard Set(current.map(\.pid)) == Set(inspected.map(\.pid)), current.allSatisfy(inspected.contains) else {
            throw IFInstallerError.conflict("Input method restarted after inspection; retry")
        }
        for process in current {
            _ = try await checkedReceipt(process, app: app)
            guard Self.identity(process.pid) == process,
                  let running = NSRunningApplication(processIdentifier: process.pid),
                  running.bundleIdentifier == IFInputIdentity.bundleID, running.terminate() else {
                throw IFInstallerError.terminationDeclined
            }
        }
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if current.allSatisfy({ Self.identity($0.pid) != $0 }) {
                try await assertStopped(app, at: target); return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw IFInstallerError.terminationTimeout
    }
    func assertStopped(_ app: IFVerifiedApp?, at target: URL) async throws {
        guard try await processes(executable: app?.executable ?? "InkFlow", target: target).isEmpty else {
            throw IFInstallerError.conflict("Input method is still running; installation preserved")
        }
    }
    func observe(_ app: IFVerifiedApp, at target: URL) async throws -> IFRuntimeObservation {
        let processes = try await processes(executable: app.executable, target: target)
        guard !processes.isEmpty else { return .waitingForSystemLaunch }
        guard processes.count == 1 else { throw IFInstallerError.conflict("Multiple live InkFlow instances") }
        guard let receipt = try await checkedReceipt(processes[0], app: app) else { return .unverifiedReceipt }
        return IFReceiptMatcher.observation(receipt)
    }
}
