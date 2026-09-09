import AppKit

struct EngineSnapshot: Equatable {
    var preedit = ""
    var cursor = 0
    var candidates: [String] = []
    var page = 0
    var highlight = 0
    var hasSelectedPrefix = false
}

/// librime and its shared schema configuration are accessed synchronously on the main actor.
@MainActor
final class IFEngine {
    private static let api = rime_get_api()!
    private(set) static var ready = false
    private static var generation: UInt64 = 0
    private final class WeakSession {
        weak var value: IFEngine?
        init(_ value: IFEngine) { self.value = value }
    }
    private static var instances: [ObjectIdentifier: WeakSession] = [:]
    private static var idleScheduled = false
    static var idleHandler: (@MainActor () -> Void)?
    private var sessionGeneration: UInt64 = 0
    private var sessionRestored = false
    private var deliveryDepth = 0
    private var savedASCII = false

    static var liveSessions: [IFEngine] { instances.values.compactMap(\.value) }
    var available: Bool { Self.ready && session != 0 && sessionGeneration == Self.generation }
    var asciiMode: Bool {
        get { available ? Self.api.pointee.get_option(session, "ascii_mode") != 0 : savedASCII }
        set {
            savedASCII = newValue
            applyConfigurationIfIdle()
        }
    }
    var requestedASCIIMode: Bool { savedASCII }
    /// Keep the lease until every native client callback returns, including nested run loops.
    func beginDelivery() { deliveryDepth += 1 }
    func endDelivery() { deliveryDepth = max(0, deliveryDepth - 1); Self.signalIdle() }
    static var allSessionsIdle: Bool {
        liveSessions.allSatisfy { engine in
            guard engine.deliveryDepth == 0 else { return false }
            engine.bufferedCommit += engine.readCommit()
            return engine.rawSnapshot().preedit.isEmpty && engine.bufferedCommit.isEmpty
        }
    }
    static func signalIdle() {
        guard idleHandler != nil, !idleScheduled else { return }
        idleScheduled = true
        Task { @MainActor in
            idleScheduled = false
            idleHandler?()
        }
    }
    private static var userDirectory = ""
    private static var compiledDirectory = URL(fileURLWithPath: "/")
    private static var contextRanker: IFContextRanker?
    private static var productionQualityStore: QualityStore?
    private final class WeakQualityRecorder {
        weak var value: QualityRecorder?
        init(_ value: QualityRecorder) { self.value = value }
    }
    private static var qualityRecorders: [WeakQualityRecorder] = []
    private var session: RimeSessionId = 0
    private(set) var candidateCount = 5
    private var requestedCount = 5
    private var requestedPhrases: [CustomPhrase] = []
    private var appliedPhrases: [CustomPhrase] = []
    private var requestedInput = InputPreferences()
    private(set) var inputPreferences: InputPreferences?
    private var bufferedCommit = ""
    private var temporaryDictionary: URL?
    private(set) var configurationError: String?
    private var precedingText = ""
    private var orderedContent = EngineSnapshot()
    private var candidateOrder: [Int] = []
    let qualityRecorder: QualityRecorder?
    private(set) var qualityRevision = QualityConfigRevision(configuration: QualityAppliedConfiguration(candidateCount: 5))
    private var qualityDepth = 0
    private var qualityEventTime: TimeInterval?
    private var qualityFontSize = 14
    private var qualityVertical = false

    static var version: String { string(api.pointee.get_version()) }

    /// The process owns recording across native dictionary replacement and recovery.
    static func configureQualityRecording(_ store: QualityStore?) { productionQualityStore = store }

