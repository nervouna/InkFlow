@preconcurrency import InputMethodKit
import ObjectiveC

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

/// The application owns this object until its event loop stops. IMKServer borrows
/// the last-created candidate panel, while the panel retains its server. A weak
/// association avoids a retain cycle and keeps exactly one extra panel alive.
@MainActor
final class NativeCandidateLifetime {
    private final class WeakOwner {
        weak var value: NativeCandidateLifetime?
        init(_ value: NativeCandidateLifetime) { self.value = value }
    }
    private static var associationKey: UInt8 = 0
    private var latestPanel: IMKCandidates?

    init(server: IMKServer) {
        precondition(Self.owner(for: server) == nil, "One candidate lifetime per server")
        objc_setAssociatedObject(server, &Self.associationKey, WeakOwner(self), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private static func owner(for server: IMKServer) -> NativeCandidateLifetime? {
        (objc_getAssociatedObject(server, &associationKey) as? WeakOwner)?.value
    }

    static func retainLatest(_ panel: IMKCandidates, server: IMKServer) {
        guard let owner = owner(for: server) else {
            preconditionFailure("Create the candidate lifetime before input controllers")
        }
        owner.latestPanel = panel
    }
}
