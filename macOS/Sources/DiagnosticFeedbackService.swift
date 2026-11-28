import InkFlowRime
import Foundation

enum DiagnosticFeedbackError: Error, LocalizedError {
    case invalidTime, unavailable, archiveFailed, unsafePath
    var errorDescription: String? {
        switch self {
        case .invalidTime: "请选择不晚于当前时间的有效发生时间。"
        case .unavailable: "本地诊断资料暂时不可用。"
        case .archiveFailed: "诊断包未能生成，原有导出文件未更改。"
        case .unsafePath: "无法安全访问所选诊断路径。"
        }
    }
}

enum DiagnosticTime {
    static func milliseconds(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1_000).rounded() }
}

extension DiagnosticSnapshot {
    var isPartial: Bool {
        status.availability == .unavailable || invalidRecordCount > 0 || records.isEmpty
            || status.loss.queueDropped > 0 || status.loss.oversizedDropped > 0
            || status.loss.corruptBytes > 0 || status.loss.expiredFiles > 0 || status.loss.capacityFiles > 0
    }
}

enum DiagnosticExportSelection: Sendable {
    case lastThirtyMinutes, lastDay, retainedHistory
}

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
            stagingRoot: IFApplicationPaths.user.appendingPathComponent("Diagnostics/Exports"))
    }

    func export(_ selection: DiagnosticExportSelection, clickedAt: Date, destination: URL) async throws -> DiagnosticExportResult {
        try Task.checkCancellation()
        guard clickedAt.timeIntervalSince1970.isFinite, clickedAt <= now() else { throw DiagnosticFeedbackError.invalidTime }
        let end = clickedAt
        let start: Date?
        switch selection {
        case .lastThirtyMinutes: start = end.addingTimeInterval(-1_800)
        case .lastDay: start = end.addingTimeInterval(-86_400)
        case .retainedHistory: start = nil
        }
        let snapshot = await store?.snapshot(since: start, until: end)
            ?? .init(records: [], status: .init(availability: .unavailable))
        try Task.checkCancellation()
        let crashes = await crashReader.collect(since: start ?? end.addingTimeInterval(-7 * 86_400), until: end)
        let payload = DiagnosticArchivePayload(snapshot: snapshot,
            requestedStart: start, requestedEnd: end, exportedAt: now(), crashes: crashes)
        try await writer.write(payload, destination: destination)
        return .init(url: destination, eventCount: snapshot.records.count,
                     isPartial: snapshot.isPartial || crashes.issues.contains { $0 != .noMatchingReport })
    }
}

struct DiagnosticExportResult: Sendable {
    let url: URL
    let eventCount: Int
    let isPartial: Bool
}
