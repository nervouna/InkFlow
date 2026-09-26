import Foundation

/// Request identity deliberately excludes candidate paging, highlighting and display preedit.
package struct AIInputIdentity: Equatable, Sendable {
    package init(rawInput: String, caret: Int, selectedPrefix: String) {
        self.rawInput = rawInput; self.caret = caret; self.selectedPrefix = selectedPrefix
    }
    package let rawInput: String
    package let caret: Int
    package let selectedPrefix: String
}
