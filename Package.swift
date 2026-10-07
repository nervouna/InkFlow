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
let nativeRoot = URL(fileURLWithPath: dependencyRoot).deletingLastPathComponent().appendingPathComponent("native").path
let nativeCxxSettings: [CXXSetting] = [.unsafeFlags([
    "-Wall", "-Wextra", "-Werror", "-DBOOST_DLL_USE_STD_FS",
    "-DGLOG_EXPORT=", "-DGLOG_NO_EXPORT=", "-DGLOG_DEPRECATED=__attribute__((deprecated))",
    "-isystem", "\(nativeRoot)/deps/include", "-isystem", "\(nativeRoot)/generated",
    "-isystem", "\(nativeRoot)/boost", "-isystem", "\(nativeRoot)/librime/src",
    "-isystem", "\(nativeRoot)/librime/include",
])]
let strictCSettings: [CSetting] = [.unsafeFlags(["-Wall", "-Wextra", "-Werror"])]
let inkFlowCoreSources = [
    "AIChatCompletions.swift", "AIContext.swift", "AIDiagnostics.swift", "AIInputPresentation.swift",
    "AISettings.swift",
    "AISuggestionCoordinator.swift", "AISuggestionPanel.swift", "ApplicationBootstrap.swift", "ApplicationLifecycle.swift",
    "AppleVoiceRecognizer.swift", "VoiceSession.swift", "VoiceCorrectionClient.swift", "VoiceLearning.swift", "VoicePolishApplicationPicker.swift", "VoicePolishPrompt.swift", "VoicePolishRule.swift", "VoicePolishRuleEditor.swift", "VoicePolishRuleRow.swift", "VoicePolishRulesView.swift", "VoiceSettings.swift", "VoiceSettingsView.swift", "InputControllerVoice.swift", "CandidatePresentation.swift", "Context.swift", "InputControllerAI.swift",
    "EngineEvent.swift", "InputControllerCore.swift", "InputRankingContext.swift", "InputStatusPanel.swift", "InputStatusPresentation.swift",
    "ThunderPanel.swift", "ThunderPresentation.swift",
    "CustomPhrases.swift", "DictionaryCoordinator.swift",
    "DictionarySettings.swift",
    "PersonalLearningSettings.swift",
    "PersonalDataBackup.swift", "PersonalDataTransaction.swift", "PersonalDataSettingsView.swift",
    "QualitySettingsView.swift",
    "QualityExport.swift",
    "DictionaryWorkerBootstrap.swift", "DictionaryWorkerProtocol.swift",
    "DictionaryWorkerRunner.swift", "InputController.swift",
    "Settings.swift", "KeyboardShortcuts.swift", "ShortcutsSettingsView.swift", "AboutSettingsView.swift", "FeedbackReport.swift", "FeedbackSettingsView.swift", "DiagnosticFeedbackDependencies.swift", "DiagnosticFeedbackModel.swift", "DiagnosticFeedbackView.swift",
    "SmartSettingsView.swift", "StartupDiagnostics.swift", "LocalDiagnostics.swift", "DiagnosticIncident.swift", "DiagnosticArchive.swift", "DiagnosticCrashReader.swift",
    "UpdateSettingsView.swift",
]
let installerCoreSources = [
    "Bootstrap.swift", "InstallerCoordinator.swift", "InstallerLifecycle.swift", "InstallerTransaction.swift",
    "InstallerValidation.swift", "NativeWindow.swift", "ShippedPayload.swift",
]
let toolSources = [ "QualityBuildMetadata.swift", "RegisterInputSource.swift", "quality_exchange.py"]
let testSwiftSources = [
    "PersonalDataTests.swift", "QualityExportFixture.swift",
    "AIControllerNativeTests.swift", "AICredentialTests.swift",
    "AIDiagnosticTestSupport.swift", "AIHeadlessPipelineSupport.swift", "AIHeadlessPipelineTests.swift",
    "AILiveConfiguration.swift", "AILiveTests.swift", "AIRuntimeTestSupport.swift",
    "AIRuntimeTests.swift", "AISuggestionTests.swift",
    "ControllerInitializationTests.swift", "ControllerTests.swift", "DeploymentTests.swift",
    "DictionaryActivationTests.swift", "DictionarySettingsUITests.swift",
    "BundleArtifactSmokeTests.swift", "DictionaryUpdateTests.swift", "DictionaryWorkerFixture.swift", "EngineTests.swift", "InstallerCoreTests.swift",
    "InstallerWindowTests.swift", "MetadataTests.swift", "QualityCaptureTests.swift",
    "QualityControllerTimingTests.swift", "QualityIdentityTests.swift", "QualityStoreTests.swift", "QualityTimingTests.swift",
    "ServingStartupTests.swift", "SettingsTests.swift", "DiagnosticFeedbackModelTests.swift", "SettingsUITests.swift", "StartupDiagnosticsTests.swift", "LocalDiagnosticsTests.swift", "DiagnosticArchiveTests.swift",
    "TerminationTests.swift", "TestSupport.swift", "UpdateTests.swift", "VoiceSessionTests.swift", "AppleVoiceRecognizerTests.swift", "VoiceControllerTests.swift",
]
let testAuxiliarySources = [
    "NativeTestSupport.m", "QualityQueryTests.py", "ServingStartupHarness.plist", "include",
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
    ("personal-data-tests", "PersonalDataTests"),
    ("voice-learning-coordinator-tests", "VoiceLearningCoordinatorTests"),
    ("ai-adoption-learning-tests", "AIAdoptionLearningTests"),
    ("ai-credential-tests", "AICredentialTests"),
    ("ai-headless-tests", "AIHeadlessTests"),
    ("ai-live-tests", "AILiveTests"),
    ("ai-native-tests", "AINativeTests"),
    ("ai-pronunciation-tests", "AIPronunciationTests"),
    ("ai-runtime-tests", "AIRuntimeTests"),
    ("ai-suggestion-tests", "AISuggestionTests"),
    ("controller-initialization-tests", "ControllerInitializationTests"),
    ("controller-tests", "ControllerTests"),
    ("deployment-tests", "DeploymentTests"),
    ("dictionary-activation-tests", "DictionaryActivationTests"),
    ("dictionary-generator-tests", "DictionaryGeneratorTests"),
    ("dictionary-store-tests", "DictionaryStoreTests"),
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
    ("local-diagnostics-tests", "LocalDiagnosticsTests"),
    ("diagnostic-archive-tests", "DiagnosticArchiveTests"),
    ("termination-tests", "TerminationTests"),
    ("voice-session-tests", "VoiceSessionTests"),
    ("apple-voice-tests", "AppleVoiceRecognizerTests"),
    ("bundle-artifact-smoke-tests", "BundleArtifactSmokeTests"),
    ("voice-lexicon-tests", "VoiceLexiconTests"),
    ("voice-controller-tests", "VoiceControllerTests"),
]

