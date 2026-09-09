import Foundation
import CryptoKit
import SQLite3
import Darwin

struct AIStatisticsStoreCounters: Codable, Sendable {
    var submitted = 0
    var written = 0
    var droppedQueue = 0
    var droppedOversized = 0
    var droppedBusy = 0
    var droppedDisabled = 0
    var droppedMissingAttempt = 0
    var errors = 0
    var buffered = 0
    var peakBuffered = 0
    var disabled = false
    var lastErrorCode: Int32?
}

struct AIStatisticsStoreHooks: Sendable {
    var beforeOpen: (@Sendable () -> Void)? = nil
    var beforeWrite: (@Sendable () -> Void)? = nil
    var failWrite: (@Sendable () -> Int32?)? = nil
}

/// Locks protect a bounded command queue only. Encoding, pricing, retention and SQLite
/// live on this worker. A handle never accumulates a mutable in-memory request history.
final class AIStatisticsStore: @unchecked Sendable {
    let runID = UUID().uuidString
    private let worker = DispatchQueue(label: "io.damao.inkflow.ai-statistics", qos: .utility)
    private let lock = NSLock()
    private var pending: [Command] = []
    private var inFlight = 0
    private var scheduled = false
    private var accepting = true
    private var counters = AIStatisticsStoreCounters()
    private var timer: DispatchSourceTimer?
    private let capacity: Int
    private let database: AIStatisticsDatabase
    private let hooks: AIStatisticsStoreHooks
    private var ready = false
    private var closed = false

    private enum Command: Sendable {
        case begin(String, AIStatisticsStamp, AIConfigurationSnapshot, AIStatisticsAssociation)
        case event(String, AIStatisticsStamp, AIStatisticsEvent)
    }

    init(url: URL, pricing: AIPricingConfiguration? = nil, pricingURL: URL? = nil,
         buildIdentity: String = "unknown", capacity: Int = 256,
         now: @escaping @Sendable () -> Date = { Date() }, hooks: AIStatisticsStoreHooks = .init()) {
        self.capacity = max(1, min(1024, capacity)); self.hooks = hooks
        database = AIStatisticsDatabase(url: url, runID: runID, pricing: pricing, pricingURL: pricingURL,
                                        buildIdentity: buildIdentity, now: now)
        let timer = DispatchSource.makeTimerSource(queue: worker)
        self.timer = timer
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        worker.async { [weak self] in _ = self?.start() }
    }

    deinit {
        timer?.cancel()
        let database = database, counters = statistics()
        worker.async { try? database.close(counters: counters) }
    }

    func begin(id: UUID = UUID(), at: AIStatisticsStamp = .now, configuration: AIConfigurationSnapshot,
               association: AIStatisticsAssociation = .init()) -> AIStatisticsHandle {
        enqueue(.begin(id.uuidString, at, configuration, association), oversized:
            configuration.promptTemplate.utf8.count > 16_384 ||
            [configuration.strategyVersion, configuration.promptVersion, configuration.provider, configuration.requestedModel].contains { $0.utf8.count > 256 } ||
            !Self.bounded(association))
        return .init(id: id.uuidString, started: at, store: self)
    }

    func submit(id: String, started: AIStatisticsStamp, event: AIStatisticsEvent) {
        let oversized = event.input.map {
            $0.preceding.utf8.count + $0.following.utf8.count + $0.pinyin.utf8.count + $0.selectedPrefix.utf8.count > 32_768
        } ?? false
        enqueue(.event(id, started, event), oversized: oversized || !(event.association.map(Self.bounded) ?? true) ||
                (event.response?.text?.utf8.count ?? 0) > 16_384 || (event.reason?.utf8.count ?? 0) > 128)
    }

    private static func bounded(_ value: AIStatisticsAssociation) -> Bool {
        value.candidates.count <= 32 && value.candidates.reduce(0) { $0 + $1.utf8.count } <= 16_384 &&
        (value.compositionID?.utf8.count ?? 0) <= 128 && (value.appBundleID?.utf8.count ?? 0) <= 256
    }

