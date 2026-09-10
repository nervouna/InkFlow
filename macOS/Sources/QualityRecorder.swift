import Foundation

/// Only outer engine operations enter the recorder, including nested digit/select callbacks.
enum QualityAction {
    case key(Int32, Int32, Bool = false), select(Int, QualityTrigger, Bool), highlight, flush(QualityTrigger), toggle(Bool), clear

    var keypress: Bool {
        switch self { case .key, .toggle: true; default: false }
    }
    func requestsPage(with inputOptions: [String: Bool]?) -> Bool {
        guard case .key(let key, _, _) = self else { return false }
        switch key {
        case 0xff55, 0xff56: return true
        case 45, 61: return inputOptions?["minusEqualPaging"] ?? true
        case 91, 93: return inputOptions?["bracketPaging"] ?? true
        default: return false
        }
    }
    var candidateMove: Bool {
        switch self {
        case .highlight: true
        case .key(let key, _, _): key == 0xff52 || key == 0xff54
        default: false
        }
    }
    var edit: Bool {
        if case .key(let key, _, _) = self { return [0xff08, 0xffff, 0xff51, 0xff53, 0xff50, 0xff57].contains(key) }
        return false
    }
    var cancellation: Bool {
        switch self { case .clear, .key(0xff1b, _, _): true; default: false }
    }
}

/// Capture is synchronous bounded memory. This class never encodes JSON, reads a file or waits for SQL.
@MainActor
final class QualityRecorder {
    private let store: QualityStore
    private let clock: QualityClock
    private var timing: QualityTiming?
    private var monotonicStart: TimeInterval = 0
    private var lastKeyOffset: TimeInterval?
    private var keySequence = 0
    private var visible = false
    private var visibilityObserved = false
    private var visibleSince: TimeInterval?
    private var visibleAccumulated: TimeInterval = 0
    private var phaseVisibleSince: TimeInterval?
    private var phaseVisibleAccumulated: TimeInterval = 0
    private var timingEnabled = true
    private var timingSuppressed = false
    private var envelope: QualityEnvelope?
    private var observedComposition = false
    private var latest: QualityPageSnapshot?
    private var firstPage: QualityPageSnapshot?
    private var pages: [QualityPageSnapshot] = []
    private var cacheHistoryTruncated = false
    private var cacheDroppedPages = 0
    private var revision: QualityConfigRevision?
    private var generation = 0
    private var sinceDecision = QualityOperations()
    private var pendingPrefixes: [Int: String] = [:]
    private var inProgress: (action: QualityAction, before: QualityPageSnapshot, decision: Int?, entered: TimeInterval)?
    private var expectedCommit: String?
    private var commitKind: QualityCommitKind = .unknown
    private var allowPunctuationSuffix = false
    private var suppressed = false
    private var appBundleID: String?
    private var clientID: String?
    private weak var associatedClient: AnyObject?
    private var hadClient = false

    init(store: QualityStore, clock: QualityClock = QualityClock()) { self.store = store; self.clock = clock }

    var activeCompositionID: String? { suppressed ? nil : envelope?.composition.id }
    var timingSnapshot: QualityTiming? { snapshotTiming(at: offsetNow) }
    var lastEditMonotonicTime: TimeInterval? { timing?.lastEditOffset.map { monotonicStart + $0 } }
    private var offsetNow: TimeInterval { max(0, clock.monotonic() - monotonicStart) }

    func setTimingCaptureEnabled(_ enabled: Bool) {
        timingEnabled = enabled
        if !enabled {
            timing = nil
            timingSuppressed = envelope != nil
            envelope?.composition.operations.timing = nil
            if let envelope { for index in envelope.decisions.indices { self.envelope?.decisions[index].operations.timing = nil } }
        }
    }

    func observeCandidateVisibility(_ isVisible: Bool, at monotonicTime: TimeInterval? = nil) {
        guard timing != nil, timing?.endedOffset == nil else { return }
        let now = monotonicTime.map { max(0, $0 - monotonicStart) } ?? offsetNow
        if visible, let since = visibleSince { visibleAccumulated += max(0, now - since) }
        if visible, let since = phaseVisibleSince { phaseVisibleAccumulated += max(0, now - since) }
        visibilityObserved = true
        visible = isVisible
        visibleSince = isVisible ? now : nil
        phaseVisibleSince = isVisible ? now : nil
        timing?.visibilityObservationInterval = QualityLimits.visibilityObservationInterval
    }

