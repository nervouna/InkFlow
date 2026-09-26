import InkFlowDomain
import Foundation
import CryptoKit

/// Values captured in memory. JSON and fingerprinting belong to the store's worker.
package struct QualityBuildMetadata: Codable, Equatable, Sendable {
    package var sourceRevision: String
    package var sourceTreeSHA256: String
    package var sourceDirty: Bool?
    package var bundledResourcesSHA256: String
    /// Complete unsigned .app payload, excluding this metadata file and later signing/notarization envelopes.
    /// The legacy resources digest remains for compatibility.
    package var bundleSHA256: String = "unknown"
    package var rankingSourceSHA256: String = "unknown"
    package var rankingResourcesSHA256: String = "unknown"
    package var appVersion: String
    package var appBuild: String

    package static let unknown = QualityBuildMetadata(sourceRevision: "unknown", sourceTreeSHA256: "unknown",
        sourceDirty: nil, bundledResourcesSHA256: "unknown", appVersion: "unknown", appBuild: "unknown")

    private enum CodingKeys: String, CodingKey {
        case sourceRevision, sourceTreeSHA256, sourceDirty, bundledResourcesSHA256, bundleSHA256
        case rankingSourceSHA256, rankingResourcesSHA256, appVersion, appBuild
    }

    package init(sourceRevision: String, sourceTreeSHA256: String, sourceDirty: Bool?, bundledResourcesSHA256: String,
         bundleSHA256: String = "unknown", rankingSourceSHA256: String = "unknown",
         rankingResourcesSHA256: String = "unknown", appVersion: String, appBuild: String) {
        self.sourceRevision = sourceRevision
        self.sourceTreeSHA256 = sourceTreeSHA256
        self.sourceDirty = sourceDirty
        self.bundledResourcesSHA256 = bundledResourcesSHA256
        self.bundleSHA256 = bundleSHA256
        self.rankingSourceSHA256 = rankingSourceSHA256
        self.rankingResourcesSHA256 = rankingResourcesSHA256
        self.appVersion = appVersion
        self.appBuild = appBuild
    }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceRevision = try values.decode(String.self, forKey: .sourceRevision)
        sourceTreeSHA256 = try values.decode(String.self, forKey: .sourceTreeSHA256)
        sourceDirty = try values.decodeIfPresent(Bool.self, forKey: .sourceDirty)
        bundledResourcesSHA256 = try values.decode(String.self, forKey: .bundledResourcesSHA256)
        bundleSHA256 = try values.decodeIfPresent(String.self, forKey: .bundleSHA256) ?? "unknown"
        rankingSourceSHA256 = try values.decodeIfPresent(String.self, forKey: .rankingSourceSHA256) ?? "unknown"
        rankingResourcesSHA256 = try values.decodeIfPresent(String.self, forKey: .rankingResourcesSHA256) ?? "unknown"
        appVersion = try values.decode(String.self, forKey: .appVersion)
        appBuild = try values.decode(String.self, forKey: .appBuild)
    }
}

