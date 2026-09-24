import Foundation
#if SWIFT_PACKAGE
@testable import InkFlowCore
import InkFlowTestSupport
#endif

@main
struct AIAdoptionLearningTests {
    @MainActor static func main() async throws {
        let shared = CommandLine.arguments[1], user = CommandLine.arguments[2]
        let scenario = CommandLine.arguments[3]
        let writing = scenario == "write"
        let readsDuringUndo = CommandLine.arguments.count < 5 || CommandLine.arguments[4] != "no-voice-read"
        let bootstrap = ContinuousClock.now
        try IFEngine.start(shared: shared, user: user)
        print("TRACE AI learning bootstrap: \(bootstrap.duration(to: .now))")
        defer { IFEngine.stop() }
        let engine = IFEngine()!
        engine.setConfiguration(candidateCount: 9, customPhrases: [], inputPreferences: .init())
        if scenario.hasPrefix("contract-") {
            try learningContract(engine: engine, user: user, scenario: scenario)
            print("PASS Rime learning contract \(scenario)")
            return
        }
        if scenario.hasPrefix("english-") {
            try keyboardEnglishLearning(engine: engine, user: user, scenario: scenario)
            print("PASS keyboard English learning \(scenario)")
            return
        }
        if scenario.hasPrefix("mixed-") {
            try mixedPersonalEnglish(engine: engine, scenario: scenario)
            print("PASS mixed personal English \(scenario)")
            return
        }
        let initialVoice = engine.readVoiceLexicon(generation: 1, revision: 1)
        check(initialVoice.availability == .available, "Bundled Lua supports bounded user dictionary lookup")
        let words = [("xingmoliang", "星墨量"), ("xingmolan", "星墨蓝"), ("xingmohai", "星墨海"), ("xingmohao", "星墨好")]
        func candidates(_ input: String) -> [String] {
            engine.clear(); type(engine, input)
            var result: [String] = []
            for _ in 0..<20 {
                let page = engine.snapshot()
                result += page.candidates
                if page.candidates.isEmpty { break }
                engine.key(0xff56)
                if engine.snapshot().page == page.page { break }
            }
            engine.clear()
            return result
        }
        if writing {
            func ordinaryCommit(_ input: String, expected: String, undo: Bool) {
                engine.clear(); type(engine, input); engine.key(32)
                check(engine.takeCommit() == expected)
                if readsDuringUndo {
                    for _ in 0..<3 {
                        let view = engine.readVoiceLexicon(generation: 1, revision: 2)
                        check(view.availability == .unknown, "Snapshot requests never touch Rime during its undo window")
                    }
                }
                engine.key(undo ? 0xff08 : 0xff09)
            }
            // With AI never requested, its bridge must not change ordinary undo.
            ordinaryCommit("nihao", expected: "你好", undo: true)
            type(engine, "yh")
            let bankInput = engine.aiInputIdentity()!
            let lookup = ContinuousClock.now
            let bank = engine.aiPronunciation(input: bankInput, text: "银行")
            check(bank.resolve(input: "yh", text: "银行") == "yin hang ", "Existing native phrase resolves abbreviated polyphone")
            print("TRACE native reading lookup: \(lookup.duration(to: .now))")
            engine.clear(); type(engine, "h")
            let ambiguous = engine.aiPronunciation(input: engine.aiInputIdentity()!, text: "行")
            check(ambiguous.resolve(input: "h", text: "行") == nil, "Unification must not hide alternate readings")
            engine.clear()
            let dictionary = try String(contentsOfFile: shared + "/pinyin_simp.dict.yaml", encoding: .utf8)
            for (_, word) in words { check(!dictionary.contains("\n" + word + "\t"), "Fixture must be novel") }
            let inputs = ["xingmoliang", "xml", "xingmoha", "xingmohoa"]
            for (index, pair) in words.enumerated() {
                check(candidates(pair.0).first != pair.1, "Novel fixture must not already rank first")
                type(engine, inputs[index])
                let input = engine.aiInputIdentity()!
                engine.clear()
                check(engine.learnAIAdoption(input: input, text: pair.1), "Learn \(inputs[index]) → \(pair.1)")
                check(candidates(pair.0).first == pair.1, "One adoption improves ordinary rank \(pair.1)")
            }
            // Whole original input includes the selected prefix. No suffix-only code is registered.
            let prefix = AIInputIdentity(rawInput: "xingmoliang", caret: 11, selectedPrefix: "星")
            check(engine.learnAIAdoption(input: prefix, text: "星墨量"))
            check(!engine.learnAIAdoption(input: prefix, text: "新墨量"), "Changed prefix must not learn")
            check(!engine.learnAIAdoption(input: .init(rawInput: "nihao", caret: 5, selectedPrefix: ""), text: "你好星墨量"), "Expansion cannot learn")
            check(!engine.learnAIAdoption(input: .init(rawInput: "h", caret: 1, selectedPrefix: ""), text: "行"), "Ambiguous reading skips learning")
            let before = candidates("zhangwei")
            guard let existing = before.dropFirst().first(where: { $0.count == 2 }) else { fatalError("Missing existing-word fixture") }
            check(engine.learnAIAdoption(input: .init(rawInput: "zhangwei", caret: 8, selectedPrefix: ""), text: existing))
            check(candidates("zhangwei").first == existing, "Existing-word adoption improves preference")
            try await Task.sleep(for: .milliseconds(4100))
            let voice = engine.readVoiceLexicon(generation: 1, revision: 3)
            check(voice.entries.contains { $0.text == "星墨海" && $0.code == "xing mo hai " && $0.commits == 1 },
                  "Voice reads the ordinary learned entry and canonical code")
            check(VoiceAlternativeReranker.select([["星莫海", "星墨海"]], snapshot: voice) == "星墨海",
                  "Existing learning changes eligible voice alternatives without an LLM")
            check(VoiceAlternativeReranker.select([["星莫海", "星墨海"]], snapshot: initialVoice) == "星莫海",
                  "Same alternatives preserve Apple order before learning")
            try existing.write(toFile: user + "/expected-existing.txt", atomically: true, encoding: .utf8)
            // Ordinary undo must also survive prior lookup/adoption callbacks.
            ordinaryCommit("zaijian", expected: "再见", undo: true)
            ordinaryCommit("ceshi", expected: "测试", undo: false)
        } else {
            for (input, word) in words { check(candidates(input).first == word, "Restart ordinary recall \(word)") }
            let existing = try String(contentsOfFile: user + "/expected-existing.txt", encoding: .utf8)
            check(candidates("zhangwei").first == existing, "Existing preference persists")
            let files = try FileManager.default.contentsOfDirectory(atPath: user)
            check(files.contains("pinyin_simp.userdb"))
            check(files.contains("inkflow_shared_english.userdb"), "Named shared English user dictionary is independent")
            check(!files.contains(where: { $0.hasSuffix(".userdb") && $0 != "pinyin_simp.userdb" && $0 != "inkflow_shared_english.userdb" }),
                  "AI adoption does not create unrelated user dictionaries")
        }
        engine.clear()
        IFEngine.signalIdle()
        try await Task.sleep(for: .milliseconds(4400))
        check(IFEngine.voiceLexicon.snapshot.availability == .available, "Deferred idle preparation publishes view")
        check(IFEngine.voiceLexicon.snapshot.entries.contains { $0.text == "星墨海" }, "Deferred view includes existing learning")
        let generation = IFEngine.voiceLexicon.snapshot.generation
        IFEngine.stop()
        check(IFEngine.voiceLexicon.snapshot.availability == .unknown && IFEngine.voiceLexicon.snapshot.entries.isEmpty,
              "Teardown clears all learned content")
        check(IFEngine.voiceLexicon.snapshot.generation != generation, "Teardown invalidates snapshot generation")
        print("PASS AI learning \(writing ? "write" : "restart"): novel words, preference, abbreviated/incomplete/typo, prefix, ambiguity")
    }

