// swift-tools-version: 6.2
import Foundation
import PackageDescription

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let dependencyRoot = repository.appendingPathComponent("build/deps/dist").path
let rimeLinkerSettings: [LinkerSetting] = [.unsafeFlags(["-L\(dependencyRoot)/lib"]), .linkedLibrary("rime")]
let buildRimeRuntime: [LinkerSetting] = [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "\(dependencyRoot)/lib"])]
let strictSwiftSettings: [SwiftSetting] = [.unsafeFlags(["-warnings-as-errors"])]
let strictCSettings: [CSetting] = [.unsafeFlags(["-Wall", "-Wextra", "-Werror"])]
let package = Package(
    name: "InkFlowShared",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .executable(name: "dictionary-preparation-fixture", targets: ["DictionaryPreparationFixture"]),
        .executable(name: "core-dictionary-tests", targets: ["CoreDictionaryTests"]),
        .executable(name: "voice-learning-coordinator-tests", targets: ["VoiceLearningCoordinatorTests"]),
        .executable(name: "dictionary-store-tests", targets: ["DictionaryStoreTests"]),
        .executable(name: "voice-lexicon-tests", targets: ["VoiceLexiconTests"]),
        .executable(name: "core-engine-tests", targets: ["CoreEngineTests"]),
        .library(name: "InkFlowDomain", targets: ["InkFlowDomain"]),
        .library(name: "InkFlowRime", targets: ["InkFlowRime"]),
        .executable(name: "dictionary-generator", targets: ["DictionaryGeneratorTool"]),
        .executable(name: "packaged-cache-tool", targets: ["PackagedCacheTool"]),
        .executable(name: "dictionary-generator-tests", targets: ["DictionaryGeneratorTests"]),
        .executable(name: "ai-pronunciation-tests", targets: ["AIPronunciationTests"]),
        .executable(name: "ai-adoption-learning-tests", targets: ["AIAdoptionLearningTests"]),
        .executable(name: "ranking-tests", targets: ["RankingTests"])
    ],
    targets: [
        .executableTarget(name: "DictionaryPreparationFixture", dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowRimeWorker"], path: "Tests/DictionaryPreparationFixture", swiftSettings: strictSwiftSettings, linkerSettings: buildRimeRuntime),
        .executableTarget(name: "CoreDictionaryTests", dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowDictionaryTestSupport"], path: "Tests/CoreDictionaryTests", swiftSettings: strictSwiftSettings, linkerSettings: buildRimeRuntime),
        .executableTarget(name: "VoiceLearningCoordinatorTests", dependencies: ["InkFlowDomain"], path: "Tests/VoiceLearningCoordinatorTests", swiftSettings: strictSwiftSettings),
        .target(name: "InkFlowDictionaryTestSupport", dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowCoreTestSupport"], path: "Tests/InkFlowDictionaryTestSupport", swiftSettings: strictSwiftSettings),
        .executableTarget(name: "DictionaryStoreTests", dependencies: ["InkFlowDictionaryTestSupport"], path: "Tests/DictionaryStoreTests", swiftSettings: strictSwiftSettings, linkerSettings: buildRimeRuntime),
        .executableTarget(name: "VoiceLexiconTests", dependencies: ["InkFlowDomain", "InkFlowRime"], path: "Tests/VoiceLexiconTests", swiftSettings: strictSwiftSettings, linkerSettings: buildRimeRuntime),
        .executableTarget(name: "CoreEngineTests", dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowCoreTestSupport", "InkFlowEngineTestSupport"], path: "Tests/CoreEngineTests", swiftSettings: strictSwiftSettings, linkerSettings: buildRimeRuntime),
        .target(name: "InkFlowRankingTestSupport", dependencies: ["InkFlowDomain"], path: "Tests/InkFlowRankingTestSupport", swiftSettings: strictSwiftSettings),
        .target(name: "InkFlowEngineTestSupport", dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowCoreTestSupport", "InkFlowRankingTestSupport"], path: "Tests/InkFlowEngineTestSupport", swiftSettings: strictSwiftSettings),
        .target(name: "InkFlowCoreTestSupport", dependencies: ["InkFlowDomain", "InkFlowRime"], path: "Tests/InkFlowCoreTestSupport", swiftSettings: strictSwiftSettings),
        .target(name: "InkFlowRimeWorker", dependencies: ["CRime"], publicHeadersPath: "include", cSettings: strictCSettings + [.unsafeFlags(["-I\(dependencyRoot)/include"])]),
        .executableTarget(name: "DictionaryGeneratorTool", dependencies: ["InkFlowDomain"], path: "Tools/DictionaryGeneratorTool", swiftSettings: strictSwiftSettings),
        .executableTarget(name: "PackagedCacheTool", dependencies: ["InkFlowRime", "InkFlowRimeWorker"], path: "Tools/PackagedCacheTool", swiftSettings: strictSwiftSettings, linkerSettings: buildRimeRuntime),
        .executableTarget(name: "DictionaryGeneratorTests", dependencies: ["InkFlowDomain"], path: "Tests/DictionaryGeneratorTests", swiftSettings: strictSwiftSettings, linkerSettings: buildRimeRuntime),
        .executableTarget(name: "AIPronunciationTests", dependencies: ["InkFlowDomain"], path: "Tests/AIPronunciationTests", swiftSettings: strictSwiftSettings, linkerSettings: buildRimeRuntime),
        .executableTarget(name: "AIAdoptionLearningTests", dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowCoreTestSupport"], path: "Tests/AIAdoptionLearningTests", swiftSettings: strictSwiftSettings, linkerSettings: buildRimeRuntime),
        .executableTarget(name: "RankingTests", dependencies: ["InkFlowRankingTestSupport"], path: "Tests/RankingTests", swiftSettings: strictSwiftSettings, linkerSettings: buildRimeRuntime),

        .target(name: "InkFlowDomain", swiftSettings: strictSwiftSettings),
        .target(name: "CRime", publicHeadersPath: "include",
                cSettings: strictCSettings + [.unsafeFlags(["-I\(dependencyRoot)/include"])],
                linkerSettings: rimeLinkerSettings),
        .target(name: "InkFlowRime", dependencies: ["InkFlowDomain", "CRime"],
                swiftSettings: strictSwiftSettings, linkerSettings: [.linkedLibrary("sqlite3")] + rimeLinkerSettings)
    ]
)