    /// Standalone startup retains the existing explicit quality-store injection.
    static func start(shared: String, user: String, qualityStore: QualityStore? = nil) throws {
        if ready { return }
        let configuration = IFEngineConfiguration(shared: URL(fileURLWithPath: shared), cache: nil,
            user: user, ranker: try IFContextRanker(dictionary: (shared as NSString).appendingPathComponent("pinyin_simp.dict.yaml")))
        do { try start(configuration); productionQualityStore = qualityStore }
        catch let error as IFDictionaryUpdateError where error.code == "missing-runtime-resource" {
            // Preserve the established standalone API's missing-resource error contract.
            throw NSError(domain: "io.damao.inputmethod.inkflow", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "InkFlow 缺少内置词典资源，请重新构建并安装。"])
        }
        NotificationCenter.default.post(name: .engineAvailabilityDidChange, object: nil)
    }

    static func start(_ configuration: IFEngineConfiguration,
                      fault: (IFEngineSwitchStep) throws -> Void = { _ in }) throws {
        guard !ready else { return }
        try fault(.start)
        let shared = configuration.shared.path
        for name in ["default.yaml", "inkflow_pinyin.schema.yaml", "pinyin_simp.dict.yaml",
                     "easy_en.schema.yaml", "easy_en.dict.yaml", "inkflow_mixed.schema.yaml", "inkflow_mixed.dict.yaml",
                     "lua/inkflow_english.lua", "lua/inkflow_mixed.lua", "lua/inkflow_ai_learning.lua", "opencc/inkflow_emoji.json", "opencc/emoji.txt",
                     "opencc/inkflow_s2t.json", "opencc/STPhrases.txt", "opencc/STCharacters.txt"] +
                    (0..<32).map({ InputPreferences.spellingProfile($0) + ".schema.yaml" }) {
            guard FileManager.default.isReadableFile(atPath: configuration.shared.appendingPathComponent(name).path) else {
                throw IFDictionaryUpdateError(.apply, "missing-runtime-resource", file: name)
            }
        }
        let user = configuration.user
        try FileManager.default.createDirectory(atPath: user, withIntermediateDirectories: true)
        var traits = RimeTraits()
        traits.data_size = Int32(MemoryLayout<RimeTraits>.size - MemoryLayout.size(ofValue: traits.data_size))
        traits.distribution_name = cString("InkFlow")
        traits.distribution_code_name = cString("inkflow")
        traits.distribution_version = cString("1.0")
        traits.app_name = cString("rime.inkflow")
        traits.min_log_level = 3
        traits.log_dir = cString("")
        shared.withCString { sharedPath in
            user.withCString { userPath in
                @MainActor func initialize(_ cachePath: UnsafePointer<CChar>?) {
                    traits.shared_data_dir = sharedPath
                    traits.user_data_dir = userPath
                    traits.staging_dir = cachePath
                    traits.prebuilt_data_dir = cachePath
                    api.pointee.setup(&traits)
                    api.pointee.initialize(&traits)
                }
                if let cache = configuration.cache { cache.path.withCString { initialize($0) } }
                else { initialize(nil) }
            }
        }
        generation &+= 1
        // Prepared caches were compiled/probed by the isolated worker. Never deploy on a live switch.
        if configuration.cache == nil, api.pointee.start_maintenance(1) != 0 { api.pointee.join_maintenance_thread() }
        do {
            let compiled = configuration.cache ?? URL(fileURLWithPath: user).appendingPathComponent("build")
            for file in ["pinyin_simp.reverse.bin"] + InputPreferences.compiledSpellingFiles {
                guard FileManager.default.isReadableFile(atPath: compiled.appendingPathComponent(file).path) else {
                    throw IFDictionaryUpdateError(.apply, "compiled-file-missing", file: file)
                }
            }
            compiledDirectory = compiled
            try fault(.probe)
            let probe = api.pointee.create_session()
            defer {
                if probe != 0 { api.pointee.clear_composition(probe); _ = api.pointee.destroy_session(probe) }
            }
            guard probe != 0, api.pointee.select_schema(probe, "inkflow_pinyin") != 0 else {
                throw IFDictionaryUpdateError(.apply, "schema-unavailable")
            }
            for key in "nihao".utf8 { _ = api.pointee.process_key(probe, Int32(key), 0) }
            var context = makeContext()
            guard api.pointee.get_context(probe, &context) != 0 else { throw IFDictionaryUpdateError(.apply, "probe-context") }
            let hasCandidates = context.menu.num_candidates > 0
            _ = api.pointee.free_context(&context)
            // A learned user's first candidate need not equal the clean worker probe's first candidate.
            guard hasCandidates else { throw IFDictionaryUpdateError(.apply, "probe-empty") }
        } catch { api.pointee.finalize(); throw error }
        ready = true
        userDirectory = user
        contextRanker = configuration.ranker
        do {
            for (index, engine) in liveSessions.enumerated() {
                try fault(.session(index))
                try engine.restoreSession(afterCreate: { try fault(.sessionCreated(index)) })
            }
        } catch { stop(); throw error }
    }

    static func stop() {
        for recorder in qualityRecorders { recorder.value?.interrupt(reason: "engine_stopped") }
        qualityRecorders = []
        // Invalidate every object before finalize; a stale deinit can never destroy a reused native ID.
        for engine in liveSessions { engine.detachSession() }
        if ready { api.pointee.finalize(); ready = false }
        contextRanker = nil
        generation &+= 1
    }

    static func replace(with next: IFEngineConfiguration, restoring old: IFEngineConfiguration?,
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

    init?(qualityStore: QualityStore? = nil, qualityClock: QualityClock = QualityClock()) {
        qualityRecorder = (qualityStore ?? Self.productionQualityStore).map { QualityRecorder(store: $0, clock: qualityClock) }
        guard Self.ready else { return nil }
        do { try restoreSession() } catch { detachSession(); return nil }
        Self.instances[ObjectIdentifier(self)] = WeakSession(self)
    }

    private func restoreSession(afterCreate: () throws -> Void = {}) throws {
        sessionRestored = false
        session = Self.api.pointee.create_session()
        sessionGeneration = Self.generation
        guard session != 0 else { throw IFDictionaryUpdateError(.apply, "session-create") }
        try afterCreate()
        guard Self.api.pointee.select_schema(session, "inkflow_pinyin") != 0 else {
            throw IFDictionaryUpdateError(.apply, "session-create")
        }
        if let qualityRecorder {
            Self.qualityRecorders.removeAll { $0.value == nil }
            Self.qualityRecorders.append(WeakQualityRecorder(qualityRecorder))
        }
        candidateCount = 5; appliedPhrases = []; inputPreferences = nil; configurationError = nil
        candidateOrder = []; orderedContent = EngineSnapshot(); precedingText = ""
        applyConfigurationIfIdle()
        if let configurationError { throw IFDictionaryUpdateError(.apply, "session-settings", detail: configurationError) }
        asciiMode = savedASCII
        sessionRestored = true
    }

    private func detachSession() {
        if available {
            // A partially initialized session still has native defaults. Keep the captured mode for rollback.
            _ = Self.api.pointee.destroy_session(session)
        }
        session = 0; sessionGeneration = 0; sessionRestored = false
        candidateOrder = []; orderedContent = EngineSnapshot(); precedingText = ""
    }

    isolated deinit {
        qualityRecorder?.interrupt(reason: "engine_teardown")
        detachSession()
        Self.instances.removeValue(forKey: ObjectIdentifier(self))
        Self.signalIdle()
    }

    @discardableResult
    func key(_ key: Int32, modifiers: Int32 = 0, isRepeat: Bool = false) -> Bool {
        guard available else { return false }
        defer { Self.signalIdle() }
        // Apply existing idle configuration before capturing the values this key actually uses.
        applyConfigurationIfIdle()
        return qualityOperation(.key(key, modifiers, isRepeat)) { performKey(key, modifiers: modifiers) }
    }

    private func performKey(_ key: Int32, modifiers: Int32) -> Bool {
        let state = snapshot()
        if modifiers == 0, (49...57).contains(key), Int(key - 49) < state.candidates.count {
            select(Int(key - 49))
            return true
        }
        if modifiers == 0, (key == 0xff52 || key == 0xff54), !state.candidates.isEmpty {
            return moveHighlight(key == 0xff54 ? 1 : -1, key: key)
        }
        let handled = Self.api.pointee.process_key(session, key, modifiers) != 0
        updateOrdering()
        return handled
    }

    func setCandidateCount(_ count: Int) {
        setConfiguration(candidateCount: count, customPhrases: requestedPhrases, inputPreferences: requestedInput)
    }

    func setPrecedingText(_ text: String) {
        let prefix = String(text.suffix(IFPrecedingText.limit))
        guard prefix != precedingText else { return }
        precedingText = prefix
        guard !rawSnapshot().preedit.isEmpty else { return }
        updateOrdering(force: true)
    }

    func setConfiguration(candidateCount: Int, customPhrases: [CustomPhrase], inputPreferences: InputPreferences? = nil) {
        do { try CustomPhrase.validate(customPhrases) }
        catch { reportConfigurationError(error.localizedDescription); return }
        requestedCount = (3...9).contains(candidateCount) ? candidateCount : 5
        requestedPhrases = customPhrases
        if let inputPreferences { requestedInput = inputPreferences }
        applyConfigurationIfIdle()
    }

    private func applyConfigurationIfIdle() {
        guard available else { return }
        // Retain a failed cleanup for retry instead of silently leaving phrase text on disk.
        guard removeTemporaryDictionary() else { return }
        guard candidateCount != requestedCount || appliedPhrases != requestedPhrases || inputPreferences != requestedInput else {
            configurationError = nil
            if snapshot().preedit.isEmpty { applyRuntimeOptions() }
            return
        }
        guard snapshot().preedit.isEmpty else { return }
        // StableDb caches loaded data by name. A fresh name lets old composing sessions retain
        // their snapshot while this idle session synchronously loads the new phrases.
        let name = "inkflow_phrases_" + UUID().uuidString
        let file = URL(fileURLWithPath: Self.userDirectory).appendingPathComponent(name + ".txt")
        // librime's TSV parser otherwise treats phrases beginning with '#' as comments.
        let tsv = "# no comment\n" + requestedPhrases.enumerated().map { index, phrase in
            "\(phrase.text)\t\(phrase.code)\t\(requestedPhrases.count - index)\n"
        }.joined()
        temporaryDictionary = file
        defer { _ = removeTemporaryDictionary() }
        guard FileManager.default.createFile(atPath: file.path, contents: Data(tsv.utf8),
                                              attributes: [.posixPermissions: 0o600]) else {
            reportConfigurationError("无法载入自定义短语，请检查墨流数据目录的可用空间和写入权限。")
            return
        }
        do {
            try recreateSchema(dictionary: name)
            configurationError = nil
        }
        catch { reportConfigurationError(error.localizedDescription) }
    }

    private func removeTemporaryDictionary() -> Bool {
        guard let temporaryDictionary else { return true }
        do {
            try FileManager.default.removeItem(at: temporaryDictionary)
            self.temporaryDictionary = nil
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            self.temporaryDictionary = nil
            return true
        } catch {
            reportConfigurationError("临时短语文件清理失败，请检查墨流数据目录的写入权限。")
            return false
        }
    }

    private func recreateSchema(dictionary: String) throws {
        // Replace whole nodes and restore them synchronously. Existing sessions retain their
        // component configuration, while this idle session loads one coherent snapshot.
        let api = Self.api.pointee
        guard FileManager.default.isReadableFile(atPath: Self.compiledDirectory
            .appendingPathComponent(requestedInput.spellingProfile + ".prism.bin").path) else {
            throw CustomPhraseError("缺少已编译的拼音规则，设置尚未应用。请重启墨流后重试。")
        }
        var config = RimeConfig()
        guard api.schema_open("inkflow_pinyin", &config) != 0 else {
            throw CustomPhraseError("无法打开输入方案，设置尚未应用。")
        }
        defer { _ = api.config_close(&config) }
        var patch = RimeConfig()
        let yaml = requestedInput.schemaPatch + """

        menu:
          page_size: \(requestedCount)
        translator:
          dictionary: pinyin_simp
          prism: \(requestedInput.spellingProfile)
          preedit_format: ['xform/([nl])v/$1ü/', 'xform/([jqxy])v/$1u/']
        custom_phrase:
          dictionary: ""
          user_dict: \(dictionary)
          db_class: stabledb
          enable_completion: false
          enable_sentence: false
          initial_quality: 100
        """
        guard api.config_init(&patch) != 0 else { throw CustomPhraseError("无法创建输入设置。") }
        defer { _ = api.config_close(&patch) }
        guard yaml.withCString({ api.config_load_string(&patch, $0) }) != 0 else {
            throw CustomPhraseError("无法载入输入设置。")
        }
        var originals: [(String, RimeConfig)] = []
        var patched = true
        for path in ["menu", "translator", "custom_phrase", "key_binder", "punctuator"] {
            var original = RimeConfig(), replacement = RimeConfig()
            guard api.config_get_item(&config, path, &original) != 0 else { patched = false; break }
            originals.append((path, original))
            guard api.config_get_item(&patch, path, &replacement) != 0 else { patched = false; break }
            let changed = api.config_set_item(&config, path, &replacement) != 0
            _ = api.config_close(&replacement)
            if !changed { patched = false; break }
        }
        // select_schema resets the commit buffer as well as the schema. Preserve completed text
        // even if settings arrive before the controller has drained the previous key's commit.
        bufferedCommit += readCommit()
        let loaded = patched && api.select_schema(session, "inkflow_pinyin") != 0
        if loaded {
            candidateCount = requestedCount
            appliedPhrases = requestedPhrases
            inputPreferences = requestedInput
        }
        var restored = true
        for (path, var original) in originals.reversed() {
            if api.config_set_item(&config, path, &original) == 0 { restored = false }
            _ = api.config_close(&original)
        }
        applyRuntimeOptions()
        guard restored else {
            throw CustomPhraseError("恢复临时输入方案配置失败，请重启墨流后重试。")
        }
        guard loaded else { throw CustomPhraseError("无法应用输入设置，请重启墨流后重试。") }
    }

    private func applyRuntimeOptions() {
        guard available, let inputPreferences else { return }
        let api = Self.api.pointee
        api.set_option(session, "ascii_mode", savedASCII ? 1 : 0)
        api.set_option(session, "ascii_punct", savedASCII || inputPreferences[.englishPunctuation] ? 1 : 0)
        api.set_option(session, "emoji_suggestion", inputPreferences[.emoji] ? 1 : 0)
        api.set_option(session, "traditional", inputPreferences[.traditional] ? 1 : 0)
        updateQualityConfiguration(asciiMode: savedASCII)
    }

    private func reportConfigurationError(_ message: String) {
        if configurationError != message { NSLog("InkFlow input settings: %@", message) }
        configurationError = message
    }

    @discardableResult
    func event(_ event: NSEvent, capturedAt: TimeInterval? = nil) -> Bool {
        guard available else { return false }
        qualityEventTime = capturedAt
        defer { qualityEventTime = nil }
        defer { Self.signalIdle() }
        let flags = event.modifierFlags
        if event.keyCode == 49, flags.contains([.control, .shift]), flags.intersection([.command, .option]).isEmpty {
            return qualityOperation(.toggle(event.isARepeat)) {
                asciiMode = !savedASCII
                return true
            }
        }
        guard flags.intersection([.command, .control, .option]).isEmpty else { return qualityOperation(.key(-1, 0, event.isARepeat)) { false } }
        let key: Int32
        switch event.keyCode {
        case 36, 76: key = 0xff0d
        case 48: key = 0xff09
        case 51: key = 0xff08
        case 53: key = 0xff1b
        case 117: key = 0xffff
        case 123: key = 0xff51
        case 124: key = 0xff53
        case 125: key = 0xff54
        case 126: key = 0xff52
        case 115: key = 0xff50
        case 119: key = 0xff57
        case 116: key = 0xff55
        case 121: key = 0xff56
        default:
            guard let characters = event.characters, characters.utf16.count == 1,
                  let character = characters.utf16.first, character <= 127 else {
                return qualityOperation(.key(-2, 0, event.isARepeat)) { false }
            }
            key = Int32(character)
        }
        return self.key(key, modifiers: flags.contains(.shift) ? 1 : 0, isRepeat: event.isARepeat)
    }

    func select(_ index: Int, trigger: QualityTrigger = .other, ambiguousText: Bool = false,
                capturedAt: TimeInterval? = nil) {
        guard available else { return }
        defer { Self.signalIdle() }
        _ = qualityOperation(.select(index, trigger, ambiguousText), capturedAt: capturedAt) {
            guard candidateOrder.indices.contains(index) else { return false }
            let handled = Self.api.pointee.select_candidate_on_current_page(session, candidateOrder[index]) != 0
            updateOrdering()
            return handled
        }
    }

    func highlight(_ index: Int) {
        guard available else { return }
        defer { Self.signalIdle() }
        _ = qualityOperation(.highlight) { performHighlight(index); return true }
    }

    private func performHighlight(_ index: Int) {
        guard candidateOrder.indices.contains(index) else { return }
        _ = Self.api.pointee.highlight_candidate_on_current_page(session, candidateOrder[index])
        // Highlighting a partial choice can change Rime's preedit and cursor.
        // Record the new content without overriding explicit user navigation.
        orderedContent = content(of: rawSnapshot())
    }

    func commit(trigger: QualityTrigger = .forceFlush, capturedAt: TimeInterval? = nil) {
        guard available else { return }
        defer { Self.signalIdle() }
        _ = qualityOperation(.flush(trigger), capturedAt: capturedAt) {
            let handled = Self.api.pointee.commit_composition(session) != 0
            updateOrdering()
            return handled
        }
    }

    func clear(recordQuality: Bool = true) {
        guard available else { return }
        defer { Self.signalIdle() }
        let clear = {
            Self.api.pointee.clear_composition(self.session)
            self.updateOrdering()
            return true
        }
        if recordQuality { _ = qualityOperation(.clear, clear) }
        else { _ = clear() }
    }

    private func moveHighlight(_ delta: Int, key: Int32) -> Bool {
        let before = snapshot()
        let next = before.highlight + delta
        if candidateOrder.indices.contains(next) { highlight(next); return true }
        // Let Rime decide whether another page exists, starting at its native edge.
        _ = Self.api.pointee.highlight_candidate_on_current_page(session, delta > 0 ? candidateOrder.count - 1 : 0)
        let handled = Self.api.pointee.process_key(session, key, 0) != 0
        updateOrdering()
        if snapshot().page != before.page {
            if delta < 0 { highlight(candidateOrder.count - 1) }
        } else if !candidateOrder.isEmpty { highlight(before.highlight) }
        return handled
    }

    private func content(of snapshot: EngineSnapshot) -> EngineSnapshot {
        var result = snapshot
        result.highlight = 0
        return result
    }

    private func updateOrdering(force: Bool = false) {
        guard available else { return }
        let raw = rawSnapshot()
        let content = content(of: raw)
        guard force || content != orderedContent else { return }
        // Explicit custom codes keep the user's ordered phrases ahead of ordinary words.
        // Use the applied snapshot so deferred settings cannot change a live composition.
        let input = Self.string(Self.api.pointee.get_input(session))
        let hasCustomCode = appliedPhrases.contains { $0.code == input }
        // Once a segment is selected, the immediate prefix is inside the mark.
        // Leave these remaining candidates to Rime instead of applying older document text.
        candidateOrder = raw.hasSelectedPrefix || hasCustomCode ? Array(raw.candidates.indices) :
            (Self.contextRanker?.order(raw.candidates, precedingText: precedingText) ?? Array(raw.candidates.indices))
        if let first = candidateOrder.first {
            _ = Self.api.pointee.highlight_candidate_on_current_page(session, first)
        }
        orderedContent = self.content(of: rawSnapshot())
        if raw.preedit.isEmpty { precedingText = "" }
    }

    func takeCommit(recordQuality: Bool = true) -> String {
        defer { Self.signalIdle() }
        let text = bufferedCommit + readCommit()
        bufferedCommit = ""
        if recordQuality { qualityRecorder?.commitDrained(text, insertionIssued: false, clientID: nil) }
        return text
    }

    private func readCommit() -> String {
        guard available else { return "" }
        var commit = RimeCommit()
        commit.data_size = Int32(MemoryLayout<RimeCommit>.size - MemoryLayout.size(ofValue: commit.data_size))
        guard Self.api.pointee.get_commit(session, &commit) != 0 else { return "" }
        defer { _ = Self.api.pointee.free_commit(&commit) }
        return Self.string(commit.text)
    }

    static func utf16Cursor(in preedit: String, byteOffset: Int) -> Int {
        let bytes = Array(preedit.utf8.prefix(max(0, byteOffset)))
        return String(bytes: bytes, encoding: .utf8)?.utf16.count ?? 0
    }

    func snapshot() -> EngineSnapshot {
        var result = rawSnapshot()
        guard candidateOrder.count == result.candidates.count else { return result }
        result.candidates = candidateOrder.map { result.candidates[$0] }
        result.highlight = candidateOrder.firstIndex(of: result.highlight) ?? 0
        return result
    }

    /// Small read-only input observation; candidate presentation and quality telemetry are unrelated.
    func aiInputIdentity() -> AIInputIdentity? {
        guard available, !asciiMode else { return nil }
        let input = Self.string(Self.api.pointee.get_input(session))
        guard !input.isEmpty else { return nil }
        var context = Self.makeContext()
        guard Self.api.pointee.get_context(session, &context) != 0 else { return nil }
        defer { _ = Self.api.pointee.free_context(&context) }
        let preedit = Self.string(context.composition.preedit)
        let offset = Int(context.composition.sel_start)
        guard offset >= 0, offset <= preedit.utf8.count,
              let prefix = String(bytes: preedit.utf8.prefix(offset), encoding: .utf8) else { return nil }
        return AIInputIdentity(rawInput: input, caret: Int(Self.api.pointee.get_caret_pos(session)), selectedPrefix: prefix)
    }

    /// Called only for a consumed AI adoption, inside the controller's delivery scope.
    /// Learning failure must never prevent insertion or register the original typo.
    @discardableResult
    func learnAIAdoption(input: AIInputIdentity, text: String, preferences: InputPreferences? = nil,
                         pronunciation: AIPronunciation? = nil) -> Bool {
        guard available, text.hasPrefix(input.selectedPrefix),
              let code = (pronunciation ?? aiPronunciation(input: input, text: text)).resolve(input: input.rawInput, text: text,
                  preferences: preferences ?? inputPreferences ?? requestedInput) else { return false }
        let api = Self.api.pointee
        let payload = code + "\t" + text
        api.set_property(session, "inkflow_ai_learning_result", "")
        payload.withCString { api.set_property(session, "inkflow_ai_learning", $0) }
        // Properties are transport only: retain no adopted text in the live context.
        api.set_property(session, "inkflow_ai_learning", "")
        var result = [CChar](repeating: 0, count: 16)
        let read = api.get_property(session, "inkflow_ai_learning_result", &result, result.count)
        api.set_property(session, "inkflow_ai_learning_result", "")
        return read != 0 && String(decoding: result.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == "ok"
    }

    func allowsAIRecommendation(input: AIInputIdentity, text: String) -> Bool {
        text.hasPrefix(input.selectedPrefix) &&
            !aiPronunciation(input: input, text: text).isClearExpansion(input: input.rawInput, text: text,
                preferences: inputPreferences ?? requestedInput)
    }

    /// Read only the current recommendation's native phrase/character codes. The
    /// absolute reverse-table path follows active dictionary activation and rollback.
    func aiPronunciation(input: AIInputIdentity, text: String) -> AIPronunciation {
        guard available else { return AIPronunciation(phrases: [:], characters: [:]) }
        let api = Self.api.pointee
        Self.compiledDirectory.appendingPathComponent("pinyin_simp.reverse.bin").path.withCString {
            api.set_property(session, "inkflow_ai_reverse_path", $0)
        }
        api.set_property(session, "inkflow_ai_readings_result", "")
        (input.rawInput + "\t" + text).withCString { api.set_property(session, "inkflow_ai_readings", $0) }
        var result = [CChar](repeating: 0, count: 128 * 1024)
        let read = api.get_property(session, "inkflow_ai_readings_result", &result, result.count)
        for name in ["inkflow_ai_readings", "inkflow_ai_readings_result", "inkflow_ai_reverse_path"] {
            api.set_property(session, name, "")
        }
        let readings = read != 0 ? String(decoding: result.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        return AIPronunciation(text: text, nativeReadings: readings)
    }

    func setQualityPresentation(fontSize: Int, vertical: Bool) {
        guard qualityFontSize != fontSize || qualityVertical != vertical else { return }
        qualityFontSize = fontSize
        qualityVertical = vertical
        updateQualityConfiguration(asciiMode: asciiMode)
    }

    private func updateQualityConfiguration(asciiMode: Bool) {
        let configuration = QualityAppliedConfiguration(candidateCount: candidateCount,
            customPhrases: appliedPhrases.map { QualityPhrase(id: $0.id.uuidString, code: $0.code, text: $0.text) },
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

    /// Read-only C API observation; never reads commit buffers, updates order or changes highlight.
    func qualitySnapshot() -> QualityPageSnapshot {
        guard available else {
            return QualityPageSnapshot(generation: 0, rawInput: "", caret: 0, selectedPrefix: "",
                precedingContext: "", configurationRevisionID: qualityRevision.id,
                configuration: qualityRevision.configuration, page: 0, pageSize: candidateCount,
                candidates: [], highlightedDisplayIndex: 0, selectedPrefixValid: false)
        }
        var context = Self.makeContext()
        let available = Self.api.pointee.get_context(session, &context) != 0
        defer { if available { _ = Self.api.pointee.free_context(&context) } }
        let preedit = Self.string(context.composition.preedit)
        let offset = Int(context.composition.sel_start)
        let prefix = offset >= 0 && offset <= preedit.utf8.count ?
            String(bytes: preedit.utf8.prefix(offset), encoding: .utf8) : nil
        let page = Int(context.menu.page_no)
        let size = Int(context.menu.page_size)
        let count = max(0, Int(context.menu.num_candidates))
        let order = candidateOrder.count == count ? candidateOrder : Array(0..<count)
        var candidates: [QualityCandidate] = []
        if let buffer = context.menu.candidates {
            candidates = order.enumerated().map { display, native in
                QualityCandidate(text: Self.string(buffer[native].text), comment: Self.string(buffer[native].comment),
                    displayIndex: display, displayRank: page * size + display + 1,
                    nativeIndex: native, nativeRank: page * size + native + 1)
            }
        }
        return QualityPageSnapshot(generation: 0, rawInput: Self.string(Self.api.pointee.get_input(session)),
            caret: Int(Self.api.pointee.get_caret_pos(session)), selectedPrefix: prefix ?? "",
            precedingContext: precedingText, configurationRevisionID: qualityRevision.id,
            configuration: qualityRevision.configuration, page: page, pageSize: size, candidates: candidates,
            highlightedDisplayIndex: order.firstIndex(of: Int(context.menu.highlighted_candidate_index)) ?? 0,
            selectedPrefixValid: available && prefix != nil)
    }

    private func rawSnapshot() -> EngineSnapshot {
        guard available else { return EngineSnapshot() }
        var context = Self.makeContext()
        guard Self.api.pointee.get_context(session, &context) != 0 else { return EngineSnapshot() }
        defer { _ = Self.api.pointee.free_context(&context) }
        let preedit = Self.string(context.composition.preedit)
        var candidates: [String] = []
        if let buffer = context.menu.candidates {
            for index in 0..<Int(context.menu.num_candidates) {
                candidates.append(Self.string(buffer[index].text))
            }
        }
        return EngineSnapshot(preedit: preedit,
                              cursor: Self.utf16Cursor(in: preedit, byteOffset: Int(context.composition.cursor_pos)),
                              candidates: candidates, page: Int(context.menu.page_no),
                              highlight: Int(context.menu.highlighted_candidate_index),
                              hasSelectedPrefix: context.composition.sel_start > 0)
    }

    private static func makeContext() -> RimeContext {
        var context = RimeContext()
        context.data_size = Int32(MemoryLayout<RimeContext>.size - MemoryLayout.size(ofValue: context.data_size))
        return context
    }

    private static func cString(_ literal: StaticString) -> UnsafePointer<CChar> {
        UnsafeRawPointer(literal.utf8Start).assumingMemoryBound(to: CChar.self)
    }

    private static func string(_ pointer: UnsafePointer<CChar>?) -> String {
        pointer.map(String.init(cString:)) ?? ""
    }
}

extension Notification.Name {
    static let engineAvailabilityDidChange = Notification.Name("InkFlowEngineAvailabilityDidChange")
}

enum IFEngineSwitchStep: Equatable { case start, probe, session(Int), sessionCreated(Int) }

/// Immutable index construction and descriptor validation happen away from live native input callbacks.
struct IFEngineConfiguration: Sendable {
    let shared: URL
    let cache: URL?
    let user: String
    let ranker: IFContextRanker
}
