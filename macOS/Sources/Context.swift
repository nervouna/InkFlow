@preconcurrency import InputMethodKit
import Carbon
import InkFlowDomain

enum IFPrecedingText {
    static let limit = IFContextRanker.contextLimit

    @MainActor static func read(from client: IMKTextInput?, ownsMarkedText: Bool,
                                secureInput: Bool = IsSecureEventInputEnabled()) -> String {
        read(from: client, ownsMarkedText: ownsMarkedText, secureInput: { secureInput })
    }

    @MainActor static func read(from client: IMKTextInput?, ownsMarkedText: Bool,
                                secureInput: () -> Bool) -> String {
        guard !secureInput(), let client else { return "" }
        let selection = client.selectedRange()
        guard !secureInput(), valid(selection) else { return "" }
        let mark = client.markedRange()
        guard !secureInput() else { return "" }
        let anchor: Int
        if ownsMarkedText {
            guard valid(mark), mark.length > 0, selection.location >= mark.location,
                  NSMaxRange(selection) <= NSMaxRange(mark) else { return "" }
            anchor = mark.location
        } else {
            guard !valid(mark) || mark.length == 0 else { return "" }
            anchor = selection.location
        }
        guard anchor > 0 else { return "" }
        let request = NSRange(location: max(0, anchor - limit), length: min(anchor, limit))
        var actual = request
        guard !secureInput(), let text = client.string(from: request, actualRange: &actual), !secureInput(), valid(actual),
              actual.length == text.utf16.count,
              actual.location >= max(0, request.location - 1), actual.location < anchor,
              NSMaxRange(actual) >= anchor, NSMaxRange(actual) - anchor <= 1
        else { return "" }
        let units = text.utf16
        let end = units.index(units.startIndex, offsetBy: anchor - actual.location)
        guard end == units.endIndex || !(0xDC00...0xDFFF).contains(units[end]) else { return "" }
        return String(decoding: units[..<end], as: UTF16.self)
    }

    private static func valid(_ range: NSRange) -> Bool {
        range.location >= 0 && range.location != NSNotFound && range.length >= 0 &&
        range.length != NSNotFound && range.length <= Int.max - range.location
    }
}
