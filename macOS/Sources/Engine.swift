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
    private static var ready = false
    private static var userDirectory = ""
    private static var contextRanker: IFContextRanker?
    private var session: RimeSessionId = 0
    private(set) var candidateCount = 5
    private var requestedCount = 5
    private var requestedPhrases: [CustomPhrase] = []
    private var appliedPhrases: [CustomPhrase] = []
    private var bufferedCommit = ""
    private var temporaryDictionary: URL?
    private(set) var configurationError: String?
    private var precedingText = ""
    private var orderedContent = EngineSnapshot()
    private var candidateOrder: [Int] = []

    static var version: String { string(api.pointee.get_version()) }

    static func start(shared: String, user: String) throws {
        if ready { return }
        for name in ["default.yaml", "inkflow_pinyin.schema.yaml", "pinyin_simp.dict.yaml",
                     "opencc/inkflow_emoji.json", "opencc/emoji.txt"] {
            guard FileManager.default.isReadableFile(atPath: (shared as NSString).appendingPathComponent(name)) else {
                throw NSError(domain: "io.damao.inputmethod.inkflow", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "InkFlow 缺少内置拼音资源，请重新构建并安装。"])
            }
        }
        contextRanker = try IFContextRanker(dictionary: (shared as NSString).appendingPathComponent("pinyin_simp.dict.yaml"))
        try FileManager.default.createDirectory(atPath: user, withIntermediateDirectories: true)
        var traits = RimeTraits()
        traits.data_size = Int32(MemoryLayout<RimeTraits>.size - MemoryLayout.size(ofValue: traits.data_size))
        traits.distribution_name = cString("InkFlow")
        traits.distribution_code_name = cString("inkflow")
        traits.distribution_version = cString("1.0")
        // glog retains app_name, so use process-lifetime literal storage.
        traits.app_name = cString("rime.inkflow")
        traits.min_log_level = 3
        traits.log_dir = cString("")
        // librime copies these paths during setup/initialize; keep them alive for both calls.
        shared.withCString { sharedPath in
            user.withCString { userPath in
                traits.shared_data_dir = sharedPath
                traits.user_data_dir = userPath
                api.pointee.setup(&traits)
                api.pointee.initialize(&traits)
            }
        }
        if api.pointee.start_maintenance(0) != 0 { api.pointee.join_maintenance_thread() }
        let probe = api.pointee.create_session()
        ready = probe != 0 && api.pointee.select_schema(probe, "inkflow_pinyin") != 0
        // A missing schema can report success; require an actual translator result.
        if ready {
            for key in "nihao".utf8 { _ = api.pointee.process_key(probe, Int32(key), 0) }
            var context = makeContext()
            ready = api.pointee.get_context(probe, &context) != 0
            if ready {
                ready = context.menu.num_candidates > 0
                _ = api.pointee.free_context(&context)
            }
        }
        if probe != 0 {
            api.pointee.clear_composition(probe)
            _ = api.pointee.destroy_session(probe)
        }
        guard ready else {
            api.pointee.finalize()
            throw NSError(domain: "io.damao.inputmethod.inkflow", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法载入拼音方案，请重新构建并安装 InkFlow。"])
        }
        userDirectory = user
    }

    static func stop() {
        if ready { api.pointee.finalize(); ready = false }
        contextRanker = nil
    }

    init?() {
        guard Self.ready else { return nil }
        session = Self.api.pointee.create_session()
        guard session != 0 else { return nil }
        guard Self.api.pointee.select_schema(session, "inkflow_pinyin") != 0 else {
            _ = Self.api.pointee.destroy_session(session)
            session = 0
            return nil
        }
    }

    isolated deinit {
        if Self.ready && session != 0 { _ = Self.api.pointee.destroy_session(session) }
    }

    @discardableResult
    func key(_ key: Int32, modifiers: Int32 = 0) -> Bool {
        applyConfigurationIfIdle()
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
        setConfiguration(candidateCount: count, customPhrases: requestedPhrases)
    }

    func setPrecedingText(_ text: String) {
        let prefix = String(text.suffix(IFPrecedingText.limit))
        guard prefix != precedingText else { return }
        precedingText = prefix
        guard !rawSnapshot().preedit.isEmpty else { return }
        updateOrdering(force: true)
    }

    func setConfiguration(candidateCount: Int, customPhrases: [CustomPhrase]) {
        do { try CustomPhrase.validate(customPhrases) }
        catch { reportConfigurationError(error.localizedDescription); return }
        requestedCount = (3...9).contains(candidateCount) ? candidateCount : 5
        requestedPhrases = customPhrases
        applyConfigurationIfIdle()
    }

    private func applyConfigurationIfIdle() {
        // Retain a failed cleanup for retry instead of silently leaving phrase text on disk.
        guard removeTemporaryDictionary() else { return }
        guard candidateCount != requestedCount || appliedPhrases != requestedPhrases else {
            configurationError = nil
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
        // Both values belong to one session snapshot. Patch and restore the shared in-memory
        // config on the main actor; never save/deploy it or replace Rime's learned dictionary.
        let api = Self.api.pointee
        var config = RimeConfig()
        guard api.schema_open("inkflow_pinyin", &config) != 0 else {
            throw CustomPhraseError("无法打开输入方案，设置尚未应用。")
        }
        var previous: Int32 = 5
        let hadValue = api.config_get_int(&config, "menu/page_size", &previous) != 0
        let previousDictionary = api.config_get_cstring(&config, "custom_phrase/user_dict").map(String.init(cString:))
        let ascii = api.get_option(session, "ascii_mode")
        let changed = api.config_set_int(&config, "menu/page_size", Int32(requestedCount)) != 0
        let patched = dictionary.withCString { api.config_set_string(&config, "custom_phrase/user_dict", $0) != 0 }
        // select_schema resets the commit buffer as well as the schema. Preserve completed text
        // even if settings arrive before the controller has drained the previous key's commit.
        bufferedCommit += readCommit()
        let loaded = changed && patched && api.select_schema(session, "inkflow_pinyin") != 0
        if loaded {
            candidateCount = requestedCount
            appliedPhrases = requestedPhrases
        }
        let restoredCount = hadValue ? api.config_set_int(&config, "menu/page_size", previous)
                                    : api.config_clear(&config, "menu/page_size")
        let restoredDictionary = previousDictionary.map { value in
            value.withCString { api.config_set_string(&config, "custom_phrase/user_dict", $0) }
        } ?? api.config_clear(&config, "custom_phrase/user_dict")
        let closed = api.config_close(&config)
        api.set_option(session, "ascii_mode", ascii)
        guard restoredCount != 0, restoredDictionary != 0, closed != 0 else {
            throw CustomPhraseError("恢复临时输入方案配置失败，请重启墨流后重试。")
        }
        guard loaded else { throw CustomPhraseError("无法应用输入设置，请重启墨流后重试。") }
    }

    private func reportConfigurationError(_ message: String) {
        if configurationError != message { NSLog("InkFlow input settings: %@", message) }
        configurationError = message
    }

    @discardableResult
    func event(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        if event.keyCode == 49, flags.contains([.control, .shift]), flags.intersection([.command, .option]).isEmpty {
            commit()
            let ascii = Self.api.pointee.get_option(session, "ascii_mode")
            Self.api.pointee.set_option(session, "ascii_mode", ascii == 0 ? 1 : 0)
            return true
        }
        guard flags.intersection([.command, .control, .option]).isEmpty else { return false }
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
                  let character = characters.utf16.first, character <= 127 else { return false }
            key = Int32(character)
        }
        return self.key(key, modifiers: flags.contains(.shift) ? 1 : 0)
    }

    func select(_ index: Int) {
        guard candidateOrder.indices.contains(index) else { return }
        _ = Self.api.pointee.select_candidate_on_current_page(session, candidateOrder[index])
        updateOrdering()
    }

    func highlight(_ index: Int) {
        guard candidateOrder.indices.contains(index) else { return }
        _ = Self.api.pointee.highlight_candidate_on_current_page(session, candidateOrder[index])
        // Highlighting a partial choice can change Rime's preedit and cursor.
        // Record the new content without overriding explicit user navigation.
        orderedContent = content(of: rawSnapshot())
    }

    func commit() {
        _ = Self.api.pointee.commit_composition(session)
        updateOrdering()
    }

    func clear() {
        Self.api.pointee.clear_composition(session)
        updateOrdering()
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

    func takeCommit() -> String {
        let text = bufferedCommit + readCommit()
        bufferedCommit = ""
        return text
    }

    private func readCommit() -> String {
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

    private func rawSnapshot() -> EngineSnapshot {
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
