import Foundation

/// Values captured in memory. JSON and fingerprinting belong to the store's worker.
struct QualityBuildMetadata: Codable, Equatable, Sendable {
    var sourceRevision: String
    var sourceTreeSHA256: String
    var sourceDirty: Bool?
    var bundledResourcesSHA256: String
    var appVersion: String
    var appBuild: String

    static let unknown = QualityBuildMetadata(sourceRevision: "unknown", sourceTreeSHA256: "unknown",
        sourceDirty: nil, bundledResourcesSHA256: "unknown", appVersion: "unknown", appBuild: "unknown")
}

struct QualityPhrase: Codable, Equatable, Sendable {
    var id: String
    var code: String
    var text: String
}

struct QualityAppliedConfiguration: Codable, Equatable, Sendable {
    var candidateCount: Int
    var customPhrases: [QualityPhrase] = []
    var schemaID = "inkflow_pinyin"
    var asciiMode = false
    var fontSize = 14
    var vertical = false
    /// Nil for records captured before input preferences were available.
    var inputOptions: [String: Bool]? = nil
}

struct QualityConfigRevision: Codable, Equatable, Sendable {
    /// Capture-time identity; the worker adds a stable content fingerprint for comparisons.
    var id = UUID().uuidString
    var configuration: QualityAppliedConfiguration
    var createdAt = Date()
}

/// Text kind is a descriptive output category, never translator provenance.
enum QualityTextKind: String, Codable, Sendable {
    case chinese, english, emoji, mixed, symbol, number, other, unknown

    static func classify(_ text: String) -> Self {
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

struct QualityCandidate: Codable, Equatable, Sendable {
    var text: String
    var comment: String? = nil
    var displayIndex: Int
    var displayRank: Int
    var nativeIndex: Int
    var nativeRank: Int
    var source: String? = nil
    var consumedInputStart: Int? = nil
    var consumedInputEnd: Int? = nil
}

/// Independent of EngineSnapshot equality. Indices/pages are zero-based; ranks are one-based.
struct QualityPageSnapshot: Codable, Equatable, Sendable {
    var generation: Int
    var rawInput: String
    var caret: Int
    var selectedPrefix: String
    var precedingContext: String
    var configurationRevisionID: String
    var configuration: QualityAppliedConfiguration
    var page: Int
    var pageSize: Int
    var candidates: [QualityCandidate]
    var highlightedDisplayIndex: Int
    var selectedPrefixValid = true
    /// Engine observation alone does not establish that a client requested or showed candidates.
    var presentation: QualityPresentation = .notShown
    var capturedAt = Date()
}

enum QualityPresentation: String, Codable, Sendable {
    case notShown = "not_shown", candidatesRequested = "candidates_requested", panelShowIssued = "panel_show_issued"
}

/// Counters are separate facts: an arrow crossing a page increments moves and page turns.
struct QualityOperations: Codable, Equatable, Sendable {
    var keypresses = 0
    var pageRequests = 0
    var pageTurns = 0
    var candidateMoves = 0
    /// Actual Backspace/Delete/caret-edit operations that changed composition state, excluding typing and selection.
    var preeditEdits = 0
    /// Absent in older records or when capture was suppressed. Never interpret absence as zero.
    var timing: QualityTiming? = nil

    mutating func add(_ other: Self) {
        keypresses += other.keypresses
        pageRequests += other.pageRequests
        pageTurns += other.pageTurns
        candidateMoves += other.candidateMoves
        preeditEdits += other.preeditEdits
        // Timing is a phase snapshot, not an additive counter. In particular, do not
        // double-count dwell when a tentative punctuation decision is folded back.
    }
}

enum QualityKeyKind: String, Codable, Sendable {
    case typing, backspace, delete, caret, candidateMove = "candidate_move", page
    case space, digit, returnRaw = "return", escape, tab, aiTab = "ai_tab"
    case shortcut, modeToggle = "mode_toggle", other
}

struct QualityKeySample: Codable, Equatable, Sendable {
    var sequence: Int
    /// Seconds at the controller keyDown callback entry (or direct engine call),
    /// on the monotonic timeline relative to QualityTiming.startedAt.
    var offset: TimeInterval
    var interval: TimeInterval?
    var kind: QualityKeyKind
    var isRepeat: Bool
}

/// Composition-level samples and decision-level phase snapshots share this schema.
/// Visibility is observed at refresh/key boundaries and a bounded polling interval;
/// it proves panel visibility at observations, not attention or exact display onset.
struct QualityTiming: Codable, Equatable, Sendable {
    var version = 1
    var startedAt: Date
    var keySamples: [QualityKeySample] = []
    var droppedKeyCount = 0
    var lastEditOffset: TimeInterval? = nil
    var phaseStartedOffset: TimeInterval? = nil
    var endedOffset: TimeInterval? = nil
    var postEditWait: TimeInterval? = nil
    var observedVisibleDuration: TimeInterval? = nil
    /// A partial candidate selection starts a new remaining-input phase without
    /// resetting the whole last-edit-to-final-selection measurements above.
    var phaseWait: TimeInterval? = nil
    var phaseObservedVisibleDuration: TimeInterval? = nil
    var visibilityObservationInterval: TimeInterval? = nil

    var lastEditAt: Date? { lastEditOffset.map { startedAt.addingTimeInterval($0) } }
}

/// One injectable monotonic source for physical key entry, edit, visibility and end.
/// NSEvent timestamps are deliberately not mixed with this clock (fixtures may be zero).
@MainActor
struct QualityClock {
    var monotonic: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var utc: () -> Date = { Date() }
}

enum QualityCompositionOutcome: String, Codable, Sendable {
    case committed, cancelled, interrupted, unknown
}
enum QualityDecisionOutcome: String, Codable, Sendable {
    case tentative, committed, reverted, edited, cancelled, interrupted, unknown
}
enum QualityTrigger: String, Codable, Sendable {
    case digit, space, panel, returnRaw = "return_raw", punctuation
    case forceFlush = "force_flush", modeToggle = "mode_toggle", other
}
enum QualityCommitKind: String, Codable, Sendable {
    case candidate, punctuation, rawReturn = "raw_return", ascii
    case directSymbol = "direct_symbol", forcedFlush = "forced_flush", modeToggle = "mode_toggle", unknown
}

struct QualityComposition: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    var startedAt = Date()
    var endedAt = Date()
    var appBundleID: String? = nil
    var clientID: String? = nil
    var outcome: QualityCompositionOutcome
    var outcomeReason: String? = nil
    var operations = QualityOperations()
    var pageHistoryTruncated = false
    var droppedPageCount = 0
}

struct QualityDecision: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    var occurredAt = Date()
    var sequence: Int
    var trigger: QualityTrigger
    var outcome: QualityDecisionOutcome
    var selectedDisplayIndex: Int? = nil
    var selectedText: String? = nil
    var textKind: QualityTextKind = .unknown
    var commitID: String? = nil
    var operations = QualityOperations()
    var regularRankedSelection = false
    var matchesCustomPhrase = false
    var unknownRankReason: String? = nil
    var pathReason: String? = nil
    /// Captured before mutation, with the exact order presented for this decision.
    var snapshot: QualityPageSnapshot
    /// Nil means unknown. Never replace with the top candidate of a later page.
    var firstPage: QualityPageSnapshot? = nil
    var visitedPages: [QualityPageSnapshot] = []
    var pageHistoryTruncated = false
    var droppedPageCount = 0
}