    private func enqueue(_ command: Command, oversized: Bool) {
        lock.withLock {
            counters.submitted += 1
            guard accepting && !counters.disabled else { counters.droppedDisabled += 1; return }
            guard !oversized else { counters.droppedOversized += 1; return }
            guard pending.count + inFlight < capacity else { counters.droppedQueue += 1; return }
            pending.append(command)
            counters.buffered = pending.count + inFlight
            counters.peakBuffered = max(counters.peakBuffered, counters.buffered)
            guard !scheduled else { return }
            scheduled = true
            worker.async { [weak self] in self?.drain() }
        }
    }

    func statistics() -> AIStatisticsStoreCounters { lock.withLock { counters } }

    func flush() async {
        await withCheckedContinuation { continuation in
            worker.async { [self] in drain(); tick(); continuation.resume() }
        }
    }

    func close() async {
        lock.withLock { accepting = false }
        await withCheckedContinuation { continuation in
            worker.async { [self] in
                if !closed {
                    timer?.cancel(); drain()
                    do { try database.close(counters: statistics()) } catch { failure(error, count: 0) }
                    closed = true
                }
                continuation.resume()
            }
        }
    }

    private func start() -> Bool {
        guard !closed && !statistics().disabled else { return false }
        if ready { return true }
        do {
            hooks.beforeOpen?()
            try database.start(counters: statistics()); ready = true; return true
        } catch { failure(error, count: 0); return false }
    }

    private func drain() {
        while true {
            let batch: [Command] = lock.withLock {
                guard !pending.isEmpty else { scheduled = false; return [] }
                let batch = Array(pending.prefix(32)); pending.removeFirst(batch.count)
                inFlight += batch.count; return batch
            }
            guard !batch.isEmpty else { return }
            if start() {
                do {
                    hooks.beforeWrite?()
                    if let code = hooks.failWrite?() { throw AISQLError(code: code) }
                    var missing = 0
                    try database.transaction {
                        for command in batch {
                            switch command {
                            case .begin(let id, let stamp, let configuration, let association):
                                try database.begin(id: id, stamp: stamp, configuration: configuration, association: association)
                            case .event(let id, let started, let event):
                                missing += try database.record(id: id, started: started, event: event)
                            }
                        }
                    }
                    lock.withLock { counters.written += batch.count - missing; counters.droppedMissingAttempt += missing }
                } catch { failure(error, count: batch.count) }
            } else {
                lock.withLock {
                    if counters.disabled { counters.droppedDisabled += batch.count }
                    else { counters.droppedBusy += batch.count }
                }
            }
            lock.withLock { inFlight -= batch.count; counters.buffered = pending.count + inFlight }
        }
    }

    private func tick() {
        guard start() else { return }
        do { try database.cleanup(); try database.save(counters: statistics()) }
        catch { failure(error, count: 0) }
    }

    private func failure(_ error: any Error, count: Int) {
        let code = (error as? AISQLError)?.code ?? SQLITE_ERROR
        let shouldLog = lock.withLock {
            let wasDisabled = counters.disabled
            counters.errors += 1; counters.lastErrorCode = code
            if code == SQLITE_BUSY || code == SQLITE_LOCKED { counters.droppedBusy += count }
            else { counters.disabled = true; counters.droppedDisabled += count }
            return counters.disabled && !wasDisabled
        }
        // Permanent failures may prevent saving the counters themselves. Retain one
        // content-free diagnostic, never an error message, path, SQL, or provider body.
        if shouldLog { NSLog("InkFlow AI statistics recording disabled (code %d)", code) }
    }
}

