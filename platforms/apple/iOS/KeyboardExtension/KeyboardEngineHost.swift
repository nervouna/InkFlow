import Foundation
import InkFlowAppleEngine

final class KeyboardEngineHost: @unchecked Sendable {
    static let shared = KeyboardEngineHost()

    private let runtimeResult: Result<EngineRuntime, Error>

    private init() {
        runtimeResult = Result {
            guard let resourceURL = Bundle.main.resourceURL else {
                throw EngineError.runtimeUnavailable
            }
            let schemaURL = resourceURL.appendingPathComponent(
                "Schema",
                isDirectory: true
            )
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("InkFlow/Keyboard", isDirectory: true)
            let cache = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("InkFlow/Keyboard", isDirectory: true)
            return try EngineRuntime(configuration: EngineConfiguration(
                sharedDataURL: schemaURL,
                userDataURL: support.appendingPathComponent("User", isDirectory: true),
                prebuiltDataURL: schemaURL,
                stagingDataURL: cache.appendingPathComponent("Staging", isDirectory: true),
                distributionCodeName: "inkflow-ios",
                applicationName: "rime.inkflow.ios.keyboard"
            ))
        }
    }

    func makeSession() throws -> EngineSession {
        try runtimeResult.get().makeSession(schemaID: "inkflow")
    }
}
