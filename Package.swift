// swift-tools-version: 6.2
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let bundledRimeRuntime: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
]
let portableRoot = "\(packageRoot)/build/portable"
let portableLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["\(portableRoot)/cargo/release/libinkflow_rime.a", "-L\(portableRoot)/prefix/lib"]),
    .linkedLibrary("rime"), .linkedLibrary("c++"),
]
let portableRuntime: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "\(portableRoot)/prefix/lib"]),
]
let strictSwiftSettings: [SwiftSetting] = [.unsafeFlags(["-warnings-as-errors"])]
let strictCSettings: [CSetting] = [.unsafeFlags(["-Wall", "-Wextra", "-Werror"])]
let toolSources = [ "QualityBuildMetadata.swift", "RegisterInputSource.swift", "quality_exchange.py"]
let testSwiftSources = [
    "PersonalDataTests.swift", "QualityExportFixture.swift",
    "AIControllerNativeTests.swift", "AICredentialTests.swift",
    "AIDiagnosticTestSupport.swift", "AIHeadlessPipelineSupport.swift", "AIHeadlessPipelineTests.swift",
    "AILiveConfiguration.swift", "AILiveTests.swift", "AIRuntimeTestSupport.swift",
    "AIRuntimeTests.swift", "AISuggestionTests.swift",
    "ControllerInitializationTests.swift", "ControllerTests.swift", "DeploymentTests.swift",
    "DictionaryActivationTests.swift", "DictionarySettingsUITests.swift",
    "BundleArtifactSmokeTests.swift", "DictionaryUpdateTests.swift", "DictionaryWorkerFixture.swift", "EngineTests.swift", "InputSourceLifecycleTests.swift",
    "MetadataTests.swift", "QualityCaptureTests.swift",
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
                          linkerSettings: [LinkerSetting] = portableRuntime) -> Target {
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
    ("ai-credential-tests", "AICredentialTests"),
    ("ai-headless-tests", "AIHeadlessTests"),
    ("ai-live-tests", "AILiveTests"),
    ("ai-native-tests", "AINativeTests"),
    ("ai-runtime-tests", "AIRuntimeTests"),
    ("ai-suggestion-tests", "AISuggestionTests"),
    ("controller-initialization-tests", "ControllerInitializationTests"),
    ("controller-tests", "ControllerTests"),
    ("deployment-tests", "DeploymentTests"),
    ("dictionary-activation-tests", "DictionaryActivationTests"),
    ("dictionary-update-tests", "DictionaryUpdateTests"),
    ("dictionary-worker-fixture", "DictionaryWorkerFixture"),
    ("engine-tests", "EngineTests"),
    ("input-source-lifecycle-tests", "InputSourceLifecycleTests"),
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
    ("voice-controller-tests", "VoiceControllerTests"),
    ("portable-abi-tests", "PortableABITests"),
]