    /// Physical keys intercepted by the controller, including held Tabs, never enter Rime.
    func recordExternalKey(_ kind: QualityKeyKind, isRepeat: Bool, at monotonicTime: TimeInterval? = nil) {
        guard envelope != nil, !suppressed else { return }
        envelope?.composition.operations.keypresses += 1
        sinceDecision.keypresses += 1
        recordKey(kind, isRepeat: isRepeat, at: monotonicTime.map { max(0, $0 - monotonicStart) } ?? offsetNow)
        enforceBudget()
    }

    /// AI insertion has its own content/usage record. Keep this ordinary record text-free
    /// for that insertion and terminate without inventing a regular candidate decision.
    func finishExternalSelection(reason: String, at monotonicTime: TimeInterval? = nil) {
        guard envelope != nil else { return }
        timing?.endedOffset = monotonicTime.map { max(0, $0 - monotonicStart) } ?? offsetNow
        finish(.committed, reason: reason)
    }

    func associateClient(_ client: AnyObject?, id: String?, app: String?) {
        if let client, hadClient, associatedClient !== client {
            finish(.interrupted, reason: "client_changed")
            clientID = nil
            appBundleID = nil
        }
        if let client { associatedClient = client; hadClient = true }
        if let id { clientID = id }
        if let app { appBundleID = app }
    }

    func willMutate(_ snapshot: QualityPageSnapshot, revision: QualityConfigRevision, action: QualityAction,
                    at monotonicTime: TimeInterval? = nil) {
        if suppressed, snapshot.rawInput.isEmpty { reset() }
        guard !suppressed else { return }
        if snapshot.rawInput.isEmpty && snapshot.candidates.isEmpty {
            switch action {
            case .flush, .clear, .highlight:
                // An idle IMK finish callback can reenter during insertText, before its original
                // decision is linked. Preserve that pending drain instead of replacing its origin.
                return
            default: break
            }
        }
        self.revision = revision
        ensureComposition(at: monotonicTime)
        let entered = monotonicTime.map { max(0, $0 - monotonicStart) } ?? offsetNow
        observe(snapshot)
        guard envelope != nil, let before = latest else { return }
        if action.keypress { envelope?.composition.operations.keypresses += 1; sinceDecision.keypresses += 1 }
        if case .key(_, _, let repeated) = action {
            recordKey(keyKind(action, snapshot: before), isRepeat: repeated, at: entered)
        } else if case .toggle(let repeated) = action { recordKey(.modeToggle, isRepeat: repeated, at: entered) }
        if action.requestsPage(with: before.configuration.inputOptions) && !before.candidates.isEmpty {
            envelope?.composition.operations.pageRequests += 1; sinceDecision.pageRequests += 1
        }
        commitKind = .unknown
        switch action {
        case .key(0xff0d, _, _): commitKind = .rawReturn
        case .flush: commitKind = .forcedFlush
        default: break
        }
        let selection = selection(for: action, snapshot: before)
        var index: Int?
        if let selection {
            var decision = QualityDecision(sequence: envelope!.decisions.count, trigger: selection.trigger,
                outcome: .tentative, selectedDisplayIndex: selection.ambiguous ? nil : selection.index,
                selectedText: selection.text, textKind: selection.text.map(QualityTextKind.classify) ?? .unknown,
                snapshot: before, firstPage: firstPage, visitedPages: pages)
            decision.pageHistoryTruncated = cacheHistoryTruncated
            decision.droppedPageCount = cacheDroppedPages
            decision.operations = sinceDecision
            decision.operations.timing = snapshotTiming(at: entered, includeKeys: false, ended: true)
            decision.occurredAt = timing.map { $0.startedAt.addingTimeInterval(entered) } ?? clock.utc()
            sinceDecision = QualityOperations()
            decision.regularRankedSelection = selection.regular
            decision.matchesCustomPhrase = selection.text.map { text in
                before.configuration.customPhrases.contains { $0.code == before.rawInput && $0.text == text }
            } ?? false
            if selection.ambiguous { decision.unknownRankReason = "ambiguous_candidate_text" }
            else if selection.index == nil { decision.unknownRankReason = "not_a_candidate_selection" }
            if firstPage == nil { decision.pathReason = "first_page_not_observed" }
            index = envelope!.decisions.count
            envelope?.decisions.append(decision)
            commitKind = selection.kind
            allowPunctuationSuffix = selection.trigger == .punctuation
            expectedCommit = selection.text.map { before.selectedPrefix + $0 }
        }
        inProgress = (action, before, index, entered)
        enforceBudget()
    }

