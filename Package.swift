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
let testsRoot = "macOS/Tests"
let standardTestDependencies: [Target.Dependency] = [
    "InkFlowCore", "InkFlowTestSupport", "InkFlowNativeTestSupport",
]
func executableTestTarget(_ name: String,
                          dependencies: [Target.Dependency]? = nil,
                          linkerSettings: [LinkerSetting] = portableRuntime) -> Target {
    .executableTarget(
        name: name,
        dependencies: dependencies ?? standardTestDependencies,
        path: "\(testsRoot)/\(name)",
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
            path: "macOS/Tools/RegisterInputSource",
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "QualityBuildMetadataTool",
            dependencies: ["InkFlowRime"],
            path: "macOS/Tools/QualityBuildMetadata",
            swiftSettings: strictSwiftSettings,
            linkerSettings: portableRuntime
        ),
        .target(
            name: "InkFlowNativeTestSupport",
            path: "macOS/Tests/InkFlowNativeTestSupport",
            publicHeadersPath: "include",
            cSettings: strictCSettings + [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("InputMethodKit")]
        ),
        .target(
            name: "InkFlowTestSupport",
            dependencies: ["InkFlowCore", "InkFlowCoreTestSupport"],
            path: "macOS/Tests/InkFlowTestSupport",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "InkFlowAITestSupport",
            dependencies: ["InkFlowCore", "InkFlowTestSupport"],
            path: "macOS/Tests/InkFlowAITestSupport",
            swiftSettings: strictSwiftSettings,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        executableTestTarget("PersonalDataTests", dependencies: ["InkFlowCore", "InkFlowRime", "InkFlowDomain"]),
        executableTestTarget("AICredentialTests"),
        executableTestTarget("AIHeadlessTests", dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("AILiveTests", dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("AINativeTests", dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("AIRuntimeTests", dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("AISuggestionTests", dependencies: standardTestDependencies + ["InkFlowAITestSupport"]),
        executableTestTarget("ControllerInitializationTests"),
        executableTestTarget("ControllerTests"),
        executableTestTarget("DeploymentTests"),
        executableTestTarget("DictionaryActivationTests",
            dependencies: standardTestDependencies + ["InkFlowDictionaryTestSupport"]),
        executableTestTarget("DictionaryUpdateTests",
            dependencies: standardTestDependencies + ["InkFlowDictionaryTestSupport"]),
        executableTestTarget("DictionaryWorkerFixture"),
        executableTestTarget("EngineTests", dependencies: standardTestDependencies + ["InkFlowEngineTestSupport"]),
        executableTestTarget("InputSourceLifecycleTests", dependencies: ["InkFlowInputSources"], linkerSettings: []),
        executableTestTarget("MetadataTests"),
        executableTestTarget("QualityCaptureTests"),
        executableTestTarget("QualityIdentityTests"),
        executableTestTarget("QualityStoreTests"),
        executableTestTarget("QualityTimingTests"),
        executableTestTarget("ServingStartupTests"),
        executableTestTarget("SettingsTests"),
        executableTestTarget("SettingsUITests"),
        executableTestTarget("StartupDiagnosticsTests"),
        executableTestTarget("LocalDiagnosticsTests"),
        executableTestTarget("DiagnosticArchiveTests"),
        executableTestTarget("AppleVoiceRecognizerTests"),
        executableTestTarget("BundleArtifactSmokeTests", dependencies: ["InkFlowDomain", "InkFlowRime"]),
        executableTestTarget("VoiceSessionTests"),
        executableTestTarget("VoiceControllerTests"),
        executableTestTarget("TerminationTests"),
        .target(name: "InkFlowPortable", path: "Core/Sources/InkFlowPortable",
                publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I\(portableRoot)/include"])],
                linkerSettings: portableLinkerSettings),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