package struct QualityFingerprints: Equatable, Sendable {
    package let ranking: String
    package let settings: String
    package let measurement: String
    package let buildIdentity: String

    package static func make(configuration: QualityAppliedConfiguration, build: QualityBuildMetadata,
                     engineVersion: String, databaseSchemaVersion: Int, metricRuleVersion: Int,
                     collectionRuleVersion: Int) throws -> Self {
        try requireDigest(build.rankingSourceSHA256, name: "ranking source")
        try requireDigest(build.rankingResourcesSHA256, name: "ranking resources")
        try requireDigest(build.sourceTreeSHA256, name: "source tree")
        try requireDigest(build.bundledResourcesSHA256, name: "bundled resources")
        try requireDigest(build.bundleSHA256, name: "bundle")
        guard !build.sourceRevision.isEmpty, build.sourceRevision != "unknown",
              build.sourceDirty != nil, !build.appVersion.isEmpty, build.appVersion != "unknown",
              !build.appBuild.isEmpty, build.appBuild != "unknown" else {
            throw QualityIdentityError.missing("build metadata")
        }
        guard !engineVersion.isEmpty, engineVersion != "unknown" else { throw QualityIdentityError.missing("engine version") }
        let rankingConfiguration = RankingConfiguration(candidateCount: configuration.candidateCount,
            customPhrases: configuration.customPhrases.map { .init(code: $0.code, text: $0.text) },
            schemaID: configuration.schemaID, asciiMode: configuration.asciiMode,
            inputOptions: configuration.inputOptions)
        return Self(
            ranking: try digest(RankingIdentity(engineVersion: engineVersion,
                sourceSHA256: build.rankingSourceSHA256, resourcesSHA256: build.rankingResourcesSHA256,
                configuration: rankingConfiguration)),
            settings: try digest(configuration),
            measurement: try digest(MeasurementIdentity(databaseSchemaVersion: databaseSchemaVersion,
                metricRuleVersion: metricRuleVersion, collectionRuleVersion: collectionRuleVersion)),
            buildIdentity: try digest(build))
    }

    private struct RankingPhrase: Codable { let code: String; let text: String }
    private struct RankingConfiguration: Codable {
        let candidateCount: Int
        let customPhrases: [RankingPhrase]
        let schemaID: String
        let asciiMode: Bool
        let inputOptions: [String: Bool]?
    }
    private struct RankingIdentity: Codable {
        let engineVersion: String
        let sourceSHA256: String
        let resourcesSHA256: String
        let configuration: RankingConfiguration
    }
    private struct MeasurementIdentity: Codable {
        let databaseSchemaVersion: Int
        let metricRuleVersion: Int
        let collectionRuleVersion: Int
    }
    private static func requireDigest(_ value: String, name: String) throws {
        guard value.count == 64, value.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw QualityIdentityError.missing(name)
        }
    }
    private static func digest<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try QualityJSON.encoder().encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}

package enum QualityIdentityError: Error, Equatable {
    case missing(String)
}

package struct QualityPhrase: Codable, Equatable, Sendable {
    package var id: String
    package var code: String
    package var text: String
    package init(id: String,
        code: String,
        text: String) {
        self.id = id
        self.code = code
        self.text = text
    }

}

package struct QualityAppliedConfiguration: Codable, Equatable, Sendable {
    package var candidateCount: Int
    package var customPhrases: [QualityPhrase] = []
    package var schemaID = "inkflow_pinyin"
    package var asciiMode = false
    package var fontSize = 14
    package var vertical = false
    /// Nil for records captured before input preferences were available.
    package var inputOptions: [String: Bool]? = nil
    package init(candidateCount: Int,
        customPhrases: [QualityPhrase] = [],
        schemaID: String = "inkflow_pinyin",
        asciiMode: Bool = false,
        fontSize: Int = 14,
        vertical: Bool = false,
        inputOptions: [String: Bool]? = nil) {
        self.candidateCount = candidateCount
        self.customPhrases = customPhrases
        self.schemaID = schemaID
        self.asciiMode = asciiMode
        self.fontSize = fontSize
        self.vertical = vertical
        self.inputOptions = inputOptions
    }

}

package struct QualityConfigRevision: Codable, Equatable, Sendable {
    /// Capture-time identity; the worker adds a stable content fingerprint for comparisons.
    package var id = UUID().uuidString
    package var configuration: QualityAppliedConfiguration
    package var createdAt = Date()
    package init(id: String = UUID().uuidString,
        configuration: QualityAppliedConfiguration,
        createdAt: Date = Date()) {
        self.id = id
        self.configuration = configuration
        self.createdAt = createdAt
    }

}

/// Text kind is a descriptive output category, never translator provenance.
package enum QualityTextKind: String, Codable, Sendable {
    case chinese, english, emoji, mixed, symbol, number, other, unknown

    package static func classify(_ text: String) -> Self {
        guard !text.isEmpty else { return .unknown }
        let scalars = text.unicodeScalars
        // Digits have the Unicode Emoji property; require an actual emoji sequence/presentation.
        let emoji = scalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xfe0f || $0.value == 0x20e3 }
        let han = scalars.contains { (0x3400...0x9fff).contains($0.value) || (0x20000...0x323af).contains($0.value) }
        let latin = scalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
        if emoji && !han && !latin { return .emoji }
        if (han && latin) || (emoji && (han || latin)) { return .mixed }
        if han { return .chinese }
        if latin { return .english }
        if scalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) { return .number }
        if scalars.allSatisfy({ CharacterSet.punctuationCharacters.union(.symbols).union(.whitespaces).contains($0) }) { return .symbol }
        return .other
    }
}

