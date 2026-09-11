@preconcurrency import InputMethodKit

enum InputStatus: Equatable {
    case chinese
    case english
    case simplified
    case traditional
    case chinesePunctuation
    case englishPunctuation

    var title: String {
        switch self {
        case .chinese: "中文"
        case .english: "英文"
        case .simplified: "简体"
        case .traditional: "繁体"
        case .chinesePunctuation: "中文标点"
        case .englishPunctuation: "英文标点"
        }
    }
}

@MainActor
protocol InputStatusPresenting: AnyObject {
    func present(_ status: InputStatus, client: IMKTextInput?, characterIndex: Int)
    func hide()
}

/// Resolves the insertion caret through the public InputMethodKit client API and
/// delegates only passive window presentation to the panel.
@MainActor
final class NativeInputStatusPresentation: InputStatusPresenting {
    private var panel: InputStatusPanel?

    func present(_ status: InputStatus, client: IMKTextInput?, characterIndex: Int) {
        guard let client else {
            panel?.hide()
            return
        }
        guard let caretRect = Self.caretRect(for: client, characterIndex: characterIndex) else {
            panel?.hide()
            return
        }
        if panel == nil { panel = InputStatusPanel() }
        panel?.show(status, above: caretRect)
    }

    func hide() { panel?.hide() }

    static func caretRect(for client: IMKTextInput, characterIndex: Int) -> NSRect? {
        guard characterIndex >= 0 else { return nil }
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: characterIndex, lineHeightRectangle: &rect)
        guard [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite),
              rect.width >= 0, rect.height > 0 else { return nil }
        return rect
    }
}