    func didMutate(_ snapshot: QualityPageSnapshot, handled: Bool) {
        if suppressed {
            // Stay disabled through the drain for an oversized committing operation.
            if snapshot.rawInput.isEmpty { latest = snapshot }
            return
        }
        guard let operation = inProgress else { return }
        inProgress = nil
        let before = operation.before
        let edited = before.rawInput != snapshot.rawInput || before.caret != snapshot.caret ||
            before.selectedPrefix != snapshot.selectedPrefix || before.selectedPrefixValid != snapshot.selectedPrefixValid
        // Final empty state is a selection/cancellation, not a new Pinyin edit.
        // Partial selection establishes a new remaining-input phase at this event.
        if snapshot.rawInput.isEmpty && (!before.rawInput.isEmpty || operation.decision != nil) {
            timing?.endedOffset = operation.entered
        } else if edited && !snapshot.rawInput.isEmpty {
            let partialSelection = operation.decision != nil && before.selectedPrefix != snapshot.selectedPrefix &&
                snapshot.selectedPrefix.hasPrefix(before.selectedPrefix)
            if partialSelection { restartPhase(at: operation.entered, edited: false) }
            else if operation.action.keypress && !operation.action.candidateMove {
                restartPhase(at: operation.entered, edited: true)
            }
        }
        if edited && operation.action.edit { envelope?.composition.operations.preeditEdits += 1; sinceDecision.preeditEdits += 1 }
        if operation.action.requestsPage(with: before.configuration.inputOptions) || operation.action.candidateMove,
           before.page != snapshot.page, !before.rawInput.isEmpty, !snapshot.rawInput.isEmpty {
            envelope?.composition.operations.pageTurns += 1; sinceDecision.pageTurns += 1
        }
        if operation.action.candidateMove, before.highlightedDisplayIndex != snapshot.highlightedDisplayIndex || before.page != snapshot.page {
            envelope?.composition.operations.candidateMoves += 1; sinceDecision.candidateMoves += 1
        }
        if let index = operation.decision {
            if envelope?.decisions[index].trigger == .punctuation, !snapshot.rawInput.isEmpty {
                if edited && !pendingPrefixes.isEmpty { invalidatePending("composition_edited_after_selection") }
                // Apostrophe can delimit Pinyin; brackets page. Neither proves candidate acceptance.
                if let discarded = envelope?.decisions.removeLast() {
                    sinceDecision.add(discarded.operations)
                }
                expectedCommit = nil
                allowPunctuationSuffix = false
                commitKind = .unknown
            } else if !handled {
                setOutcome(index, .unknown, "action_not_accepted")
                expectedCommit = nil
            } else if !before.selectedPrefixValid || !snapshot.selectedPrefixValid {
                invalidatePending("invalid_selected_prefix")
                setOutcome(index, .unknown, "invalid_selected_prefix")
                expectedCommit = nil
            } else if snapshot.rawInput.isEmpty {
                // Only the original takeCommit drain can prove this tentative final selection.
            } else if let text = envelope?.decisions[index].selectedText,
                      snapshot.rawInput == before.rawInput,
                      snapshot.selectedPrefix == before.selectedPrefix + text,
                      snapshot.selectedPrefix != before.selectedPrefix {
                pendingPrefixes[index] = snapshot.selectedPrefix
                expectedCommit = nil
            } else {
                invalidatePending("ambiguous_selection_transition")
                setOutcome(index, .unknown, "selection_did_not_establish_prefix")
                expectedCommit = nil
            }
        } else if !snapshot.rawInput.isEmpty && edited && !pendingPrefixes.isEmpty {
            if before.rawInput == snapshot.rawInput, before.selectedPrefix.hasPrefix(snapshot.selectedPrefix),
               snapshot.selectedPrefix.utf8.count < before.selectedPrefix.utf8.count, snapshot.selectedPrefixValid {
                for (index, prefix) in pendingPrefixes where !snapshot.selectedPrefix.hasPrefix(prefix) {
                    setOutcome(index, .reverted, "selected_prefix_undone")
                    pendingPrefixes.removeValue(forKey: index)
                }
            } else {
                invalidatePending("composition_edited_after_selection")
            }
        }
        observe(snapshot)
        if operation.action.cancellation {
            finish(.cancelled, reason: "clear_or_escape")
        } else if snapshot.rawInput.isEmpty && operation.decision == nil {
            if before.rawInput.isEmpty && !handled {
                finish(.unknown, reason: "unhandled_passthrough")
            }
        }
        enforceBudget()
    }

