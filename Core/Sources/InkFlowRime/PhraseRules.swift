import InkFlowDomain
import InkFlowPortable
import Foundation

package enum IFPhraseRules {
    package static func validated(id: UUID = UUID(), code: String, text: String) throws -> CustomPhrase {
        if code.contains("\0") { throw error("invalid-code") }
        if text.contains("\0") { throw error("control-character") }
        var normalizedCode: UnsafeMutablePointer<CChar>?
        var normalizedText: UnsafeMutablePointer<CChar>?
        guard ifr_phrase_normalize(code, text, &normalizedCode, &normalizedText) == ifrOK,
              let normalizedCode, let normalizedText else { throw failure() }
        defer {
            ifr_string_free(normalizedCode)
            ifr_string_free(normalizedText)
        }
        return CustomPhrase(id: id, code: String(cString: normalizedCode), text: String(cString: normalizedText))
    }

    package static func validate(_ phrases: [CustomPhrase]) throws {
        if phrases.contains(where: { $0.code.contains("\0") }) { throw error("invalid-code") }
        if phrases.contains(where: { $0.text.contains("\0") }) { throw error("control-character") }
        let status = withCStrings(phrases.flatMap { [$0.id.uuidString, $0.code, $0.text] }) { strings in
            let list = phrases.indices.map {
                IFRPhrase(id: strings[3 * $0], code: strings[3 * $0 + 1], text: strings[3 * $0 + 2])
            }
            return ifr_phrases_validate(list, list.count)
        }
        guard status == ifrOK else { throw failure() }
    }

    private static func failure() -> CustomPhraseError {
        error(ifrString(ifr_last_error()))
    }

    private static func error(_ code: String) -> CustomPhraseError {
        CustomPhraseError(configurationMessage(code))
    }
}
