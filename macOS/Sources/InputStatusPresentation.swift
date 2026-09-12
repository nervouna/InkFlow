@preconcurrency import InputMethodKit

enum InputStatus: Equatable {
    case chinese
    case english
    case simplified
    case traditional
    case chinesePunctuation
    case englishPunctuation
    case voiceRecordingHold, voiceRecordingToggle, voiceTail, voiceCorrecting, voiceFallback, voiceFailed
    case voiceNotReady, voiceLexiconWaiting, voiceTargetUnavailable, voiceSelectionUnsupported

    var persistent: Bool { [.voiceRecordingHold, .voiceRecordingToggle, .voiceTail, .voiceCorrecting].contains(self) }

    var title: String {
        switch self {
        case .chinese: "中文"
        case .english: "英文"
        case .simplified: "简体"
        case .traditional: "繁体"
        case .chinesePunctuation: "中文标点"
        case .englishPunctuation: "英文标点"
        case .voiceRecordingHold: "正在听写 · 松开右 Shift 结束 / Esc 取消"
        case .voiceRecordingToggle: "正在听写 · 双击右 Shift 结束 / Esc 取消"
        case .voiceTail: "正在完成识别 · Esc 取消"
        case .voiceCorrecting: "正在润色 · Esc 取消"
        case .voiceFallback: "润色未完成，已使用原始识别"
        case .voiceFailed: "语音未完成，已取消"
        case .voiceNotReady: "请在设置的「语音」页准备识别"
        case .voiceLexiconWaiting: "词库正在准备，请稍后重试"
        case .voiceTargetUnavailable: "请先将光标放在可输入的位置"
        case .voiceSelectionUnsupported: "请取消文字选择后再开始语音"
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
