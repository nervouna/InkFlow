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
        try IFEngine.start(shared: shared, user: user)
        let schemaURL = URL(fileURLWithPath: user).appendingPathComponent("build/inkflow_pinyin.schema.yaml")
        let schemaBefore = try Data(contentsOf: schemaURL)
        try runCases()
        try rankingRules()
        IFEngine.stop()
        let schemaAfter = try Data(contentsOf: schemaURL)
        check(schemaAfter == schemaBefore)
        print("PASS engine: Chinese, sessions, edit, cancel, paging, number/space selection, English toggle, shortcut passthrough, deferred 3/9 paging, digit 9, existing/new session isolation, UTF-16 cursor")
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
        contextReranking()
    }

    @MainActor static func contextReranking() {
        func prepared(_ prefix: String = "准备午", _ input: String = "can") -> IFEngine {
            let engine = IFEngine()!
            engine.setPrecedingText(prefix); type(engine, input)
            return engine
        }
        for (prefix, input, expected) in [("准备午", "can", "餐"), ("正式宣", "bu", "布"),
                                           ("最新软", "jian", "件"), ("非常感", "xie", "谢")] {
            let engine = prepared(prefix, input)
            check(engine.snapshot().candidates.first == expected, "Bundled dictionary context \(prefix) + \(input)")
            check(engine.snapshot().highlight == 0)
            check(engine.key(32)); check(engine.takeCommit() == expected)
        }
        for count in [3, 5, 9] {
            let engine = IFEngine()!; engine.setCandidateCount(count); type(engine, "can")
            let original = engine.snapshot().candidates
            engine.setPrecedingText("准备午")
            let ranked = engine.snapshot()
            check(ranked.candidates.first == "餐" && ranked.candidates.count == count)
            check(Set(ranked.candidates) == Set(original))
            check(ranked.candidates.dropFirst() == original.filter { $0 != "餐" }[...])
            check(engine.snapshot() == ranked, "Snapshot reads must be side-effect free")
            check(engine.key(0xff54)); check(engine.snapshot().highlight == 1)
            engine.setPrecedingText("准备午"); check(engine.snapshot().highlight == 1)
            check(engine.key(32)); check(engine.takeCommit() == ranked.candidates[1])
        }
        for prefix in ["", "完全无关", "准备午，", "准备午 ", "准备午\n", "准备午😀"] {
            let baseline = prepared(""), engine = prepared(prefix)
            check(engine.snapshot().candidates == baseline.snapshot().candidates)
        }
        for index in 0..<5 {
            for digit in [false, true] {
                let engine = prepared(), expected = engine.snapshot().candidates[index]
                if digit { check(engine.key(Int32(49 + index))) } else { engine.select(index) }
                check(engine.takeCommit() == expected && engine.snapshot().preedit.isEmpty)
            }
        }
        for action in ["commit", "space", "comma", "toggle", "return"] {
            let engine = prepared()
            switch action {
            case "commit": engine.commit()
            case "space": check(engine.key(32))
            case "comma": check(engine.key(44))
            case "toggle": check(engine.event(keyEvent(49, " ", [.control, .shift])))
            default: check(engine.key(0xff0d))
            }
            check(engine.takeCommit() == (action == "comma" ? "餐，" : action == "return" ? "can" : "餐"))
            check(engine.snapshot().preedit.isEmpty)
        }
        let engine = prepared("正式宣", "bu")
        let first = engine.snapshot().candidates
        check(engine.key(0xff56)); check(engine.snapshot().page == 1)
        let second = engine.snapshot().candidates
        check(second != first)
        check(engine.key(0xff55)); check(engine.snapshot().candidates == first)
        engine.highlight(first.count - 1); check(engine.key(0xff54))
        check(engine.snapshot().page == 1 && engine.snapshot().highlight == 0)
        check(engine.key(0xff52)); check(engine.snapshot().page == 0 && engine.snapshot().highlight == first.count - 1)
        engine.clear(); type(engine, "can")
        check(engine.snapshot().candidates == prepared("").snapshot().candidates, "Clearing must discard the old prefix")
        engine.setPrecedingText("准备午"); check(engine.snapshot().candidates.first == "餐")
        check(engine.key(0xff08)); check(engine.snapshot().preedit == "ca")
        check(engine.key(0xff1b)); check(engine.snapshot().preedit.isEmpty)
        let partial = prepared("迷", "nihao"), plain = prepared("", "nihao")
        check(partial.snapshot().candidates == plain.snapshot().candidates, "Do not promote the shorter 你 through 迷你")
        let index = partial.snapshot().candidates.firstIndex(of: "你")!
        partial.select(index); plain.select(index)
        check(partial.takeCommit().isEmpty && !partial.snapshot().preedit.isEmpty)
        check(partial.snapshot().hasSelectedPrefix)
        check(partial.snapshot().candidates == plain.snapshot().candidates)
        partial.select(0); check(partial.takeCommit() == "你好")
        let internalPrefix = prepared("正式宣", "ni'bu"), internalPlain = prepared("", "ni'bu")
        let ni = internalPrefix.snapshot().candidates.firstIndex(of: "你")!
        internalPrefix.select(ni); internalPlain.select(ni)
        check(internalPrefix.snapshot().hasSelectedPrefix)
        check(internalPrefix.snapshot().candidates == internalPlain.snapshot().candidates, "Do not match 宣布 across a selected 你 segment")
        let expectedRemaining = "你" + internalPlain.snapshot().candidates[0]
        internalPrefix.select(0); internalPlain.select(0)
        check(internalPrefix.takeCommit() == expectedRemaining && internalPlain.takeCommit() == expectedRemaining)
        check(internalPrefix.snapshot().preedit.isEmpty && internalPlain.snapshot().preedit.isEmpty)
        print("PASS context engine: real phrases, 3/5/9 pages, stable fallback, digits/click/default/arrow mappings, paging, raw Return, edit/cancel, partial selection, session isolation")
    }

    @MainActor static func rankingRules() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("ranking-fixture.yaml")
        defer { try? FileManager.default.removeItem(at: url) }
        try "午餐\twu can\t100\n午参\twu can\t100\n午惨\twu can\t50\n准备午参\tzhun bei wu can\t1\n迷你\tmi ni\t70\n".write(to: url, atomically: true, encoding: .utf8)
        let ranker = try IFContextRanker(dictionary: url.path)
        check(ranker.order(["惨", "餐", "参"], precedingText: "准备午") == [2, 1, 0], "Longer crossing phrases precede frequency")
        check(ranker.order(["惨", "餐", "参"], precedingText: "午") == [1, 2, 0], "Frequency then stable original order")
        check(ranker.order(["你好", "你"], precedingText: "迷") == [0, 1], "Unequal-length choices remain in the native relative order")
        print("PASS context ranking rules: longer match, frequency, stable ties, partial length guard")
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