    /// Called after the existing controller has made the candidate list available and requested its panel.
    func presented(_ snapshot: QualityPageSnapshot, revision: QualityConfigRevision, panelShowIssued: Bool) {
        guard !suppressed, !snapshot.rawInput.isEmpty else { return }
        self.revision = revision
        ensureComposition()
        var snapshot = snapshot
        snapshot.presentation = panelShowIssued ? .panelShowIssued : .candidatesRequested
        observe(snapshot)
        enforceBudget()
    }

    func commitDrained(_ text: String, insertionIssued: Bool, clientID: String?) {
        if suppressed {
            if !text.isEmpty || latest?.rawInput.isEmpty == true { reset() }
            return
        }
        guard !text.isEmpty else {
            // Backspace deleting the final raw character has no get_commit payload.
            if latest?.rawInput.isEmpty == true, expectedCommit == nil { finish(.cancelled, reason: "composition_emptied") }
            return
        }
        ensureComposition()
        var kind = commitKind
        if kind == .unknown && envelope?.decisions.isEmpty == true {
            kind = QualityTextKind.classify(text) == .symbol ? .directSymbol :
                (text.unicodeScalars.allSatisfy { $0.isASCII } ? .ascii : .unknown)
        }
        let commit = QualityCommit(text: text, kind: kind, insertionIssued: insertionIssued, clientID: clientID)
        envelope?.commits.append(commit)
        let proven: Bool
        if let expectedCommit {
            let suffix = text.hasPrefix(expectedCommit) ? String(text.dropFirst(expectedCommit.count)) : ""
            proven = text == expectedCommit || (allowPunctuationSuffix && text.hasPrefix(expectedCommit) &&
                !suffix.isEmpty && QualityTextKind.classify(suffix) == .symbol)
        } else { proven = false }
        if let envelope {
            for index in envelope.decisions.indices where envelope.decisions[index].outcome == .tentative {
                if proven {
                    self.envelope?.decisions[index].outcome = .committed
                    self.envelope?.decisions[index].commitID = commit.id
                    self.envelope?.decisions[index].pathReason = nil
                } else { setOutcome(index, .unknown, "final_commit_path_unproven") }
            }
        }
        finish(.committed, reason: nil)
    }

    func interrupt(reason: String) { finish(.interrupted, reason: reason) }

    private typealias Selection = (index: Int?, text: String?, trigger: QualityTrigger, kind: QualityCommitKind, regular: Bool, ambiguous: Bool)
    private func selection(for action: QualityAction, snapshot: QualityPageSnapshot) -> Selection? {
        func candidate(_ index: Int, _ trigger: QualityTrigger, _ kind: QualityCommitKind = .candidate,
                       regular: Bool = true, ambiguous: Bool = false) -> Selection? {
            guard snapshot.candidates.indices.contains(index) else { return nil }
            return (index, snapshot.candidates[index].text, trigger, kind, regular, ambiguous)
        }
        switch action {
        case .select(let index, let trigger, let ambiguous): return candidate(index, trigger, regular: [.digit, .space, .panel].contains(trigger), ambiguous: ambiguous)
        case .key(let key, let modifiers, _):
            if modifiers == 0, (49...57).contains(key) { return candidate(Int(key - 49), .digit) }
            if key == 32, modifiers == 0 { return candidate(snapshot.highlightedDisplayIndex, .space) }
            if key == 0xff0d, !snapshot.rawInput.isEmpty, !snapshot.candidates.isEmpty {
                return (nil, nil, .returnRaw, .rawReturn, false, false)
            }
            if (33...126).contains(key), let scalar = UnicodeScalar(UInt32(key)),
               CharacterSet.punctuationCharacters.union(.symbols).contains(scalar), !snapshot.candidates.isEmpty {
                return candidate(snapshot.highlightedDisplayIndex, .punctuation, .punctuation, regular: false)
            }
            return nil
        case .flush(let trigger):
            return candidate(snapshot.highlightedDisplayIndex, trigger, .forcedFlush, regular: false)
        // A mode request preserves the composition. Its later selection/flush owns the decision.
        case .toggle: return nil
        default: return nil
        }
    }

