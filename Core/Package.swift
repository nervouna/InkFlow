// swift-tools-version: 6.2
import Foundation
import PackageDescription

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
// Portable Rust core, built by Core/scripts/build-portable.sh; see the root Package.swift.
let portableRoot = repository.appendingPathComponent("build/portable").path
let portableLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["\(portableRoot)/cargo/release/libinkflow_rime.a", "-L\(portableRoot)/prefix/lib"]),
    .linkedLibrary("rime"), .linkedLibrary("c++"),
]
let portableRuntime: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "\(portableRoot)/prefix/lib"]),
]
let strictSwiftSettings: [SwiftSetting] = [.unsafeFlags(["-warnings-as-errors"])]
let package = Package(
    name: "InkFlowShared",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .executable(name: "quality-baseline", targets: ["QualityBaseline"]),
        .executable(name: "performance-baseline", targets: ["PerformanceBaseline"]),
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
        .executable(name: "ai-adoption-learning-tests", targets: ["AIAdoptionLearningTests"])
    ],
    targets: [
        .executableTarget(name: "QualityBaseline", dependencies: ["InkFlowDomain", "InkFlowRime"], path: "Tests/QualityBaseline", swiftSettings: strictSwiftSettings, linkerSettings: portableRuntime),
        .executableTarget(name: "PerformanceBaseline", dependencies: ["InkFlowDomain", "InkFlowRime"], path: "Tests/PerformanceBaseline", swiftSettings: strictSwiftSettings, linkerSettings: portableRuntime),
        .executableTarget(name: "DictionaryPreparationFixture", dependencies: ["InkFlowDomain", "InkFlowRime"], path: "Tests/DictionaryPreparationFixture", swiftSettings: strictSwiftSettings, linkerSettings: portableRuntime),
        .executableTarget(name: "CoreDictionaryTests", dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowDictionaryTestSupport"], path: "Tests/CoreDictionaryTests", swiftSettings: strictSwiftSettings, linkerSettings: portableRuntime),
        .executableTarget(name: "VoiceLearningCoordinatorTests", dependencies: ["InkFlowDomain"], path: "Tests/VoiceLearningCoordinatorTests", swiftSettings: strictSwiftSettings),
        .target(name: "InkFlowDictionaryTestSupport", dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowCoreTestSupport"], path: "Tests/InkFlowDictionaryTestSupport", swiftSettings: strictSwiftSettings),
        .executableTarget(name: "DictionaryStoreTests", dependencies: ["InkFlowDictionaryTestSupport"], path: "Tests/DictionaryStoreTests", swiftSettings: strictSwiftSettings, linkerSettings: portableRuntime),
        .executableTarget(name: "VoiceLexiconTests", dependencies: ["InkFlowDomain", "InkFlowRime"], path: "Tests/VoiceLexiconTests", swiftSettings: strictSwiftSettings, linkerSettings: portableRuntime),
        .executableTarget(name: "CoreEngineTests", dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowCoreTestSupport", "InkFlowEngineTestSupport"], path: "Tests/CoreEngineTests", swiftSettings: strictSwiftSettings, linkerSettings: portableRuntime),
        .target(name: "InkFlowEngineTestSupport", dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowCoreTestSupport"], path: "Tests/InkFlowEngineTestSupport", swiftSettings: strictSwiftSettings),
        .target(name: "InkFlowCoreTestSupport", dependencies: ["InkFlowDomain", "InkFlowRime"], path: "Tests/InkFlowCoreTestSupport", swiftSettings: strictSwiftSettings),
        .executableTarget(name: "DictionaryGeneratorTool", dependencies: ["InkFlowDomain"], path: "Tools/DictionaryGeneratorTool", swiftSettings: strictSwiftSettings),
        .executableTarget(name: "PackagedCacheTool", dependencies: ["InkFlowRime"], path: "Tools/PackagedCacheTool", swiftSettings: strictSwiftSettings, linkerSettings: portableRuntime),
        .executableTarget(name: "DictionaryGeneratorTests", dependencies: ["InkFlowDomain"], path: "Tests/DictionaryGeneratorTests", swiftSettings: strictSwiftSettings),
        .executableTarget(name: "AIPronunciationTests", dependencies: ["InkFlowDomain"], path: "Tests/AIPronunciationTests", swiftSettings: strictSwiftSettings),
        .executableTarget(name: "AIAdoptionLearningTests", dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowCoreTestSupport"], path: "Tests/AIAdoptionLearningTests", swiftSettings: strictSwiftSettings, linkerSettings: portableRuntime),

        .target(name: "InkFlowDictionary", path: "Sources/InkFlowDictionary",
                publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I\(repository.path)/build/dictionary/include"])],
                linkerSettings: [.unsafeFlags(["-L\(repository.path)/build/dictionary/cargo/release"]),
                    .linkedLibrary("inkflow_dictionary"), .linkedLibrary("resolv"), .linkedLibrary("iconv")]),
        .target(name: "InkFlowDomain", dependencies: ["InkFlowDictionary"], path: "Sources/InkFlowDomain",
                swiftSettings: strictSwiftSettings),
        .target(name: "InkFlowRime", dependencies: ["InkFlowDomain", "InkFlowPortable"],
                swiftSettings: strictSwiftSettings, linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "InkFlowPortable", path: "Sources/InkFlowPortable",
                publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I\(portableRoot)/include"])],
                linkerSettings: portableLinkerSettings)
    ],
    cxxLanguageStandard: .cxx17
)
