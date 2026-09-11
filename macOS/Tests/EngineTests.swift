import AppKit
#if SWIFT_PACKAGE
@testable import InkFlowCore
import InkFlowTestSupport
#endif

@main
struct EngineTests {
    @MainActor static func main() throws {
        let arguments = CommandLine.arguments
        let modes = ["--basic", "--options", "--english", "--context", "--custom-phrases", "--input-settings-only"]
        check(arguments.count == 3 || (arguments.count == 4 && modes.contains(arguments[3])), "Unknown engine scenario")
        let shared = arguments[1], user = arguments[2]
        let mode = arguments.count == 3 ? "all" : arguments[3]
        func selected(_ name: String) -> Bool { mode == "all" || mode == "--\(name)" || (name == "options" && mode == "--input-settings-only") }
        if selected("basic") {
            do {
                try IFEngine.start(shared: "/nonexistent/inkflow", user: user)
                check(false, "Missing resources must fail")
            } catch { check(!(error as NSError).localizedDescription.isEmpty) }
            try missingEnglishResources(shared: shared, user: user)
            try missingEmojiResources(shared: shared, user: user)
        }
        try IFEngine.start(shared: shared, user: user)
        if selected("options") { try inputSettings(user: user) }
        let schemaURL = URL(fileURLWithPath: user).appendingPathComponent("build/inkflow_pinyin.schema.yaml")
        let schemaBefore = try Data(contentsOf: schemaURL)
        if selected("basic") { chineseDictionaryCoverage(); try runCases() }
        if selected("english") {
            try domainVocabulary()
            englishAdmission()
            conservativeChinesePrefixes()
            mixedEnglishCandidates()
            englishCandidates()
            englishFeatureCoexistence()
            spellingCorrection()
        }
        if selected("context") { contextReranking(); contextCustomPhrasePriority(); try rankingRules() }
        if selected("custom-phrases") {
            try customPhrases(user: user)
            let isolated = IsolatedSettings()
            defer { isolated.cleanup() }
            try isolated.settings.saveCustomPhrase(code: "dz", text: "重启后的地址")
            IFEngine.stop()
            try IFEngine.start(shared: shared, user: user)
            do {
                let restored = IFSettings(defaults: isolated.defaults)
                let engine = IFEngine()!
                engine.setConfiguration(candidateCount: 5, customPhrases: restored.customPhrases)
                type(engine, "dz")
                check(engine.snapshot().candidates.first == "重启后的地址")
            }
            IFEngine.stop()
        } else { IFEngine.stop() }
        let schemaAfter = try Data(contentsOf: schemaURL)
        check(schemaAfter == schemaBefore)
        let files = try FileManager.default.contentsOfDirectory(atPath: user)
        check(files.contains("pinyin_simp.userdb"), "Keep the original Chinese user dictionary")
        check(!files.contains("inkflow_mixed.userdb") && !files.contains("easy_en.userdb"),
              "Supplemental translators must not create replacement user dictionaries")
        print("PASS engine: \(mode)")
    }

