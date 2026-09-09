import Foundation
import Darwin

/// Copy beside the destination, then publish with a single same-volume rename.
/// After a swap the old app occupies the staging slot until cleanup.
final class IFFileTransaction {
    let target: URL
    private var staging: URL?
    private let fm = FileManager.default
    private let copy: (URL, URL) throws -> Void

    init(target: URL, copy: @escaping (URL, URL) throws -> Void = {
        try FileManager.default.copyItem(at: $0, to: $1)
    }) {
        self.target = target; self.copy = copy
    }
    func prepare(_ source: URL) throws {
        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = parent.appendingPathComponent(".inkflow-install-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        staging = folder
        do { try copy(source, folder.appendingPathComponent("InkFlow.app")) }
        catch {
            let original = error
            do { try clean() }
            catch { throw IFInstallerError.invalid("\(original); cleanup: \(error)") }
            throw original
        }
    }
    func commit() throws {
        guard let staging else { throw IFInstallerError.invalid("No prepared application") }
        let app = staging.appendingPathComponent("InkFlow.app")
        let flags = UInt32(fm.fileExists(atPath: target.path) ? RENAME_SWAP : RENAME_EXCL)
        guard renameatx_np(AT_FDCWD, app.path, AT_FDCWD, target.path, flags) == 0 else {
            throw IFInstallerError.filesystem("Replace \(target.path)", errno)
        }
    }
    func clean() throws {
        guard let staging else { return }
        try fm.removeItem(at: staging)
        self.staging = nil
    }
}

protocol IFInstallerFileOperations: Sendable {
    var target: URL { get }
    func prepare() async throws -> Bool
    func commit() async throws
    func clean() async throws
}

actor IFInstallerFiles: IFInstallerFileOperations {
    nonisolated let target: URL
    private let candidate: IFUnpackedShippedCandidate
    private let transaction: IFFileTransaction

    init(candidate: IFUnpackedShippedCandidate) {
        target = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/InkFlow.app")
        self.candidate = candidate
        transaction = IFFileTransaction(target: target)
    }
    func prepare() throws -> Bool {
        let existing = FileManager.default.fileExists(atPath: target.path)
        try transaction.prepare(candidate.unpackedApp)
        return existing
    }
    func commit() throws { try transaction.commit() }
    func clean() throws { try transaction.clean() }
}
