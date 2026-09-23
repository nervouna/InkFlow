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

private final class ProducerCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LocalDiagnosticEvent] = []
    func append(_ event: LocalDiagnosticEvent) { lock.withLock { storage.append(event) } }
    var events: [LocalDiagnosticEvent] { lock.withLock { storage } }
}

@MainActor private final class DiagnosticVoiceFailure: VoiceRecognitionServing {
    let isReady = false
    var cancellation = false
    func prepare(requestPermission: Bool) async throws {
        if cancellation { throw CancellationError() }
        throw NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [NSLocalizedDescriptionKey: "secretContent-provider-body"])
    }
    func start(id: UUID, snapshot: VoiceLexiconSnapshot, callbacks: AppleVoiceRecognizer.Callbacks) { preconditionFailure() }
    func stop(id: UUID) {}
    func cancel() {}
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
        try await metadataAndBoundedDrain(root: root, configuration: config)
        try await producerRecords(root: root, configuration: config)
        print("PASS local diagnostics: correlation, queue/size/age bounds, restart, tail recovery, blocked IO, write failure, symlink refusal, sentinel exclusion")
    }

    @MainActor private static func producerRecords(root: URL, configuration: DiagnosticStoreConfiguration) async throws {
        precondition(LocalDiagnostics.shared.store == nil, "Test producers must never activate the user's diagnostics directory")
        let capture = ProducerCapture(), attempt = UUID(), session = UUID()
        let service = DiagnosticVoiceFailure()
        let preparation = VoicePreparation(service: service)
        await LocalDiagnostics.$observe.withValue({ capture.append($0) }) {
            let startup = IFStartupDiagnostics()
            startup.end(startup.begin(.engine, source: .bundled), .ready)
            InputDiagnostics.write(.init(event: .firstKeyCheckpoint, reason: .none, outcome: nil,
                controller: UUID(), activation: session, key: attempt, stage: .routing,
                elapsedMilliseconds: 12.5))
            AIDiagnostics.write(.init(event: .transportFailed, reason: .network, attempt: attempt,
                session: session, networkCode: -1009, enabled: true, keyPresent: true))
            IFDictionaryCoordinator.persistentLogger(.init(.download, "secretContent-code", source: "secretContent-source",
                httpStatus: 503, detail: "secretContent-detail", stderr: "secretContent-stderr"))
            await preparation.prepare()
            service.cancellation = true
            await preparation.prepare()
        }
        let ai = capture.events.first { $0.module == .ai }!
        precondition(ai.event == "transportFailed" && ai.reason == "network" && ai.context?.session == session
            && ai.context?.attempt == attempt && ai.context?.keyPresent == true)
        let startup = capture.events.filter { $0.module == .startup }
        precondition(startup.count == 2 && startup[0].correlation == startup[1].correlation && startup[0].context?.source == .bundled)
        let voice = capture.events.filter { $0.module == .voice }
        precondition(voice.count == 4 && voice[0].correlation == voice[1].correlation
            && voice[1].outcome == .failed && voice[1].errorDomain == .url && voice[1].errorCode == -1009
            && voice[2].correlation == voice[3].correlation && voice[3].outcome == .cancelled)
        let store = LocalDiagnosticStore(directory: root.appendingPathComponent("Producers"))
        capture.events.forEach(store.submit)
        let snapshot = await store.snapshot()
        precondition(snapshot.records.count == capture.events.count)
        let input = snapshot.records.first { $0.module == .input && $0.event == "firstKeyCheckpoint" }!
        precondition(input.elapsedMilliseconds == 12.5 && input.context?.activation == session
            && input.context?.key == attempt && input.correlation == attempt,
            "Persisted first-key checkpoints must retain timing and correlation")
        let inputJSON = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        precondition(inputJSON.contains("\"inputStage\":\"routing\""),
            "Exported first-key checkpoints must identify their bounded work stage")
        let encoded = String(decoding: try snapshot.jsonLines(), as: UTF8.self)
        precondition(!encoded.contains("secretContent"))
        precondition(snapshot.records.first { $0.module == .dictionary }?.reason == "unknown")
    }

    private static func metadataAndBoundedDrain(root: URL, configuration: DiagnosticStoreConfiguration) async throws {
        let url = root.appendingPathComponent("QualityBuild.json")
        var metadata = QualityBuildMetadata.unknown
        metadata.sourceRevision = "abcdef0123456789abcdef0123456789abcdef0123"
        try JSONEncoder().encode(metadata).write(to: url)
        let store = LocalDiagnosticStore(directory: root.appendingPathComponent("Metadata"), configuration: configuration,
            beforeIO: { precondition(!Thread.isMainThread) }, buildMetadataURL: url)
        store.submit(.init(module: .startup, event: "process", outcome: .begin))
        let result = await store.snapshot()
        precondition(result.records.first?.process.revision == metadata.sourceRevision)
        let gate = DispatchSemaphore(value: 0)
        let blocked = LocalDiagnosticStore(directory: root.appendingPathComponent("Drain"), configuration: configuration,
            beforeIO: { gate.wait() })
        blocked.submit(.init(module: .termination, event: "cleanup", outcome: .completed))
        let began = ProcessInfo.processInfo.systemUptime
        let drained = await blocked.drain(timeout: 0.05)
        precondition(!drained && ProcessInfo.processInfo.systemUptime - began < 1)
        gate.signal()
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
        precondition(snapshot.status.loss.corruptBytes > 0 && snapshot.invalidRecordCount > 0)
        let repeated = await recovered.snapshot(since: exact, until: exact)
        precondition(repeated.invalidRecordCount == snapshot.invalidRecordCount)
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