package struct QualityCandidate: Codable, Equatable, Sendable {
    package var text: String
    package var comment: String? = nil
    package var displayIndex: Int
    package var displayRank: Int
    package var nativeIndex: Int
    package var nativeRank: Int
    package var source: String? = nil
    package var consumedInputStart: Int? = nil
    package var consumedInputEnd: Int? = nil
    package init(text: String,
        comment: String? = nil,
        displayIndex: Int,
        displayRank: Int,
        nativeIndex: Int,
        nativeRank: Int,
        source: String? = nil,
        consumedInputStart: Int? = nil,
        consumedInputEnd: Int? = nil) {
        self.text = text
        self.comment = comment
        self.displayIndex = displayIndex
        self.displayRank = displayRank
        self.nativeIndex = nativeIndex
        self.nativeRank = nativeRank
        self.source = source
        self.consumedInputStart = consumedInputStart
        self.consumedInputEnd = consumedInputEnd
    }

}

/// Independent of EngineSnapshot equality. Indices/pages are zero-based; ranks are one-based.
package struct QualityPageSnapshot: Codable, Equatable, Sendable {
    package var generation: Int
    package var rawInput: String
    package var caret: Int
    package var selectedPrefix: String
    package var precedingContext: String
    package var configurationRevisionID: String
    package var configuration: QualityAppliedConfiguration
    package var page: Int
    package var pageSize: Int
    package var candidates: [QualityCandidate]
    package var highlightedDisplayIndex: Int
    package var selectedPrefixValid = true
    /// Engine observation alone does not establish that a client requested or showed candidates.
    package var presentation: QualityPresentation = .notShown
    package var capturedAt = Date()
    package init(generation: Int,
        rawInput: String,
        caret: Int,
        selectedPrefix: String,
        precedingContext: String,
        configurationRevisionID: String,
        configuration: QualityAppliedConfiguration,
        page: Int,
        pageSize: Int,
        candidates: [QualityCandidate],
        highlightedDisplayIndex: Int,
        selectedPrefixValid: Bool = true,
        presentation: QualityPresentation = .notShown,
        capturedAt: Date = Date()) {
        self.generation = generation
        self.rawInput = rawInput
        self.caret = caret
        self.selectedPrefix = selectedPrefix
        self.precedingContext = precedingContext
        self.configurationRevisionID = configurationRevisionID
        self.configuration = configuration
        self.page = page
        self.pageSize = pageSize
        self.candidates = candidates
        self.highlightedDisplayIndex = highlightedDisplayIndex
        self.selectedPrefixValid = selectedPrefixValid
        self.presentation = presentation
        self.capturedAt = capturedAt
    }

}

package enum QualityPresentation: String, Codable, Sendable {
    case notShown = "not_shown", candidatesRequested = "candidates_requested", panelShowIssued = "panel_show_issued"
}