    private func ensureComposition(at monotonicTime: TimeInterval? = nil) {
        guard envelope == nil, !suppressed else { return }
        let now = clock.monotonic()
        monotonicStart = monotonicTime ?? now
        let startedAt = clock.utc().addingTimeInterval(monotonicStart - now)
        if timingEnabled && !timingSuppressed { timing = QualityTiming(startedAt: startedAt) }
        envelope = QualityEnvelope(composition: QualityComposition(startedAt: startedAt, appBundleID: appBundleID,
            clientID: clientID, outcome: .unknown))
    }

    private func keyKind(_ action: QualityAction, snapshot: QualityPageSnapshot) -> QualityKeyKind {
        guard case .key(let key, let modifiers, _) = action else { return .other }
        if key == -1 || modifiers > 1 { return .shortcut }
        if action.requestsPage(with: snapshot.configuration.inputOptions), !snapshot.candidates.isEmpty { return .page }
        switch key {
        case 0xff08: return .backspace
        case 0xffff: return .delete
        case 0xff51, 0xff53, 0xff50, 0xff57: return .caret
        case 0xff52, 0xff54: return .candidateMove
        case 0xff55, 0xff56: return .page
        case 0xff0d: return .returnRaw
        case 0xff1b: return .escape
        case 9, 0xff09: return .tab
        case 32: return .space
        case 48...57: return .digit
        case 65...90, 97...122, 39: return .typing
        default: return .other
        }
    }

    private func recordKey(_ kind: QualityKeyKind, isRepeat: Bool, at offset: TimeInterval) {
        guard timing != nil else { return }
        let sample = QualityKeySample(sequence: keySequence, offset: offset,
            interval: lastKeyOffset.map { max(0, offset - $0) }, kind: kind, isRepeat: isRepeat)
        keySequence += 1
        lastKeyOffset = offset
        if timing!.keySamples.count == QualityLimits.keySamples {
            // Keep the first N-1 keys and latest key, so the terminating operation and
            // its actual adjacent interval survive even an unusually long composition.
            timing?.keySamples.removeLast()
            timing?.droppedKeyCount += 1
        }
        timing?.keySamples.append(sample)
    }

    private func restartPhase(at offset: TimeInterval, edited: Bool) {
        if edited {
            timing?.lastEditOffset = offset
            visibleAccumulated = 0
            visibleSince = visible ? offset : nil
        }
        timing?.phaseStartedOffset = offset
        timing?.endedOffset = nil
        phaseVisibleAccumulated = 0
        phaseVisibleSince = visible ? offset : nil
    }

    private func snapshotTiming(at offset: TimeInterval, includeKeys: Bool = true, ended: Bool = false) -> QualityTiming? {
        guard var result = timing else { return nil }
        let end = result.endedOffset ?? offset
        if ended { result.endedOffset = end }
        if let lastEdit = result.lastEditOffset {
            result.postEditWait = max(0, end - lastEdit)
            if visibilityObserved {
                result.observedVisibleDuration = visibleAccumulated + (visibleSince.map { max(0, end - $0) } ?? 0)
            }
        }
        if let phaseStart = result.phaseStartedOffset {
            result.phaseWait = max(0, end - phaseStart)
            if visibilityObserved {
                result.phaseObservedVisibleDuration = phaseVisibleAccumulated + (phaseVisibleSince.map { max(0, end - $0) } ?? 0)
            }
        }
        if !includeKeys { result.keySamples = []; result.droppedKeyCount = 0 }
        return result
    }

    private func sameGeneration(_ lhs: QualityPageSnapshot, _ rhs: QualityPageSnapshot) -> Bool {
        lhs.rawInput == rhs.rawInput && lhs.caret == rhs.caret && lhs.selectedPrefix == rhs.selectedPrefix &&
        lhs.selectedPrefixValid == rhs.selectedPrefixValid && lhs.precedingContext == rhs.precedingContext &&
        lhs.configurationRevisionID == rhs.configurationRevisionID
    }

