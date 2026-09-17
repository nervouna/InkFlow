import Foundation
import Darwin
#if SWIFT_PACKAGE
@testable import InkFlowCore
#endif

private final class TestClock: @unchecked Sendable {
    let lock = NSLock()
    var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value.addTimeInterval(seconds) } }
}

@main struct LocalDiagnosticsTests {
    static func main() async throws {
        // Foundation deliberately abbreviates /private/var to /var even in resolvingSymlinksInPath.
        // The store refuses symlink ancestors, so use the physical POSIX temporary directory path.
        let physical = realpath(FileManager.default.temporaryDirectory.path, nil)!
        let temporary = URL(fileURLWithPath: String(cString: physical)); free(physical)
        let root = temporary
            .appendingPathComponent("inkflow-diagnostics-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock()
        let config = DiagnosticStoreConfiguration(maximumBytes: 16_384, maximumFileBytes: 2_048,
            maximumEventBytes: 1_024, maximumQueuedEvents: 4, retention: 60, flushDelay: 60)
        let store = LocalDiagnosticStore(directory: root.appendingPathComponent("Diagnostics"),
            configuration: config, now: { clock.now() })
        let correlation = UUID()
        store.submit(.init(module: .input, event: "composition", outcome: .begin, correlation: correlation))
        store.submit(.init(module: .input, event: "composition", outcome: .failed, reason: "engineUnavailable", correlation: correlation))
        let first = await store.snapshot()
        precondition(first.status.availability == .available, "Status: \(first.status)")
        precondition(first.records.count == 2)
        precondition(first.records[0].correlation == first.records[1].correlation)
        precondition(first.records.allSatisfy { $0.process.run == first.records[0].process.run })
        let firstData = try first.jsonLines()
        precondition(!String(decoding: firstData, as: UTF8.self).contains("secretContent"))
        for _ in 0..<9 { store.submit(.init(module: .input, event: "bounded", outcome: .ready)) }
        let overflow = await store.snapshot()
        precondition(overflow.status.loss.queueDropped == 5)
        precondition(overflow.records.count == 6)
        let restarted = LocalDiagnosticStore(directory: root.appendingPathComponent("Diagnostics"), configuration: config, now: { clock.now() })
        let afterRestart = await restarted.snapshot()
        precondition(afterRestart.records.count == 6 && afterRestart.status.loss.queueDropped == 5)
        clock.advance(61)
        let expired = await store.snapshot()
        precondition(expired.records.isEmpty && expired.status.loss.expiredFiles > 0)
        // A blocked worker cannot hold the submission lock or enqueue an unbounded number of events.
        let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        let gated = LocalDiagnosticStore(directory: root.appendingPathComponent("Gated"), configuration: config,
            beforeIO: { entered.signal(); gate.wait() })
        gated.submit(.init(module: .input, event: "first", outcome: .ready))
        let waiter = Task.detached { await gated.snapshot() }
        precondition(entered.wait(timeout: .now() + 5) == .success)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 { gated.submit(.init(module: .input, event: "gated", outcome: .ready)) }
        precondition(ProcessInfo.processInfo.systemUptime - start < 0.1)
        gate.signal()
        _ = await waiter.value
        // Unsafe directories must fail closed without touching a symlink target.
        let outside = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let unsafe = LocalDiagnosticStore(directory: link, configuration: config)
        unsafe.submit(.init(module: .input, event: "unsafe", outcome: .ready))
        let denied = await unsafe.snapshot()
        precondition(denied.status.availability == .unavailable)
        let outsideFiles = try FileManager.default.contentsOfDirectory(atPath: outside.path)
        precondition(outsideFiles.isEmpty)
        try await recoveryAndPrivacy(root: root, configuration: config, clock: clock)
        try await capacityAndFailure(root: root, configuration: config, clock: clock)
        print("PASS local diagnostics: correlation, queue/size/age bounds, restart, tail recovery, blocked IO, write failure, symlink refusal, sentinel exclusion")
    }

    private static func recoveryAndPrivacy(root: URL, configuration: DiagnosticStoreConfiguration, clock: TestClock) async throws {
        let directory = root.appendingPathComponent("Recovery")
        let initial = LocalDiagnosticStore(directory: directory, configuration: configuration, now: { clock.now() })
        clock.advance(0.123)
        let exact = clock.now()
        initial.submit(.init(module: .voice, event: "resources", outcome: .failed, reason: "permissionDenied"))
        let written = await initial.snapshot()
        precondition(written.records.count == 1)
        let file = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" }!
        var object = try JSONSerialization.jsonObject(with: written.jsonLines()) as! [String: Any]
        object["privateText"] = "secretContent-sentinel"
        var injected = try JSONSerialization.data(withJSONObject: object); injected.append(10)
        injected.append(Data("{\"privateText\":\"secretContent-invalid\"}\n{\"privateText\":\"secretContent-tail".utf8))
        try injected.write(to: file)
        let recovered = LocalDiagnosticStore(directory: directory, configuration: configuration, now: { clock.now() })
        let snapshot = await recovered.snapshot(since: exact, until: exact)
        precondition(snapshot.records.count == 1)
        precondition(snapshot.oldest!.timeIntervalSince1970 == exact.timeIntervalSince1970
            && snapshot.newest!.timeIntervalSince1970 == exact.timeIntervalSince1970)
        precondition(snapshot.status.loss.corruptBytes > 0 && snapshot.status.loss.invalidRecords > 0)
        let safe = String(decoding: try snapshot.jsonLines(), as: UTF8.self)
        precondition(!safe.contains("secretContent") && !safe.contains("privateText"))
        let repaired = try Data(contentsOf: file)
        precondition(repaired.last == 10)
        // A second process/run can append without replacing the earlier process identity.
        recovered.submit(.init(module: .voice, event: "resources", outcome: .ready))
        let joined = await recovered.snapshot()
        precondition(Set(joined.records.map { $0.process.run }).count == 2)
        let coordination = open(directory.appendingPathComponent("coordination.lock").path, O_RDWR)
        precondition(coordination >= 0 && flock(coordination, LOCK_EX | LOCK_NB) == 0)
        recovered.submit(.init(module: .input, event: "waiting", outcome: .begin))
        let busy = await recovered.snapshot()
        precondition(busy.status.failure == .busy)
        flock(coordination, LOCK_UN); close(coordination)
        let resumed = await recovered.snapshot()
        precondition(resumed.status.availability == .available && resumed.status.failure == nil)
        precondition(resumed.records.contains { $0.event == "waiting" })
    }

    private static func capacityAndFailure(root: URL, configuration: DiagnosticStoreConfiguration, clock: TestClock) async throws {
        let directory = root.appendingPathComponent("Capacity")
        let store = LocalDiagnosticStore(directory: directory, configuration: configuration, now: { clock.now() })
        for _ in 0..<20 {
            for _ in 0..<4 { store.submit(.init(module: .input, event: "composition", outcome: .completed)) }
            _ = await store.snapshot()
            clock.advance(0.1)
        }
        let bounded = await store.snapshot()
        precondition(bounded.records.count < 80 && bounded.status.loss.capacityFiles > 0)
        // Reserved incident filenames participate in exactly the same age/size budget.
        let incident = directory.appendingPathComponent("incident_\(Int64(clock.now().timeIntervalSince1970 * 1_000))_\(UUID()).json")
        try Data(repeating: 32, count: 10_000).write(to: incident)
        let unrelated = directory.appendingPathComponent("user-owned.txt")
        try Data("keep".utf8).write(to: unrelated)
        _ = await store.snapshot()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let ownedSize = try files.filter { $0.lastPathComponent.hasPrefix("log_") || $0.lastPathComponent.hasPrefix("incident_") }
            .reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
        precondition(ownedSize <= configuration.maximumBytes - 2_048)
        precondition(FileManager.default.fileExists(atPath: incident.path) && FileManager.default.fileExists(atPath: unrelated.path))
        enum FullDisk: Error { case full }
        let failed = LocalDiagnosticStore(directory: root.appendingPathComponent("Failed"), configuration: configuration,
            beforeWrite: { throw FullDisk.full })
        failed.submit(.init(module: .input, event: "write", outcome: .ready))
        let unavailable = await failed.snapshot()
        precondition(unavailable.status.availability == .unavailable && unavailable.status.failure == .ioFailure)
        for _ in 0..<100 { failed.submit(.init(module: .input, event: "ignored", outcome: .ready)) }
        let afterFailure = await failed.snapshot()
        precondition(afterFailure.records.isEmpty)
        let denied = root.appendingPathComponent("Denied")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o500])
        defer { chmod(denied.path, 0o700) }
        let permission = LocalDiagnosticStore(directory: denied.appendingPathComponent("Diagnostics"), configuration: configuration)
        let result = await permission.snapshot()
        precondition(result.status.availability == .unavailable)
    }
}
