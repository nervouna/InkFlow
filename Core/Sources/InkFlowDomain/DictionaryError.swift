import Foundation

/// Shared by dictionary generation and the context ranker; compiled standalone by Core/Portable/ranking-reference.sh.
package struct IFDictionaryError: Error, LocalizedError, Sendable {
    package let code: String
    package let source: String?
    package let line: Int?
    package let detail: String
    package init(_ code: String, source: String? = nil, line: Int? = nil, _ detail: String) {
        self.code = code; self.source = source; self.line = line; self.detail = detail
    }
    package var errorDescription: String? {
        [code, source, line.map { "line \($0)" }, detail].compactMap { $0 }.joined(separator: ": ")
    }
}
