import Foundation
import Observation
import OSLog

struct IFDictionaryActiveInfo: Sendable {
    let manifest: IFDictionaryManifest
    let activatedAt: Date
    let isBundled: Bool
}

enum IFDictionaryActivity: Equatable {
    case idle, updated, checking, upToDate, updateAvailable, downloading, preparing, verifying, waitingForIdle, applying
}

/// The process owns this service. Views observe it but never create/cancel its task.
struct IFDictionaryServices: Sendable {
    typealias Progress = @Sendable (IFDictionaryProgress) -> Void
    var check: @Sendable ([IFDictionarySourceReceipt]) async throws -> IFDictionaryCheck
    var download: @Sendable (IFDictionaryCheck, @escaping Progress) async throws -> [IFDictionaryInput]
    var prepare: @Sendable (URL, [IFDictionaryInput], IFDictionaryContentIdentity?, @escaping Progress) async throws -> IFDictionaryWorkerResult
    var rebuild: @Sendable (URL, URL) throws -> IFDictionaryWorkerResult

    init(client: IFDictionarySourceClient, worker: IFDictionaryWorkerRunner) {
        check = { try await client.check(observed: $0) }
        download = { try await client.download($0, progress: $1) }
        prepare = { try await worker.prepare(candidate: $0, inputs: $1, existing: $2, progress: $3) }
        rebuild = { try worker.rebuildBlocking(candidate: $0, dictionaryShared: $1) }
    }
}

struct IFDictionaryBackend: Sendable {
    let store: IFDictionaryStore
    let runtime: IFDictionaryRuntime
    let user: URL
    let services: IFDictionaryServices
}

private struct IFPreparedActivation: Sendable {
    let descriptor: IFDictionaryDescriptor
    let configuration: IFEngineConfiguration
}

private struct IFRecoveryPreparation: Sendable {
    let state: IFDictionaryState
    let malformed: Bool
    let fingerprint: String?
    let versions: [String: IFPreparedActivation]
    let bundled: IFPreparedActivation?
    let errors: [IFDictionaryUpdateError]
}

@MainActor @Observable
final class IFDictionaryCoordinator {
    private(set) var activity = IFDictionaryActivity.idle
    private(set) var progress: IFDictionaryProgress?
    private(set) var active: IFDictionaryActiveInfo?
    private(set) var failure: IFDictionaryUpdateError?
    private(set) var engineAvailable = false
    private(set) var isBusy = false
    private(set) var isPresented = false
    private(set) var isShuttingDown = false
    var canCheck: Bool { !isShuttingDown && backend != nil && fingerprint != nil && engineAvailable && !isBusy }
    var canUpdate: Bool { canCheck && checked?.hasUpdate == true }
    var canRetry: Bool { !isShuttingDown && (backend != nil || backendFactory != nil) && !isBusy && retryOperation != nil }

    @ObservationIgnored private var backend: IFDictionaryBackend?
    @ObservationIgnored private let backendFactory: (@Sendable () throws -> IFDictionaryBackend)?
    @ObservationIgnored private let logger: IFDictionaryDiagnosticLogger
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var checked: IFDictionaryCheck?
    @ObservationIgnored private var descriptor: IFDictionaryDescriptor?
    @ObservationIgnored private var configuration: IFEngineConfiguration?
    @ObservationIgnored private var fingerprint: String?
    @ObservationIgnored private var pending: IFPreparedActivation?
    @ObservationIgnored private var servingStartup: (runtime: IFDictionaryRuntime, user: URL)?
    @ObservationIgnored private var servingFallback: IFPreparedActivation?
    @ObservationIgnored private var pendingRecovery: IFDictionaryVersion?
    @ObservationIgnored private var recoveryAlternatives: [(IFDictionaryVersion, IFPreparedActivation)] = []
    @ObservationIgnored private var retryOperation: Operation?
    @ObservationIgnored private var presentationGeneration: UInt64 = 0
    @ObservationIgnored private var operationPresentation: UInt64 = 0
    /// Narrow fault seam for native initialize/probe/individual session restoration tests.
    @ObservationIgnored var activationFault: (IFEngineSwitchStep, Bool) throws -> Void = { _, _ in }
    private enum Operation { case check, update, recovery, servingRecovery, cleanup }

