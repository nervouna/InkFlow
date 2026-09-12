// swift-tools-version: 6.2
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let dependencyRoot = "\(packageRoot)/build/deps/dist"
let rimeLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L\(dependencyRoot)/lib"]),
    .linkedLibrary("rime"),
]
let bundledRimeRuntime: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
]
let buildRimeRuntime: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "\(dependencyRoot)/lib"]),
]
let strictSwiftSettings: [SwiftSetting] = [.unsafeFlags(["-warnings-as-errors"])]
let strictCSettings: [CSetting] = [.unsafeFlags(["-Wall", "-Wextra", "-Werror"])]
let inkFlowCoreSources = [
    "AIChatCompletions.swift", "AIContext.swift", "AIDiagnostics.swift", "AIInputPresentation.swift",
    "AIPronunciation.swift", "AISettings.swift", "AIStatistics.swift", "AIStatisticsStore.swift",
    "AISuggestionCoordinator.swift", "AISuggestionPanel.swift", "ApplicationBootstrap.swift", "ApplicationLifecycle.swift",
    "AppleVoiceRecognizer.swift", "VoiceSession.swift", "VoiceCorrectionClient.swift", "VoiceLexicon.swift", "VoiceSettings.swift", "VoiceSettingsView.swift", "InputControllerVoice.swift", "CandidatePresentation.swift", "Context.swift", "EngineAI.swift", "InputControllerAI.swift",
    "InputControllerCore.swift", "InputRankingContext.swift", "InputStatusPanel.swift", "InputStatusPresentation.swift",
    "CustomPhrases.swift", "DictionaryCoordinator.swift", "DictionaryGenerator.swift", "DictionaryModels.swift",
    "DictionarySettings.swift", "DictionarySourceClient.swift", "DictionaryStore.swift", "DictionaryToolBootstrap.swift",
    "DictionaryUpdateModels.swift", "DictionaryWorkerBootstrap.swift", "DictionaryWorkerProtocol.swift",
    "DictionaryWorkerRunner.swift", "Engine.swift", "InputController.swift", "InputPreferences.swift",
    "PackagedCache.swift", "PackagedCacheBootstrap.swift", "QualityRecorder.swift", "QualityRecords.swift",
    "QualityStore.swift", "Settings.swift", "SmartSettingsView.swift", "StartupDiagnostics.swift",
]
let installerCoreSources = [
    "Bootstrap.swift", "InstallerCoordinator.swift", "InstallerLifecycle.swift", "InstallerTransaction.swift",
    "InstallerValidation.swift", "NativeWindow.swift", "ShippedPayload.swift",
]
let toolSources = ["PackagedCacheTool.swift", "QualityBuildMetadata.swift", "RegisterInputSource.swift", "ai-statistics.py"]
let testSwiftSources = [
    "AIAdoptionLearningTests.swift", "AIControllerNativeTests.swift", "AICredentialTests.swift",
    "AIDiagnosticTestSupport.swift", "AIHeadlessPipelineSupport.swift", "AIHeadlessPipelineTests.swift",
    "AILiveConfiguration.swift", "AILiveTests.swift", "AIPronunciationTests.swift", "AIRuntimeTestSupport.swift",
    "AIRuntimeTests.swift", "AIStatisticsTestSupport.swift", "AIStatisticsTests.swift", "AISuggestionTests.swift",
    "ControllerInitializationTests.swift", "ControllerTests.swift", "DeploymentTests.swift",
    "DictionaryActivationTests.swift", "DictionaryGeneratorTests.swift", "DictionarySettingsUITests.swift",
    "DictionaryUpdateTests.swift", "DictionaryWorkerFixture.swift", "EngineTests.swift", "InstallerCoreTests.swift",
    "InstallerWindowTests.swift", "MetadataTests.swift", "QualityCaptureTests.swift",
    "QualityControllerTimingTests.swift", "QualityIdentityTests.swift", "QualityStoreTests.swift", "QualityTimingTests.swift",
    "ServingStartupTests.swift", "SettingsTests.swift", "SettingsUITests.swift", "StartupDiagnosticsTests.swift",
    "TerminationTests.swift", "TestSupport.swift", "VoiceSessionTests.swift", "AppleVoiceRecognizerTests.swift", "VoiceLexiconTests.swift", "VoiceControllerTests.swift",
]
let testAuxiliarySources = [
    "AIStatisticsQueryTests.py", "NativeTestSupport.m", "QualityQueryTests.py", "ServingStartupHarness.plist", "include",
]
let standardTestDependencies: [Target.Dependency] = [
    "InkFlowCore", "InkFlowTestSupport", "InkFlowNativeTestSupport",
]
func executableTestTarget(_ name: String, sources: [String],
                          dependencies: [Target.Dependency]? = nil,
                          linkerSettings: [LinkerSetting] = buildRimeRuntime) -> Target {
    .executableTarget(
        name: name,
        dependencies: dependencies ?? standardTestDependencies,
        path: "macOS/Tests",
        exclude: testSwiftSources.filter { !sources.contains($0) } + testAuxiliarySources,
        sources: sources,
        swiftSettings: strictSwiftSettings,
        linkerSettings: linkerSettings
    )
}

