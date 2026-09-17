import Foundation
import Darwin
#if SWIFT_PACKAGE
@testable import InkFlowCore
#endif

private final class ArchiveClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000.123456)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: Double) { lock.withLock { date.addTimeInterval(seconds) } }
}

@main struct DiagnosticArchiveTests {
    static func main() async throws {
        let path = realpath(FileManager.default.temporaryDirectory.path, nil)!
        let root = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("inkflow-archive-test-\(UUID())")
        free(path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ArchiveClock()
        let store = LocalDiagnosticStore(directory: root.appendingPathComponent("Diagnostics"), now: { clock.now() })
        for _ in 0..<80 { store.submit(.init(module: .input, event: "composition", outcome: .completed)) }
        let saved = try await store.saveIncident(occurredAt: clock.now(), clickedAt: clock.now(), note: "Synthetic incident")
        precondition(saved.records.count == 80)
        clock.advance(1)
        store.submit(.init(module: .voice, event: "later", outcome: .begin))
        let restarted = LocalDiagnosticStore(directory: root.appendingPathComponent("Diagnostics"), now: { clock.now() })
        let frozen = try await restarted.incident(id: saved.id)
        precondition(frozen.records.count == 80 && frozen.note == "Synthetic incident")
        let listing = try await restarted.incidents()
        precondition(listing.incidents.map(\.id) == [saved.id])
        do {
            _ = try await store.saveIncident(occurredAt: clock.now(), clickedAt: clock.now(), note: String(repeating: "a", count: 2_001))
            preconditionFailure("Long note accepted")
        } catch DiagnosticFeedbackError.noteTooLong {}
        do {
            _ = try await store.saveIncident(occurredAt: clock.now(), clickedAt: clock.now(), note: String(repeating: "a\u{301}", count: 1_999) + String(repeating: "\u{301}", count: 8_000))
            preconditionFailure("Large grapheme accepted")
        } catch DiagnosticFeedbackError.noteTooLong {}
        let reports = root.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let scanner = DiagnosticCrashReader(directories: [reports])
        let service = DiagnosticFeedbackService(store: store, crashReader: scanner,
            stagingRoot: root.appendingPathComponent("Staging"), now: { clock.now() })
        let destination = root.appendingPathComponent("diagnostics.zip")
        let result = try await service.export(.incident(saved.id), clickedAt: clock.now(), destination: destination)
        precondition(result.eventCount == 80)
        let expanded = root.appendingPathComponent("Expanded")
        try await DiagnosticArchiveWriter.runDitto(["-x", "-k", destination.path, expanded.path])
        let events = try Data(contentsOf: expanded.appendingPathComponent("events.jsonl"))
        precondition(events.count > 8_000 && events.split(separator: 10).count == 80)
        precondition(!String(decoding: events, as: UTF8.self).contains("later"))
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: expanded.appendingPathComponent("manifest.json"))) as! [String: Any]
        precondition(manifest["historyCompleteness"] as? String == "unknown")
        let files = try FileManager.default.contentsOfDirectory(atPath: expanded.path)
        precondition(Set(files) == ["README.txt", "manifest.json", "events.jsonl", "summary.json"])
        try await crashPrivacy(root: root, reports: reports, date: saved.occurredAt)
        try await failureAndCancellation(root: root, service: service, store: store, date: clock.now())
        try await storeBoundaries(root: root)
        try await staleStages(root: root)
        try await crashVariants(reports: reports, date: saved.occurredAt)
        print("PASS diagnostic archives: incident freeze/restart, note limits, ZIP round trip, crash privacy, atomic failure/cancellation")
    }

    private static func crashPrivacy(root: URL, reports: URL, date: Date) async throws {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body: [String: Any] = ["captureTime": formatter.string(from: date), "pid": 42,
            "bundleInfo": ["CFBundleIdentifier": "io.damao.inputmethod.inkflow", "CFBundleShortVersionString": "0.4.4", "CFBundleVersion": "123"],
            "exception": ["type": "EXC_BAD_ACCESS", "message": "secretContent"], "threads": ["secretContent"]]
        let metadata: [String: Any] = ["bug_type": "309", "timestamp": "wrong-secretContent", "bundleID": "io.damao.inputmethod.inkflow"]
        var data = try JSONSerialization.data(withJSONObject: metadata)
        data.append(10); data.append(try JSONSerialization.data(withJSONObject: body))
        try data.write(to: reports.appendingPathComponent("InkFlow.ips"))
        let scan = await DiagnosticCrashReader(directories: [reports]).collect(since: date.addingTimeInterval(-1), until: date.addingTimeInterval(1))
        precondition(scan.summaries.count == 1 && DiagnosticTime.milliseconds(scan.summaries[0].timestamp) == DiagnosticTime.milliseconds(date))
        let encoded = try JSONEncoder().encode(scan)
        precondition(!String(decoding: encoded, as: UTF8.self).contains("secretContent"))
        try FileManager.default.createSymbolicLink(at: reports.appendingPathComponent("InkFlow-linked.ips"), withDestinationURL: reports.appendingPathComponent("InkFlow.ips"))
        let refused = await DiagnosticCrashReader(directories: [reports]).collect(since: date.addingTimeInterval(-1), until: date.addingTimeInterval(1))
        precondition(refused.issues.contains(.unsafePath))
    }

    private static func failureAndCancellation(root: URL, service: DiagnosticFeedbackService, store: LocalDiagnosticStore, date: Date) async throws {
        let destination = root.appendingPathComponent("existing.zip")
        let original = Data("prior-export".utf8)
        try original.write(to: destination)
        let writer = DiagnosticArchiveWriter(stagingRoot: root.appendingPathComponent("FailureStaging"), compress: { _, _ in throw DiagnosticFeedbackError.archiveFailed })
        let failed = DiagnosticFeedbackService(store: store, crashReader: .init(directories: []), writer: writer, now: { date })
        do {
            _ = try await failed.export(.lastThirtyMinutes, clickedAt: date, destination: destination)
            preconditionFailure("Compressor failure accepted")
        } catch DiagnosticFeedbackError.archiveFailed {}
        let preserved = try Data(contentsOf: destination)
        precondition(preserved == original)
        let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        let cancelWriter = DiagnosticArchiveWriter(stagingRoot: root.appendingPathComponent("CancelStaging"), compress: { _, output in
            entered.signal(); gate.wait(); try Data("new".utf8).write(to: output)
        })
        let cancelled = DiagnosticFeedbackService(store: store, crashReader: .init(directories: []), writer: cancelWriter, now: { date })
        let task = Task { try await cancelled.export(.lastThirtyMinutes, clickedAt: date, destination: destination) }
        let waiting = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success) }
        }
        precondition(waiting)
        store.submit(.init(module: .input, event: "whileCompressing", outcome: .ready))
        let current = await store.snapshot()
        precondition(current.records.contains { $0.event == "whileCompressing" })
        task.cancel(); gate.signal()
        do { _ = try await task.value; preconditionFailure("Cancellation accepted") } catch is CancellationError {}
        let afterCancellation = try Data(contentsOf: destination)
        precondition(afterCancellation == original)
        for directory in ["FailureStaging", "CancelStaging"] {
            let contents = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(directory).path)
            precondition(contents == ["coordination.lock"])
        }
    }
    private static func storeBoundaries(root: URL) async throws {
        let clock = ArchiveClock()
        let directory = root.appendingPathComponent("Bounds")
        let store = LocalDiagnosticStore(directory: directory, now: { clock.now() })
        store.submit(.init(module: .input, event: "atStart", outcome: .ready))
        let start = clock.now()
        clock.advance(1_800)
        let clicked = clock.now()
        store.submit(.init(module: .input, event: "atEnd", outcome: .ready))
        clock.advance(0.001)
        store.submit(.init(module: .input, event: "afterEnd", outcome: .ready))
        let frozen = try await store.saveIncident(occurredAt: clicked, clickedAt: clicked, note: nil)
        precondition(frozen.records.map(\.event) == ["atStart", "atEnd"])
        let exact = await store.snapshot(since: start, until: start)
        precondition(exact.records.map(\.event) == ["atStart"])
        do {
            _ = try await store.saveIncident(occurredAt: clock.now().addingTimeInterval(1), clickedAt: clock.now(), note: nil)
            preconditionFailure("Future incident accepted")
        } catch DiagnosticFeedbackError.invalidTime {}
        do {
            _ = try await store.saveIncident(occurredAt: clock.now().addingTimeInterval(-7 * 86_400), clickedAt: clock.now(), note: nil)
            preconditionFailure("Expired incident accepted")
        } catch DiagnosticFeedbackError.expired {}
        // A fresh process can read the surviving history even though bookkeeping writes fail.
        let failed = LocalDiagnosticStore(directory: directory, now: { clock.now() }, beforeWrite: { throw DiagnosticFeedbackError.unavailable })
        let partial = await failed.snapshot()
        precondition(partial.records.count == 3 && partial.status.availability == .unavailable)
        let readableList = try await failed.incidents()
        precondition(readableList.incidents.contains { $0.id == frozen.id }
            && readableList.storageStatus?.availability == .unavailable)
        let readableIncident = try await failed.incident(id: frozen.id)
        precondition(readableIncident.records.count == 2 && readableIncident.isPartial,
                     "Counter-write failure must retain readable frozen evidence with an honest partial status")
        let repaired = await LocalDiagnosticStore(directory: directory, now: { clock.now() }).snapshot()
        precondition(repaired.records.count == 3)
        let service = DiagnosticFeedbackService(store: failed, crashReader: .init(directories: []),
            stagingRoot: root.appendingPathComponent("PartialStaging"), now: { clock.now() })
        let result = try await service.export(.retainedHistory, clickedAt: clock.now(), destination: root.appendingPathComponent("partial.zip"))
        precondition(result.isPartial && result.eventCount == 3)
        let missing = DiagnosticFeedbackService(store: nil, crashReader: .init(directories: []),
            stagingRoot: root.appendingPathComponent("MissingStaging"), now: { clock.now() })
        let absent = try await missing.export(.lastDay, clickedAt: clock.now(), destination: root.appendingPathComponent("missing.zip"))
        precondition(absent.isPartial && absent.eventCount == 0)

        let budgetDirectory = root.appendingPathComponent("Budget")
        let config = DiagnosticStoreConfiguration(maximumBytes: 4_096, maximumFileBytes: 1_024,
            maximumEventBytes: 1_024, maximumQueuedEvents: 4, retention: 3_600, flushDelay: 60)
        let budget = LocalDiagnosticStore(directory: budgetDirectory, configuration: config, now: { clock.now() })
        budget.submit(.init(module: .input, event: "preserve", outcome: .ready))
        let before = await budget.snapshot()
        do {
            _ = try await budget.saveIncident(occurredAt: clock.now(), clickedAt: clock.now(), note: String(repeating: "x", count: 2_000))
            preconditionFailure("Oversized incident accepted")
        } catch DiagnosticFeedbackError.tooLarge {}
        let after = await budget.snapshot()
        precondition(after.records.count == before.records.count && after.status.loss.capacityFiles == before.status.loss.capacityFiles)
        let incident = try await budget.saveIncident(occurredAt: clock.now(), clickedAt: clock.now(), note: nil)
        let unrelated = budgetDirectory.appendingPathComponent("incident_0_\(UUID()).extra.json")
        try Data("user-owned".utf8).write(to: unrelated)
        clock.advance(1_801)
        let expired = try await budget.incidents()
        precondition(expired.incidents.isEmpty && FileManager.default.fileExists(atPath: unrelated.path))
        let listLoss = expired.storageStatus!.loss.expiredFiles
        precondition(listLoss > 0)
        let resumed = LocalDiagnosticStore(directory: budgetDirectory, configuration: config, now: { clock.now() })
        let persisted = await resumed.snapshot()
        precondition(persisted.status.loss.expiredFiles == listLoss,
                     "List-triggered expiry bookkeeping must survive a later reader/restart")
        do { _ = try await budget.incident(id: incident.id); preconditionFailure("Expired saved content survived") }
        catch DiagnosticFeedbackError.missingIncident {}

        let readDirectory = root.appendingPathComponent("ReadExpiry")
        let reader = LocalDiagnosticStore(directory: readDirectory, configuration: config, now: { clock.now() })
        reader.submit(.init(module: .input, event: "readExpiry", outcome: .ready))
        let readIncident = try await reader.saveIncident(occurredAt: clock.now(), clickedAt: clock.now(), note: nil)
        clock.advance(1_801)
        do { _ = try await reader.incident(id: readIncident.id); preconditionFailure("Expired incident read succeeded") }
        catch DiagnosticFeedbackError.missingIncident {}
        let readRestarted = LocalDiagnosticStore(directory: readDirectory, configuration: config, now: { clock.now() })
        let readLoss = await readRestarted.snapshot()
        precondition(readLoss.status.loss.expiredFiles > 0,
                     "Missing-incident result must not discard read-triggered expiry bookkeeping")
    }

    private static func staleStages(root: URL) async throws {
        let staging = root.appendingPathComponent("StaleStages")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let active = staging.appendingPathComponent("export_\(UUID())")
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        let lease = open(active.appendingPathComponent("lease").path, O_RDWR | O_CREAT, 0o600)
        precondition(lease >= 0 && flock(lease, LOCK_EX | LOCK_NB) == 0)
        defer { close(lease) }
        for hasLease in [false, true] {
            let abandoned = staging.appendingPathComponent("export_\(UUID())")
            let content = abandoned.appendingPathComponent("content")
            try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: content.appendingPathComponent("events.jsonl"))
            if hasLease { try Data().write(to: abandoned.appendingPathComponent("lease")) }
        }
        let unrelated = staging.appendingPathComponent("user-data")
        try Data("preserve".utf8).write(to: unrelated)
        let writer = DiagnosticArchiveWriter(stagingRoot: staging)
        await writer.cleanupStale()
        let files = try FileManager.default.contentsOfDirectory(atPath: staging.path)
        precondition(Set(files) == ["coordination.lock", active.lastPathComponent, "user-data"])
        flock(lease, LOCK_UN)
        await writer.cleanupStale()
        precondition(!FileManager.default.fileExists(atPath: active.path))
        precondition(FileManager.default.fileExists(atPath: unrelated.path))
    }

    private static func crashVariants(reports: URL, date: Date) async throws {
        for file in try FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: file) }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let metadata: [String: Any] = ["bug_type": "309", "bundleID": "io.damao.inputmethod.inkflow", "timestamp": "secretContent"]
        let body: [String: Any] = ["captureTime": iso.string(from: date), "pid": 42,
            "bundleInfo": ["CFBundleIdentifier": "io.damao.inputmethod.inkflow", "CFBundleShortVersionString": "secretContent", "CFBundleVersion": "secretContent"],
            "exception": ["type": "secretContent"], "applicationSpecificInformation": "secretContent"]
        func write(_ metadata: [String: Any], _ body: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: metadata); data.append(10)
            data.append(try JSONSerialization.data(withJSONObject: body)); try data.write(to: reports.appendingPathComponent("InkFlow-fixture.ips"))
        }
        let reader = DiagnosticCrashReader(directories: [reports])
        let empty = await reader.collect(since: date, until: date)
        precondition(empty.issues == [.noMatchingReport])
        let missing = await DiagnosticCrashReader(directories: [reports.appendingPathComponent("Missing")]).collect(since: date, until: date)
        precondition(missing.issues == [.missingDirectory])
        try write(metadata, body)
        let unknown = await reader.collect(since: date.addingTimeInterval(-1), until: date.addingTimeInterval(1))
        precondition(unknown.summaries.count == 1 && unknown.summaries[0].exception == .unknown
            && unknown.summaries[0].version == nil && unknown.summaries[0].build == nil)
        let encoded = try JSONEncoder().encode(unknown)
        precondition(!String(decoding: encoded, as: UTF8.self).contains("secretContent"))
        for value: Any in [true, "true", "1", 1] {
            for key in ["isNonFatal", "isSimulated"] {
                var modified = body; modified[key] = value; try write(metadata, modified)
                let result = await reader.collect(since: date.addingTimeInterval(-1), until: date.addingTimeInterval(1))
                precondition(result.summaries.isEmpty && result.issues.contains(key == "isNonFatal" ? .nonfatal : .simulated))
            }
        }
        var wrong = metadata; wrong["bundleID"] = "com.example.other"
        try write(wrong, body)
        let foreign = await reader.collect(since: date.addingTimeInterval(-1), until: date.addingTimeInterval(1))
        precondition(foreign.summaries.isEmpty && foreign.issues == [.noMatchingReport])
        wrong = metadata; wrong["bug_type"] = "298"; try write(wrong, body)
        let unsupported = await reader.collect(since: date.addingTimeInterval(-1), until: date.addingTimeInterval(1))
        precondition(unsupported.summaries.isEmpty && unsupported.issues == [.unsupported])
        try write(metadata, body)
        let outside = await reader.collect(since: date.addingTimeInterval(30), until: date.addingTimeInterval(60))
        precondition(outside.summaries.isEmpty)
        var limited = reader; limited.maximumFileBytes = 10
        let tooLarge = await limited.collect(since: date.addingTimeInterval(-1), until: date.addingTimeInterval(1))
        precondition(tooLarge.issues == [.truncated])
        limited = reader; limited.maximumFiles = 0
        let tooMany = await limited.collect(since: date.addingTimeInterval(-1), until: date.addingTimeInterval(1))
        precondition(tooMany.issues == [.truncated])
        try Data("invalid".utf8).write(to: reports.appendingPathComponent("InkFlow-fixture.ips"))
        let malformed = await reader.collect(since: date, until: date)
        precondition(malformed.issues == [.unsupported])
        try FileManager.default.removeItem(at: reports.appendingPathComponent("InkFlow-fixture.ips"))
        try Data("unrelated malformed report".utf8).write(to: reports.appendingPathComponent("OtherApp.ips"))
        let unrelated = await reader.collect(since: date, until: date)
        precondition(unrelated.issues == [.noMatchingReport])
        chmod(reports.path, 0)
        let denied = await reader.collect(since: date, until: date)
        chmod(reports.path, 0o700)
        precondition(denied.issues == [.permissionDenied])
    }

}