    /// No default root, preferences, networking, or engine startup. Shared Settings remains inert in harnesses.
    init(backend: IFDictionaryBackend? = nil, backendFactory: (@Sendable () throws -> IFDictionaryBackend)? = nil,
         now: @escaping @Sendable () -> Date = Date.init,
         logger: @escaping IFDictionaryDiagnosticLogger = { _ in }) {
        self.backend = backend; self.backendFactory = backendFactory; self.now = now; self.logger = logger
    }

    static let persistentLogger: IFDictionaryDiagnosticLogger = { failure in
        // Only source/protocol/worker diagnostics enter here, never document context or learning data.
        let log = Logger(subsystem: "io.damao.inputmethod.inkflow", category: "dictionary")
        let event = UUID().uuidString
        let parts = diagnosticChunks(failure.technicalDetails)
        for (index, part) in parts.enumerated() {
            log.error("event=\(event, privacy: .public) part=\(index + 1)/\(parts.count) \(part, privacy: .public)")
        }
    }

    /// Unified-log payloads truncate around 1 KiB on the target OS. Scalar-safe chunks retain bounded diagnostics.
    nonisolated static func diagnosticChunks(_ text: String) -> [String] {
        var parts: [String] = [], chunk = "", bytes = 0
        for scalar in text.unicodeScalars {
            let value = String(scalar), count = value.utf8.count
            if bytes + count > 700 { parts.append(chunk); chunk = ""; bytes = 0 }
            chunk += value; bytes += count
        }
        if !chunk.isEmpty { parts.append(chunk) }
        return parts
    }

    func presentationOpened() {
        guard !isPresented else { return }
        isPresented = true
        failure = nil
        // A task's new failure may display in the current presentation; old failures are never replayed.
        operationPresentation = presentationGeneration
    }
    func presentationClosed() {
        isPresented = false; failure = nil; presentationGeneration &+= 1
    }

    func recordUnavailable(_ error: Error) {
        engineAvailable = false
        record(IFDictionaryUpdateError.wrapping(error, stage: .recovery), retry: .recovery)
    }

    /// Legacy synchronous entry point retained for focused harnesses. Production uses bootstrapForServing.
    func bootstrap() { bootstrap(prepared: nil) }

    /// Only immutable, precompiled bundled input precedes server construction. Downloaded recovery
    /// starts later on a detached executor and cannot confirm over the saved journal prematurely.
    func bootstrapForServing(runtime: IFDictionaryRuntime, user: URL) {
        guard !isShuttingDown, !isBusy, !IFEngine.ready else { return }
        servingStartup = (runtime, user)
        let span = IFStartupDiagnostics.shared.begin(.bootstrap, source: .bundled)
        defer { IFStartupDiagnostics.shared.end(span, IFEngine.ready ? .ready : .failed) }
        do {
            let descriptor = try IFStartupDiagnostics.shared.measure(.cacheValidation, source: .bundled) {
                try IFPackagedCache.descriptor(resources: runtime.resources)
            }
            let prepared = try Self.prepareIndex(descriptor, user: user)
            try IFEngine.start(prepared.configuration)
            servingFallback = prepared
            use(prepared, date: now())
            begin(.servingRecovery)
        } catch {
            recordUnavailable(error)
            retryOperation = .servingRecovery
        }
        NotificationCenter.default.post(name: .engineAvailabilityDidChange, object: nil)
    }

