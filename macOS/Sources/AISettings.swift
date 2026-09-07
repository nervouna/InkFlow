import Combine
import Foundation
import LocalAuthentication
import Security

extension Notification.Name {
    static let smartSettingsDidChange = Notification.Name("IFSmartSettingsDidChange")
}

struct AISuggestionConfiguration: Equatable, Sendable {
    let baseURL: String
    let apiKey: String
    let model: String

    init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isComplete: Bool { !baseURL.isEmpty && !apiKey.isEmpty && !model.isEmpty }
}

enum AICredentialError: Error, LocalizedError {
    case unavailable
    var errorDescription: String? { "无法访问钥匙串，配置未保存。请解锁钥匙串后重试。" }
}

@MainActor
protocol AICredentialStore {
    func read() throws -> String
    func write(_ key: String) throws
}

@MainActor
final class MemoryAICredentialStore: AICredentialStore {
    private var key: String
    var failReads = false
    var failWrites = false
    init(key: String = "") { self.key = key }
    func read() throws -> String {
        if failReads { throw AICredentialError.unavailable }
        return key
    }
    func write(_ key: String) throws {
        if failWrites { throw AICredentialError.unavailable }
        self.key = key
    }
}

@MainActor
final class KeychainAICredentialStore: AICredentialStore {
    private let service: String
    init(service: String = "io.damao.inputmethod.inkflow.ai") { self.service = service }

    private var query: [String: Any] {
        // Input-method startup must never interrupt typing with a Keychain prompt.
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "api-key",
         kSecUseAuthenticationContext as String: context]
    }

    func read() throws -> String {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data,
              let key = String(data: data, encoding: .utf8) else { throw AICredentialError.unavailable }
        return key
    }

    func write(_ key: String) throws {
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AICredentialError.unavailable }
            return
        }
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw AICredentialError.unavailable }
        var addition = query
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else { throw AICredentialError.unavailable }
    }
}

@MainActor
final class IFSmartSettings: ObservableObject {
    private let defaults: UserDefaults
    private let credentials: any AICredentialStore
    @Published private(set) var configuration: AISuggestionConfiguration
    @Published private var enabled: Bool
    @Published private(set) var credentialError: String?

    init(defaults: UserDefaults, credentials: any AICredentialStore) {
        self.defaults = defaults
        self.credentials = credentials
        var key = ""
        do { key = try credentials.read() }
        catch { credentialError = "无法读取钥匙串中的 API Key。请解锁钥匙串后重新保存配置。" }
        let loaded = AISuggestionConfiguration(baseURL: defaults.string(forKey: "aiBaseURL") ?? "",
            apiKey: key, model: defaults.string(forKey: "aiModel") ?? "")
        configuration = loaded
        enabled = defaults.bool(forKey: "aiEnabled") && loaded.isComplete
    }

    var isAvailable: Bool { configuration.isComplete }
    var isEnabled: Bool {
        get { enabled && isAvailable }
        set {
            let value = newValue && isAvailable
            guard enabled != value else { return }
            enabled = value
            defaults.set(value, forKey: "aiEnabled")
            changed()
        }
    }

    func save(baseURL: String, apiKey: String, model: String) throws {
        let updated = AISuggestionConfiguration(baseURL: baseURL, apiKey: apiKey, model: model)
        // Keychain update is the only fallible step. Never publish partially saved fields.
        do { try credentials.write(updated.apiKey) }
        catch { throw AICredentialError.unavailable }
        defaults.set(updated.baseURL, forKey: "aiBaseURL")
        defaults.set(updated.model, forKey: "aiModel")
        configuration = updated
        credentialError = nil
        if !updated.isComplete {
            enabled = false
            defaults.set(false, forKey: "aiEnabled")
        }
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: .smartSettingsDidChange, object: self)
    }
}