extension QualityPageSnapshot {
    private enum CodingKeys: String, CodingKey {
        case generation, rawInput, caret, selectedPrefix, precedingContext, configurationRevisionID, configuration
        case page, pageSize, candidates, highlightedDisplayIndex, selectedPrefixValid, presentation, capturedAt
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generation, forKey: .generation)
        try container.encode(rawInput, forKey: .rawInput)
        try container.encode(caret, forKey: .caret)
        try container.encode(selectedPrefix, forKey: .selectedPrefix)
        try container.encode(precedingContext, forKey: .precedingContext)
        try container.encode(configurationRevisionID, forKey: .configurationRevisionID)
        if encoder.userInfo[QualityJSON.compactPages] as? Bool != true {
            try container.encode(configuration, forKey: .configuration)
        }
        try container.encode(page, forKey: .page)
        try container.encode(pageSize, forKey: .pageSize)
        try container.encode(candidates, forKey: .candidates)
        try container.encode(highlightedDisplayIndex, forKey: .highlightedDisplayIndex)
        try container.encode(selectedPrefixValid, forKey: .selectedPrefixValid)
        try container.encode(presentation, forKey: .presentation)
        try container.encode(capturedAt, forKey: .capturedAt)
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .configurationRevisionID)
        let resolved = (decoder.userInfo[QualityJSON.configurationResolver] as? [String: QualityAppliedConfiguration])?[id]
        guard let configuration = try container.decodeIfPresent(QualityAppliedConfiguration.self, forKey: .configuration) ?? resolved else {
            throw DecodingError.dataCorruptedError(forKey: .configurationRevisionID, in: container,
                debugDescription: "Compact quality page requires its applied configuration revision")
        }
        if let resolved, resolved != configuration {
            throw DecodingError.dataCorruptedError(forKey: .configurationRevisionID, in: container,
                debugDescription: "Quality revision content mismatch")
        }
        self.init(generation: try container.decode(Int.self, forKey: .generation),
            rawInput: try container.decode(String.self, forKey: .rawInput), caret: try container.decode(Int.self, forKey: .caret),
            selectedPrefix: try container.decode(String.self, forKey: .selectedPrefix),
            precedingContext: try container.decode(String.self, forKey: .precedingContext),
            configurationRevisionID: id, configuration: configuration,
            page: try container.decode(Int.self, forKey: .page), pageSize: try container.decode(Int.self, forKey: .pageSize),
            candidates: try container.decode([QualityCandidate].self, forKey: .candidates),
            highlightedDisplayIndex: try container.decode(Int.self, forKey: .highlightedDisplayIndex),
            selectedPrefixValid: try container.decode(Bool.self, forKey: .selectedPrefixValid),
            presentation: try container.decode(QualityPresentation.self, forKey: .presentation),
            capturedAt: try container.decode(Date.self, forKey: .capturedAt))
    }
}

/// Counters are separate facts: an arrow crossing a page increments moves and page turns.
package struct QualityOperations: Codable, Equatable, Sendable {
    package var keypresses = 0
    package var pageRequests = 0
    package var pageTurns = 0
    package var candidateMoves = 0
    /// Actual Backspace/Delete/caret-edit operations that changed composition state, excluding typing and selection.
    package var preeditEdits = 0
    /// Absent in older records or when capture was suppressed. Never interpret absence as zero.
    package var timing: QualityTiming? = nil

    mutating func add(_ other: Self) {
        keypresses += other.keypresses
        pageRequests += other.pageRequests
        pageTurns += other.pageTurns
        candidateMoves += other.candidateMoves
        preeditEdits += other.preeditEdits
        // Timing is a phase snapshot, not an additive counter. In particular, do not
        // double-count dwell when a tentative punctuation decision is folded back.
    }
    package init(keypresses: Int = 0,
        pageRequests: Int = 0,
        pageTurns: Int = 0,
        candidateMoves: Int = 0,
        preeditEdits: Int = 0,
        timing: QualityTiming? = nil) {
        self.keypresses = keypresses
        self.pageRequests = pageRequests
        self.pageTurns = pageTurns
        self.candidateMoves = candidateMoves
        self.preeditEdits = preeditEdits
        self.timing = timing
    }

}

package enum QualityKeyKind: String, Codable, Sendable {
    case typing, backspace, delete, caret, candidateMove = "candidate_move", page
    case space, digit, returnRaw = "return", escape, tab, aiTab = "ai_tab"
    case shortcut, modeToggle = "mode_toggle", other
}

/// Content-free effectiveness evidence. These closed enums deliberately cannot carry
/// transcript, candidate, document, or correction text.
package enum QualityEffectivenessSource: String, Codable, Sendable {
    case voiceSession = "voice_session"
    case voiceCorrection = "voice_correction"
    case voiceAlias = "voice_alias"
    case canonicalLexicon = "canonical_lexicon"
}

