import InkFlowRime
import Foundation
import Darwin

struct DiagnosticProcess: Codable, Sendable {
    let run: UUID
    let pid: Int32
    let version: String
    let build: String
    var revision: String
    let systemVersion: String

    init(bundle: Bundle = .main) {
        run = UUID(); pid = ProcessInfo.processInfo.processIdentifier
        func token(_ value: Any?) -> String {
            guard let value = value as? String, !value.isEmpty, value.utf8.count <= 64,
                  value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46].contains($0) }) else { return "unknown" }
            return value
        }
        version = token(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString"))
        build = token(bundle.object(forInfoDictionaryKey: "CFBundleVersion"))
        revision = token(bundle.object(forInfoDictionaryKey: "InkFlowBuildRevision"))
        let os = ProcessInfo.processInfo.operatingSystemVersion
        systemVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
}

struct DiagnosticRecord: Codable, Sendable {
    let schema: Int
    let timestamp: Date
    let uptime: Double
    var process: DiagnosticProcess
    let module: LocalDiagnosticEvent.Module
    let event: String
    let outcome: LocalDiagnosticEvent.Outcome
    let reason: String?
    let correlation: UUID?
    let elapsedMilliseconds: Double?
    let errorDomain: LocalDiagnosticEvent.ErrorDomain?
    let errorCode: Int?
    let httpStatus: Int?
    let context: DiagnosticContext?

    init(_ event: LocalDiagnosticEvent, process: DiagnosticProcess, timestamp: Date) {
        schema = 1; self.timestamp = timestamp; uptime = ProcessInfo.processInfo.systemUptime
        self.process = process; module = event.module; self.event = event.event; outcome = event.outcome
        reason = event.reason; correlation = event.correlation; elapsedMilliseconds = event.elapsedMilliseconds
        errorDomain = event.errorDomain; errorCode = event.errorCode; httpStatus = event.httpStatus
        context = event.context
    }

    var isValid: Bool {
        func label(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 80 && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 || $0 == 46
            }
        }
        return schema == 1 && timestamp.timeIntervalSince1970.isFinite && uptime.isFinite && uptime >= 0
            && label(event) && (reason.map(label) ?? true)
            && [process.version, process.build, process.revision, process.systemVersion].allSatisfy(label)
            && (elapsedMilliseconds.map { $0.isFinite && $0 >= 0 } ?? true)
            && (httpStatus.map { (100...599).contains($0) } ?? true)
    }
}

struct DiagnosticLoss: Codable, Sendable {
    var queueDropped = 0
    var oversizedDropped = 0
    var expiredFiles = 0
    var capacityFiles = 0
    var corruptBytes = 0

}

struct DiagnosticStatus: Codable, Sendable {
    enum Availability: String, Codable, Sendable { case available, unavailable }
    enum Failure: String, Codable, Sendable { case unsafePath, ioFailure, busy, tooManyFiles, invalidData }
    var availability: Availability = .available
    var failure: Failure?
    var loss = DiagnosticLoss()
}

struct DiagnosticSnapshot: Codable, Sendable {
    let records: [DiagnosticRecord]
    let status: DiagnosticStatus
    var invalidRecordCount = 0
    var oldest: Date? { records.first?.timestamp }
    var newest: Date? { records.last?.timestamp }
    func jsonLines() throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for record in records { data.append(try encoder.encode(record)); data.append(10) }
        return data
    }
}

struct DiagnosticStoreConfiguration: Sendable {
    var maximumBytes = 50 * 1_024 * 1_024
    var maximumFileBytes = 1_024 * 1_024
    var maximumEventBytes = 2_048
    var maximumQueuedEvents = 512
    var retention: TimeInterval = 7 * 24 * 60 * 60
    var flushDelay: TimeInterval = 1
}

final class LocalDiagnosticStore: @unchecked Sendable {
    private let directory: URL
    private let configuration: DiagnosticStoreConfiguration
    private let process = DiagnosticProcess()
    private let buildMetadataURL: URL?
    private var loadedRevision: String?
    private let now: @Sendable () -> Date
    private let beforeIO: (@Sendable () -> Void)?
    private let beforeWrite: (@Sendable () throws -> Void)?
    private let worker = DispatchQueue(label: "io.damao.inkflow.diagnostics", qos: .utility)
    private let lock = NSLock()
    private var pending: [DiagnosticRecord] = []
    private var queueDropped = 0
    private var disabled = false
    private var requests = 0
    private var status = DiagnosticStatus()
    private var directoryFD: Int32 = -1
    private var lockFD: Int32 = -1
    private var activeFile: String?
    private var recovered = false
    private var invalidRecordCount = 0
    private var maintenanceTimer: DispatchSourceTimer?
    private var lastMaintenance = Date.distantPast

