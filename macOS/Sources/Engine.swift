import AppKit

struct EngineSnapshot: Equatable {
    var preedit = ""
    var cursor = 0
    var candidates: [String] = []
    var page = 0
    var highlight = 0
}

/// librime and its shared schema configuration are accessed synchronously on the main actor.
@MainActor
final class IFEngine {
    private static let api = rime_get_api()!
    private static var ready = false
    private var session: RimeSessionId = 0
    private(set) var candidateCount = 5
    private var requestedCount = 5

    static var version: String { string(api.pointee.get_version()) }

    static func start(shared: String, user: String) throws {
        if ready { return }
        for name in ["default.yaml", "inkflow_pinyin.schema.yaml", "pinyin_simp.dict.yaml",
                     "easy_en.schema.yaml", "easy_en.dict.yaml",
                     "inkflow_mixed.schema.yaml", "inkflow_mixed.dict.yaml",
                     "lua/inkflow_english.lua", "lua/inkflow_mixed.lua"] {
            guard FileManager.default.isReadableFile(atPath: (shared as NSString).appendingPathComponent(name)) else {
                throw NSError(domain: "io.damao.inputmethod.inkflow", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "InkFlow 缺少内置词典资源，请重新构建并安装。"])
            }
        }
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
    }

    static func stop() {
        if ready { api.pointee.finalize(); ready = false }
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
        applyCandidateCountIfIdle()
        return Self.api.pointee.process_key(session, key, modifiers) != 0
    }

    func setCandidateCount(_ count: Int) {
        requestedCount = (3...9).contains(count) ? count : 5
        applyCandidateCountIfIdle()
    }

    private func applyCandidateCountIfIdle() {
        guard candidateCount != requestedCount, snapshot().preedit.isEmpty else { return }
        // Temporarily patch the shared in-memory config while creating this session's schema.
        // Restore it without writing/deploying or reloading a composing session.
        let api = Self.api.pointee
        var config = RimeConfig()
        guard api.schema_open("inkflow_pinyin", &config) != 0 else {
            NSLog("Cannot open candidate configuration")
            return
        }
        var previous: Int32 = 5
        let hadValue = api.config_get_int(&config, "menu/page_size", &previous) != 0
        let ascii = api.get_option(session, "ascii_mode")
        let changed = api.config_set_int(&config, "menu/page_size", Int32(requestedCount)) != 0
        if changed && api.select_schema(session, "inkflow_pinyin") != 0 { candidateCount = requestedCount }
        else { NSLog("Cannot apply candidate count") }
        if hadValue { _ = api.config_set_int(&config, "menu/page_size", previous) }
        else { _ = api.config_clear(&config, "menu/page_size") }
        _ = api.config_close(&config)
        api.set_option(session, "ascii_mode", ascii)
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

    func select(_ index: Int) { _ = Self.api.pointee.select_candidate_on_current_page(session, index) }
    func commit() { _ = Self.api.pointee.commit_composition(session) }
    func clear() { Self.api.pointee.clear_composition(session) }

    func takeCommit() -> String {
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
                              highlight: Int(context.menu.highlighted_candidate_index))
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
