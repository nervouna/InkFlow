import Foundation
@testable import InkFlowDomain
@testable import InkFlowRime
import InkFlowCoreTestSupport

package enum EngineRegression {
    // Event modifiers: Shift = 1, Command = 2, Control = 4, Option = 8.
    // macOS uses native metadata; standalone Core uses the equivalent Rime key.
    package typealias Event = @MainActor (IFEngine, Int32, UInt16, String, Int32) -> Bool

    @MainActor package static func rimeEvent(_ engine: IFEngine, _ key: Int32, _ code: UInt16,
                                            _ text: String, _ modifiers: Int32) -> Bool {
        engine.input(key, modifiers: modifiers & 1)
    }

    @MainActor package static func inputSettings(
        user: String, event: Event = rimeEvent,
        updatePreferences: ((InputPreferences) -> InputPreferences)? = nil
    ) throws {
        func configure(_ engine: IFEngine, _ preferences: InputPreferences) {
            engine.setConfiguration(candidateCount: 9, customPhrases: [], inputPreferences: preferences)
            check(engine.configurationError == nil)
        }
        func contains(_ engine: IFEngine, _ input: String, _ expected: String, limit: Int = 100) -> Bool {
            engine.clear(); type(engine, input)
            for _ in 0..<limit {
                let before = engine.snapshot()
                if before.candidates.contains(expected) { return true }
                engine.key(0xff56)
                if before.page == engine.snapshot().page { break }
            }
            return false
        }
        let engine = IFEngine()!, defaults = InputPreferences()
        let spelling: [InputOption] = [.abbreviation, .typoTolerance, .fuzzyZ, .fuzzyC, .fuzzyS]
        for mask in 0..<32 {
            engine.clear()
            let profile = InputPreferences(Dictionary(uniqueKeysWithValues: spelling.enumerated().map {
                ($0.element, mask & (1 << $0.offset) != 0)
            }))
            configure(engine, profile)
            check(contains(engine, "nihao", "你好"), "Every compiled spelling profile decodes: \(mask)")
            for (input, expected) in [("xianzaiwomenlai", "现在我们来"), ("womenlia", "我们俩")] {
                engine.clear(); type(engine, input)
                check(engine.snapshot().candidates.first == expected,
                      "Legal full syllables survive every profile: \(mask), \(input): \(engine.snapshot())")
                check(!engine.snapshot().preedit.contains("~"), "Compile-time spelling markers never reach preedit")
            }
        }
        engine.clear()
        configure(engine, defaults)
        for input in ["hlw", "hulw", "hlianw", "hulianwang"] {
            check(contains(engine, input, "互联网"), "Abbreviation recall: \(input)")
        }
        check(contains(engine, "bs", "不是"), "Initial abbreviation recall")
        check(contains(engine, "zhguo", "中国"), "Two-letter initial abbreviation")
        engine.clear()
        let exact = defaults.setting(.abbreviation, to: false).setting(.typoTolerance, to: false)
        configure(engine, exact)
        check(!contains(engine, "hlw", "互联网"), "Abbreviation OFF")
        for (option, input, output, reverse, reverseOutput) in [
            (InputOption.fuzzyZ, "zongguo", "中国", "zhiran", "自然"),
            (.fuzzyC, "canpin", "产品", "changuan", "参观"),
            (.fuzzyS, "sanghai", "上海", "shenlin", "森林")
        ] {
            engine.clear(); configure(engine, exact)
            check(!contains(engine, input, output), "Fuzzy OFF: \(input)")
            engine.clear(); configure(engine, exact.setting(option, to: true))
            check(contains(engine, input, output), "Fuzzy ON: \(input)")
            check(contains(engine, reverse, reverseOutput), "Fuzzy reverse: \(reverse)")
            for (other, spelling, text) in [(InputOption.fuzzyZ, "zongguo", "中国"), (.fuzzyC, "canpin", "产品"), (.fuzzyS, "sanghai", "上海")] where other != option {
                check(!contains(engine, spelling, text), "Fuzzy pairs remain independent")
            }
        }
        engine.clear(); configure(engine, exact)
        check(!contains(engine, "nnihao", "你好"), "Typo OFF")
        engine.clear(); configure(engine, exact.setting(.typoTolerance, to: true))
        check(contains(engine, "nnihao", "你好") && contains(engine, "hzidao", "知道"), "Typo examples are independent of fuzzy pairs")
        engine.clear(); configure(engine, defaults)
        type(engine, "hulianwang")
        let before = engine.snapshot(), revision = engine.qualityRevision.id
        let traditional = defaults.setting(.traditional, to: true).setting(.emoji, to: false)
        engine.setConfiguration(candidateCount: 9, customPhrases: [], inputPreferences: traditional)
        check(engine.snapshot() == before && engine.qualityRevision.id == revision && engine.takeCommit().isEmpty,
              "Pending options must preserve the composing snapshot and quality revision")
        engine.key(32)
        engine.setConfiguration(candidateCount: 9, customPhrases: [], inputPreferences: traditional)
        check(engine.takeCommit() == "互联网", "Settings reload must preserve a pending simplified commit")
        check(engine.qualityRevision.id != revision && engine.qualityRevision.configuration.inputOptions?["traditional"] == true)
        check(contains(engine, "hulianwang", "互聯網"), "Traditional next composition")
        engine.clear()
        let phrase = CustomPhrase(id: UUID(), code: "dz", text: "互联网发型😀")
        engine.setConfiguration(candidateCount: 9, customPhrases: [phrase], inputPreferences: traditional)
        type(engine, "dz"); engine.setPrecedingText("准备午")
        check(engine.snapshot().candidates.first == phrase.text, "Custom phrase remains verbatim under traditional/context")
        engine.select(0); check(engine.takeCommit() == phrase.text)
        engine.clear(); configure(engine, defaults.setting(.traditional, to: true))
        check(contains(engine, "weixiao", "😊"), "Traditional retains Emoji from simplified source")
        engine.clear(); configure(engine, traditional)
        check(!contains(engine, "weixiao", "😊"), "Emoji OFF")

        for (option, inputs, outputs) in [(InputOption.cornerQuotes, "{}", "「」"), (.middleDot, "`", "·"),
                                          (.fullwidthPipe, "|", "｜"), (.ideographicComma, "\\", "、")] {
            for enabled in [false, true] {
                engine.clear(); configure(engine, defaults.setting(option, to: enabled))
                for (input, output) in zip(inputs, enabled ? outputs : inputs) {
                    let handled = engine.key(Int32(input.asciiValue!))
                    let commit = engine.takeCommit()
                    check((handled ? commit : String(input)) == String(output), "Mapping \(option) = \(enabled)")
                }
            }
        }
        engine.clear(); configure(engine, defaults.setting(.englishPunctuation, to: true))
        for input in "{},.`|\\" {
            let handled = engine.key(Int32(input.asciiValue!)), output = engine.takeCommit()
            check((handled ? output : String(input)) == String(input), "English punctuation \(input)")
        }
        for (option, previous, next) in [(InputOption.bracketPaging, Int32(91), Int32(93)), (.minusEqualPaging, 45, 61)] {
            for enabled in [false, true] {
                engine.clear(); configure(engine, defaults.setting(option, to: enabled))
                type(engine, "shi"); engine.key(next)
                check(engine.snapshot().page == (enabled ? 1 : 0), "Independent paging \(option) = \(enabled)")
                if enabled { engine.key(previous); check(engine.snapshot().page == 0) }
                _ = engine.takeCommit()
            }
        }
        engine.clear(); configure(engine, defaults)
        type(engine, "nihao")
        let composing = engine.snapshot()
        check(!event(engine, -1, 49, " ", 5) && !engine.requestedASCIIMode,
              "The replaced Control-Shift-Space shortcut must pass through")
        engine.asciiMode = true
        check(engine.requestedASCIIMode && !engine.asciiMode && engine.snapshot() == composing && engine.takeCommit().isEmpty)
        engine.key(32); check(engine.takeCommit() == "你好")
        check(!engine.key(97) && engine.asciiMode, "ASCII starts only after the old composition finishes")
        for input in "{},.`|\\" { check(!engine.key(Int32(input.asciiValue!))) }
        check(engine.inputPreferences?[.englishPunctuation] == false)
        engine.asciiMode = false
        check(engine.key(44)); check(engine.takeCommit() == "，")

        engine.clear()
        let protectedPreferences = defaults.setting(.cornerQuotes, to: true)
        configure(engine, protectedPreferences)
        engine.asciiMode = true
        check(engine.asciiMode)
        for protected in ["user_id", "C++", "https://example.com/api/v1?x=1#top", "/Users/damao/InkFlow/config.yml", "v1.2.3-beta+4"] {
            var passthrough = ""
            for character in protected {
                let text = String(character)
                check(!event(engine, Int32(text.utf16.first!), 0, text, 0), "ASCII mode must pass through \(text)")
                passthrough += text
                check(engine.snapshot().candidates.isEmpty && engine.snapshot().preedit.isEmpty && engine.takeCommit().isEmpty,
                      "ASCII passthrough must not create candidates or converted punctuation")
            }
            check(Array(passthrough.utf8) == Array(protected.utf8), "ASCII mode must preserve bytes for \(protected)")
        }
        check(engine.inputPreferences == protectedPreferences, "ASCII mode must not overwrite saved Chinese punctuation")
        engine.asciiMode = false
        check(!engine.asciiMode)
        check(contains(engine, "nihao", "你好"), "Leaving ASCII mode restores Chinese candidates")
        engine.clear()
        check(engine.key(123)); check(engine.takeCommit() == "「", "Leaving ASCII mode restores saved Chinese punctuation")

        let retained = IFEngine()!
        type(retained, "hlw"); let retainedState = retained.snapshot()
        configure(retained, exact)
        configure(engine, exact)
        check(retained.snapshot() == retainedState, "Other live session keeps its composing prism/config")
        check(retained.inputPreferences == defaults && engine.inputPreferences == exact,
              "The same preference update applies independently at each session's boundary")
        retained.clear()
        check(!contains(retained, "hlw", "互联网"), "Deferred abbreviation OFF applies after cancellation")
        retained.clear()
        engine.clear(); configure(engine, defaults)
        let prism = URL(fileURLWithPath: user).appendingPathComponent("build/\(exact.spellingProfile).prism.bin")
        let hidden = prism.appendingPathExtension("test-backup")
        try FileManager.default.moveItem(at: prism, to: hidden)
        engine.setConfiguration(candidateCount: 9, customPhrases: [], inputPreferences: exact)
        let failed = engine.configurationError != nil && engine.inputPreferences == defaults
        try FileManager.default.moveItem(at: hidden, to: prism)
        check(failed, "Missing prism must not mark settings applied")
        configure(engine, exact)
        check(engine.inputPreferences == exact)

        var preferences = InputPreferences().setting(.abbreviation, to: false).setting(.typoTolerance, to: false)
        preferences = updatePreferences?(preferences) ?? preferences
        engine.clear(); configure(engine, preferences)
        type(engine, "shi")
        let groupedBefore = engine.snapshot(), groupedRevision = engine.qualityRevision.id
        let groupedOriginal = preferences
        preferences = preferences.setting(.fuzzyZ, to: true).setting(.fuzzyC, to: true).setting(.fuzzyS, to: true)
        preferences = preferences.setting(.bracketPaging, to: false).setting(.minusEqualPaging, to: true)
        preferences = updatePreferences?(preferences) ?? preferences
        let groupedUpdated = preferences
        configure(engine, groupedUpdated)
        retained.clear(); configure(retained, groupedUpdated)
        check(engine.snapshot() == groupedBefore && engine.inputPreferences == groupedOriginal &&
              engine.qualityRevision.id == groupedRevision && engine.takeCommit().isEmpty,
              "Grouped changes retain composing candidates, keys and recorded options")
        check(retained.inputPreferences == groupedUpdated &&
              retained.qualityRevision.configuration.inputOptions == groupedUpdated.recordedValues,
              "An idle session applies and records the complete grouped snapshot")
        engine.key(93); check(engine.snapshot().page == 1, "Composing session retains its previous bracket paging")
        engine.key(91); engine.key(32)
        check(engine.takeCommit() == groupedBefore.candidates[0], "Grouped changes preserve the selected displayed candidate")
        type(engine, "shi")
        check(engine.inputPreferences == groupedUpdated &&
              engine.qualityRevision.configuration.inputOptions == groupedUpdated.recordedValues,
              "Grouped options and recording apply at the next composition")
        engine.clear()
        for enabled in [true, false] {
            preferences = preferences.setting(.fuzzyZ, to: enabled).setting(.fuzzyC, to: enabled).setting(.fuzzyS, to: enabled)
            preferences = updatePreferences?(preferences) ?? preferences
            configure(engine, preferences)
            for (spelling, word) in [("zongguo", "中国"), ("canpin", "产品"), ("sanghai", "上海")] {
                check(contains(engine, spelling, word) == enabled, "Unified fuzzy setting: \(spelling) = \(enabled)")
            }
            engine.clear()
        }
        for brackets in [true, false] {
            preferences = preferences.setting(.bracketPaging, to: brackets).setting(.minusEqualPaging, to: !brackets)
            preferences = updatePreferences?(preferences) ?? preferences
            configure(engine, preferences)
            let previous: Int32 = brackets ? 91 : 45
            let next: Int32 = brackets ? 93 : 61
            let inactive: Int32 = brackets ? 61 : 93
            type(engine, "shi"); engine.key(next)
            check(engine.snapshot().page == 1, "Selected paging pair: \(brackets)")
            engine.key(previous); check(engine.snapshot().page == 0)
            engine.key(inactive)
            check(engine.snapshot().page == 0 && !engine.takeCommit().isEmpty, "Other paging pair retains punctuation behavior")
            engine.clear()
        }
        type(engine, "shi")
        preferences = preferences.setting(.fuzzyZ, to: true).setting(.fuzzyC, to: true).setting(.fuzzyS, to: true); preferences = preferences.setting(.bracketPaging, to: true).setting(.minusEqualPaging, to: false)
        preferences = updatePreferences?(preferences) ?? preferences
        configure(engine, preferences)
        engine.clear(); type(engine, "zongguo")
        check(engine.inputPreferences == preferences &&
              engine.qualityRevision.configuration.inputOptions == preferences.recordedValues,
              "Cancellation also applies and records complete grouped settings")
        print("PASS grouped input settings: three fuzzy pairs, exclusive paging, selected commit/cancel boundaries, session isolation and effective recorded values")
        print("PASS input settings: spelling recall/toggles, traditional/custom/Emoji, literal mappings, paging, deferred revisions/ASCII, session isolation and missing-prism recovery")
    }

    @MainActor package static func chineseDictionaryCoverage() {
        let engine = IFEngine()!
        for (input, expected) in [("xiehouyu", "歇后语"), ("suranqijing", "肃然起敬"),
                                  ("chuangqianmingyueguang", "床前明月光"), ("chunmianbujuexiao", "春眠不觉晓")] {
            type(engine, input)
            check(engine.snapshot().candidates.first == expected,
                  "Default Chinese dictionary \(input): \(engine.snapshot().candidates)")
            engine.key(0xff1b)
        }
        print("PASS expanded Chinese dictionary: default first candidates for common term, idiom and poems")
    }

    @MainActor package static func selectCandidate(_ expected: String, input: String, engine: IFEngine) {
        type(engine, input)
        for _ in 0..<1000 {
            let snapshot = engine.snapshot()
            if let index = snapshot.candidates.firstIndex(of: expected) {
                engine.select(index)
                check(engine.takeCommit() == expected, "Exact domain spelling/selection: \(input) -> \(expected)")
                check(engine.snapshot().preedit.isEmpty, "Domain candidate covers complete input")
                return
            }
            engine.key(0xff56)
            if engine.snapshot().page == snapshot.page { break }
        }
        check(false, "Missing domain candidate \(input) -> \(expected)")
    }

    @MainActor package static func domainVocabulary() throws {
        let engine = IFEngine()!
        let chinese = try String(contentsOfFile: "Core/config/chinese-overrides.tsv", encoding: .utf8)
        selectCandidate("命令行用户交互", input: "minglinghangyonghujiaohu", engine: engine)
        for line in chinese.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            check(fields.count == 4)
            selectCandidate(String(fields[0]), input: fields[1].replacingOccurrences(of: " ", with: ""), engine: engine)
        }
        selectCandidate("深度求索", input: "shenduqiusuo", engine: engine)
        selectCandidate("阿米诺斯", input: "aminuosi", engine: engine)
        selectCandidate("并发信息系统", input: "bingfaxinxixitong", engine: engine)
        let english = try String(contentsOfFile: "Core/Data/english-technology.tsv", encoding: .utf8)
        let rows = english.split(separator: "\n").filter { !$0.hasPrefix("#") }.map {
            $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
        check(!rows.isEmpty && rows.allSatisfy { $0.count == 3 && $0.allSatisfy { !$0.isEmpty } },
              "Technology source rows require display, ASCII lookup code and source")
        check(rows.allSatisfy { row in
            row[1].unicodeScalars.allSatisfy { (48...57).contains($0.value) || (97...122).contains($0.value) }
        }, "Technology lookup codes are lowercase ASCII letters and digits")
        check(Set(rows.map { $0[0] }).count == rows.count && Set(rows.map { $0[1] }).count == rows.count,
              "Technology display forms and lookup codes are unique")
        check(Set(rows.map { $0[2] }).isSubset(of: ["inkflow-maintained", "rime-ice-en-ext"]),
              "Technology rows use a declared spelling source")
        let source = Dictionary(uniqueKeysWithValues: rows.map { ($0[0], $0[1]) })
        for display in ["eBPF", "Type-C", "SwiftUI", "C++", "Claude Code", ".NET"] {
            guard let code = source[display] else {
                check(false, "Missing representative technology source row: \(display)"); return
            }
            selectCandidate(display, input: code, engine: engine)
            engine.key(0xff09)
        }
        selectCandidate("API", input: "Api", engine: engine) // Existing easy-en case alias remains available.
        engine.key(0xff09)
        type(engine, "swiftui")
        for prefix in ["swiftui", "swiftu", "swift", "swif", "swi", "sw"] {
            let candidates = allCandidates(engine)
            check(candidates.contains("SwiftUI") == (prefix.count >= 3), "Technology completion/backspace boundary: \(prefix)")
            engine.key(0xff08)
        }
        engine.clear()
        for (input, expected) in [("woAPI", "API"), ("APIhenhao", "API"),
                                  ("wocpp", "C++"), ("wotypec", "Type-C")] {
            type(engine, input)
            check(allCandidates(engine).contains { $0.contains(expected) },
                  "Selected personal ASCII run bypasses public mixed structural restrictions: \(input)")
            engine.clear()
        }
        for input in ["woapi", "apihenhao"] {
            type(engine, input)
            check(!allCandidates(engine).contains { $0.contains("API") },
                  "An unmarked normal Pinyin sequence is not personal English intent: \(input)")
            engine.clear()
        }
        type(engine, "claudecodehenhao")
        check(!allCandidates(engine).contains { $0.contains("Claude Code") },
              "A spaced personal phrase is not a single mixed ASCII run")
        engine.clear()
        engine.setConfiguration(candidateCount: 5, customPhrases: [CustomPhrase(id: UUID(), code: "api", text: "我的接口")])
        engine.setPrecedingText("调用")
        type(engine, "api")
        check(engine.snapshot().candidates.first == "我的接口" && allCandidates(engine).contains("API"),
              "Explicit custom phrases keep priority while technical English remains reachable")
        engine.clear()
        engine.setConfiguration(candidateCount: 5, customPhrases: [])
        print("PASS domain vocabulary: structured technology source plus representative case/punctuation/space goldens, aliases, prefix/backspace, mixed boundaries and custom phrase coexistence")
    }

    @MainActor package static func conservativeChinesePrefixes() {
        let engine = IFEngine()!
        var failures = 0
        var steps = 0
        let start = Date()
        func record(_ input: String, _ direction: String) {
            let candidates = engine.snapshot().candidates
            let first = candidates.first ?? ""
            let containsASCII = first.unicodeScalars.contains {
                (65...90).contains($0.value) || (97...122).contains($0.value)
            }
            let valid = !first.isEmpty && !containsASCII && (input != "d" || first == "的")
            if !valid {
                print("FAIL Chinese \(direction) \(input) => \(first)")
                failures += 1
            }
            steps += 1
        }
        for input in ["d", "niyebuxiangnid", "womenshenzh", "niyebuxiangnidepengyoushangxin",
                      "womenshenzhikeyizuodegenghao", "niruguoxiangyaozhefenwenjian",
                      "woxiangyaoxuexizhongwen", "jintiantianqihenhao", "womenyihuiquchifan",
                      "woxiangyaoyifenwancan", "xianzaiwoyaohuijiale",
                      "niyebuxiangnidepengyouzhidaoba", "womenshenzhimeiyoukaishixingdong",
                      "jintianwoyaohuijiashuijiao", "xianzaiwoyaofayifengyoujian",
                      "wozhebianyougewenjian", "mingtiankeyima", "wozaibeijinggongzuo",
                      "tamenkeyilaile", "ganshenme", "womanmanlai"] {
            var prefix = ""
            for letter in input {
                prefix.append(letter)
                type(engine, String(letter))
                record(prefix, "type")
            }
            while !prefix.isEmpty {
                engine.key(0xff08)
                prefix.removeLast()
                if !prefix.isEmpty { record(prefix, "backspace") }
            }
            check(engine.snapshot().preedit.isEmpty && engine.takeCommit().isEmpty)
        }
        check(failures == 0, "Chinese partial input must stay ahead of English across \(steps) steps")
        print("PASS conservative Chinese: short keys, incomplete syllables, \(steps) prefixes and backspaces in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }

    @MainActor package static func missingEnglishResources(shared: String, user: String) throws {
        for resource in ["inkflow_mixed.schema.yaml", "inkflow_mixed.dict.yaml",
                         "lua/inkflow_english.lua", "lua/inkflow_mixed.lua", "lua/inkflow_short_conflict.lua",
                         "lua/inkflow_ai_learning.lua", "lua/inkflow_input_coverage.lua", "lua/inkflow_channel.lua"] {
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

    @MainActor package static func mixedEnglishCandidates(event: Event = rimeEvent) {
        let engine = IFEngine()!
        // Before any mixed selection: selecting a mixed sentence teaches its words (see
        // mixedSelectionLearning). A learned sentence would lead its input, and a learned
        // spelling would lead its standalone English.
        for input in ["Hello", "email"] {
            type(engine, input)
            let english = engine.snapshot().candidates.filter { $0.unicodeScalars.allSatisfy { $0.value < 128 } }
            check(english.first == input, "Prefer an exact case match among English with equal source weights")
            engine.clear()
        }
        engine.clear()
        type(engine, "wofaleemail")
        let mixedCollision = engine.snapshot().candidates
        check(mixedCollision.first?.unicodeScalars.allSatisfy { $0.value > 127 } == true,
              "Complete Chinese coverage leads mixed English: \(mixedCollision)")
        engine.select(0)
        check(engine.takeCommit() == mixedCollision.first && engine.snapshot().preedit.isEmpty,
              "The leading Chinese candidate must consume the complete mixed input")
        type(engine, "wofaleemail")
        guard let emailIndex = engine.snapshot().candidates.firstIndex(of: "我发了email") else {
            check(false, "Keep colliding mixed email selectable: \(engine.snapshot().candidates)"); return
        }
        engine.select(emailIndex)
        check(engine.takeCommit() == "我发了email" && engine.snapshot().preedit.isEmpty)
        for (input, expected) in [
            ("niruguoxiangyaozhefenoffer", "你如果想要这份offer"),
            ("niruguoxiangyaozhefenofferkeyihuifuwo", "你如果想要这份offer可以回复我"),
            ("offerhenhao", "offer很好"),
            ("wofaleemails", "我发了emails"),
            ("wofaleEmail", "我发了Email"),
            ("woyongAPIkeyihuifuwo", "我用API可以回复我"),
            ("woyongSwiftUIhenhao", "我用SwiftUI很好"),
            ("banbenDkeyi", "版本D可以"),
            ("womenquoffice", "我们去office"),
            ("zhefenoffer", "这份offer")
        ] {
            // Abbreviation can add a full-coverage Chinese interpretation before this
            // mixed candidate. Preserve native coverage priority and exact selection.
            type(engine, input)
            engine.clear()
            selectCandidate(expected, input: input, engine: engine)
        }
        type(engine, "woyong")
        for (code, letter) in [(UInt16(0), "A"), (UInt16(35), "P"), (UInt16(34), "I")] {
            check(event(engine, Int32(letter.utf16.first!), code, letter, 1))
        }
        type(engine, "keyihuifuwo")
        check(engine.snapshot().candidates.contains("我用API可以回复我"),
              "Real Shift events must preserve uppercase mixed input and following Pinyin")
        for (suffix, complete) in [("keyihuifuw", false), ("keyihuifu", true), ("keyihuif", false),
                                   ("keyihui", true), ("keyihu", true), ("keyih", false), ("keyi", true)] {
            engine.key(0xff08)
            check(engine.qualitySnapshot().rawInput.hasSuffix(suffix),
                  "Uppercase mixed backspace boundary: \(engine.snapshot())")
            if complete {
                check(engine.snapshot().candidates.contains { $0.contains("API") },
                      "Uppercase mixed candidate survives complete-Pinyin backspace: \(engine.snapshot())")
            }
        }
        engine.clear()
        for (input, expected) in [("compute", "computer"), ("comm", "community"),
                                  ("actual", "actual"), ("cpp", "C++"), ("macos", "macOS"), ("deepseek", "DeepSeek")] {
            type(engine, input)
            let english = allCandidates(engine).filter { $0.unicodeScalars.allSatisfy { $0.value < 128 } }
            check(english.first == expected, "Exact English code before completions for \(input): \(english)")
            check(!english.contains("compute"), "Excluded exact words cannot bypass admission")
            if input == "actual" {
                check(english.dropFirst().contains("actually"), "Retain frequency-ordered completions after exact English")
            }
            check(Set(english).count == english.count, "No duplicate English candidates across pages")
            engine.clear()
        }
        // Standalone words typed with real Shift events reach the admitted lowercase code;
        // the entry spelled exactly as typed leads.
        let keyCodes: [Character: UInt16] = ["A": 0, "P": 35, "I": 34, "S": 1, "w": 13, "i": 34, "f": 3, "t": 17, "U": 32]
        for word in ["API", "SwiftUI"] {
            for letter in word {
                check(event(engine, Int32(letter.asciiValue!), keyCodes[letter]!, String(letter), letter.isUppercase ? 1 : 0),
                      "Handle Shift-typed standalone letter: \(word)")
            }
            check(engine.snapshot().candidates.first == word,
                  "Shift-typed technical word leads standalone: \(word) -> \(engine.snapshot().candidates)")
            engine.select(0)
            check(engine.takeCommit() == word && engine.snapshot().preedit.isEmpty,
                  "Select the Shift-typed technical word: \(word)")
        }
        type(engine, "zhefenoffes")
        engine.key(0xff08); type(engine, "r")
        let edited = engine.snapshot().candidates
        check(edited.contains("这份offer"), "Edit mixed composition: \(edited)")
        engine.select(edited.firstIndex(of: "这份offer")!)
        check(engine.takeCommit() == "这份offer")
        type(engine, "zhefenoffer")
        engine.key(0xff51); type(engine, "x"); engine.key(0xff08); engine.key(0xff57)
        check(engine.snapshot().candidates.contains("这份offer"), "Move the cursor and edit inside mixed composition")
        engine.key(0xff1b)
        check(engine.snapshot().preedit.isEmpty && engine.takeCommit().isEmpty)
        for input in ["can", "you", "she", "he", "man", "bug"] {
            type(engine, input)
            let snapshot = engine.snapshot()
            check(snapshot.candidates.first?.unicodeScalars.allSatisfy { $0.value > 127 } == true,
                  "Chinese leads ambiguous English \(input)")
            guard let index = snapshot.candidates.firstIndex(of: input) else {
                check(false, "Keep exact ambiguous English on the first page: \(input) -> \(snapshot.candidates)")
                engine.clear()
                continue
            }
            check(index < 3, "Keep exact ambiguous English in Top-3: \(input) -> \(snapshot.candidates)")
            engine.select(index)
            check(engine.takeCommit() == input && engine.snapshot().preedit.isEmpty,
                  "Select the exact displayed English candidate: \(input)")
        }
        for input in ["canpin", "youxi", "sheji", "hezuo"] {
            type(engine, input)
            let first = engine.snapshot().candidates.first ?? ""
            check(!first.isEmpty && first.unicodeScalars.allSatisfy { $0.value > 127 },
                  "Short-conflict handling keeps a Chinese continuation first \(input): \(engine.snapshot().candidates)")
            check(allCandidates(engine).contains { candidate in
                !candidate.isEmpty && candidate.unicodeScalars.allSatisfy { $0.value > 127 }
            }, "Short-conflict handling keeps Chinese continuations reachable: \(input)")
            engine.clear()
        }
        type(engine, "D")
        check(engine.snapshot().candidates.first == "D", "Keep intentional uppercase letter input")
        engine.clear()
        print("PASS mixed English: initial/internal/final words, adjacent boundaries, source-frequency completion ranking, exact retention, deduplication, edit/select")
    }

    /// Selecting a mixed candidate confirms each of its ASCII runs in the English user dictionary,
    /// like selecting the same words alone, and a sentence whose every run is confirmed then
    /// leads. Return, cancel and an immediate undo confirm nothing; one unconfirmed run, a complete
    /// Pinyin word and a custom phrase keep their places. The words are used by no other test.
    @MainActor package static func mixedSelectionLearning() {
        let engine = IFEngine()!
        // Where the sentence sits on the first page, and whether its evidence says every run is learned.
        func state(_ input: String, _ expected: String) -> (index: Int, learned: Bool)? {
            engine.clear(); type(engine, input)
            let candidates = engine.qualitySnapshot().candidates
            guard let index = candidates.firstIndex(where: { $0.text == expected }) else { return nil }
            return (index, candidates[index].source == "personal_exact_mixed")
        }
        // Select the sentence, then undo the commit with Backspace or end the undo window with Tab.
        func choose(_ input: String, _ expected: String, undo: Bool = false) {
            engine.clear(); type(engine, input)
            guard let index = engine.snapshot().candidates.firstIndex(of: expected) else {
                check(false, "Missing mixed candidate \(input) -> \(expected): \(engine.snapshot().candidates)"); return
            }
            engine.select(index)
            check(engine.takeCommit() == expected && engine.snapshot().preedit.isEmpty, "Select the mixed candidate \(expected)")
            engine.key(undo ? 0xff08 : 0xff09)
        }
        // Whether standalone `google` carries personal evidence in a technical context. Its place no
        // longer shows that: `google` is not Pinyin-shaped, so it leads either way (rule 14).
        func standaloneLearned() -> Bool {
            engine.clear(); engine.setPrecedingText("代码"); type(engine, "google")
            return engine.qualitySnapshot().candidates.first { $0.text == "google" }?.source == "personal_exact_english"
        }
        let (google, sentence) = ("wofalegoogle", "我发了google")
        var current = state(google, sentence)
        check(current?.index == 1 && current?.learned == false, "An unlearned sentence stays behind the Chinese reading: \(engine.snapshot().candidates)")
        check(!standaloneLearned(), "Standalone google has no personal evidence yet")

        // Raw Return and cancellation commit no candidate; an immediate undo reverts the selection.
        engine.clear(); type(engine, google)
        check(engine.key(0xff0d) && engine.takeCommit() == google, "Return commits the raw input")
        engine.key(0xff09)
        engine.clear(); type(engine, google)
        check(engine.key(0xff1b) && engine.takeCommit().isEmpty, "Cancel commits nothing")
        engine.key(0xff09)
        choose(google, sentence, undo: true)
        current = state(google, sentence)
        check(current?.index == 1 && current?.learned == false, "Return, cancel and an immediate undo learn nothing")
        check(!standaloneLearned(), "Standalone google is still unlearned")

        // A regular selection learns the run with its display and lowercase code.
        choose(google, sentence)
        current = state(google, sentence)
        check(current?.index == 0 && current?.learned == true, "The learned sentence leads: \(engine.snapshot().candidates)")
        check(standaloneLearned(), "The same record serves standalone English")

        // A sentence with one unlearned run keeps its place until every run is learned.
        let (both, bothSentence) = ("wofalegoogleheamazon", "我发了google和amazon")
        current = state(both, bothSentence)
        check(current?.index == 1 && current?.learned == false, "amazon has no personal evidence yet: \(engine.snapshot().candidates)")
        choose("wokanamazon", "我看amazon")
        current = state(both, bothSentence)
        check(current?.index == 0 && current?.learned == true, "Every run is learned: \(engine.snapshot().candidates)")

        // A custom phrase keeps its explicit priority over a learned sentence.
        engine.setConfiguration(candidateCount: 5, customPhrases: [CustomPhrase(id: UUID(), code: google, text: "自定义词")])
        engine.clear(); type(engine, google)
        check(engine.snapshot().candidates.first == "自定义词", "Custom phrase keeps priority over a learned sentence")
        engine.clear()
        engine.setConfiguration(candidateCount: 5, customPhrases: [])

        // A complete Pinyin word is never a personal token, however often it is selected.
        let (banana, bananaSentence) = ("wokanbanana", "我看banana")
        current = state(banana, bananaSentence)
        check(current?.index == 1 && current?.learned == false, "banana is a mixed candidate behind the Chinese reading")
        choose(banana, bananaSentence); choose(banana, bananaSentence)
        current = state(banana, bananaSentence)
        check(current?.index == 1 && current?.learned == false, "Complete Pinyin sequences never promote a mixed sentence")
        engine.clear()
        print("PASS mixed selection learning: regular selection learns, Return/cancel/undo do not, every run must be learned, custom phrases and complete Pinyin words keep their places")
    }

    @MainActor package static func englishFeatureCoexistence() {
        let engine = IFEngine()!
        engine.setPrecedingText("准备午")
        type(engine, "can")
        check(engine.snapshot().candidates.first == "餐", "Context still ranks Chinese before colliding English")
        check(allCandidates(engine).contains("can"), "Context keeps admitted English reachable")
        engine.clear()
        for (input, expected) in [("actual", "actual"), ("zhefenoffer", "这份offer")] {
            engine.setPrecedingText("准备午")
            type(engine, input)
            let candidates = engine.snapshot().candidates
            let supplemental = candidates.filter { $0.unicodeScalars.contains { $0.value < 128 } }
            check(supplemental.first == expected, "Context preserves order within English/mixed candidates")
            engine.highlight(candidates.firstIndex(of: expected)!)
            engine.key(32)
            check(engine.takeCommit() == expected)
        }
        engine.setConfiguration(candidateCount: 5, customPhrases: [CustomPhrase(id: UUID(), code: "email", text: "电子邮件")])
        engine.setPrecedingText("准备午")
        type(engine, "email")
        check(engine.snapshot().candidates.first == "电子邮件", "Explicit custom phrases retain priority over English")
        check(allCandidates(engine).contains("email"), "Custom phrase priority retains ordinary English")
        engine.key(32)
        check(engine.takeCommit() == "电子邮件")
        engine.setConfiguration(candidateCount: 5, customPhrases: [])
        print("PASS English integration: Chinese context priority, English reachability/order, mixed commits and custom phrase coexistence")
    }

    @MainActor package static func shortConflictBounds() {
        let engine = IFEngine()!
        let phrases = (0..<1_024).map {
            CustomPhrase(id: UUID(), code: "can", text: "自定义候选\($0)")
        }
        engine.setConfiguration(candidateCount: 9, customPhrases: phrases)
        check(engine.configurationError == nil)
        let started = ContinuousClock.now
        type(engine, "can")
        let firstPage = engine.snapshot().candidates
        let elapsed = started.duration(to: .now)
        check(elapsed < .seconds(2), "High-cardinality first-page latency stays bounded: \(elapsed)")
        check(!firstPage.contains("can"),
              "An exact English candidate beyond the bounded lookahead keeps native pagination")
        let all = allCandidates(engine)
        check(all.contains("can"), "Bounded lookahead keeps a later exact candidate reachable")
        check(phrases.allSatisfy { all.contains($0.text) },
              "Bounded lookahead retains every high-cardinality candidate across pages")
        engine.clear()
        engine.setConfiguration(candidateCount: 9, customPhrases: [])
        print("PASS short-conflict bounds: 256-candidate lookahead, 1024-candidate latency/memory envelope, pagination and exact reachability")
    }

    @MainActor package static func allCandidates(_ engine: IFEngine) -> [String] {
        var candidates: [String] = []
        for _ in 0..<1000 {
            let snapshot = engine.snapshot()
            candidates += snapshot.candidates
            engine.key(0xff56)
            if engine.snapshot().page == snapshot.page {
                for _ in 0..<snapshot.page { engine.key(0xff55) }
                check(engine.snapshot().page == 0, "Restore first page after exhaustive candidate lookup")
                return candidates
            }
        }
        check(false, "Candidate enumeration must reach the final page")
        return candidates
    }

    @MainActor package static func englishAdmission() {
        let engine = IFEngine()!
        let rejected = ["WOMENS", "womenfolk", "tameness", "Nimes", "nimetti", "nimetz",
                        "Haiti", "Haitian", "Haitienne", "haitians", "compute"]
        let forbidden = Set(rejected.map { $0.lowercased() })
        func verify(_ candidates: [String], _ input: String) {
            for candidate in candidates {
                let words = candidate.split { !$0.isASCII || !$0.isLetter }.map { $0.lowercased() }
                check(forbidden.isDisjoint(with: words), "Rejected English for \(input): \(candidate)")
            }
        }
        let screenshots = ["women", "tamen", "nime", "haiti"]
        let exactAndCase = rejected.flatMap { [$0, $0.lowercased(), $0.uppercased(), $0.capitalized] }
        for input in Set(screenshots + exactAndCase).sorted() {
            type(engine, input)
            let candidates = allCandidates(engine)
            verify(candidates, input)
            if input == "women" {
                check(candidates.first == "我们" && candidates.contains("women"),
                      "Measured common English remains available after Chinese: \(candidates)")
            }
            engine.clear()
        }
        // Exercise prefix lookup, edits, cache replacement, and selection/re-entry.
        for input in screenshots {
            var prefix = ""
            for letter in input {
                prefix.append(letter); type(engine, String(letter))
                verify(engine.snapshot().candidates, prefix)
            }
            for letter in input.reversed() {
                engine.key(0xff08); prefix.removeLast()
                verify(engine.snapshot().candidates, prefix)
                type(engine, String(letter))
                verify(allCandidates(engine), prefix + String(letter))
                engine.key(0xff08)
            }
            check(engine.snapshot().preedit.isEmpty && engine.takeCommit().isEmpty)
            type(engine, input)
            if !engine.snapshot().candidates.isEmpty { engine.select(0) }
            verify([engine.takeCommit()], input)
            engine.clear()
            type(engine, input)
            verify(allCandidates(engine), input)
            engine.clear()
        }
        for word in rejected {
            for input in ["zhefen" + word, word + "henhao", "wo" + word + "henhao"] {
                type(engine, input)
                verify(allCandidates(engine), input)
                engine.clear()
            }
        }
        // Explicit ASCII mode is character passthrough, not dictionary admission.
        engine.asciiMode = true
        for letter in "women compute Haiti".utf16 { check(!engine.key(Int32(letter))) }
        check(engine.snapshot().candidates.isEmpty && engine.takeCommit().isEmpty)
        print("PASS English admission: women admitted after Chinese; low-frequency screenshot words and compute absent from exact/prefix/case/all pages, edits, re-entry, mixed boundaries; explicit ASCII unaffected")
    }

    @MainActor package static func missingEmojiResources(shared: String, user: String) throws {
        let directory = URL(fileURLWithPath: user).appendingPathComponent("incomplete-resources")
        let files = FileManager.default
        try files.createDirectory(at: directory.appendingPathComponent("opencc"), withIntermediateDirectories: true)
        try files.createDirectory(at: directory.appendingPathComponent("lua"), withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        for name in ["default.yaml", "inkflow_pinyin.schema.yaml", "pinyin_simp.dict.yaml", "pinyin_simp.context.bin",
                     "easy_en.schema.yaml", "easy_en.dict.yaml",
                     "inkflow_mixed.schema.yaml", "inkflow_mixed.dict.yaml",
                     "lua/inkflow_english.lua", "lua/inkflow_mixed.lua", "lua/inkflow_short_conflict.lua",
                     "lua/inkflow_ai_learning.lua", "lua/inkflow_input_coverage.lua", "lua/inkflow_channel.lua",
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

    @MainActor package static func spellingCorrection(event: Event = rimeEvent) {
        let cases = [("hzidao", "知道"), ("nnihao", "你好"), ("hcuqu", "出去"),
                     ("hsuru", "输入"), ("ppinyin", "拼音"), ("nnihhao", "你好"),
                     ("zhognguo", "中国"), ("beijign", "背景"), ("nihoa", "你好"),
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
        // Frost's measured homophone order prefers 背景 for both beijing and its
        // tolerated transposition; 北京 remains directly selectable.
        let normalCity = IFEngine()!
        type(normalCity, "beijing")
        let normalCandidates = normalCity.snapshot().candidates
        check(normalCandidates.first == "背景", "Pinned Frost homophone ranking: \(normalCandidates)")
        normalCity.clear()
        let city = IFEngine()!
        type(city, "beijign")
        let typoCandidates = city.snapshot().candidates
        check(typoCandidates.first == normalCandidates.first, "Typo alias preserves ordinary homophone ranking")
        guard let cityIndex = typoCandidates.firstIndex(of: "北京") else {
            check(false, "Keep 北京 reachable after final transposition"); return
        }
        city.select(cityIndex)
        check(city.takeCommit() == "北京")
        for (input, expected) in [("nihao", "你好"), ("zhidao", "知道"), ("shanghai", "伤害"),
                                  ("jinnian", "今年"), ("nannv", "男女"), ("tiananmen", "天安门"),
                                  ("xi'an", "西安"), ("womenlai", "我们来"), ("womenlia", "我们俩"),
                                  ("xianzaiwomenlai", "现在我们来")] {
            let engine = IFEngine()!
            type(engine, input)
            check(engine.snapshot().candidates.first == expected, "Normal spelling \(input): \(engine.snapshot())")
            if input == "shanghai" {
                let candidates = engine.snapshot().candidates
                guard let index = candidates.firstIndex(of: "上海") else {
                    check(false, "Keep 上海 reachable in ordinary homophone candidates"); return
                }
                engine.select(index)
                check(engine.takeCommit() == "上海")
            }
            engine.clear()
        }
        let engine = IFEngine()!
        type(engine, "nnihao")
        check(event(engine, 0xff08, 51, "", 0))
        check(engine.snapshot().preedit.replacingOccurrences(of: " ", with: "") == "nniha")
        type(engine, "o")
        check(engine.snapshot().candidates.first == "你好")
        check(event(engine, 0xff50, 115, "", 0)) // Home, then remove the extra initial.
        check(engine.snapshot().cursor == 0)
        check(event(engine, 0xffff, 117, "", 0))
        check(engine.snapshot().preedit.replacingOccurrences(of: " ", with: "") == "nihao")
        check(engine.snapshot().candidates.first == "你好")
        check(event(engine, 0xff57, 119, "", 0))
        check(engine.snapshot().cursor == engine.snapshot().preedit.utf16.count)
        check(event(engine, 0xff1b, 53, "", 0))
        check(engine.snapshot().preedit.isEmpty && engine.takeCommit().isEmpty)
        type(engine, "hzidao")
        engine.select(0)
        check(engine.takeCommit() == "知道" && engine.snapshot().preedit.isEmpty)
        engine.asciiMode = true
        for code in "nnihao".utf16 { check(!engine.key(Int32(code))) }
        check(engine.snapshot().preedit.isEmpty && engine.takeCommit().isEmpty)
        print("PASS spelling correction: 12 typo phrases, normal spelling/boundaries, editable preedit, selection, cancel, ASCII passthrough")
    }

    @MainActor package static func customPhrases(
        user: String, storedPhrases: (() -> [CustomPhrase])? = nil,
        savePhrase: ((CustomPhrase) throws -> CustomPhrase)? = nil
    ) throws {
        var phrases = try ["地址甲", "地址乙", "地址丙", "地址丁", "地址戊", "地址己", "地址庚", "地址辛", "地址壬", "地址癸", "地址十一", "地址十二"].map {
            let phrase = try CustomPhrase.validated(code: "dz", text: $0)
            return try savePhrase?(phrase) ?? phrase
        }
        for (code, text) in [("nihao", "您好朋友"), ("nihao", "你好"), ("bq", "#标签"), ("zw", "# no comment")] {
            let phrase = try CustomPhrase.validated(code: code, text: text)
            phrases.append(try savePhrase?(phrase) ?? phrase)
        }
        phrases = storedPhrases?() ?? phrases
        let a = IFEngine()!, b = IFEngine()!
        a.setConfiguration(candidateCount: 3, customPhrases: phrases)
        b.setConfiguration(candidateCount: 3, customPhrases: phrases)
        check(a.configurationError == nil)
        for phrase in phrases.suffix(2) {
            type(a, phrase.code)
            check(a.snapshot().candidates.first == phrase.text)
            check(a.snapshot().candidates.filter { $0 == phrase.text }.count == 1)
            a.clear()
        }
        type(a, "nihao")
        check(a.snapshot().candidates.prefix(2) == ["您好朋友", "你好"], "Custom phrases precede ordinary candidates")
        check(a.snapshot().candidates.filter { $0 == "你好" }.count == 1)
        check(a.snapshot().candidates.filter { $0 == "👋" }.count == 1,
              "Emoji must coexist with custom phrases without duplicate suggestions")
        a.select(2); check(a.takeCommit() == "👋")
        type(a, "nnihao")
        check(a.snapshot().candidates.first == "你好",
              "Typo correction must remain available without fuzzy-matching custom codes")
        check(!a.snapshot().candidates.contains("您好朋友"))
        a.clear()
        type(a, "d"); check(!a.snapshot().candidates.contains("地址甲")); a.clear()
        type(a, "dza"); check(!a.snapshot().candidates.contains("地址甲")); a.clear()
        type(a, "dz")
        check(a.snapshot().candidates == ["地址甲", "地址乙", "地址丙"])
        a.key(0xff56)
        check(a.snapshot().page == 1 && a.snapshot().candidates == ["地址丁", "地址戊", "地址己"])
        a.key(50); check(a.takeCommit() == "地址戊")
        let shiPhrases = phrases.prefix(12).map { CustomPhrase(id: $0.id, code: "shi", text: $0.text) }
        type(b, "shi"); let ordinary = b.snapshot().candidates; b.clear()
        a.setConfiguration(candidateCount: 3, customPhrases: shiPhrases)
        type(a, "shi")
        for _ in 0..<4 { a.key(0xff56) }
        check(!ordinary.isEmpty && a.snapshot().candidates == ordinary, "Ordinary candidates must remain after all custom phrases")
        a.clear()
        a.setConfiguration(candidateCount: 3, customPhrases: phrases)
        type(a, "dz"); a.select(1); check(a.takeCommit() == "地址乙")
        a.setConfiguration(candidateCount: 9, customPhrases: phrases)
        type(a, "dz"); check(a.snapshot().candidates.count == 9)
        a.key(57); check(a.takeCommit() == "地址壬")
        type(a, "dz"); let old = a.snapshot()
        let replacement = try CustomPhrase.validated(id: phrases[0].id, code: "dz", text: "更新地址")
        let changed = try savePhrase?(replacement) ?? replacement
        phrases[0] = changed
        phrases = storedPhrases?() ?? phrases
        a.setConfiguration(candidateCount: 5, customPhrases: phrases)
        a.setConfiguration(candidateCount: 3, customPhrases: [changed])
        check(a.snapshot() == old && a.takeCommit().isEmpty && a.candidateCount == 9)
        a.key(32)
        // Applying settings between a completed composition and draining its commit must not lose text.
        a.setConfiguration(candidateCount: 3, customPhrases: [changed])
        check(a.takeCommit() == "地址甲")
        type(a, "dz"); check(a.snapshot().candidates.first == "更新地址" && a.candidateCount == 3)
        a.clear(); type(b, "dz")
        check(b.snapshot().candidates.first == "更新地址" && b.candidateCount == 3,
              "Every idle session reloads the saved phrases together and keeps its own count")
        b.clear()
        do {
            let fresh = IFEngine()!
            fresh.setConfiguration(candidateCount: 3, customPhrases: [changed])
            type(fresh, "dz"); check(fresh.snapshot().candidates.first == "更新地址")
        }
        a.asciiMode = true
        a.setConfiguration(candidateCount: 9, customPhrases: [])
        check(!a.key(97), "Schema reload must preserve ASCII mode")
        a.asciiMode = false
        type(a, "dz")
        check(!a.snapshot().candidates.contains("更新地址") && !a.snapshot().candidates.contains("地址戊"))
        a.clear()
        a.setConfiguration(candidateCount: 9, customPhrases: phrases)
        type(a, "dz"); a.key(32); check(a.takeCommit() == "更新地址")
        a.setConfiguration(candidateCount: 9, customPhrases: [])
        type(a, "dz"); check(!a.snapshot().candidates.contains("更新地址"), "Deleted selected phrases must not be learned into Pinyin")
        a.clear()
        let invalid = CustomPhrase(id: UUID(), code: "x\ty", text: "invalid")
        a.setConfiguration(candidateCount: 5, customPhrases: [invalid])
        check(a.configurationError != nil)
        a.setConfiguration(candidateCount: 5, customPhrases: [])
        check(a.configurationError == nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: user)[.posixPermissions]!
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: user)
        a.setConfiguration(candidateCount: 3, customPhrases: [changed])
        let writeFailed = a.configurationError != nil && a.candidateCount == 5
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: user)
        check(writeFailed, "An unwritable dictionary directory must surface failure and retain the old configuration")
        a.setConfiguration(candidateCount: 3, customPhrases: [changed])
        check(a.configurationError != nil && a.candidateCount == 5,
              "The same request is pushed on every refresh and must not retry the write")
        let retried = try CustomPhrase.validated(id: changed.id, code: "dz", text: "重试地址")
        a.setConfiguration(candidateCount: 3, customPhrases: [retried])
        check(a.configurationError == nil, "A changed request writes the file again")
        type(a, "dz"); check(a.snapshot().candidates.first == retried.text && a.candidateCount == 3); a.clear()
        let file = URL(fileURLWithPath: user).appendingPathComponent("custom_phrase.txt")
        let saved = try String(contentsOf: file, encoding: .utf8)
        check(saved == "# no comment\n重试地址\tdz\t1\n", "Rime's native custom_phrase.txt holds the saved phrases")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: user).filter { $0.hasPrefix("inkflow_phrases_") }
        check(leftovers.isEmpty, "No temporary dictionaries")
        a.setConfiguration(candidateCount: 5, customPhrases: [])
        print("PASS custom phrase engine: exact match, priority/coexistence, Unicode/hash text, dedup, native pagination/digits/click, coalesced idle reload, pending commits, ASCII, shared/fresh sessions, removal after selection, write failure/retry, native custom_phrase.txt")
    }

    @MainActor package static func runCases(event: Event = rimeEvent) throws {
        let a = IFEngine()!, b = IFEngine()!
        type(a, "nihao"); check(a.snapshot().candidates.contains("你好"))
        check(b.snapshot().preedit.isEmpty)
        a.select(0); check(a.takeCommit() == "你好")
        type(a, "zhongguo"); check(a.snapshot().candidates.contains("中国"))
        a.key(0xff1b); check(a.snapshot().preedit.isEmpty)
        type(a, "ni"); a.key(0xff08); check(a.snapshot().preedit == "n")
        a.clear(); type(a, "ni")
        check(event(a, 0xff08, 51, "\u{8}", 0)); check(a.snapshot().preedit == "n")
        check(event(a, 0xff1b, 53, "\u{1b}", 0)); check(a.snapshot().preedit.isEmpty)
        a.clear(); type(a, "shi"); let first = a.snapshot().candidates
        check(first.count == 5)
        _ = event(a, 0xff56, 121, "", 0); check(a.snapshot().page == 1)
        var second = a.snapshot().candidates; check(second.count == 5 && second != first)
        _ = event(a, 0xff55, 116, "", 0); check(a.snapshot().page == 0 && a.snapshot().candidates == first)
        _ = event(a, 50, 19, "2", 0); check(a.takeCommit() == first[1])
        type(a, "shi"); _ = event(a, 0xff56, 121, "", 0)
        second = a.snapshot().candidates; check(second.count == 5)
        _ = event(a, 53, 23, "5", 0); check(a.takeCommit() == second[4])
        type(a, "nihao"); a.key(32); check(a.takeCommit() == "你好")
        a.asciiMode = true; check(!a.key(97))
        a.asciiMode = false; type(a, "nihao"); a.commit(); check(a.takeCommit() == "你好")
        check(!event(a, -1, 0, "a", 2))
        a.clear(); type(a, "shi"); let before = a.snapshot()
        a.setCandidateCount(9); check(a.snapshot() == before && a.takeCommit().isEmpty)
        a.clear(); type(a, "shi"); check(a.snapshot().candidates.count == 9)
        _ = event(a, 0xff56, 121, "", 0); let nine = a.snapshot().candidates; check(nine.count == 9)
        _ = event(a, 57, 25, "9", 0); check(a.takeCommit() == nine[8])
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
        punctuation(event: event)
        learnedEnglishOverSentence(event: event)
        technicalEnglishLead(event: event)
        compositionKeys(event: event)
        forgetCandidate(event: event)
        emojiCandidates()
    }

    @MainActor package static func emojiCandidates() {
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
            engine.asciiMode = true
            for key in "nihao".utf8 { check(!engine.key(Int32(key))) }
            check(engine.snapshot().candidates.isEmpty && engine.takeCommit().isEmpty)
        }
        print("PASS emoji: simplified keywords, original words preserved, unique candidates, full Unicode commits, digit/space selection, 3/5/9 paging, cancel, English passthrough")
    }

    @MainActor package static func contextReranking() {
        func prepared(_ prefix: String = "准备午", _ input: String = "can", count: Int = 5) -> IFEngine {
            let engine = IFEngine()!
            engine.setCandidateCount(count)
            engine.setPrecedingText(prefix); type(engine, input)
            return engine
        }
        let coverage = prepared("什么", "neng", count: 9)
        check(coverage.snapshot().candidates.first == "能",
              "Context must not promote partial 呢 above complete 能: \(coverage.snapshot())")
        check(coverage.key(32))
        check(coverage.takeCommit() == "能" && coverage.snapshot().preedit.isEmpty,
              "The complete contextual first candidate consumes neng")
        for count in [3, 5, 9] {
            let contextual = prepared("什么", "neng", count: count), native = prepared("", "neng", count: count)
            check(contextual.snapshot().candidates == native.snapshot().candidates,
                  "Same-character-length partial choices retain native order")
            let firstPage = contextual.snapshot().candidates
            check(contextual.key(0xff56) && contextual.snapshot().page == 1)
            check(contextual.key(0xff55) && contextual.snapshot().candidates == firstPage,
                  "Coverage remains aligned after paging back")
            guard let partialIndex = firstPage.firstIndex(of: "呢") else {
                check(false, "Expected partial 呢 on neng first page"); continue
            }
            contextual.highlight(partialIndex)
            contextual.setPrecedingText("什么")
            check(contextual.snapshot().highlight == partialIndex, "An unchanged prefix preserves explicit selection")
            check(contextual.key(32))
            check(contextual.takeCommit().isEmpty && contextual.snapshot().preedit == "呢ng",
                  "Selecting the displayed partial candidate retains native unconsumed input")
            native.select(partialIndex)
            check(contextual.snapshot().candidates == native.snapshot().candidates,
                  "Selected-prefix bypass preserves native remaining candidates")
        }
        for (prefix, input, expected) in [("准备午", "can", "餐"), ("正式宣", "bu", "布"),
                                           ("最新软", "jian", "件"), ("非常感", "xie", "谢")] {
            // Emoji also occupy page slots; keep the target inside the tested page.
            let engine = prepared(prefix, input, count: 9)
            check(engine.snapshot().candidates.first == expected, "Bundled dictionary context \(prefix) + \(input): \(engine.snapshot())")
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
        for count in [3, 5, 9] {
            let engine = prepared("多", "can", count: count)
            let candidates = engine.snapshot().candidates
            check(candidates.count == count, "Context retains the configured \(count)-candidate page: \(candidates)")
            check(candidates.first?.unicodeScalars.allSatisfy { $0.value > 127 } == true,
                  "Context keeps Chinese first for short English conflicts: \(candidates)")
            guard let index = candidates.firstIndex(of: "can") else {
                check(false, "Context keeps exact short English on the first page: \(candidates)")
                continue
            }
            check(index < 3, "Context keeps exact short English in Top-3 for \(count) candidates: \(candidates)")
            engine.select(index)
            check(engine.takeCommit() == "can" && engine.snapshot().preedit.isEmpty,
                  "Context selection commits the displayed short English exactly")
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
        for action in ["commit", "space", "comma", "return"] {
            let engine = prepared()
            switch action {
            case "commit": engine.commit()
            case "space": check(engine.key(32))
            case "comma": check(engine.key(44))
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

    /// Swift–Lua requests travel through the core's one versioned property protocol. Its framing and
    /// version checks are the core's (`channel.rs` unit tests, `parity.sh` swift_property_channel).
    @MainActor package static func propertyChannel() {
        let engine = IFEngine()!
        check(engine.call("learning_invalidate") == IFRimeChannel.Reply(status: "ok"), "A live module answers a version 1 request")
        check(engine.call("no_such_operation") == nil, "No module answers an unknown operation")
        check(engine.call("ai_learning", ["bad code", "你好"])?.status == "failed", "Modules validate their own fields")
        check(engine.call("input_coverage", ["0", "3"])?.status == "failed", "Input coverage without a composition fails closed")
        for (op, fields) in [("", ["a"]), ("Input", []), ("ai-learning", []), ("ai_learning", ["a\tb"]),
                             ("ai_learning", ["a\nb"]), ("ai_learning", ["a\rb"])] {
            check(engine.call(op, fields) == nil, "Framing characters and bad operation names fail closed: \(op) \(fields)")
        }
        check(engine.call("voice_aliases", capacity: 8) == nil, "A reply that does not fit is no reply")
        print("PASS property channel: live dispatch, field validation and bounded replies through the core")
    }

    @MainActor package static func contextCustomPhrasePriority() {
        let engine = IFEngine()!
        let phrase = CustomPhrase(id: UUID(), code: "can", text: "残")
        engine.setConfiguration(candidateCount: 5, customPhrases: [phrase])
        engine.setPrecedingText("准备午")
        type(engine, "can")
        check(engine.snapshot().candidates.first == "残", "CTX-MERGE-1: an exact custom phrase must retain priority over contextual 餐")
        engine.setConfiguration(candidateCount: 3, customPhrases: [])
        check(engine.snapshot().candidates.first == "残", "Deferred deletion must preserve the current custom phrase snapshot")
        check(engine.key(32)); check(engine.takeCommit() == "残")
        engine.setPrecedingText("准备午")
        type(engine, "can")
        check(engine.snapshot().candidates.first == "餐", "Context ranking resumes after the custom code is deleted at idle")
        check(engine.key(32)); check(engine.takeCommit() == "餐")
        print("PASS context integration: exact custom phrase priority, deferred deletion, context resumes at idle")
    }

    @MainActor package static func englishCandidates() {
        let engine = IFEngine()!
        var missingLetters: [String] = []
        for (input, expected) in [("a", "a"), ("i", "I")] {
            type(engine, input)
            var selected = false
            for _ in 0..<100 {
                let snapshot = engine.snapshot()
                if let index = snapshot.candidates.firstIndex(of: expected) {
                    engine.select(index)
                    check(engine.takeCommit() == expected && engine.snapshot().preedit.isEmpty)
                    selected = true
                    break
                }
                engine.key(0xff56)
                if engine.snapshot().page == snapshot.page { break }
            }
            if !selected {
                print("FAIL single-letter English \(input) -> \(expected) is missing")
                missingLetters.append(input)
            }
            engine.clear()
        }
        check(missingLetters.isEmpty, "Keep single-letter English reachable: \(missingLetters)")
        for word in ["hello", "apple", "computer", "world", "email", "emails", "online", "file", "code", "update", "Hello", "Apple"] {
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
        engine.clear(); type(engine, "emai")
        let mail = allCandidates(engine)
        check(mail.firstIndex(of: "email") != nil && mail.firstIndex(of: "emails") != nil)
        check(mail.firstIndex(of: "email")! < mail.firstIndex(of: "emails")!, "Measured email frequency exceeds emails")
        engine.clear(); type(engine, "comm")
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
        type(engine, "hello")
        let helloCandidates = engine.snapshot().candidates
        guard let helloIndex = helloCandidates.firstIndex(of: "hello") else {
            check(false, "Admitted hello must remain selectable"); return
        }
        // Fuzzy Pinyin may cover the same input and retain Chinese priority.
        engine.highlight(helloIndex)
        check(engine.key(32))
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
        engine.asciiMode = true
        for letter in "hello".utf16 { check(!engine.key(Int32(letter))) }
        check(engine.snapshot().candidates.isEmpty && engine.takeCommit().isEmpty)
        print("PASS English candidates: common words, case, prefix completion, paging/digit/space selection, edit/cancel, Chinese priority, ASCII passthrough")
    }

    @MainActor package static func punctuation(event: Event = rimeEvent) {
        let cases: [(String, String, UInt16, Bool)] = [
            ("{", "「", 33, true), ("}", "」", 30, true), ("[", "【", 33, false), ("]", "】", 30, false),
            ("<", "《", 43, true), (">", "》", 47, true), ("\\", "、", 42, false), ("|", "｜", 42, true),
            ("`", "·", 50, false), ("~", "～", 50, true), ("$", "¥", 21, true), ("^", "……", 22, true),
            ("_", "——", 27, true), (",", "，", 43, false), (".", "。", 47, false), (";", "；", 41, false),
            (":", "：", 41, true), ("!", "！", 18, true), ("?", "？", 44, true), ("(", "（", 25, true), (")", "）", 29, true)
        ]
        for (input, expected, code, shifted) in cases {
            let engine = IFEngine()!
            let key = Int32(input.utf16.first!), modifiers: Int32 = shifted ? 1 : 0
            check(event(engine, key, code, input, modifiers)); check(engine.takeCommit() == expected)
            check(engine.snapshot().preedit.isEmpty)
            engine.asciiMode = true; check(!event(engine, key, code, input, modifiers)); check(engine.takeCommit().isEmpty)
        }
        for (input, expected) in [("\"\"\"\"", "“”“”"), ("''''", "‘’‘’"), ("\"'\"'", "“‘”’")] {
            let engine = IFEngine()!
            for (quote, output) in zip(input, expected) {
                check(event(engine, Int32(String(quote).utf16.first!), 39, String(quote), quote == "\"" ? 1 : 0))
                check(engine.takeCommit() == String(output)); check(engine.snapshot().preedit.isEmpty)
            }
            engine.asciiMode = true
            check(!event(engine, 34, 39, "\"", 1))
            check(!event(engine, 39, 39, "'", 0)); check(engine.takeCommit().isEmpty)
        }
        let engine = IFEngine()!
        type(engine, "xi'an "); check(engine.takeCommit() == "西安")
        check(event(engine, 34, 39, "\"", 1)); check(engine.takeCommit() == "“")
        type(engine, "xi'an "); check(engine.takeCommit() == "西安")
        check(event(engine, 34, 39, "\"", 1)); check(engine.takeCommit() == "”")
        type(engine, "shi"); let first = engine.snapshot().candidates
        check(event(engine, 93, 30, "]", 0)); check(engine.snapshot().page == 1)
        check(engine.takeCommit().isEmpty)
        check(event(engine, 91, 33, "[", 0)); check(engine.snapshot().candidates == first)
        check(engine.takeCommit().isEmpty); engine.clear()
        check(event(engine, 91, 33, "[", 0)); check(engine.takeCommit() == "【")
        for text in ["@", "#", "%", "&", "*", "-", "=", "+", "/"] {
            check(!event(engine, Int32(text.utf16.first!), 0, text, 0)); check(engine.takeCommit().isEmpty)
        }
        for modifier: Int32 in [2, 4, 8] {
            check(!event(engine, -1, 22, "^", modifier | 1))
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

    /// One block per row of the key table in rules.md ("Keys during composition"). The block's
    /// first comment is the row id, and every failure message starts with that id. Each block
    /// covers the idle, composing and recognizer-match columns of its row.
    @MainActor package static func compositionKeys(event: Event = rimeEvent) {
        struct Key { let symbol: Int32, code: UInt16, text: String, modifiers: Int32 }
        let space = Key(symbol: 32, code: 49, text: " ", modifiers: 0)
        let enter = Key(symbol: 0xff0d, code: 36, text: "\r", modifiers: 0)
        let backspace = Key(symbol: 0xff08, code: 51, text: "\u{8}", modifiers: 0)
        let escape = Key(symbol: 0xff1b, code: 53, text: "\u{1b}", modifiers: 0)
        let left = Key(symbol: 0xff51, code: 123, text: "", modifiers: 0)
        let right = Key(symbol: 0xff53, code: 124, text: "", modifiers: 0)
        let up = Key(symbol: 0xff52, code: 126, text: "", modifiers: 0)
        let down = Key(symbol: 0xff54, code: 125, text: "", modifiers: 0)
        let pageUp = Key(symbol: 0xff55, code: 116, text: "", modifiers: 0)
        let pageDown = Key(symbol: 0xff56, code: 121, text: "", modifiers: 0)
        let home = Key(symbol: 0xff50, code: 115, text: "", modifiers: 0)
        let end = Key(symbol: 0xff57, code: 119, text: "", modifiers: 0)
        func char(_ character: Character) -> Key {
            let shifted = character.isUppercase || "~!@#$%^&*()_+{}|:\"<>?".contains(character)
            return Key(symbol: Int32(character.asciiValue!), code: 0, text: String(character), modifiers: shifted ? 1 : 0)
        }
        @discardableResult func press(_ engine: IFEngine, _ key: Key) -> Bool {
            event(engine, key.symbol, key.code, key.text, key.modifiers)
        }
        func send(_ engine: IFEngine, _ text: String) { for character in text { press(engine, char(character)) } }
        func spelled(_ engine: IFEngine) -> String { engine.snapshot().preedit.filter { $0 != " " } }
        func fresh(_ preferences: InputPreferences? = nil) -> IFEngine {
            let engine = IFEngine()!
            if let preferences { engine.setConfiguration(candidateCount: 5, customPhrases: [], inputPreferences: preferences) }
            return engine
        }
        func composing(_ text: String, _ preferences: InputPreferences? = nil) -> IFEngine {
            let engine = fresh(preferences)
            send(engine, text)
            return engine
        }
        // An engine whose composition the recognizer has taken: the raw text, no menu.
        func matched(_ text: String = "www.example", _ preferences: InputPreferences? = nil) -> IFEngine {
            let engine = composing(text, preferences), state = engine.snapshot()
            check(state.preedit == text && state.candidates.isEmpty && engine.takeCommit().isEmpty,
                  "recognizer: \(text) must stay raw ASCII without a menu: \(state)")
            return engine
        }
        func idleIgnores(_ key: Key, _ row: String) {
            let engine = IFEngine()!
            check(!press(engine, key) && engine.takeCommit().isEmpty && engine.snapshot().preedit.isEmpty,
                  "\(row) idle: passes through")
        }
        func unchanged(_ engine: IFEngine, _ before: EngineSnapshot) -> Bool {
            engine.snapshot() == before && engine.takeCommit().isEmpty
        }
        let url = "www.example", mail = "name@example"
        let chinese: [(Character, String)] = [
            (",", "，"), (".", "。"), (";", "；"), (":", "："), ("!", "！"), ("?", "？"), ("(", "（"), (")", "）"),
            ("{", "「"), ("}", "」"), ("<", "《"), (">", "》"), ("\\", "、"), ("|", "｜"), ("`", "·"), ("~", "～"),
            ("$", "¥"), ("^", "……"), ("_", "——"), ("\"", "“")
        ]

        // letter-lower
        do {
            let idle = IFEngine()!
            check(press(idle, char("n")) && idle.snapshot().preedit == "n", "letter-lower idle: starts a composition")
            let engine = composing("ni")
            check(press(engine, char("h")) && spelled(engine) == "nih", "letter-lower composing: appended")
            let raw = matched(url)
            check(press(raw, char("x")) && raw.snapshot().preedit == url + "x", "letter-lower match: appended raw")
        }
        // letter-upper
        do {
            let idle = IFEngine()!
            check(press(idle, char("A")) && idle.snapshot().preedit == "A", "letter-upper idle: starts a composition")
            let engine = composing("ni")
            check(press(engine, char("H")) && spelled(engine) == "niH", "letter-upper composing: appended with its case")
            let raw = matched(url)
            check(press(raw, char("X")) && raw.snapshot().preedit == url + "X", "letter-upper match: appended raw")
        }
        // digit-page
        do {
            idleIgnores(char("2"), "digit-page")
            let engine = composing("shi"), page = engine.snapshot().candidates
            check(page.count == 5 && press(engine, char("2")) && engine.takeCommit() == page[1]
                  && engine.snapshot().preedit.isEmpty, "digit-page composing: selects the displayed candidate")
            let raw = matched(url)
            check(press(raw, char("2")) && raw.snapshot().preedit == url + "2", "digit-page match: appended raw")
        }
        // digit-zero
        do {
            idleIgnores(char("0"), "digit-zero")
            let engine = composing("shi"), before = engine.snapshot()
            check(press(engine, char("0")) && unchanged(engine, before), "digit-zero composing: swallowed, no effect")
            let raw = matched(url)
            check(press(raw, char("0")) && raw.snapshot().preedit == url + "0", "digit-zero match: appended raw")
        }
        // digit-beyond-page
        do {
            for digit in "6789" {
                idleIgnores(char(digit), "digit-beyond-page")
                let engine = composing("shi"), before = engine.snapshot()
                check(before.candidates.count == 5 && press(engine, char(digit)) && unchanged(engine, before),
                      "digit-beyond-page composing: \(digit) swallowed, no effect")
                let raw = matched(url)
                check(press(raw, char(digit)) && raw.snapshot().preedit == url + String(digit),
                      "digit-beyond-page match: appended raw")
            }
        }
        // space
        do {
            idleIgnores(space, "space")
            let engine = composing("nihao")
            check(press(engine, space) && engine.takeCommit() == "你好", "space composing: commits the highlighted candidate")
            for text in [url + ".com", mail + ".com"] {
                let raw = matched(text)
                check(press(raw, space) && raw.takeCommit() == text && raw.snapshot().preedit.isEmpty,
                      "space match: commits \(text) literally")
            }
        }
        // return
        do {
            idleIgnores(enter, "return")
            let engine = composing("nihao")
            check(press(engine, enter) && engine.takeCommit() == "nihao" && engine.snapshot().preedit.isEmpty,
                  "return composing: commits the raw input")
            for text in [url + ".com", mail + ".com"] {
                let raw = matched(text)
                check(press(raw, enter) && raw.takeCommit() == text && raw.snapshot().preedit.isEmpty,
                      "return match: commits \(text) literally")
            }
        }
        // backspace
        do {
            idleIgnores(backspace, "backspace")
            let engine = composing("ni")
            check(press(engine, backspace) && spelled(engine) == "n", "backspace composing: deletes the last letter")
            let partial = composing("nihao"), all = partial.snapshot().candidates
            let index = all.firstIndex(of: "你")!
            check(index < 5 && press(partial, char(Character(String(index + 1)))) && partial.takeCommit().isEmpty
                  && partial.snapshot().hasSelectedPrefix, "backspace fixture: a partial selection")
            check(press(partial, backspace) && !partial.snapshot().hasSelectedPrefix && partial.snapshot().candidates == all
                  && partial.takeCommit().isEmpty, "backspace composing: reverts the last partial selection first")
            let raw = matched(url)
            check(press(raw, backspace) && raw.snapshot().preedit == "www.exampl", "backspace match: deletes the last character")
            let leaving = matched("www.")
            check(press(leaving, backspace) && spelled(leaving) == "www" && !leaving.snapshot().candidates.isEmpty,
                  "backspace match: input that stops matching composes as usual")
        }
        // escape
        do {
            idleIgnores(escape, "escape")
            let engine = composing("nihao")
            check(press(engine, escape) && engine.snapshot().preedit.isEmpty && engine.takeCommit().isEmpty,
                  "escape composing: cancels without committing")
            for text in [url, mail] {
                let raw = matched(text)
                check(press(raw, escape) && raw.snapshot().preedit.isEmpty && raw.takeCommit().isEmpty,
                      "escape match: cancels \(text) without committing")
            }
        }
        // punctuation-chinese
        do {
            for (character, output) in chinese {
                let key = char(character)
                let alone = IFEngine()!
                check(press(alone, key) && alone.takeCommit() == output, "punctuation-chinese idle: \(character) → \(output)")
                let engine = composing("nihao")
                check(press(engine, key) && engine.takeCommit() == "你好" + output && engine.snapshot().preedit.isEmpty,
                      "punctuation-chinese composing: \(character) commits the highlighted candidate and \(output)")
            }
            let quote = IFEngine()!
            check(press(quote, char("'")) && quote.takeCommit() == "‘", "punctuation-chinese idle: ' → ‘")
            let delimiter = composing("xi")
            check(press(delimiter, char("'")) && delimiter.snapshot().preedit.contains("'") && delimiter.takeCommit().isEmpty,
                  "punctuation-chinese composing: ' is the syllable delimiter")
            for character in "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~" {
                let raw = matched(url)
                check(press(raw, char(character)) && raw.snapshot().preedit == url + String(character) && raw.takeCommit().isEmpty,
                      "punctuation-chinese match: \(character) appended raw")
            }
        }
        // punctuation-ascii
        do {
            let ascii = InputPreferences().setting(.englishPunctuation, to: true)
            for (character, _) in chinese {
                let idle = fresh(ascii)
                check(!press(idle, char(character)) && idle.takeCommit().isEmpty && idle.snapshot().preedit.isEmpty,
                      "punctuation-ascii idle: \(character) passes through")
                let engine = composing("nihao", ascii)
                check(!press(engine, char(character)) && engine.takeCommit() == "你好" && engine.snapshot().preedit.isEmpty,
                      "punctuation-ascii composing: \(character) commits the highlighted candidate and passes through")
            }
            for character in "@.:/-_" {
                let raw = matched(url, ascii)
                check(press(raw, char(character)) && raw.snapshot().preedit == url + String(character),
                      "punctuation-ascii match: \(character) appended raw")
            }
        }
        // at
        do {
            idleIgnores(char("@"), "at")
            // Letters followed by @ are an email start; an apostrophe keeps the input out of the pattern.
            let engine = composing("xi'an")
            check(!press(engine, char("@")) && engine.takeCommit() == "西安" && engine.snapshot().preedit.isEmpty,
                  "at composing: commits the highlighted candidate and passes through")
            for letters in ["name", "nihao"] {
                let start = composing(letters)
                check(press(start, char("@")) && start.snapshot().preedit == letters + "@" && start.snapshot().candidates.isEmpty
                      && start.takeCommit().isEmpty, "at match: \(letters)@ starts an email")
            }
            let raw = matched(mail)
            check(press(raw, char("@")) && raw.snapshot().preedit == mail + "@", "at match: appended raw")
        }
        // dot
        do {
            let idle = IFEngine()!
            check(press(idle, char(".")) && idle.takeCommit() == "。", "dot idle: Chinese full stop")
            let engine = composing("nihao")
            check(press(engine, char(".")) && engine.takeCommit() == "你好。", "dot composing: highlighted candidate and 。")
            for prefix in ["www", "ftp"] {
                let start = composing(prefix)
                check(press(start, char(".")) && start.snapshot().preedit == prefix + "." && start.snapshot().candidates.isEmpty
                      && start.takeCommit().isEmpty, "dot match: \(prefix). starts a URL")
            }
            let later = matched("www.example")
            check(press(later, char(".")) && later.snapshot().preedit == "www.example.", "dot match: appended raw")
            let longer = composing("wwww")
            check(press(longer, char(".")) && longer.takeCommit().hasSuffix("。"), "dot composing: wwww. is not a URL")
        }
        // colon
        do {
            let idle = IFEngine()!
            check(press(idle, char(":")) && idle.takeCommit() == "：", "colon idle: Chinese colon")
            let engine = composing("nihao")
            check(press(engine, char(":")) && engine.takeCommit() == "你好：", "colon composing: highlighted candidate and ：")
            for prefix in ["http", "https", "ftp", "mailto", "file"] {
                let start = composing(prefix)
                check(press(start, char(":")) && start.snapshot().preedit == prefix + ":" && start.snapshot().candidates.isEmpty
                      && start.takeCommit().isEmpty, "colon match: \(prefix): starts a URL")
            }
            let later = matched("https://example.com")
            check(press(later, char(":")) && later.snapshot().preedit == "https://example.com:", "colon match: appended raw")
        }
        // slash
        do {
            idleIgnores(char("/"), "slash")
            let engine = composing("nihao")
            check(!press(engine, char("/")) && engine.takeCommit() == "你好" && engine.snapshot().preedit.isEmpty,
                  "slash composing: commits the highlighted candidate and passes through")
            let start = composing("https")
            send(start, ":")
            for character in "//example.com/a/b" { check(press(start, char(character)), "slash match: \(character) accepted") }
            check(start.snapshot().preedit == "https://example.com/a/b", "slash match: appended raw")
            check(press(start, space) && start.takeCommit() == "https://example.com/a/b", "slash match: commits literally")
        }
        // paging-keys
        do {
            idleIgnores(pageUp, "paging-keys"); idleIgnores(pageDown, "paging-keys")
            let engine = composing("shi"), first = engine.snapshot().candidates
            check(press(engine, pageDown) && engine.snapshot().page == 1 && engine.takeCommit().isEmpty,
                  "paging-keys composing: Page Down")
            check(press(engine, pageUp) && engine.snapshot().page == 0 && engine.snapshot().candidates == first,
                  "paging-keys composing: Page Up")
            for key in [pageDown, pageUp] {
                let raw = matched(url), before = raw.snapshot(), handled = press(raw, key)
                check(handled && unchanged(raw, before), "paging-keys match: swallowed, no menu: \(handled) \(raw.snapshot())")
            }
        }
        // paging-bound-keys
        do {
            let idle = IFEngine()!
            check(press(idle, char("[")) && idle.takeCommit() == "【" && press(idle, char("]")) && idle.takeCommit() == "】",
                  "paging-bound-keys idle: brackets are Chinese punctuation")
            idleIgnores(char("-"), "paging-bound-keys"); idleIgnores(char("="), "paging-bound-keys")
            for (next, previous) in [("]", "["), ("=", "-")] {
                let engine = composing("shi"), first = engine.snapshot().candidates
                check(press(engine, char(Character(next))) && engine.snapshot().page == 1 && engine.takeCommit().isEmpty,
                      "paging-bound-keys composing: \(next) pages forward")
                check(press(engine, char(Character(previous))) && engine.snapshot().page == 0
                      && engine.snapshot().candidates == first, "paging-bound-keys composing: \(previous) pages back")
            }
            for character in "[]-=" {
                let raw = matched(url)
                check(press(raw, char(character)) && raw.snapshot().preedit == url + String(character),
                      "paging-bound-keys match: \(character) appended raw")
            }
        }
        // arrows-vertical
        do {
            idleIgnores(up, "arrows-vertical"); idleIgnores(down, "arrows-vertical")
            let engine = composing("shi"), first = engine.snapshot().candidates
            check(press(engine, down) && engine.snapshot().highlight == 1, "arrows-vertical composing: Down moves the highlight")
            check(press(engine, up) && engine.snapshot().highlight == 0, "arrows-vertical composing: Up moves it back")
            press(engine, down)
            check(press(engine, space) && engine.takeCommit() == first[1], "arrows-vertical composing: Space commits the highlight")
            for key in [down, up] {
                let raw = matched(url), before = raw.snapshot(), handled = press(raw, key)
                check(handled && unchanged(raw, before), "arrows-vertical match: swallowed, no menu: \(handled) \(raw.snapshot())")
            }
        }
        // arrows-horizontal
        do {
            idleIgnores(left, "arrows-horizontal"); idleIgnores(right, "arrows-horizontal")
            let engine = composing("nihao"), end = engine.snapshot().cursor
            check(press(engine, left) && engine.snapshot().cursor < end && engine.takeCommit().isEmpty,
                  "arrows-horizontal composing: Left moves the caret")
            check(press(engine, right) && engine.snapshot().cursor == end, "arrows-horizontal composing: Right moves it back")
            let raw = matched(url)
            check(press(raw, left) && raw.snapshot().cursor == url.count - 1 && raw.snapshot().preedit == url,
                  "arrows-horizontal match: Left moves the caret in the raw text")
            check(press(raw, right) && raw.snapshot().cursor == url.count, "arrows-horizontal match: Right moves it back")
            // Rime rebuilds the composition at the start of the input and cannot keep a later candidate
            // highlighted there, so the page at the start keeps Rime's order (see `home`).
            let reordered = fresh()
            reordered.setPrecedingText("准备午")
            send(reordered, "can")
            for _ in 0..<3 { press(reordered, left) }
            check(reordered.snapshot().cursor == 0 && reordered.snapshot().highlight == 0,
                  "arrows-horizontal composing: Left onto the start of a reordered page highlights the first candidate: \(reordered.snapshot())")
        }
        // Three pages for the Home and End rows: Rime's own order, a page the context reordered, and a page
        // led by a learned mixed sentence. The last two show a first candidate that is not Rime's first.
        var learned = false
        func pages() -> [(name: String, engine: IFEngine, reordered: Bool)] {
            if !learned {
                let teacher = composing("wokannetflix")
                guard let index = teacher.snapshot().candidates.firstIndex(of: "我看netflix") else {
                    check(false, "home fixture: the mixed sentence is missing: \(teacher.snapshot().candidates)"); return []
                }
                teacher.select(index)
                check(teacher.takeCommit() == "我看netflix", "home fixture: select the mixed sentence")
                teacher.key(0xff09)
                learned = true
            }
            let context = fresh()
            context.setPrecedingText("准备午")
            send(context, "can")
            return [("native", composing("nihao"), false), ("context", context, true), ("learned mixed", composing("wokannetflix"), true)]
        }
        // home
        do {
            idleIgnores(home, "home")
            for (name, engine, reordered) in pages() {
                let before = engine.snapshot(), led = engine.qualitySnapshot()
                check(before.highlight == 0 && (led.candidates.first?.nativeIndex != 0) == reordered,
                      "home \(name) fixture: \(led.candidates)")
                let handled = press(engine, home), committed = engine.takeCommit()
                let state = engine.snapshot(), quality = engine.qualitySnapshot()
                check(handled && committed.isEmpty && state.cursor == 0 && quality.caret == 0 && quality.rawInput == led.rawInput,
                      "home \(name): the caret moves to the start: \(state)")
                check(state.highlight == 0 && quality.highlightedDisplayIndex == 0 && Set(state.candidates) == Set(before.candidates),
                      "home \(name): the first candidate of the page is highlighted: \(state) vs \(before)")
                check(quality.candidates.allSatisfy { $0.nativeIndex == $0.displayIndex },
                      "home \(name): the page at the start keeps Rime's order: \(quality.candidates)")
                let again = press(engine, home), repeated = engine.snapshot()
                check(again && repeated == state && engine.takeCommit().isEmpty,
                      "home \(name): a second press at the start changes nothing: \(repeated)")
            }
            // The key moves the caret in one press, whatever the highlight was.
            let moved = composing("shi")
            press(moved, down); press(moved, down)
            check(moved.snapshot().highlight == 2, "home fixture: the highlight is on the third candidate")
            let handled = press(moved, home), state = moved.snapshot()
            check(handled && state.cursor == 0 && state.highlight == 0,
                  "home composing: a moved highlight does not take the first press: \(state)")
            let raw = matched(url), rawHandled = press(raw, home)
            check(rawHandled && raw.snapshot().cursor == 0 && raw.snapshot().preedit == url,
                  "home match: moves the caret to the start of the raw text: \(raw.snapshot())")
        }
        // end
        do {
            idleIgnores(end, "end")
            for (name, engine, _) in pages() {
                // At the end of the input the key changes nothing, even where the first candidate is not Rime's first.
                let before = engine.snapshot(), atEnd = press(engine, end)
                check(atEnd && unchanged(engine, before), "end \(name): at the end nothing changes: \(engine.snapshot()) vs \(before)")
                // From the start the caret returns to the end and the page is ranked again.
                press(engine, home)
                check(engine.snapshot().cursor == 0, "end \(name) fixture: the caret is at the start")
                let handled = press(engine, end), committed = engine.takeCommit(), state = engine.snapshot()
                check(handled && committed.isEmpty && state == before,
                      "end \(name): from the start the caret returns to the end and the page is ranked again: \(state) vs \(before)")
            }
            let moved = composing("shi"), last = moved.snapshot().cursor
            press(moved, down)
            check(moved.snapshot().highlight == 1, "end fixture: the highlight is on the second candidate")
            let handled = press(moved, end), state = moved.snapshot()
            check(handled && state.highlight == 0 && state.cursor == last,
                  "end composing: at the end the highlight returns to the first candidate: \(state)")
            let raw = matched(url)
            press(raw, left)
            let rawHandled = press(raw, end)
            check(rawHandled && raw.snapshot().cursor == url.count && raw.snapshot().preedit == url,
                  "end match: moves the caret to the end of the raw text: \(raw.snapshot())")
        }
        print("PASS composition keys: letter-lower, letter-upper, digit-page, digit-zero, digit-beyond-page, space, return, backspace, escape, punctuation-chinese, punctuation-ascii, at, dot, colon, slash, paging-keys, paging-bound-keys, arrows-vertical, arrows-horizontal, home, end")
    }

    /// An exact technical English word leads the page when its input is 4 or more letters that are
    /// not complete Pinyin syllables optionally followed by one unfinished final syllable (rule 14).
    /// Every guard input kept the first candidate recorded on `main` before this rule existed.
    @MainActor package static func technicalEnglishLead(event: Event = rimeEvent) {
        let engine = IFEngine()!
        func first(_ input: String) -> String? {
            engine.clear()
            for character in input {
                _ = event(engine, Int32(character.asciiValue!), 0, String(character), character.isUppercase ? 1 : 0)
            }
            return engine.snapshot().candidates.first
        }
        // technical-guard: complete Pinyin, an unfinished final syllable, abbreviations and inputs of
        // three letters or fewer keep the first candidate recorded before the rule.
        let guards = [("tin", "题嗯"), ("chin", "吃嗯"), ("women", "我们"), ("can", "惨"), ("hen", "很"),
                      ("bs", "不是"), ("hlw", "互联网"), ("zhguo", "中国"), ("nihao", "你好"),
                      ("xianzaiwomenlai", "现在我们来"), ("shanghai", "伤害"),
                      ("email", "而买了"), ("banana", "芭娜娜")]
        for (input, expected) in guards {
            let candidate = first(input)
            check(candidate == expected, "technical-guard \(input): first candidate stays \(expected), got \(candidate ?? "none")")
        }
        // technical-lead: the English word beats the reading built from abbreviations and typos.
        for (input, expected) in [("macos", "macOS"), ("deepseek", "DeepSeek"), ("ios", "iOS")] {
            let candidate = first(input)
            check(candidate == expected, "technical-lead \(input): \(expected) leads the page, got \(candidate ?? "none"): \(engine.snapshot().candidates)")
        }
        // technical-lead: the Chinese reading stays selectable behind it.
        _ = first("macos")
        check(engine.snapshot().candidates.contains("马刺欧式"), "technical-lead macos: the Chinese reading stays on the page")
        engine.key(0xff54)
        engine.key(32)
        check(engine.takeCommit() == "马刺欧式", "technical-lead macos: the displayed second candidate commits the Chinese reading")
        engine.clear()
        print("PASS technical English lead: macos/deepseek/ios lead, the Chinese reading stays behind, Pinyin-shaped and short inputs keep their first candidate")
    }

    /// Shift+Backspace forgets the learning of the highlighted candidate and nothing else: Rime's own
    /// delete_candidate for Chinese and standalone English, one negative update per learned ASCII run for
    /// a mixed sentence, the heaviest learned word of a Chinese sentence made of learned words. The words
    /// are used by no other test, and every record is forgotten again.
    @MainActor package static func forgetCandidate(event: Event = rimeEvent) {
        // A session still composing from an earlier case would keep the custom phrase file from reloading.
        for other in IFEngine.liveSessions { other.clear() }
        let engine = IFEngine()!
        @discardableResult func forget() -> Bool { event(engine, 0xff08, 51, "\u{8}", 1) }
        func compose(_ input: String) { engine.clear(); type(engine, input) }
        func candidates(_ input: String) -> [String] { compose(input); return engine.snapshot().candidates }
        // The texts of the first page that carry the user's own confirmations.
        func personal(_ input: String) -> [String] {
            compose(input)
            return engine.qualitySnapshot().candidates.filter { $0.source != nil }.map(\.text)
        }
        // Select a candidate, then end the undo window as the next key of a user typing on does.
        func learn(_ input: String, _ text: String) {
            guard let index = candidates(input).firstIndex(of: text) else {
                check(false, "forget fixture: \(text) is missing for \(input): \(engine.snapshot().candidates)"); return
            }
            engine.select(index)
            check(engine.takeCommit() == text && engine.snapshot().preedit.isEmpty, "forget fixture: select \(text)")
            engine.key(0xff09)
        }
        // Shift+Backspace on the highlighted candidate consumes the key and leaves the composition open.
        func forgetKeepsComposition(_ row: String) {
            let input = engine.qualitySnapshot().rawInput
            check(forget(), "\(row): the key is consumed")
            check(engine.takeCommit().isEmpty && !engine.snapshot().preedit.isEmpty
                  && engine.qualitySnapshot().rawInput == input, "\(row): nothing is committed, the composition stays open")
        }

        // Idle: the key passes through to the application and never enters Rime.
        check(!forget() && engine.takeCommit().isEmpty && engine.snapshot().preedit.isEmpty, "forget idle: passes through")
        compose("ni")
        check(event(engine, 0xff08, 51, "\u{8}", 0) && engine.snapshot().preedit == "n", "forget: plain Backspace still edits")

        // A recognizer match has no candidates: nothing to forget, the key edits like Backspace.
        compose("www.example")
        check(forget() && engine.snapshot().preedit == "www.exampl" && engine.takeCommit().isEmpty,
              "forget match: deletes the last character: \(engine.snapshot())")

        // Chinese: a candidate learned to first place returns to its native position, other learning stays.
        let native = candidates("yuyan"), nativeOther = candidates("wenti")
        check(native.count == 5 && nativeOther.count == 5, "forget Chinese fixture: \(native) \(nativeOther)")
        learn("yuyan", native[2]); learn("wenti", nativeOther[1])
        check(candidates("yuyan").first == native[2], "forget Chinese: the learned candidate leads: \(engine.snapshot().candidates)")
        let learnedOther = candidates("wenti")
        check(learnedOther.first == nativeOther[1], "forget Chinese: the other candidate leads: \(learnedOther)")
        compose("yuyan")
        forgetKeepsComposition("forget Chinese")
        check(engine.snapshot().candidates == native && engine.snapshot().highlight == 0,
              "forget Chinese: the candidate returns to its native position: \(engine.snapshot().candidates) vs \(native)")
        check(candidates("wenti") == learnedOther, "forget Chinese: another learned entry is unchanged")
        // Only the highlighted candidate is forgotten, and the highlight stays at its index.
        engine.key(0xff54)
        check(engine.snapshot().highlight == 1)
        forgetKeepsComposition("forget Chinese highlighted")
        check(engine.snapshot().candidates == learnedOther && engine.snapshot().highlight == 1,
              "forget Chinese: a candidate without learning changes nothing and the highlight stays: \(engine.snapshot())")
        engine.key(0xff52)
        forgetKeepsComposition("forget Chinese cleanup")
        check(engine.snapshot().candidates == nativeOther, "forget Chinese: the second learned candidate is forgotten too")

        // Standalone English: the personal record is forgotten, the dictionary candidate stays where it is.
        check(personal("docker").isEmpty, "forget English fixture: no personal Docker yet")
        learn("docker", "Docker")
        check(personal("docker") == ["Docker"], "forget English: the learned word carries evidence: \(personal("docker"))")
        let docker = engine.snapshot().candidates, index = docker.firstIndex(of: "Docker")!
        engine.highlight(index)
        forgetKeepsComposition("forget English")
        check(engine.snapshot().candidates.contains("Docker") && engine.qualitySnapshot().candidates.allSatisfy { $0.source == nil }
              && engine.snapshot().highlight == index, "forget English: the record is forgotten: \(engine.qualitySnapshot().candidates)")
        check(personal("docker").isEmpty, "forget English: the next composition has no evidence")

        // Mixed: the sentence loses its personal bucket and falls back behind the Chinese reading.
        let mixed = "wofaleyoutube", sentence = "我发了youtube"
        check(personal(mixed).isEmpty && personal("youtube").isEmpty, "forget mixed fixture: nothing learned yet")
        let before = candidates(mixed)
        check(before.firstIndex(of: sentence) == 1, "forget mixed fixture: \(before)")
        learn(mixed, sentence)
        compose(mixed)
        let learned = engine.qualitySnapshot().candidates
        check(learned[0].text == sentence && learned[0].source == "personal_exact_mixed",
              "forget mixed: the learned sentence leads: \(learned)")
        check(learned[0].nativeIndex != learned[0].displayIndex,
              "forget mixed: the highlighted display slot is not its native slot: \(learned)")
        check(personal("youtube") == ["youtube"], "forget mixed: the run serves standalone English")
        compose(mixed)
        forgetKeepsComposition("forget mixed")
        check(engine.snapshot().candidates == before && engine.qualitySnapshot().candidates.allSatisfy { $0.source == nil },
              "forget mixed: the sentence falls back: \(engine.snapshot().candidates) vs \(before)")
        check(personal("youtube").isEmpty, "forget mixed: the run is forgotten for standalone English too")

        // Sentence: Rime's poet makes a sentence from learned words, so deleting the sentence's own record
        // is not enough, it is made again with the same text. `测试学习奥` for `ceshixuexiao` is learned four
        // ways, and the unlearned first candidate is `测试学校`. Shift+Backspace ends the lead of the
        // sentence by forgetting the learned word that weighs most in it, and leaves other learning alone:
        // words forgotten in vain are given back.
        let typed = "ceshixuexiao", split = "ceshixuexi'ao", target = "测试学习奥"
        let unlearnedSentence = candidates(typed)
        check(unlearnedSentence.first == "测试学校", "forget sentence fixture: \(unlearnedSentence)")
        let music = candidates("shuiguo")
        learn("shuiguo", music[1])
        let learnedMusic = candidates("shuiguo")
        check(learnedMusic.first == music[1], "forget sentence fixture: another learned entry leads: \(learnedMusic)")
        func forgetSentence(_ path: String) {
            compose(typed)
            check(engine.snapshot().candidates.first == target,
                  "forget sentence \(path): the learned sentence leads: \(engine.snapshot().candidates)")
            forgetKeepsComposition("forget sentence \(path)")
            check(engine.snapshot().candidates.first == "测试学校" && engine.snapshot().highlight == 0,
                  "forget sentence \(path): the unlearned candidate leads again: \(engine.snapshot())")
            check(candidates(typed).first == "测试学校", "forget sentence \(path): retyping lists the unlearned candidate first")
            check(candidates("shuiguo") == learnedMusic, "forget sentence \(path): another learned entry is unchanged")
        }
        // Select the candidate with this text, paging forward when it is not on the page.
        func pick(_ text: String) {
            for _ in 0..<6 {
                if let index = engine.snapshot().candidates.firstIndex(of: text) { engine.select(index); return }
                engine.key(0xff56)
            }
            check(false, "forget sentence fixture: \(text) is missing: \(engine.snapshot().candidates)")
        }
        // A sentence that leads without learning: 测试 is learned through the abbreviation `cs`, where it is
        // natively fourth, and is a word of the unlearned `测试学校`. Forgetting it changes nothing there, so
        // Shift+Backspace gives it back.
        let abbreviation = candidates("cs")
        check(abbreviation.first != "测试", "forget sentence fixture: \(abbreviation)")
        learn("cs", "测试")
        check(candidates("cs").first == "测试", "forget sentence fixture: the learned word leads: \(engine.snapshot().candidates)")
        compose(typed)
        check(engine.snapshot().candidates.first == "测试学校", "forget sentence unlearned lead fixture: \(engine.snapshot().candidates)")
        forgetKeepsComposition("forget sentence unlearned lead")
        check(engine.snapshot().candidates.first == "测试学校" && engine.snapshot().highlight == 0,
              "forget sentence unlearned lead: the sentence still leads: \(engine.snapshot())")
        check(candidates("cs").first == "测试", "forget sentence unlearned lead: its word keeps its learning: \(engine.snapshot().candidates)")
        compose("cs")
        forgetKeepsComposition("forget sentence cleanup abbreviation")
        check(engine.snapshot().candidates == abbreviation, "forget sentence cleanup: the word is forgotten: \(engine.snapshot().candidates)")
        // (a) The whole sentence selected as one candidate, twice, after an apostrophe split the input.
        learn(split, target); learn(split, target)
        forgetSentence("whole")
        // (b) Partial selections, twice: 测试, then 学习, then 奥.
        for _ in 0..<2 {
            compose(typed)
            for part in ["测试", "学习", "奥"] { pick(part) }
            check(engine.takeCommit() == target, "forget sentence fixture: partial selections commit the sentence")
            engine.key(0xff09)
        }
        forgetSentence("partial")
        // (c) Its words learned on their own: the sentence has no record, the poet makes it from them.
        learn("ceshixuexi", "测试学习"); learn("ao", "奥")
        forgetSentence("words")
        // (d) Both: the record goes first, and the sentence is made again from the words.
        learn("ao", "奥"); learn(split, target); learn(split, target)
        forgetSentence("words and whole")
        // The words left over and the other learned entry are forgotten again.
        compose("ceshixuexi")
        forgetKeepsComposition("forget sentence cleanup words")
        compose("shuiguo")
        forgetKeepsComposition("forget sentence cleanup")
        check(engine.snapshot().candidates == music, "forget sentence cleanup: the other learned entry is forgotten")

        // A candidate without learning changes nothing, and the highlight, the page and a confirmed
        // prefix survive Rime's recomposition.
        let plain = candidates("zhishi")
        engine.key(0xff54); engine.key(0xff54)
        forgetKeepsComposition("forget unlearned")
        check(engine.snapshot().candidates == plain && engine.snapshot().highlight == 2,
              "forget unlearned: the list and the highlight stay: \(engine.snapshot())")
        compose("zhishi")
        engine.key(0xff56); engine.key(0xff54); engine.key(0xff54)
        let later = engine.snapshot()
        check(later.page == 1 && later.highlight == 2, "forget page fixture: \(later)")
        forgetKeepsComposition("forget page")
        check(engine.snapshot() == later, "forget page: the page and the highlight stay: \(engine.snapshot()) vs \(later)")
        compose("yuyanwenti")
        guard let prefix = engine.snapshot().candidates.firstIndex(of: native[0]) else {
            check(false, "forget prefix fixture: \(engine.snapshot().candidates)"); return
        }
        engine.select(prefix)
        let rest = engine.snapshot()
        check(rest.hasSelectedPrefix && engine.takeCommit().isEmpty, "forget prefix fixture: partial selection \(rest)")
        forgetKeepsComposition("forget prefix")
        check(engine.snapshot().hasSelectedPrefix && engine.snapshot().candidates == rest.candidates,
              "forget prefix: the confirmed prefix and the list stay: \(engine.snapshot()) vs \(rest)")
        // A mixed sentence whose runs have no record writes nothing and keeps its place.
        compose(mixed)
        forgetKeepsComposition("forget unlearned mixed")
        check(engine.snapshot().candidates == before && personal(mixed).isEmpty && personal("youtube").isEmpty,
              "forget unlearned mixed: the list and the evidence stay: \(engine.snapshot().candidates)")
        // A custom phrase keeps its place.
        let phrase = CustomPhrase(id: UUID(), code: "zhishi", text: "自定义知识")
        engine.clear()
        engine.setConfiguration(candidateCount: 5, customPhrases: [phrase])
        let withPhrase = candidates("zhishi")
        check(withPhrase.first == phrase.text, "forget custom phrase fixture: \(withPhrase)")
        forgetKeepsComposition("forget custom phrase")
        check(engine.snapshot().candidates == withPhrase && engine.snapshot().highlight == 0,
              "forget custom phrase: the phrase keeps its place: \(engine.snapshot().candidates)")
        engine.clear()
        engine.setConfiguration(candidateCount: 5, customPhrases: [])
        check(candidates("zhishi") == plain, "forget custom phrase: removing it restores the dictionary list")
        engine.clear()
        print("PASS forget candidate: idle passthrough, Chinese native delete, sentences made of learned words, personal English, mixed runs, unlearned and custom phrase unchanged, composition kept, highlight kept")
    }

    /// An English word the user chose leads the next time when the only Chinese rival is a sentence the
    /// engine composed from separate words (rule 14). A dictionary phrase and a phrase the user learned keep
    /// the first place. The guards kept the first candidate recorded on `main` before this rule existed:
    /// `shanghai` 伤害, `a` 啊 and `release` 热了阿瑟. The learned records stay in the test's user directory.
    @MainActor package static func learnedEnglishOverSentence(event: Event = rimeEvent) {
        let engine = IFEngine()!
        func compose(_ input: String) {
            engine.clear()
            for character in input {
                _ = event(engine, Int32(character.asciiValue!), 0, String(character), character.isUppercase ? 1 : 0)
            }
        }
        func candidates(_ input: String) -> [String] { compose(input); return engine.snapshot().candidates }
        // The texts of the first page that carry the user's own confirmations.
        func personal(_ input: String) -> [String] {
            compose(input)
            return engine.qualitySnapshot().candidates.filter { $0.source != nil }.map(\.text)
        }
        // Select a candidate, then end the undo window as the next key of a user typing on does.
        func learn(_ input: String, _ text: String) {
            guard let index = candidates(input).firstIndex(of: text) else {
                check(false, "learned-english fixture: \(text) is missing for \(input): \(engine.snapshot().candidates)"); return
            }
            engine.select(index)
            check(engine.takeCommit() == text && engine.snapshot().preedit.isEmpty, "learned-english fixture: select \(text)")
            engine.key(0xff09)
        }

        // learned-guard: a dictionary phrase leads `shanghai` with or without the learned English word.
        let shanghai = candidates("shanghai")
        check(shanghai.prefix(3) == ["伤害", "Shanghai", "上海"], "learned-guard shanghai fixture: \(shanghai)")
        learn("shanghai", "Shanghai")
        check(personal("shanghai") == ["Shanghai"], "learned-guard shanghai: the English word is learned: \(engine.qualitySnapshot().candidates)")
        check(candidates("shanghai") == shanghai, "learned-guard shanghai: the phrase keeps its place: \(engine.snapshot().candidates)")
        // learned-guard: a single syllable has no sentence, so a learned `A` stays behind 啊 without a technical context.
        check(candidates("a").first == "啊", "learned-guard a fixture: \(engine.snapshot().candidates)")
        learn("A", "A")
        check(personal("a") == ["A"], "learned-guard a: the English letter is learned: \(engine.qualitySnapshot().candidates)")
        check(engine.snapshot().candidates.first == "啊", "learned-guard a: 啊 keeps its place: \(engine.snapshot().candidates)")

        // learned-lead: before anything is learned, the sentence composed from separate words leads.
        let release = candidates("release")
        check(release.first == "热了阿瑟" && release.contains("release") && personal("release").isEmpty,
              "learned-lead release fixture: \(release)")
        learn("release", "release")
        // learned-lead: the word chosen once leads, and the sentence stays selectable behind it.
        let learned = candidates("release")
        check(learned.first == "release" && learned.contains("热了阿瑟") && engine.snapshot().highlight == 0,
              "learned-lead release: the learned word leads: \(learned)")
        check(personal("release") == ["release"], "learned-lead release: it carries personal evidence: \(engine.qualitySnapshot().candidates)")
        engine.key(32)
        check(engine.takeCommit() == "release", "learned-lead release: the highlighted first candidate commits")
        engine.key(0xff09)
        // learned-lead: the second candidate commits the Chinese reading, which Rime now learns as a phrase.
        compose("release")
        engine.key(0xff54)
        engine.key(32)
        check(engine.takeCommit() == "热了阿瑟", "learned-lead release: the displayed second candidate commits the sentence")
        engine.key(0xff09)
        // learned-guard: a phrase the user learned keeps the first place, with the English word behind it.
        let phrase = candidates("release")
        check(phrase.prefix(2) == ["热了阿瑟", "release"], "learned-guard release: the learned phrase keeps its place: \(phrase)")
        engine.clear()
        print("PASS learned English over sentence: release leads a composed sentence once chosen, a dictionary phrase (shanghai), a single syllable (a) and a learned phrase keep the first place")
    }
}