private struct AISQLError: Error { let code: Int32 }
private enum AISQLValue {
    case text(String), number(Double), integer(Int), null
    static func optional(_ value: String?) -> Self { value.map(Self.text) ?? .null }
    static func optional(_ value: Int?) -> Self { value.map(Self.integer) ?? .null }
    static func optional(_ value: Double?) -> Self { value.map(Self.number) ?? .null }
    static func optional(_ value: Date?) -> Self { value.map { .number($0.timeIntervalSince1970) } ?? .null }
}

private final class AIStatisticsDatabase: @unchecked Sendable {
    private let url: URL
    private let runID: String
    private var pricing: AIPricingConfiguration?
    private let pricingURL: URL?
    private let buildIdentity: String
    private let now: @Sendable () -> Date
    private var connection: OpaquePointer?
    private var recorderLock: Int32 = -1
    private var running = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    static let applicationID = 0x49464131 // IFA1
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    init(url: URL, runID: String, pricing: AIPricingConfiguration?, pricingURL: URL?, buildIdentity: String,
         now: @escaping @Sendable () -> Date) {
        self.url = url; self.runID = runID; self.pricing = (pricing?.rules.count ?? 0) <= 256 ? pricing : nil; self.pricingURL = pricingURL
        self.buildIdentity = String(buildIdentity.prefix(256)); self.now = now
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func start(counters: AIStatisticsStoreCounters) throws {
        if connection == nil {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let code = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
            guard code == SQLITE_OK else { release(); throw AISQLError(code: code) }
            sqlite3_busy_timeout(connection, 100)
        }
        try validateSchema()
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA secure_delete = ON")
        guard try scalar("PRAGMA journal_mode = DELETE") == "delete" else { throw AISQLError(code: -1001) }
        _ = chmod(url.path, 0o600)
        if pricing == nil, let pricingURL, let file = try? FileHandle(forReadingFrom: pricingURL) {
            defer { try? file.close() }
            if let data = try? file.read(upToCount: 128 * 1024 + 1), data.count <= 128 * 1024 {
                pricing = try? decoder.decode(AIPricingConfiguration.self, from: data)
            }
        }
        if !running {
            if recorderLock < 0 {
                recorderLock = Darwin.open(lockPath(runID), O_CREAT | O_RDWR, 0o600)
                guard recorderLock >= 0, flock(recorderLock, LOCK_EX | LOCK_NB) == 0 else { throw AISQLError(code: SQLITE_CANTOPEN) }
            }
            try transaction {
                for row in try query("SELECT id FROM recording_runs WHERE status = 'running'") where row[0] != runID {
                    guard row[0].utf8.count <= 128, row[0].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else { continue }
                    let descriptor = Darwin.open(lockPath(row[0]), O_CREAT | O_RDWR, 0o600)
                    guard descriptor >= 0 else { continue }
                    defer { Darwin.close(descriptor) }
                    // An OS advisory lock, not a timeout/PID guess, protects other live writers.
                    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                        try execute("UPDATE recording_runs SET status = 'interrupted', ended_at = ? WHERE id = ?", [.number(now().timeIntervalSince1970), .text(row[0])])
                        try execute("UPDATE attempts SET recovery_state = 'interrupted' WHERE run_id = ? AND (\(Self.incompletePredicate))", [.text(row[0])])
                        _ = unlink(lockPath(row[0]))
                    }
                }
                try execute("INSERT OR IGNORE INTO recording_runs(id, started_at, status, counters_json) VALUES (?, ?, 'running', ?)", [.text(runID), .number(now().timeIntervalSince1970), .text(try json(counters))])
            }
            running = true
            try cleanup()
        }
    }

    private func lockPath(_ id: String) -> String { url.path + ".recorder-" + id + ".lock" }