    @MainActor static func inputSettings(user: String) throws {
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
        check(!engine.event(keyEvent(49, " ", [.control, .shift])) && !engine.requestedASCIIMode,
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
                check(!engine.event(keyEvent(0, text)), "ASCII mode must pass through \(text)")
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

        let isolated = IsolatedSettings()
        defer { isolated.cleanup() }
        let settings = isolated.settings
        settings.setInputOption(.abbreviation, enabled: false)
        settings.setInputOption(.typoTolerance, enabled: false)
        engine.clear(); configure(engine, settings.inputPreferences)
        type(engine, "shi")
        let groupedBefore = engine.snapshot(), groupedRevision = engine.qualityRevision.id
        let groupedOriginal = settings.inputPreferences
        settings.fuzzyEnabled = true
        settings.pagingKeys = .minusEqual
        let groupedUpdated = settings.inputPreferences
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
            settings.fuzzyEnabled = enabled
            configure(engine, settings.inputPreferences)
            for (spelling, word) in [("zongguo", "中国"), ("canpin", "产品"), ("sanghai", "上海")] {
                check(contains(engine, spelling, word) == enabled, "Unified fuzzy setting: \(spelling) = \(enabled)")
            }
            engine.clear()
        }
        for keys in IFSettings.PagingKeys.allCases {
            settings.pagingKeys = keys
            configure(engine, settings.inputPreferences)
            let previous: Int32 = keys == .brackets ? 91 : 45
            let next: Int32 = keys == .brackets ? 93 : 61
            let inactive: Int32 = keys == .brackets ? 61 : 93
            type(engine, "shi"); engine.key(next)
            check(engine.snapshot().page == 1, "Selected paging pair: \(keys.rawValue)")
            engine.key(previous); check(engine.snapshot().page == 0)
            engine.key(inactive)
            check(engine.snapshot().page == 0 && !engine.takeCommit().isEmpty, "Other paging pair retains punctuation behavior")
            engine.clear()
        }
        type(engine, "shi")
        settings.fuzzyEnabled = true; settings.pagingKeys = .brackets
        configure(engine, settings.inputPreferences)
        engine.clear(); type(engine, "zongguo")
        check(engine.inputPreferences == settings.inputPreferences &&
              engine.qualityRevision.configuration.inputOptions == settings.inputPreferences.recordedValues,
              "Cancellation also applies and records complete grouped settings")
        print("PASS grouped input settings: three fuzzy pairs, exclusive paging, selected commit/cancel boundaries, session isolation and effective recorded values")
        print("PASS input settings: spelling recall/toggles, traditional/custom/Emoji, literal mappings, paging, deferred revisions/ASCII, session isolation and missing-prism recovery")
    }

    @MainActor static func chineseDictionaryCoverage() {
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

    @MainActor static func selectCandidate(_ expected: String, input: String, engine: IFEngine) {
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

    @MainActor static func domainVocabulary() throws {
        let engine = IFEngine()!
        let chinese = try String(contentsOfFile: "macOS/config/chinese-overrides.tsv", encoding: .utf8)
        selectCandidate("命令行用户交互", input: "minglinghangyonghujiaohu", engine: engine)
        for line in chinese.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            check(fields.count == 4)
            selectCandidate(String(fields[0]), input: fields[1].replacingOccurrences(of: " ", with: ""), engine: engine)
        }
        selectCandidate("串行打印机", input: "chuanxingdayinji", engine: engine)
        selectCandidate("深度求索", input: "shenduqiusuo", engine: engine)
        selectCandidate("阿米诺斯", input: "aminuosi", engine: engine)
        selectCandidate("并发信息系统", input: "bingfaxinxixitong", engine: engine)
        selectCandidate("eBPF", input: "ebpf", engine: engine)
        selectCandidate("Type-C", input: "typec", engine: engine)
        let english = try String(contentsOfFile: "macOS/Data/english-technology.tsv", encoding: .utf8)
        var count = 0
        for line in english.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            check(fields.count == 3)
            selectCandidate(String(fields[0]), input: String(fields[1]), engine: engine)
            count += 1
        }
        check(count == 122, "Every selected technical English spelling is exercised")
        selectCandidate("API", input: "Api", engine: engine) // Existing easy-en case alias remains available.
        type(engine, "swiftui")
        for prefix in ["swiftui", "swiftu", "swift", "swif", "swi", "sw"] {
            let candidates = allCandidates(engine)
            check(candidates.contains("SwiftUI") == (prefix.count >= 3), "Technology completion/backspace boundary: \(prefix)")
            engine.key(0xff08)
        }
        engine.clear()
        for input in ["woapi", "apihenhao", "wocpp", "wotypec", "claudecodehenhao"] {
            type(engine, input)
            check(!allCandidates(engine).contains { $0.contains("API") || $0.contains("C++") || $0.contains("Type-C") || $0.contains("Claude Code") },
                  "Short/punctuated/spaced technical aliases do not bypass mixed structural restrictions")
            engine.clear()
        }
        engine.setConfiguration(candidateCount: 5, customPhrases: [CustomPhrase(id: UUID(), code: "api", text: "我的接口")])
        engine.setPrecedingText("调用")
        type(engine, "api")
        check(engine.snapshot().candidates.first == "我的接口" && allCandidates(engine).contains("API"),
              "Explicit custom phrases keep priority while technical English remains reachable")
        engine.clear()
        print("PASS domain vocabulary: all curated Chinese and 122 technical English spellings selectable; exact case/punctuation/space commits, aliases, prefix/backspace, mixed boundaries and custom phrase coexistence")
    }