let executableTestProducts: [(String, String)] = [
    ("ai-adoption-learning-tests", "AIAdoptionLearningTests"),
    ("ai-credential-tests", "AICredentialTests"),
    ("ai-headless-tests", "AIHeadlessTests"),
    ("ai-live-tests", "AILiveTests"),
    ("ai-native-tests", "AINativeTests"),
    ("ai-pronunciation-tests", "AIPronunciationTests"),
    ("ai-runtime-tests", "AIRuntimeTests"),
    ("ai-statistics-tests", "AIStatisticsTests"),
    ("ai-suggestion-tests", "AISuggestionTests"),
    ("controller-initialization-tests", "ControllerInitializationTests"),
    ("controller-tests", "ControllerTests"),
    ("deployment-tests", "DeploymentTests"),
    ("dictionary-activation-tests", "DictionaryActivationTests"),
    ("dictionary-generator-tests", "DictionaryGeneratorTests"),
    ("dictionary-update-tests", "DictionaryUpdateTests"),
    ("dictionary-worker-fixture", "DictionaryWorkerFixture"),
    ("engine-tests", "EngineTests"),
    ("installer-core-tests", "InstallerCoreTests"),
    ("installer-window-tests", "InstallerWindowTests"),
    ("metadata-tests", "MetadataTests"),
    ("quality-capture-tests", "QualityCaptureTests"),
    ("quality-store-tests", "QualityStoreTests"),
    ("quality-identity-tests", "QualityIdentityTests"),
    ("quality-timing-tests", "QualityTimingTests"),
    ("serving-startup-tests", "ServingStartupTests"),
    ("settings-tests", "SettingsTests"),
    ("settings-ui-tests", "SettingsUITests"),
    ("startup-diagnostics-tests", "StartupDiagnosticsTests"),
    ("termination-tests", "TerminationTests"),
    ("voice-session-tests", "VoiceSessionTests"),
    ("apple-voice-tests", "AppleVoiceRecognizerTests"),
    ("voice-lexicon-tests", "VoiceLexiconTests"),
    ("voice-controller-tests", "VoiceControllerTests"),
]