    private func validateSchema() throws {
        let version = try scalar("PRAGMA user_version"), identity = try scalar("PRAGMA application_id")
        let rows = try query("SELECT name, sql, type FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")
        if version == "0", identity == "0", rows.isEmpty {
            try transaction {
                guard try scalar("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == "0" else { throw AISQLError(code: SQLITE_BUSY) }
                for (_, sql) in Self.schema.sorted(by: { $0.key < $1.key }) { try execute(sql) }
                try execute("PRAGMA application_id = \(Self.applicationID)")
                try execute("PRAGMA user_version = 1")
            }
        } else {
            guard version == "1", identity == String(Self.applicationID) else { throw AISQLError(code: -1001) }
            var remaining = Set(Self.schema.keys)
            for row in rows {
                if let expected = Self.schema[row[0]] {
                    guard normalize(row[1]) == normalize(expected) else { throw AISQLError(code: -1001) }
                    remaining.remove(row[0])
                } else {
                    guard row[2] == "view" || (row[2] == "index" && row[1].uppercased().hasPrefix("CREATE INDEX ")) else { throw AISQLError(code: -1001) }
                }
            }
            guard remaining.isEmpty else { throw AISQLError(code: -1001) }
        }
    }

    private func normalize(_ sql: String) -> String { sql.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    func begin(id: String, stamp: AIStatisticsStamp, configuration: AIConfigurationSnapshot, association: AIStatisticsAssociation) throws {
        let rule = pricing?.rule(provider: configuration.provider, model: configuration.requestedModel, at: stamp.utc)
        let snapshot = try json(configuration)
        let priceJSON = try rule.map { try json($0) }
        // Identical safe configurations share their static prompt rather than duplicating
        // it for every per-key schedule. The immutable pricing rule is part of this identity.
        let configurationID = SHA256.hash(data: Data((snapshot + "\u{0}" + (priceJSON ?? "") + "\u{0}" + buildIdentity).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let existing = try scalar("SELECT snapshot_json FROM configurations WHERE id = ?", [.text(configurationID)])
        guard existing.isEmpty || existing == snapshot else { throw AISQLError(code: SQLITE_CONSTRAINT) }
        try execute("INSERT OR IGNORE INTO configurations(id, snapshot_json, pricing_json, pricing_version, build_identity) VALUES (?, ?, ?, ?, ?)",
                    [.text(configurationID), .text(snapshot), .optional(priceJSON), rule == nil ? .null : .integer(1), .text(buildIdentity)])
        try execute("INSERT OR IGNORE INTO attempts(id, run_id, configuration_id, scheduled_at, composition_id, app_bundle_id, last_edit_at, last_edit_to_schedule_ms, provider, requested_model, strategy_version) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    [.text(id), .text(runID), .text(configurationID), .number(stamp.utc.timeIntervalSince1970), .optional(association.compositionID),
                     .optional(association.appBundleID), .optional(association.lastEditAt),
                     .optional(association.lastEditMonotonic.map { max(0, stamp.monotonic - $0) * 1000 }),
                     .text(configuration.provider), .text(configuration.requestedModel), .text(configuration.strategyVersion)])
        guard try scalar("SELECT run_id FROM attempts WHERE id = ?", [.text(id)]) == runID else { throw AISQLError(code: SQLITE_CONSTRAINT) }
        guard try scalar("SELECT configuration_id FROM attempts WHERE id = ?", [.text(id)]) == configurationID else { throw AISQLError(code: SQLITE_CONSTRAINT) }
        try record(id: id, started: stamp, event: .init(kind: .scheduled, stamp: stamp))
    }

    @discardableResult
    func record(id: String, started: AIStatisticsStamp, event: AIStatisticsEvent) throws -> Int {
        // A queue-dropped begin never creates a misleading orphan record.
        guard try scalar("SELECT run_id FROM attempts WHERE id = ?", [.text(id)]) == runID else { return 1 }
        try execute("INSERT OR IGNORE INTO attempt_events(attempt_id, kind, occurred_at, elapsed_ms, reason, http_status) VALUES (?, ?, ?, ?, ?, ?)",
                    [.text(id), .text(event.kind.rawValue), .number(event.stamp.utc.timeIntervalSince1970),
                     .number(max(0, event.stamp.monotonic - started.monotonic) * 1000), .optional(event.reason), .optional(event.httpStatus)])
        guard sqlite3_changes(connection) == 1 else { return 0 }
        let retained = now() < started.utc.addingTimeInterval(Self.retention)
        if retained {
            try execute("INSERT OR IGNORE INTO samples(attempt_id, expires_at) VALUES (?, ?)", [.text(id), .number(started.utc.addingTimeInterval(Self.retention).timeIntervalSince1970)])
        }
        if let input = event.input, let association = event.association {
            if retained {
                struct Input: Encodable { let preceding: String; let following: String; let pinyin: String; let selectedPrefix: String }
                try execute("UPDATE samples SET input_json = ?, candidates_json = ? WHERE attempt_id = ?", [
                    .text(try json(Input(preceding: input.preceding, following: input.following, pinyin: input.pinyin, selectedPrefix: input.selectedPrefix))),
                    association.candidatePage == nil ? .null : .text(try json(association.candidates)), .text(id)])
            }
            try execute("UPDATE attempts SET dispatch_composition_id = ?, dispatch_last_edit_at = ?, last_edit_to_dispatch_ms = ?, ordinary_visible_ms = ?, candidate_count = ?, candidate_page = ?, candidate_coverage = ?, pinyin_length = ?, prefix_length = ?, preceding_length = ?, following_length = ?, preceding_available = ?, following_available = ? WHERE id = ?", [
                .optional(association.compositionID), .optional(association.lastEditAt),
                .optional(association.lastEditMonotonic.map { max(0, event.stamp.monotonic - $0) * 1000 }),
                .optional(association.observedVisibleAfterEdit.map { $0 * 1000 }), .optional(association.candidatePage == nil ? nil : association.candidates.count), .optional(association.candidatePage),
                .text(association.candidatePage == nil ? "unavailable" : "current_page"),
                .integer(input.pinyin.count), .integer(input.selectedPrefix.count), .integer(input.preceding.count), .integer(input.following.count),
                .optional(input.precedingAvailable.map { $0 ? 1 : 0 }), .optional(input.followingAvailable.map { $0 ? 1 : 0 }), .text(id)])
        }
        if let response = event.response {
            if event.kind == .responseObserved {
                let ruleJSON = try scalar("SELECT c.pricing_json FROM configurations c JOIN attempts a ON a.configuration_id = c.id WHERE a.id = ?", [.text(id)])
                let rule = try? decoder.decode(AIPriceRule.self, from: Data(ruleJSON.utf8))
                let modelMismatch = response.returnedModel.map { $0 != rule?.model } ?? false
                let cost = modelMismatch ? nil : rule?.estimate(response.usage)
                let reason = response.usage.state != .valid ? "usage_" + response.usage.state.rawValue :
                    (rule == nil ? "price_missing" : (modelMismatch ? "returned_model_mismatch" : (cost == nil ? "cache_usage_or_rate_missing" : "known")))
                try execute("UPDATE attempts SET returned_model = ?, usage_state = ?, prompt_tokens = ?, completion_tokens = ?, cached_tokens = ?, reasoning_tokens = ?, total_tokens = ?, estimated_cost = ?, currency = ?, cost_state = ?, response_oversized = ? WHERE id = ?", [
                    .optional(response.returnedModel), .text(response.usage.state.rawValue), .optional(response.usage.prompt), .optional(response.usage.completion),
                    .optional(response.usage.cached), .optional(response.usage.reasoning), .optional(response.usage.total),
                    .optional(cost.map { NSDecimalNumber(decimal: $0).stringValue }), .optional(rule?.currency), .text(reason), .integer(response.responseOversized ? 1 : 0), .text(id)])
            }
            if let text = response.text {
                // The transport sample precedes validation and can truncate before the
                // useful text (for example, a long leading whitespace run). Prefer the
                // actual service return when it becomes available, even after UI end.
                let returned = event.kind == .serviceReturned
                if retained {
                    let update = returned ? "response_text = ?" : "response_text = COALESCE(response_text, ?)"
                    try execute("UPDATE samples SET \(update) WHERE attempt_id = ?", [.text(text), .text(id)])
                }
                let candidatesJSON = try scalar("SELECT candidates_json FROM samples WHERE attempt_id = ?", [.text(id)])
                let candidates = try? decoder.decode([String].self, from: Data(candidatesJSON.utf8))
                let inputJSON = try scalar("SELECT input_json FROM samples WHERE attempt_id = ?", [.text(id)])
                let input = try? decoder.decode([String: String].self, from: Data(inputJSON.utf8))
                // Rime's current page is the unselected suffix; AI returns the complete
                // replacement, including the already selected prefix. Compare equal scopes.
                let replacements = input?["selectedPrefix"].flatMap { prefix in candidates.map { $0.map { prefix + $0 } } }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let update = returned ? "suggestion_length = ?, matches_first_candidate = ?, matches_candidate_page = ?" :
                    "suggestion_length = COALESCE(suggestion_length, ?), matches_first_candidate = COALESCE(matches_first_candidate, ?), matches_candidate_page = COALESCE(matches_candidate_page, ?)"
                try execute("UPDATE attempts SET \(update), response_truncated = MAX(response_truncated, ?) WHERE id = ?", [
                    .integer(trimmed.count),
                    .optional(response.textTruncated ? nil : replacements?.first.map { $0 == trimmed ? 1 : 0 }),
                    .optional(response.textTruncated ? nil : replacements.map { $0.contains(trimmed) ? 1 : 0 }),
                    .integer(response.textTruncated ? 1 : 0), .text(id)])
            }
        }
        return 0
    }

    func cleanup() throws {
        try execute("DELETE FROM samples WHERE expires_at <= ?", [.number(now().timeIntervalSince1970)])
    }
    func save(counters: AIStatisticsStoreCounters) throws {
        guard running else { return }
        try execute("UPDATE recording_runs SET counters_json = ? WHERE id = ?", [.text(try json(counters)), .text(runID)])
    }
    func close(counters: AIStatisticsStoreCounters) throws {
        defer { release() }
        guard running else { return }
        try transaction {
            try save(counters: counters)
            try execute("UPDATE recording_runs SET status = ?, ended_at = ? WHERE id = ?", [.text(counters.disabled ? "disabled" : "closed"), .number(now().timeIntervalSince1970), .text(runID)])
            try execute("UPDATE attempts SET recovery_state = 'closed_incomplete' WHERE run_id = ? AND (\(Self.incompletePredicate))", [.text(runID)])
        }
    }
    private func release() {
        if let connection { sqlite3_close(connection); self.connection = nil }
        if recorderLock >= 0 { _ = unlink(lockPath(runID)); Darwin.close(recorderLock); recorderLock = -1 }
        running = false
    }
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { _ = sqlite3_exec(connection, "ROLLBACK", nil, nil, nil); throw error }
    }
    private func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    private func execute(_ sql: String, _ values: [AISQLValue] = []) throws { _ = try query(sql, values) }
    private func scalar(_ sql: String, _ values: [AISQLValue] = []) throws -> String { try query(sql, values).first?.first ?? "" }
    private func query(_ sql: String, _ values: [AISQLValue] = []) throws -> [[String]] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else { throw AISQLError(code: prepared) }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1), code: Int32
            switch value {
            case .text(let text): code = text.withCString { sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case .number(let value): code = sqlite3_bind_double(statement, index, value)
            case .integer(let value): code = sqlite3_bind_int64(statement, index, Int64(value))
            case .null: code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else { throw AISQLError(code: code) }
        }
        var rows: [[String]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { throw AISQLError(code: code) }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                guard let bytes = sqlite3_column_text(statement, column) else { return "" }
                return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
            })
        }
    }

    private static let incompletePredicate = """
    NOT EXISTS (SELECT 1 FROM attempt_events e WHERE e.attempt_id = attempts.id AND e.kind = 'uiEnded')
    OR (EXISTS (SELECT 1 FROM attempt_events e WHERE e.attempt_id = attempts.id AND e.kind = 'dispatched')
        AND NOT EXISTS (SELECT 1 FROM attempt_events e WHERE e.attempt_id = attempts.id AND e.kind IN ('serviceReturned','serviceFailed')))
    OR (EXISTS (SELECT 1 FROM attempt_events e WHERE e.attempt_id = attempts.id AND e.kind = 'transportStarted')
        AND NOT EXISTS (SELECT 1 FROM attempt_events e WHERE e.attempt_id = attempts.id AND e.kind = 'transportEnded'))
    """

    private static let schema: [String: String] = [
        "recording_runs": """
        CREATE TABLE recording_runs (
            id TEXT PRIMARY KEY NOT NULL, started_at REAL NOT NULL, ended_at REAL,
            status TEXT NOT NULL, counters_json TEXT NOT NULL
        )
        """,
        "configurations": """
        CREATE TABLE configurations (
            id TEXT PRIMARY KEY NOT NULL, snapshot_json TEXT NOT NULL, pricing_json TEXT, pricing_version INTEGER, build_identity TEXT NOT NULL
        )
        """,
        "attempts": """
        CREATE TABLE attempts (
            id TEXT PRIMARY KEY NOT NULL, run_id TEXT NOT NULL REFERENCES recording_runs(id),
            configuration_id TEXT NOT NULL REFERENCES configurations(id), scheduled_at REAL NOT NULL,
            composition_id TEXT, app_bundle_id TEXT, last_edit_at REAL, last_edit_to_schedule_ms REAL,
            dispatch_composition_id TEXT, dispatch_last_edit_at REAL, last_edit_to_dispatch_ms REAL,
            ordinary_visible_ms REAL, candidate_count INTEGER, candidate_page INTEGER, candidate_coverage TEXT,
            pinyin_length INTEGER, prefix_length INTEGER, preceding_length INTEGER, following_length INTEGER,
            preceding_available INTEGER, following_available INTEGER,
            suggestion_length INTEGER, matches_first_candidate INTEGER, matches_candidate_page INTEGER,
            comparison_scope TEXT NOT NULL DEFAULT 'selected_prefix_plus_current_page',
            provider TEXT NOT NULL, requested_model TEXT NOT NULL, returned_model TEXT, strategy_version TEXT NOT NULL,
            usage_state TEXT NOT NULL DEFAULT 'unobserved', prompt_tokens INTEGER, completion_tokens INTEGER,
            cached_tokens INTEGER, reasoning_tokens INTEGER, total_tokens INTEGER, estimated_cost TEXT,
            currency TEXT, cost_state TEXT NOT NULL DEFAULT 'unobserved',
            response_truncated INTEGER NOT NULL DEFAULT 0, response_oversized INTEGER NOT NULL DEFAULT 0,
            recovery_state TEXT NOT NULL DEFAULT 'none'
        )
        """,
        "attempt_events": """
        CREATE TABLE attempt_events (
            attempt_id TEXT NOT NULL REFERENCES attempts(id), kind TEXT NOT NULL, occurred_at REAL NOT NULL,
            elapsed_ms REAL NOT NULL, reason TEXT, http_status INTEGER, PRIMARY KEY(attempt_id, kind)
        )
        """,
        "samples": """
        CREATE TABLE samples (
            attempt_id TEXT PRIMARY KEY NOT NULL REFERENCES attempts(id), expires_at REAL NOT NULL,
            input_json TEXT, candidates_json TEXT, response_text TEXT
        )
        """,
        "attempts_time_app": "CREATE INDEX attempts_time_app ON attempts(scheduled_at, app_bundle_id)"
    ]
}
