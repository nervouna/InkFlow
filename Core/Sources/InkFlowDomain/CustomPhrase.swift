import Foundation

package struct CustomPhrase: Codable, Equatable, Identifiable {
    package let id: UUID
    package let code: String
    package let text: String

    package init(id: UUID, code: String, text: String) {
        self.id = id
        self.code = code
        self.text = text
    }
}

package struct CustomPhraseError: LocalizedError {
    package let errorDescription: String?
    package init(_ message: String) { errorDescription = message }
}
