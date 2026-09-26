import Foundation

package struct CustomPhrase: Codable, Equatable, Identifiable {
    package let id: UUID
    package let code: String
    package let text: String

    package static func validated(id: UUID = UUID(), code: String, text: String) throws -> Self {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !code.isEmpty, code.utf8.allSatisfy({ (97...122).contains($0) }) else {
            throw CustomPhraseError("输入码只能包含英文字母 a–z。")
        }
        guard text.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else {
            throw CustomPhraseError("短语不能包含换行、制表符或其他控制字符。")
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CustomPhraseError("请输入短语内容。") }
        return Self(id: id, code: code, text: text)
    }

    package static func validate(_ phrases: [Self]) throws {
        var ids = Set<UUID>()
        var pairs = Set<String>()
        for phrase in phrases {
            guard try validated(id: phrase.id, code: phrase.code, text: phrase.text) == phrase,
                  ids.insert(phrase.id).inserted else {
                throw CustomPhraseError("自定义短语数据格式无效。")
            }
            guard pairs.insert(phrase.code + "\t" + phrase.text).inserted else {
                throw CustomPhraseError("该输入码和短语已存在。")
            }
        }
    }
    package init(id: UUID,
        code: String,
        text: String) {
        self.id = id
        self.code = code
        self.text = text
    }

}

package struct CustomPhraseError: LocalizedError {
    package let errorDescription: String?
    package init(_ message: String) { errorDescription = message }
}
