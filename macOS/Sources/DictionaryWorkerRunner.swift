import Foundation
import Darwin

final class IFDictionaryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private final class IFDictionaryPipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var partial = Data()
    private var truncated = false
    private var stage = IFDictionaryStage.prepare
    private var result: IFDictionaryWorkerResult?
    private var failure: IFDictionaryUpdateError?
    init(limit: Int) { self.limit = limit }
    func drain(_ handle: FileHandle, events: (@Sendable (IFDictionaryProgress) -> Void)? = nil) {
        defer { try? handle.close() }
        while let bytes = try? handle.read(upToCount: 8192), !bytes.isEmpty {
            lock.lock()
            let available = max(0, limit - data.count)
            data.append(bytes.prefix(available)); truncated = truncated || bytes.count > available
            var progress = [IFDictionaryProgress]()
            if events != nil {
                partial.append(bytes)
                while let newline = partial.firstIndex(of: 0x0a) {
                    let line = Data(partial[..<newline]); partial.removeSubrange(...newline)
                    if let event = try? JSONDecoder().decode(IFDictionaryWorkerEvent.self, from: line) {
                        if let update = event.progress { stage = update.stage; progress.append(update) }
                        if let value = event.result { result = value }
                        if let value = event.failure { failure = value; stage = value.stage }
                    }
                }
                if partial.count > limit { partial.removeAll(); truncated = true }
            }
            lock.unlock()
            for update in progress { events?(update) }
        }
    }
    func snapshot() -> (String, IFDictionaryStage, IFDictionaryWorkerResult?, IFDictionaryUpdateError?) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: data, as: UTF8.self) + (truncated ? "\n[diagnostic output truncated]" : ""), stage, result, failure)
    }
}

struct IFDictionaryWorkerRunner: Sendable {
    let runtime: IFDictionaryRuntime
    let protectedUserRoot: URL
    let candidatesRoot: URL
    var timeout: TimeInterval = 600
    var logger: IFDictionaryDiagnosticLogger = { _ in }

    /// sandbox-exec is a deprecated macOS facility. Failure to launch is an error; never run unsandboxed.
    static let sandboxProfile = """
    (version 1)
    (allow default)
    (deny network*)
    (deny file-read* file-write* (subpath (param "USER_ROOT")))
    (allow file-read-metadata (literal (param "USER_ROOT")) (literal (param "STORE_ROOT")) (literal (param "CANDIDATES_ROOT")))
    (deny file-write*)
    (allow file-read* file-write* (subpath (param "CANDIDATE_ROOT")))
    """