    private func observe(_ input: QualityPageSnapshot) {
        guard envelope != nil else { return }
        var snapshot = input
        if let latest, sameGeneration(latest, snapshot) {
            snapshot.generation = latest.generation
            if latest.presentation != .notShown, latest.page == snapshot.page,
               latest.candidates == snapshot.candidates { snapshot.presentation = latest.presentation }
        } else {
            generation += 1
            snapshot.generation = generation
            firstPage = nil
            pages = []
            cacheHistoryTruncated = false
            cacheDroppedPages = 0
        }
        latest = snapshot
        if !snapshot.rawInput.isEmpty {
            observedComposition = true
            if snapshot.page == 0 {
                if firstPage == nil { firstPage = snapshot }
                else if firstPage?.candidates == snapshot.candidates { firstPage?.presentation = snapshot.presentation }
            }
            if let index = pages.firstIndex(where: { $0.page == snapshot.page && $0.candidates == snapshot.candidates }) {
                pages[index].presentation = snapshot.presentation
            } else { pages.append(snapshot) }
        }
        if let revision, !(envelope?.revisions.contains { $0.id == revision.id } ?? true) {
            envelope?.revisions.append(revision)
        }
    }

    private func setOutcome(_ index: Int, _ outcome: QualityDecisionOutcome, _ reason: String) {
        envelope?.decisions[index].outcome = outcome
        envelope?.decisions[index].pathReason = reason
    }

    private func invalidatePending(_ reason: String) {
        for index in pendingPrefixes.keys { setOutcome(index, .unknown, reason) }
        pendingPrefixes = [:]
    }

    private func enforceBudget() {
        envelope?.composition.operations.timing = timingSnapshot
        guard var record = envelope else { return }
        // Include all transient cache pages in the same active cap, retaining decision/first-page core.
        if let latest {
            record.decisions.append(QualityDecision(sequence: record.decisions.count, trigger: .other,
                outcome: .unknown, snapshot: latest, firstPage: firstPage, visitedPages: pages))
        }
        guard var bounded = record.bounded() else {
            do { _ = try record.validatedConfigurations(); store.noteOversizedActiveRecord() }
            catch QualityEnvelope.ConfigurationFailure.invalid { store.noteInvalidActiveRecord() }
            catch { store.noteOversizedActiveRecord() }
            reset()
            suppressed = true
            return
        }
        if latest != nil {
            let cache = bounded.decisions.removeLast()
            latest = cache.snapshot
            firstPage = cache.firstPage
            pages = cache.visitedPages
            cacheHistoryTruncated = cacheHistoryTruncated || cache.pageHistoryTruncated
            cacheDroppedPages += cache.droppedPageCount
        }
        envelope = bounded
    }

    private func finish(_ outcome: QualityCompositionOutcome, reason: String?) {
        guard !suppressed else { reset(); return }
        guard var record = envelope else { reset(); return }
        for index in record.decisions.indices where record.decisions[index].outcome == .tentative {
            record.decisions[index].outcome = outcome == .cancelled ? .cancelled : .interrupted
            record.decisions[index].pathReason = reason
        }
        record.composition.outcome = outcome
        record.composition.outcomeReason = reason
        record.composition.operations.timing = snapshotTiming(at: offsetNow, ended: true)
        record.composition.endedAt = record.composition.operations.timing.map {
            $0.startedAt.addingTimeInterval($0.endedOffset ?? offsetNow)
        } ?? clock.utc()
        // Empty finish callbacks and idle highlight calls do not create compositions.
        if !record.decisions.isEmpty || !record.commits.isEmpty || observedComposition {
            store.submit(record)
        }
        reset()
    }

    private func reset() {
        envelope = nil
        revision = nil
        observedComposition = false
        latest = nil
        firstPage = nil
        pages = []
        cacheHistoryTruncated = false
        cacheDroppedPages = 0
        pendingPrefixes = [:]
        sinceDecision = QualityOperations()
        inProgress = nil
        expectedCommit = nil
        commitKind = .unknown
        allowPunctuationSuffix = false
        suppressed = false
        timing = nil
        timingSuppressed = false
        lastKeyOffset = nil
        keySequence = 0
        visible = false
        visibilityObserved = false
        visibleSince = nil
        visibleAccumulated = 0
        phaseVisibleSince = nil
        phaseVisibleAccumulated = 0
    }
}
