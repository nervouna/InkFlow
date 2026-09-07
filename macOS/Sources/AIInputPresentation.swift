@preconcurrency import InputMethodKit

/// The controller owns input and candidate state; this boundary only renders it.
/// Tests replace windows while retaining the normal per-event refresh lifecycle.
@MainActor
protocol AIInputPresentation: AnyObject {
    var candidatesVisible: Bool { get }
    var suggestionVisible: Bool { get }
    func refreshCandidates(_ candidates: [String], highlight: Int)
    func hideCandidates()
    func presentSuggestion(_ text: String) -> Bool
    func hideSuggestion()
}

@MainActor
final class NativeAIInputPresentation: AIInputPresentation {
    private weak var panel: IMKCandidates?
    private var suggestion: AISuggestionPanel?

    init(panel: IMKCandidates) { self.panel = panel }

    var candidatesVisible: Bool { panel?.isVisible() ?? false }
    var suggestionVisible: Bool { suggestion?.isVisible ?? false }

    func refreshCandidates(_ candidates: [String], highlight: Int) {
        guard let panel else { return }
        panel.update()
        guard !candidates.isEmpty else { panel.hide(); return }
        let index = min(max(0, highlight), candidates.count - 1)
        panel.selectCandidate(withIdentifier: panel.candidateStringIdentifier(candidates[index]))
        panel.show(kIMKLocateCandidatesBelowHint)
    }

    func hideCandidates() { panel?.hide() }
    func hideSuggestion() { suggestion?.hide() }

    func presentSuggestion(_ text: String) -> Bool {
        guard let panel else { AIDiagnostics.emit(.presentationFailed, reason: .missingPanel); return false }
        guard panel.isVisible() else { AIDiagnostics.emit(.presentationFailed, reason: .panelHidden); return false }
        guard let frame = InkFlowInputController.candidateScreenFrame(panel) else { return false }
        if suggestion == nil { suggestion = AISuggestionPanel() }
        guard let suggestion else { AIDiagnostics.emit(.presentationFailed, reason: .suggestionHidden); return false }
        suggestion.setSuggestion(text)
        suggestion.show(relativeTo: frame)
        if !suggestion.isVisible { AIDiagnostics.emit(.presentationFailed, reason: .suggestionHidden) }
        return suggestion.isVisible
    }
}
