import Foundation
@testable import InkFlowAppleEngine

private final class AppleEngineTestBundleAnchor: NSObject {}

enum AppleEngineTestEnvironment {
    static let runtime = Result<EngineRuntime, Error> {
        guard let schemaURL = Bundle(for: AppleEngineTestBundleAnchor.self).url(
            forResource: "Schema",
            withExtension: nil
        ) else {
            throw EngineError.runtimeUnavailable
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "InkFlowAppleTests-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
        return try EngineRuntime(configuration: EngineConfiguration(
            sharedDataURL: schemaURL,
            userDataURL: root.appendingPathComponent("User", isDirectory: true),
            prebuiltDataURL: schemaURL,
            stagingDataURL: root.appendingPathComponent("Staging", isDirectory: true),
            distributionCodeName: "inkflow-apple-tests",
            applicationName: "rime.inkflow.apple.tests"
        ))
    }

    static func makeSession() throws -> EngineSession {
        try runtime.get().makeSession(schemaID: "inkflow")
    }
}