package enum QualityEffectivenessKind: String, Codable, Sendable {
    case finalized, detected, learned, rejected, hit
    case laterReuse = "later_reuse"
}

package enum QualityEffectivenessReason: String, Codable, Sendable {
    case immediateUndo = "immediate_undo"
    case deactivated, cancelled
    case clientDrift = "client_drift"
    case secure, unreadable
    case invalidRange = "invalid_range"
    case unrelatedEdit = "unrelated_edit"
    case timeout
    case storageFailure = "storage_failure"
    case unavailable
}

package struct QualityEffectivenessEvent: Equatable, Sendable {
    package var source: QualityEffectivenessSource
    package var event: QualityEffectivenessKind
    package var reason: QualityEffectivenessReason? = nil
    package var count = 1
    package var milliseconds: Int? = nil
    package var occurredAt = Date()

    package var isValid: Bool {
        guard (1...QualityLimits.effectivenessMaxCount).contains(count),
              milliseconds.map({ (0...QualityLimits.effectivenessMaxMilliseconds).contains($0) }) ?? true else {
            return false
        }
        let pairing = switch source {
        case .voiceSession: event == .finalized
        case .voiceCorrection: [.detected, .learned, .rejected].contains(event)
        case .voiceAlias, .canonicalLexicon: [.hit, .laterReuse].contains(event)
        }
        guard pairing else { return false }
        return event == .rejected ? reason != nil : reason == nil
    }
    package init(source: QualityEffectivenessSource,
        event: QualityEffectivenessKind,
        reason: QualityEffectivenessReason? = nil,
        count: Int = 1,
        milliseconds: Int? = nil,
        occurredAt: Date = Date()) {
        self.source = source
        self.event = event
        self.reason = reason
        self.count = count
        self.milliseconds = milliseconds
        self.occurredAt = occurredAt
    }

}

package struct QualityKeySample: Codable, Equatable, Sendable {
    package var sequence: Int
    /// Seconds at the controller keyDown callback entry (or direct engine call),
    /// on the monotonic timeline relative to QualityTiming.startedAt.
    package var offset: TimeInterval
    package var interval: TimeInterval?
    package var kind: QualityKeyKind
    package var isRepeat: Bool
    package init(sequence: Int,
        offset: TimeInterval,
        interval: TimeInterval? = nil,
        kind: QualityKeyKind,
        isRepeat: Bool) {
        self.sequence = sequence
        self.offset = offset
        self.interval = interval
        self.kind = kind
        self.isRepeat = isRepeat
    }

}

/// Composition-level samples and decision-level phase snapshots share this schema.
/// Visibility is observed at refresh/key boundaries and a bounded polling interval;
/// it proves panel visibility at observations, not attention or exact display onset.
package struct QualityTiming: Codable, Equatable, Sendable {
    package var version = 1
    package var startedAt: Date
    package var keySamples: [QualityKeySample] = []
    package var droppedKeyCount = 0
    package var lastEditOffset: TimeInterval? = nil
    package var phaseStartedOffset: TimeInterval? = nil
    package var endedOffset: TimeInterval? = nil
    package var postEditWait: TimeInterval? = nil
    package var observedVisibleDuration: TimeInterval? = nil
    /// A partial candidate selection starts a new remaining-input phase without
    /// resetting the whole last-edit-to-final-selection measurements above.
    package var phaseWait: TimeInterval? = nil
    package var phaseObservedVisibleDuration: TimeInterval? = nil
    package var visibilityObservationInterval: TimeInterval? = nil

    package var lastEditAt: Date? { lastEditOffset.map { startedAt.addingTimeInterval($0) } }
    package init(version: Int = 1,
        startedAt: Date,
        keySamples: [QualityKeySample] = [],
        droppedKeyCount: Int = 0,
        lastEditOffset: TimeInterval? = nil,
        phaseStartedOffset: TimeInterval? = nil,
        endedOffset: TimeInterval? = nil,
        postEditWait: TimeInterval? = nil,
        observedVisibleDuration: TimeInterval? = nil,
        phaseWait: TimeInterval? = nil,
        phaseObservedVisibleDuration: TimeInterval? = nil,
        visibilityObservationInterval: TimeInterval? = nil) {
        self.version = version
        self.startedAt = startedAt
        self.keySamples = keySamples
        self.droppedKeyCount = droppedKeyCount
        self.lastEditOffset = lastEditOffset
        self.phaseStartedOffset = phaseStartedOffset
        self.endedOffset = endedOffset
        self.postEditWait = postEditWait
        self.observedVisibleDuration = observedVisibleDuration
        self.phaseWait = phaseWait
        self.phaseObservedVisibleDuration = phaseObservedVisibleDuration
        self.visibilityObservationInterval = visibilityObservationInterval
    }

}

