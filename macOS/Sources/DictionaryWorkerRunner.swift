import InkFlowRime
import InkFlowDomain
import Foundation

final class IFDictionaryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private final class IFDictionaryWorkerEvents: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (IFDictionaryProgress) -> Void
    private var stage = IFDictionaryStage.prepare
    private var result: IFDictionaryWorkerResult?
    private var failure: IFDictionaryUpdateError?
    init(progress: @escaping @Sendable (IFDictionaryProgress) -> Void) { self.progress = progress }
    func consume(_ line: Data) {
        guard let event = try? JSONDecoder().decode(IFDictionaryWorkerEvent.self, from: line) else { return }
        lock.lock()
        if let update = event.progress { stage = update.stage }
        if let value = event.result { result = value }
        if let value = event.failure { failure = value; stage = value.stage }
        lock.unlock()
        if let update = event.progress { progress(update) }
    }
    func snapshot() -> (IFDictionaryStage, IFDictionaryWorkerResult?, IFDictionaryUpdateError?) {
        lock.lock(); defer { lock.unlock() }
        return (stage, result, failure)
    }
}

struct IFDictionaryWorkerRunner: Sendable {
    let runtime: IFDictionaryRuntime
    let protectedUserRoot: URL
    let candidatesRoot: URL
    var timeout: TimeInterval = 600
    var logger: IFDictionaryDiagnosticLogger = { _ in }

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
            let result = try await Task.detached {
                try prepareBlocking(candidate: candidate, inputs: inputs, existing: existing, cancellation: cancellation, progress: progress)
            }.value
            try checkCancellation(cancellation)
            return result
        } onCancel: { cancellation.cancel() }
    }
    func prepareBlocking(candidate: URL, inputs: [IFDictionaryInput], existing: IFDictionaryContentIdentity? = nil,
                         cancellation: IFDictionaryCancellation = .init(),
                         progress: @escaping @Sendable (IFDictionaryProgress) -> Void = { _ in }) throws -> IFDictionaryWorkerResult {
        do {
            try checkCancellation(cancellation)
            try validateCandidate(candidate)
            let request = try IFDictionaryPreparation.stage(candidate: candidate, inputs: inputs, runtime: runtime,
                existing: existing, checkCancellation: { try checkCancellation(cancellation) })
            return try runBlocking(request, cancellation: cancellation, progress: progress)
        } catch { let value = IFDictionaryUpdateError.wrapping(error, stage: .prepare); logger(value); throw value }
    }
    func rebuildBlocking(candidate: URL, dictionaryShared: URL,
                         cancellation: IFDictionaryCancellation = .init(),
                         progress: @escaping @Sendable (IFDictionaryProgress) -> Void = { _ in }) throws -> IFDictionaryWorkerResult {
        do {
            try checkCancellation(cancellation)
            try validateCandidate(candidate)
            let request = try IFDictionaryPreparation.stageRebuild(candidate: candidate, dictionaryShared: dictionaryShared,
                runtime: runtime, checkCancellation: { try checkCancellation(cancellation) })
            return try runBlocking(request, cancellation: cancellation, progress: progress)
        } catch { let value = IFDictionaryUpdateError.wrapping(error, stage: .prepare); logger(value); throw value }
    }
    private func checkCancellation(_ cancellation: IFDictionaryCancellation) throws {
        if cancellation.isCancelled || Task.isCancelled { throw IFDictionaryUpdateError(.prepare, "cancelled") }
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
    func runBlocking(_ request: IFDictionaryWorkerRequest, cancellation: IFDictionaryCancellation = .init(),
                     progress: @escaping @Sendable (IFDictionaryProgress) -> Void = { _ in }) throws -> IFDictionaryWorkerResult {
        let startup = IFStartupDiagnostics.shared
        let span = startup.begin(.worker, source: .downloaded)
        var outcome: IFStartupDiagnostics.Status = .failed
        defer { startup.end(span, outcome) }
        try validateCandidate(request.candidate)
        if cancellation.isCancelled || Task.isCancelled { outcome = .cancelled; throw IFDictionaryUpdateError(.prepare, "cancelled") }
        let requestURL = try IFDictionaryFiles.child("request.json", in: request.candidate)
        try IFDictionaryFiles.atomicWrite(IFDictionaryFiles.encode(request), to: requestURL)
        let roots = [
            (name: "USER_ROOT", path: try IFDictionaryFiles.canonical(protectedUserRoot).path),
            (name: "STORE_ROOT",
             path: try IFDictionaryFiles.canonical(candidatesRoot.deletingLastPathComponent()).path),
            (name: "CANDIDATES_ROOT", path: try IFDictionaryFiles.canonical(candidatesRoot).path),
            (name: "CANDIDATE_ROOT", path: request.candidate.path)
        ]
        let events = IFDictionaryWorkerEvents(progress: progress)
        var launcher = IFSandboxedWorkerLauncher(profile: Self.sandboxProfile, roots: roots, helper: runtime.helper,
            arguments: [requestURL.path], directory: request.candidate, timeout: timeout, killGrace: 1)
        launcher.isCancelled = { cancellation.isCancelled || Task.isCancelled }
        launcher.stdoutLimit = 262_144
        launcher.onStdoutLine = { events.consume($0) }
        launcher.stderrLimit = 16_000
        try checkCancellation(cancellation)
        let ended: IFSandboxedWorkerLauncher.Exit
        do {
            ended = try launcher.run()
        } catch {
            let detail = "\((error as NSError).domain) (\((error as NSError).code))"
            throw IFDictionaryUpdateError(.prepare, "worker-launch", detail: detail)
        }
        let (stage, result, failure) = events.snapshot()
        let diagnosticText = ended.stderr
        let interrupted: String? = switch ended.interruption {
        case .cancelled: "cancelled"
        case .timeout: "worker-timeout"
        case nil: nil
        }
        if let interrupted {
            outcome = interrupted == "cancelled" ? .cancelled : .timeout
            throw IFDictionaryUpdateError(stage, interrupted, exitStatus: ended.status, stderr: diagnosticText)
        }
        if let failure {
            throw IFDictionaryUpdateError(failure.stage, failure.code, source: failure.source, file: failure.file,
                exitStatus: ended.status, detail: failure.detail, stderr: diagnosticText)
        }
        guard ended.status == 0, let result else {
            throw IFDictionaryUpdateError(stage, "worker-exit", exitStatus: ended.status, stderr: diagnosticText)
        }
        outcome = .ready
        return result
    }
}