    private func bootstrap(prepared: IFRecoveryPreparation?) {
        guard !isShuttingDown, !isBusy, !IFEngine.ready else { return }
        let startup = IFStartupDiagnostics.shared
        let bootstrapSpan = startup.begin(.bootstrap, source: prepared == nil ? .process : .prepared)
        defer { startup.end(bootstrapSpan, IFEngine.ready ? .ready : .failed) }
        if backend == nil, let backendFactory {
            do { backend = try startup.measure(.backend) { try backendFactory() } }
            catch { recordUnavailable(error); return }
        }
        guard let backend else { return }
        let store = backend.store
        var malformed = prepared?.malformed ?? false
        var state = prepared?.state ?? IFDictionaryState()
        if let prepared {
            fingerprint = prepared.fingerprint
            for error in prepared.errors { record(error, retry: .recovery) }
        } else {
            do { state = try startup.measure(.journal) { try store.recoverInterrupted() } }
            catch { malformed = true; record(.wrapping(error, stage: .recovery), retry: .recovery) }
            do { fingerprint = try startup.measure(.fingerprint) { try backend.runtime.fingerprint() } }
            catch { record(.wrapping(error, stage: .recovery), retry: .recovery) }
        }

        if let fingerprint, !malformed, state.bundled == nil {
            for version in [state.current, state.previous].compactMap({ $0 }) {
                do {
                    let resolved: IFPreparedActivation
                    if let prepared {
                        guard let cached = prepared.versions[version.artifactID] else { continue }
                        resolved = cached
                    } else { resolved = try recover(version, backend: backend, fingerprint: fingerprint) }
                    try IFEngine.start(resolved.configuration)
                    var activationDate = version.activatedAt ?? now()
                    do {
                        if resolved.descriptor.version != version {
                            let prepared = resolved.descriptor.version!
                            try store.beginValidatedActivation(prepared)
                            activationDate = prepared.contentVersion == version.contentVersion ? version.activatedAt ?? now() : now()
                            try store.confirmActivation(prepared, now: activationDate)
                        } else { try store.confirmValidatedFallback(version) }
                    } catch { IFEngine.stop(); throw error }
                    use(resolved, date: activationDate)
                    finishRecoveryCleanup(store, deferred: prepared != nil)
                    NotificationCenter.default.post(name: .engineAvailabilityDidChange, object: nil)
                    return
                } catch {
                    IFEngine.stop()
                    record(.wrapping(error, stage: .recovery), retry: .recovery)
                    do { try store.abandonActivation() }
                    catch { record(.wrapping(error, stage: .recovery), retry: .recovery) }
                }
            }
        }
        do {
            let loaded: IFPreparedActivation
            if let prepared {
                guard let bundled = prepared.bundled else { throw IFDictionaryUpdateError(.recovery, "bundled-unavailable") }
                loaded = bundled
            } else { loaded = try Self.prepareIndex(store.bundled(backend.runtime.resources), user: backend.user) }
            let bundled = loaded.descriptor
            try IFEngine.start(loaded.configuration)
            let date = !malformed && state.bundled?.contentVersion == bundled.manifest.contentVersion ? state.bundled!.activatedAt : now()
            do {
                if malformed { try store.repairBundled(bundled.manifest, now: date) }
                else { try store.confirmBundled(bundled.manifest, now: date) }
            } catch { IFEngine.stop(); throw error }
            use(loaded, date: date)
            finishRecoveryCleanup(store, deferred: prepared != nil)
        } catch {
            IFEngine.stop(); engineAvailable = false; active = nil; descriptor = nil; configuration = nil
            record(.wrapping(error, stage: .recovery), retry: .recovery)
        }
        NotificationCenter.default.post(name: .engineAvailabilityDidChange, object: nil)
    }

    private func recover(_ version: IFDictionaryVersion, backend: IFDictionaryBackend, fingerprint: String) throws -> IFPreparedActivation {
        do {
            let descriptor = try IFStartupDiagnostics.shared.measure(.cacheValidation, source: .downloaded) {
                try backend.store.resolve(version, fingerprint: fingerprint)
            }
            return try Self.prepareIndex(descriptor, user: backend.user)
        }
        catch {
            record(.wrapping(error, stage: .recovery), retry: .recovery)
            return try Self.rebuild(version, backend: backend, fingerprint: fingerprint)
        }
    }