    @MainActor private static func learningContract(engine: IFEngine, user: String, scenario: String) throws {
        check(IFEngine.version == "1.17.0", "Learning contract is pinned to bundled librime 1.17.0")
        let api = IFEngine.api.pointee
        func request(_ value: String) -> String {
            api.set_property(engine.session, "inkflow_learning_contract_result", "")
            value.withCString { api.set_property(engine.session, "inkflow_learning_contract", $0) }
            var result = [CChar](repeating: 0, count: 4096)
            check(api.get_property(engine.session, "inkflow_learning_contract_result", &result, result.count) != 0,
                  "Learning contract probe must return a result")
            return IFEngine.string(result)
        }
        func query(_ namespace: String, _ code: String) -> String {
            request("query\t\(namespace)\t\(code)")
        }
        func expectAbsent(_ namespace: String, _ code: String, _ reason: String) {
            check(query(namespace, code) == "ok\t0", reason)
        }
        func expectEntry(_ namespace: String, _ code: String, _ text: String, _ reason: String) {
            let result = query(namespace, code)
            check(result.hasPrefix("ok\t1\t\(text)\t\(code)\t"), "\(reason): \(result)")
        }
        func display(_ namespace: String, _ code: String, _ text: String, select: Bool) {
            check(request("candidate\t\(namespace)\t\(code)\t\(text)") == "ok", "Configure test Phrase")
            engine.clear(); type(engine, code)
            let candidates = engine.snapshot().candidates
            guard let index = candidates.firstIndex(of: text) else {
                check(false, "Missing case-preserving contract candidate \(text): \(candidates)")
                return
            }
            if select {
                api.set_property(engine.session, "inkflow_learning_contract_result", "")
                engine.select(index)
                check(engine.takeCommit() == text, "Selected ShadowCandidate keeps display case")
                // Close Rime's ordinary undo window before querying durable state.
                engine.key(0xff09)
                var result = [CChar](repeating: 0, count: 128)
                let available = api.get_property(engine.session, "inkflow_learning_contract_result", &result, result.count) != 0
                check(available && IFEngine.string(result) == "selected", "Memory.memorize must learn selected Phrase")
            } else {
                engine.clear()
            }
        }

        switch scenario {
        case "contract-seed":
            engine.clear(); type(engine, "nihao"); engine.select(0)
            check(!engine.takeCommit().isEmpty, "Seed the original Chinese user dictionary")
            engine.key(0xff09)
        case "contract-write":
            display("shared", "qzxsharedprobe", "CoDeXProbe", select: false)
            expectAbsent("shared", "qzxsharedprobe", "Displaying a Phrase must not learn")
            check(request("reject\tshared\tqzxrejected\tRejectedWord") == "rejected", "Rejected update result")
            expectAbsent("shared", "qzxrejected", "Rejected update must not learn")
            check(request("ambiguous\tvoice\tqzxambiguous\tFirst\tSecond") == "ambiguous", "Ambiguous update result")
            expectAbsent("voice", "qzxambiguous", "Ambiguous update must not learn")

            display("shared", "qzxsharedprobe", "CoDeXProbe", select: true)
            display("voice", "qzxvoiceprobe", "SwiftUIVoice", select: true)

            for (namespace, code, text) in [("shared", "arbitrarysharedcode", "CasePreserved"),
                                             ("voice", "codux", "Codex")] {
                check(request("update\t\(namespace)\t\(code)\t\(text)\t1") == "ok", "Explicit update \(namespace)")
                expectEntry(namespace, code, text, "Explicit update query \(namespace)")
                check(request("update\t\(namespace)\t\(code)\t\(text)\t-1") == "ok", "Explicit undo \(namespace)")
                expectAbsent(namespace, code, "Explicit undo removes \(namespace) entry")
            }
        case "contract-read":
            expectEntry("shared", "qzxsharedprobe", "CoDeXProbe", "Shared entry persists after reopen")
            expectEntry("voice", "qzxvoiceprobe", "SwiftUIVoice", "Voice entry persists after reopen")
            expectAbsent("voice", "qzxsharedprobe", "Shared entry never leaks into voice aliases")
            expectAbsent("shared", "qzxvoiceprobe", "Voice alias never leaks into shared English")
            expectAbsent("shared", "arbitrarysharedcode", "Shared undo persists after reopen")
            expectAbsent("voice", "codux", "Voice undo persists after reopen")
            expectAbsent("shared", "qzxrejected", "Rejected update remains absent after reopen")
            expectAbsent("voice", "qzxambiguous", "Ambiguous update remains absent after reopen")
            let files = try FileManager.default.contentsOfDirectory(atPath: user)
            check(files.contains("pinyin_simp.userdb"), "Original Chinese user dictionary remains")
            check(files.contains("inkflow_shared_english.userdb"), "Shared English namespace is independent")
            check(files.contains("inkflow_voice_alias.userdb"), "Voice alias namespace is independent")
        case "contract-keyboard-negative":
            for code in ["email", "world", "apple", "community", "nihao"] {
                expectAbsent("shared", code, "Display, Return, cancellation, paging, editing, and Chinese selection must not learn \(code)")
            }
        case "contract-keyboard-read":
            let hello = query("shared", "hello")
            check(hello.hasPrefix("ok\t2\t") && hello.contains("\thello\thello\t3") && hello.contains("\tHello\thello\t1"),
                  "Caseful display variants share the normalized lowercase code: \(hello)")
            expectEntry("shared", "computer", "computer", "Completion selection learns its canonical full code")
            for (code, text) in [("swiftui", "SwiftUI"), ("cpp", "C++"), ("typec", "Type-C"),
                                 ("claudecode", "Claude Code"), ("dotnet", ".NET"), ("can", "can")] {
                expectEntry("shared", code, text, "Selected case/symbol/short-conflict candidate persists")
            }
        case "contract-personal-seed":
            check(request("update\tshared\tplugin\tPrivatePlugin\t1") == "ok", "Seed a personal-only exact record")
            expectEntry("shared", "plugin", "PrivatePlugin", "Personal exact seed persists")
        case "contract-mixed-seed":
            for (code, text) in [("codex", "Codex"), ("swiftui", "SwiftUI"), ("cpp", "C++"),
                                 ("offline", "offline"), ("can", "can")] {
                check(request("update\tshared\t\(code)\t\(text)\t1") == "ok", "Seed mixed personal exact record \(text)")
                expectEntry("shared", code, text, "Mixed personal exact seed persists")
            }
            check(request("update\tshared\tcodex\tCODEX\t1") == "ok",
                  "Seed a second display variant for one exact code")
            check(request("batch\tshared\tzzoverflow\tOverflow") == "ok",
                  "Seed an exact record after 512 earlier dictionary keys")
            expectEntry("shared", "zzoverflow", "Overflow", "Exact records after 512 keys remain queryable")
        case "contract-mixed-verify":
            let codex = query("shared", "codex")
            check(codex.hasPrefix("ok\t2\t") && codex.contains("\tCodex\tcodex\t1")
                    && codex.contains("\tCODEX\tcodex\t1"),
                  "All exact display variants remain unchanged: \(codex)")
            for (code, text) in [("swiftui", "SwiftUI"), ("cpp", "C++"),
                                 ("offline", "offline"), ("can", "can")] {
                let result = query("shared", code)
                check(result == "ok\t1\t\(text)\t\(code)\t1",
                      "Mixed display and selection must not update shared learning: \(result)")
            }
            expectEntry("shared", "zzoverflow", "Overflow", "Mixed lookup has no first-512 admission cutoff")
            expectAbsent("shared", "offli", "Mixed personal lookup never creates a completion record")
        default:
            check(false, "Unknown learning contract scenario")
        }
    }

