import Foundation
import Darwin

struct IFFileIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    init(_ url: URL) throws {
        guard let value = try IFFileSafety.info(url), value.st_mode & S_IFMT == S_IFDIR else {
            throw IFInstallerError.conflict("Expected directory: \(url.path)")
        }
        device = value.st_dev; inode = value.st_ino
    }
    func matches(_ url: URL) -> Bool { (try? Self(url)) == self }
}

/// One small transaction, no user-data paths. Synchronous methods run on IFInstallerFiles' actor.
/// Verification/archive operations are narrow injection points for isolated filesystem tests.
final class IFFileTransaction {
    struct Journal: Codable {
        let id: String
        let new: IFFileIdentity
        let old: IFFileIdentity?
    }
    let target: URL
    let state: URL
    private let verify: (URL) throws -> Void
    private let archive: (URL, URL) throws -> Void
    private var lockFD: Int32 = -1
    private let fm = FileManager.default
    private var journalURL: URL { state.appendingPathComponent("transaction.json") }
    private func directory(_ journal: Journal) -> URL { state.appendingPathComponent(journal.id) }
    private func slot(_ journal: Journal) -> URL { directory(journal).appendingPathComponent("candidate.bundle") }

    init(target: URL, state: URL, verify: @escaping (URL) throws -> Void,
         archive: @escaping (URL, URL) throws -> Void) {
        self.target = target; self.state = state; self.verify = verify; self.archive = archive
    }
    deinit { unlock() }
    func lock() throws {
        guard lockFD < 0 else { throw IFInstallerError.locked }
        try IFFileSafety.privateDirectory(state)
        let fd = open(state.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw IFInstallerError.filesystem("open installer lock", errno) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_uid == getuid(), value.st_mode & S_IFMT == S_IFREG,
              value.st_nlink == 1, value.st_mode & 0o077 == 0 else {
            close(fd); throw IFInstallerError.conflict("Invalid installer lock")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw IFInstallerError.locked }
        lockFD = fd
    }
    func unlock() {
        if lockFD >= 0 { _ = flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }
    private func requireLock() throws {
        guard lockFD >= 0 else { throw IFInstallerError.locked }
    }
    private func read() throws -> Journal? {
        try requireLock()
        try IFFileSafety.noLinks(journalURL)
        guard let metadata = try IFFileSafety.info(journalURL) else { return nil }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(), metadata.st_size < 16_384 else {
            throw IFInstallerError.recoveryRequired("Invalid transaction journal")
        }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        guard UUID(uuidString: journal.id) != nil else { throw IFInstallerError.recoveryRequired("Invalid transaction directory") }
        try IFFileSafety.noLinks(directory(journal))
        return journal
    }
    private func write(_ journal: Journal) throws {
        let temp = state.appendingPathComponent("journal-\(UUID().uuidString)")
        let data = try JSONEncoder().encode(journal)
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw IFInstallerError.filesystem("write journal", errno)
        }
        defer { try? fm.removeItem(at: temp) }
        let fd = open(temp.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw IFInstallerError.filesystem("open journal", errno) }
        let result = fsync(fd); close(fd)
        guard result == 0, renameatx_np(AT_FDCWD, temp.path, AT_FDCWD, journalURL.path, UInt32(RENAME_EXCL)) == 0 else {
            throw IFInstallerError.filesystem("publish journal", errno)
        }
    }
    private func rename(_ from: URL, _ to: URL, flags: UInt32) throws {
        guard renameatx_np(AT_FDCWD, from.path, AT_FDCWD, to.path, flags) == 0 else {
            throw IFInstallerError.filesystem("atomic rename (no copy fallback)", errno)
        }
    }
    func prepare(_ source: URL) throws {
        try requireLock()
        guard try read() == nil else { throw IFInstallerError.recoveryRequired("Recover prior transaction first") }
        try IFFileSafety.noLinks(target)
        try IFFileSafety.noLinks(state)
        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        guard try IFFileIdentity(parent).device == IFFileIdentity(state).device else {
            throw IFInstallerError.invalid("Installer staging and target must be on the same volume")
        }
        let old = try IFFileSafety.info(target) == nil ? nil : IFFileIdentity(target)
        if old != nil { try verify(target) }
        let id = UUID().uuidString
        let folder = state.appendingPathComponent(id)
        try IFFileSafety.privateDirectory(folder)
        let candidate = folder.appendingPathComponent("candidate.bundle")
        do {
            try fm.copyItem(at: source, to: candidate)
            try verify(candidate)
            let journal = Journal(id: id, new: try IFFileIdentity(candidate), old: old)
            try write(journal)
        } catch {
            // No rename was attempted. An unpublished candidate is safe to remove.
            try? fm.removeItem(at: folder)
            throw error
        }
    }
    func cancelPrepared() throws {
        guard let journal = try read() else { return }
        guard journal.new.matches(slot(journal)), try targetIsOld(journal) else {
            throw IFInstallerError.recoveryRequired("Transaction already changed; cancellation cannot remove it")
        }
        try clear(journal)
    }
    private func targetIsOld(_ journal: Journal) throws -> Bool {
        if let old = journal.old { return old.matches(target) }
        return try IFFileSafety.info(target) == nil
    }
    /// Called only after the coordinator proves old processes have exited, before any launch request.
    func commit(validateCandidate: (URL) throws -> Void = { _ in }) throws {
        guard let journal = try read() else { throw IFInstallerError.invalid("No prepared candidate") }
        try IFFileSafety.noLinks(target)
        guard journal.new.matches(slot(journal)), try targetIsOld(journal) else {
            throw IFInstallerError.recoveryRequired("Target changed since preparation; preserved both bundles")
        }
        try verify(slot(journal))
        try validateCandidate(slot(journal))
        if journal.old != nil { try verify(target) }
        try rename(slot(journal), target, flags: UInt32(journal.old == nil ? RENAME_EXCL : RENAME_SWAP))
        do { try verify(target); try validateCandidate(target) }
        catch {
            do { try rollback(journal) }
            catch { throw IFInstallerError.recoveryRequired("Post-swap verification and rollback failed: \(error)") }
            throw error
        }
        // Files have committed and passed verification. Archive failure must not trigger cancellation.
        do { try finish(journal) }
        catch { throw IFInstallerError.installedRecoveryRequired(String(describing: error)) }

    }
    private func rollback(_ journal: Journal) throws {
        guard journal.new.matches(target) else { throw IFInstallerError.recoveryRequired("Cannot identify new target for rollback") }
        if let old = journal.old {
            guard old.matches(slot(journal)) else { throw IFInstallerError.recoveryRequired("Cannot identify rollback bundle") }
            try verify(slot(journal))
            try rename(slot(journal), target, flags: UInt32(RENAME_SWAP))
            try verify(target)
        } else {
            guard try IFFileSafety.info(slot(journal)) == nil else { throw IFInstallerError.recoveryRequired("Rollback slot occupied") }
            try rename(target, slot(journal), flags: UInt32(RENAME_EXCL))
        }
        try clear(journal)
    }
    /// Never overwrites the formal path during recovery. Inode identities resolve a crash around SWAP.
    @discardableResult func recover() throws -> Bool {
        guard let journal = try read() else { return false }
        try IFFileSafety.noLinks(target)
        if journal.new.matches(slot(journal)), try targetIsOld(journal) {
            try clear(journal); return false
        }
        guard journal.new.matches(target) else {
            throw IFInstallerError.recoveryRequired("Unknown target after interruption; inspect installer state without replacing files")
        }
        try verify(target)
        try finish(journal)
        return true
    }
    private func finish(_ journal: Journal) throws {
        guard journal.new.matches(target) else { throw IFInstallerError.recoveryRequired("Committed target changed") }
        if let old = journal.old {
            guard old.matches(slot(journal)) else {
                throw IFInstallerError.recoveryRequired("Backup identity changed; preserved journal")
            }
            try verify(slot(journal))
            let backup = state.appendingPathComponent("backup-\(journal.id)-\(UUID().uuidString).zip")
            // Recreate into an exclusive temporary archive if a crash left an earlier archive.
            let temp = state.appendingPathComponent("archive-\(UUID().uuidString).zip")
            defer { try? fm.removeItem(at: temp) }
            try archive(slot(journal), temp)
            // A fresh exclusive name makes recovery after archive publication idempotent.
            // Existing archives are retained, never overwritten or assumed trustworthy.
            try rename(temp, backup, flags: UInt32(RENAME_EXCL))
        }
        try clear(journal)
    }
    private func clear(_ journal: Journal) throws {
        // Remove journal before scratch so interruption cannot make an unrelated target recoverable.
        try fm.removeItem(at: journalURL)
        try fm.removeItem(at: directory(journal))
    }
}

struct IFInstallPreparation: Sendable {
    let installed: IFVerifiedApp?
    let candidate: IFVerifiedApp
    let needsReplacement: Bool
}

protocol IFInstallerFileOperations: Sendable {
    var target: URL { get }
    func prepare() async throws -> IFInstallPreparation
    func commit() async throws
    func release(cancelPrepared: Bool) async throws
    func resumeRecovery() async throws -> IFVerifiedApp
    func validateInstalled() async throws -> IFVerifiedApp
}

/// Files, signatures and archive subprocesses execute off the main actor.
actor IFInstallerFiles: IFInstallerFileOperations {
    nonisolated let target: URL
    private let state: URL
    private let userDirectory: URL
    private let systemDirectory: URL
    private let candidate: IFUnpackedShippedCandidate
    private var transaction: IFFileTransaction?
    private let verifier = IFAppVerifier()
    private var expected: IFVerifiedApp?
    private var preparedOld: IFVerifiedApp?

    init(candidate: IFUnpackedShippedCandidate) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        userDirectory = home.appendingPathComponent("Library/Input Methods")
        target = userDirectory.appendingPathComponent("InkFlow.app")
        state = home.appendingPathComponent("Library/Application Support/InkFlow Installer")
        systemDirectory = URL(fileURLWithPath: "/Library/Input Methods")
        self.candidate = candidate
    }
    private func conflicts() throws {
        try IFFileSafety.noLinks(userDirectory)
        try IFFileSafety.noLinks(systemDirectory)
        for directory in [userDirectory, systemDirectory] {
            guard try IFFileSafety.info(directory) != nil else { continue }
            for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                // A link could hide an identity collision; do not resolve it and continue silently.
                try IFFileSafety.noLinks(item)
                let infoURL = item.appendingPathComponent("Contents/Info.plist")
                if let data = try? Data(contentsOf: infoURL),
                   let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   info["CFBundleIdentifier"] as? String == IFInputIdentity.bundleID || info["InputMethodConnectionName"] as? String == IFInputIdentity.connection {
                    guard item.standardizedFileURL == target.standardizedFileURL else {
                        throw IFInstallerError.conflict("Another InkFlow identity exists: \(item.path)")
                    }
                }
            }
        }
        if try IFFileSafety.info(target) != nil { _ = try verifier.verify(target) }
    }
    func prepare() throws -> IFInstallPreparation {
        guard transaction == nil else { throw IFInstallerError.locked }
        let app = try candidate.verify()
        try conflicts()
        let transaction = IFFileTransaction(target: target, state: state,
            verify: { _ = try IFAppVerifier().verify($0) }, archive: Self.archive)
        try transaction.lock()
        self.transaction = transaction
        do {
            _ = try transaction.recover()
            try conflicts()
            let old = try IFFileSafety.info(target) == nil ? nil : verifier.verify(target)
            if let old, old.version.isNewer(than: app.version) { throw IFInstallerError.invalid("A newer InkFlow version is already installed") }
            preparedOld = old
            let replacement = old != app
            expected = app
            if replacement { try transaction.prepare(candidate.unpackedApp) }
            return .init(installed: old, candidate: app, needsReplacement: replacement)
        } catch { transaction.unlock(); self.transaction = nil; throw error }
    }
    func commit() throws {
        try conflicts()
        let current = try IFFileSafety.info(target) == nil ? nil : verifier.verify(target)
        guard current == preparedOld else { throw IFInstallerError.conflict("Installed code changed after preparation") }
        guard let transaction else { throw IFInstallerError.invalid("No install transaction") }
        guard let expected else { throw IFInstallerError.invalid("Missing candidate identity") }
        try transaction.commit { url in
            guard try IFAppVerifier().verify(url) == expected else {
                throw IFInstallerError.invalid("Candidate code/version changed")
            }
        }
        _ = try validateInstalled()
    }
    func release(cancelPrepared: Bool) throws {
        guard let transaction else { return }
        defer { transaction.unlock(); self.transaction = nil }
        if cancelPrepared { try transaction.cancelPrepared() }
    }
    func resumeRecovery() throws -> IFVerifiedApp {
        guard transaction == nil else { throw IFInstallerError.locked }
        let recovery = IFFileTransaction(target: target, state: state,
            verify: { _ = try IFAppVerifier().verify($0) }, archive: Self.archive)
        try recovery.lock()
        defer { recovery.unlock() }
        // Revalidate the expected installed code before touching the journal or archive.
        _ = try validateInstalled()
        _ = try recovery.recover()
        return try validateInstalled()
    }
    func validateInstalled() throws -> IFVerifiedApp {

        try conflicts()
        let app = try verifier.verify(target)
        guard let expected, app == expected else { throw IFInstallerError.invalid("Installed candidate changed") }
        return app
    }
    private static func archive(_ source: URL, _ destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destination.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now + .seconds(30)
        while process.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate() // Only our archive helper; never an input-method process.
            throw IFInstallerError.invalid("Backup archive timed out; old bundle and journal retained")
        }
        guard process.terminationStatus == 0 else { throw IFInstallerError.invalid("Backup archive failed: \(process.terminationStatus)") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
