import Foundation

struct VoicePolishRule: Codable, Equatable, Identifiable, Sendable {
    static let maximumRuleCount = 100
    static let maximumBundleIdentifierUTF16 = 255
    static let maximumDisplayNameUTF16 = 200
    static let maximumPromptUTF16 = 4_000

    let bundleIdentifier: String
    let displayName: String
    let isEnabled: Bool
    let prompt: String

    var id: String { bundleIdentifier }

    static func validated(bundleIdentifier: String, displayName: String,
                          isEnabled: Bool, prompt: String) throws -> Self {
        guard bundleIdentifier.utf16.count <= maximumBundleIdentifierUTF16,
              validBundleIdentifier(bundleIdentifier) else {
            throw VoicePolishRuleError("应用标识符无效。")
        }
        let displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty, displayName.utf16.count <= maximumDisplayNameUTF16,
              displayName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw VoicePolishRuleError("应用名称无效。")
        }
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.utf16.count <= maximumPromptUTF16,
              prompt.unicodeScalars.allSatisfy({ scalar in
                  scalar == "\n" || !CharacterSet.controlCharacters.contains(scalar)
              }) else {
            throw VoicePolishRuleError("润色提示词不能为空、不能超过 4000 个字符，也不能包含制表符或其他控制字符。")
        }
        return Self(bundleIdentifier: bundleIdentifier, displayName: displayName,
                    isEnabled: isEnabled, prompt: prompt)
    }

    static func validate(_ rules: [Self]) throws {
        guard rules.count <= maximumRuleCount else {
            throw VoicePolishRuleError("最多只能保存 100 条应用规则。")
        }
        var bundleIdentifiers = Set<String>()
        for rule in rules {
            guard try validated(bundleIdentifier: rule.bundleIdentifier, displayName: rule.displayName,
                                isEnabled: rule.isEnabled, prompt: rule.prompt) == rule else {
                throw VoicePolishRuleError("语音润色规则数据格式无效。")
            }
            guard bundleIdentifiers.insert(rule.bundleIdentifier).inserted else {
                throw VoicePolishRuleError("该应用已存在语音润色规则。")
            }
        }
    }

    static func enabledRule(in rules: [Self], matching bundleIdentifier: String) -> Self? {
        rules.first { $0.bundleIdentifier == bundleIdentifier && $0.isEnabled }
    }

    private static func validBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.first != ".", value.last != "." else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        return value.unicodeScalars.allSatisfy(allowed.contains)
            && !value.contains("..")
    }
}

struct VoicePolishRuleError: LocalizedError, Sendable {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
