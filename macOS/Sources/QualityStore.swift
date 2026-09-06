import Foundation
import CryptoKit
import SQLite3

struct QualityStoreStatistics: Codable, Equatable, Sendable {
    var submitted = 0
    var written = 0
    var droppedQueue = 0
    var droppedOversized = 0
    var droppedBusy = 0
    var droppedInvalid = 0
    var droppedDisabled = 0
    var truncatedEnvelopes = 0
    var peakBuffered = 0
    var buffered = 0
    var errors = 0
    var disabled = false
    var lastErrorCode: Int32? = nil
}

enum QualitySubmission: Equatable, Sendable { case accepted, queueFull, oversized, disabled }
enum QualityStoreFaultPoint: Sendable { case afterComposition, beforeCommit }

/// Test hooks run on the worker only. Production leaves them empty.
struct QualityStoreHooks: Sendable {
    var beforeOpen: (@Sendable () -> Void)? = nil
    var beforeBatch: (@Sendable () -> Void)? = nil
    var fault: (@Sendable (QualityStoreFaultPoint) -> Int32?)? = nil
    var loggedFailure: (@Sendable (Int32) -> Void)? = nil
}

/// The lock protects bounded memory only. The SQLite connection and all encoding belong to queue.
final class QualityStore: @unchecked Sendable {
    let runID: String
    private let queue = DispatchQueue(label: "io.damao.inkflow.quality", qos: .utility)
    private let lock = NSLock()
    private var pending: [(sequence: Int, envelope: QualityEnvelope)] = []
    private var inFlight = 0
    private var acceptedSequence = 0
    private var scheduled = false
    private var accepting = true
    private var stats = QualityStoreStatistics()
    private let database: QualityDatabase
    private let hooks: QualityStoreHooks
    private var timer: DispatchSourceTimer?
    // Worker-only lifecycle state.
    private var ready = false
    private var closed = false

    init(url: URL, engineVersion: String, buildMetadata: QualityBuildMetadata? = nil,
         metadataURL: URL? = nil, hooks: QualityStoreHooks = QualityStoreHooks()) {
        runID = UUID().uuidString
        self.hooks = hooks
        database = QualityDatabase(url: url, runID: runID, engineVersion: engineVersion,
                                   buildMetadata: buildMetadata, metadataURL: metadataURL, hooks: hooks)
        // Queue/timer creation is in-memory; even locating the bundled manifest happens below.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now() + QualityLimits.flushInterval, repeating: QualityLimits.flushInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        queue.async { [weak self] in _ = self?.startIfNeeded() }
    }

    deinit {
        timer?.cancel()
        let database = database
        let statistics = lock.withLock { stats }
        // Never close a connection or write run metadata on the releasing/event thread.
        queue.async { try? database.finish(statistics: statistics, status: "closed") }
    }

    @discardableResult
    func submit(_ envelope: QualityEnvelope) -> QualitySubmission {
        let bounded = envelope.bounded()
        return lock.withLock {
            stats.submitted += 1
            guard accepting && !stats.disabled else { stats.droppedDisabled += 1; return .disabled }
            guard let bounded else { stats.droppedOversized += 1; return .oversized }
            guard pending.count + inFlight < QualityLimits.bufferedEnvelopes else {
                stats.droppedQueue += 1
                return .queueFull
            }
            acceptedSequence += 1
            pending.append((acceptedSequence, bounded))
            stats.buffered = pending.count + inFlight
            stats.peakBuffered = max(stats.peakBuffered, stats.buffered)
            if bounded.composition.pageHistoryTruncated { stats.truncatedEnvelopes += 1 }
            scheduleIfFull()
            return .accepted
        }
    }

    /// Active recorders call this once when their core exceeds the same 64 KiB cap.
    func noteOversizedActiveRecord() {
        lock.withLock { stats.submitted += 1; stats.droppedOversized += 1 }
    }

    func statistics() -> QualityStoreStatistics { lock.withLock { stats } }