    @MainActor static func conservativeChinesePrefixes() {
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
            print("TRACE Chinese \(direction) \(input) => \(first)\(valid ? "" : " [FAIL]")")
            if !valid { failures += 1 }
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
        print("TRACE Chinese prefix summary: \(steps) steps, \(failures) failures, \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        check(failures == 0, "Chinese partial input must stay ahead of English")
        print("PASS conservative Chinese: short keys, incomplete syllables, all prefixes and backspaces")
    }

    @MainActor static func missingEnglishResources(shared: String, user: String) throws {
        for resource in ["inkflow_mixed.schema.yaml", "inkflow_mixed.dict.yaml",
                         "lua/inkflow_english.lua", "lua/inkflow_mixed.lua", "lua/inkflow_short_conflict.lua",
                         "lua/inkflow_ai_learning.lua"] {
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
            print("TRACE mixed recall \(input) => \(engine.snapshot().candidates)")
            engine.clear()
            selectCandidate(expected, input: input, engine: engine)
        }
        type(engine, "woyong")
        for (keyCode, letter) in [(UInt16(0), "A"), (UInt16(35), "P"), (UInt16(34), "I")] {
            check(engine.event(keyEvent(keyCode, letter, .shift)))
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
        type(engine, "wofaleemail")
        let mixedCollision = engine.snapshot().candidates
        check(mixedCollision.first?.unicodeScalars.allSatisfy { $0.value > 127 } == true,
              "Complete Chinese coverage leads mixed English: \(mixedCollision)")
        print("TRACE mixed collision wofaleemail => \(mixedCollision)")
        engine.select(0)
        check(engine.takeCommit() == mixedCollision.first && engine.snapshot().preedit.isEmpty,
              "The leading Chinese candidate must consume the complete mixed input")
        type(engine, "wofaleemail")
        guard let emailIndex = engine.snapshot().candidates.firstIndex(of: "我发了email") else {
            check(false, "Keep colliding mixed email selectable: \(engine.snapshot().candidates)"); return
        }
        engine.select(emailIndex)
        check(engine.takeCommit() == "我发了email" && engine.snapshot().preedit.isEmpty)
        for (input, expected) in [("compute", "computer"), ("comm", "community"),
                                  ("actual", "actual"), ("cpp", "C++"), ("macos", "macOS")] {
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
        for input in ["Hello", "email"] {
            type(engine, input)
            let english = engine.snapshot().candidates.filter { $0.unicodeScalars.allSatisfy { $0.value < 128 } }
            check(english.first == input, "Prefer an exact case match among English with equal source weights")
            engine.clear()
        }
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

    @MainActor static func englishFeatureCoexistence() {
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
        print("PASS English integration: Chinese context priority, English reachability/order, mixed commits and custom phrase coexistence")
    }

    @MainActor static func allCandidates(_ engine: IFEngine) -> [String] {
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

    @MainActor static func englishAdmission() {
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
            print("TRACE English admission \(input) => \(candidates)")
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

    @MainActor static func missingEmojiResources(shared: String, user: String) throws {
        let directory = URL(fileURLWithPath: user).appendingPathComponent("incomplete-resources")
        let files = FileManager.default
        try files.createDirectory(at: directory.appendingPathComponent("opencc"), withIntermediateDirectories: true)
        try files.createDirectory(at: directory.appendingPathComponent("lua"), withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        for name in ["default.yaml", "inkflow_pinyin.schema.yaml", "pinyin_simp.dict.yaml",
                     "easy_en.schema.yaml", "easy_en.dict.yaml",
                     "inkflow_mixed.schema.yaml", "inkflow_mixed.dict.yaml",
                     "lua/inkflow_english.lua", "lua/inkflow_mixed.lua", "lua/inkflow_short_conflict.lua",
                     "lua/inkflow_ai_learning.lua",
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
        print("TRACE homophone correction: beijing=\(normalCandidates), beijign=\(typoCandidates)")
        guard let cityIndex = typoCandidates.firstIndex(of: "北京") else {
            check(false, "Keep 北京 reachable after final transposition"); return
        }
        city.select(cityIndex)
        check(city.takeCommit() == "北京")
        for (input, expected) in [("nihao", "你好"), ("zhidao", "知道"), ("shanghai", "伤害"),
                                  ("jinnian", "今年"), ("nannv", "男女"), ("tiananmen", "天安门"),
                                  ("xi'an", "西安")] {
            let engine = IFEngine()!
            type(engine, input)
            check(engine.snapshot().candidates.first == expected, "Normal spelling \(input): \(engine.snapshot())")
            if input == "shanghai" {
                let candidates = engine.snapshot().candidates
                print("TRACE homophone shanghai: \(candidates)")
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
        engine.asciiMode = true
        for code in "nnihao".utf16 { check(!engine.key(Int32(code))) }
        check(engine.snapshot().preedit.isEmpty && engine.takeCommit().isEmpty)
        print("PASS spelling correction: 12 typo phrases, normal spelling/boundaries, editable preedit, selection, cancel, ASCII passthrough")
    }

    @MainActor static func customPhrases(user: String) throws {
        let isolated = IsolatedSettings()
        defer { isolated.cleanup() }
        let settings = isolated.settings
        for phrase in ["地址甲", "地址乙", "地址丙", "地址丁", "地址戊", "地址己", "地址庚", "地址辛", "地址壬", "地址癸", "地址十一", "地址十二"] {
            try settings.saveCustomPhrase(code: "dz", text: phrase)
        }
        try settings.saveCustomPhrase(code: "nihao", text: "您好朋友")
        try settings.saveCustomPhrase(code: "nihao", text: "你好")
        try settings.saveCustomPhrase(code: "bq", text: "#标签")
        try settings.saveCustomPhrase(code: "zw", text: "# no comment")
        let a = IFEngine()!, b = IFEngine()!
        a.setConfiguration(candidateCount: 3, customPhrases: settings.customPhrases)
        b.setConfiguration(candidateCount: 3, customPhrases: settings.customPhrases)
        check(a.configurationError == nil)
        for phrase in settings.customPhrases.suffix(2) {
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
        let shiPhrases = settings.customPhrases.prefix(12).map { CustomPhrase(id: $0.id, code: "shi", text: $0.text) }
        a.setConfiguration(candidateCount: 3, customPhrases: shiPhrases)
        type(b, "shi"); let ordinary = b.snapshot().candidates; b.clear()
        type(a, "shi")
        for _ in 0..<4 { a.key(0xff56) }
        check(!ordinary.isEmpty && a.snapshot().candidates == ordinary, "Ordinary candidates must remain after all custom phrases")
        a.clear()
        a.setConfiguration(candidateCount: 3, customPhrases: settings.customPhrases)
        type(a, "dz"); a.select(1); check(a.takeCommit() == "地址乙")
        a.setConfiguration(candidateCount: 9, customPhrases: settings.customPhrases)
        type(a, "dz"); check(a.snapshot().candidates.count == 9)
        a.key(57); check(a.takeCommit() == "地址壬")
        type(a, "dz"); let old = a.snapshot()
        let changed = try settings.saveCustomPhrase(id: settings.customPhrases[0].id, code: "dz", text: "更新地址")
        a.setConfiguration(candidateCount: 5, customPhrases: settings.customPhrases)
        a.setConfiguration(candidateCount: 3, customPhrases: [changed])
        check(a.snapshot() == old && a.takeCommit().isEmpty && a.candidateCount == 9)
        a.key(32)
        // Applying settings between a completed composition and draining its commit must not lose text.
        a.setConfiguration(candidateCount: 3, customPhrases: [changed])
        check(a.takeCommit() == "地址甲")
        type(a, "dz"); check(a.snapshot().candidates.first == "更新地址" && a.candidateCount == 3)
        a.clear(); type(b, "dz"); check(b.snapshot().candidates.first == "地址甲")
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
        a.setConfiguration(candidateCount: 9, customPhrases: settings.customPhrases)
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
        check(a.configurationError == nil)
        type(a, "dz"); check(a.snapshot().candidates.first == changed.text); a.clear()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: user).filter { $0.hasPrefix("inkflow_phrases_") }
        check(leftovers.isEmpty, "Temporary dictionaries must be removed after synchronous load")
        print("PASS custom phrase engine: exact match, priority/coexistence, Unicode/hash text, dedup, native pagination/digits/click, coalesced idle reload, pending commits, ASCII, existing/fresh sessions, removal after selection, write failure/retry, TSV cleanup")
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
        a.asciiMode = true; check(!a.key(97))
        a.asciiMode = false; type(a, "nihao"); a.commit(); check(a.takeCommit() == "你好")
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
            engine.asciiMode = true
            for key in "nihao".utf8 { check(!engine.key(Int32(key))) }
            check(engine.snapshot().candidates.isEmpty && engine.takeCommit().isEmpty)
        }
        print("PASS emoji: simplified keywords, original words preserved, unique candidates, full Unicode commits, digit/space selection, 3/5/9 paging, cancel, English passthrough")
    }

    @MainActor static func contextReranking() {
        func prepared(_ prefix: String = "准备午", _ input: String = "can", count: Int = 5) -> IFEngine {
            let engine = IFEngine()!
            engine.setCandidateCount(count)
            engine.setPrecedingText(prefix); type(engine, input)
            return engine
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

    @MainActor static func contextCustomPhrasePriority() {
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

    @MainActor static func rankingRules() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("ranking-fixture.yaml")
        defer { try? FileManager.default.removeItem(at: url) }
        try "午餐\twu can\t100\n午参\twu can\t100\n午惨\twu can\t50\n准备午参\tzhun bei wu can\t1\n迷你\tmi ni\t70\n".write(to: url, atomically: true, encoding: .utf8)
        let ranker = try IFContextRanker(dictionary: url.path)
        check(ranker.order(["惨", "餐", "参"], precedingText: "准备午") == [2, 1, 0], "Longer crossing phrases precede frequency")
        check(ranker.order(["惨", "餐", "参"], precedingText: "午") == [1, 2, 0], "Frequency then stable original order")
        check(ranker.order(["惨", "can", "餐", "你"], precedingText: "午") == [2, 1, 0, 3],
              "Context reorders eligible Han candidates only within their original slots")
        check(ranker.order(["你好", "你"], precedingText: "迷") == [0, 1], "Unequal-length choices remain in the native relative order")
        print("PASS context ranking rules: longer match, frequency, stable ties, fixed ineligible slots, partial length guard")
    }

    @MainActor static func englishCandidates() {
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
                    print("TRACE single-letter English \(input) -> \(expected) selected on page \(snapshot.page)")
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
        print("TRACE English space selection hello => \(helloCandidates)")
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

    @MainActor static func punctuation() {
        let cases: [(String, String, UInt16, Bool)] = [
            ("{", "「", 33, true), ("}", "」", 30, true), ("[", "【", 33, false), ("]", "】", 30, false),
            ("<", "《", 43, true), (">", "》", 47, true), ("\\", "、", 42, false), ("|", "｜", 42, true),
            ("`", "·", 50, false), ("~", "～", 50, true), ("$", "¥", 21, true), ("^", "……", 22, true),
            ("_", "——", 27, true), (",", "，", 43, false), (".", "。", 47, false), (";", "；", 41, false),
            (":", "：", 41, true), ("!", "！", 18, true), ("?", "？", 44, true), ("(", "（", 25, true), (")", "）", 29, true)
        ]
        for (input, expected, code, shifted) in cases {
            let engine = IFEngine()!
            let key = keyEvent(code, input, shifted ? .shift : [])
            check(engine.event(key)); check(engine.takeCommit() == expected)
            check(engine.snapshot().preedit.isEmpty)
            engine.asciiMode = true; check(!engine.event(key)); check(engine.takeCommit().isEmpty)
        }
        for (input, expected) in [("\"\"\"\"", "“”“”"), ("''''", "‘’‘’"), ("\"'\"'", "“‘”’")] {
            let engine = IFEngine()!
            for (quote, output) in zip(input, expected) {
                check(engine.event(keyEvent(39, String(quote), quote == "\"" ? .shift : [])))
                check(engine.takeCommit() == String(output)); check(engine.snapshot().preedit.isEmpty)
            }
            engine.asciiMode = true
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
