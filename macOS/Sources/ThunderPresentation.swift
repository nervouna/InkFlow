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
    private let commitCaretRect: (IMKTextInput) -> NSRect?
    private let panelFactory: () -> any ThunderPanelPresenting
    private var panel: (any ThunderPanelPresenting)?
    private var presentationGeneration = 0

    init(reduceMotion: @escaping () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }, scheduleAfterClientLayout: @escaping (@escaping @MainActor () -> Void) -> Void = { action in
        RunLoop.main.perform { MainActor.assumeIsolated { action() } }
    }, commitCaretRect: @escaping (IMKTextInput) -> NSRect? = {
        NativeThunderPresentation.documentSelectionRect(for: $0)
    }, panelFactory: @escaping () -> any ThunderPanelPresenting = { ThunderPanel() }) {
        self.reduceMotion = reduceMotion
        self.scheduleAfterClientLayout = scheduleAfterClientLayout
        self.commitCaretRect = commitCaretRect
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
            scheduleAfterClientLayout { [weak self, weak client] in
                guard let self, self.presentationGeneration == generation else { return }
                self.present(burst, client: client, characterIndex: characterIndex)
            }
            return
        }
        present(burst, client: client, characterIndex: characterIndex)
    }

    private func present(_ burst: ThunderBurst, client: IMKTextInput?, characterIndex: Int) {
        guard let client else { return }
        let caretRect = burst == .commit
            ? commitCaretRect(client) ?? NativeInputStatusPresentation.caretRect(for: client, characterIndex: 0)
            : NativeInputStatusPresentation.caretRect(for: client, characterIndex: characterIndex)
        guard let caretRect else { return }
        if panel == nil { panel = panelFactory() }
        panel?.burst(burst, at: caretRect)
    }

    private static func documentSelectionRect(for client: IMKTextInput) -> NSRect? {
        let selection = client.selectedRange()
        guard selection.location != NSNotFound, selection.length == 0 else { return nil }
        let rect = client.firstRect(forCharacterRange: selection, actualRange: nil)
        guard [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite),
              rect.width >= 0, rect.height > 0 else { return nil }
        return rect
    }

    func hide() {
        presentationGeneration += 1
        panel?.hide()
    }
}
