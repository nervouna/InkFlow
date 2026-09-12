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
    private let panelFactory: () -> any ThunderPanelPresenting
    private var panel: (any ThunderPanelPresenting)?

    init(reduceMotion: @escaping () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }, panelFactory: @escaping () -> any ThunderPanelPresenting = { ThunderPanel() }) {
        self.reduceMotion = reduceMotion
        self.panelFactory = panelFactory
    }

    func burst(_ burst: ThunderBurst, client: IMKTextInput?, characterIndex: Int) {
        guard !reduceMotion() else {
            hide()
            return
        }
        guard let client,
              let caretRect = NativeInputStatusPresentation.caretRect(for: client,
                                                                      characterIndex: characterIndex) else {
            return
        }
        if panel == nil { panel = panelFactory() }
        panel?.burst(burst, at: caretRect)
    }

    func hide() { panel?.hide() }
}
