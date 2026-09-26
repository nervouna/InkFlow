import Foundation
@testable import InkFlowDomain
@testable import InkFlowRime

private final class FixtureCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value || Task.isCancelled { throw IFDictionaryUpdateError(.prepare, "cancelled") }
    }
}

/// Test-only process adapter. Production process/sandbox execution remains in the macOS target.
package struct NativePreparationFixture: Sendable {
    private let runtime: IFDictionaryRuntime
    private let exchanges: URL
    package init(runtime: IFDictionaryRuntime, exchanges: URL) {
        self.runtime = runtime; self.exchanges = exchanges
    }
    package var services: IFDictionaryServices {
        let client = IFDictionarySourceClient()
        return .init(check: { try await client.check(observed: $0) },
                     download: { try await client.download($0, progress: $1) },
                     prepare: { candidate, inputs, existing, progress in
            let cancellation = FixtureCancellation()
            return try await withTaskCancellationHandler {
                let result = try await Task.detached {
                    try cancellation.check()
                    let request = try IFDictionaryPreparation.stage(candidate: candidate, inputs: inputs, runtime: runtime,
                        existing: existing, checkCancellation: cancellation.check)
                    return try run(request, cancellation: cancellation, progress: progress)
                }.value
                try cancellation.check()
                return result
            } onCancel: { cancellation.cancel() }
        }, rebuild: { candidate, dictionary in
            let cancellation = FixtureCancellation()
            let request = try IFDictionaryPreparation.stageRebuild(candidate: candidate, dictionaryShared: dictionary,
                runtime: runtime, checkCancellation: cancellation.check)
            return try run(request, cancellation: cancellation)
        })
    }

    private func run(_ request: IFDictionaryWorkerRequest, cancellation: FixtureCancellation,
                     progress: @escaping @Sendable (IFDictionaryProgress) -> Void = { _ in }) throws -> IFDictionaryWorkerResult {
        let exchange = exchanges.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: exchange, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: exchange) }
        let requestURL = exchange.appendingPathComponent("request.json")
        let eventsURL = exchange.appendingPathComponent("events.jsonl")
        let logURL = exchange.appendingPathComponent("native.log")
        try IFDictionaryFiles.encode(request).write(to: requestURL)
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = runtime.helper
        process.arguments = [requestURL.path, runtime.resources.path, eventsURL.path] + runtime.libraries.map(\.path)
        process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": exchange.path, "LANG": "en_US.UTF-8"]
        process.standardOutput = log; process.standardError = log; process.standardInput = FileHandle.nullDevice
        try cancellation.check()
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        var interruption: Error?
        while process.isRunning {
            do {
                try cancellation.check()
                if ContinuousClock.now >= deadline { throw IFDictionaryUpdateError(.prepare, "worker-timeout") }
            } catch { interruption = error; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if interruption != nil, process.isRunning {
            process.terminate()
            let terminationDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while process.isRunning, ContinuousClock.now < terminationDeadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        if let interruption { throw interruption }
        try cancellation.check()
        var result: IFDictionaryWorkerResult?
        var failure: IFDictionaryUpdateError?
        if FileManager.default.fileExists(atPath: eventsURL.path) {
            let events = try Data(contentsOf: eventsURL)
            guard events.count <= 262_144 else { throw IFDictionaryUpdateError(.prepare, "fixture-event-size") }
            for line in events.split(separator: 0x0a) {
                let event = try JSONDecoder().decode(IFDictionaryWorkerEvent.self, from: Data(line))
                if let update = event.progress { progress(update) }
                if let value = event.result { result = value }
                if let value = event.failure { failure = value }
            }
        }
        let input = try FileHandle(forReadingFrom: logURL); defer { try? input.close() }
        let diagnostics = try input.read(upToCount: 16_000) ?? Data()
        let diagnosticText = String(decoding: diagnostics, as: UTF8.self)
        if let failure {
            throw IFDictionaryUpdateError(failure.stage, failure.code, source: failure.source, file: failure.file,
                httpStatus: failure.httpStatus, exitStatus: process.terminationStatus, detail: failure.detail, stderr: diagnosticText)
        }
        guard process.terminationStatus == 0, let result else {
            throw IFDictionaryUpdateError(.prepare, "fixture-process", exitStatus: process.terminationStatus,
                stderr: diagnosticText)
        }
        return result
    }

    package static func copyRuntime(_ runtime: IFDictionaryRuntime, to destination: URL) throws -> IFDictionaryRuntime {
        let resources = destination.appendingPathComponent("Resources/Rime")
        let helper = destination.appendingPathComponent("bin/preparation-fixture")
        try FileManager.default.createDirectory(at: resources.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: runtime.resources, to: resources)
        let cache = runtime.resources.deletingLastPathComponent().appendingPathComponent(IFPackagedCache.directory)
        if FileManager.default.fileExists(atPath: cache.path) {
            try FileManager.default.copyItem(at: cache, to: resources.deletingLastPathComponent().appendingPathComponent(IFPackagedCache.directory))
        }
        try FileManager.default.copyItem(at: runtime.helper, to: helper)
        return .init(resources: resources, helper: helper, libraries: runtime.libraries)
    }
}
