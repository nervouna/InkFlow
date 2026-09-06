import AppKit

@main
struct EngineTests {
    @MainActor static func main() throws {
        check(CommandLine.arguments.count == 3)
        let shared = CommandLine.arguments[1], user = CommandLine.arguments[2]
        do {
            try IFEngine.start(shared: "/nonexistent/inkflow", user: user)
            check(false, "Missing resources must fail")
        } catch { check(!(error as NSError).localizedDescription.isEmpty) }
        try missingEmojiResources(shared: shared, user: user)
        try IFEngine.start(shared: shared, user: user)
        let schemaURL = URL(fileURLWithPath: user).appendingPathComponent("build/inkflow_pinyin.schema.yaml")
        let schemaBefore = try Data(contentsOf: schemaURL)
        spellingCorrection()
        try runCases()
        IFEngine.stop()
        let schemaAfter = try Data(contentsOf: schemaURL)
        check(schemaAfter == schemaBefore)
        print("PASS engine: Chinese, sessions, edit, cancel, paging, number/space selection, English toggle, shortcut passthrough, deferred 3/9 paging, digit 9, existing/new session isolation, UTF-16 cursor")
    }

    @MainActor static func missingEmojiResources(shared: String, user: String) throws {
        let directory = URL(fileURLWithPath: user).appendingPathComponent("incomplete-resources")
        let files = FileManager.default
        try files.createDirectory(at: directory.appendingPathComponent("opencc"), withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        for name in ["default.yaml", "inkflow_pinyin.schema.yaml", "pinyin_simp.dict.yaml",
                     "opencc/inkflow_emoji.json", "opencc/emoji.txt"] {
            try files.createSymbolicLink(at: directory.appendingPathComponent(name),
                                         withDestinationURL: URL(fileURLWithPath: shared).appendingPathComponent(name))
        }
        for name in ["opencc/inkflow_emoji.json", "opencc/emoji.txt"] {
            let link = directory.appendingPathComponent(name)
            try files.removeItem(at: link)
            do {
                try IFEngine.start(shared: directory.path, user: user)
                check(false, "Missing \(name) must fail before engine initialization")
            } catch { check((error as NSError).code == 2) }
            try files.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: shared).appendingPathComponent(name))
        }
    }

    @MainActor static func spellingCorrection() {
        let cases = [("hzidao", "知道"), ("nnihao", "你好"), ("hcuqu", "出去"),
                     ("hsuru", "输入"), ("ppinyin", "拼音"), ("nnihhao", "你好"),
                     ("zhognguo", "中国"), ("beijign", "北京"), ("nihoa", "你好"),
                     ("tainqi", "天气"), ("xaingxin", "相信"), ("xaiwu", "下午")]
        for (input, expected) in cases {
            let engine = IFEngine()!
            type(engine, input)
            let state = engine.snapshot()
            check(state.candidates.first == expected, "\(input): \(state)")
            check(engine.takeCommit().isEmpty, "Correction must stay in composition")
            check(state.preedit.replacingOccurrences(of: " ", with: "") == input)
            check(state.cursor == state.preedit.utf16.count)
            check(engine.key(32))
            check(engine.takeCommit() == expected)
            check(engine.snapshot().preedit.isEmpty)
        }
        for (input, expected) in [("nihao", "你好"), ("zhidao", "知道"), ("shanghai", "上海"),
                                  ("jinnian", "今年"), ("nannv", "男女"), ("tiananmen", "天安门"),
                                  ("xi'an", "西安")] {
            let engine = IFEngine()!
            type(engine, input)
            check(engine.snapshot().candidates.first == expected, "Normal spelling \(input): \(engine.snapshot())")
            engine.clear()
        }
        let engine = IFEngine()!
        type(engine, "nnihao")
        check(engine.event(keyEvent(51, "")))
        check(engine.snapshot().preedit.replacingOccurrences(of: " ", with: "") == "nniha")
        type(engine, "o")
        check(engine.snapshot().candidates.first == "你好")
        check(engine.event(keyEvent(115, ""))) // Home, then remove the extra initial.
        check(engine.snapshot().cursor == 0)
        check(engine.event(keyEvent(117, "")))
        check(engine.snapshot().preedit.replacingOccurrences(of: " ", with: "") == "nihao")
        check(engine.snapshot().candidates.first == "你好")
        check(engine.event(keyEvent(119, "")))
        check(engine.snapshot().cursor == engine.snapshot().preedit.utf16.count)
        check(engine.event(keyEvent(53, "")))
        check(engine.snapshot().preedit.isEmpty && engine.takeCommit().isEmpty)
        type(engine, "hzidao")
        engine.select(0)
        check(engine.takeCommit() == "知道" && engine.snapshot().preedit.isEmpty)
        let toggle = keyEvent(49, " ", [.control, .shift])
        check(engine.event(toggle))
        for code in "nnihao".utf16 { check(!engine.key(Int32(code))) }
        check(engine.snapshot().preedit.isEmpty && engine.takeCommit().isEmpty)
        print("PASS spelling correction: 12 typo phrases, normal spelling/boundaries, editable preedit, selection, cancel, ASCII passthrough")
    }

    @MainActor static func runCases() throws {
        let a = IFEngine()!, b = IFEngine()!
        type(a, "nihao"); check(a.snapshot().candidates.contains("你好"))
        check(b.snapshot().preedit.isEmpty)
        a.select(0); check(a.takeCommit() == "你好")
        type(a, "zhongguo"); check(a.snapshot().candidates.contains("中国"))
        a.key(0xff1b); check(a.snapshot().preedit.isEmpty)
        type(a, "ni"); a.key(0xff08); check(a.snapshot().preedit == "n")
        a.clear(); type(a, "ni")
        check(a.event(keyEvent(51, "\u{8}"))); check(a.snapshot().preedit == "n")
        check(a.event(keyEvent(53, "\u{1b}"))); check(a.snapshot().preedit.isEmpty)
        a.clear(); type(a, "shi"); let first = a.snapshot().candidates
        check(first.count == 5)
        a.event(keyEvent(121, "")); check(a.snapshot().page == 1)
        var second = a.snapshot().candidates; check(second.count == 5 && second != first)
        a.event(keyEvent(116, "")); check(a.snapshot().page == 0 && a.snapshot().candidates == first)
        a.event(keyEvent(19, "2")); check(a.takeCommit() == first[1])
        type(a, "shi"); a.event(keyEvent(121, ""))
        second = a.snapshot().candidates; check(second.count == 5)
        a.event(keyEvent(23, "5")); check(a.takeCommit() == second[4])
        type(a, "nihao"); a.key(32); check(a.takeCommit() == "你好")
        let toggle = keyEvent(49, " ", [.control, .shift])
        check(a.event(toggle)); check(!a.key(97))
        check(a.event(toggle)); type(a, "nihao"); a.commit(); check(a.takeCommit() == "你好")
        check(!a.event(keyEvent(0, "a", .command)))
        a.clear(); type(a, "shi"); let before = a.snapshot()
        a.setCandidateCount(9); check(a.snapshot() == before && a.takeCommit().isEmpty)
        a.clear(); type(a, "shi"); check(a.snapshot().candidates.count == 9)
        a.event(keyEvent(121, "")); let nine = a.snapshot().candidates; check(nine.count == 9)
        a.event(keyEvent(25, "9")); check(a.takeCommit() == nine[8])
        do {
            let fresh = IFEngine()!; type(fresh, "shi"); check(fresh.snapshot().candidates.count == 5)
            fresh.clear(); fresh.setCandidateCount(9); type(fresh, "shi")
            check(fresh.snapshot().candidates.count == 9)
        }
        b.clear(); type(b, "shi"); check(b.snapshot().candidates.count == 5)
        a.setCandidateCount(3); type(a, "shi"); check(a.snapshot().candidates.count == 3)
        check(IFEngine.utf16Cursor(in: "你😀a", byteOffset: 3) == 1)
        check(IFEngine.utf16Cursor(in: "你😀a", byteOffset: 7) == 3)
        check(IFEngine.utf16Cursor(in: "你😀a", byteOffset: 100) == 4)
        check(IFEngine.utf16Cursor(in: "你😀a", byteOffset: -1) == 0)
        check(IFEngine.utf16Cursor(in: "你😀a", byteOffset: 4) == 0)
        punctuation()
        emojiCandidates()
    }

    @MainActor static func emojiCandidates() {
        let cases = [("weixiao", "微笑", "😊"), ("kafei", "咖啡", "☕"),
                     ("aixin", "爱心", "❤️"), ("zhongguo", "中国", "🇨🇳"),
                     ("yisheng", "医生", "👨‍⚕️")]
        for (input, word, emoji) in cases {
            let engine = IFEngine()!
            type(engine, input)
            var seen: [String] = []
            var selected = false
            for _ in 0..<10 {
                let state = engine.snapshot()
                seen += state.candidates
                if let index = state.candidates.firstIndex(of: emoji) {
                    check(seen.contains(word), "Chinese candidate must precede \(emoji)")
                    check(Set(seen).count == seen.count, "Candidates must be unique")
                    engine.select(index)
                    check(engine.takeCommit() == emoji, "Commit complete emoji sequence for \(input)")
                    check(engine.snapshot().preedit.isEmpty && engine.takeCommit().isEmpty)
                    selected = true
                    break
                }
                engine.key(0xff56)
                if engine.snapshot().page == state.page { break }
            }
            check(selected, "Missing emoji candidate for \(input): \(emoji)")
        }
        for count in [3, 5, 9] {
            let engine = IFEngine()!
            engine.setCandidateCount(count)
            type(engine, "nihao")
            let first = engine.snapshot().candidates
            check(first.first == "你好")
            check(first.contains("👋"), "Emoji must survive page-size schema reload")
            engine.key(32); check(engine.takeCommit() == "你好")
            type(engine, "nihao")
            let index = engine.snapshot().candidates.firstIndex(of: "👋")!
            engine.key(Int32(49 + index)); check(engine.takeCommit() == "👋")
            type(engine, "nihao")
            for _ in 0..<index { engine.key(0xff54) }
            engine.key(32); check(engine.takeCommit() == "👋")
            type(engine, "nihao"); engine.key(0xff56)
            check(engine.snapshot().page == 1)
            engine.key(0xff55); check(engine.snapshot().candidates == first)
            engine.key(0xff1b); check(engine.snapshot().preedit.isEmpty && engine.takeCommit().isEmpty)
            check(engine.event(keyEvent(49, " ", [.control, .shift])))
            for key in "nihao".utf8 { check(!engine.key(Int32(key))) }
            check(engine.snapshot().candidates.isEmpty && engine.takeCommit().isEmpty)
        }
        print("PASS emoji: simplified keywords, original words preserved, unique candidates, full Unicode commits, digit/space selection, 3/5/9 paging, cancel, English passthrough")
    }

    @MainActor static func punctuation() {
        let cases: [(String, String, UInt16, Bool)] = [
            ("{", "「", 33, true), ("}", "」", 30, true), ("[", "【", 33, false), ("]", "】", 30, false),
            ("<", "《", 43, true), (">", "》", 47, true), ("\\", "、", 42, false), ("|", "｜", 42, true),
            ("`", "·", 50, false), ("~", "～", 50, true), ("$", "¥", 21, true), ("^", "……", 22, true),
            ("_", "——", 27, true), (",", "，", 43, false), (".", "。", 47, false), (";", "；", 41, false),
            (":", "：", 41, true), ("!", "！", 18, true), ("?", "？", 44, true), ("(", "（", 25, true), (")", "）", 29, true)
        ]
        let toggle = keyEvent(49, " ", [.control, .shift])
        for (input, expected, code, shifted) in cases {
            let engine = IFEngine()!
            let key = keyEvent(code, input, shifted ? .shift : [])
            check(engine.event(key)); check(engine.takeCommit() == expected)
            check(engine.snapshot().preedit.isEmpty)
            check(engine.event(toggle)); check(!engine.event(key)); check(engine.takeCommit().isEmpty)
        }
        for (input, expected) in [("\"\"\"\"", "“”“”"), ("''''", "‘’‘’"), ("\"'\"'", "“‘”’")] {
            let engine = IFEngine()!
            for (quote, output) in zip(input, expected) {
                check(engine.event(keyEvent(39, String(quote), quote == "\"" ? .shift : [])))
                check(engine.takeCommit() == String(output)); check(engine.snapshot().preedit.isEmpty)
            }
            check(engine.event(toggle))
            check(!engine.event(keyEvent(39, "\"", .shift)))
            check(!engine.event(keyEvent(39, "'"))); check(engine.takeCommit().isEmpty)
        }
        let engine = IFEngine()!
        type(engine, "xi'an "); check(engine.takeCommit() == "西安")
        check(engine.event(keyEvent(39, "\"", .shift))); check(engine.takeCommit() == "“")
        type(engine, "xi'an "); check(engine.takeCommit() == "西安")
        check(engine.event(keyEvent(39, "\"", .shift))); check(engine.takeCommit() == "”")
        type(engine, "shi"); let first = engine.snapshot().candidates
        check(engine.event(keyEvent(30, "]"))); check(engine.snapshot().page == 1)
        check(engine.takeCommit().isEmpty)
        check(engine.event(keyEvent(33, "["))); check(engine.snapshot().candidates == first)
        check(engine.takeCommit().isEmpty); engine.clear()
        check(engine.event(keyEvent(33, "["))); check(engine.takeCommit() == "【")
        for text in ["@", "#", "%", "&", "*", "-", "=", "+", "/"] {
            check(!engine.event(keyEvent(0, text))); check(engine.takeCommit().isEmpty)
        }
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option] {
            check(!engine.event(keyEvent(22, "^", [modifier, .shift])))
            check(engine.takeCommit().isEmpty)
        }
        for input in ["3.14", "10:30"] {
            let numbers = IFEngine()!; var document = ""
            for code in input.utf16 {
                let handled = numbers.key(Int32(code))
                document += numbers.takeCommit()
                if !handled { document += String(UnicodeScalar(code)!) }
            }
            check(document == input && numbers.snapshot().preedit.isEmpty)
        }
        print("PASS punctuation: exact mappings, Shift, independent quotes, apostrophe delimiter, bracket paging, ASCII/shortcut passthrough, decimal/time input")
    }
}
