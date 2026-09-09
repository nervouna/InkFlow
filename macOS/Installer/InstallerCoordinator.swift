import Foundation

/// Single-window handoff: call perform(), observe stateChanged, and render actions. No UI or launcher.
enum IFInstallerAction: Equatable, Sendable {
    case installAndEnable
    case resumeRecovery
    case retryActivation
    case repairMissingRegistration
    case cancel
}

enum IFInstallerState: Equatable, Sendable {
    case idle
    case preparing
    case stoppingOldVersion
    case committing
    case activating
    case installedAwaitingApproval(String)
    case installedRegistrationFailed(String)
    case installedMissingRegistration
    case installedEnabled(IFRuntimeObservation)
    case installedRuntimeFailed(reason: String, fallbackRestored: Bool)
    case installedRecoveryRequired(String)
    case cancelled
    case legacyNeedsReview(IFAppVersion)
    case failed(installed: Bool, message: String)

    var busy: Bool {
        switch self {
        case .preparing, .stoppingOldVersion, .committing, .activating: true
        default: false
        }
    }
    var actions: [IFInstallerAction] {
        switch self {
        case .idle, .cancelled, .legacyNeedsReview: [.installAndEnable]
        case .preparing: [.cancel]
        case .stoppingOldVersion, .committing, .activating: []
        case .installedMissingRegistration, .installedRegistrationFailed: [.repairMissingRegistration, .retryActivation]
        case .installedAwaitingApproval, .installedEnabled, .installedRuntimeFailed: [.retryActivation]
        case .installedRecoveryRequired: [.resumeRecovery]
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
    private var installed: IFVerifiedApp?
    private var registrationAttempted = false
    private var registrationFailed = false
    private var cancelled = false
    private var registerAfterRecovery = false

    init(files: any IFInstallerFileOperations, sources: any IFInputSourceOperations,
         lifecycle: any IFInstallerLifecycleOperations,
         pause: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }) {
        self.files = files; self.sources = sources; self.lifecycle = lifecycle; self.pause = pause
    }
    static func production(candidate: IFUnpackedShippedCandidate) -> IFInstallerCoordinator {
        .init(files: IFInstallerFiles(candidate: candidate), sources: IFSystemInputSources(), lifecycle: IFSystemLifecycle())
    }
    /// Close requests are deferred while busy; cancel only applies to preparation, before disruption.
    func perform(_ action: IFInstallerAction) async {
        if action == .cancel {
            if state == .preparing { cancelled = true }
            return
        }
        guard !state.busy, state.actions.contains(action) else { return }
        cancelled = false
        do {
            switch action {
            case .installAndEnable:
                state = .preparing
                let plan = try await files.prepare()
                do {
                    if cancelled || Task.isCancelled { throw IFInstallerError.cancelled }
                    // Reject duplicate/invalid registrations before stopping any old process.
                    let roster = try checkedRoster()
                    if plan.needsReplacement {
                        if let old = plan.installed {
                            try await lifecycle.inspectForReplacement(old, at: files.target)
                            if cancelled || Task.isCancelled { throw IFInstallerError.cancelled }
                            state = .stoppingOldVersion
                            try await selectFallback(roster)
                            try await lifecycle.terminateOld(old, at: files.target)
                        }
                        try await lifecycle.assertStopped(plan.installed, at: files.target)
                        state = .committing
                        registerAfterRecovery = plan.installed == nil
                        try await files.commit()
                    }
                    installed = plan.candidate
                    try await files.release(cancelPrepared: false)
                } catch IFInstallerError.installedRecoveryRequired(let message) {
                    installed = plan.candidate
                    try await files.release(cancelPrepared: false)
                    throw IFInstallerError.installedRecoveryRequired(message)
                } catch {
                    do { try await files.release(cancelPrepared: true) }
                    catch { throw IFInstallerError.recoveryRequired("Release/recovery needed: \(error)") }
                    throw error
                }
                try await activate(allowRegistration: plan.installed == nil)
            case .resumeRecovery:
                state = .committing
                do { installed = try await files.resumeRecovery() }
                catch {
                    state = .installedRecoveryRequired(String(describing: error)); return
                }
                try await activate(allowRegistration: registerAfterRecovery)
            case .retryActivation, .repairMissingRegistration:
                state = .activating
                installed = try await files.validateInstalled()
                try await activate(allowRegistration: action == .repairMissingRegistration)
            case .cancel: break
            }
        } catch IFInstallerError.cancelled { state = .cancelled }
        catch IFInstallerError.installedRecoveryRequired(let message) { state = .installedRecoveryRequired(message) }
        catch IFInstallerError.legacyEvidenceRequired(let version) { state = .legacyNeedsReview(version) }
        catch {
            state = .failed(installed: installed != nil, message: String(describing: error))
        }
    }
    private func checkedRoster() throws -> IFInputRoster {
        let roster = try sources.snapshot()
        let parent = try roster.unique(IFInputIdentity.bundleID)
        if let parent, parent.bundleID != IFInputIdentity.bundleID { throw IFInputError.invalidMode }
        _ = try roster.mode()
        for id in [IFInputIdentity.bundleID, IFInputIdentity.modeID] {
            guard roster.enabled.filter({ $0.id == id }).count <= 1 else { throw IFInputError.duplicate(id) }
        }
        return roster
    }
    private func fallback(in roster: IFInputRoster) throws -> IFInputSource {
        let candidates = roster.enabled.filter { entry in
            entry.ascii && entry.enabled && entry.selectable && entry.bundleID != IFInputIdentity.bundleID
                && roster.enabled.filter { $0.id == entry.id }.count == 1
        }
        guard let fallback = candidates.first(where: { $0.id == roster.selectedID }) ?? candidates.first else {
            throw IFInstallerError.invalid("Enable an ASCII keyboard input source before activating InkFlow")
        }
        return fallback
    }
    private func available(_ fallback: IFInputSource, in roster: IFInputRoster) -> Bool {
        let matches = roster.enabled.filter { $0.id == fallback.id }
        return matches.count == 1 && matches[0].bundleID == fallback.bundleID
            && matches[0].enabled && matches[0].ascii && matches[0].selectable
    }
    private func restoreFallback(_ fallback: IFInputSource) async throws {
        // Fresh snapshots, including identity and enabled-roster membership; stale refs are never reused.
        guard available(fallback, in: try sources.snapshot()) else {
            throw IFInstallerError.invalid("The retained ASCII fallback is no longer uniquely enabled")
        }
        try sources.select(fallback.id)
        for _ in 0..<8 {
            let current = try sources.snapshot()
            if current.selectedID == fallback.id && available(fallback, in: current) { return }
            try await pause()
        }
        throw IFInstallerError.invalid("System did not confirm ASCII fallback restoration; select a working keyboard in the input menu")
    }
    private func selectFallback(_ roster: IFInputRoster) async throws {
        try await restoreFallback(fallback(in: roster))
    }
    private func runtimeFailed(_ reason: String, fallback: IFInputSource) async {
        do {
            try await restoreFallback(fallback)
            state = .installedRuntimeFailed(reason: reason, fallbackRestored: true)
        } catch {
            state = .installedRuntimeFailed(reason: "\(reason). Fallback restoration failed: \(error)", fallbackRestored: false)
        }
    }
    private func activate(allowRegistration: Bool) async throws {
        state = .activating
        guard let installed else { throw IFInstallerError.invalid("No verified installed application") }
        var roster = try checkedRoster()
        if try roster.mode() == nil || roster.unique(IFInputIdentity.bundleID) == nil {
            if allowRegistration && (!registrationAttempted || registrationFailed) {
                // Set before the call: an API error may still have partially registered with LS/TIS.
                registrationAttempted = true
                do {
                    try sources.register(at: files.target)
                    registrationFailed = false
                } catch {
                    registrationFailed = true
                    state = .installedRegistrationFailed(String(describing: error))
                    return
                }
            }
            for _ in 0..<8 {
                roster = try checkedRoster()
                if try roster.mode() != nil && roster.unique(IFInputIdentity.bundleID) != nil { break }
                try await pause()
            }
            guard try roster.mode() != nil, try roster.unique(IFInputIdentity.bundleID) != nil else {
                state = .installedMissingRegistration; return
            }
        }
        // Re-enumerate and wait for the parent before enabling the child. Retry loops only read.
        for id in [IFInputIdentity.bundleID, IFInputIdentity.modeID] {
            roster = try checkedRoster()
            if try roster.unique(id)?.enabled != true || !roster.isEnabled(id) { try sources.enable(id) }
            var enabled = false
            for _ in 0..<8 {
                roster = try checkedRoster()
                if try roster.unique(id)?.enabled == true && roster.isEnabled(id) { enabled = true; break }
                try await pause()
            }
            guard enabled else {
                state = .installedAwaitingApproval("Installed; system has not confirmed enablement. Approve in System Settings, then retry activation.")
                return
            }
        }
        let retainedFallback = try fallback(in: try checkedRoster())
        do {
            try sources.select(IFInputIdentity.modeID)
            for _ in 0..<8 {
                roster = try checkedRoster()
                if roster.selectedID == IFInputIdentity.modeID && roster.isEnabled(IFInputIdentity.bundleID)
                    && roster.isEnabled(IFInputIdentity.modeID) {
                    var observation = try await lifecycle.observe(installed, at: files.target)
                    // Up to 10 seconds for cold bootstrap; only never-started processes are deferred.
                    var seenLive = false
                    for poll in 0...40 {
                        if observation == .waitingForSystemLaunch {
                            if seenLive { throw IFInstallerError.invalid("InkFlow exited during startup observation") }
                            break
                        }
                        seenLive = true
                        if observation == .ready || observation == .terminating || poll == 40 { break }
                        try await pause()
                        observation = try await lifecycle.observe(installed, at: files.target)
                    }

                    // Selection can legitimately defer process creation until a client needs the IME.
                    switch observation {
                    case .ready, .waitingForSystemLaunch:
                        state = .installedEnabled(observation)
                    case .initializing, .terminating, .unverifiedReceipt:
                        await runtimeFailed("Installed InkFlow is not usable after bounded startup observation: \(observation)", fallback: retainedFallback)
                    }
                    return
                }
                try await pause()
            }
            state = .installedAwaitingApproval("Installed and enabled; system has not confirmed selection. Retry activation after approval.")
        } catch {
            await runtimeFailed("Activation/runtime observation failed: \(error)", fallback: retainedFallback)
        }
    }
}
