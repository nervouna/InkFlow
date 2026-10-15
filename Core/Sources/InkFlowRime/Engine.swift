import InkFlowDomain
import InkFlowPortable
import Foundation

package struct EngineSnapshot: Equatable {
    package var preedit = ""
    package var cursor = 0
    package var candidates: [String] = []
    package var page = 0
    package var highlight = 0
    package var hasSelectedPrefix = false
    package init(preedit: String = "",
        cursor: Int = 0,
        candidates: [String] = [],
        page: Int = 0,
        highlight: Int = 0,
        hasSelectedPrefix: Bool = false) {
        self.preedit = preedit
        self.cursor = cursor
        self.candidates = candidates
        self.page = page
        self.highlight = highlight
        self.hasSelectedPrefix = hasSelectedPrefix
    }

}

/// The Swift face of the Rust core (`Core/Portable`, reached through its C ABI). Sessions, keys,
/// candidate order, selection, paging, commits, custom phrases and input preferences live in the
/// core; this class keeps what is the frontend's: the delivery lease and idle signalling, the
/// voice-lexicon gating, the quality recording around each mutation and the Settings-facing
/// errors. The core and its Rime are process-global and accessed on the main actor.
@MainActor
package final class IFEngine {
    package static let voiceLexicon = VoiceLexiconStore()
    package private(set) static var ready = false
    private static var generation: UInt64 = 0
    private final class WeakSession {
        weak var value: IFEngine?
        init(_ value: IFEngine) { self.value = value }
    }
    private static var instances: [ObjectIdentifier: WeakSession] = [:]
    private static var idleScheduled = false
    package static var idleHandler: (@MainActor () -> Void)?
    private var sessionGeneration: UInt64 = 0
    private var deliveryDepth = 0
    private var savedASCII = false

    package static var liveSessions: [IFEngine] { instances.values.compactMap(\.value) }
    package static var personalDataSuspended = false
    /// Created and still attached to the running core, whether or not the core has lost its Rime session.
    private var attached: Bool {
        Self.ready && !Self.personalDataSuspended && session != nil && sessionGeneration == Self.generation
    }
    package var available: Bool {
        guard attached, let session else { return false }
        return ifr_session_available(session) != 0
    }
    package var asciiMode: Bool {
        get {
            guard available, let session else { return savedASCII }
            var value: Int32 = 0
            return ifr_session_ascii_mode(session, &value) == ifrOK ? value != 0 : savedASCII
        }
        set {
            savedASCII = newValue
            guard available, let session else { return }
            _ = ifr_session_set_ascii_mode(session, newValue ? 1 : 0)
            refreshApplied()
        }
    }
    package var requestedASCIIMode: Bool {
        guard available, let session else { return savedASCII }
        return ifr_session_requested_ascii_mode(session) != 0
    }
    @discardableResult
    package func toggleASCIIMode(capturedAt: TimeInterval? = nil) -> Bool {
        guard available else { return false }
        defer { Self.signalIdle() }
        return qualityOperation(.toggle(false), capturedAt: capturedAt) {
            var handled: Int32 = 0
            guard ifr_session_toggle_ascii_mode(session, &handled) == ifrOK else { return false }
            savedASCII = requestedASCIIMode
            refreshApplied()
            return handled != 0
        }
    }
    /// Keep the lease until every native client callback returns, including nested run loops.
    package func beginDelivery() { deliveryDepth += 1 }
    package func endDelivery() { deliveryDepth = max(0, deliveryDepth - 1); Self.signalIdle() }
    package static var allSessionsIdle: Bool { sessionsIdle(includingDelivery: true) }

    /// Drains completed text into each session's buffer, so an undelivered commit counts as busy.
    private static func sessionsIdle(includingDelivery: Bool) -> Bool {
        liveSessions.allSatisfy { engine in
            guard !includingDelivery || engine.deliveryDepth == 0 else { return false }
            engine.bufferedCommit += engine.readCommit()
            return !engine.isComposing && engine.bufferedCommit.isEmpty
        }
    }
    package static func signalIdle() {
        guard !idleScheduled else { return }
        idleScheduled = true
        Task { @MainActor in
            idleScheduled = false
            idleHandler?()
            voiceLexicon.prepareIfNeeded()
        }
    }
    private(set) static var native: OpaquePointer?
    package static var compiledDirectory = URL(fileURLWithPath: "/")
    package static var contextRankingReady: Bool { native.map { ifr_engine_context_ranking_ready($0) != 0 } ?? false }
    private static var productionQualityStore: QualityStore?
    private final class WeakQualityRecorder {
        weak var value: QualityRecorder?
        init(_ value: QualityRecorder) { self.value = value }
    }
    private static var qualityRecorders: [WeakQualityRecorder] = []
    private(set) var session: OpaquePointer?
    package var candidateCount: Int { available ? Int(ifr_session_candidate_count(session)) : 5 }
    private var requestedCount = 5
    package var requestedInput = InputPreferences()
    /// The preferences the session applied at its last composition boundary.
    package var inputPreferences: InputPreferences? {
        var mask: UInt32 = 0
        guard available, ifr_session_input_options(session, &mask) != 0 else { return nil }
        return InputPreferences(optionMask: mask)
    }
    private var bufferedCommit = ""
    /// Custom phrases are requested for every session and outlive engine restarts, like each session's
    /// requested count; the core writes Rime's custom_phrase.txt and reloads it at the next shared idle.
    private static var requestedPhrases: [CustomPhrase] = []
    /// The phrases Rime has loaded, which quality records. The core applies a change at the first
    /// idle boundary after the request; this follows the same condition.
    private static var loadedPhrases: [CustomPhrase] = []
    package private(set) var configurationError: String?
    private var configurationCode: String?
    // Quality records the preceding context this session last received and clears it when the
    // composition's content ends, as the core's ranking does.
    private var precedingText = ""
    private var orderedContent = EngineSnapshot()
    package let qualityRecorder: QualityRecorder?
    package private(set) var qualityRevision = QualityConfigRevision(configuration: QualityAppliedConfiguration(candidateCount: 5))
    private var qualityDepth = 0
    private var qualityEventTime: TimeInterval?
    private var qualityFontSize = 14
    private var qualityVertical = false

    package static var version: String { ifrString(ifr_rime_version()) }

    /// The process owns recording across native dictionary replacement and recovery.
    package static func configureQualityRecording(_ store: QualityStore?) { productionQualityStore = store }

    /// Standalone startup retains the existing explicit quality-store injection.
    package static func start(shared: String, user: String, qualityStore: QualityStore? = nil) throws {
        if ready { return }
        let sharedURL = URL(fileURLWithPath: shared)
        let configuration = IFEngineConfiguration(shared: sharedURL, cache: nil, user: user,
            contextIndex: sharedURL.appendingPathComponent(IFDictionaryCatalog.contextIndexFilename))
        do { try start(configuration); productionQualityStore = qualityStore }
        catch let error as IFDictionaryUpdateError where error.code == "missing-runtime-resource" {
            // Preserve the established standalone API's missing-resource error contract.
            throw NSError(domain: "io.damao.inputmethod.inkflow", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "InkFlow 缺少内置词典资源，请重新构建并安装。"])
        }
        NotificationCenter.default.post(name: .engineAvailabilityDidChange, object: nil)
    }

    package static func start(_ configuration: IFEngineConfiguration,
                      fault: (IFEngineSwitchStep) throws -> Void = { _ in }) throws {
        guard !ready else { return }
        let startup = IFStartupDiagnostics.shared
        let source: IFStartupDiagnostics.Source = configuration.cache == nil ? .bundled : .prepared
        let engineSpan = startup.begin(.engine, source: source)
        var started = false
        defer { startup.end(engineSpan, started ? .ready : .failed) }
        try fault(.start)
        let shared = configuration.shared.path
        for name in ["default.yaml", "inkflow_pinyin.schema.yaml", "pinyin_simp.dict.yaml",
                     "easy_en.schema.yaml", "easy_en.dict.yaml", "inkflow_mixed.schema.yaml", "inkflow_mixed.dict.yaml",
                     "lua/inkflow_english.lua", "lua/inkflow_mixed.lua", "lua/inkflow_short_conflict.lua",
                     "lua/inkflow_ai_learning.lua", "lua/inkflow_input_coverage.lua", "lua/inkflow_channel.lua",
                     "opencc/inkflow_emoji.json", "opencc/emoji.txt",
                     "opencc/inkflow_s2t.json", "opencc/STPhrases.txt", "opencc/STCharacters.txt"] +
                    (0..<32).map({ InputPreferences.spellingProfile($0) + ".schema.yaml" }) {
            guard FileManager.default.isReadableFile(atPath: configuration.shared.appendingPathComponent(name).path) else {
                throw IFDictionaryUpdateError(.apply, "missing-runtime-resource", file: name)
            }
        }
        let user = configuration.user
        // Rime initialization (compiling into user/build without a prepared cache), the phrase file and
        // the context index are all part of creating the core's engine. A prepared cache is never deployed here.
        let initialization = startup.begin(.initialization, source: source)
        var created: OpaquePointer?
        let status = withCStrings([shared, user, configuration.cache?.path, configuration.contextIndex?.path]
            .map { $0 ?? "" }) { strings in
            var config = IFREngineConfig(shared: strings[0], user: strings[1],
                cache: configuration.cache == nil ? nil : strings[2],
                context_index: configuration.contextIndex == nil ? nil : strings[3])
            return ifr_engine_create(&config, &created)
        }
        startup.end(initialization, status == ifrOK ? .ready : .failed)
        if configuration.cache != nil { startup.end(startup.begin(.maintenance, source: source), .skipped) }
        guard status == ifrOK, let native = created else { throw createFailure(status) }
        generation &+= 1
        do {
            let compiled = configuration.cache ?? URL(fileURLWithPath: user).appendingPathComponent("build")
            for file in ["pinyin_simp.reverse.bin"] + InputPreferences.compiledSpellingFiles {
                guard FileManager.default.isReadableFile(atPath: compiled.appendingPathComponent(file).path) else {
                    throw IFDictionaryUpdateError(.apply, "compiled-file-missing", file: file)
                }
            }
            compiledDirectory = compiled
            try fault(.probe)
            try probe(native, phrases: requestedPhrases)
        } catch { ifr_engine_destroy(native); throw error }
        Self.native = native
        ready = true
        do {
            for (index, engine) in liveSessions.enumerated() {
                try fault(.session(index))
                try engine.restoreSession(afterCreate: { try fault(.sessionCreated(index)) })
            }
        } catch { stop(); throw error }
        voiceLexicon.markDirty()
        signalIdle()
        started = true
    }

    private static func createFailure(_ status: IFRStatus) -> IFDictionaryUpdateError {
        let message = ifrString(ifr_last_error())
        switch Int(status) {
        case IFR_RESOURCE where message.hasPrefix("missing resource "):
            return IFDictionaryUpdateError(.apply, "compiled-file-missing", file: String(message.dropFirst("missing resource ".count)))
        case IFR_RESOURCE: return IFDictionaryUpdateError(.apply, "context-index", detail: message)
        case IFR_CONFIGURATION: return IFDictionaryUpdateError(.apply, "custom-phrases", detail: message)
        case IFR_ALREADY_RUNNING: return IFDictionaryUpdateError(.apply, "engine-already-running", detail: message)
        default: return IFDictionaryUpdateError(.apply, "engine-create", detail: message)
        }
    }

    /// The new engine starts with no phrases, so the requested ones are written to custom_phrase.txt through
    /// the probe session: restoring a session later reads that file and never writes it.
    /// A learned user's first candidate need not equal the clean worker probe's first candidate.
    private static func probe(_ native: OpaquePointer, phrases: [CustomPhrase]) throws {
        var created: OpaquePointer?
        guard ifr_session_create(native, &created) == ifrOK, let probe = created else {
            throw IFDictionaryUpdateError(.apply, "schema-unavailable")
        }
        defer { _ = ifr_session_clear(probe); ifr_session_destroy(probe) }
        if !phrases.isEmpty {
            configure(probe, count: 5, options: nil, phrases: phrases)
            if let code = ifr_session_configuration_error(probe).map({ String(cString: $0) }) {
                throw IFDictionaryUpdateError(.apply, "custom-phrases", detail: configurationMessage(code))
            }
        }
        for key in "nihao".utf8 { _ = ifr_session_key(probe, Int32(key), 0, nil) }
        guard let snapshot = PortableSnapshot(probe) else { throw IFDictionaryUpdateError(.apply, "probe-context") }
        guard snapshot.candidateCount > 0 else { throw IFDictionaryUpdateError(.apply, "probe-empty") }
    }

    package static func stop() {
        voiceLexicon.reset()
        for recorder in qualityRecorders { recorder.value?.interrupt(reason: "engine_stopped") }
        qualityRecorders = []
        // Invalidate every object before the core goes; a stale deinit can never destroy a reused handle.
        // The core finalizes Rime when its last session and the engine reference are gone.
        for engine in liveSessions { engine.detachSession() }
        if let native { ifr_engine_destroy(native) }
        native = nil
        ready = false
        generation &+= 1
    }

    package static func replace(with next: IFEngineConfiguration, restoring old: IFEngineConfiguration?,
                        fault: (IFEngineSwitchStep, Bool) throws -> Void = { _, _ in },
                        confirm: () throws -> Void) throws {
        guard allSessionsIdle else { throw IFDictionaryUpdateError(.apply, "sessions-busy") }
        stop()
        do {
            try start(next, fault: { try fault($0, false) })
            try confirm()
        } catch {
            let original = IFDictionaryUpdateError.wrapping(error, stage: .apply)
            stop()
            do {
                guard let old else { throw IFDictionaryUpdateError(.rollback, "no-confirmed-engine") }
                try start(old, fault: { try fault($0, true) })
            } catch {
                stop()
                NotificationCenter.default.post(name: .engineAvailabilityDidChange, object: nil)
                throw IFDictionaryUpdateError(.rollback, "engine-unavailable", detail: original.technicalDetails + "\n" +
                    IFDictionaryUpdateError.wrapping(error, stage: .rollback).technicalDetails)
            }
            NotificationCenter.default.post(name: .engineAvailabilityDidChange, object: nil)
            throw original
        }
        NotificationCenter.default.post(name: .engineAvailabilityDidChange, object: nil)
    }

    package init?(qualityStore: QualityStore? = nil, qualityClock: QualityClock = QualityClock()) {
        qualityRecorder = (qualityStore ?? Self.productionQualityStore).map { QualityRecorder(store: $0, clock: qualityClock) }
        guard Self.ready, !Self.personalDataSuspended else { return nil }
        do { try restoreSession() } catch { detachSession(); return nil }
        Self.instances[ObjectIdentifier(self)] = WeakSession(self)
        Self.voiceLexicon.markDirty()
        Self.signalIdle()
    }

    private func restoreSession(afterCreate: () throws -> Void = {}) throws {
        var created: OpaquePointer?
        session = nil
        guard let native = Self.native, ifr_session_create(native, &created) == ifrOK, let created else {
            throw IFDictionaryUpdateError(.apply, "session-create")
        }
        session = created
        sessionGeneration = Self.generation
        try afterCreate()
        if let qualityRecorder {
            Self.qualityRecorders.removeAll { $0.value == nil }
            if !Self.qualityRecorders.contains(where: { $0.value === qualityRecorder }) {
                Self.qualityRecorders.append(WeakQualityRecorder(qualityRecorder))
            }
        }
        configurationError = nil; configurationCode = nil
        orderedContent = EngineSnapshot(); precedingText = ""
        pushConfiguration()
        if let configurationError { throw IFDictionaryUpdateError(.apply, "session-settings", detail: configurationError) }
        asciiMode = savedASCII
    }

    private func detachSession() {
        if let session { ifr_session_destroy(session) }
        session = nil; sessionGeneration = 0
        orderedContent = EngineSnapshot(); precedingText = ""
    }

    isolated deinit {
        qualityRecorder?.interrupt(reason: "engine_teardown")
        detachSession()
        Self.instances.removeValue(forKey: ObjectIdentifier(self))
        Self.signalIdle()
    }

    @discardableResult
    package func key(_ key: Int32, modifiers: Int32 = 0, isRepeat: Bool = false) -> Bool {
        // The core retries a session it lost during a phrase reload on its next use.
        guard attached else { return false }
        defer { Self.signalIdle() }
        // Apply existing idle configuration before capturing the values this key actually uses.
        applyConfigurationIfIdle()
        guard available else { return false }
        return qualityOperation(.key(key, modifiers, isRepeat)) { performKey(key, modifiers: modifiers) }
    }

    private func performKey(_ key: Int32, modifiers: Int32) -> Bool {
        var handled: Int32 = 0
        let status = ifr_session_key(session, key, modifiers, &handled)
        // Rime can undo learning while leaving Backspace unhandled for the client.
        if key == 0xff08 || key == 0xffff { Self.voiceLexicon.markDirty() }
        trackOrdering()
        return status == ifrOK && handled != 0
    }

    package func setCandidateCount(_ count: Int) {
        setConfiguration(candidateCount: count, customPhrases: Self.requestedPhrases, inputPreferences: requestedInput)
    }

    package func setPrecedingText(_ text: String) {
        let prefix = String(text.suffix(IFContextRanker.contextLimit))
        if available { _ = ifr_session_set_preceding_text(session, prefix) }
        guard prefix != precedingText else { return }
        precedingText = prefix
        guard isComposing else { return }
        orderedContent = content(of: snapshotContent())
    }

    package func setConfiguration(candidateCount: Int, customPhrases: [CustomPhrase], inputPreferences: InputPreferences? = nil) {
        do { try CustomPhrase.validate(customPhrases) }
        catch { reportConfigurationError(error.localizedDescription); return }
        let previous = (requestedCount, requestedInput, Self.requestedPhrases)
        Self.requestedPhrases = customPhrases
        requestedCount = (3...9).contains(candidateCount) ? candidateCount : 5
        if let inputPreferences { requestedInput = inputPreferences }
        configurationError = nil; configurationCode = nil
        pushConfiguration()
        // A phrase file that could not be written keeps the whole configuration waiting.
        if configurationCode == "phrase-write" { (requestedCount, requestedInput, _) = previous }
    }

    /// Hand the requested count, preferences and phrases to the core. It applies them at this
    /// session's next composition boundary, and the phrases to every idle session.
    private func pushConfiguration() {
        guard attached, let session else { return }
        Self.configure(session, count: requestedCount, options: requestedInput.optionMask, phrases: Self.requestedPhrases)
        refreshApplied()
    }

    private static func configure(_ session: OpaquePointer, count: Int, options: UInt32?, phrases: [CustomPhrase]) {
        var mask = options ?? 0
        withCStrings(phrases.flatMap { [$0.id.uuidString, $0.code, $0.text] }) { strings in
            let list = phrases.indices.map { IFRPhrase(id: strings[3 * $0], code: strings[3 * $0 + 1], text: strings[3 * $0 + 2]) }
            if options == nil { _ = ifr_session_set_configuration(session, count, list, list.count, nil) }
            else { _ = ifr_session_set_configuration(session, count, list, list.count, &mask) }
        }
    }

    /// Existing idle configuration applies before the values a key actually uses are captured.
    private func applyConfigurationIfIdle() {
        guard attached, let session else { return }
        _ = ifr_session_set_ascii_mode(session, requestedASCIIMode ? 1 : 0)
        refreshApplied()
    }

    /// What the core applied or refused after a call that can change the configuration.
    private func refreshApplied() {
        guard let session else { return }
        configurationCode = ifr_session_configuration_error(session).map { String(cString: $0) }
        if let configurationCode { reportConfigurationError(configurationMessage(configurationCode)) }
        else { configurationError = nil }
        // Settings, ASCII mode and phrases take effect between compositions, and so does their record.
        guard orderedContent.preedit.isEmpty else { return }
        if Self.loadedPhrases != Self.requestedPhrases, configurationCode != "phrase-write",
           Self.sessionsIdle(includingDelivery: false) {
            Self.loadedPhrases = Self.requestedPhrases
        }
        updateQualityConfiguration(asciiMode: savedASCII)
    }

    private func reportConfigurationError(_ message: String) {
        if configurationError != message {
            LocalDiagnostics.shared.submit(.init(module: .input, event: "configurationFailed", outcome: .failed))
            NSLog("InkFlow input settings: %@", message)
        }
        configurationError = message
    }

    /// Semantic key input. Negative values record an unsupported platform event without entering Rime.
    @discardableResult
    package func input(_ key: Int32, modifiers: Int32 = 0, isRepeat: Bool = false,
               capturedAt: TimeInterval? = nil) -> Bool {
        guard available else { return false }
        qualityEventTime = capturedAt
        defer { qualityEventTime = nil }
        defer { Self.signalIdle() }
        guard key >= 0 else { return qualityOperation(.key(key, 0, isRepeat)) { false } }
        return self.key(key, modifiers: modifiers, isRepeat: isRepeat)
    }

    package func select(_ index: Int, trigger: QualityTrigger = .other, ambiguousText: Bool = false,
                capturedAt: TimeInterval? = nil) {
        guard available else { return }
        defer { Self.signalIdle() }
        _ = qualityOperation(.select(index, trigger, ambiguousText), capturedAt: capturedAt) {
            // The snapshot is the current page, so the core never sees a stale selection.
            guard let page = PortableSnapshot(session), index >= 0, index < page.candidateCount else { return false }
            var handled: Int32 = 0
            let status = ifr_session_select(session, page.handle, index, &handled)
            trackOrdering()
            return status == ifrOK && handled != 0
        }
    }

    package func highlight(_ index: Int) {
        guard available else { return }
        defer { Self.signalIdle() }
        _ = qualityOperation(.highlight) { performHighlight(index); return true }
    }

    private func performHighlight(_ index: Int) {
        guard let page = PortableSnapshot(session), index >= 0, index < page.candidateCount else { return }
        _ = ifr_session_highlight(session, page.handle, index)
        // Highlighting a partial choice can change Rime's preedit and cursor.
        // Record the new content without overriding explicit user navigation.
        orderedContent = content(of: snapshotContent())
    }

    package func commit(trigger: QualityTrigger = .forceFlush, capturedAt: TimeInterval? = nil) {
        guard available else { return }
        defer { Self.signalIdle() }
        _ = qualityOperation(.flush(trigger), capturedAt: capturedAt) {
            var handled: Int32 = 0
            let status = ifr_session_commit(session, &handled)
            trackOrdering()
            return status == ifrOK && handled != 0
        }
    }

    package func clear(recordQuality: Bool = true) {
        guard available else { return }
        defer { Self.signalIdle() }
        let clear = {
            // An adopted AI suggestion ends the composition without being the user's cancellation.
            _ = recordQuality ? ifr_session_clear(self.session) : ifr_session_clear_unobserved(self.session)
            self.trackOrdering()
            return true
        }
        if recordQuality { _ = qualityOperation(.clear, clear) }
        else { _ = clear() }
    }

    private func content(of snapshot: EngineSnapshot) -> EngineSnapshot {
        var result = snapshot
        result.highlight = 0
        return result
    }

    /// The preceding context ends with the composition whose content it ranked.
    private func trackOrdering() {
        guard available else { return }
        let current = content(of: snapshotContent())
        guard current != orderedContent else { return }
        orderedContent = current
        if current.preedit.isEmpty { precedingText = "" }
    }

    package func takeCommit(recordQuality: Bool = true) -> String {
        defer { Self.signalIdle() }
        let text = bufferedCommit + readCommit()
        bufferedCommit = ""
        if recordQuality { qualityRecorder?.commitDrained(text, insertionIssued: false, clientID: nil) }
        return text
    }

    private func readCommit() -> String {
        guard available else { return "" }
        var commit: UnsafeMutablePointer<CChar>?
        guard ifr_session_take_commit(session, &commit) == ifrOK, let commit else { return "" }
        defer { ifr_string_free(commit) }
        Self.voiceLexicon.nativeCommit()
        return String(cString: commit)
    }

    package nonisolated static func utf16Cursor(in preedit: String, byteOffset: Int) -> Int {
        let bytes = Array(preedit.utf8.prefix(max(0, byteOffset)))
        return String(bytes: bytes, encoding: .utf8)?.utf16.count ?? 0
    }

    package func snapshot() -> EngineSnapshot { snapshotContent() }

    private var isComposing: Bool { available && PortableSnapshot(session).map { !$0.preedit.isEmpty } == true }

    private func snapshotContent() -> EngineSnapshot {
        guard available else { return EngineSnapshot() }
        return PortableSnapshot(session)?.content ?? EngineSnapshot()
    }

    package func setQualityPresentation(fontSize: Int, vertical: Bool) {
        guard qualityFontSize != fontSize || qualityVertical != vertical else { return }
        qualityFontSize = fontSize
        qualityVertical = vertical
        updateQualityConfiguration(asciiMode: asciiMode)
    }

    private func updateQualityConfiguration(asciiMode: Bool) {
        let configuration = QualityAppliedConfiguration(candidateCount: candidateCount,
            customPhrases: Self.loadedPhrases.map { QualityPhrase(id: $0.id.uuidString, code: $0.code, text: $0.text) },
            asciiMode: asciiMode, fontSize: qualityFontSize, vertical: qualityVertical,
            inputOptions: inputPreferences?.recordedValues)
        if configuration != qualityRevision.configuration {
            qualityRevision = QualityConfigRevision(configuration: configuration)
        }
    }

    private func qualityOperation(_ action: QualityAction, capturedAt: TimeInterval? = nil, _ body: () -> Bool) -> Bool {
        guard let qualityRecorder, qualityDepth == 0 else { return body() }
        qualityDepth += 1
        defer { qualityDepth -= 1 }
        qualityRecorder.willMutate(qualitySnapshot(), revision: qualityRevision, action: action, at: capturedAt ?? qualityEventTime)
        let handled = body()
        qualityRecorder.didMutate(qualitySnapshot(), handled: handled)
        return handled
    }

    /// Read-only observation; never reads commit buffers, updates order or changes highlight.
    package func qualitySnapshot() -> QualityPageSnapshot {
        guard available, let page = PortableSnapshot(session) else {
            return QualityPageSnapshot(generation: 0, rawInput: "", caret: 0, selectedPrefix: "",
                precedingContext: "", configurationRevisionID: qualityRevision.id,
                configuration: qualityRevision.configuration, page: 0, pageSize: candidateCount,
                candidates: [], highlightedDisplayIndex: 0, selectedPrefixValid: false)
        }
        let preedit = page.preedit
        let offset = page.selectionStart
        let prefix = offset <= preedit.utf8.count ? String(bytes: preedit.utf8.prefix(offset), encoding: .utf8) : nil
        let number = page.page
        // Rime reports a page size only while a menu is shown.
        let size = page.candidateCount > 0 ? candidateCount : 0
        let candidates = (0..<page.candidateCount).map { display in
            let source: String? = switch Int(ifr_snapshot_candidate_personal_source(page.handle, display)) {
            case IFR_PERSONAL_EXACT_ENGLISH: "personal_exact_english"
            case IFR_PERSONAL_EXACT_MIXED: "personal_exact_mixed"
            default: nil
            }
            var start = 0, end = 0
            let consumed = source != nil && ifr_snapshot_candidate_consumed_input(page.handle, display, &start, &end) != 0
            return QualityCandidate(text: page.text(display), comment: page.comment(display),
                displayIndex: display, displayRank: number * size + display + 1,
                nativeIndex: Int(ifr_snapshot_candidate_native_index(page.handle, display)),
                nativeRank: Int(ifr_snapshot_candidate_native_rank(page.handle, display)), source: source,
                consumedInputStart: consumed ? start : nil, consumedInputEnd: consumed ? end : nil)
        }
        return QualityPageSnapshot(generation: 0, rawInput: page.input, caret: page.rawCaretBytes,
            selectedPrefix: prefix ?? "", precedingContext: precedingText, configurationRevisionID: qualityRevision.id,
            configuration: qualityRevision.configuration, page: number, pageSize: size, candidates: candidates,
            highlightedDisplayIndex: page.highlighted, selectedPrefixValid: prefix != nil)
    }
}

extension Notification.Name {
    package static let engineAvailabilityDidChange = Notification.Name("InkFlowEngineAvailabilityDidChange")
}

package enum IFEngineSwitchStep: Equatable { case start, probe, session(Int), sessionCreated(Int) }

/// Descriptor validation happens away from live native input callbacks; the engine loads the context index itself.
package struct IFEngineConfiguration: Sendable {
    package struct Identity: Equatable, Sendable {
        let shared: String
        let cache: String?
        let user: String
    }

    package let shared: URL
    package let cache: URL?
    package let user: String
    /// The prepared `pinyin_simp.context.bin`; without it Rime keeps its own candidate order.
    package let contextIndex: URL?

    package var identity: Identity {
        .init(shared: shared.standardizedFileURL.path,
              cache: cache?.standardizedFileURL.path,
              user: URL(fileURLWithPath: user).standardizedFileURL.path)
    }
    package init(shared: URL,
        cache: URL?,
        user: String,
        contextIndex: URL?) {
        self.shared = shared
        self.cache = cache
        self.user = user
        self.contextIndex = contextIndex
    }

}
