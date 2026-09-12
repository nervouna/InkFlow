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
    private let scheduleAfterClientLayout: (@escaping @MainActor () -> Void) -> Void
    private let panelFactory: () -> any ThunderPanelPresenting
    private var panel: (any ThunderPanelPresenting)?
    private var presentationGeneration = 0

    init(reduceMotion: @escaping () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }, scheduleAfterClientLayout: @escaping (@escaping @MainActor () -> Void) -> Void = { action in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated { action() }
        }
    }, panelFactory: @escaping () -> any ThunderPanelPresenting = { ThunderPanel() }) {
        self.reduceMotion = reduceMotion
        self.scheduleAfterClientLayout = scheduleAfterClientLayout
        self.panelFactory = panelFactory
    }

    func burst(_ burst: ThunderBurst, client: IMKTextInput?, characterIndex: Int) {
        guard !reduceMotion() else {
            hide()
            return
        }
        guard let client else { return }
        if burst == .commit {
            let generation = presentationGeneration
            scheduleAfterClientLayout { [weak self, client] in
                guard let self, self.presentationGeneration == generation else { return }
                self.present(burst, client: client, characterIndex: characterIndex)
            }
            return
        }
        present(burst, client: client, characterIndex: characterIndex)
    }

    private func present(_ burst: ThunderBurst, client: IMKTextInput?, characterIndex: Int) {
        guard let client,
              let caretRect = NativeInputStatusPresentation.caretRect(for: client,
                                                                      characterIndex: characterIndex) else { return }
        if panel == nil { panel = panelFactory() }
        panel?.burst(burst, at: caretRect)
    }

    func hide() {
        presentationGeneration += 1
        panel?.hide()
    }
}
