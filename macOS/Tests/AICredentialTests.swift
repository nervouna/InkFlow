import Foundation
#if SWIFT_PACKAGE
@testable import InkFlowCore
#endif

@main
struct AICredentialTests {
    @MainActor static func main() {
        // This adapter check owns a random service and synthetic keys; never access the real service.
        let suite = "inkflow.ai-keychain-test.\(UUID().uuidString)"
        let store = KeychainAICredentialStore(service: "io.damao.inkflow.ai-test.\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        do {
            guard try store.read().isEmpty else { throw AICredentialError.unavailable }
            defaults.set(true, forKey: "aiEnabled")
            defaults.set("https://synthetic.invalid/v1", forKey: "aiBaseURL")
            defaults.set("synthetic-model", forKey: "aiModel")
            let missing = IFSmartSettings(defaults: defaults, credentials: store)
            guard !missing.isAvailable && !missing.isEnabled else { throw AICredentialError.unavailable }
            try store.write("synthetic-first-key")
            defer { try? store.write("") }
            guard try store.read() == "synthetic-first-key" else { throw AICredentialError.unavailable }
            let started = IFSmartSettings(defaults: defaults, credentials: store)
            guard started.isAvailable && started.isEnabled && started.configuration.apiKey == "synthetic-first-key"
            else { throw AICredentialError.unavailable }
            try store.write("synthetic-replacement-key")
            guard try store.read() == "synthetic-replacement-key" else { throw AICredentialError.unavailable }
            try store.write("")
            guard try store.read().isEmpty else { throw AICredentialError.unavailable }
            print("PASS AI Keychain startup: isolated service, no production credentials, fail-closed enablement, create/read/replace/delete")
        } catch {
            print("FAIL AI Keychain startup unavailable; isolated service only, no production credentials accessed")
            exit(1)
        }
    }
}