    /// Only lifecycle/tests/tools await this. Event handlers must never wait for disk.
    /// Drains the accepted prefix at invocation; later submissions need not have finished.
    func flush() async {
        let target = lock.withLock { acceptedSequence }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                drain(upTo: target)
                saveRunStatistics()
                continuation.resume()
            }
        }
    }

    /// Stops accepting immediately, drains accepted work, saves the run, then closes asynchronously.
    func close() async {
        let target = lock.withLock { accepting = false; return acceptedSequence }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if !closed {
                    timer?.cancel()
                    drain(upTo: target)
                    do { try database.finish(statistics: statistics(), status: statsDisabled ? "disabled" : "closed") }
                    catch { handle(error, count: 0) }
                    closed = true
                }
                continuation.resume()
            }
        }
    }

    private var statsDisabled: Bool { lock.withLock { stats.disabled } }

    /// Caller holds lock; at most one batch wakeup is queued regardless of producer pressure.
    private func scheduleIfFull() {
        guard pending.count >= QualityLimits.batchEnvelopes, !scheduled else { return }
        scheduled = true
        queue.async { [weak self] in
            guard let self else { return }
            self.writeBatch(upTo: Int.max)
            self.lock.withLock {
                self.scheduled = false
                self.scheduleIfFull()
            }
        }
    }

    private func tick() {
        guard !closed && !statsDisabled else { return }
        writeBatch(upTo: Int.max)
        saveRunStatistics()
    }

    private func startIfNeeded() -> Bool {
        guard !closed && !statsDisabled else { return false }
        if ready { return true }
        do {
            try database.start(statistics: statistics())
            ready = true
            return true
        } catch {
            handle(error, count: 0)
            return false
        }
    }

    private func drain(upTo target: Int) {
        guard !closed else { return }
        _ = startIfNeeded()
        while lock.withLock({ pending.first.map { $0.sequence <= target } ?? false }) {
            writeBatch(upTo: target)
        }
    }

    private func writeBatch(upTo target: Int) {
        guard !closed else { return }
        let batch: [QualityEnvelope] = lock.withLock {
            let count = pending.prefix(QualityLimits.batchEnvelopes).prefix { $0.sequence <= target }.count
            let batch = pending.prefix(count).map(\.envelope)
            pending.removeFirst(count)
            inFlight += count
            return batch
        }
        guard !batch.isEmpty else { _ = startIfNeeded(); return }
        defer {
            lock.withLock {
                inFlight -= batch.count
                stats.buffered = pending.count + inFlight
            }
        }
        guard startIfNeeded() else {
            lock.withLock {
                if stats.disabled { stats.droppedDisabled += batch.count }
                else { stats.droppedBusy += batch.count }
            }
            return
        }
        hooks.beforeBatch?()
        do {
            let outcome = try database.write(batch)
            lock.withLock {
                stats.written += outcome.written
                stats.droppedOversized += outcome.oversized
                stats.truncatedEnvelopes += outcome.truncated
            }
        } catch { handle(error, count: batch.count) }
    }

    private func saveRunStatistics() {
        guard ready && !closed && !statsDisabled else { return }
        do { try database.updateRun(statistics: statistics(), status: "running") }
        catch { handle(error, count: 0) }
    }

    private func handle(_ error: Error, count: Int) {
        let code = (error as? QualityDatabaseError)?.code ?? (error is EncodingError ? SQLITE_MISMATCH : SQLITE_IOERR)
        let primary = code & 0xff
        let fatal = primary != SQLITE_BUSY && primary != SQLITE_LOCKED && primary != SQLITE_CONSTRAINT && primary != SQLITE_MISMATCH
        let shouldLog: Bool = lock.withLock {
            stats.errors += 1
            stats.lastErrorCode = code
            if primary == SQLITE_BUSY || primary == SQLITE_LOCKED { stats.droppedBusy += count }
            else if !fatal { stats.droppedInvalid += count }
            else { stats.droppedDisabled += count }
            guard fatal && !stats.disabled else { return false }
            stats.disabled = true
            accepting = false
            stats.droppedDisabled += pending.count
            pending.removeAll()
            stats.buffered = inFlight
            return true
        }
        if shouldLog {
            // No input, SQL, filesystem path, or arbitrary SQLite error text enters logs.
            NSLog("InkFlow quality recording disabled (code %d)", code)
            hooks.loggedFailure?(code)
            var finalStatistics = statistics()
            finalStatistics.buffered = 0
            try? database.finish(statistics: finalStatistics, status: "disabled")
        }
    }
}

