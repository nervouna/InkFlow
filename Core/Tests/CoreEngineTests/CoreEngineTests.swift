import Foundation
@testable import InkFlowDomain
@testable import InkFlowRime
import InkFlowCoreTestSupport
import InkFlowEngineTestSupport

@main struct CoreEngineTests {
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
            try EngineRegression.missingEnglishResources(shared: shared, user: user)
            try EngineRegression.missingEmojiResources(shared: shared, user: user)
        }
        try IFEngine.start(shared: shared, user: user)
        if selected("options") { try EngineRegression.inputSettings(user: user) }
        let schemaURL = URL(fileURLWithPath: user).appendingPathComponent("build/inkflow_pinyin.schema.yaml")
        let schemaBefore = try Data(contentsOf: schemaURL)
        if selected("basic") { EngineRegression.chineseDictionaryCoverage(); try EngineRegression.runCases(); EngineRegression.propertyChannel() }
        if selected("english") {
            try EngineRegression.domainVocabulary()
            EngineRegression.englishAdmission()
            EngineRegression.conservativeChinesePrefixes()
            EngineRegression.mixedEnglishCandidates()
            EngineRegression.shortConflictBounds()
            EngineRegression.englishCandidates()
            EngineRegression.englishFeatureCoexistence()
            EngineRegression.spellingCorrection()
        }
        if selected("context") { EngineRegression.contextReranking(); EngineRegression.contextCustomPhrasePriority(); try EngineRegression.rankingRules() }
        if selected("custom-phrases") {
            try EngineRegression.customPhrases(user: user)
            let phrases = [try CustomPhrase.validated(code: "dz", text: "重启后的地址")]
            let encoded = try JSONEncoder().encode(phrases)
            IFEngine.stop()
            try IFEngine.start(shared: shared, user: user)
            do {
                let restored = try JSONDecoder().decode([CustomPhrase].self, from: encoded)
                let engine = IFEngine()!
                engine.setConfiguration(candidateCount: 5, customPhrases: restored)
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

}