    private nonisolated static func rebuild(_ version: IFDictionaryVersion, backend: IFDictionaryBackend, fingerprint: String) throws -> IFPreparedActivation {
        return try IFStartupDiagnostics.shared.measure(.rebuild, source: .downloaded) {
            let inert = try backend.store.storedDictionary(version)
            let candidate = try backend.store.candidate()
            defer { if FileManager.default.fileExists(atPath: candidate.path) { try? backend.store.removeCandidate(candidate) } }
            _ = try backend.services.rebuild(candidate, inert)
            let rebuilt = try backend.store.adopt(candidate, fingerprint: fingerprint)
            return try Self.prepareIndex(backend.store.resolve(rebuilt, fingerprint: fingerprint), user: backend.user)
        }
    }

    /// Manual and serving recovery share disk validation, helper work and indexes on a background executor.
    /// The serving path supplies its already-running packaged fallback to avoid rebuilding its index.
    private nonisolated static func prepareRecovery(_ backend: IFDictionaryBackend, bundledFallback: IFPreparedActivation? = nil) -> IFRecoveryPreparation {
        var errors: [IFDictionaryUpdateError] = []
        var state = IFDictionaryState(), malformed = false
        do { state = try IFStartupDiagnostics.shared.measure(.journal) { try backend.store.recoverInterrupted() } }
        catch { malformed = true; errors.append(.wrapping(error, stage: .recovery)) }
        var fingerprint: String?
        do { fingerprint = try IFStartupDiagnostics.shared.measure(.fingerprint) { try backend.runtime.fingerprint() } }
        catch { errors.append(.wrapping(error, stage: .recovery)) }
        var versions: [String: IFPreparedActivation] = [:]
        if let fingerprint, !malformed, state.bundled == nil {
            for version in [state.current, state.previous].compactMap({ $0 }) {
                do {
                    do { versions[version.artifactID] = try prepareIndex(backend.store.resolve(version, fingerprint: fingerprint), user: backend.user) }
                    catch {
                        errors.append(.wrapping(error, stage: .recovery))
                        versions[version.artifactID] = try rebuild(version, backend: backend, fingerprint: fingerprint)
                    }
                } catch { errors.append(.wrapping(error, stage: .recovery)) }
            }
        }
        var bundled = bundledFallback
        if bundled == nil {
            do { bundled = try prepareIndex(backend.store.bundled(backend.runtime.resources), user: backend.user) }
            catch { errors.append(.wrapping(error, stage: .recovery)) }
        }
        return .init(state: state, malformed: malformed, fingerprint: fingerprint, versions: versions, bundled: bundled, errors: errors)
    }

    private func finishRecoveryCleanup(_ store: IFDictionaryStore, deferred: Bool) {
        if !deferred {
            do { try store.cleanup() } catch { record(.wrapping(error, stage: .recovery), retry: .recovery) }
        }
        IFEngine.idleHandler = nil
    }

    /// Drain owned tasks, including detached file/worker work. Never cancel a filesystem transaction midway.
    /// Pending activation is abandoned only after every producer has stopped; normal replacement is unchanged.
    func shutdown() async throws {
        isShuttingDown = true
        IFEngine.idleHandler = nil
        while let current = task { await current.value }
        IFEngine.idleHandler = nil
        pending = nil
        pendingRecovery = nil; recoveryAlternatives = []
        if let backend {
            try await Task.detached { try backend.store.abandonActivation() }.value
            _ = try await Task.detached { try backend.store.cleanup() }.value
        }
        isBusy = false; operationID = nil; progress = nil
    }