let package = Package(
    name: "InkFlow",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "InkFlow", targets: ["InkFlowApp"]),
        .executable(name: "InkFlowDictionaryWorker", targets: ["InkFlowDictionaryWorker"]),
        .executable(name: "register-input-source", targets: ["RegisterInputSourceTool"]),
        .executable(name: "quality-build-metadata", targets: ["QualityBuildMetadataTool"]),
    ] + executableTestProducts.map { .executable(name: $0.0, targets: [$0.1]) },
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "InkFlowDictionaryTestSupport", dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowCoreTestSupport"], path: "Core/Tests/InkFlowDictionaryTestSupport", swiftSettings: strictSwiftSettings),
        .target(name: "InkFlowEngineTestSupport", dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowCoreTestSupport"], path: "Core/Tests/InkFlowEngineTestSupport", swiftSettings: strictSwiftSettings),
        .target(name: "InkFlowCoreTestSupport", dependencies: ["InkFlowDomain", "InkFlowRime"], path: "Core/Tests/InkFlowCoreTestSupport", swiftSettings: strictSwiftSettings),
        .target(name: "InkFlowRime", dependencies: ["InkFlowDomain", "InkFlowPortable"], path: "Core/Sources/InkFlowRime", swiftSettings: strictSwiftSettings, linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "InkFlowDictionary", path: "Core/Sources/InkFlowDictionary",
                publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I\(packageRoot)/build/dictionary/include"])],
                linkerSettings: [.unsafeFlags(["-L\(packageRoot)/build/dictionary/cargo/release"]),
                    .linkedLibrary("inkflow_dictionary"), .linkedLibrary("resolv"), .linkedLibrary("iconv")]),
        .target(name: "InkFlowDomain", dependencies: ["InkFlowDictionary"], path: "Core/Sources/InkFlowDomain",
                swiftSettings: strictSwiftSettings),
        .target(
            name: "InkFlowNative",
            path: "macOS/SwiftPM/InkFlowNative",
            publicHeadersPath: "include",
            cSettings: strictCSettings + [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("InputMethodKit")]
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
            dependencies: ["InkFlowDomain", "InkFlowRime", "InkFlowNative"],
            path: "macOS/Sources",
            swiftSettings: strictSwiftSettings,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("InputMethodKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("sqlite3"),
                .linkedLibrary("z"),
            ]
        ),
        .executableTarget(
            name: "InkFlowApp",
            dependencies: ["InkFlowCore", "InkFlowRime", .product(name: "Sparkle", package: "Sparkle")],
            path: "macOS/App",
            swiftSettings: strictSwiftSettings,
            linkerSettings: bundledRimeRuntime
        ),
        .executableTarget(
            name: "InkFlowDictionaryWorker",
            dependencies: ["InkFlowCore", "InkFlowRime"],
            path: "macOS/DictionaryWorker",
            swiftSettings: strictSwiftSettings,
            linkerSettings: bundledRimeRuntime
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
            dependencies: ["InkFlowRime"],
            path: "macOS/Tools",
            exclude: toolSources.filter { $0 != "QualityBuildMetadata.swift" },
            sources: ["QualityBuildMetadata.swift"],
            swiftSettings: strictSwiftSettings,
            linkerSettings: portableRuntime
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
        executableTestTarget("PersonalDataTests", sources: ["PersonalDataTests.swift"], dependencies: ["InkFlowCore", "InkFlowRime", "InkFlowDomain"]),
        executableTestTarget("AICredentialTests", sources: ["AICredentialTests.swift"]),
        executableTestTarget("AIHeadlessTests", sources: ["AIHeadlessPipelineTests.swift"],
            dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("AILiveTests", sources: ["AILiveTests.swift"],
            dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("AINativeTests", sources: ["AIControllerNativeTests.swift"],
            dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("AIRuntimeTests", sources: ["AIRuntimeTests.swift"],
            dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("AISuggestionTests", sources: ["AISuggestionTests.swift"],
            dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("ControllerInitializationTests", sources: ["ControllerInitializationTests.swift"]),
        executableTestTarget("ControllerTests", sources: ["ControllerTests.swift"]),
        executableTestTarget("DeploymentTests", sources: ["DeploymentTests.swift"]),
        executableTestTarget("DictionaryActivationTests", sources: ["DictionaryActivationTests.swift"], dependencies: standardTestDependencies + ["InkFlowDictionaryTestSupport"]),
        executableTestTarget("DictionaryUpdateTests", sources: ["DictionaryUpdateTests.swift"], dependencies: standardTestDependencies + ["InkFlowDictionaryTestSupport"]),
        executableTestTarget("DictionaryWorkerFixture", sources: ["DictionaryWorkerFixture.swift"]),
        executableTestTarget("EngineTests", sources: ["EngineTests.swift"], dependencies: standardTestDependencies + ["InkFlowEngineTestSupport"]),
        executableTestTarget("InputSourceLifecycleTests", sources: ["InputSourceLifecycleTests.swift"],
            dependencies: ["InkFlowInputSources"], linkerSettings: []),
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
        executableTestTarget("VoiceControllerTests", sources: ["VoiceControllerTests.swift"]),
        executableTestTarget("TerminationTests", sources: ["TerminationTests.swift"]),
        .target(name: "InkFlowPortable", path: "Core/Sources/InkFlowPortable",
                publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I\(portableRoot)/include"])],
                linkerSettings: portableLinkerSettings),
        .executableTarget(name: "PortableABITests", dependencies: ["InkFlowPortable", "InkFlowDictionary"],
                path: "Core/Tests/PortableABITests", swiftSettings: strictSwiftSettings,
                linkerSettings: portableRuntime),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
