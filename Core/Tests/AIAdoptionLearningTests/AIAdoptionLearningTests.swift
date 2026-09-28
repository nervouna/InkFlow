import InkFlowRime
import InkFlowDomain
import Foundation
#if SWIFT_PACKAGE
@testable import InkFlowDomain
@testable import InkFlowRime
import InkFlowCoreTestSupport
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
        if scenario == "personal-management-read" {
            let rows = try IFEngine.personalLearningEntries()
            check(rows.filter { $0.text == "Codex" }.allSatisfy { $0.commits == 4 }, "Restored learning survives restart")
            check(rows.count == 4, "Case variants and both namespaces survive restart")
            return
        }
        if scenario == "personal-management" {
            try await personalManagement(engine: engine)
            print("PASS personal management: source identity, delete/undo, stale conflicts, cached sessions, native undo guard")
            return
        }
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
        if scenario == "mixed-letter-write" || scenario == "mixed-letter-read" {
            try mixedLetterIsolation(engine: engine, shared: shared, user: user, learn: scenario == "mixed-letter-write")
            print("PASS mixed letter isolation \(scenario)")
            return
        }
        if scenario.hasPrefix("mixed-") {
            try mixedPersonalEnglish(engine: engine, scenario: scenario)
            print("PASS mixed personal English \(scenario)")
            return
        }
        if scenario.hasPrefix("voice-correction-") {
            try voiceCorrectionLearning(engine: engine, user: user, scenario: scenario)
            print("PASS voice correction learning \(scenario)")
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
            check(!engine.prepareConsumedAIAdoption(input: engine.aiInputIdentity()!, text: "行"),
                  "Consumed ambiguous adoption still clears composition when learning is unavailable")
            check(engine.snapshot().preedit.isEmpty && engine.takeCommit().isEmpty,
                  "Preparing AI delivery never commits a default candidate")
            let dictionary = try String(contentsOfFile: shared + "/pinyin_simp.dict.yaml", encoding: .utf8)
            for (_, word) in words { check(!dictionary.contains("\n" + word + "\t"), "Fixture must be novel") }
            let inputs = ["xingmoliang", "xml", "xingmoha", "xingmohoa"]
            for (index, pair) in words.enumerated() {
                check(candidates(pair.0).first != pair.1, "Novel fixture must not already rank first")
                type(engine, inputs[index])
                let input = engine.aiInputIdentity()!
                if index == 1 {
                    engine.setConfiguration(candidateCount: 9, customPhrases: [], inputPreferences: .init([.abbreviation: false]))
                    check(engine.inputPreferences?[.abbreviation] == true, "Active composition retains its own preference snapshot")
                }
                check(engine.prepareConsumedAIAdoption(input: input, text: pair.1), "Learn \(inputs[index]) → \(pair.1)")
                check(engine.snapshot().preedit.isEmpty && engine.takeCommit().isEmpty,
                      "Consumed adoption clears without an ordinary commit before platform insertion")
                engine.setConfiguration(candidateCount: 9, customPhrases: [], inputPreferences: .init())
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

    @MainActor private static func personalManagement(engine: IFEngine) async throws {
        func verify(_ value: Bool, _ message: String) { check(value, message) }
        func entry(_ source: IFEngine.PersonalLearningEntry.Source) throws -> IFEngine.PersonalLearningEntry {
            guard let result = try IFEngine.personalLearningEntries().first(where: { $0.source == source && $0.text == "Codex" }) else {
                fatalError("Missing fixture entry")
            }
            return result
        }
        func expectError(_ error: IFEngine.PersonalLearningError, _ operation: () throws -> Void) {
            do { try operation(); check(false, "Expected management failure") }
            catch let actual as IFEngine.PersonalLearningError { check(actual == error, "Management error identity") }
            catch { check(false, "Unexpected error") }
        }
        verify(try IFEngine.personalLearningEntries().isEmpty, "Empty available management snapshot")
        check(engine.learnVoiceCorrection(.init(sourceCode: "codux", canonicalText: "Codex")), "Seed learning")
        check(engine.learnVoiceCorrection(.init(sourceCode: "codux", canonicalText: "CODEX")), "Distinct case identity")
        let stale = try entry(.english)
        check(engine.learnVoiceCorrection(.init(sourceCode: "codux", canonicalText: "Codex")), "Repeat learning")
        expectError(.conflict) { _ = try IFEngine.deletePersonalLearning(stale) }
        let second = IFEngine()!
        type(second, "codex"); _ = second.snapshot(); second.clear()
        let alias = try entry(.voice)
        let generation = IFEngine.voiceLexicon.snapshot.generation
        let undo = try IFEngine.deletePersonalLearning(alias)
        verify(try IFEngine.personalLearningEntries().filter { $0.source == .voice && $0.text == "Codex" }.isEmpty, "Delete only exact alias")
        verify(try IFEngine.personalLearningEntries().filter { $0.text == "CODEX" }.count == 2, "Other display identity unchanged")
        check(IFEngine.voiceLexicon.snapshot.generation != generation, "Management invalidates captured voice generation")
        verify(try entry(.english).commits == 2, "Canonical record survives alias deletion")
        try IFEngine.undoPersonalLearning(undo)
        verify(try entry(.voice).commits == 3, "Native undo restores entry with one additional confirmation")
        expectError(.conflict) { try IFEngine.undoPersonalLearning(undo) }
        let canonicalUndo = try IFEngine.deletePersonalLearning(entry(.english))
        type(second, "codex")
        check(!second.qualitySnapshot().candidates.contains { $0.text == "Codex" && $0.source == "personal_exact_english" },
              "Other session's warmed same-input cache invalidates")
        expectError(.busy) { try IFEngine.undoPersonalLearning(canonicalUndo) }
        second.clear()
        try IFEngine.undoPersonalLearning(canonicalUndo)
        verify(try entry(.english).commits == 3, "Canonical restoration adds one native confirmation")
        let obsoleteUndo = try IFEngine.deletePersonalLearning(entry(.voice))
        check(engine.learnVoiceCorrection(.init(sourceCode: "codux", canonicalText: "Codex")), "Relearn after deletion")
        expectError(.conflict) { try IFEngine.undoPersonalLearning(obsoleteUndo) }
        type(engine, "ni")
        expectError(.busy) { _ = try IFEngine.personalLearningEntries() }
        engine.clear()
        type(engine, "ceshi"); engine.select(0); _ = engine.takeCommit()
        expectError(.busy) { _ = try IFEngine.personalLearningEntries() }
        // A rejected management read must not finish Rime's immediate-undo transaction.
        engine.key(0xff08)
        try await Task.sleep(for: .milliseconds(4100))
        _ = try IFEngine.personalLearningEntries()
    }

    @MainActor private static func voiceCorrectionLearning(engine: IFEngine, user: String,
                                                            scenario: String) throws {
        check(["voice-correction-write", "voice-correction-read", "voice-correction-clear", "voice-correction-cleared-read"].contains(scenario),
              "Unknown voice correction scenario")
        func candidates(_ input: String) -> [String] {
            engine.clear(); type(engine, input)
            var result: [String] = []
            for _ in 0..<100 {
                let page = engine.snapshot()
                result += page.candidates
                engine.key(0xff56)
                if engine.snapshot().page == page.page { break }
            }
            engine.clear()
            return result
        }

        check(candidates("nihao").first == "你好", "Voice learning preserves the Chinese baseline")
        if scenario == "voice-correction-write" || scenario == "voice-correction-clear" {
            check(engine.learnVoiceCorrection(.init(sourceCode: "codux", canonicalText: "Codex")),
                  "One attributable correction updates both Rime namespaces")
            if scenario == "voice-correction-clear" {
                check(engine.learnVoiceCorrection(.init(sourceCode: "codux", canonicalText: "Codex")),
                      "Reset fixture retains arbitrary prior commit counts")
                engine.clear(); type(engine, "ni")
                check(!IFEngine.clearPersonalEnglishLearning(), "Active composition blocks the destructive lifecycle action")
                engine.clear()
                check(engine.readVoiceAliases().entries.contains { $0.code == "codux" && $0.commits == 2 },
                      "Blocked reset changes neither English namespace")
            }
            check(!engine.learnVoiceCorrection(.init(sourceCode: "co dux", canonicalText: "Codex")),
                  "Malformed source aliases fail closed")
        }
        let aliases = engine.readVoiceAliases(generation: 7, revision: 9)
        check(aliases.availability == .available && aliases.generation == 7 && aliases.revision == 9,
              "Voice aliases are a bounded available snapshot")
        if scenario == "voice-correction-clear" {
            engine.clear(); type(engine, "ceshi"); engine.select(0)
            check(engine.takeCommit() == "测试", "Seed unrelated ordinary Chinese learning")
            engine.key(0xff09)
            check(IFEngine.clearPersonalEnglishLearning(), "Explicit lifecycle action clears both English namespaces")
            check(engine.readVoiceAliases().entries.isEmpty, "Voice alias namespace is empty immediately after clear")
            check(candidates("world").contains("world"), "Reset never deletes the public English dictionary")
            return
        }
        if scenario == "voice-correction-cleared-read" {
            check(aliases.entries.isEmpty, "Cleared voice aliases stay empty after restart")
            check(candidates("ceshi").first == "测试", "Clearing English learning preserves Chinese userdb")
            return
        }
        check(aliases.entries.contains { $0.code == "codux" && $0.text == "Codex" && $0.commits == 1 },
              "The exact voice-only alias is readable with its native count")
        check(VoiceAliasRewriter.apply("用 codux，配合。", snapshot: aliases) == "用 Codex，配合。",
              "Restarted voice aliases apply at exact token boundaries")
        check(VoiceAliasRewriter.apply("mycodux coduxx", snapshot: aliases) == "mycodux coduxx",
              "Voice aliases never expand a partial Latin token")
        check(candidates("codex").contains("Codex"),
              "The canonical display is persisted to shared keyboard English")
        engine.clear(); type(engine, "codex")
        let personal = engine.qualitySnapshot().candidates.first { $0.text == "Codex" }
        check(personal?.source == "personal_exact_english" && personal?.consumedInputStart == 0 && personal?.consumedInputEnd == 5,
              "Canonical personal exact evidence reaches quality capture without dictionary text metadata")
        engine.clear()
        check(!candidates("codux").contains("Codex"),
              "A voice-only alias never leaks into keyboard completion")
        let files = try FileManager.default.contentsOfDirectory(atPath: user)
        check(files.contains("inkflow_shared_english.userdb") && files.contains("inkflow_voice_alias.userdb"),
              "Voice correction uses the two named Rime user dictionaries")
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
        if scenario == "contract-management-limit" {
            check(request("batch\tshared\tzzoverflow\tOverflow\t4096") == "ok", "Seed management bound")
            do {
                _ = try IFEngine.personalLearningEntries()
                check(false, "Over-limit list must not masquerade as empty or partial")
            } catch let error as IFEngine.PersonalLearningError {
                check(error == .unavailable, "Oversized native list has explicit failure")
            }
            expectEntry("shared", "zzoverflow", "Overflow", "Failed management listing preserves stored entry")
            return
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
        case "contract-ranking-seed":
            check(request("update\tshared\tcodex\tCodex\t1") == "ok", "Seed one unambiguous ranking record")
            expectEntry("shared", "codex", "Codex", "Ranking seed persists")
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
        case "contract-mixed-immediate":
            // Exercise the production mixed translator after a real shared-memory
            // update in this engine, without recompilation or process restart.
            for (code, text) in [("codex", "Codex"), ("cpp", "C++"), ("offline", "offline")] {
                check(request("update\tshared\t\(code)\t\(text)\t1") == "ok", "Confirm an exact personal record")
                for (input, expected) in [(code + "henhao", text + "很好"),
                                          ("woyong" + code, "我用" + text),
                                          ("woyong" + code + "kaifa", "我用" + text + "开发")] {
                    checkMixedRecall(engine, input: input, expected: expected)
                }
            }
        case "contract-mixed-letters-verify":
            for (code, text) in [("a", "A"), ("i", "I")] {
                check(query("shared", code) == "ok\t1\t\(text)\t\(code)\t1",
                      "Display, mixed lookup and cancelled compositions do not relearn \(text)")
                expectAbsent("voice", code, "Keyboard letters do not become voice aliases")
            }
            expectAbsent("shared", "email", "Immediate standalone English undo remains intact")
            for code in ["shiyitai", "huichuxian", "duihua", "woyongcodexkaifa"] {
                expectAbsent("shared", code, "Mixed queries never become whole-sentence English records")
            }
        case "contract-mixed-pinyin-conflicts":
            for (code, text) in [("api", "PrivateAPI"), ("qian", "PrivateQian"), ("shijian", "PrivateShijian")] {
                check(request("update\tshared\t\(code)\t\(text)\t1") == "ok", "Seed a normally spelled Pinyin sequence alias")
                for context in ["", "API 已经"] {
                    engine.clear(); engine.setPrecedingText(context); type(engine, "woyong" + code)
                    var exhausted = false
                    for _ in 0..<1000 {
                        let page = engine.snapshot()
                        check(!page.candidates.contains { $0.contains(text) },
                              "Unmarked normally spelled Pinyin sequence does not acquire personal English intent: \(code), \(page.candidates)")
                        engine.key(0xff56)
                        if engine.snapshot().page == page.page { exhausted = true; break }
                    }
                    check(exhausted, "Enumerate all normally spelled conflict pages")
                }
                checkMixedRecall(engine, input: "woyong" + code.uppercased(), expected: "我用" + text)
            }
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
        check(["mixed-read", "mixed-restart", "mixed-bounded", "mixed-ranking-read"].contains(scenario), "Unknown mixed personal scenario")

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

        if scenario == "mixed-ranking-read" {
            type(engine, "women")
            check(engine.snapshot().candidates.first == "我们", "Neutral evidence keeps Chinese first")
            engine.clear()
            engine.setPrecedingText("正在使用 Swift ")
            type(engine, "codex")
            check(engine.snapshot().candidates.first == "Codex",
                  "Personal exact English may lead in bounded technical context: \(engine.snapshot().candidates)")
            check(engine.snapshot().candidates.firstIndex(of: "Codex")! < engine.snapshot().candidates.firstIndex(of: "Codex CLI")!,
                  "Exact personal English remains ahead of public completion")
            check(engine.key(32) && engine.takeCommit() == "Codex",
                  "Space selects the displayed evidence-ranked candidate through native mapping")
            engine.setPrecedingText("正在使用 Swift ")
            type(engine, "codey"); engine.key(0xff08); type(engine, "x")
            check(engine.snapshot().candidates.first == "Codex", "Editing recomputes bounded evidence ranking")
            engine.clear(); type(engine, "codex")
            check(engine.snapshot().candidates.first != "Codex", "Clearing invalidates stale technical context")
            let isolated = IFEngine()!
            type(isolated, "codex")
            check(isolated.snapshot().candidates.first != "Codex", "Technical context remains session-local")
            return
        }

        let exactCases = [
            ("codexhenhao", "Codex很好"),
            ("sangcodexhenhao", "桑Codex很好"),
            ("woyongcodexkaifa", "我用Codex开发"),
            ("woyongcodex", "我用Codex"),
            ("Codexhenhao", "Codex很好"),
            ("woyongCODEXkaifa", "我用CODEX开发"),
            ("woyongswiftuihenhao", "我用SwiftUI很好"),
            ("cpphenhao", "C++很好"),
            ("woyongcppkaifa", "我用C++开发"),
            ("woyongcpp", "我用C++"),
            ("offlinehenhao", "offline很好"),
            ("woyongofflinehenhao", "我用offline很好"),
            ("woyongoffline", "我用offline"),
            ("zzoverflowhenhao", "Overflow很好")
        ]
        for (input, expected) in exactCases {
            let result = candidates(input)
            check(result.contains(expected), "Personal exact mixed candidate \(input) -> \(expected): \(result)")
            check(result.filter { $0 == expected }.count == 1, "Personal/static mixed candidates deduplicate \(input) -> \(expected)")
            checkMixedRecall(engine, input: input, expected: expected)
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
        checkOriginalInput(engine, expected: "woyongcpp", caret: 9)
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

        // Select a real Chinese prefix, then continue the same composition.
        engine.clear(); type(engine, "woyongcpp")
        // Ordinary Left uses Rime Rewind and may jump syllables. The keypad
        // binding explicitly moves by source character to select the wo prefix.
        for _ in 0..<7 { engine.key(0xff96) }
        check(engine.qualitySnapshot().caret == 2, "Caret refers to raw ASCII input positions")
        guard let prefix = engine.snapshot().candidates.firstIndex(of: "我") else {
            check(false, "A native prefix remains selectable before personal mixed input")
            return
        }
        engine.select(prefix)
        check(engine.takeCommit().isEmpty && engine.qualitySnapshot().selectedPrefix == "我",
              "Partial selection preserves the native selected-prefix transaction")
        engine.key(0xff57)
        check(engine.qualitySnapshot().rawInput == "woyongcpp", "Partial selection retains the complete raw input")
        check(allCandidates().contains("用C++"), "A personal mixed suffix remains reachable after selecting Chinese")
        engine.clear()

        engine.setConfiguration(candidateCount: 9,
                                customPhrases: [CustomPhrase(id: UUID(), code: "codexhenhao", text: "自定义词"),
                                                CustomPhrase(id: UUID(), code: "codexhenhao", text: "Codex很好")],
                                inputPreferences: .init())
        type(engine, "codexhenhao")
        check(engine.snapshot().candidates.first == "自定义词", "Custom phrase keeps explicit priority")
        check(allCandidates().filter { $0 == "Codex很好" }.count == 1,
              "Custom phrase and personal mixed candidate deduplicate while preserving custom priority")
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

    @MainActor private static func checkOriginalInput(_ engine: IFEngine, expected: String, caret: Int? = nil) {
        let state = engine.qualitySnapshot()
        check(state.rawInput == expected, "Highlight/edit must retain raw input \(expected): \(state.rawInput)")
        check((0...expected.utf8.count).contains(state.caret), "Caret remains within original input")
        if let caret { check(state.caret == caret, "Caret is an input offset, not a display-text offset") }
        // Native Pinyin may insert syllable spaces or retain apostrophe delimiters.
        // Neither permits replacing source letters with a fabricated carrier.
        let letters: (String) -> String = { $0.filter { $0 != " " && $0 != "'" } }
        if state.selectedPrefix.isEmpty {
            check(letters(engine.snapshot().preedit) == letters(expected),
                  "Highlighted preedit derives from original input \(expected): \(engine.snapshot().preedit)")
        }
    }

    @MainActor private static func checkMixedRecall(_ engine: IFEngine, input: String, expected: String) {
        engine.clear(); type(engine, input)
        for _ in 0..<1000 {
            let page = engine.snapshot()
            if let index = page.candidates.firstIndex(of: expected) {
                engine.highlight(index)
                checkOriginalInput(engine, expected: input, caret: input.utf8.count)
                let pronunciation = engine.aiPronunciation(input: engine.aiInputIdentity()!, text: expected)
                check(pronunciation.resolve(input: input, text: expected) == nil, "A mixed phrase cannot become a Chinese pronunciation through Lua")
                let row = engine.qualitySnapshot().candidates[index]
                check(row.source == "personal_exact_mixed", "Native deduplication preserves exact personal token provenance")
                check(row.consumedInputStart == 0 && row.consumedInputEnd == input.utf8.count,
                      "Mixed candidate covers its actual complete input span")
                if input == "woyongcpp" {
                    engine.key(0xff51, modifiers: 4) // Native Control-Left syllable navigation.
                    check(engine.qualitySnapshot().caret == 6,
                          "Native navigation crosses the actual cpp input span, independent of C++ output")
                    check(engine.qualitySnapshot().rawInput == input, "Syllable navigation preserves original input")
                    engine.key(0xff57)
                    check(engine.qualitySnapshot().caret == input.utf8.count, "End restores the real input caret")
                }
                engine.clear()
                return
            }
            engine.key(0xff56)
            if engine.snapshot().page == page.page { break }
        }
        check(false, "Missing exact personal mixed candidate \(input) -> \(expected)")
    }

    @MainActor private static func mixedLetterIsolation(engine: IFEngine, shared: String, user: String, learn: Bool) throws {
        // These native dictionary records cover i/a within normally spelled
        // syllables and alternate syllable boundaries, beyond the reported words.
        let dictionary = try String(contentsOfFile: shared + "/pinyin_simp.dict.yaml", encoding: .utf8)
        let families = [("时间", "shi jian"), ("知道", "zhi dao"), ("天气", "tian qi"),
                        ("上海", "shang hai"), ("西安", "xi an")]
        for (text, code) in families {
            check(dictionary.contains("\n\(text)\t\(code)\t"), "Conflict family is backed by the actual Chinese dictionary")
        }
        let inputs = ["shiyitai", "huichuxian", "duihua", "chajian", "xiang", "qian", "liang", "xi'an"]
            + families.map { $0.1.replacingOccurrences(of: " ", with: "") }
        let baselineFile = user + "/letter-chinese-baseline.json"
        var baseline: [String: String]
        if learn {
            baseline = [:]
            for input in inputs {
                engine.clear(); type(engine, input)
                baseline[input] = engine.snapshot().candidates.first
                checkOriginalInput(engine, expected: input)
            }
            try JSONEncoder().encode(baseline).write(to: URL(fileURLWithPath: baselineFile))
            for (input, expected, undo) in [("A", "A", false), ("i", "I", false), ("email", "email", true)] {
                engine.clear(); type(engine, input)
                guard let index = engine.snapshot().candidates.firstIndex(of: expected) else {
                    check(false, "Real standalone selection fixture missing \(input) -> \(expected)")
                    return
                }
                engine.select(index)
                check(engine.takeCommit() == expected, "Learn through actual standalone candidate selection")
                engine.key(undo ? 0xff08 : 0xff09)
            }
        } else {
            baseline = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: baselineFile)))
        }
        var violations: [String] = []
        for context in ["", "API 已经"] {
            for input in inputs {
                engine.clear(); engine.setPrecedingText(context); type(engine, input)
                if context.isEmpty && engine.snapshot().candidates.first != baseline[input] {
                    violations.append("\(input): Chinese baseline changed after learning standalone letters")
                }
                var exhausted = false
                for _ in 0..<1000 {
                    let page = engine.snapshot()
                    for (index, candidate) in page.candidates.enumerated() {
                        engine.highlight(index)
                        let state = engine.qualitySnapshot()
                        let preedit = engine.snapshot().preedit
                        let compact = preedit.filter { $0 != " " && $0 != "'" }
                        let actual = input.filter { $0 != " " && $0 != "'" }
                        let embeddedLetter = candidate.unicodeScalars.contains { $0.value > 127 }
                            && candidate.contains { $0 == "A" || $0 == "I" }
                        if embeddedLetter || compact != actual || state.rawInput != input {
                            violations.append("input=\(input) context=\(context.isEmpty ? "neutral" : "technical") page=\(page.page) candidate=\(candidate) preedit=\(preedit) raw=\(state.rawInput)")
                        }
                        check((0...input.utf8.count).contains(state.caret), "Highlighted caret stays within real input")
                    }
                    engine.key(0xff56)
                    if engine.snapshot().page == page.page { exhausted = true; break }
                }
                check(exhausted, "All negative candidate pages must be enumerated")
            }
        }
        engine.clear()
        check(violations.isEmpty, "Learned letters must not contaminate ordinary Pinyin or highlighted preedit:\n" + violations.joined(separator: "\n"))
        for letter in ["A", "I"] {
            checkMixedRecall(engine, input: "woyong" + letter, expected: "我用" + letter)
        }
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
