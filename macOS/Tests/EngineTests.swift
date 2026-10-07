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
            try EngineRegression.missingEnglishResources(shared: shared, user: user)
            try EngineRegression.missingEmojiResources(shared: shared, user: user)
        }
        try IFEngine.start(shared: shared, user: user)
        if selected("options") {
            let isolated = IsolatedSettings()
            defer { isolated.cleanup() }
            let settings = isolated.settings
            try EngineRegression.inputSettings(user: user, event: nativeEvent) { preferences in
                settings.setInputOption(.abbreviation, enabled: preferences[.abbreviation])
                settings.setInputOption(.typoTolerance, enabled: preferences[.typoTolerance])
                settings.fuzzyEnabled = preferences[.fuzzyZ]
                settings.pagingKeys = preferences[.bracketPaging] ? .brackets : .minusEqual
                check(settings.inputPreferences == preferences.setting(.minusEqualPaging, to: !preferences[.bracketPaging]),
                      "Grouped settings produce the complete preference snapshot with exclusive paging")
                return settings.inputPreferences
            }
        }
        let schemaURL = URL(fileURLWithPath: user).appendingPathComponent("build/inkflow_pinyin.schema.yaml")
        let schemaBefore = try Data(contentsOf: schemaURL)
        if selected("basic") {
            EngineRegression.chineseDictionaryCoverage()
            try EngineRegression.runCases(event: nativeEvent)
        }
        if selected("english") {
            try EngineRegression.domainVocabulary()
            EngineRegression.englishAdmission()
            EngineRegression.conservativeChinesePrefixes()
            EngineRegression.mixedEnglishCandidates(event: nativeEvent)
            EngineRegression.shortConflictBounds()
            EngineRegression.englishCandidates()
            EngineRegression.englishFeatureCoexistence()
            EngineRegression.spellingCorrection(event: nativeEvent)
        }
        if selected("context") {
            EngineRegression.contextReranking()
            EngineRegression.contextCustomPhrasePriority()
            try EngineRegression.rankingRules()
        }
        if selected("custom-phrases") {
            do {
                let isolated = IsolatedSettings()
                defer { isolated.cleanup() }
                try EngineRegression.customPhrases(user: user, storedPhrases: { isolated.settings.customPhrases }) { phrase in
                    let settings = isolated.settings
                    let id = settings.customPhrases.contains { $0.id == phrase.id } ? phrase.id : nil
                    let saved = try settings.saveCustomPhrase(id: id, code: phrase.code, text: phrase.text)
                    check(settings.customPhrases.contains(saved), "Saved phrase remains in settings")
                    return saved
                }
            }
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

    @MainActor static func nativeEvent(_ engine: IFEngine, _ key: Int32, _ code: UInt16,
                                      _ text: String, _ modifiers: Int32) -> Bool {
        var flags: NSEvent.ModifierFlags = []
        for (mask, flag): (Int32, NSEvent.ModifierFlags) in [(1, .shift), (2, .command), (4, .control), (8, .option)] {
            if modifiers & mask != 0 { flags.insert(flag) }
        }
        return engine.event(keyEvent(code, text, flags))
    }
}