private struct QualityDatabaseError: Error { var code: Int32 }

private enum QualitySQLValue {
    case text(String), integer(Int), null
    static func optional(_ value: String?) -> Self { value.map(Self.text) ?? .null }
    static func optional(_ value: Int?) -> Self { value.map(Self.integer) ?? .null }
}

/// All methods and destruction/close are confined to QualityStore's serial worker.
private final class QualityDatabase: @unchecked Sendable {
    private let url: URL
    private let runID: String
    private let engineVersion: String
    private var buildMetadata: QualityBuildMetadata?
    private let metadataURL: URL?
    private let hooks: QualityStoreHooks
    private var connection: OpaquePointer?
    private var runStarted = false
    private var lastSavedStatistics: QualityStoreStatistics?
    private let startedAt = Date()
    private lazy var encoder = QualityJSON.encoder()
    private static let applicationID = 0x49465131 // IFQ1
    private static let unsupportedSchema: Int32 = -1001

    init(url: URL, runID: String, engineVersion: String, buildMetadata: QualityBuildMetadata?,
         metadataURL: URL?, hooks: QualityStoreHooks) {
        self.url = url
        self.runID = runID
        self.engineVersion = engineVersion
        self.buildMetadata = buildMetadata
        self.metadataURL = metadataURL
        self.hooks = hooks
    }

