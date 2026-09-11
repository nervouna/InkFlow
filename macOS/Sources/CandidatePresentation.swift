@preconcurrency import InputMethodKit

/// Audited binding from offline engine candidates to the native IMK panel.
@MainActor
protocol CandidatePresentation: AnyObject {
    var candidatesVisible: Bool { get }
    func refreshCandidates(_ candidates: [String], highlight: Int)
    func hideCandidates()
}

@MainActor
final class NativeCandidatePresentation: CandidatePresentation {
    private weak var panel: IMKCandidates?

    init(panel: IMKCandidates) { self.panel = panel }

    var candidatesVisible: Bool { panel?.isVisible() ?? false }

    func refreshCandidates(_ candidates: [String], highlight: Int) {
        guard let panel else { return }
        panel.update()
        guard !candidates.isEmpty else { panel.hide(); return }
        let index = min(max(0, highlight), candidates.count - 1)
        panel.selectCandidate(withIdentifier: panel.candidateStringIdentifier(candidates[index]))
        panel.show(kIMKLocateCandidatesBelowHint)
    }

    func hideCandidates() { panel?.hide() }
}