/// One injectable monotonic source for physical key entry, edit, visibility and end.
/// NSEvent timestamps are deliberately not mixed with this clock (fixtures may be zero).
@MainActor
package struct QualityClock {
    package init(monotonic: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, utc: @escaping () -> Date = { Date() }) {
        self.monotonic = monotonic; self.utc = utc
    }
    package var monotonic: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    package var utc: () -> Date = { Date() }
}

package enum QualityCompositionOutcome: String, Codable, Sendable {
    case committed, cancelled, interrupted, unknown
}
package enum QualityDecisionOutcome: String, Codable, Sendable {
    case tentative, committed, reverted, edited, cancelled, interrupted, unknown
}
package enum QualityTrigger: String, Codable, Sendable {
    case digit, space, panel, returnRaw = "return_raw", punctuation
    case forceFlush = "force_flush", modeToggle = "mode_toggle", other
}
package enum QualityCommitKind: String, Codable, Sendable {
    case candidate, punctuation, rawReturn = "raw_return", ascii
    case directSymbol = "direct_symbol", forcedFlush = "forced_flush", modeToggle = "mode_toggle", unknown
}

package struct QualityComposition: Codable, Equatable, Sendable {
    package var id = UUID().uuidString
    package var startedAt = Date()
    package var endedAt = Date()
    package var appBundleID: String? = nil
    package var clientID: String? = nil
    package var outcome: QualityCompositionOutcome
    package var outcomeReason: String? = nil
    package var operations = QualityOperations()
    package var pageHistoryTruncated = false
    package var droppedPageCount = 0
}

package struct QualityDecision: Codable, Equatable, Sendable {
    package var id = UUID().uuidString
    package var occurredAt = Date()
    package var sequence: Int
    package var trigger: QualityTrigger
    package var outcome: QualityDecisionOutcome
    package var selectedDisplayIndex: Int? = nil
    package var selectedText: String? = nil
    package var textKind: QualityTextKind = .unknown
    package var commitID: String? = nil
    package var operations = QualityOperations()
    package var regularRankedSelection = false
    package var matchesCustomPhrase = false
    package var unknownRankReason: String? = nil
    package var pathReason: String? = nil
    /// Captured before mutation, with the exact order presented for this decision.
    package var snapshot: QualityPageSnapshot
    /// Nil means unknown. Never replace with the top candidate of a later page.
    package var firstPage: QualityPageSnapshot? = nil
    package var visitedPages: [QualityPageSnapshot] = []
    package var pageHistoryTruncated = false
    package var droppedPageCount = 0
}

package struct QualityCommit: Codable, Equatable, Sendable {
    package var id = UUID().uuidString
    package var issuedAt = Date()
    package var text: String
    package var kind: QualityCommitKind
    /// An insertText call was issued; this is not independent observation of the document.
    package var insertionIssued: Bool
    package var clientID: String? = nil
}

