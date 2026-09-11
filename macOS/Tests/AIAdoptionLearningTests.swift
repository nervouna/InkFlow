import Foundation
#if SWIFT_PACKAGE
@testable import InkFlowCore
import InkFlowTestSupport
#endif

@main
struct AIAdoptionLearningTests {
    @MainActor static func main() throws {
        let shared = CommandLine.arguments[1], user = CommandLine.arguments[2]
        let writing = CommandLine.arguments[3] == "write"
        let bootstrap = ContinuousClock.now
        try IFEngine.start(shared: shared, user: user)
        print("TRACE AI learning bootstrap: \(bootstrap.duration(to: .now))")
        defer { IFEngine.stop() }
        let engine = IFEngine()!
        engine.setConfiguration(candidateCount: 9, customPhrases: [], inputPreferences: .init())
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
        print("PASS AI learning \(writing ? "write" : "restart"): novel words, preference, abbreviated/incomplete/typo, prefix, ambiguity")
    }
}
