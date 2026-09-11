@preconcurrency import InputMethodKit

@MainActor
protocol AISuggestionPresentation: AnyObject {
    var suggestionVisible: Bool { get }
    func presentSuggestion(_ text: String) -> Bool
    func hideSuggestion()
}

/// Test endpoints may implement both isolated presentation boundaries.
@MainActor
protocol AIInputPresentation: CandidatePresentation, AISuggestionPresentation {}

@MainActor
final class NativeAIInputPresentation: AISuggestionPresentation {
    private weak var panel: IMKCandidates?
    private var suggestion: AISuggestionPanel?

    init(panel: IMKCandidates) { self.panel = panel }

    var suggestionVisible: Bool { suggestion?.isVisible ?? false }
    func hideSuggestion() { suggestion?.hide() }

    func presentSuggestion(_ text: String) -> Bool {
        guard let panel else { AIDiagnostics.emit(.presentationFailed, reason: .missingPanel); return false }
        guard panel.isVisible() else { AIDiagnostics.emit(.presentationFailed, reason: .panelHidden); return false }
        guard let frame = InkFlowInputController.candidateScreenFrame(panel) else { return false }
        if suggestion == nil { suggestion = AISuggestionPanel() }
        guard let suggestion else { AIDiagnostics.emit(.presentationFailed, reason: .suggestionHidden); return false }
        let font = panel.attributes()?[NSAttributedString.Key.font] as? NSFont ?? .systemFont(ofSize: 14)
        suggestion.setSuggestion(text, font: font)
        suggestion.show(relativeTo: frame)
        if !suggestion.isVisible { AIDiagnostics.emit(.presentationFailed, reason: .suggestionHidden) }
        return suggestion.isVisible
    }
}