    func checkForUpdates() {
        guard canCheck else { return }
        begin(.check)
    }
    /// Only a user action after a successful check may enter this path.
    func downloadAndUpdate() {
        guard canUpdate else { return }
        begin(.update)
    }
    func retry() {
        guard canRetry, let retryOperation else { return }
        if let startup = servingStartup, retryOperation == .servingRecovery || !engineAvailable {
            if engineAvailable { begin(.servingRecovery) }
            else { bootstrapForServing(runtime: startup.runtime, user: startup.user) }
        }
        else if !engineAvailable { begin(.recovery) }
        else if retryOperation == .recovery || retryOperation == .cleanup { begin(.cleanup) }
        else if retryOperation == .check { checkForUpdates() }
        else { downloadAndUpdate() }
    }

    private func begin(_ operation: Operation) {
        guard !isShuttingDown, !isBusy else { return }
        failure = nil; retryOperation = nil; isBusy = true; progress = nil
        operationPresentation = presentationGeneration
        let id = UUID(); operationID = id
        if operation == .servingRecovery {
            beginServingRecovery()
            return
        }
        if operation == .recovery {
            activity = .preparing
            task = Task { [self] in
                do {
                    if backend == nil, let factory = backendFactory { backend = try await Task.detached { try factory() }.value }
                    if let backend {
                        let prepared = await Task.detached { Self.prepareRecovery(backend) }.value
                        isBusy = false
                        bootstrap(prepared: prepared)
                        isBusy = true
                        await cleanupAfterOperation(backend.store)
                    }
                } catch { recordUnavailable(error) }
                isBusy = false; task = nil; operationID = nil; activity = .idle
            }
            return
        }
        guard let backend else { isBusy = false; operationID = nil; return }
        activity = operation == .check ? .checking : operation == .update ? .downloading : .idle
        task = Task { [self] in
            do {
                switch operation {
                case .check:
                    guard let descriptor else { throw IFDictionaryUpdateError(.check, "engine-unavailable") }
                    let observed = try await Task.detached { try backend.store.observed(active: descriptor.manifest) }.value
                    checked = try await backend.services.check(observed)
                    operationID = nil
                    activity = checked!.hasUpdate ? .updateAvailable : .upToDate
                case .update:
                    guard let checked, let descriptor, let fingerprint else { throw IFDictionaryUpdateError(.prepare, "missing-check") }
                    let report: IFDictionaryServices.Progress = { [weak self] update in
                        Task { @MainActor in self?.acceptProgress(update, operation: id) }
                    }
                    let inputs = try await backend.services.download(checked, report)
                    activity = .preparing
                    let candidate = try await Task.detached { try backend.store.candidate() }.value
                    do {
                        let identity = IFDictionaryContentIdentity(contentVersion: descriptor.manifest.contentVersion, runtimeFingerprint: fingerprint)
                        let result = try await backend.services.prepare(candidate, inputs, identity, report)
                        operationID = nil; progress = nil
                        if result.outcome == .contentUnchanged {
                            try await Task.detached {
                                try backend.store.recordContentUnchanged(result.manifest, activeContentVersion: descriptor.manifest.contentVersion)
                                try backend.store.removeCandidate(candidate)
                            }.value
                            self.checked = nil; activity = .upToDate
                        } else {
                            let date = now()
                            // Hash-heavy adopt/resolve and immutable context-index construction all stay off the input actor.
                            let prepared = try await Task.detached {
                                let version = try backend.store.adopt(candidate, fingerprint: fingerprint, now: date)
                                let prepared = try Self.prepareIndex(backend.store.resolve(version, fingerprint: fingerprint), user: backend.user)
                                try backend.store.beginActivation(version)
                                return prepared
                            }.value
                            pending = prepared
                            activity = .waitingForIdle; progress = nil
                            IFEngine.idleHandler = { [weak self] in self?.activateIfIdle() }
                            IFEngine.signalIdle()
                            task = nil
                            return // Single-flight remains occupied while pending activation waits for every session.
                        }
                    } catch {
                        await Task.detached { if FileManager.default.fileExists(atPath: candidate.path) { try? backend.store.removeCandidate(candidate) } }.value
                        throw error
                    }
                case .cleanup:
                    if fingerprint == nil {
                        fingerprint = try await Task.detached { try backend.runtime.fingerprint() }.value
                    }
                    try await Task.detached { try backend.store.abandonActivation() }.value
                case .recovery, .servingRecovery: break
                }
                retryOperation = nil
            } catch {
                operationID = nil
                record(.wrapping(error, stage: operation == .check ? .check : operation == .cleanup ? .recovery : .prepare), retry: operation)
                activity = checked?.hasUpdate == true ? .updateAvailable : .idle
            }
            await cleanupAfterOperation(backend.store)
            isBusy = false; task = nil; operationID = nil; progress = nil
        }
    }

