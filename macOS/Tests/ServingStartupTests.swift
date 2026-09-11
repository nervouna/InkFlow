import AppKit
import InputMethodKit
#if SWIFT_PACKAGE
@testable import InkFlowCore
import InkFlowNativeTestSupport
import InkFlowTestSupport
#endif

private final class StartupGate: @unchecked Sendable {
    private let lock = NSCondition()
    private var entered = false
    private var opened = false
    private var expired = false
    func wait() throws {
        lock.lock(); defer { lock.unlock() }
        entered = true
        let deadline = Date(timeIntervalSinceNow: 8)
        while !opened {
            if !lock.wait(until: deadline) { expired = true; throw IFDictionaryUpdateError(.prepare, "test-gate-timeout") }
        }
    }
    func open() { lock.lock(); opened = true; lock.broadcast(); lock.unlock() }
    var held: Bool { lock.lock(); defer { lock.unlock() }; return entered && !opened && !expired }
}

private final class StartupFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func shouldFail() -> Bool { lock.lock(); defer { lock.unlock() }; calls += 1; return calls == 1 }
}

@main struct ServingStartupTests {
    @MainActor static func until(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        check(predicate(), label)
    }
    @MainActor static func main() {
        _ = NSApplication.shared
        if CommandLine.arguments.contains("--native") { NSApp.setActivationPolicy(.regular) }
        Task { @MainActor in
            do { try await run(); fflush(stdout); exit(0) }
            catch { print("FAIL startup: \(error)"); fflush(stdout); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func run() async throws {
        let native = CommandLine.arguments.contains("--native")
        var host: NSWindow?
        if native {
            let window = NSWindow(contentRect: NSRect(x: 140, y: 240, width: 620, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "墨流启动隔离验证"; window.isReleasedWhenClosed = false
            let field = NSTextView(frame: NSRect(x: 20, y: 20, width: 580, height: 200))
            window.contentView?.addSubview(field)
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); window.makeFirstResponder(field)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while (!window.isKeyWindow || !NSApp.isActive) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            guard window.isKeyWindow && NSApp.isActive else {
                print("BLOCKED native prerequisite: host window cannot acquire focus; visible=\(window.isVisible) key=\(window.isKeyWindow) active=\(NSApp.isActive) pid=\(ProcessInfo.processInfo.processIdentifier) foreground_pid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1); no startup product verdict")
                exit(2)
            }
            host = window
        }
        defer { host?.orderOut(nil) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let app = URL(fileURLWithPath: CommandLine.arguments[2])
        let runtime = IFDictionaryRuntime.bundled(helper: app.appendingPathComponent("Contents/MacOS/InkFlowDictionaryWorker"))
        let packaged = try IFPackagedCache.descriptor(resources: runtime.resources)
        let fingerprint = try runtime.fingerprint()
        let templateUser = root.appendingPathComponent("template")
        let templateStore = try IFDictionaryStore(root: templateUser.appendingPathComponent("Dictionaries"))
        let templateWorker = IFDictionaryWorkerRunner(runtime: runtime, protectedUserRoot: templateUser,
            candidatesRoot: templateStore.root.appendingPathComponent("candidates"))
        let candidate = try templateStore.candidate()
        _ = try await Task.detached { try templateWorker.rebuildBlocking(candidate: candidate, dictionaryShared: runtime.resources) }.value
        let templateVersion = try templateStore.adopt(candidate, fingerprint: fingerprint)
        let templateDirectory = templateStore.root.appendingPathComponent(templateVersion.directory)
        func adoptTemplate(_ store: IFDictionaryStore) throws -> IFDictionaryVersion {
            let copy = try store.candidate()
            for name in try FileManager.default.contentsOfDirectory(atPath: templateDirectory.path) {
                try FileManager.default.copyItem(at: templateDirectory.appendingPathComponent(name), to: copy.appendingPathComponent(name))
            }
            return try store.adopt(copy, fingerprint: fingerprint)
        }

        IFStubHeadlessControllerFramework()
        var retainedServer: IMKServer?
        for mode in native ? ["success"] : ["success", "previous", "failure", "activation-failure", "shutdown"] {
            let user = root.appendingPathComponent(mode)
            let store = try IFDictionaryStore(root: user.appendingPathComponent("Dictionaries"))
            if mode == "previous" {
                let previous = try adoptTemplate(store)
                try store.beginValidatedActivation(previous)
                try store.confirmActivation(previous, now: Date(timeIntervalSince1970: 1000))
            }
            let version = try adoptTemplate(store)
            try store.beginValidatedActivation(version)
            let savedDate = Date(timeIntervalSince1970: 1234)
            try store.confirmActivation(version, now: savedDate)
            let saved = try store.state()
            // Current has valid inert sources but an unusable cache, forcing the actual recovery rebuild path.
            try Data("corrupt fixture".utf8).write(to: store.root.appendingPathComponent(version.directory + "/cache/pinyin_simp.table.bin"))
            let worker = IFDictionaryWorkerRunner(runtime: runtime, protectedUserRoot: user,
                candidatesRoot: store.root.appendingPathComponent("candidates"))
            let gate = StartupGate()
            var services = IFDictionaryServices(client: .init(), worker: worker)
            services.rebuild = { candidate, inert in
                try gate.wait()
                if mode != "success" && mode != "activation-failure" { throw IFDictionaryUpdateError(.prepare, "test-recovery-failure") }
                return try worker.rebuildBlocking(candidate: candidate, dictionaryShared: inert)
            }
            let coordinator = IFDictionaryCoordinator(backend: .init(store: store, runtime: runtime, user: user, services: services))
            var switches = 0
            coordinator.activationFault = { step, rollback in
                if step == .start && !rollback {
                    switches += 1
                    if mode == "activation-failure" { throw IFDictionaryUpdateError(.apply, "test-native-activation-failure") }
                }
            }
            coordinator.bootstrapForServing(runtime: runtime, user: user)
            check(coordinator.engineAvailable && coordinator.active?.isBundled == true, "Shipped fallback serves before downloaded recovery")
            // IMK owns one process server connection. Reuse it across isolated coordinator cases.
            if retainedServer == nil { retainedServer = IMKServer(name: "inkflow.serving.\(UUID())", bundleIdentifier: Bundle.main.bundleIdentifier ?? "inkflow.serving.tests")! }
            let server = retainedServer!
            try await until("Rebuild enters detached gate") { gate.held }
            var tick = false
            DispatchQueue.main.async { tick = true }
            try await until("Main loop remains responsive") { tick }
            let during = try store.state()
            check(during.current == saved.current && during.previous == saved.previous && during.bundled == nil,
                  "Transient fallback does not confirm over saved downloaded journal")
            let defaults = UserDefaults(suiteName: "inkflow.serving.\(UUID())")!
            defaults.setVolatileDomain(["candidateCount": 5, "aiEnabled": false, "aiBaseURL": "", "aiModel": "",
                "customPhrases": Data("[]".utf8)], forName: UserDefaults.argumentDomain)
            let settings = IFSettings(defaults: defaults)
            let client = RecordingClient(document: "")
            let controller = InkFlowInputController(server: server, delegate: nil, client: client,
                settings: settings, settingsWindow: IFSettingsWindowController(settings: settings), secureInput: { false })!
            for letter in "nihao" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
            check(controller.engine!.snapshot().candidates.contains("你好") && gate.held && switches == 0)
            if native {
                controller.panel!.setCandidateData(controller.engine!.snapshot().candidates)
                controller.panel!.setCandidateFrameTopLeft(NSPoint(x: 240, y: 430))
                controller.refresh(client)
                check(controller.panel!.isVisible(), "Native fallback candidate panel is visible in focused host")
            }
            let otherClient = RecordingClient(document: "")
            let other = InkFlowInputController(server: server, delegate: nil, client: otherClient,
                settings: settings, settingsWindow: IFSettingsWindowController(settings: settings), secureInput: { false })!
            for letter in "beijing" { check(other.handle(keyEvent(0, String(letter)), client: otherClient)) }
            check(other.engine!.snapshot().candidates.contains("北京"))
            if mode == "shutdown" {
                let shutdown = Task { try await coordinator.shutdown() }
                try await until("Shutdown begins while rebuild is held") { coordinator.isShuttingDown }
                gate.open(); try await shutdown.value
                check(switches == 0 && coordinator.engineAvailable && !coordinator.isBusy)
            } else {
                gate.open()
                try await until("Recovery preparation resolves") { coordinator.activity == .waitingForIdle || !coordinator.isBusy }
                check(switches == 0, "Recovery never switches an active composition")
                controller.candidateSelected(NSAttributedString(string: "你好"))
                check(client.document == "你好" && client.insertions.count == 1)
                check(switches == 0 && !other.engine!.snapshot().preedit.isEmpty, "Other client composition prevents recovery switch")
                other.candidateSelected(NSAttributedString(string: "北京"))
                check(otherClient.document == "北京" && otherClient.insertions.count == 1 && client.document == "你好", "Client delivery never reroutes during switching")
                try await until("Recovery finishes at native idle boundary") { !coordinator.isBusy }
                if mode == "success" || mode == "previous" {
                    let expectedDate = mode == "previous" ? Date(timeIntervalSince1970: 1000) : savedDate
                    check(switches == 1 && coordinator.active?.isBundled == false && coordinator.active?.activatedAt == expectedDate)
                } else {
                    let failed = try store.state()
                    check(switches == (mode == "activation-failure" ? 1 : 0) && coordinator.engineAvailable && coordinator.canRetry && coordinator.active?.isBundled == true)
                    check(failed.current == saved.current && failed.previous == saved.previous && failed.bundled == nil)
                }
                try await coordinator.shutdown()
            }
            controller.engine?.clear()
            other.engine?.clear()
            IFEngine.stop()
            print("PASS serving startup \(mode): gate/main heartbeat/Chinese composition/journal/idle switch or failure/shutdown")
            fflush(stdout)
        }
        check(packaged.cache != nil)
        if !native { try await packagedReadOnly(root: root, runtime: runtime) }
        if native { print("PASS native serving startup: focused host/real candidate panel/two isolated clients/exact delivery/idle recovery; IMK client lookup shim retained") }
        print("PASS serving startup: actual coordinator path; native controller/RecordingClient shim, not external-app routing")
    }

    @MainActor static func packagedReadOnly(root: URL, runtime: IFDictionaryRuntime) async throws {
        let fm = FileManager.default
        let resources = root.appendingPathComponent("readonly/Rime")
        let cache = resources.deletingLastPathComponent().appendingPathComponent(IFPackagedCache.directory)
        try fm.createDirectory(at: resources.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: runtime.resources, to: resources)
        try fm.copyItem(at: runtime.resources.deletingLastPathComponent().appendingPathComponent(IFPackagedCache.directory), to: cache)
        let descriptor = try IFPackagedCache.descriptor(resources: resources)
        let before = try IFDictionaryFiles.hashes(in: cache)
        let entries = [cache] + (fm.enumerator(at: cache, includingPropertiesForKeys: nil)!.allObjects as! [URL])
        defer { for entry in entries { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: entry.path) } }
        for entry in entries {
            let directory = try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            try fm.setAttributes([.posixPermissions: directory ? 0o555 : 0o444], ofItemAtPath: entry.path)
        }
        var denied = false
        do { try Data("fixture".utf8).write(to: cache.appendingPathComponent("denied-write"), options: .withoutOverwriting) }
        catch { denied = true }
        check(denied, "Shipped cache rejects an actual write")
        let user = root.appendingPathComponent("readonly-user")
        let ranker = try IFContextRanker(dictionary: resources.appendingPathComponent(IFDictionaryCatalog.dictionaryFilename).path)
        let configuration = IFEngineConfiguration(shared: resources, cache: descriptor.cache, user: user.path, ranker: ranker)
        let phrase = CustomPhrase(id: UUID(), code: "zz", text: "只读短语")
        for reopen in 0...1 {
            try IFEngine.start(configuration)
            let engine = IFEngine()!
            for mask in 0..<32 {
                var input = InputPreferences()
                for (bit, option) in [InputOption.abbreviation, .typoTolerance, .fuzzyZ, .fuzzyC, .fuzzyS].enumerated() {
                    input = input.setting(option, to: (mask & (1 << bit)) != 0)
                }
                engine.setConfiguration(candidateCount: 9, customPhrases: [phrase], inputPreferences: input)
                type(engine, "nihao")
                check(engine.configurationError == nil && engine.snapshot().candidates.contains("你好"), "Prepared spelling profile \(mask)")
                engine.clear()
                type(engine, "zz")
                check(engine.snapshot().candidates.first == phrase.text)
                engine.clear()
            }
            type(engine, "beijing")
            let selected = engine.snapshot().candidates.firstIndex(of: "北京")!
            engine.select(selected); check(engine.takeCommit() == "北京")
            IFEngine.stop()
            check(fm.fileExists(atPath: user.appendingPathComponent("pinyin_simp.userdb").path))
            let after = try IFDictionaryFiles.hashes(in: cache)
            check(before == after, "All cache hashes unchanged after profiles/phrases/reopen \(reopen)")
        }
        let isolatedRuntime = IFDictionaryRuntime(resources: resources, helper: runtime.helper, libraries: runtime.libraries)
        let factory = StartupFactory()
        let retryUser = root.appendingPathComponent("factory-retry")
        let coordinator = IFDictionaryCoordinator(backendFactory: {
            if factory.shouldFail() { throw IFDictionaryUpdateError(.recovery, "fixture-factory-failure") }
            let store = try IFDictionaryStore(root: retryUser.appendingPathComponent("Dictionaries"))
            let worker = IFDictionaryWorkerRunner(runtime: isolatedRuntime, protectedUserRoot: retryUser,
                candidatesRoot: store.root.appendingPathComponent("candidates"))
            return .init(store: store, runtime: isolatedRuntime, user: retryUser, services: .init(client: .init(), worker: worker))
        })
        coordinator.bootstrapForServing(runtime: isolatedRuntime, user: retryUser)
        try await until("Factory failure returns with fallback live") { !coordinator.isBusy }
        check(coordinator.engineAvailable && coordinator.canRetry)
        coordinator.retry()
        try await until("Serving recovery retries factory rather than cleanup") { !coordinator.isBusy }
        check(coordinator.canCheck && !coordinator.canRetry && coordinator.engineAvailable)
        try await coordinator.shutdown(); IFEngine.stop()

        let malformedStore = try IFDictionaryStore(root: user.appendingPathComponent("Dictionaries"))
        try Data("malformed journal fixture".utf8).write(to: malformedStore.root.appendingPathComponent("state.json"))
        let malformedWorker = IFDictionaryWorkerRunner(runtime: isolatedRuntime, protectedUserRoot: user,
            candidatesRoot: malformedStore.root.appendingPathComponent("candidates"))
        let malformed = IFDictionaryCoordinator(backend: .init(store: malformedStore, runtime: isolatedRuntime, user: user,
            services: .init(client: .init(), worker: malformedWorker)))
        malformed.bootstrapForServing(runtime: isolatedRuntime, user: user)
        try await until("Malformed journal repaired after fallback starts") { !malformed.isBusy }
        let repaired = try malformedStore.state()
        check(repaired.bundled != nil && malformed.canCheck && !malformed.canRetry && malformed.engineAvailable)
        check(fm.fileExists(atPath: user.appendingPathComponent("pinyin_simp.userdb").path), "Journal repair preserves existing real userdb")
        try await malformed.shutdown(); IFEngine.stop()

        for entry in entries { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: entry.path) }
        // A self-consistent receipt cannot excuse a manifest whose dictionary digest is false.
        let manifestURL = resources.appendingPathComponent(IFDictionaryManifest.filename)
        let receiptURL = cache.appendingPathComponent(IFPackagedCache.filename)
        let manifestBytes = try Data(contentsOf: manifestURL), receiptBytes = try Data(contentsOf: receiptURL)
        var forged = try JSONSerialization.jsonObject(with: manifestBytes) as! [String: Any]
        forged["dictionarySHA256"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: forged, options: .sortedKeys).write(to: manifestURL)
        let receipt = try JSONDecoder().decode(IFPackagedCache.self, from: receiptBytes)
        let forgedReceipt = IFPackagedCache(formatVersion: receipt.formatVersion, contentVersion: receipt.contentVersion,
            resources: try IFDictionaryFiles.hashes(in: resources), compiled: receipt.compiled)
        try IFDictionaryFiles.encode(forgedReceipt).write(to: receiptURL)
        var rejected = false
        do { _ = try IFPackagedCache.descriptor(resources: resources) }
        catch let error as IFDictionaryUpdateError { rejected = error.code == "packaged-cache-integrity" }
        try manifestBytes.write(to: manifestURL); try receiptBytes.write(to: receiptURL)
        check(rejected, "Packaged cache retains dictionary-to-manifest integrity validation")
        let missing = cache.deletingLastPathComponent().appendingPathComponent("missing-cache")
        try fm.moveItem(at: cache, to: missing)
        defer { try? fm.moveItem(at: missing, to: cache) }
        let missingUser = root.appendingPathComponent("missing-user")
        let absent = IFDictionaryCoordinator(backendFactory: { throw IFDictionaryUpdateError(.recovery, "unused-factory") })
        absent.bootstrapForServing(runtime: isolatedRuntime, user: missingUser)
        check(!IFEngine.ready && !absent.engineAvailable && absent.canRetry)
        check(!fm.fileExists(atPath: missingUser.appendingPathComponent("build").path), "Missing packaged cache never triggers synchronous maintenance")
        // Engine loss may overwrite the retry reason after startup. Production must still
        // retry the packaged serving path, never the legacy maintenance-capable bootstrap.
        absent.recordUnavailable(IFDictionaryUpdateError(.recovery, "fixture-engine-loss"))
        absent.retry()
        check(!absent.isBusy && !IFEngine.ready && absent.canRetry,
            "Unavailable production retry stays on packaged startup instead of legacy recovery")
        check(!fm.fileExists(atPath: missingUser.appendingPathComponent("build").path))
        print("PASS packaged readonly: write denied, 32 spelling profiles/custom phrases/fresh user/reopen/userdb/cache hashes; backend retry; malformed journal repair; manifest digest rejection; missing cache explicitly unavailable")
    }
}
