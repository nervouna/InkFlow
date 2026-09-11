import Foundation
import CryptoKit

/// Values captured in memory. JSON and fingerprinting belong to the store's worker.
struct QualityBuildMetadata: Codable, Equatable, Sendable {
    var sourceRevision: String
    var sourceTreeSHA256: String
    var sourceDirty: Bool?
    var bundledResourcesSHA256: String
    /// Complete unsigned .app payload, excluding this metadata file and later signing/notarization envelopes.
    /// The legacy resources digest remains for compatibility.
    var bundleSHA256: String = "unknown"
    var rankingSourceSHA256: String = "unknown"
    var rankingResourcesSHA256: String = "unknown"
    var appVersion: String
    var appBuild: String

    static let unknown = QualityBuildMetadata(sourceRevision: "unknown", sourceTreeSHA256: "unknown",
        sourceDirty: nil, bundledResourcesSHA256: "unknown", appVersion: "unknown", appBuild: "unknown")

    private enum CodingKeys: String, CodingKey {
        case sourceRevision, sourceTreeSHA256, sourceDirty, bundledResourcesSHA256, bundleSHA256
        case rankingSourceSHA256, rankingResourcesSHA256, appVersion, appBuild
    }

    init(sourceRevision: String, sourceTreeSHA256: String, sourceDirty: Bool?, bundledResourcesSHA256: String,
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

    init(from decoder: Decoder) throws {
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

struct QualityFingerprints: Equatable, Sendable {
    let ranking: String
    let settings: String
    let measurement: String
    let buildIdentity: String

    static func make(configuration: QualityAppliedConfiguration, build: QualityBuildMetadata,
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

enum QualityIdentityError: Error, Equatable {
    case missing(String)
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

extension QualityPageSnapshot {
    private enum CodingKeys: String, CodingKey {
        case generation, rawInput, caret, selectedPrefix, precedingContext, configurationRevisionID, configuration
        case page, pageSize, candidates, highlightedDisplayIndex, selectedPrefixValid, presentation, capturedAt
    }

    func encode(to encoder: Encoder) throws {
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

    init(from decoder: Decoder) throws {
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
    var configurationsByID: [String: QualityAppliedConfiguration]? { try? validatedConfigurations() }

    enum ConfigurationFailure: Error { case invalid, oversized }

    func validatedConfigurations() throws -> [String: QualityAppliedConfiguration] {
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

    var retainedBytes: Int {
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

enum QualityLimits {
    static let databaseSchemaVersion = 2
    static let envelopeBytes = 64 * 1024
    static let configurationBytes = 256 * 1024
    static let bufferedBytes = 8 * 1024 * 1024
    static let bufferedEnvelopes = 128
    static let batchEnvelopes = 16
    static let flushInterval: TimeInterval = 1
    static let metricRuleVersion = 1
    static let collectionRuleVersion = 1
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
enum QualityJSON {
    static let compactPages = CodingUserInfoKey(rawValue: "quality.compactPages")!
    static let configurationResolver = CodingUserInfoKey(rawValue: "quality.configurationResolver")!
    static func encoder(compact: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.userInfo[compactPages] = compact
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamp(date))
        }
        return encoder
    }
    static func decoder(configurations: [String: QualityAppliedConfiguration]? = nil) -> JSONDecoder {
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
    static func timestamp(_ date: Date) -> String { formatter().string(from: date) }
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
