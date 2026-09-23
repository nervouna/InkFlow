import Foundation

enum DiagnosticFeedbackError: Error, LocalizedError {
    case noteTooLong, invalidTime, expired, tooLarge, unavailable, missingIncident, invalidIncident, archiveFailed, unsafePath
    var errorDescription: String? {
        switch self {
        case .noteTooLong: "现象说明最多 2,000 字，且不能超过 8 KiB。"
        case .invalidTime: "请选择不晚于当前时间的有效发生时间。"
        case .expired: "所选现场时间已超出本地保留期限。"
        case .tooLarge: "现场大小超出本地诊断容量上限，未保存。"
        case .unavailable: "本地诊断资料暂时不可用。"
        case .missingIncident: "该现场已过期、被容量清理或不存在。"
        case .invalidIncident: "现场文件无法安全读取。"
        case .archiveFailed: "诊断包未能生成，原有导出文件未更改。"
        case .unsafePath: "无法安全访问所选诊断路径。"
        }
    }
}

// Dates are compared in the archive's canonical Unix-millisecond time base.
enum DiagnosticTime {
    static func milliseconds(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1_000).rounded() }
    static func canonical(_ date: Date) -> Date { Date(timeIntervalSince1970: milliseconds(date) / 1_000) }
}

struct DiagnosticIncident: Codable, Sendable {
    let schema: Int
    let id: UUID
    let savedAt: Date
    let occurredAt: Date
    let windowStart: Date
    let windowEnd: Date
    let note: String?
    let snapshot: DiagnosticSnapshot
    var records: [DiagnosticRecord] { snapshot.records }
    var isPartial: Bool { snapshot.isPartial }
    var summary: DiagnosticIncidentSummary {
        .init(id: id, occurredAt: occurredAt, savedAt: savedAt, eventCount: records.count, isPartial: isPartial)
    }
    static func validate(note: String?) throws {
        guard note.map({ $0.count <= 2_000 && $0.utf8.count <= 8_192 }) ?? true else { throw DiagnosticFeedbackError.noteTooLong }
    }
    var isValid: Bool {
        schema == 1 && [savedAt, occurredAt, windowStart, windowEnd].allSatisfy { $0.timeIntervalSince1970.isFinite && Int64(exactly: DiagnosticTime.milliseconds($0)) != nil }
            && DiagnosticTime.milliseconds(occurredAt) <= DiagnosticTime.milliseconds(savedAt)
            && DiagnosticTime.milliseconds(windowEnd) == DiagnosticTime.milliseconds(occurredAt)
            && DiagnosticTime.milliseconds(windowStart) == DiagnosticTime.milliseconds(occurredAt) - 1_800_000
            && (try? Self.validate(note: note)) != nil
            && records.allSatisfy { $0.isValid && DiagnosticTime.milliseconds($0.timestamp) >= DiagnosticTime.milliseconds(windowStart)
                && DiagnosticTime.milliseconds($0.timestamp) <= DiagnosticTime.milliseconds(windowEnd) }
    }
}

struct DiagnosticIncidentSummary: Identifiable, Sendable {
    let id: UUID
    let occurredAt: Date
    let savedAt: Date
    let eventCount: Int
    let isPartial: Bool
}

struct DiagnosticIncidentList: Sendable {
    let incidents: [DiagnosticIncidentSummary]
    let invalidIncidentCount: Int
    var storageStatus: DiagnosticStatus? = nil
}

extension DiagnosticSnapshot {
    var isPartial: Bool {
        status.availability == .unavailable || invalidRecordCount > 0 || records.isEmpty
            || status.loss.queueDropped > 0 || status.loss.oversizedDropped > 0
            || status.loss.corruptBytes > 0 || status.loss.expiredFiles > 0 || status.loss.capacityFiles > 0
    }
}

enum DiagnosticExportSelection: Sendable {
    case lastThirtyMinutes, lastDay, retainedHistory, incident(UUID)
}

/// Service injection keeps the Settings UI independent of the store, filesystem and GitHub reporter.
struct DiagnosticFeedbackService: Sendable {
    let store: LocalDiagnosticStore?
    let crashReader: DiagnosticCrashReader
    let writer: DiagnosticArchiveWriter
    let now: @Sendable () -> Date

    init(store: LocalDiagnosticStore?, crashReader: DiagnosticCrashReader,
         stagingRoot: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(store: store, crashReader: crashReader, writer: .init(stagingRoot: stagingRoot), now: now)
    }
    init(store: LocalDiagnosticStore?, crashReader: DiagnosticCrashReader,
         writer: DiagnosticArchiveWriter, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.crashReader = crashReader; self.writer = writer; self.now = now
    }
    static var live: Self {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return Self(store: LocalDiagnostics.shared.store,
            crashReader: .init(directories: [home.appendingPathComponent("Library/Logs/DiagnosticReports"),
                                            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")]),
            stagingRoot: home.appendingPathComponent("Library/Application Support/InkFlow/Diagnostics/Exports"))
    }

    func save(occurredAt: Date, clickedAt: Date, note: String?) async throws -> DiagnosticIncidentSummary {
        guard let store else { throw DiagnosticFeedbackError.unavailable }
        return try await store.saveIncident(occurredAt: occurredAt, clickedAt: clickedAt, note: note).summary
    }
    func incidents() async throws -> DiagnosticIncidentList {
        guard let store else { throw DiagnosticFeedbackError.unavailable }
        return try await store.incidents()
    }
    func export(_ selection: DiagnosticExportSelection, clickedAt: Date, destination: URL) async throws -> DiagnosticExportResult {
        try Task.checkCancellation()
        guard clickedAt.timeIntervalSince1970.isFinite, clickedAt <= now() else { throw DiagnosticFeedbackError.invalidTime }
        let start: Date?, end: Date, snapshot: DiagnosticSnapshot, incident: DiagnosticIncident?
        switch selection {
        case .incident(let id):
            guard let store else { throw DiagnosticFeedbackError.unavailable }
            let saved = try await store.incident(id: id)
            incident = saved; start = saved.windowStart; end = saved.windowEnd; snapshot = saved.snapshot
        default:
            incident = nil; end = clickedAt
            switch selection {
            case .lastThirtyMinutes: start = end.addingTimeInterval(-1_800)
            case .lastDay: start = end.addingTimeInterval(-86_400)
            default: start = nil
            }
            snapshot = await store?.snapshot(since: start, until: end)
                ?? .init(records: [], status: .init(availability: .unavailable))
        }
        try Task.checkCancellation()
        let crashes = await crashReader.collect(since: start ?? end.addingTimeInterval(-7 * 86_400), until: end)
        let payload = DiagnosticArchivePayload(snapshot: snapshot, incident: incident,
            requestedStart: start, requestedEnd: end, exportedAt: now(), crashes: crashes)
        try await writer.write(payload, destination: destination)
        return .init(url: destination, incidentID: incident?.id, eventCount: snapshot.records.count,
                     isPartial: snapshot.isPartial || crashes.issues.contains { $0 != .noMatchingReport })
    }
}

struct DiagnosticExportResult: Sendable {
    let url: URL
    let incidentID: UUID?
    let eventCount: Int
    let isPartial: Bool
}
