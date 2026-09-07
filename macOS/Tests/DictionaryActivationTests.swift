import AppKit

private final class TestBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
    func update(_ body: (inout Value) -> Void) { lock.lock(); body(&storage); lock.unlock() }
}

private actor TestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@main struct DictionaryActivationTests {
    @MainActor static func main() async throws {
        check(CommandLine.arguments.count == 3)
        let diagnostic = String(repeating: "中文🙂e\u{301}诊断\n", count: 3000) + "TAIL-END"
        let parts = IFDictionaryCoordinator.diagnosticChunks(diagnostic)
        check(parts.count > 1 && parts.allSatisfy { $0.utf8.count <= 700 && !$0.isEmpty } && parts.joined() == diagnostic,
              "Persistent diagnostics retain every UTF-8 scalar through bounded chunks")
        print("PASS logging: <=700-byte chunks rejoin complete Chinese/emoji/combining-scalar diagnostics")
        let root = try IFDictionaryFiles.canonical(URL(fileURLWithPath: CommandLine.arguments[1]))
        let repository = URL(fileURLWithPath: CommandLine.arguments[2])
        let runtime = IFDictionaryRuntime.bundled(helper: repository.appendingPathComponent("build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker"))
        let fingerprint = try runtime.fingerprint()
        let templateStore = try IFDictionaryStore(root: root.appendingPathComponent("template/Dictionaries"))
        let worker = IFDictionaryWorkerRunner(runtime: runtime, protectedUserRoot: root.appendingPathComponent("template"),
            candidatesRoot: templateStore.root.appendingPathComponent("candidates"))
        let candidate = try templateStore.candidate()
        // One real worker preparation proves the full generator/compiler/probe -> coordinator activation path.
        let inputs = try IFDictionaryCatalog.sources.filter(\.isUpdatable).map { spec in
            var data = try Data(contentsOf: repository.appendingPathComponent("build/dictionary-sources/\(spec.id).yaml"))
            if spec.id == "frost-8105" { data.append(Data("\n墨流更新测试\tmo liu geng xin ce shi\t7\n".utf8)) }
            let receipt = IFDictionarySourceReceipt(id: spec.id,
                commit: spec.pinnedCommit, blobSHA: IFDictionaryHash.gitBlob(data), sha256: IFDictionaryHash.sha256(data),
                byteCount: data.count, recordCount: 0, name: spec.name, repository: spec.repository, path: spec.path)
            return IFDictionaryInput(receipt: receipt, data: data)
        }
        let result = try await worker.prepare(candidate: candidate, inputs: inputs)
        check(result.outcome == .prepared, "Real worker produces update with extra synthetic entry")
        let version = try templateStore.adopt(candidate, fingerprint: fingerprint)
        let template = try templateStore.resolve(version, fingerprint: fingerprint)
        try await nativeLifecycle(root: root, runtime: runtime, template: template)
        try await qualityAcrossReplacement(root: root, template: template)
        try partialRestoreModes(root: root, template: template)
        try await missingFingerprintRetry(root: root, runtime: runtime)
        try await coordinatorLifecycle(root: root, runtime: runtime, template: template)
        try await transactionFailures(root: root, runtime: runtime, template: template)
        try await recovery(root: root, runtime: runtime, template: template)
        try await domainCatalogUpgrade(root: root, runtime: runtime, repository: repository)
        IFEngine.stop(); IFEngine.idleHandler = nil
        print("PASS activation: all focused native/coordinator/recovery tests")
    }

    @MainActor static func until(_ message: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(90)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        check(condition(), message)
    }

    @MainActor static func qualityAcrossReplacement(root: URL, template: IFDictionaryDescriptor) async throws {
        let store = QualityStore(url: root.appendingPathComponent("replacement-quality.sqlite3"),
                                 engineVersion: IFEngine.version, buildMetadata: .unknown)
        IFEngine.configureQualityRecording(store)
        defer { IFEngine.stop(); IFEngine.configureQualityRecording(nil) }
        let configuration = try config(template.sharedData, cache: template.cache,
                                       user: root.appendingPathComponent("replacement-quality-user"))
        try IFEngine.start(configuration)
        let existing = IFEngine()!
        let recorder = existing.qualityRecorder
        check(recorder != nil, "Production recording is configured before coordinator startup")
        type(existing, "nihao"); existing.key(32); check(existing.takeCommit() == "你好")
        await store.flush()
        let initialWrites = store.statistics().written
        check(initialWrites > 0)

        try IFEngine.replace(with: configuration, restoring: configuration, confirm: {})
        check(existing.qualityRecorder === recorder)
        let fresh = IFEngine()!
        check(fresh.qualityRecorder != nil, "New controllers retain recording after dictionary replacement")
        existing.asciiMode = true
        check(existing.qualitySnapshot().configuration.asciiMode)
        existing.asciiMode = false
        type(existing, "nihao"); existing.key(32); check(existing.takeCommit() == "你好")
        type(fresh, "nihao"); fresh.key(32); check(fresh.takeCommit() == "你好")
        await store.flush()
        check(store.statistics().written > initialWrites, "Restored and new sessions still write quality records")

        expectFailure("engine-unavailable") {
            try IFEngine.replace(with: configuration, restoring: configuration,
                fault: { step, _ in if step == .probe { throw IFDictionaryUpdateError(.apply, "quality-recovery-fixture") } }, confirm: {})
        }
        check(!existing.available && !existing.qualitySnapshot().selectedPrefixValid)
        existing.setQualityPresentation(fontSize: 18, vertical: true)
        try IFEngine.start(configuration)
        let recovered = IFEngine()!
        check(recovered.qualityRecorder != nil, "Manual recovery retains the process recording store")
        type(recovered, "nihao")
        let beforeStop = store.statistics().submitted
        IFEngine.stop()
        check(store.statistics().submitted > beforeStop, "Restored recorder registry still records interruption")
        await store.close()
        print("PASS merged lifecycle: quality recording survives replacement/recovery for existing and new sessions; unavailable snapshots are safe")
    }

    @MainActor static func expectFailure(_ code: String? = nil, _ body: () throws -> Void) {
        do { try body(); check(false, "Expected failure \(code ?? "")") }
        catch let error as IFDictionaryUpdateError { if let code { check(error.code == code, error.technicalDetails) } }
        catch { check(code == nil, "Unexpected error \(error)") }
    }

    @MainActor static func config(_ shared: URL, cache: URL?, user: URL) throws -> IFEngineConfiguration {
        .init(shared: shared, cache: cache, user: user.path,
              ranker: try IFContextRanker(dictionary: shared.appendingPathComponent(IFDictionaryCatalog.dictionaryFilename).path))
    }

    @MainActor static func nativeLifecycle(root: URL, runtime: IFDictionaryRuntime, template: IFDictionaryDescriptor) async throws {
        let legacy = root.appendingPathComponent("legacy-shared")
        try FileManager.default.copyItem(at: runtime.resources, to: legacy)
        let legacyDictionary = try Data(contentsOf: runtime.resources.appendingPathComponent(IFDictionaryCatalog.legacyFilename))
        try legacyDictionary.write(to: legacy.appendingPathComponent(IFDictionaryCatalog.dictionaryFilename))
        let user = root.appendingPathComponent("learning-user")
        let old = try config(legacy, cache: nil, user: user)
        try IFEngine.start(old)
        var primary: IFEngine? = IFEngine()!
        type(primary!, "beijing")
        check(primary!.snapshot().candidates.first == "北京", "Old legacy 北京 first")
        primary!.select(0)
        check(!IFEngine.allSessionsIdle, "Native commit blocks idle even when preedit empty")
        check(!IFEngine.allSessionsIdle, "Peeking preserves pending text in buffered commit")
        check(primary!.takeCommit() == "北京", "Peeking must not discard learned commit")
        let hidden = IFEngine()!
        let ascii = IFEngine()!
        ascii.asciiMode = true
        primary!.setConfiguration(candidateCount: 9, customPhrases: [CustomPhrase(id: UUID(), code: "zz", text: "隔离短语")])
        hidden.setCandidateCount(3)
        type(hidden, "nihao")
        let next = try config(template.sharedData, cache: template.cache, user: user)
        let oldCached = IFEngineConfiguration(shared: old.shared, cache: user.appendingPathComponent("build"), user: old.user, ranker: old.ranker)
        expectFailure("sessions-busy") { try IFEngine.replace(with: next, restoring: oldCached, confirm: {}) }
        check(!hidden.snapshot().preedit.isEmpty, "Hidden composition survives deferred update")
        hidden.commit()
        check(!IFEngine.allSessionsIdle, "Hidden native commit blocks activation")
        check(hidden.takeCommit() == "你好")
        primary!.beginDelivery()
        expectFailure("sessions-busy") { try IFEngine.replace(with: next, restoring: oldCached, confirm: {}) }
        primary!.endDelivery()
        try IFEngine.replace(with: next, restoring: oldCached, confirm: {})
        check(primary!.available && hidden.available && ascii.available, "Every live weak-registered instance restored")
        check(primary!.candidateCount == 9 && hidden.candidateCount == 3 && ascii.asciiMode, "Counts and ASCII mode retained")
        type(primary!, "zz"); check(primary!.snapshot().candidates.first == "隔离短语", "Custom phrases restored")
        primary!.clear(); type(primary!, "beijing")
        check(primary!.snapshot().candidates.first == "北京", "Real learned 北京 remains first after expanded dictionary activation")
        primary!.clear()
        check(FileManager.default.fileExists(atPath: user.appendingPathComponent("pinyin_simp.userdb").path), "Same learning database identity/path retained")
        for step in [IFEngineSwitchStep.start, .probe, .session(1)] {
            expectFailure("injected") {
                try IFEngine.replace(with: next, restoring: next, fault: { current, rollback in
                    if !rollback && current == step { throw IFDictionaryUpdateError(.apply, "injected") }
                }, confirm: {})
            }
            check(primary!.available && hidden.available && ascii.asciiMode, "Rollback restores all sessions and modes for \(step)")
        }
        expectFailure("write-failed") {
            try IFEngine.replace(with: next, restoring: next) { throw IFDictionaryUpdateError(.apply, "write-failed") }
        }
        expectFailure("engine-unavailable") {
            try IFEngine.replace(with: next, restoring: next, fault: { step, _ in
                if step == .probe { throw IFDictionaryUpdateError(.apply, "double-failure") }
            }, confirm: {})
        }
        check(!IFEngine.ready && !primary!.available && !hidden.available, "Double failure explicitly invalidates engine")
        for engine in [primary!, hidden, ascii] {
            check(!engine.key(97)); check(!engine.event(keyEvent(0, "a")))
            engine.select(0); engine.highlight(0); engine.commit(); engine.clear(); engine.setPrecedingText("隔离")
            engine.setCandidateCount(5); check(engine.snapshot().preedit.isEmpty && engine.takeCommit().isEmpty)
        }
        // Deinit of an invalidated old object must never destroy the next generation's reused native ID.
        try IFEngine.start(next)
        let newSession = IFEngine()!
        primary = nil
        type(newSession, "nihao"); check(!newSession.snapshot().candidates.isEmpty)
        newSession.clear(); IFEngine.stop()
        let clean = try config(template.sharedData, cache: template.cache, user: root.appendingPathComponent("clean-user"))
        try IFEngine.start(clean)
        let cleanSession = IFEngine()!
        type(cleanSession, "beijing"); check(cleanSession.snapshot().candidates.first == "背景", "Clean expanded corpus distinguishes learning from corpus ordering")
        cleanSession.clear(); IFEngine.stop()
        print("PASS native: all-session idle/native+buffered commits/delivery lease, mode/count/phrase restore, learned 北京 vs clean 背景, start/probe/session/write rollback, double failure and stale IDs")
    }

    @MainActor static func partialRestoreModes(root: URL, template: IFDictionaryDescriptor) throws {
        check(IFEngine.liveSessions.isEmpty, "Partial-restoration fixture has no earlier sessions")
        let user = root.appendingPathComponent("partial-restore-user")
        let configuration = try config(template.sharedData, cache: template.cache, user: user)
        try IFEngine.start(configuration)
        let engine = IFEngine()!
        engine.setConfiguration(candidateCount: 7, customPhrases: [CustomPhrase(id: UUID(), code: "zz", text: "隔离短语")])
        engine.asciiMode = true
        let permissions = try FileManager.default.attributesOfItem(atPath: user.path)[.posixPermissions]!
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: user.path); IFEngine.stop() }
        // Exercise the actual fallible custom-phrase write AFTER native session creation/schema selection.
        expectFailure("session-settings") {
            try IFEngine.replace(with: configuration, restoring: configuration, fault: { step, rollback in
                if !rollback && step == .session(0) {
                    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: user.path)
                }
                if rollback && step == .start {
                    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: user.path)
                }
            }, confirm: {})
        }
        check(engine.available && engine.asciiMode && engine.candidateCount == 7,
              "Transient settings-write failure preserves captured ASCII mode through partial cleanup and rollback")
        // A real allocated session also needs safe cleanup before schema selection has completed.
        expectFailure("session-create") {
            try IFEngine.replace(with: configuration, restoring: configuration, fault: { step, rollback in
                if !rollback && step == .sessionCreated(0) { throw IFDictionaryUpdateError(.apply, "session-create") }
            }, confirm: {})
        }
        check(engine.available && engine.asciiMode && engine.candidateCount == 7,
              "Pre-schema failure preserves captured ASCII mode while destroying the partially created native session")
        engine.asciiMode = false
        type(engine, "zz"); check(engine.snapshot().candidates.first == "隔离短语", "Rollback retains the actual custom phrase configuration")
        engine.clear()
        print("PASS partial restoration: real transient settings-write failure and allocated pre-schema session failure retain ASCII/count/phrases through rollback")
    }

    nonisolated static func copyTemplate(_ template: IFDictionaryDescriptor, to candidate: URL) throws -> IFDictionaryWorkerResult {
        let source = template.sharedData.deletingLastPathComponent()
        for name in ["shared", "cache", "raw", IFDictionaryPreparedReceipt.filename] {
            let file = source.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.copyItem(at: file, to: candidate.appendingPathComponent(name)) }
        }
        return .init(outcome: .prepared, manifest: template.manifest)
    }

    @MainActor static func backend(_ root: URL, runtime: IFDictionaryRuntime) throws -> IFDictionaryBackend {
        let store = try IFDictionaryStore(root: root.appendingPathComponent("Dictionaries"))
        let worker = IFDictionaryWorkerRunner(runtime: runtime, protectedUserRoot: root, candidatesRoot: store.root.appendingPathComponent("candidates"))
        return .init(store: store, runtime: runtime, user: root, services: .init(client: .init(), worker: worker))
    }

    @MainActor static func missingFingerprintRetry(root: URL, runtime: IFDictionaryRuntime) async throws {
        let app = root.appendingPathComponent("MissingHelper.app")
        try FileManager.default.copyItem(at: runtime.helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(), to: app)
        let isolatedRuntime = IFDictionaryRuntime.bundled(helper: app.appendingPathComponent("Contents/MacOS/InkFlowDictionaryWorker"))
        let held = isolatedRuntime.helper.appendingPathExtension("held")
        try FileManager.default.moveItem(at: isolatedRuntime.helper, to: held)
        let base = try backend(root.appendingPathComponent("missing-fingerprint-user"), runtime: isolatedRuntime)
        var services = base.services
        services.check = { _ in .init(sources: [], hasUpdate: false) }
        let service = IFDictionaryCoordinator(backend: .init(store: base.store, runtime: isolatedRuntime, user: base.user, services: services),
            now: { Date(timeIntervalSince1970: 1500) })
        service.presentationOpened(); service.bootstrap()
        check(service.engineAvailable && !service.canCheck && service.canRetry && service.failure != nil,
              "Missing helper fingerprint disables updates while bundled input remains available")
        let engine = IFEngine()!; type(engine, "nihao")
        let composition = engine.snapshot(), original = service.active!
        try FileManager.default.moveItem(at: held, to: isolatedRuntime.helper)
        service.retry(); await until("Missing fingerprint recovered") { !service.isBusy }
        check(service.engineAvailable && service.canCheck && !service.canRetry && service.failure == nil,
              "Restored helper fingerprint re-enables updates after background retry")
        check(engine.snapshot() == composition && service.active?.manifest.contentVersion == original.manifest.contentVersion &&
              service.active?.activatedAt == original.activatedAt, "Fingerprint recovery preserves composing engine and confirmed metadata")
        service.checkForUpdates(); await until("Check enabled after fingerprint retry") { !service.isBusy }
        check(service.activity == .upToDate && engine.snapshot() == composition, "Recovered checking works without replacing active composition")
        engine.clear(); IFEngine.stop()
        print("PASS missing fingerprint: absent bundled helper -> usable input/disabled updates, restored helper -> background retry/check with composition/date preserved")
    }

    @MainActor static func coordinatorLifecycle(root: URL, runtime: IFDictionaryRuntime, template: IFDictionaryDescriptor) async throws {
        let base = try backend(root.appendingPathComponent("coordinator"), runtime: runtime)
        let calls = TestBox((check: 0, download: 0, prepare: 0))
        let failCheck = TestBox(false)
        let gate = TestGate()
        let preparationGate = TestGate()
        let log = TestBox<[IFDictionaryUpdateError]>([])
        var services = base.services
        services.check = { _ in
            calls.update { $0.check += 1 }; await gate.wait()
            if failCheck.value { throw IFDictionaryUpdateError(.check, "offline", httpStatus: 429) }
            return .init(sources: [], hasUpdate: true)
        }
        services.download = { _, progress in
            calls.update { $0.download += 1 }; progress(.init(stage: .download, completed: 1, total: 1)); return []
        }
        let lateProgress = TestBox<IFDictionaryServices.Progress?>(nil)
        services.prepare = { candidate, _, _, progress in
            calls.update { $0.prepare += 1 }; lateProgress.value = progress
            await preparationGate.wait()
            return try await Task.detached { try copyTemplate(template, to: candidate) }.value
        }
        let service = IFDictionaryCoordinator(backend: .init(store: base.store, runtime: runtime, user: base.user, services: services),
            now: { Date(timeIntervalSince1970: 500) }, logger: { value in log.update { $0.append(value) } })
        service.bootstrap()
        check(service.engineAvailable && service.active?.isBundled == true && service.active?.activatedAt == Date(timeIntervalSince1970: 500))
        let bundledVersion = service.active!.manifest.contentVersion
        service.presentationOpened(); service.checkForUpdates(); service.checkForUpdates()
        await until("Check started") { calls.value.check == 1 }
        service.presentationClosed(); service.presentationOpened()
        check(service.isBusy && service.activity == .checking && service.failure == nil, "Progress survives Settings close/reopen")
        await gate.open(); await until("Check complete") { !service.isBusy }
        check(service.activity == .updateAvailable && calls.value.download == 0, "Check never implicitly downloads")
        let hidden = IFEngine()!; type(hidden, "nihao")
        service.downloadAndUpdate(); service.downloadAndUpdate()
        await until("Background preparation active") { calls.value.prepare == 1 }
        let composing = hidden.snapshot()
        hidden.key(0xff08); hidden.key(111)
        check(service.isBusy && hidden.snapshot().preedit == composing.preedit, "Old native engine keeps editing during worker preparation")
        await preparationGate.open()
        await until("Prepared update waiting for hidden session") { service.activity == .waitingForIdle }
        check(calls.value.download == 1 && calls.value.prepare == 1, "Single-flight double clicks")
        check(try! base.store.state().pending != nil, "Intent journal persisted before publishing waiting")
        check(service.active?.manifest.contentVersion == bundledVersion && !hidden.snapshot().preedit.isEmpty, "Old engine serves during preparation and waiting")
        lateProgress.value?(.init(stage: .prepare, completed: 0, total: 1))
        await Task.yield(); check(service.activity == .waitingForIdle, "Late progress cannot replace waiting state")
        hidden.commit(); check(!IFEngine.allSessionsIdle)
        await Task.yield(); check(service.activity == .waitingForIdle, "Native/buffered commit remains a blocker")
        check(hidden.takeCommit() == "你好")
        await until("Activation completed") { !service.isBusy }
        check(service.activity == .updated && service.active?.manifest.contentVersion == template.manifest.contentVersion)
        check(service.active?.activatedAt == Date(timeIntervalSince1970: 500) && hidden.available)
        check(try! base.store.state().current?.contentVersion == service.active?.manifest.contentVersion)
        lateProgress.value?(.init(stage: .verify, completed: 0, total: 1))
        await Task.yield(); check(service.activity == .updated, "Late progress cannot replace successful terminal outcome")
        failCheck.value = true
        service.checkForUpdates(); await until("Visible failure") { !service.isBusy }
        check(service.failure?.code == "offline" && service.canRetry && log.value.count == 1, "One coordinator diagnostic log")
        service.presentationClosed(); service.presentationOpened(); check(service.failure == nil, "Reopen clears prior error")
        service.presentationClosed(); service.checkForUpdates(); await until("Closed failure") { !service.isBusy }
        service.presentationOpened(); check(service.failure == nil && log.value.count == 2, "Closed failures log without replay")
        failCheck.value = false; service.retry(); await until("Retry check") { !service.isBusy }
        check(service.activity == .updateAvailable && calls.value.download == 1, "Retry repeats check without download")
        IFEngine.stop()

        // Proven content-equivalent source receipts keep both active content and activation date unchanged.
        var unchangedServices = services
        unchangedServices.prepare = { _, _, _, progress in
            lateProgress.value = progress
            return .init(outcome: .contentUnchanged, manifest: template.manifest)
        }
        let unchanged = IFDictionaryCoordinator(backend: .init(store: base.store, runtime: runtime, user: base.user, services: unchangedServices),
            now: { Date(timeIntervalSince1970: 900) })
        unchanged.bootstrap(); unchanged.checkForUpdates(); await until("Unchanged check") { !unchanged.isBusy }
        unchanged.downloadAndUpdate(); await until("Unchanged done") { !unchanged.isBusy }
        lateProgress.value?(.init(stage: .prepare, completed: 0, total: 1)); await Task.yield()
        check(unchanged.activity == .upToDate && unchanged.active?.activatedAt == Date(timeIntervalSince1970: 500))
        check(try! base.store.state().pending == nil, "Same-content observation never starts activation")
        IFEngine.stop()
        print("PASS coordinator: explicit check/download, single-flight, pending-before-idle, background preparation, actual active metadata/date, same-content, close/progress/error/log/retry and delayed progress")
    }

    @MainActor static func transactionFailures(root: URL, runtime: IFDictionaryRuntime, template: IFDictionaryDescriptor) async throws {
        let base = try backend(root.appendingPathComponent("transaction-failures"), runtime: runtime)
        let failConfirm = TestBox(true)
        let failAbandon = TestBox(false)
        let confirmationWrites = TestBox(0)
        let store = try IFDictionaryStore(root: base.store.root, beforeStateWrite: { state in
            if state.current?.contentVersion == template.manifest.contentVersion && state.pending == nil {
                confirmationWrites.update { $0 += 1 }
                if failConfirm.value || (failAbandon.value && confirmationWrites.value > 1) {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
        })
        var services = base.services
        let hasUpdate = TestBox(false)
        services.check = { _ in .init(sources: [], hasUpdate: hasUpdate.value) }
        services.download = { _, _ in [] }
        services.prepare = { candidate, _, _, _ in try await Task.detached { try copyTemplate(template, to: candidate) }.value }
        let service = IFDictionaryCoordinator(backend: .init(store: store, runtime: runtime, user: base.user, services: services),
            now: { Date(timeIntervalSince1970: 1000) })
        service.bootstrap(); service.presentationOpened()
        let original = service.active!
        service.checkForUpdates(); await until("No-update check") { !service.isBusy }
        check(service.activity == .upToDate && !service.canUpdate, "No-change check provides no download action")
        hasUpdate.value = true; service.checkForUpdates(); await until("Fault check") { !service.isBusy }
        let engine = IFEngine()!
        service.downloadAndUpdate(); await until("Confirmation failure rollback") { !service.isBusy }
        check(service.engineAvailable && engine.available && service.active?.manifest.contentVersion == original.manifest.contentVersion)
        check(service.active?.activatedAt == original.activatedAt && service.failure?.stage == .apply)
        check(try! store.state().current == nil && store.state().pending == nil && store.state().bundled?.activatedAt == original.activatedAt,
              "Precommit persistence failure preserves original metadata and clears pending after rollback")
        failConfirm.value = false; failAbandon.value = true; confirmationWrites.value = 0
        service.retry(); await until("Postconfirm housekeeping failure") { !service.isBusy }
        check(service.engineAvailable && service.active?.manifest.contentVersion == template.manifest.contentVersion && service.canRetry)
        let confirmed = service.active!
        type(engine, "nihao")
        let composition = engine.snapshot()
        failAbandon.value = false
        service.retry(); await until("Live housekeeping retry") { !service.isBusy }
        check(engine.snapshot() == composition && service.active?.manifest.contentVersion == confirmed.manifest.contentVersion,
              "Housekeeping retry cannot stop/rebootstrap a composing engine or change active metadata")
        service.bootstrap()
        check(engine.snapshot() == composition, "Bootstrap refuses a running native engine")
        engine.clear()
        IFEngine.stop()
        print("PASS transaction: no-update, confirmation write rollback/date, compact housekeeping failure and safe composing retry")
    }

    @MainActor static func installTemplate(_ template: IFDictionaryDescriptor, store: IFDictionaryStore, date: TimeInterval) throws -> IFDictionaryVersion {
        let candidate = try store.candidate()
        _ = try copyTemplate(template, to: candidate)
        let version = try store.adopt(candidate, fingerprint: template.version!.runtimeFingerprint)
        try store.beginActivation(version); try store.confirmActivation(version, now: Date(timeIntervalSince1970: date))
        return try store.state().current!
    }

    @MainActor static func domainCatalogUpgrade(root: URL, runtime: IFDictionaryRuntime, repository: URL) async throws {
        let base = try backend(root.appendingPathComponent("domain-catalog-upgrade"), runtime: runtime)
        let oldCatalog = IFDictionaryCatalog.sources.filter { $0.group != "specialty" }
        let oldInputs = try oldCatalog.map { spec in
            IFDictionaryInput(receipt: spec.pinnedReceipt, data: try Data(contentsOf: spec.isUpdatable
                ? repository.appendingPathComponent("build/dictionary-sources/\(spec.id).yaml")
                : runtime.resources.appendingPathComponent(IFDictionaryCatalog.legacyFilename)))
        }
        let generated = try IFDictionaryGenerator.generate(inputs: oldInputs, catalog: oldCatalog)
        let canonical = String(decoding: generated.dictionary, as: UTF8.self).components(separatedBy: "\n...\n")[1]
        let oldContentVersion = "r1-" + IFDictionaryHash.sha256(Data("recipe:1\n\(canonical)".utf8))
        let oldDictionary = Data(("""
        # Generated by InkFlow from Rime Frost, Rime Ice and pinned pinyin_simp.
        # Entries are merged and supplemental weights calibrated; see bundled Licenses.
        ---
        name: pinyin_simp
        version: '\(oldContentVersion)'
        sort: by_weight
        use_preset_vocabulary: false
        ...

        """ + canonical).utf8)
        let oldManifest = IFDictionaryManifest(formatVersion: 1, recipeVersion: 1, contentVersion: oldContentVersion,
            entryCount: generated.manifest.entryCount, contentSHA256: generated.manifest.contentSHA256,
            dictionarySHA256: IFDictionaryHash.sha256(oldDictionary), correctionsSHA256: IFDictionaryHash.sha256(Data()),
            sources: generated.manifest.sources, calibrations: generated.manifest.calibrations)
        check(oldManifest.entryCount == 963_978 && oldManifest.sources.count == 7, "Actual recipe-1 catalog fixture")
        let oldVersion = IFDictionaryVersion(contentVersion: oldContentVersion, runtimeFingerprint: String(repeating: "0", count: 64),
            preparedAt: Date(timeIntervalSince1970: 100), activatedAt: Date(timeIntervalSince1970: 200))
        let artifact = base.store.root.appendingPathComponent(oldVersion.directory)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        let shared = artifact.appendingPathComponent("shared")
        try FileManager.default.copyItem(at: runtime.resources, to: shared)
        try oldDictionary.write(to: shared.appendingPathComponent(IFDictionaryCatalog.dictionaryFilename))
        try oldManifest.encoded().write(to: shared.appendingPathComponent(IFDictionaryManifest.filename))
        try Data().write(to: shared.appendingPathComponent(IFDictionaryCatalog.correctionsFilename))

        // Create real Chinese learning under the old complete dictionary, before the app upgrade.
        try IFEngine.start(shared: shared.path, user: base.user.path)
        do {
            let engine = IFEngine()!
            type(engine, "beijing")
            check(engine.snapshot().candidates.first == "背景", "Clean old dictionary starts with 背景 before learning 北京")
            engine.clear()
            for _ in 0..<3 {
                type(engine, "beijing")
                var selected = false
                for _ in 0..<20 {
                    let snapshot = engine.snapshot()
                    if let index = snapshot.candidates.firstIndex(of: "北京") {
                        engine.select(index); check(engine.takeCommit() == "北京"); selected = true; break
                    }
                    engine.key(0xff56)
                    if engine.snapshot().page == snapshot.page { break }
                }
                check(selected, "Learn a nondefault Chinese choice before upgrade")
            }
        }
        IFEngine.stop()
        let userdb = base.user.appendingPathComponent("pinyin_simp.userdb")
        check(FileManager.default.fileExists(atPath: userdb.path))
        let userdbIdentity = try FileManager.default.attributesOfItem(atPath: userdb.path)[.systemFileNumber] as! NSNumber
        try FileManager.default.copyItem(at: base.user.appendingPathComponent("build"), to: artifact.appendingPathComponent("cache"))
        let prepared = IFDictionaryPreparedReceipt(contentVersion: oldContentVersion, runtimeFingerprint: oldVersion.runtimeFingerprint,
            files: try IFDictionaryFiles.hashes(in: artifact))
        try IFDictionaryFiles.encode(prepared).write(to: artifact.appendingPathComponent(IFDictionaryPreparedReceipt.filename))
        try IFDictionaryFiles.encode(IFDictionaryState(current: oldVersion)).write(to: base.store.root.appendingPathComponent("state.json"))
        let observations = try JSONSerialization.data(withJSONObject: ["contentVersion": oldContentVersion,
            "receipts": JSONSerialization.jsonObject(with: IFDictionaryFiles.encode(oldManifest.sources))])
        let observationURL = base.store.root.appendingPathComponent("observed.json")
        try observations.write(to: observationURL)
        check(try! base.store.state().current == oldVersion, "Historical journal identity remains valid")

        let logs = TestBox<[IFDictionaryUpdateError]>([]), checks = TestBox(0)
        let checkedSources = TestBox<[String]>([])
        var services = base.services
        services.check = { observed in
            checkedSources.value = observed.map(\.id)
            checks.update { $0 += 1 }
            return .init(sources: [], hasUpdate: false)
        }
        let service = IFDictionaryCoordinator(backend: .init(store: base.store, runtime: runtime, user: base.user, services: services),
            logger: { failure in logs.update { $0.append(failure) } })
        service.bootstrap()
        check(service.engineAvailable && service.active?.isBundled == true && service.canCheck, "Old downloaded catalog activates current bundled dictionary")
        check(service.failure == nil, "Successful startup upgrade has no user-facing recovery failure")
        check(service.active?.manifest.recipeVersion == IFDictionaryCatalog.recipeVersion)
        check(try! base.store.state().current == nil && base.store.state().bundled?.contentVersion == service.active?.manifest.contentVersion)
        check(!FileManager.default.fileExists(atPath: artifact.path), "Successful bundled upgrade removes the now-unreferenced historical compiled artifact")
        check(!logs.value.contains { $0.code == "invalid-version" || $0.code == "invalid-state" }, "Expected old catalog is not malformed state")
        check(try! Data(contentsOf: observationURL) == observations, "Old observations remain on disk and are ignored by content version")
        check(try! FileManager.default.attributesOfItem(atPath: userdb.path)[.systemFileNumber] as? NSNumber == userdbIdentity,
              "Upgrade preserves original learning database directory")
        let engine = IFEngine()!
        type(engine, "beijing"); check(engine.snapshot().candidates.first == "北京", "Real learned candidate survives catalog/recipe upgrade")
        engine.clear()
        type(engine, "jiansuozengqiangshengcheng")
        check(engine.snapshot().candidates.contains("检索增强生成"), "New bundled specialty vocabulary is active")
        engine.clear()
        service.checkForUpdates(); await until("Checking after catalog upgrade") { !service.isBusy }
        check(checks.value == 1 && service.activity == .upToDate)
        check(checkedSources.value == IFDictionaryCatalog.sources.map(\.id), "Update check uses expanded active catalog")
        check(try! Data(contentsOf: observationURL) == observations, "Continued update checking does not delete old observations")
        IFEngine.stop()
        print("PASS domain upgrade: actual old 7-source r1 downloaded artifact -> new bundled catalog, obsolete artifact removed, same real userdb/learned choice, stale observation retained/ignored, continued update check")
    }

    @MainActor static func recovery(root: URL, runtime: IFDictionaryRuntime, template: IFDictionaryDescriptor) async throws {
        let base = try backend(root.appendingPathComponent("recovery"), runtime: runtime)
        let confirmed = try installTemplate(template, store: base.store, date: 200)
        let pendingCandidate = try base.store.candidate(); _ = try copyTemplate(template, to: pendingCandidate)
        let pending = try base.store.adopt(pendingCandidate, fingerprint: confirmed.runtimeFingerprint)
        try base.store.beginActivation(pending)
        let loose = try (0..<3).map { _ in try base.store.candidate() }
        let outside = root.appendingPathComponent("cleanup-outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("isolated sentinel".utf8).write(to: outside.appendingPathComponent("sentinel"))
        try FileManager.default.createSymbolicLink(at: base.store.root.appendingPathComponent("candidates/" + UUID().uuidString), withDestinationURL: outside)
        check(try! base.store.cleanup(limit: 2) == 2, "Cleanup is bounded")
        check(loose.filter { FileManager.default.fileExists(atPath: $0.path) }.count == 1)
        check(FileManager.default.fileExists(atPath: outside.appendingPathComponent("sentinel").path), "Cleanup never follows symlinks outside owned artifacts")
        check(FileManager.default.fileExists(atPath: base.store.root.appendingPathComponent(pending.directory).path) &&
              FileManager.default.fileExists(atPath: base.store.root.appendingPathComponent(confirmed.directory).path), "Cleanup retains confirmed and pending artifacts")
        let service = IFDictionaryCoordinator(backend: base, now: { Date(timeIntervalSince1970: 800) })
        service.bootstrap()
        check(service.active?.activatedAt == Date(timeIntervalSince1970: 200) && service.active?.manifest.contentVersion == confirmed.contentVersion)
        check(try! base.store.state().current == confirmed && base.store.state().pending == nil, "Interrupted pending discarded without retry")
        check(!FileManager.default.fileExists(atPath: base.store.root.appendingPathComponent(pending.directory).path), "Unreferenced interrupted artifact removed")
        IFEngine.stop()

        // Fingerprint rebuild must combine retained inert source data with CURRENT assets/corrections.
        let currentApp = root.appendingPathComponent("NewApp.app")
        try FileManager.default.copyItem(at: runtime.helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(), to: currentApp)
        let currentRuntime = IFDictionaryRuntime.bundled(helper: currentApp.appendingPathComponent("Contents/MacOS/InkFlowDictionaryWorker"))
        let lua = currentRuntime.resources.appendingPathComponent("lua/inkflow_mixed.lua")
        var bytes = try Data(contentsOf: lua); bytes.append(Data("\n-- isolated current application marker\n".utf8)); try bytes.write(to: lua)
        let corrections = currentRuntime.resources.appendingPathComponent(IFDictionaryCatalog.correctionsFilename)
        var policy = try Data(contentsOf: corrections); policy.append(Data("\n# isolated current correction policy\n".utf8)); try policy.write(to: corrections)
        let rebuilds = TestBox(0)
        var services = base.services
        services.rebuild = { candidate, inert in
            rebuilds.update { $0 += 1 }
            let runner = IFDictionaryWorkerRunner(runtime: currentRuntime, protectedUserRoot: base.user,
                candidatesRoot: base.store.root.appendingPathComponent("candidates"))
            return try runner.rebuildBlocking(candidate: candidate, dictionaryShared: inert)
        }
        let rebuilt = IFDictionaryCoordinator(backend: .init(store: base.store, runtime: currentRuntime, user: base.user, services: services))
        rebuilt.bootstrap()
        check(rebuilds.value == 1 && rebuilt.engineAvailable && rebuilt.active?.activatedAt == Date(timeIntervalSince1970: 200), "Compatible rebuild preserves content activation date")
        let newVersion = try base.store.state().current!
        check(newVersion.runtimeFingerprint == (try! currentRuntime.fingerprint()) && newVersion.artifactID != confirmed.artifactID)
        let resolved = try base.store.resolve(newVersion, fingerprint: currentRuntime.fingerprint())
        check(try! Data(contentsOf: resolved.sharedData.appendingPathComponent("lua/inkflow_mixed.lua")) == Data(contentsOf: lua), "Current app Lua selected")
        check(resolved.manifest.correctionsSHA256 == IFDictionaryHash.sha256(policy), "Current corrections regenerated from retained inert sources")
        let rebuiltSession = IFEngine()!
        type(rebuiltSession, "moliugengxinceshi")
        check(rebuiltSession.snapshot().candidates.contains("墨流更新测试"), "Downloaded synthetic entry survives current-app rebuild")
        rebuiltSession.clear()
        IFEngine.stop()

        // Corrupt all recoverable dictionaries. Confirmed bundled fallback must not retry previous artifacts next launch.
        for version in [try base.store.state().current, try base.store.state().previous].compactMap({ $0 }) {
            try Data("corrupt".utf8).write(to: base.store.root.appendingPathComponent(version.directory + "/shared/pinyin_simp.dict.yaml"))
        }
        let logs = TestBox<[IFDictionaryUpdateError]>([])
        let fallback = IFDictionaryCoordinator(backend: base, logger: { value in logs.update { $0.append(value) } })
        fallback.bootstrap(); check(fallback.engineAvailable && fallback.active?.isBundled == true && !logs.value.isEmpty)
        IFEngine.stop(); logs.value = []
        let restart = IFDictionaryCoordinator(backend: base, logger: { value in logs.update { $0.append(value) } })
        restart.bootstrap(); check(restart.active?.isBundled == true && logs.value.isEmpty, "Confirmed bundled choice does not replay failed version recovery")
        IFEngine.stop()
        try Data("malformed journal".utf8).write(to: base.store.root.appendingPathComponent("state.json"))
        let repaired = IFDictionaryCoordinator(backend: base)
        repaired.bootstrap(); check(repaired.engineAvailable && repaired.active?.isBundled == true)
        check(try! base.store.state().current == nil && base.store.state().bundled != nil, "Malformed journal repaired after actual bundled success")
        IFEngine.stop()

        // A failed real backend factory remains retryable and never makes default/shared Settings perform I/O.
        let failFactory = TestBox(true)
        let factoryOnMain = TestBox(true)
        let factory = IFDictionaryCoordinator(backendFactory: {
            if failFactory.value { throw CocoaError(.fileWriteNoPermission) }
            factoryOnMain.value = Thread.isMainThread
            return base
        })
        factory.bootstrap(); check(!factory.engineAvailable && factory.canRetry)
        failFactory.value = false; factory.retry(); await until("Factory recovery retry") { factory.engineAvailable && !factory.isBusy }
        check(factory.active?.isBundled == true && !factory.canRetry && !factoryOnMain.value, "Manual factory/index recovery runs in background and clears completed retry")
        let inert = IFDictionaryCoordinator(); inert.bootstrap(); inert.checkForUpdates(); inert.retry()
        check(!inert.engineAvailable && !inert.isBusy && !inert.canRetry && inert.active == nil)
        IFEngine.stop()
        print("PASS recovery: interrupted journal, bounded pruning, current-runtime rebuild/date, corrupt-version bundled fallback without restart replay, malformed repair, backend factory retry and inert defaults")
    }
}