    init(directory: URL, configuration: DiagnosticStoreConfiguration = .init(),
         now: @escaping @Sendable () -> Date = { Date() }, beforeIO: (@Sendable () -> Void)? = nil,
         beforeWrite: (@Sendable () throws -> Void)? = nil, buildMetadataURL: URL? = nil) {
        self.directory = directory; self.configuration = configuration; self.now = now; self.beforeIO = beforeIO
        self.beforeWrite = beforeWrite
        self.buildMetadataURL = buildMetadataURL
        precondition(configuration.maximumBytes >= 4_096 && configuration.maximumFileBytes > 0
            && configuration.maximumFileBytes <= configuration.maximumBytes - 2_048
            && configuration.maximumEventBytes > 0 && configuration.maximumEventBytes <= configuration.maximumFileBytes
            && configuration.maximumQueuedEvents > 0 && configuration.retention > 0)
        let timer = DispatchSource.makeTimerSource(queue: worker)
        let interval = min(60, max(0.01, configuration.flushDelay))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.lock.withLock({ !self.pending.isEmpty }) || self.now().timeIntervalSince(self.lastMaintenance) >= min(60, configuration.retention / 2) {
                self.flush()
            }
        }
        maintenanceTimer = timer
        timer.resume()
    }

    deinit { maintenanceTimer?.cancel(); if lockFD >= 0 { close(lockFD) }; if directoryFD >= 0 { close(directoryFD) } }

    func submit(_ event: LocalDiagnosticEvent) {
        let record = DiagnosticRecord(event, process: process, timestamp: now())
        lock.lock()
        guard !disabled else { lock.unlock(); return }
        if pending.count < configuration.maximumQueuedEvents { pending.append(record) }
        else { queueDropped = min(Int.max - 1, queueDropped) + 1 }
        lock.unlock()
    }

    func snapshot(since: Date? = nil, until: Date? = nil) async -> DiagnosticSnapshot {
        guard lock.withLock({ if requests >= 4 { return false }; requests += 1; return true }) else {
            return .init(records: [], status: .init(availability: .unavailable, failure: .busy))
        }
        return await withCheckedContinuation { continuation in
            worker.async {
                defer { self.lock.withLock { self.requests -= 1 } }
                self.flush()
                do {
                    let records = try self.withDirectoryLock {
                        try self.loadLoss()
                        try self.maintain()
                        let records = try self.readRecords(since: since, until: until)
                        do { try self.saveLoss() } catch { self.fail(error) }
                        return records
                    }
                    continuation.resume(returning: .init(records: records, status: self.status, invalidRecordCount: self.invalidRecordCount))
                } catch {
                    self.fail(error)
                    continuation.resume(returning: .init(records: [], status: self.status))
                }
            }
        }
    }

    private final class DrainReply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ success: Bool) {
            let reply = lock.withLock { let reply = continuation; continuation = nil; return reply }
            reply?.resume(returning: success)
        }
    }

    @discardableResult func drain(timeout: TimeInterval = 0.5) async -> Bool {
        await withCheckedContinuation { continuation in
            let reply = DrainReply(continuation)
            worker.async {
                self.flush()
                reply.finish(self.status.availability == .available && self.lock.withLock { self.pending.isEmpty })
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) { reply.finish(false) }
        }
    }

    private func flush() {
        guard !lock.withLock({ disabled }) else { return }
        beforeIO?()
        do {
            try withDirectoryLock {
                try loadLoss()
                try maintain()
                let batch = lock.withLock { () -> ([DiagnosticRecord], Int) in
                    let batch = pending; let dropped = queueDropped
                    pending.removeAll(keepingCapacity: true); queueDropped = 0
                    return (batch, dropped)
                }
                status.loss.queueDropped += batch.1
                let encoder = Self.encoder()
                if loadedRevision == nil {
                    loadedRevision = "unknown"
                    if let url = buildMetadataURL,
                       let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_384,
                       let data = try? Data(contentsOf: url),
                       let build = try? JSONDecoder().decode(QualityBuildMetadata.self, from: data),
                       (7...64).contains(build.sourceRevision.utf8.count),
                       build.sourceRevision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                        loadedRevision = build.sourceRevision
                    }
                }
                for var record in batch.0 {
                    record.process.revision = loadedRevision ?? "unknown"
                    guard record.isValid else { status.loss.oversizedDropped += 1; continue }
                    var data = try encoder.encode(record); data.append(10)
                    guard data.count <= configuration.maximumEventBytes else { status.loss.oversizedDropped += 1; continue }
                    try maintain(reserving: data.count)
                    try append(data)
                }
                try maintain()
                try saveLoss()
                lastMaintenance = now()
                status.availability = .available; status.failure = nil
            }
        } catch StoreError.failure(.busy) {
            return
        } catch { fail(error) }
    }

    private enum StoreError: Error { case failure(DiagnosticStatus.Failure) }
    private func fail(_ error: Error) {
        status.availability = .unavailable
        status.failure = (error as? StoreError).flatMap { if case let .failure(reason) = $0 { return reason }; return nil } ?? .ioFailure
        if status.failure != .busy {
            lock.withLock { disabled = true; pending.removeAll() }
        }
    }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.sortedKeys]; return encoder
    }
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970; return decoder
    }

    private func prepareDirectory() throws {
        guard directoryFD < 0 else { return }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.failure(.ioFailure) }
        do {
            for part in directory.pathComponents.dropFirst() {
                guard part != "." && part != ".." else { throw StoreError.failure(.unsafePath) }
                var next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT {
                    if mkdirat(fd, part, 0o700) != 0 && errno != EEXIST { throw StoreError.failure(.ioFailure) }
                    next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw StoreError.failure(.unsafePath) }
                close(fd); fd = next
            }
            guard fchmod(fd, 0o700) == 0 else { throw StoreError.failure(.ioFailure) }
            let descriptor = openat(fd, "coordination.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw StoreError.failure(.unsafePath) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1 else {
                close(descriptor); throw StoreError.failure(.unsafePath)
            }
            directoryFD = fd; lockFD = descriptor
        } catch { close(fd); throw error }
    }
    private func withDirectoryLock<T>(_ operation: () throws -> T) throws -> T {
        try prepareDirectory()
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw StoreError.failure(.busy) }
        defer { flock(lockFD, LOCK_UN) }
        return try operation()
    }

    private struct OwnedFile {
        let name: String
        let created: Date
        let size: Int
        let incident: Bool
    }
    private func ownedFiles() throws -> [OwnedFile] {
        let copied = dup(directoryFD)
        guard copied >= 0, let stream = fdopendir(copied) else { if copied >= 0 { close(copied) }; throw StoreError.failure(.ioFailure) }
        defer { closedir(stream) }
        rewinddir(stream)
        var files: [OwnedFile] = [], count = 0
        while let entry = readdir(stream) {
            count += 1
            guard count <= 16_384 else { throw StoreError.failure(.tooManyFiles) }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            let parts = name.split(separator: "_")
            guard parts.count == 3, parts[0] == "log" || parts[0] == "incident",
                  let milliseconds = Int64(parts[1]), milliseconds >= 0,
                  String(milliseconds) == parts[1] else { continue }
            let suffix = parts[0] == "log" ? ".jsonl" : ".json"
            guard parts[2].hasSuffix(suffix) else { continue }
            let identifier = String(parts[2].dropLast(suffix.count))
            guard let uuid = UUID(uuidString: identifier), uuid.uuidString == identifier else { continue }
            var info = stat()
            guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1 else { throw StoreError.failure(.unsafePath) }
            files.append(.init(name: name, created: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
                               size: Int(info.st_size), incident: parts[0] == "incident"))
        }
        return files.sorted { $0.created == $1.created ? $0.name < $1.name : $0.created < $1.created }
    }
    private func maintain(reserving: Int = 0) throws {
        var files = try ownedFiles()
        for file in files where file.created <= now().addingTimeInterval(-configuration.retention) {
            try remove(file.name); status.loss.expiredFiles += 1
        }
        files.removeAll { $0.created <= now().addingTimeInterval(-configuration.retention) }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files where total + reserving > configuration.maximumBytes - 2_048 {
            try remove(file.name); total -= file.size; status.loss.capacityFiles += 1
        }
        if !recovered {
            for file in try ownedFiles() where !file.incident {
                guard file.size <= configuration.maximumFileBytes else {
                    try remove(file.name); status.loss.capacityFiles += 1; continue
                }
                let data = try read(file.name, limit: configuration.maximumFileBytes)
                let end = data.lastIndex(of: 10).map { $0 + 1 } ?? 0
                if end < data.count {
                    let fd = try openRegular(file.name, flags: O_WRONLY)
                    defer { close(fd) }
                    guard ftruncate(fd, off_t(end)) == 0 else { throw StoreError.failure(.ioFailure) }
                    status.loss.corruptBytes += data.count - end
                }
            }
            recovered = true
        }
    }
    private func remove(_ name: String) throws {
        guard unlinkat(directoryFD, name, 0) == 0 else { throw StoreError.failure(.ioFailure) }
        if activeFile == name { activeFile = nil }
    }
    private func openRegular(_ name: String, flags: Int32) throws -> Int32 {
        let fd = openat(directoryFD, name, (flags & ~O_TRUNC) | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.failure(.ioFailure) }
        var info = stat()
        guard fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1 else {
            close(fd); throw StoreError.failure(.unsafePath)
        }
        if flags & O_TRUNC != 0 && ftruncate(fd, 0) != 0 { close(fd); throw StoreError.failure(.ioFailure) }
        return fd
    }
    private func append(_ data: Data) throws {
        if let current = activeFile {
            var info = stat()
            if fstatat(directoryFD, current, &info, AT_SYMLINK_NOFOLLOW) != 0 || info.st_size + Int64(data.count) > configuration.maximumFileBytes { activeFile = nil }
        }
        let name: String
        let fd: Int32
        if let current = activeFile { name = current; fd = try openRegular(name, flags: O_WRONLY | O_APPEND) }
        else {
            name = "log_\(Int64(now().timeIntervalSince1970 * 1_000))_\(UUID()).jsonl"
            fd = try openRegular(name, flags: O_WRONLY | O_CREAT | O_EXCL)
            activeFile = name
        }
        defer { close(fd) }
        let original = lseek(fd, 0, SEEK_END)
        do { try writeAll(data, fd: fd) }
        catch { _ = ftruncate(fd, original); throw error }
    }
    private func writeAll(_ data: Data, fd: Int32) throws {
        try beforeWrite?()
        try data.withUnsafeBytes { bytes in
            var position = 0
            while position < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: position), bytes.count - position)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw StoreError.failure(.ioFailure) }
                position += written
            }
        }
    }
    private func read(_ name: String, limit: Int) throws -> Data {
        let fd = try openRegular(name, flags: O_RDONLY); defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 && info.st_size <= limit else { throw StoreError.failure(.invalidData) }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var position = 0
            while position < bytes.count {
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: position), bytes.count - position)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StoreError.failure(.ioFailure) }
                position += count
            }
        }
        return data
    }
    private func readRecords(since: Date?, until: Date?) throws -> [DiagnosticRecord] {
        invalidRecordCount = 0
        let decoder = Self.decoder()
        var records: [DiagnosticRecord] = []
        let lower = max(since ?? .distantPast, now().addingTimeInterval(-configuration.retention))
        for file in try ownedFiles() where !file.incident {
            let data = try read(file.name, limit: configuration.maximumFileBytes)
            for line in data.split(separator: 10) {
                guard line.count <= configuration.maximumEventBytes,
                      let record = try? decoder.decode(DiagnosticRecord.self, from: Data(line)), record.isValid else {
                    invalidRecordCount += 1
                    continue
                }
                if DiagnosticTime.milliseconds(record.timestamp) >= DiagnosticTime.milliseconds(lower)
                    && DiagnosticTime.milliseconds(record.timestamp) <= DiagnosticTime.milliseconds(until ?? .distantFuture) { records.append(record) }
            }
        }
        return records.sorted { $0.timestamp == $1.timestamp ? $0.uptime < $1.uptime : $0.timestamp < $1.timestamp }
    }
    private func loadLoss() throws {
        var info = stat()
        guard fstatat(directoryFD, "loss.json", &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }; throw StoreError.failure(.ioFailure)
        }
        let data = try read("loss.json", limit: 2_048)
        if let loss = try? JSONDecoder().decode(DiagnosticLoss.self, from: data) { status.loss = loss }
        else { status.loss.corruptBytes += data.count }
    }
    private func saveLoss() throws {
        let data = try JSONEncoder().encode(status.loss)
        let fd = try openRegular("loss.next", flags: O_WRONLY | O_CREAT | O_TRUNC)
        defer { close(fd) }
        try writeAll(data, fd: fd)
        guard renameat(directoryFD, "loss.next", directoryFD, "loss.json") == 0 else { throw StoreError.failure(.ioFailure) }
    }
}

private final class PlatformDiagnosticStorage: @unchecked Sendable {
    static let shared = PlatformDiagnosticStorage()
    let lock = NSLock()
    var storage: LocalDiagnosticStore?
}

extension LocalDiagnostics {
    func activate(directory: URL, buildMetadataURL: URL? = nil) {
        let owner = PlatformDiagnosticStorage.shared
        let activated = owner.lock.withLock {
            guard owner.storage == nil else { return false }
            let store = LocalDiagnosticStore(directory: directory, buildMetadataURL: buildMetadataURL)
            owner.storage = store
            configure { store.submit($0) }
            return true
        }
        if activated {
            Task.detached(priority: .utility) {
                await DiagnosticArchiveWriter(stagingRoot: directory.appendingPathComponent("Exports")).cleanupStale()
            }
        }
    }
    var store: LocalDiagnosticStore? {
        let owner = PlatformDiagnosticStorage.shared
        return owner.lock.withLock { owner.storage }
    }
}
