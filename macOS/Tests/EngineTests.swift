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
        try missingEnglishResources(shared: shared, user: user)
        try IFEngine.start(shared: shared, user: user)
        let schemaURL = URL(fileURLWithPath: user).appendingPathComponent("build/inkflow_pinyin.schema.yaml")
        let schemaBefore = try Data(contentsOf: schemaURL)
        mixedEnglishCandidates()
        englishCandidates()
        try runCases()
        IFEngine.stop()
        let schemaAfter = try Data(contentsOf: schemaURL)
        check(schemaAfter == schemaBefore)
        let files = try FileManager.default.contentsOfDirectory(atPath: user)
        check(files.contains("pinyin_simp.userdb"), "Keep the original Chinese user dictionary")
        check(!files.contains("inkflow_mixed.userdb") && !files.contains("easy_en.userdb"),
              "Supplemental translators must not create replacement user dictionaries")
        print("PASS engine: Chinese, sessions, edit, cancel, paging, number/space selection, English toggle, shortcut passthrough, deferred 3/9 paging, digit 9, existing/new session isolation, UTF-16 cursor")
    }

    @MainActor static func missingEnglishResources(shared: String, user: String) throws {
        for resource in ["inkflow_mixed.schema.yaml", "inkflow_mixed.dict.yaml",
                         "lua/inkflow_english.lua", "lua/inkflow_mixed.lua"] {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("inkflow-missing-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: shared), to: copy)
            defer { try? FileManager.default.removeItem(at: copy) }
            try FileManager.default.removeItem(at: copy.appendingPathComponent(resource))
            do {
                try IFEngine.start(shared: copy.path, user: user)
                check(false, "Missing \(resource) must fail before engine startup")
            } catch { check((error as NSError).code == 2) }
        }
    }

    @MainActor static func mixedEnglishCandidates() {
        let engine = IFEngine()!
        for (input, expected) in [
            ("niruguoxiangyaozhefenoffer", "你如果想要这份offer"),
            ("niruguoxiangyaozhefenofferkeyihuifuwo", "你如果想要这份offer可以回复我"),
            ("offerhenhao", "offer很好"),
            ("wofaleemail", "我发了email"),
            ("wofaleemails", "我发了emails"),
            ("wofaleEmail", "我发了Email"),
            ("womenquoffice", "我们去office"),
            ("zhefenoffer", "这份offer")
        ] {
            type(engine, input)
            check(engine.snapshot().candidates.first == expected,
                  "Mixed composition \(input): \(engine.snapshot().candidates)")
            engine.key(32)
            check(engine.takeCommit() == expected && engine.snapshot().preedit.isEmpty)
        }
        for (input, expected) in [("compute", "computer"), ("comm", "community")] {
            type(engine, input)
            let candidates = engine.snapshot().candidates
            check(candidates.first == expected, "Frequency before exactness/length for \(input): \(candidates)")
            if input == "compute" {
                var seen = candidates
                for _ in 0..<20 where !seen.contains("compute") {
                    let before = engine.snapshot().page
                    engine.key(0xff56)
                    if engine.snapshot().page == before { break }
                    seen += engine.snapshot().candidates
                }
                check(seen.contains("compute"), "Retain the lower-frequency exact English word")
                check(Set(seen).count == seen.count, "No duplicate English candidates across pages")
            }
            engine.clear()
        }
        type(engine, "zhefenoffes")
        engine.key(0xff08); type(engine, "r")
        check(engine.snapshot().candidates.first == "这份offer", "Edit mixed composition")
        engine.select(0)
        check(engine.takeCommit() == "这份offer")
        type(engine, "zhefenoffer")
        engine.key(0xff51); type(engine, "x"); engine.key(0xff08); engine.key(0xff57)
        check(engine.snapshot().candidates.first == "这份offer", "Move the cursor and edit inside mixed composition")
        engine.key(0xff1b)
        check(engine.snapshot().preedit.isEmpty && engine.takeCommit().isEmpty)
        for input in ["Hello", "email"] {
            type(engine, input)
            check(engine.snapshot().candidates.first == input, "Prefer an exact case match on equal source weights")
            engine.clear()
        }
        print("PASS mixed English: initial/internal/final words, adjacent boundaries, source-frequency completion ranking, exact retention, deduplication, edit/select")
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
    }

    @MainActor static func englishCandidates() {
        let engine = IFEngine()!
        for word in ["hello", "apple", "computer", "world", "email", "file", "code", "update", "Hello", "Apple"] {
            type(engine, word)
            let candidates = engine.snapshot().candidates
            guard let index = candidates.firstIndex(of: word) else {
                check(false, "Missing English candidate for \(word): \(candidates)"); return
            }
            engine.select(index)
            check(engine.takeCommit() == word && engine.snapshot().preedit.isEmpty)
        }
        type(engine, "comput")
        check(engine.snapshot().candidates.contains("computer"), "English prefix completion")
        let first = engine.snapshot().candidates
        check(engine.key(0xff56))
        let second = engine.snapshot()
        check(second.page == 1 && second.candidates != first, "Page through English completions")
        check(engine.key(49))
        check(engine.takeCommit() == second.candidates[0], "Digit selects on the current page")
        type(engine, "hellp")
        check(engine.key(0xff08)); type(engine, "o")
        check(engine.snapshot().candidates.contains("hello"), "Backspace edits English composition")
        check(engine.key(0xff1b))
        check(engine.snapshot().preedit.isEmpty && engine.takeCommit().isEmpty)
        engine.clear()
        type(engine, "hello ")
        check(engine.takeCommit() == "hello", "Space selects the complete English word")
        for (input, expected) in [("nihao", "你好"), ("zhongguo", "中国"), ("shi", "是"), ("xi'an", "西安"),
                                  ("woqubeijing", "我去北京"), ("womendouhenhao", "我们都很好"),
                                  ("niruguoxiangyaozhefenwenjian", "你如果想要这份文件"),
                                  ("woxiangyaoxuexizhongwen", "我想要学习中文"),
                                  ("jintiantianqihenhao", "今天天气很好"), ("wohenkaixin", "我很开心"),
                                  ("womenyihuiquchifan", "我们一会去吃饭"),
                                  ("woxiangyaoyifenwancan", "我想要一份晚餐"),
                                  ("wozaibeijinggongzuo", "我在北京工作"), ("xianzaiwoyaohuijiale", "现在我要回家了")] {
            type(engine, input)
            check(engine.snapshot().candidates.first == expected, "Preserve Pinyin priority for \(input): \(engine.snapshot().candidates)")
            engine.clear()
        }
        let toggle = keyEvent(49, " ", [.control, .shift])
        check(engine.event(toggle))
        for letter in "hello".utf16 { check(!engine.key(Int32(letter))) }
        check(engine.snapshot().candidates.isEmpty && engine.takeCommit().isEmpty)
        print("PASS English candidates: common words, case, prefix completion, paging/digit/space selection, edit/cancel, Chinese priority, ASCII passthrough")
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