struct QualityCommit: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    var issuedAt = Date()
    var text: String
    var kind: QualityCommitKind
    /// An insertText call was issued; this is not independent observation of the document.
    var insertionIssued: Bool
    var clientID: String? = nil
}

struct QualityEnvelope: Codable, Equatable, Sendable {
    var composition: QualityComposition
    var decisions: [QualityDecision] = []
    var commits: [QualityCommit] = []
    var revisions: [QualityConfigRevision] = []

    /// Also use this cap while growing an active recorder, before retaining another snapshot.
    /// Counts strings and collection/record overhead with an early exit, without JSON or I/O.
    func bounded() -> QualityEnvelope? {
        guard decisions.count <= 128, commits.count <= 256, revisions.count <= 256 else { return nil }
        if fitsMemoryBudget { return self }
        var reduced = self
        reduced.removePageHistory()
        return reduced.fitsMemoryBudget ? reduced : nil
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
        var budget = QualityMemoryBudget()
        budget.record(512)
        budget.strings(composition.id, composition.appBundleID, composition.clientID, composition.outcomeReason)
        budget.timing(composition.operations.timing)
        for revision in revisions {
            if budget.exhausted { return false }
            budget.record(256)
            budget.strings(revision.id)
            budget.configuration(revision.configuration)
        }
        for decision in decisions {
            if budget.exhausted { return false }
            budget.record(512)
            budget.strings(decision.id, decision.selectedText, decision.commitID, decision.unknownRankReason, decision.pathReason)
            budget.timing(decision.operations.timing)
            budget.page(decision.snapshot)
            if let first = decision.firstPage { budget.page(first) }
            for page in decision.visitedPages {
                if budget.exhausted { return false }
                budget.page(page)
            }
        }
        for commit in commits {
            if budget.exhausted { return false }
            budget.record(256)
            budget.strings(commit.id, commit.text, commit.clientID)
        }
        return !budget.exhausted
    }
}

enum QualityLimits {
    static let envelopeBytes = 64 * 1024
    static let bufferedEnvelopes = 128
    static let batchEnvelopes = 16
    static let flushInterval: TimeInterval = 1
    static let metricRuleVersion = 1
    static let keySamples = 256
    static let visibilityObservationInterval: TimeInterval = 0.1
}

/// Conservative logical retained-byte budget. The worker separately checks encoded bytes.
private struct QualityMemoryBudget {
    var remaining = QualityLimits.envelopeBytes
    var exhausted: Bool { remaining < 0 }
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
        configuration(value.configuration)
        for candidate in value.candidates {
            guard !exhausted else { return }
            record(256)
            strings(candidate.text, candidate.comment, candidate.source)
        }
    }
}

/// Timestamp JSON uses UTC ISO 8601 with milliseconds, matching SQL's time columns.
enum QualityJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamp(date))
        }
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
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
    static func timestamp(_ date: Date) -> String { formatter().string(from: date) }
    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}
