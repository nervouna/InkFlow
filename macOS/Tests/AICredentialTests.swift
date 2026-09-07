import Foundation

@main
struct AICredentialTests {
    @MainActor static func main() {
        // This adapter check owns a random service and synthetic keys; never access the real service.
        let store = KeychainAICredentialStore(service: "io.damao.inkflow.ai-test.\(UUID().uuidString)")
        do {
            guard try store.read().isEmpty else { throw AICredentialError.unavailable }
            try store.write("synthetic-first-key")
            defer { try? store.write("") }
            guard try store.read() == "synthetic-first-key" else { throw AICredentialError.unavailable }
            try store.write("synthetic-replacement-key")
            guard try store.read() == "synthetic-replacement-key" else { throw AICredentialError.unavailable }
            try store.write("")
            guard try store.read().isEmpty else { throw AICredentialError.unavailable }
            print("PASS AI Keychain adapter: isolated service create/read/replace/delete")
        } catch {
            print("FAIL AI Keychain adapter unavailable; no production credentials accessed")
            exit(1)
        }
    }
}
