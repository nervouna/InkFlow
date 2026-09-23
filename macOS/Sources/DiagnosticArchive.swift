import Foundation
import Darwin

struct DiagnosticArchivePayload: Sendable {
    let snapshot: DiagnosticSnapshot
    let incident: DiagnosticIncident?
    let requestedStart: Date?
    let requestedEnd: Date
    let exportedAt: Date
    let crashes: DiagnosticCrashCollection

    func files() throws -> [String: Data] {
        struct Manifest: Encodable {
            let formatVersion = 1
            let historyCompleteness = "unknown"
            let dateEncoding = "unixMilliseconds"
            let requestedStart: Date?
            let requestedEnd: Date
            let exportedAt: Date
            let incidentID: UUID?
            let exporter: DiagnosticProcess
            let eventCount: Int
            let oldestEvent: Date?
            let newestEvent: Date?
            let storage: DiagnosticStatus
            let invalidRecordsObserved: Int
            let crashCollection: DiagnosticCrashCollection
            let attachments = ["README.txt", "manifest.json", "events.jsonl", "summary.json"]
        }
        struct Summary: Encodable {
            let note: String?
            let processVersions: [DiagnosticProcess]
            let modules: [String: String]
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        var processes: [DiagnosticProcess] = [], runs = Set<UUID>()
        for record in snapshot.records where runs.insert(record.process.run).inserted { processes.append(record.process) }
        let modules = ["startup", "input", "ai", "voice", "dictionary", "update", "termination", "statistics", "diagnostics"]
        let observed = Set(snapshot.records.map { $0.module.rawValue })
        let manifest = Manifest(requestedStart: requestedStart, requestedEnd: requestedEnd, exportedAt: exportedAt,
            incidentID: incident?.id, exporter: DiagnosticProcess(), eventCount: snapshot.records.count, oldestEvent: snapshot.oldest, newestEvent: snapshot.newest,
            storage: snapshot.status, invalidRecordsObserved: snapshot.invalidRecordCount, crashCollection: crashes)
        let summary = Summary(note: incident?.note, processVersions: processes,
            modules: Dictionary(uniqueKeysWithValues: modules.map { ($0, observed.contains($0) ? "observed" : "notObserved") }))
        return ["README.txt": Data(Self.readme.utf8), "manifest.json": try encoder.encode(manifest),
                "events.jsonl": try snapshot.jsonLines(), "summary.json": try encoder.encode(summary)]
    }

    private static let readme = """
    InkFlow local diagnostic archive / 墨流本地诊断包

    Read manifest.json first: requested and actual event windows, collection status, attachments and observed losses.
    Dates are Unix milliseconds (UTC), independent of the exporting computer's time zone.
    events.jsonl contains one complete structured event per line. Correlation IDs join related stages.
    summary.json contains observed process versions, per-module observation status and the optional user-written note.
    A saved incident freezes its event window. Crash summaries are collected during export for that same window.

    Evidence boundaries / 证据边界
    History completeness is UNKNOWN, even when every loss counter is zero. Recording starts only when InkFlow runs;
    a prior process may have lost its last buffered events or failed to persist loss counters (for example disk full).
    Rolling events and saved incidents share at most 7 days / 50 MiB. Earlier eviction is possible.
    Loss counters are observed cumulative bookkeeping, not an exact count of missing events in the requested window.
    invalidRecordsObserved counts malformed records encountered in this snapshot, not unique lifetime losses.
    A readable store after restart does not prove the preceding process recorded continuously.
    Missing module events mean not observed, never a successful check. Begin without end does not establish a cause.
    A submission event proves the call was made, not that another application visibly accepted text.
    Crash summaries contain only verified InkFlow identity, report capture time, bounded numeric versions/PID and
    a finite exception type. Missing/unsupported/permission-denied/nonfatal/truncated reports are declared explicitly.

    No original system logs, crash reports, database files, configuration contents, input text or credentials are attached.
    The optional note is user supplied and may contain sensitive text: review it before sharing.
    This archive is saved locally; InkFlow does not upload it or automatically submit a GitHub issue.
    """
}

private final class DiagnosticExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

struct DiagnosticArchiveWriter: Sendable {
    typealias Compressor = @Sendable (URL, URL) throws -> Void
    let stagingRoot: URL
    private let compress: Compressor

    init(stagingRoot: URL, compress: @escaping Compressor = { source, destination in
        try Self.ditto(["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--noqtn", source.path, destination.path])
    }) { self.stagingRoot = stagingRoot; self.compress = compress }