    func start(statistics: QualityStoreStatistics) throws {
        if connection == nil {
            hooks.beforeOpen?()
            if buildMetadata == nil {
                let source = metadataURL ?? Bundle.main.resourceURL?.appendingPathComponent("QualityBuild.json")
                buildMetadata = source.flatMap { try? Data(contentsOf: $0) }
                    .flatMap { try? QualityJSON.decoder().decode(QualityBuildMetadata.self, from: $0) } ?? .unknown
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let code = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
            guard code == SQLITE_OK else {
                if let connection { sqlite3_close(connection); self.connection = nil }
                throw QualityDatabaseError(code: code)
            }
            try check(sqlite3_busy_timeout(connection, 250))
        }
        try validateSchema()
        try execute("PRAGMA foreign_keys = ON")
        guard try scalar("PRAGMA foreign_keys") == "1" else { throw QualityDatabaseError(code: Self.unsupportedSchema) }
        guard try scalar("PRAGMA journal_mode = DELETE") == "delete" else { throw QualityDatabaseError(code: Self.unsupportedSchema) }
        if !runStarted {
            try execute("INSERT INTO recording_runs (id, started_at, status, engine_version, build_metadata_json, metric_rule_version, stats_json) VALUES (?, ?, 'running', ?, ?, ?, ?)",
                        [.text(runID), .text(QualityJSON.timestamp(startedAt)), .text(engineVersion),
                         .text(try json(buildMetadata ?? .unknown)), .integer(QualityLimits.metricRuleVersion), .text(try json(statistics))])
            runStarted = true
            lastSavedStatistics = statistics
        }
    }

    private func validateSchema() throws {
        let version = try scalar("PRAGMA user_version")
        let identity = try scalar("PRAGMA application_id")
        let rows = try query("SELECT name, sql, type FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name")
        if version == "0", identity == "0", rows.isEmpty {
            try execute("BEGIN IMMEDIATE")
            do {
                // Another recorder may have initialized the empty file before this writer lock.
                if try scalar("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") != "0" {
                    rollback()
                    try validateSchema()
                    return
                }
                for sql in Self.schema.values.sorted(by: { left, right in left.hasPrefix("CREATE TABLE") && !right.hasPrefix("CREATE TABLE") }) { try execute(sql) }
                try execute("PRAGMA application_id = \(Self.applicationID)")
                try execute("PRAGMA user_version = 1")
                try execute("COMMIT")
            } catch { rollback(); throw error }
            return
        }
        guard version == "1", identity == String(Self.applicationID), rows.count >= Self.schema.count else {
            throw QualityDatabaseError(code: Self.unsupportedSchema)
        }
        var remaining = Set(Self.schema.keys)
        for row in rows {
            if let expected = Self.schema[row[0]] {
                guard Self.normalize(row[1]) == Self.normalize(expected) else {
                    throw QualityDatabaseError(code: Self.unsupportedSchema)
                }
                remaining.remove(row[0])
            } else {
                // Analysis views and non-unique indexes cannot change inserted records.
                // Extra tables, triggers and unique constraints change the owned contract.
                guard row[2] == "view" || (row[2] == "index" && row[1].uppercased().hasPrefix("CREATE INDEX ")) else {
                    throw QualityDatabaseError(code: Self.unsupportedSchema)
                }
            }
        }
        guard remaining.isEmpty else { throw QualityDatabaseError(code: Self.unsupportedSchema) }
    }

    private static func normalize(_ sql: String) -> String { sql.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    func write(_ batch: [QualityEnvelope]) throws -> (written: Int, oversized: Int, truncated: Int) {
        var accepted: [QualityEnvelope] = []
        var oversized = 0
        var truncated = 0
        for var envelope in batch {
            if try encoder.encode(envelope).count > QualityLimits.envelopeBytes {
                let alreadyTruncated = envelope.composition.pageHistoryTruncated
                envelope.removePageHistory()
                if try encoder.encode(envelope).count > QualityLimits.envelopeBytes { oversized += 1; continue }
                if !alreadyTruncated && envelope.composition.pageHistoryTruncated { truncated += 1 }
            }
            accepted.append(envelope)
        }
        guard !accepted.isEmpty else { return (0, oversized, truncated) }
        try execute("BEGIN IMMEDIATE")
        do {
            for envelope in accepted { try insert(envelope) }
            try inject(.beforeCommit)
            try execute("COMMIT")
            return (accepted.count, oversized, truncated)
        } catch { rollback(); throw error }
    }

    private func insert(_ envelope: QualityEnvelope) throws {
        for revision in envelope.revisions { try insertRevision(revision) }
        let composition = envelope.composition
        try execute("INSERT INTO compositions (id, run_id, started_at, ended_at, app_bundle_id, client_id, outcome, page_history_truncated, dropped_page_count, outcome_reason, operations_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    [.text(composition.id), .text(runID), .text(QualityJSON.timestamp(composition.startedAt)),
                     .text(QualityJSON.timestamp(composition.endedAt)), .optional(composition.appBundleID),
                     .optional(composition.clientID), .text(composition.outcome.rawValue),
                     .integer(composition.pageHistoryTruncated ? 1 : 0), .integer(composition.droppedPageCount),
                     .optional(composition.outcomeReason), .text(try json(composition.operations))])
        try inject(.afterComposition)
        // Commit parents precede decision children; the composite FK prevents cross-composition links.
        for commit in envelope.commits {
            try execute("INSERT INTO commits (id, composition_id, issued_at, text, kind, insertion_issued, client_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        [.text(commit.id), .text(composition.id), .text(QualityJSON.timestamp(commit.issuedAt)),
                         .text(commit.text), .text(commit.kind.rawValue), .integer(commit.insertionIssued ? 1 : 0), .optional(commit.clientID)])
        }
        for decision in envelope.decisions {
            // An unchanged revision can be referenced without re-sending it. Never accept a
            // snapshot whose actual applied values disagree with that revision's saved values.
            for page in [decision.snapshot] + [decision.firstPage].compactMap({ $0 }) + decision.visitedPages {
                guard try scalar("SELECT applied_config_json FROM config_revisions WHERE id = ?", [.text(page.configurationRevisionID)]) == json(page.configuration) else {
                    throw QualityDatabaseError(code: SQLITE_CONSTRAINT)
                }
            }
            try execute("INSERT INTO candidate_decisions (id, composition_id, config_revision_id, commit_id, occurred_at, sequence, trigger, outcome, selected_display_index, selected_text, text_kind, snapshot_json, first_page_json, visited_pages_json, page_history_truncated, dropped_page_count, operations_json, regular_ranked_selection, matches_custom_phrase, unknown_rank_reason, path_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                        [.text(decision.id), .text(composition.id), .text(decision.snapshot.configurationRevisionID),
                         .optional(decision.commitID), .text(QualityJSON.timestamp(decision.occurredAt)), .integer(decision.sequence),
                         .text(decision.trigger.rawValue), .text(decision.outcome.rawValue), .optional(decision.selectedDisplayIndex),
                         .optional(decision.selectedText), .text(decision.textKind.rawValue), .text(try json(decision.snapshot)),
                         try decision.firstPage.map { .text(try json($0)) } ?? .null, .text(try json(decision.visitedPages)),
                         .integer(decision.pageHistoryTruncated ? 1 : 0), .integer(decision.droppedPageCount),
                         .text(try json(decision.operations)), .integer(decision.regularRankedSelection ? 1 : 0),
                         .integer(decision.matchesCustomPhrase ? 1 : 0), .optional(decision.unknownRankReason), .optional(decision.pathReason)])
        }
    }

    private func insertRevision(_ revision: QualityConfigRevision) throws {
        struct Identity: Encodable {
            let configuration: QualityAppliedConfiguration
            let build: QualityBuildMetadata
            let engine: String
            let metricRule: Int
        }
        let fingerprint = SHA256.hash(data: try encoder.encode(Identity(configuration: revision.configuration,
            build: buildMetadata ?? .unknown, engine: engineVersion, metricRule: QualityLimits.metricRuleVersion)))
            .map { String(format: "%02x", $0) }.joined()
        let existing = try scalar("SELECT fingerprint FROM config_revisions WHERE id = ?", [.text(revision.id)])
        if !existing.isEmpty {
            guard existing == fingerprint else { throw QualityDatabaseError(code: SQLITE_CONSTRAINT) }
            return
        }
        try execute("INSERT INTO config_revisions (id, fingerprint, created_at, applied_config_json, build_metadata_json, engine_version, metric_rule_version) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    [.text(revision.id), .text(fingerprint), .text(QualityJSON.timestamp(revision.createdAt)),
                     .text(try json(revision.configuration)), .text(try json(buildMetadata ?? .unknown)),
                     .text(engineVersion), .integer(QualityLimits.metricRuleVersion)])
    }

    func updateRun(statistics: QualityStoreStatistics, status: String) throws {
        guard runStarted else { return }
        if status == "running" && lastSavedStatistics == statistics { return }
        try execute("UPDATE recording_runs SET status = ?, ended_at = ?, stats_json = ?, error_code = ? WHERE id = ?",
                    [.text(status), status == "running" ? .null : .text(QualityJSON.timestamp(Date())),
                     .text(try json(statistics)), statistics.lastErrorCode.map { .integer(Int($0)) } ?? .null, .text(runID)])
        lastSavedStatistics = statistics
    }

    func finish(statistics: QualityStoreStatistics, status: String) throws {
        guard connection != nil else { return }
        rollback()
        defer {
            sqlite3_close(connection)
            connection = nil
            runStarted = false
        }
        // A failed final update still closes the connection. Explicit close reports the
        // failure; fatal/deinitialization cleanup remains best effort.
        try updateRun(statistics: statistics, status: status)
    }

    private func inject(_ point: QualityStoreFaultPoint) throws {
        if let code = hooks.fault?(point) { throw QualityDatabaseError(code: code) }
    }
    private func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    private func rollback() {
        if sqlite3_get_autocommit(connection) == 0 { _ = sqlite3_exec(connection, "ROLLBACK", nil, nil, nil) }
    }
    private func check(_ code: Int32) throws { if code != SQLITE_OK { throw QualityDatabaseError(code: code) } }
    private func execute(_ sql: String, _ values: [QualitySQLValue] = []) throws {
        _ = try query(sql, values)
    }
    private func scalar(_ sql: String, _ values: [QualitySQLValue] = []) throws -> String { try query(sql, values).first?.first ?? "" }
    private func query(_ sql: String, _ values: [QualitySQLValue] = []) throws -> [[String]] {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(connection, sql, -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let parameter = Int32(index + 1)
            switch value {
            case .text(let text):
                try text.withCString { pointer in
                    try check(sqlite3_bind_text(statement, parameter, pointer, Int32(text.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
                }
            case .integer(let number): try check(sqlite3_bind_int64(statement, parameter, Int64(number)))
            case .null: try check(sqlite3_bind_null(statement, parameter))
            }
        }
        var rows: [[String]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { throw QualityDatabaseError(code: code) }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                guard let text = sqlite3_column_text(statement, column) else { return "" }
                return String(decoding: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
            })
        }
    }

    private static let schema: [String: String] = [
        "recording_runs": """
        CREATE TABLE recording_runs (
            id TEXT PRIMARY KEY NOT NULL, started_at TEXT NOT NULL, ended_at TEXT,
            status TEXT NOT NULL, engine_version TEXT NOT NULL, build_metadata_json TEXT NOT NULL,
            metric_rule_version INTEGER NOT NULL, stats_json TEXT NOT NULL, error_code INTEGER
        )
        """,
        "config_revisions": """
        CREATE TABLE config_revisions (
            id TEXT PRIMARY KEY NOT NULL, fingerprint TEXT NOT NULL, created_at TEXT NOT NULL,
            applied_config_json TEXT NOT NULL, build_metadata_json TEXT NOT NULL,
            engine_version TEXT NOT NULL, metric_rule_version INTEGER NOT NULL
        )
        """,
        "compositions": """
        CREATE TABLE compositions (
            id TEXT PRIMARY KEY NOT NULL, run_id TEXT NOT NULL REFERENCES recording_runs(id),
            started_at TEXT NOT NULL, ended_at TEXT NOT NULL, app_bundle_id TEXT, client_id TEXT,
            outcome TEXT NOT NULL, page_history_truncated INTEGER NOT NULL CHECK(page_history_truncated IN (0,1)),
            dropped_page_count INTEGER NOT NULL CHECK(dropped_page_count >= 0),
            outcome_reason TEXT, operations_json TEXT NOT NULL
        )
        """,
        "commits": """
        CREATE TABLE commits (
            id TEXT PRIMARY KEY NOT NULL, composition_id TEXT NOT NULL REFERENCES compositions(id),
            issued_at TEXT NOT NULL, text TEXT NOT NULL, kind TEXT NOT NULL,
            insertion_issued INTEGER NOT NULL CHECK(insertion_issued IN (0,1)), client_id TEXT,
            UNIQUE(id, composition_id)
        )
        """,
        "candidate_decisions": """
        CREATE TABLE candidate_decisions (
            id TEXT PRIMARY KEY NOT NULL, composition_id TEXT NOT NULL REFERENCES compositions(id),
            config_revision_id TEXT NOT NULL REFERENCES config_revisions(id), commit_id TEXT,
            occurred_at TEXT NOT NULL, sequence INTEGER NOT NULL, trigger TEXT NOT NULL, outcome TEXT NOT NULL,
            selected_display_index INTEGER, selected_text TEXT, text_kind TEXT NOT NULL,
            snapshot_json TEXT NOT NULL, first_page_json TEXT, visited_pages_json TEXT NOT NULL,
            page_history_truncated INTEGER NOT NULL CHECK(page_history_truncated IN (0,1)),
            dropped_page_count INTEGER NOT NULL CHECK(dropped_page_count >= 0),
            operations_json TEXT NOT NULL,
            regular_ranked_selection INTEGER NOT NULL CHECK(regular_ranked_selection IN (0,1)),
            matches_custom_phrase INTEGER NOT NULL CHECK(matches_custom_phrase IN (0,1)),
            unknown_rank_reason TEXT, path_reason TEXT,
            UNIQUE(composition_id, sequence),
            FOREIGN KEY(commit_id, composition_id) REFERENCES commits(id, composition_id),
            CHECK(outcome != 'committed' OR commit_id IS NOT NULL)
        )
        """,
        "compositions_time_app": "CREATE INDEX compositions_time_app ON compositions(started_at, app_bundle_id)",
        "decisions_composition": "CREATE INDEX decisions_composition ON candidate_decisions(composition_id)",
        "revisions_fingerprint": "CREATE INDEX revisions_fingerprint ON config_revisions(fingerprint)"
    ]
}
