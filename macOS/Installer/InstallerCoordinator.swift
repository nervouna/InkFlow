import Foundation

enum IFInstallerAction: Equatable, Sendable {
    case installAndEnable, retryActivation, cancel
}

enum IFInstallerState: Equatable, Sendable {
    case idle, preparing, stoppingOldVersion, committing, activating
    case installedAwaitingApproval(String)
    case installedEnabled
    case cancelled
    case failed(installed: Bool, message: String)

    var busy: Bool {
        switch self {
        case .preparing, .stoppingOldVersion, .committing, .activating: true
        default: false
        }
    }
    var actions: [IFInstallerAction] {
        switch self {
        case .idle, .cancelled: [.installAndEnable]
        case .preparing: [.cancel]
        case .stoppingOldVersion, .committing, .activating: []
        case .installedAwaitingApproval, .installedEnabled: [.retryActivation]
        case .failed(let installed, _): installed ? [.retryActivation] : [.installAndEnable]
        }
    }
}

@MainActor final class IFInstallerCoordinator {
    private let files: any IFInstallerFileOperations
    private let sources: any IFInputSourceOperations
    private let lifecycle: any IFInstallerLifecycleOperations
    private let pause: @MainActor () async throws -> Void
    private(set) var state: IFInstallerState = .idle {
        didSet { stateChanged?(state) }
    }
    var stateChanged: (@MainActor (IFInstallerState) -> Void)?
    private var installed = false
    private var cancelled = false

    init(files: any IFInstallerFileOperations, sources: any IFInputSourceOperations,
         lifecycle: any IFInstallerLifecycleOperations,
         pause: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }) {
        self.files = files; self.sources = sources; self.lifecycle = lifecycle; self.pause = pause
    }
    static func production(candidate: IFUnpackedShippedCandidate) -> IFInstallerCoordinator {
        .init(files: IFInstallerFiles(candidate: candidate), sources: IFSystemInputSources(), lifecycle: IFSystemLifecycle())
    }
    func perform(_ action: IFInstallerAction) async {
        if action == .cancel {
            if state == .preparing { cancelled = true }
            return
        }
        guard !state.busy, state.actions.contains(action) else { return }
        cancelled = false
        do {
            if action == .installAndEnable {
                state = .preparing
                do {
                    let existing = try await files.prepare()
                    if cancelled || Task.isCancelled { throw IFInstallerError.cancelled }
                    state = .stoppingOldVersion
                    if existing { switchAwayIfSelected() }
                    try await lifecycle.terminateOld()
                    state = .committing
                    try await files.commit()
                    installed = true
                } catch {
                    let original = error
                    do { try await files.clean() }
                    catch { throw IFInstallerError.invalid("\(original); cleanup: \(error)") }
                    throw original
                }
                try await files.clean()
            }
            try await activate()
        } catch IFInstallerError.cancelled { state = .cancelled }
        catch { state = .failed(installed: installed, message: String(describing: error)) }
    }
    private func switchAwayIfSelected() {
        guard let roster = try? sources.snapshot(),
              [IFInputIdentity.bundleID, IFInputIdentity.modeID].contains(roster.selectedID),
              let fallback = roster.enabled.first(where: {
                  $0.bundleID != IFInputIdentity.bundleID && $0.enabled && $0.selectable && $0.ascii
              }) else { return }
        try? sources.select(fallback.id)
    }
    private func activate() async throws {
        state = .activating
        let ids = [IFInputIdentity.bundleID, IFInputIdentity.modeID]
        var roster = try sources.snapshot()
        if ids.contains(where: { roster.source($0) == nil }) {
            try sources.register(at: files.target)
            roster = try sources.snapshot()
        }
        for id in ids {
            if !roster.isEnabled(id) { try sources.enable(id) }
            for _ in 0..<8 {
                roster = try sources.snapshot()
                if roster.isEnabled(id) { break }
                try await pause()
            }
            guard roster.isEnabled(id) else {
                state = .installedAwaitingApproval("System has not confirmed enablement of \(id)")
                return
            }
        }
        try sources.select(IFInputIdentity.modeID)
        for _ in 0..<8 {
            roster = try sources.snapshot()
            if roster.selectedID == IFInputIdentity.modeID { state = .installedEnabled; return }
            try await pause()
        }
        state = .installedAwaitingApproval("System has not confirmed selection")
    }
}