package struct QualityEnvelope: Codable, Equatable, Sendable {
    package var composition: QualityComposition
    package var decisions: [QualityDecision] = []
    package var commits: [QualityCommit] = []
    package var revisions: [QualityConfigRevision] = []

    /// Also use this cap while growing an active recorder, before retaining another snapshot.
    /// Counts strings and collection/record overhead with an early exit, without JSON or I/O.
    package func bounded() -> QualityEnvelope? {
        guard decisions.count <= 128, commits.count <= 256, revisions.count <= 256 else { return nil }
        guard let configurations = configurationsByID else { return nil }
        var reduced = self
        if !reduced.fitsMemoryBudget { reduced.removePageHistory() }
        guard reduced.fitsMemoryBudget else { return nil }
        for index in reduced.revisions.indices {
            reduced.revisions[index].configuration = configurations[reduced.revisions[index].id]!
        }
        for index in reduced.decisions.indices {
            reduced.decisions[index].snapshot.configuration = configurations[reduced.decisions[index].snapshot.configurationRevisionID]!
            if let first = reduced.decisions[index].firstPage {
                reduced.decisions[index].firstPage?.configuration = configurations[first.configurationRevisionID]!
            }
            for page in reduced.decisions[index].visitedPages.indices {
                let id = reduced.decisions[index].visitedPages[page].configurationRevisionID
                reduced.decisions[index].visitedPages[page].configuration = configurations[id]!
            }
        }
        return reduced
    }

    /// Includes reference-only pages; conflicting identity is invalid evidence.
    package var configurationsByID: [String: QualityAppliedConfiguration]? { try? validatedConfigurations() }

    package enum ConfigurationFailure: Error { case invalid, oversized }

    package func validatedConfigurations() throws -> [String: QualityAppliedConfiguration] {
        var values: [String: QualityAppliedConfiguration] = [:]
        var budget = QualityMemoryBudget(remaining: QualityLimits.configurationBytes)
        func add(_ id: String, _ configuration: QualityAppliedConfiguration) throws {
            if let existing = values[id] {
                guard existing == configuration else { throw ConfigurationFailure.invalid }
                return
            }
            budget.strings(id)
            budget.configuration(configuration)
            guard !budget.exhausted else { throw ConfigurationFailure.oversized }
            values[id] = configuration
        }
        for revision in revisions { try add(revision.id, revision.configuration) }
        for decision in decisions {
            try add(decision.snapshot.configurationRevisionID, decision.snapshot.configuration)
            if let page = decision.firstPage { try add(page.configurationRevisionID, page.configuration) }
            for page in decision.visitedPages {
                try add(page.configurationRevisionID, page.configuration)
            }
        }
        return values
    }

    package var retainedBytes: Int {
        var budget = QualityMemoryBudget(remaining: QualityLimits.configurationBytes)
        for (id, config) in configurationsByID ?? [:] { budget.strings(id); budget.configuration(config) }
        return eventBytes + QualityLimits.configurationBytes - budget.remaining
    }

    mutating func removePageHistory() {
        for index in decisions.indices where !decisions[index].visitedPages.isEmpty {
            let count = decisions[index].visitedPages.count
            decisions[index].visitedPages = []
            decisions[index].pageHistoryTruncated = true
            decisions[index].droppedPageCount += count
            composition.pageHistoryTruncated = true
            composition.droppedPageCount += count
        }
    }

    private var fitsMemoryBudget: Bool {
        eventBytes <= QualityLimits.envelopeBytes
    }

    private var eventBytes: Int {
        var budget = QualityMemoryBudget()
        budget.record(512)
        budget.strings(composition.id, composition.appBundleID, composition.clientID, composition.outcomeReason)
        budget.timing(composition.operations.timing)
        for revision in revisions {
            if budget.exhausted { return QualityLimits.envelopeBytes + 1 }
            budget.record(256)
            budget.strings(revision.id)
        }
        for decision in decisions {
            if budget.exhausted { return QualityLimits.envelopeBytes + 1 }
            budget.record(512)
            budget.strings(decision.id, decision.selectedText, decision.commitID, decision.unknownRankReason, decision.pathReason)
            budget.timing(decision.operations.timing)
            budget.page(decision.snapshot)
            if let first = decision.firstPage { budget.page(first) }
            for page in decision.visitedPages {
                if budget.exhausted { return QualityLimits.envelopeBytes + 1 }
                budget.page(page)
            }
        }
        for commit in commits {
            if budget.exhausted { return QualityLimits.envelopeBytes + 1 }
            budget.record(256)
            budget.strings(commit.id, commit.text, commit.clientID)
        }
        return QualityLimits.envelopeBytes - budget.remaining
    }
}

