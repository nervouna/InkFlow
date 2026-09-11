import Foundation
#if SWIFT_PACKAGE
@testable import InkFlowCore
#endif

@main
struct QualityIdentityTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
    }

    static func main() throws {
        let baseMetadata = QualityBuildMetadata(sourceRevision: "commit-a", sourceTreeSHA256: String(repeating: "a", count: 64),
            sourceDirty: false, bundledResourcesSHA256: String(repeating: "b", count: 64),
            bundleSHA256: String(repeating: "c", count: 64),
            rankingSourceSHA256: String(repeating: "d", count: 64),
            rankingResourcesSHA256: String(repeating: "e", count: 64),
            appVersion: "1.0", appBuild: "1")
        let baseConfiguration = QualityAppliedConfiguration(candidateCount: 5,
            customPhrases: [QualityPhrase(id: "phrase", code: "dm", text: "大猫")],
            schemaID: "inkflow_pinyin", asciiMode: false, fontSize: 14, vertical: false,
            inputOptions: ["emoji": true, "fuzzyZ": false])
        let base = try QualityFingerprints.make(configuration: baseConfiguration, build: baseMetadata,
            engineVersion: "1.17.0", databaseSchemaVersion: 2, metricRuleVersion: 1, collectionRuleVersion: 1)

        var aiOnly = baseMetadata
        aiOnly.sourceTreeSHA256 = String(repeating: "1", count: 64)
        aiOnly.bundleSHA256 = String(repeating: "2", count: 64)
        let ai = try QualityFingerprints.make(configuration: baseConfiguration, build: aiOnly,
            engineVersion: "1.17.0", databaseSchemaVersion: 2, metricRuleVersion: 1, collectionRuleVersion: 1)
        expect(ai.buildIdentity != base.buildIdentity, "AI-only build changes full build identity")
        expect(ai.ranking == base.ranking, "AI-only build does not change ranking identity")

        var source = baseMetadata
        source.rankingSourceSHA256 = String(repeating: "3", count: 64)
        let sourceChanged = try QualityFingerprints.make(configuration: baseConfiguration, build: source,
            engineVersion: "1.17.0", databaseSchemaVersion: 2, metricRuleVersion: 1,
            collectionRuleVersion: 1)
        expect(sourceChanged.ranking != base.ranking, "ranking source changes ranking identity")
        var resources = baseMetadata
        resources.rankingResourcesSHA256 = String(repeating: "4", count: 64)
        let resourcesChanged = try QualityFingerprints.make(configuration: baseConfiguration, build: resources,
            engineVersion: "1.17.0", databaseSchemaVersion: 2, metricRuleVersion: 1,
            collectionRuleVersion: 1)
        expect(resourcesChanged.ranking != base.ranking, "ranking resource changes ranking identity")

        var presentation = baseConfiguration
        presentation.fontSize = 20
        presentation.vertical = true
        let shown = try QualityFingerprints.make(configuration: presentation, build: baseMetadata,
            engineVersion: "1.17.0", databaseSchemaVersion: 2, metricRuleVersion: 1, collectionRuleVersion: 1)
        expect(shown.settings != base.settings, "presentation changes complete settings identity")
        expect(shown.ranking == base.ranking, "presentation does not change ranking identity")

        for changed in [
            QualityAppliedConfiguration(candidateCount: 9, customPhrases: baseConfiguration.customPhrases,
                schemaID: baseConfiguration.schemaID, asciiMode: baseConfiguration.asciiMode,
                fontSize: baseConfiguration.fontSize, vertical: baseConfiguration.vertical,
                inputOptions: baseConfiguration.inputOptions),
            QualityAppliedConfiguration(candidateCount: 5,
                customPhrases: [QualityPhrase(id: "new", code: "xm", text: "熊猫")],
                schemaID: baseConfiguration.schemaID, asciiMode: baseConfiguration.asciiMode,
                fontSize: baseConfiguration.fontSize, vertical: baseConfiguration.vertical,
                inputOptions: baseConfiguration.inputOptions),
            QualityAppliedConfiguration(candidateCount: 5, customPhrases: baseConfiguration.customPhrases,
                schemaID: baseConfiguration.schemaID, asciiMode: baseConfiguration.asciiMode,
                fontSize: baseConfiguration.fontSize, vertical: baseConfiguration.vertical,
                inputOptions: ["emoji": false, "fuzzyZ": false])
        ] {
            let rankingChanged = try QualityFingerprints.make(configuration: changed, build: baseMetadata,
                engineVersion: "1.17.0", databaseSchemaVersion: 2, metricRuleVersion: 1,
                collectionRuleVersion: 1)
            expect(rankingChanged.ranking != base.ranking, "ranking setting changes ranking identity")
        }

        let metric = try QualityFingerprints.make(configuration: baseConfiguration, build: baseMetadata,
            engineVersion: "1.17.0", databaseSchemaVersion: 2, metricRuleVersion: 2, collectionRuleVersion: 1)
        expect(metric.measurement != base.measurement, "metric rule changes measurement identity")
        expect(metric.ranking == base.ranking, "metric rule does not change ranking identity")

        var incomplete = baseMetadata
        incomplete.rankingResourcesSHA256 = "unknown"
        do {
            _ = try QualityFingerprints.make(configuration: baseConfiguration, build: incomplete,
                engineVersion: "1.17.0", databaseSchemaVersion: 2, metricRuleVersion: 1, collectionRuleVersion: 1)
            fatalError("FAIL: incomplete layered identity was accepted")
        } catch is QualityIdentityError {}
        print("PASS quality identities: independent ranking, settings, measurement, and build boundaries")
    }
}