    @MainActor private static func mixedPersonalEnglish(engine: IFEngine, scenario: String) throws {
        check(["mixed-read", "mixed-restart", "mixed-bounded"].contains(scenario), "Unknown mixed personal scenario")

        func allCandidates() -> [String] {
            var result: [String] = []
            for _ in 0..<1000 {
                let page = engine.snapshot()
                result += page.candidates
                engine.key(0xff56)
                if engine.snapshot().page == page.page {
                    for _ in 0..<page.page { engine.key(0xff55) }
                    return result
                }
            }
            check(false, "Mixed personal candidate enumeration must terminate")
            return result
        }

        func candidates(_ input: String) -> [String] {
            engine.clear(); type(engine, input)
            let result = allCandidates()
            engine.clear()
            return result
        }

        if scenario == "mixed-bounded" {
            let boundary = "awoyongofflinehenhao"
            check(boundary.utf8.count == 20 && candidates(boundary).contains { $0.contains("offline") },
                  "Personal lookup remains active at the configured composition bound")
            check(!candidates("a" + boundary).contains { $0.contains("offline") },
                  "Overlong composition fails closed without personal dictionary lookup")
            return
        }

        let exactCases = [
            ("codexhenhao", "Codex很好"),
            ("woyongswiftuihenhao", "我用SwiftUI很好"),
            ("woyongcpp", "我用C++"),
            ("offlinehenhao", "offline很好"),
            ("zzoverflowhenhao", "Overflow很好")
        ]
        for (input, expected) in exactCases {
            let result = candidates(input)
            check(result.contains(expected), "Personal exact mixed candidate \(input) -> \(expected): \(result)")
            check(result.filter { $0 == expected }.count == 1, "Personal/static mixed candidates deduplicate \(expected)")
        }
        let codexVariants = candidates("codexhenhao")
        check(codexVariants.contains("Codex很好") && codexVariants.contains("CODEX很好"),
              "Non-predictive lookup returns every display for one personal exact code")
        check(!candidates("helloofflineworldhenhao").contains("helloofflineworld很好"),
              "Personal exact spans cannot join adjacent public words into one unadmitted ASCII run")

        let noCompletion = candidates("offlihenhao")
        check(!noCompletion.contains("offline很好"), "Personal mixed records do not provide prefix completion")

        engine.clear(); type(engine, "woyongcpx"); engine.key(0xff08); type(engine, "p")
        check(allCandidates().contains("我用C++"), "Backspace editing preserves personal symbol candidate")
        engine.clear(); type(engine, "woyongcpx"); engine.key(0xff51); engine.key(0xff08); type(engine, "p")
        engine.key(0xffff); type(engine, "p")
        check(allCandidates().contains("我用C++"), "Cursor editing preserves personal symbol candidate")
        engine.clear()

        type(engine, "woyongcpp")
        let selectable = allCandidates()
        guard let cpp = selectable.firstIndex(of: "我用C++") else {
            check(false, "Personal mixed candidate remains selectable across pages")
            return
        }
        for _ in 0..<(cpp / 9) { engine.key(0xff56) }
        engine.select(cpp % 9)
        check(engine.takeCommit() == "我用C++" && engine.snapshot().preedit.isEmpty,
              "Selecting displayed personal mixed text commits native candidate exactly")
        engine.key(0xff09)

        engine.setConfiguration(candidateCount: 9,
                                customPhrases: [CustomPhrase(id: UUID(), code: "codexhenhao", text: "自定义词")],
                                inputPreferences: .init())
        type(engine, "codexhenhao")
        check(engine.snapshot().candidates.first == "自定义词", "Custom phrase keeps explicit priority")
        check(allCandidates().contains("Codex很好"), "Custom phrase coexists with personal mixed candidate")
        engine.clear()

        type(engine, "can")
        check(engine.snapshot().candidates.first?.unicodeScalars.allSatisfy { $0.value > 127 } == true,
              "Personal short English does not replace complete Chinese coverage")
        engine.clear(); type(engine, "canpin")
        check(engine.snapshot().candidates.first?.unicodeScalars.allSatisfy { $0.value > 127 } == true,
              "Personal short English does not split a Chinese continuation")
        check(!allCandidates().contains { $0.contains("can") },
              "Legal Pinyin continuation does not expose a personal short-word split")
        engine.clear(); type(engine, "nihao")
        check(engine.snapshot().candidates.first == "你好", "Personal mixed lookup preserves Chinese baseline")
        engine.clear()

        type(engine, "UnknownCamelToken")
        check(engine.key(0xff0d) && engine.takeCommit() == "UnknownCamelToken",
              "Unknown camel-case Return commits raw input without mixed synthesis")
    }

