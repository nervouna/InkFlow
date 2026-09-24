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
            check(!files.contains(where: { $0.hasSuffix(".userdb") && $0 != "pinyin_simp.userdb" }), "Only existing userdb")
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
        default:
            check(false, "Unknown learning contract scenario")
        }
    }
}