let package = Package(
    name: "InkFlow",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "InkFlow", targets: ["InkFlowApp"]),
        .executable(name: "InkFlowDictionaryWorker", targets: ["InkFlowDictionaryWorker"]),
        .executable(name: "InkFlowInstaller", targets: ["InkFlowInstaller"]),
        .executable(name: "dictionary-generator", targets: ["DictionaryGeneratorTool"]),
        .executable(name: "register-input-source", targets: ["RegisterInputSourceTool"]),
        .executable(name: "quality-build-metadata", targets: ["QualityBuildMetadataTool"]),
        .executable(name: "packaged-cache-tool", targets: ["PackagedCacheTool"]),
    ] + executableTestProducts.map { .executable(name: $0.0, targets: [$0.1]) },
    targets: [
        .target(
            name: "CRime",
            path: "macOS/SwiftPM/CRime",
            publicHeadersPath: "include",
            cSettings: strictCSettings + [.unsafeFlags(["-I\(dependencyRoot)/include"])],
            linkerSettings: rimeLinkerSettings
        ),
        .target(
            name: "InkFlowNative",
            path: "macOS/SwiftPM/InkFlowNative",
            publicHeadersPath: "include",
            cSettings: strictCSettings + [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("InputMethodKit")]
        ),
        .target(
            name: "InkFlowRimeWorker",
            dependencies: ["CRime"],
            path: "macOS/SwiftPM/InkFlowRimeWorker",
            publicHeadersPath: "include",
            cSettings: strictCSettings + [.unsafeFlags(["-I\(dependencyRoot)/include"])]
        ),
        .target(
            name: "InkFlowInputSources",
            path: "macOS/Shared",
            sources: ["InputSourceManager.swift", "RegisterInputSourceBootstrap.swift"],
            swiftSettings: strictSwiftSettings,
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .target(
            name: "InkFlowCore",
            dependencies: ["CRime", "InkFlowNative"],
            path: "macOS/Sources",
            exclude: ["main.swift", "NativeCandidates.h", "NativeCandidates.m", "InkFlow-Bridging-Header.h"],
            sources: inkFlowCoreSources,
            swiftSettings: strictSwiftSettings + [.unsafeFlags(["-Xcc", "-I\(dependencyRoot)/include"])],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("InputMethodKit"),
                .linkedFramework("Carbon"),
                .linkedLibrary("sqlite3"),
            ] + rimeLinkerSettings
        ),
        .executableTarget(
            name: "InkFlowApp",
            dependencies: ["InkFlowCore"],
            path: "macOS/Sources",
            exclude: inkFlowCoreSources + ["NativeCandidates.h", "NativeCandidates.m", "InkFlow-Bridging-Header.h"],
            sources: ["main.swift"],
            swiftSettings: strictSwiftSettings,
            linkerSettings: bundledRimeRuntime
        ),
        .executableTarget(
            name: "InkFlowDictionaryWorker",
            dependencies: ["InkFlowCore", "InkFlowRimeWorker"],
            path: "macOS/DictionaryWorker",
            exclude: ["RimeWorker.c", "RimeWorker.h"],
            sources: ["main.swift"],
            swiftSettings: strictSwiftSettings,
            linkerSettings: bundledRimeRuntime
        ),
        .target(
            name: "InkFlowInstallerCore",
            dependencies: ["InkFlowInputSources"],
            path: "macOS/Installer",
            exclude: ["AppMain.swift", "CoreAPI.md", "Info.plist"],
            sources: installerCoreSources,
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "InkFlowInstaller",
            dependencies: ["InkFlowInstallerCore"],
            path: "macOS/Installer",
            exclude: installerCoreSources + ["CoreAPI.md", "Info.plist"],
            sources: ["AppMain.swift"],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "DictionaryGeneratorTool",
            dependencies: ["InkFlowCore"],
            path: "macOS/DictionaryTool",
            swiftSettings: strictSwiftSettings,
            linkerSettings: buildRimeRuntime
        ),
        .executableTarget(
            name: "RegisterInputSourceTool",
            dependencies: ["InkFlowInputSources"],
            path: "macOS/Tools",
            exclude: toolSources.filter { $0 != "RegisterInputSource.swift" },
            sources: ["RegisterInputSource.swift"],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "QualityBuildMetadataTool",
            dependencies: ["InkFlowCore"],
            path: "macOS/Tools",
            exclude: toolSources.filter { $0 != "QualityBuildMetadata.swift" },
            sources: ["QualityBuildMetadata.swift"],
            swiftSettings: strictSwiftSettings,
            linkerSettings: buildRimeRuntime
        ),
        .executableTarget(
            name: "PackagedCacheTool",
            dependencies: ["InkFlowCore", "InkFlowRimeWorker"],
            path: "macOS/Tools",
            exclude: toolSources.filter { $0 != "PackagedCacheTool.swift" },
            sources: ["PackagedCacheTool.swift"],
            swiftSettings: strictSwiftSettings,
            linkerSettings: buildRimeRuntime
        ),
        .target(
            name: "InkFlowNativeTestSupport",
            path: "macOS/Tests",
            exclude: testSwiftSources + testAuxiliarySources.filter { $0 != "NativeTestSupport.m" && $0 != "include" },
            sources: ["NativeTestSupport.m"],
            publicHeadersPath: "include",
            cSettings: strictCSettings + [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("InputMethodKit")]
        ),
        .target(
            name: "InkFlowTestSupport",
            dependencies: ["InkFlowCore"],
            path: "macOS/Tests",
            exclude: testSwiftSources.filter { $0 != "TestSupport.swift" } + testAuxiliarySources,
            sources: ["TestSupport.swift"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "InkFlowAITestSupport",
            dependencies: ["InkFlowCore", "InkFlowTestSupport"],
            path: "macOS/Tests",
            exclude: testSwiftSources.filter {
                !["AIDiagnosticTestSupport.swift", "AIHeadlessPipelineSupport.swift", "AILiveConfiguration.swift",
                  "AIRuntimeTestSupport.swift", "AIStatisticsTestSupport.swift"].contains($0)
            } + testAuxiliarySources,
            sources: ["AIDiagnosticTestSupport.swift", "AIHeadlessPipelineSupport.swift", "AILiveConfiguration.swift",
                      "AIRuntimeTestSupport.swift", "AIStatisticsTestSupport.swift"],
            swiftSettings: strictSwiftSettings,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        executableTestTarget("AIAdoptionLearningTests", sources: ["AIAdoptionLearningTests.swift"]),
        executableTestTarget("AICredentialTests", sources: ["AICredentialTests.swift"]),
        executableTestTarget("AIHeadlessTests", sources: ["AIHeadlessPipelineTests.swift"],
            dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("AILiveTests", sources: ["AILiveTests.swift"],
            dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("AINativeTests", sources: ["AIControllerNativeTests.swift"],
            dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("AIPronunciationTests", sources: ["AIPronunciationTests.swift"]),
        executableTestTarget("AIRuntimeTests", sources: ["AIRuntimeTests.swift"],
            dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("AIStatisticsTests", sources: ["AIStatisticsTests.swift"],
            dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("AISuggestionTests", sources: ["AISuggestionTests.swift"],
            dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("ControllerInitializationTests", sources: ["ControllerInitializationTests.swift"]),
        executableTestTarget("ControllerTests", sources: ["ControllerTests.swift"]),
        executableTestTarget("DeploymentTests", sources: ["DeploymentTests.swift"]),
        executableTestTarget("DictionaryActivationTests", sources: ["DictionaryActivationTests.swift"]),
        executableTestTarget("DictionaryGeneratorTests", sources: ["DictionaryGeneratorTests.swift"]),
        executableTestTarget("DictionaryUpdateTests", sources: ["DictionaryUpdateTests.swift"]),
        executableTestTarget("DictionaryWorkerFixture", sources: ["DictionaryWorkerFixture.swift"]),
        executableTestTarget("EngineTests", sources: ["EngineTests.swift"]),
        executableTestTarget("InstallerCoreTests", sources: ["InstallerCoreTests.swift"],
            dependencies: ["InkFlowInstallerCore", "InkFlowInputSources"], linkerSettings: []),
        executableTestTarget("InstallerWindowTests", sources: ["InstallerWindowTests.swift"],
            dependencies: ["InkFlowInstallerCore", "InkFlowInputSources"], linkerSettings: []),
        executableTestTarget("MetadataTests", sources: ["MetadataTests.swift"]),
        executableTestTarget("QualityCaptureTests",
            sources: ["QualityCaptureTests.swift", "QualityControllerTimingTests.swift"]),
        executableTestTarget("QualityIdentityTests", sources: ["QualityIdentityTests.swift"]),
        executableTestTarget("QualityStoreTests", sources: ["QualityStoreTests.swift"]),
        executableTestTarget("QualityTimingTests", sources: ["QualityTimingTests.swift"]),
        executableTestTarget("ServingStartupTests", sources: ["ServingStartupTests.swift"]),
        executableTestTarget("SettingsTests", sources: ["SettingsTests.swift"]),
        executableTestTarget("SettingsUITests", sources: ["SettingsUITests.swift", "DictionarySettingsUITests.swift"]),
        executableTestTarget("StartupDiagnosticsTests", sources: ["StartupDiagnosticsTests.swift"]),
        executableTestTarget("AppleVoiceRecognizerTests", sources: ["AppleVoiceRecognizerTests.swift"]),
        executableTestTarget("VoiceSessionTests", sources: ["VoiceSessionTests.swift"]),
        executableTestTarget("VoiceLexiconTests", sources: ["VoiceLexiconTests.swift"]),
        executableTestTarget("VoiceControllerTests", sources: ["VoiceControllerTests.swift"]),
        executableTestTarget("TerminationTests", sources: ["TerminationTests.swift"]),
    ],
    swiftLanguageModes: [.v6]
)