    func write(_ payload: DiagnosticArchivePayload, destination: URL) async throws {
        let cancellation = DiagnosticExportCancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await Task.detached(priority: .utility) {
                try cancellation.check()
                let rootFD = try Self.openDirectory(stagingRoot, create: true)
                defer { close(rootFD) }
                let coordination = try Self.coordinate(rootFD)
                defer { close(coordination) }
                Self.cleanupStale(rootFD: rootFD)
                let name = "export_\(UUID())"
                guard mkdirat(rootFD, name, 0o700) == 0 else { throw DiagnosticFeedbackError.archiveFailed }
                let fd = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw DiagnosticFeedbackError.unsafePath }
                defer { Self.removeStage(rootFD: rootFD, name: name, fd: fd); close(fd) }
                let lease = openat(fd, "lease", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard lease >= 0 else { throw DiagnosticFeedbackError.archiveFailed }
                defer { close(lease) }
                guard flock(lease, LOCK_EX | LOCK_NB) == 0, mkdirat(fd, "content", 0o700) == 0 else { throw DiagnosticFeedbackError.archiveFailed }
                flock(coordination, LOCK_UN)
                let stage = stagingRoot.appendingPathComponent(name)
                let content = stage.appendingPathComponent("content")
                for (name, data) in try payload.files() {
                    try cancellation.check()
                    try data.write(to: content.appendingPathComponent(name), options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: content.appendingPathComponent(name).path)
                }
                let archive = stage.appendingPathComponent("archive.zip")
                try compress(content, archive)
                try cancellation.check()
                try Self.install(archive, destination: destination, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    /// Called on activation as well as export. Leases preserve another process's active export.
    func cleanupStale() async {
        await Task.detached(priority: .utility) {
            guard let fd = try? Self.openDirectory(stagingRoot, create: false) else { return }
            defer { close(fd) }
            guard let coordination = try? Self.coordinate(fd) else { return }
            defer { close(coordination) }
            Self.cleanupStale(rootFD: fd)
        }.value
    }

    private static func coordinate(_ fd: Int32) throws -> Int32 {
        let lock = openat(fd, "coordination.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw DiagnosticFeedbackError.unsafePath }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              flock(lock, LOCK_EX) == 0 else { close(lock); throw DiagnosticFeedbackError.unsafePath }
        return lock
    }

    private static func openDirectory(_ url: URL, create: Bool) throws -> Int32 {
        guard url.isFileURL else { throw DiagnosticFeedbackError.unsafePath }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw DiagnosticFeedbackError.unsafePath }
        do {
            for component in url.pathComponents.dropFirst() {
                guard component != ".", component != ".." else { throw DiagnosticFeedbackError.unsafePath }
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && create {
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw DiagnosticFeedbackError.archiveFailed }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw DiagnosticFeedbackError.unsafePath }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }

    private static func cleanupStale(rootFD: Int32) {
        let copied = dup(rootFD)
        guard copied >= 0, let stream = fdopendir(copied) else { if copied >= 0 { close(copied) }; return }
        defer { closedir(stream) }
        rewinddir(stream)
        var count = 0
        while let entry = readdir(stream) {
            count += 1; if count > 16_384 { break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name.hasPrefix("export_"), let uuid = UUID(uuidString: String(name.dropFirst(7))), name == "export_\(uuid)" else { continue }
            let fd = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }; defer { close(fd) }
            // The root coordination lock excludes mkdir/lease creation, so a lease-free stage is abandoned.
            let lease = openat(fd, "lease", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard lease >= 0 else {
                if errno == ENOENT { removeStage(rootFD: rootFD, name: name, fd: fd) }
                continue
            }; defer { close(lease) }
            var info = stat()
            guard fstat(lease, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  flock(lease, LOCK_EX | LOCK_NB) == 0 else { continue }
            removeStage(rootFD: rootFD, name: name, fd: fd)
        }
    }

    private static func removeStage(rootFD: Int32, name: String, fd: Int32) {
        let content = openat(fd, "content", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if content >= 0 {
            for file in ["README.txt", "manifest.json", "events.jsonl", "summary.json"] { _ = unlinkat(content, file, 0) }
            close(content); _ = unlinkat(fd, "content", AT_REMOVEDIR)
        }
        _ = unlinkat(fd, "archive.zip", 0); _ = unlinkat(fd, "lease", 0)
        _ = unlinkat(rootFD, name, AT_REMOVEDIR)
    }

    private static func install(_ archive: URL, destination: URL, cancellation: DiagnosticExportCancellation) throws {
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty else { throw DiagnosticFeedbackError.unsafePath }
        let parent = try openDirectory(destination.deletingLastPathComponent(), create: false)
        defer { close(parent) }
        var existing = stat()
        if fstatat(parent, destination.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1 else { throw DiagnosticFeedbackError.unsafePath }
        } else if errno != ENOENT { throw DiagnosticFeedbackError.archiveFailed }
        let temporary = ".inkflow-export-\(UUID()).tmp"
        let output = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw DiagnosticFeedbackError.archiveFailed }
        defer { close(output); _ = unlinkat(parent, temporary, 0) }
        let input = open(archive.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw DiagnosticFeedbackError.archiveFailed }; defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw DiagnosticFeedbackError.unsafePath }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try cancellation.check()
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw DiagnosticFeedbackError.archiveFailed }
            if count == 0 { break }
            try buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw DiagnosticFeedbackError.archiveFailed }; offset += written
                }
            }
        }
        try cancellation.check()
        guard renameat(parent, temporary, parent, destination.lastPathComponent) == 0 else { throw DiagnosticFeedbackError.archiveFailed }
    }

    static func runDitto(_ arguments: [String]) async throws {
        try await Task.detached(priority: .utility) { try ditto(arguments) }.value
    }
    private static func ditto(_ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw DiagnosticFeedbackError.archiveFailed }
    }
}