    /// Keep the transient bundled engine serving during every disk/index/worker wait. No new
    /// persistent fallback pointer is needed: only successful recovery confirms the existing journal.
    private func beginServingRecovery() {
        activity = .preparing
        task = Task { [self] in
            do {
                if backend == nil, let factory = backendFactory { backend = try await Task.detached { try factory() }.value }
                guard !isShuttingDown else { finishServingRecovery(); return }
                guard let backend, let fallback = servingFallback else {
                    throw IFDictionaryUpdateError(.recovery, "backend-unavailable")
                }
                let prepared = await Task.detached { Self.prepareRecovery(backend, bundledFallback: fallback) }.value
                guard !isShuttingDown else { finishServingRecovery(); return }
                fingerprint = prepared.fingerprint
                for error in prepared.errors { record(error, retry: .servingRecovery) }
                recoveryAlternatives = [prepared.state.current, prepared.state.previous].compactMap { original in
                    guard let original, let value = prepared.versions[original.artifactID] else { return nil }
                    return (original, value)
                }
                if !recoveryAlternatives.isEmpty {
                    queueServingRecovery()
                    return
                }
                if prepared.malformed {
                    let date = now()
                    // The unreadable journal cannot supply recoverable pointers. Match the existing
                    // repair contract only after the shipped fallback has actually started successfully.
                    try await Task.detached { try backend.store.repairBundled(fallback.descriptor.manifest, now: date) }.value
                    guard !isShuttingDown else { finishServingRecovery(); return }
                    use(fallback, date: date)
                    retryOperation = fingerprint == nil ? .servingRecovery : nil
                    await cleanupAfterOperation(backend.store)
                    finishServingRecovery(); return
                }
                guard prepared.errors.isEmpty else {
                    retryOperation = .servingRecovery
                    finishServingRecovery(); return
                }
                let date = prepared.state.bundled?.contentVersion == fallback.descriptor.manifest.contentVersion
                    ? prepared.state.bundled!.activatedAt : now()
                try await Task.detached { try backend.store.confirmBundled(fallback.descriptor.manifest, now: date) }.value
                guard !isShuttingDown else { finishServingRecovery(); return }
                use(fallback, date: date)
                retryOperation = nil
                await cleanupAfterOperation(backend.store)
            } catch {
                record(.wrapping(error, stage: .recovery), retry: .servingRecovery)
            }
            finishServingRecovery()
        }
    }

    private func queueServingRecovery() {
        guard !isShuttingDown, !recoveryAlternatives.isEmpty else { finishServingRecovery(); return }
        let (original, prepared) = recoveryAlternatives.removeFirst()
        pendingRecovery = original; pending = prepared
        activity = .waitingForIdle; task = nil
        IFEngine.idleHandler = { [weak self] in self?.activateIfIdle() }
        IFEngine.signalIdle()
    }

    private func finishServingRecovery() {
        isBusy = false; task = nil; operationID = nil; activity = .idle; progress = nil
    }

    private func acceptProgress(_ update: IFDictionaryProgress, operation: UUID) {
        guard operationID == operation, isBusy, pending == nil else { return }
        progress = update
        switch update.stage {
        case .download: activity = .downloading
        case .prepare: activity = .preparing
        case .verify: activity = .verifying
        default: break
        }
    }