let package = Package(
    name: "InkFlow",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "dictionary-preparation-fixture", targets: ["DictionaryPreparationFixture"]),
        .executable(name: "core-dictionary-tests", targets: ["CoreDictionaryTests"]),
        .executable(name: "InkFlow", targets: ["InkFlowApp"]),
        .executable(name: "InkFlowDictionaryWorker", targets: ["InkFlowDictionaryWorker"]),
        .executable(name: "InkFlowInstaller", targets: ["InkFlowInstaller"]),
        .executable(name: "dictionary-generator", targets: ["DictionaryGeneratorTool"]),
        .executable(name: "register-input-source", targets: ["RegisterInputSourceTool"]),
        .executable(name: "quality-build-metadata", targets: ["QualityBuildMetadataTool"]),
        .executable(name: "packaged-cache-tool", targets: ["PackagedCacheTool"]),
    ] + executableTestProducts.map { .executable(name: $0.0, targets: [$0.1]) },
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "InkFlowRimeNative", path: "Core/Sources/InkFlowRimeNative",
                publicHeadersPath: "include", cxxSettings: nativeCxxSettings, linkerSettings: rimeLinkerSettings),
        .executableTarget(name: "DictionaryPreparationFixture", dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowRimeWorker"], path: "Core/Tests/DictionaryPreparationFixture", swiftSettings: strictSwiftSettings, linkerSettings: buildRimeRuntime),
        .executableTarget(name: "CoreDictionaryTests", dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowDictionaryTestSupport"], path: "Core/Tests/CoreDictionaryTests", swiftSettings: strictSwiftSettings, linkerSettings: buildRimeRuntime),
        .executableTarget(name: "VoiceLearningCoordinatorTests", dependencies: ["InkFlowDomain"], path: "Core/Tests/VoiceLearningCoordinatorTests", swiftSettings: strictSwiftSettings),
        .target(name: "InkFlowDictionaryTestSupport", dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowCoreTestSupport"], path: "Core/Tests/InkFlowDictionaryTestSupport", swiftSettings: strictSwiftSettings),
        .executableTarget(name: "DictionaryStoreTests", dependencies: ["InkFlowDictionaryTestSupport"], path: "Core/Tests/DictionaryStoreTests", swiftSettings: strictSwiftSettings, linkerSettings: buildRimeRuntime),
        .target(name: "InkFlowRankingTestSupport", dependencies: ["InkFlowDomain"], path: "Core/Tests/InkFlowRankingTestSupport", swiftSettings: strictSwiftSettings),
        .target(name: "InkFlowEngineTestSupport", dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowCoreTestSupport", "InkFlowRankingTestSupport"], path: "Core/Tests/InkFlowEngineTestSupport", swiftSettings: strictSwiftSettings),
        .target(name: "InkFlowCoreTestSupport", dependencies: ["InkFlowDomain", "InkFlowRime"], path: "Core/Tests/InkFlowCoreTestSupport", swiftSettings: strictSwiftSettings),
        .target(name: "InkFlowRime", dependencies: ["InkFlowDomain", "CRime"], path: "Core/Sources/InkFlowRime", swiftSettings: strictSwiftSettings, linkerSettings: [.linkedLibrary("sqlite3")] + rimeLinkerSettings),
        .target(name: "InkFlowDomain", path: "Core/Sources/InkFlowDomain", swiftSettings: strictSwiftSettings),
        .target(
            name: "CRime",
            dependencies: ["InkFlowRimeNative"],
            path: "Core/Sources/CRime",
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
            path: "Core/Sources/InkFlowRimeWorker",
            publicHeadersPath: "include",
            cSettings: strictCSettings + [.unsafeFlags(["-I\(dependencyRoot)/include"])]
        ),
        .target(
            name: "InkFlowInputSources",
            path: "macOS/Shared",
            sources: ["InputSourceManager.swift", "RegisterInputSourceBootstrap.swift", "TrialInstallationLifecycle.swift"],
            swiftSettings: strictSwiftSettings,
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .target(
            name: "InkFlowCore",
            dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowRimeNative", "CRime", "InkFlowNative"],
            path: "macOS/Sources",
            exclude: ["main.swift", "NativeCandidates.h", "NativeCandidates.m", "InkFlow-Bridging-Header.h"],
            sources: inkFlowCoreSources,
            swiftSettings: strictSwiftSettings + [.unsafeFlags(["-Xcc", "-I\(dependencyRoot)/include"])],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("InputMethodKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("sqlite3"),
            ] + rimeLinkerSettings
        ),
        .executableTarget(
            name: "InkFlowApp",
            dependencies: ["InkFlowCore", .product(name: "Sparkle", package: "Sparkle")],
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
        .executableTarget(name: "DictionaryGeneratorTool", dependencies: ["InkFlowDomain"],
            path: "Core/Tools/DictionaryGeneratorTool", swiftSettings: strictSwiftSettings),
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
        .executableTarget(name: "PackagedCacheTool", dependencies: ["InkFlowRime", "InkFlowRimeWorker"],
            path: "Core/Tools/PackagedCacheTool", swiftSettings: strictSwiftSettings, linkerSettings: buildRimeRuntime),
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
            dependencies: ["InkFlowCore", "InkFlowCoreTestSupport"],
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
                  "AIRuntimeTestSupport.swift"].contains($0)
            } + testAuxiliarySources,
            sources: ["AIDiagnosticTestSupport.swift", "AIHeadlessPipelineSupport.swift", "AILiveConfiguration.swift",
                      "AIRuntimeTestSupport.swift"],
            swiftSettings: strictSwiftSettings,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "AIAdoptionLearningTests", dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowCoreTestSupport"], path: "Core/Tests/AIAdoptionLearningTests", swiftSettings: strictSwiftSettings, linkerSettings: buildRimeRuntime),
        executableTestTarget("PersonalDataTests", sources: ["PersonalDataTests.swift"], dependencies: ["InkFlowCore", "InkFlowRime", "InkFlowDomain", "InkFlowRimeNative"]),
        executableTestTarget("AICredentialTests", sources: ["AICredentialTests.swift"]),
        executableTestTarget("AIHeadlessTests", sources: ["AIHeadlessPipelineTests.swift"],
            dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("AILiveTests", sources: ["AILiveTests.swift"],
            dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("AINativeTests", sources: ["AIControllerNativeTests.swift"],
            dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        .executableTarget(name: "AIPronunciationTests", dependencies: ["InkFlowDomain"], path: "Core/Tests/AIPronunciationTests", swiftSettings: strictSwiftSettings, linkerSettings: buildRimeRuntime),
        executableTestTarget("AIRuntimeTests", sources: ["AIRuntimeTests.swift"],
            dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("AISuggestionTests", sources: ["AISuggestionTests.swift"],
            dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("ControllerInitializationTests", sources: ["ControllerInitializationTests.swift"]),
        executableTestTarget("ControllerTests", sources: ["ControllerTests.swift"]),
        executableTestTarget("DeploymentTests", sources: ["DeploymentTests.swift"]),
        executableTestTarget("DictionaryActivationTests", sources: ["DictionaryActivationTests.swift"], dependencies: standardTestDependencies + ["InkFlowDictionaryTestSupport"]),
        .executableTarget(name: "DictionaryGeneratorTests", dependencies: ["InkFlowDomain"], path: "Core/Tests/DictionaryGeneratorTests", swiftSettings: strictSwiftSettings, linkerSettings: buildRimeRuntime),
        executableTestTarget("DictionaryUpdateTests", sources: ["DictionaryUpdateTests.swift"], dependencies: standardTestDependencies + ["InkFlowDictionaryTestSupport"]),
        executableTestTarget("DictionaryWorkerFixture", sources: ["DictionaryWorkerFixture.swift"]),
        executableTestTarget("EngineTests", sources: ["EngineTests.swift"], dependencies: standardTestDependencies + ["InkFlowEngineTestSupport"]),
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
        executableTestTarget("SettingsTests", sources: ["SettingsTests.swift", "UpdateTests.swift", "DiagnosticFeedbackModelTests.swift"]),
        executableTestTarget("SettingsUITests", sources: ["SettingsUITests.swift", "DictionarySettingsUITests.swift"]),
        executableTestTarget("StartupDiagnosticsTests", sources: ["StartupDiagnosticsTests.swift"]),
        executableTestTarget("LocalDiagnosticsTests", sources: ["LocalDiagnosticsTests.swift"]),
        executableTestTarget("DiagnosticArchiveTests", sources: ["DiagnosticArchiveTests.swift"]),
        executableTestTarget("AppleVoiceRecognizerTests", sources: ["AppleVoiceRecognizerTests.swift"]),
        executableTestTarget("BundleArtifactSmokeTests", sources: ["BundleArtifactSmokeTests.swift"],
            dependencies: ["InkFlowDomain", "InkFlowRime"]),
        executableTestTarget("VoiceSessionTests", sources: ["VoiceSessionTests.swift"]),
        .executableTarget(name: "VoiceLexiconTests", dependencies: ["InkFlowDomain", "InkFlowRime"], path: "Core/Tests/VoiceLexiconTests", swiftSettings: strictSwiftSettings, linkerSettings: buildRimeRuntime),
        executableTestTarget("VoiceControllerTests", sources: ["VoiceControllerTests.swift"]),
        executableTestTarget("TerminationTests", sources: ["TerminationTests.swift"]),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
