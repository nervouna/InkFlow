import InkFlowEngineTestSupport
@testable import InkFlowRime
@testable import InkFlowDomain
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
            shortConflictBounds()
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

    @MainActor static func chineseDictionaryCoverage() { EngineRegression.chineseDictionaryCoverage() }

    @MainActor static func selectCandidate(_ expected: String, input: String, engine: IFEngine) { EngineRegression.selectCandidate(expected, input: input, engine: engine) }

    @MainActor static func domainVocabulary() throws { try EngineRegression.domainVocabulary() }

    @MainActor static func conservativeChinesePrefixes() { EngineRegression.conservativeChinesePrefixes() }

    @MainActor static func missingEnglishResources(shared: String, user: String) throws { try EngineRegression.missingEnglishResources(shared: shared, user: user) }

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

    @MainActor static func englishFeatureCoexistence() { EngineRegression.englishFeatureCoexistence() }

    @MainActor static func shortConflictBounds() { EngineRegression.shortConflictBounds() }

    @MainActor static func allCandidates(_ engine: IFEngine) -> [String] { EngineRegression.allCandidates(engine) }

    @MainActor static func englishAdmission() { EngineRegression.englishAdmission() }

    @MainActor static func missingEmojiResources(shared: String, user: String) throws { try EngineRegression.missingEmojiResources(shared: shared, user: user) }

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

    @MainActor static func emojiCandidates() { EngineRegression.emojiCandidates() }

    @MainActor static func contextReranking() { EngineRegression.contextReranking() }

    @MainActor static func contextCustomPhrasePriority() { EngineRegression.contextCustomPhrasePriority() }

    @MainActor static func rankingRules() throws { try EngineRegression.rankingRules() }

    @MainActor static func englishCandidates() { EngineRegression.englishCandidates() }

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
    }}
