import Foundation
import Darwin

struct IFRuntimeReceipt: Codable {
    var schemaVersion = 1
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executablePath: String
    let version: String
    let build: String
    var engineReady = false
    var serverCreated = false
    var terminating = false
}

/// A per-process receipt avoids one process overwriting another's identity. No reader trusts it alone.
@MainActor final class IFRuntimeStatus {
    let url: URL
    private var receipt: IFRuntimeReceipt
    var serverCreated: Bool { get { receipt.serverCreated } set { receipt.serverCreated = newValue } }
    var terminating: Bool { get { receipt.terminating } set { receipt.terminating = newValue } }

    func publish(engineReady: Bool) throws {
        try update(engineReady: engineReady, serverCreated: serverCreated, terminating: terminating)
    }

    init(directory: URL, bundle: Bundle) throws {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size else {
            throw CocoaError(.fileReadUnknown)
        }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &path, UInt32(path.count)) > 0 else { throw CocoaError(.fileReadUnknown) }
        let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        receipt = .init(pid: getpid(), startSeconds: info.pbi_start_tvsec,
                        startMicroseconds: info.pbi_start_tvusec, executablePath: executable,
                        version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                        build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        url = directory.appendingPathComponent("\(getpid()).json")
    }

    func update(engineReady: Bool, serverCreated: Bool, terminating: Bool = false) throws {
        receipt.engineReady = engineReady; receipt.serverCreated = serverCreated; receipt.terminating = terminating
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(receipt),
                                             attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