    /// Invoked by a deferred native idle signal, never by polling or network work in a key callback.
    func activateIfIdle() {
        guard !isShuttingDown, let backend, let pending, activity == .waitingForIdle, IFEngine.allSessionsIdle else { return }
        activity = .applying
        let recovery = pendingRecovery
        let date = recovery.flatMap { original in
            pending.descriptor.manifest.contentVersion == original.contentVersion ? original.activatedAt : nil
        } ?? now()
        var recovered = false
        do {
            try IFEngine.replace(with: pending.configuration, restoring: configuration, fault: activationFault) {
                if let recovery {
                    if pending.descriptor.version == recovery { try backend.store.confirmValidatedFallback(recovery) }
                    else {
                        try backend.store.beginValidatedActivation(pending.descriptor.version!)
                        try backend.store.confirmActivation(pending.descriptor.version!, now: date)
                    }
                } else { try backend.store.confirmActivation(pending.descriptor.version!, now: date) }
            }
            use(pending, date: date)
            recovered = true
            checked = nil; retryOperation = nil; activity = .updated
        } catch {
            engineAvailable = IFEngine.ready
            if !engineAvailable { active = nil; descriptor = nil; configuration = nil }
            record(.wrapping(error, stage: .apply), retry: recovery == nil ? .update : .servingRecovery)
            activity = checked?.hasUpdate == true ? .updateAvailable : .idle
        }
        self.pending = nil
        pendingRecovery = nil
        IFEngine.idleHandler = nil
        task = Task { [self] in
            // Confirm is compact; journal abandonment and artifact housekeeping follow on a background executor.
            do { try await Task.detached { try backend.store.abandonActivation() }.value }
            catch { record(.wrapping(error, stage: .recovery), retry: .recovery) }
            if recovery != nil && !recovered {
                if !isShuttingDown, engineAvailable, !recoveryAlternatives.isEmpty {
                    queueServingRecovery(); return
                }
                // Preserve the saved versions for retry when only the transient fallback is usable.
                recoveryAlternatives = []
                retryOperation = .servingRecovery
            } else {
                recoveryAlternatives = []
                await cleanupAfterOperation(backend.store)
            }
            isBusy = false; task = nil; operationID = nil; progress = nil
        }
    }

    private func cleanupAfterOperation(_ store: IFDictionaryStore) async {
        do { _ = try await Task.detached { try store.cleanup() }.value }
        catch { record(.wrapping(error, stage: .recovery), retry: .recovery) }
    }

    private func use(_ prepared: IFPreparedActivation, date: Date) {
        descriptor = prepared.descriptor
        let loaded = prepared.configuration
        // Bundled bootstrap compiled the user's ordinary build cache. Preserve it for a compile-free rollback.
        configuration = .init(shared: loaded.shared,
            cache: loaded.cache ?? URL(fileURLWithPath: loaded.user).appendingPathComponent("build"),
            user: loaded.user, ranker: loaded.ranker)
        active = .init(manifest: prepared.descriptor.manifest, activatedAt: date, isBundled: prepared.descriptor.version == nil)
        engineAvailable = IFEngine.ready
    }

    private nonisolated static func prepareIndex(_ descriptor: IFDictionaryDescriptor, user: URL) throws -> IFPreparedActivation {
        let ranker = try IFStartupDiagnostics.shared.measure(.indexes, source: descriptor.version == nil ? .bundled : .downloaded) {
            try IFContextRanker(dictionary: descriptor.sharedData.appendingPathComponent(IFDictionaryCatalog.dictionaryFilename).path)
        }
        return .init(descriptor: descriptor, configuration: .init(shared: descriptor.sharedData, cache: descriptor.cache, user: user.path, ranker: ranker))
    }

    private func record(_ value: IFDictionaryUpdateError, retry: Operation) {
        logger(value)
        retryOperation = retry
        if isPresented && operationPresentation == presentationGeneration { failure = value }
    }
}
