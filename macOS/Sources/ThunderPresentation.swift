@preconcurrency import InputMethodKit

enum ThunderBurst: Equatable {
    case preedit
    case commit
}

@MainActor
protocol ThunderPresenting: AnyObject {
    func burst(_ burst: ThunderBurst, client: IMKTextInput?, characterIndex: Int)
    func hide()
}

/// Keeps decorative feedback downstream of text delivery and suppresses motion
/// when the system accessibility preference requests it.
@MainActor
final class NativeThunderPresentation: ThunderPresenting {
    private let reduceMotion: () -> Bool
    private var panel: ThunderPanel?

    init(reduceMotion: @escaping () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }) {
        self.reduceMotion = reduceMotion
    }

    func burst(_ burst: ThunderBurst, client: IMKTextInput?, characterIndex: Int) {
        guard !reduceMotion(), let client,
              let caretRect = NativeInputStatusPresentation.caretRect(for: client,
                                                                      characterIndex: characterIndex) else {
            hide()
            return
        }
        if panel == nil { panel = ThunderPanel() }
        panel?.burst(burst, at: caretRect)
    }

    func hide() { panel?.hide() }
}