package enum QualityLimits {
    package static let databaseSchemaVersion = 3
    package static let envelopeBytes = 64 * 1024
    package static let configurationBytes = 256 * 1024
    package static let bufferedBytes = 8 * 1024 * 1024
    package static let bufferedEnvelopes = 128
    package static let batchEnvelopes = 16
    package static let flushInterval: TimeInterval = 1
    package static let metricRuleVersion = 1
    package static let collectionRuleVersion = 1
    package static let keySamples = 256
    package static let visibilityObservationInterval: TimeInterval = 0.1
    package static let bufferedEffectivenessEvents = 256
    package static let effectivenessMaxCount = 64
    package static let effectivenessMaxMilliseconds = 60_000
    package static let effectivenessRetentionRows = 4_096
    package static let effectivenessRetentionDays = 90
}

/// Conservative logical retained-byte budget. The worker separately checks encoded bytes.
private struct QualityMemoryBudget {
    package var remaining = QualityLimits.envelopeBytes
    package var exhausted: Bool { remaining < 0 }
    mutating func record(_ size: Int) { remaining -= size }
    mutating func timing(_ value: QualityTiming?) {
        guard let value else { return }
        record(256 + value.keySamples.count * 96)
    }
    mutating func strings(_ values: String?...) {
        for value in values {
            guard !exhausted else { return }
            guard let value else { continue }
            // String UTF-16 storage, bookkeeping, and early exit for an arbitrarily large input.
            let count = value.utf8.prefix(max(0, remaining / 2 + 1)).count
            remaining -= 64 + 2 * count
        }
    }
    mutating func configuration(_ value: QualityAppliedConfiguration) {
        record(256)
        strings(value.schemaID)
        for (key, _) in value.inputOptions ?? [:] {
            guard !exhausted else { return }
            record(64); strings(key)
        }
        for phrase in value.customPhrases {
            guard !exhausted else { return }
            record(128)
            strings(phrase.id, phrase.code, phrase.text)
        }
    }
    mutating func page(_ value: QualityPageSnapshot) {
        guard !exhausted else { return }
        record(512)
        strings(value.rawInput, value.selectedPrefix, value.precedingContext, value.configurationRevisionID)
        for candidate in value.candidates {
            guard !exhausted else { return }
            record(256)
            strings(candidate.text, candidate.comment, candidate.source)
        }
    }
}

/// Timestamp JSON uses UTC ISO 8601 with milliseconds, matching SQL's time columns.
package enum QualityJSON {
    package static let compactPages = CodingUserInfoKey(rawValue: "quality.compactPages")!
    package static let configurationResolver = CodingUserInfoKey(rawValue: "quality.configurationResolver")!
    package static func encoder(compact: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.userInfo[compactPages] = compact
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamp(date))
        }
        return encoder
    }
    package static func decoder(configurations: [String: QualityAppliedConfiguration]? = nil) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[configurationResolver] = configurations
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = formatter().date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid UTC timestamp")
            }
            return date
        }
        return decoder
    }
    package static func timestamp(_ date: Date) -> String { formatter().string(from: date) }
    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}

#if SWIFT_PACKAGE
package enum QualityBuildMetadataAccess {
    package static func encoded(sourceRevision: String, sourceTreeSHA256: String, sourceDirty: Bool,
                                bundledResourcesSHA256: String, bundleSHA256: String,
                                rankingSourceSHA256: String, rankingResourcesSHA256: String,
                                appVersion: String, appBuild: String) throws -> Data {
        try QualityJSON.encoder().encode(QualityBuildMetadata(sourceRevision: sourceRevision,
            sourceTreeSHA256: sourceTreeSHA256, sourceDirty: sourceDirty,
            bundledResourcesSHA256: bundledResourcesSHA256, bundleSHA256: bundleSHA256,
            rankingSourceSHA256: rankingSourceSHA256, rankingResourcesSHA256: rankingResourcesSHA256,
            appVersion: appVersion, appBuild: appBuild))
    }
}
#endif
