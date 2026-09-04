import Foundation
import InkFlowEngine

public struct EngineCandidate: Equatable, Sendable {
    public let text: String
    public let comment: String?

    public init(text: String, comment: String?) {
        self.text = text
        self.comment = comment
    }
}

public struct EngineUpdate: Equatable, Sendable {
    public let handled: Bool
    public let commitText: String?
    public let preedit: String
    public let cursorUTF16Offset: Int
    public let selectionUTF16Range: NSRange
    public let candidates: [EngineCandidate]
    public let highlightedCandidateIndex: Int?
    public let hasPreviousPage: Bool
    public let hasNextPage: Bool

    public init(
        handled: Bool,
        commitText: String?,
        preedit: String,
        cursorUTF16Offset: Int,
        selectionUTF16Range: NSRange,
        candidates: [EngineCandidate],
        highlightedCandidateIndex: Int?,
        hasPreviousPage: Bool,
        hasNextPage: Bool
    ) {
        self.handled = handled
        self.commitText = commitText
        self.preedit = preedit
        self.cursorUTF16Offset = cursorUTF16Offset
        self.selectionUTF16Range = selectionUTF16Range
        self.candidates = candidates
        self.highlightedCandidateIndex = highlightedCandidateIndex
        self.hasPreviousPage = hasPreviousPage
        self.hasNextPage = hasNextPage
    }
}

public struct EngineKeyEvent: Equatable, Sendable {
    public let key: UInt32
    public let modifiers: UInt32

    public init(key: UInt32, modifiers: UInt32 = 0) {
        self.key = key
        self.modifiers = modifiers
    }
}

public enum EngineKey {
    public static let space: UInt32 = 0x20
    public static let backspace = UInt32(INKFLOW_KEY_BACKSPACE)
    public static let deleteForward = UInt32(INKFLOW_KEY_DELETE_FORWARD)
    public static let `return` = UInt32(INKFLOW_KEY_RETURN)
    public static let escape = UInt32(INKFLOW_KEY_ESCAPE)
    public static let tab = UInt32(INKFLOW_KEY_TAB)
    public static let left = UInt32(INKFLOW_KEY_LEFT)
    public static let right = UInt32(INKFLOW_KEY_RIGHT)
    public static let up = UInt32(INKFLOW_KEY_UP)
    public static let down = UInt32(INKFLOW_KEY_DOWN)
    public static let pageUp = UInt32(INKFLOW_KEY_PAGE_UP)
    public static let pageDown = UInt32(INKFLOW_KEY_PAGE_DOWN)
    public static let home = UInt32(INKFLOW_KEY_HOME)
    public static let end = UInt32(INKFLOW_KEY_END)
}

public enum EngineModifier {
    public static let shift = UInt32(INKFLOW_MODIFIER_SHIFT)
    public static let capsLock = UInt32(INKFLOW_MODIFIER_CAPS_LOCK)
    public static let control = UInt32(INKFLOW_MODIFIER_CONTROL)
    public static let alt = UInt32(INKFLOW_MODIFIER_ALT)
    public static let command = UInt32(INKFLOW_MODIFIER_SUPER)
}