    @MainActor private static func keyboardEnglishLearning(engine: IFEngine, user: String, scenario: String) throws {
        func allCandidates() -> [String] {
            var result: [String] = []
            for _ in 0..<1000 {
                let page = engine.snapshot()
                result += page.candidates
                engine.key(0xff56)
                if engine.snapshot().page == page.page {
                    for _ in 0..<page.page { engine.key(0xff55) }
                    return result
                }
            }
            check(false, "English candidate enumeration must terminate")
            return result
        }
        func select(_ text: String, input: String) {
            engine.clear(); type(engine, input)
            for _ in 0..<1000 {
                let page = engine.snapshot()
                if let index = page.candidates.firstIndex(of: text) {
                    engine.select(index)
                    check(engine.takeCommit() == text, "Selected English candidate keeps exact display \(input) -> \(text)")
                    engine.key(0xff09)
                    return
                }
                engine.key(0xff56)
                if engine.snapshot().page == page.page { break }
            }
            check(false, "Missing English candidate \(input) -> \(text)")
        }

        switch scenario {
        case "english-negative":
            engine.clear(); type(engine, "plugin")
            check(!allCandidates().contains("plugin"), "An excluded public exact word does not bypass the Zipf gate")
            engine.clear()
            type(engine, "email")
            check(allCandidates().contains("email"), "Display-only English fixture")
            engine.clear()
            type(engine, "email")
            guard let email = engine.snapshot().candidates.firstIndex(of: "email") else { check(false, "Undo English fixture"); return }
            engine.select(email); check(engine.takeCommit() == "email"); engine.key(0xff08)
            type(engine, "world")
            check(engine.key(0xff0d) && engine.takeCommit() == "world", "Return commits raw English without selecting a candidate")
            type(engine, "apple"); check(engine.key(0xff1b))
            check(engine.snapshot().preedit.isEmpty && engine.takeCommit().isEmpty, "Cancel English without learning")
            type(engine, "comm"); check(engine.key(0xff56)); engine.clear()
            type(engine, "hellp"); check(engine.key(0xff08)); type(engine, "o"); engine.clear()
            type(engine, "nihao")
            let chinese = engine.snapshot().candidates
            guard let index = chinese.firstIndex(of: "你好") else { check(false, "Chinese baseline fixture"); return }
            engine.select(index); check(engine.takeCommit() == "你好"); engine.key(0xff09)
            engine.setConfiguration(candidateCount: 9,
                                    customPhrases: [CustomPhrase(id: UUID(), code: "email", text: "email")],
                                    inputPreferences: .init())
            type(engine, "email")
            check(engine.snapshot().candidates.first == "email", "Same-text custom phrase shadows standalone English")
            engine.select(0); check(engine.takeCommit() == "email"); engine.key(0xff09)
        case "english-write":
            engine.clear(); type(engine, "emai")
            let email = allCandidates()
            check(email.firstIndex(of: "email")! < email.firstIndex(of: "emails")!, "Exact English remains before completion")
            check(Set(email).count == email.count, "Static English candidates are deduplicated")
            engine.clear()

            select("hello", input: "hello")
            select("hello", input: "hello")
            engine.clear(); type(engine, "hellp"); check(engine.key(0xff08)); type(engine, "o")
            guard let hello = engine.snapshot().candidates.firstIndex(of: "hello") else { check(false, "Edited hello candidate"); return }
            engine.select(hello); check(engine.takeCommit() == "hello"); engine.key(0xff09)
            select("computer", input: "comput")
            for (input, text) in [("Hello", "Hello"), ("swiftui", "SwiftUI"), ("cpp", "C++"),
                                  ("typec", "Type-C"), ("claudecode", "Claude Code"), ("dotnet", ".NET")] {
                select(text, input: input)
            }
            engine.clear(); type(engine, "comm")
            let first = engine.snapshot().candidates
            check(engine.key(0xff56), "Page through English completions before selection")
            let second = engine.snapshot().candidates
            check(!second.isEmpty && second != first, "English paging fixture has a second page")
            let paged = second[0]
            check(engine.key(49) && engine.takeCommit() == paged, "Select an English completion from a later page")
            engine.key(0xff09)
            try (paged + "\n").write(toFile: user + "/expected-paged-english.txt", atomically: true, encoding: .utf8)

            engine.clear(); type(engine, "can")
            let conflict = engine.snapshot().candidates
            check(conflict.first != "can" && conflict.firstIndex(of: "can") != nil, "Chinese remains first for a short conflict")
            engine.select(conflict.firstIndex(of: "can")!); check(engine.takeCommit() == "can"); engine.key(0xff09)
            engine.clear(); type(engine, "nihao")
            check(engine.snapshot().candidates.first == "你好", "English learning does not change the Chinese baseline")
            engine.clear()
        case "english-read":
            engine.clear(); type(engine, "plugin")
            let personal = allCandidates()
            check(personal.contains("PrivatePlugin"), "A personal exact record may bypass the public Zipf gate")
            check(personal.filter { $0 == "PrivatePlugin" }.count == 1, "Personal exact records are deduplicated")
            select("PrivatePlugin", input: "plugin")
            engine.clear(); type(engine, "comput")
            let completion = allCandidates()
            check(completion.firstIndex(of: "computer")! < completion.firstIndex(of: "computers")!, "Restart preserves exact-before-completion")
            check(completion.filter { $0 == "computer" }.count == 1, "Personal/static rows merge without duplicates")
            engine.clear()
            for (input, text) in [("Hello", "Hello"), ("swiftui", "SwiftUI"), ("cpp", "C++"),
                                  ("typec", "Type-C"), ("claudecode", "Claude Code"), ("dotnet", ".NET")] {
                type(engine, input)
                check(allCandidates().contains(text), "Restart keeps selected English fidelity \(input) -> \(text)")
                engine.clear()
            }
            type(engine, "hello")
            check(allCandidates().contains("Hello"), "Lowercase normalized code recalls the selected caseful display after restart")
            engine.clear()
            let paged = try String(contentsOfFile: user + "/expected-paged-english.txt", encoding: .utf8)
                .trimmingCharacters(in: .newlines)
            type(engine, "comm")
            check(allCandidates().contains(paged), "Paged selection remains reachable after restart")
            engine.clear(); type(engine, "nihao")
            check(engine.snapshot().candidates.first == "你好", "Restart keeps ordinary Chinese ranking")
            engine.clear()
        default:
            check(false, "Unknown keyboard English scenario")
        }
    }
}