    func prepare(candidate: URL, inputs: [IFDictionaryInput],
                 existing: IFDictionaryContentIdentity? = nil,
                 progress: @escaping @Sendable (IFDictionaryProgress) -> Void = { _ in }) async throws -> IFDictionaryWorkerResult {
        let cancellation = IFDictionaryCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try prepareBlocking(candidate: candidate, inputs: inputs, existing: existing, cancellation: cancellation, progress: progress)
            }.value
        } onCancel: { cancellation.cancel() }
    }
    func prepareBlocking(candidate: URL, inputs: [IFDictionaryInput], existing: IFDictionaryContentIdentity? = nil,
                         cancellation: IFDictionaryCancellation = .init(),
                         progress: @escaping @Sendable (IFDictionaryProgress) -> Void = { _ in }) throws -> IFDictionaryWorkerResult {
        do {
            try validateCandidate(candidate)
            guard inputs.map(\.receipt.id) == IFDictionaryCatalog.sources.filter(\.isUpdatable).map(\.id) else {
                throw IFDictionaryUpdateError(.prepare, "source-set")
            }
            let raw = try IFDictionaryFiles.child("raw", in: candidate)
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: false)
            for input in inputs {
                try IFDictionaryGenerator.validate(input)
                try input.data.write(to: IFDictionaryFiles.child(input.receipt.id + ".dict.yaml", in: raw), options: .withoutOverwriting)
            }
            let request = IFDictionaryWorkerRequest(candidate: candidate, runtimeFingerprint: try runtime.fingerprint(),
                receipts: inputs.map(\.receipt), reuseDictionary: false, existing: existing)
            return try runBlocking(request, cancellation: cancellation, progress: progress)
        } catch { let value = IFDictionaryUpdateError.wrapping(error, stage: .prepare); logger(value); throw value }
    }
    /// Bootstrap can call this synchronously before serving input. Reads inert data only, never old executable resources.
    func rebuildBlocking(candidate: URL, dictionaryShared: URL,
                         cancellation: IFDictionaryCancellation = .init(),
                         progress: @escaping @Sendable (IFDictionaryProgress) -> Void = { _ in }) throws -> IFDictionaryWorkerResult {
        do {
            try validateCandidate(candidate)
            let manifest = try IFDictionaryFiles.decode(IFDictionaryManifest.self, at: IFDictionaryFiles.child(IFDictionaryManifest.filename, in: dictionaryShared))
            let retainedRaw = dictionaryShared.deletingLastPathComponent().appendingPathComponent("raw")
            if FileManager.default.fileExists(atPath: retainedRaw.path) {
                let inputs = try manifest.sources.filter { $0.id != "legacy" }.map { receipt in
                    IFDictionaryInput(receipt: receipt, data: try Data(contentsOf: IFDictionaryFiles.child(receipt.id + ".dict.yaml", in: retainedRaw)))
                }
                return try prepareBlocking(candidate: candidate, inputs: inputs, cancellation: cancellation, progress: progress)
            }
            let reuse = try IFDictionaryFiles.child("rebuild", in: candidate)
            try FileManager.default.createDirectory(at: reuse, withIntermediateDirectories: false)
            for name in [IFDictionaryCatalog.dictionaryFilename, IFDictionaryManifest.filename] {
                try FileManager.default.copyItem(at: IFDictionaryFiles.child(name, in: dictionaryShared), to: reuse.appendingPathComponent(name))
            }
            let request = IFDictionaryWorkerRequest(candidate: candidate, runtimeFingerprint: try runtime.fingerprint(), receipts: [],
                reuseDictionary: true, existing: nil)
            return try runBlocking(request, cancellation: cancellation, progress: progress)
        } catch { let value = IFDictionaryUpdateError.wrapping(error, stage: .prepare); logger(value); throw value }
    }
    private func validateCandidate(_ candidate: URL) throws {
        let protected = try IFDictionaryFiles.canonical(protectedUserRoot)
        guard candidate.path != protected.path,
              candidate.path.hasPrefix(protected.path + "/"), candidate.deletingLastPathComponent().path == (try IFDictionaryFiles.canonical(candidatesRoot)).path,
              UUID(uuidString: candidate.lastPathComponent) != nil, timeout > 0,
              candidate.path == (try IFDictionaryFiles.canonical(candidate)).path else {
            throw IFDictionaryUpdateError(.prepare, "unsafe-candidate")
        }
    }
    /// Blocking process core, also used by focused timeout/pipe tests. Executable always comes from local runtime configuration.
    func runBlocking(_ request: IFDictionaryWorkerRequest, cancellation: IFDictionaryCancellation = .init(),
                     progress: @escaping @Sendable (IFDictionaryProgress) -> Void = { _ in }) throws -> IFDictionaryWorkerResult {
        try validateCandidate(request.candidate)
        if cancellation.isCancelled { throw IFDictionaryUpdateError(.prepare, "cancelled") }
        let requestURL = try IFDictionaryFiles.child("request.json", in: request.candidate)
        try IFDictionaryFiles.atomicWrite(IFDictionaryFiles.encode(request), to: requestURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-D", "USER_ROOT=\((try IFDictionaryFiles.canonical(protectedUserRoot)).path)",
                             "-D", "STORE_ROOT=\((try IFDictionaryFiles.canonical(candidatesRoot.deletingLastPathComponent())).path)",
                             "-D", "CANDIDATES_ROOT=\((try IFDictionaryFiles.canonical(candidatesRoot)).path)",
                             "-D", "CANDIDATE_ROOT=\(request.candidate.path)", "-p", Self.sandboxProfile,
                             runtime.helper.path, requestURL.path]
        // No inherited credentials, user paths or injected dynamic-loader environment reach the helper.
        process.environment = ["PATH": "/usr/bin:/bin",
                               "TMPDIR": request.candidate.path, "LANG": "en_US.UTF-8"]
        process.currentDirectoryURL = request.candidate
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr; process.standardInput = FileHandle.nullDevice
        let output = IFDictionaryPipeCapture(limit: 262_144), diagnostics = IFDictionaryPipeCapture(limit: 16_000)
        let readers = DispatchGroup()
        do { try process.run() } catch {
            throw IFDictionaryUpdateError(.prepare, "worker-launch", detail: "\((error as NSError).domain) (\((error as NSError).code))")
        }
        try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        readers.enter()
        DispatchQueue.global().async { output.drain(stdout.fileHandleForReading, events: progress); readers.leave() }
        readers.enter()
        DispatchQueue.global().async { diagnostics.drain(stderr.fileHandleForReading); readers.leave() }
        let start = ProcessInfo.processInfo.systemUptime
        var interrupted: String?
        while process.isRunning {
            if cancellation.isCancelled { interrupted = "cancelled"; break }
            if ProcessInfo.processInfo.systemUptime - start >= timeout { interrupted = "worker-timeout"; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if interrupted != nil, process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit(); readers.wait()
        let (_, stage, result, failure) = output.snapshot()
        let diagnosticText = diagnostics.snapshot().0
        if let interrupted {
            throw IFDictionaryUpdateError(stage, interrupted, exitStatus: process.terminationStatus, stderr: diagnosticText)
        }
        if let failure {
            throw IFDictionaryUpdateError(failure.stage, failure.code, source: failure.source, file: failure.file,
                exitStatus: process.terminationStatus, detail: failure.detail, stderr: diagnosticText)
        }
        guard process.terminationStatus == 0, let result else {
            throw IFDictionaryUpdateError(stage, "worker-exit", exitStatus: process.terminationStatus, stderr: diagnosticText)
        }
        return result
    }
}
