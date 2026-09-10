import Foundation
import SQLite3

private func expect(_ condition: Bool, _ message: String,
                    file: StaticString = #filePath, line: UInt = #line) {
    if !condition { fatalError("FAIL \(file):\(line) \(message)") }
}

private final class Reader {
    private var db: OpaquePointer?
    init(_ url: URL, writable: Bool = false) throws {
        let flags = writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else { throw TestError.failed }
        sqlite3_busy_timeout(db, 1000)
    }
    deinit { sqlite3_close(db) }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw TestError.failed }
    }
    func rows(_ sql: String) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw TestError.failed }
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw TestError.failed }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                guard let text = sqlite3_column_text(statement, column) else { return "NULL" }
                return String(decoding: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
            })
        }
    }
    func scalar(_ sql: String) throws -> String { try rows(sql).first?.first ?? "" }
}
private enum TestError: Error { case failed }

private let metadata = QualityBuildMetadata(sourceRevision: "source", sourceTreeSHA256: String(repeating: "a", count: 64),
    sourceDirty: true, bundledResourcesSHA256: String(repeating: "b", count: 64),
    bundleSHA256: String(repeating: "c", count: 64), rankingSourceSHA256: String(repeating: "d", count: 64),
    rankingResourcesSHA256: String(repeating: "e", count: 64), appVersion: "0.1.0", appBuild: "1")

private func fixture(_ id: String = UUID().uuidString) -> QualityEnvelope {
    let configuration = QualityAppliedConfiguration(candidateCount: 5)
    let revision = QualityConfigRevision(id: "revision-" + id, configuration: configuration)
    let candidates = [QualityCandidate(text: "你好😀", displayIndex: 0, displayRank: 6, nativeIndex: 2, nativeRank: 8)]
    let snapshot = QualityPageSnapshot(generation: 7, rawInput: "nihao", caret: 5, selectedPrefix: "",
        precedingContext: "测试", configurationRevisionID: revision.id, configuration: configuration,
        page: 1, pageSize: 5, candidates: candidates, highlightedDisplayIndex: 0)
    let commit = QualityCommit(id: "commit-" + id, text: "你好😀", kind: .candidate, insertionIssued: true)
    let decision = QualityDecision(id: "decision-" + id, sequence: 1, trigger: .space,
        outcome: .committed, selectedDisplayIndex: 0, selectedText: "你好😀", textKind: .mixed,
        commitID: commit.id, snapshot: snapshot)
    return QualityEnvelope(composition: QualityComposition(id: id, appBundleID: "test.app", outcome: .committed),
                           decisions: [decision], commits: [commit], revisions: [revision])
}

private func makeURL(_ name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inkflow-quality-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(name + ".sqlite3")
}

private func createV1Database(at url: URL, schemaVersion: Int = 1, committedLiteral: String = "committed") throws {
    let layeredColumns = schemaVersion == 2 ? ", ranking_fingerprint TEXT, settings_fingerprint TEXT, measurement_fingerprint TEXT, build_identity TEXT" : ""
    let layeredIndexes = schemaVersion == 2 ? """
        CREATE INDEX revisions_ranking_fingerprint ON config_revisions(ranking_fingerprint);
        CREATE INDEX revisions_settings_fingerprint ON config_revisions(settings_fingerprint);
        CREATE INDEX revisions_measurement_fingerprint ON config_revisions(measurement_fingerprint);
        CREATE INDEX revisions_build_identity ON config_revisions(build_identity);
        """ : ""
    let writer = try Reader(url, writable: true)
    try writer.execute("""
        PRAGMA application_id = 1229345073;
        PRAGMA user_version = \(schemaVersion);
        CREATE TABLE recording_runs (
            id TEXT PRIMARY KEY NOT NULL, started_at TEXT NOT NULL, ended_at TEXT,
            status TEXT NOT NULL, engine_version TEXT NOT NULL, build_metadata_json TEXT NOT NULL,
            metric_rule_version INTEGER NOT NULL, stats_json TEXT NOT NULL, error_code INTEGER
        );
        CREATE TABLE config_revisions (
            id TEXT PRIMARY KEY NOT NULL, fingerprint TEXT NOT NULL, created_at TEXT NOT NULL,
            applied_config_json TEXT NOT NULL, build_metadata_json TEXT NOT NULL,
            engine_version TEXT NOT NULL, metric_rule_version INTEGER NOT NULL\(layeredColumns)
        );
        CREATE TABLE compositions (
            id TEXT PRIMARY KEY NOT NULL, run_id TEXT NOT NULL REFERENCES recording_runs(id),
            started_at TEXT NOT NULL, ended_at TEXT NOT NULL, app_bundle_id TEXT, client_id TEXT,
            outcome TEXT NOT NULL, page_history_truncated INTEGER NOT NULL CHECK(page_history_truncated IN (0,1)),
            dropped_page_count INTEGER NOT NULL CHECK(dropped_page_count >= 0),
            outcome_reason TEXT, operations_json TEXT NOT NULL
        );
        CREATE TABLE commits (
            id TEXT PRIMARY KEY NOT NULL, composition_id TEXT NOT NULL REFERENCES compositions(id),
            issued_at TEXT NOT NULL, text TEXT NOT NULL, kind TEXT NOT NULL,
            insertion_issued INTEGER NOT NULL CHECK(insertion_issued IN (0,1)), client_id TEXT,
            UNIQUE(id, composition_id)
        );
        CREATE TABLE candidate_decisions (
            id TEXT PRIMARY KEY NOT NULL, composition_id TEXT NOT NULL REFERENCES compositions(id),
            config_revision_id TEXT NOT NULL REFERENCES config_revisions(id), commit_id TEXT,
            occurred_at TEXT NOT NULL, sequence INTEGER NOT NULL, trigger TEXT NOT NULL, outcome TEXT NOT NULL,
            selected_display_index INTEGER, selected_text TEXT, text_kind TEXT NOT NULL,
            snapshot_json TEXT NOT NULL, first_page_json TEXT, visited_pages_json TEXT NOT NULL,
            page_history_truncated INTEGER NOT NULL CHECK(page_history_truncated IN (0,1)),
            dropped_page_count INTEGER NOT NULL CHECK(dropped_page_count >= 0), operations_json TEXT NOT NULL,
            regular_ranked_selection INTEGER NOT NULL CHECK(regular_ranked_selection IN (0,1)),
            matches_custom_phrase INTEGER NOT NULL CHECK(matches_custom_phrase IN (0,1)),
            unknown_rank_reason TEXT, path_reason TEXT, UNIQUE(composition_id, sequence),
            FOREIGN KEY(commit_id, composition_id) REFERENCES commits(id, composition_id),
            CHECK(outcome != '\(committedLiteral)' OR commit_id IS NOT NULL)
        );
        CREATE INDEX compositions_time_app ON compositions(started_at, app_bundle_id);
        CREATE INDEX decisions_composition ON candidate_decisions(composition_id);
        CREATE INDEX revisions_fingerprint ON config_revisions(fingerprint);
        INSERT INTO recording_runs VALUES ('legacy-run','2026-01-01T00:00:00.000Z','2026-01-01T00:00:01.000Z','closed','legacy-engine','{}',1,'{}',NULL);
        INSERT INTO config_revisions (id,fingerprint,created_at,applied_config_json,build_metadata_json,engine_version,metric_rule_version) VALUES ('legacy-revision','legacy-fingerprint','2026-01-01T00:00:00.000Z','{"candidateCount":5,"customPhrases":[],"schemaID":"inkflow_pinyin","asciiMode":false,"fontSize":14,"vertical":false}','{}','legacy-engine',1);
        INSERT INTO compositions VALUES ('legacy-composition','legacy-run','2026-01-01T00:00:00.000Z','2026-01-01T00:00:01.000Z','legacy.app',NULL,'committed',0,0,NULL,'{}');
        INSERT INTO commits VALUES ('legacy-commit','legacy-composition','2026-01-01T00:00:01.000Z','legacy','candidate',1,NULL);
        INSERT INTO candidate_decisions VALUES ('legacy-decision','legacy-composition','legacy-revision','legacy-commit','2026-01-01T00:00:01.000Z',1,'space','committed',0,'legacy','english','{}',NULL,'[]',0,0,'{}',1,0,NULL,NULL);
        CREATE INDEX analysis_time ON compositions(ended_at);
        CREATE VIEW analysis_runs AS SELECT id FROM recording_runs;
        \(layeredIndexes)
        """)
}

@main
struct QualityStoreTests {
    static func main() async throws {
        for count in [0, 1, 20, 50, 200] {
            var sample = fixture("phrases-\(count)")
            let config = QualityAppliedConfiguration(candidateCount: 5, customPhrases: (0..<count).map {
                QualityPhrase(id: "phrase-\($0)", code: "code\($0)", text: "短语\($0)")
            })
            sample.revisions[0].configuration = config
            sample.decisions[0].snapshot.configuration = config
            sample.decisions[0].snapshot.candidates = (0..<5).map {
                QualityCandidate(text: "候选\($0)", displayIndex: $0, displayRank: $0 + 1, nativeIndex: $0, nativeRank: $0 + 1)
            }
            sample.decisions[0].firstPage = sample.decisions[0].snapshot
            sample.decisions[0].visitedPages = Array(repeating: sample.decisions[0].snapshot, count: 8)
            expect(sample.bounded()?.decisions[0].visitedPages.count == 8, "\(count) short phrases preserve eight history pages")
        }
        let url = try makeURL("reopen")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = QualityStore(url: url, engineVersion: "test-engine", buildMetadata: metadata)
        var record = fixture("reopen")
        record.composition.operations = QualityOperations(keypresses: 8, pageRequests: 2, pageTurns: 2, candidateMoves: 1, preeditEdits: 1)
        record.decisions[0].operations = record.composition.operations
        record.decisions[0].regularRankedSelection = true
        record.decisions[0].matchesCustomPhrase = true
        expect(store.submit(record) == .accepted, "submit accepts bounded envelope")
        await store.flush()
        expect(store.statistics().written == 1, "flush persists")
        let reader = try Reader(url)
        expect(try reader.scalar("SELECT count(*) FROM candidate_decisions") == "1", "decision persisted")
        expect(try reader.scalar("PRAGMA journal_mode") == "delete", "rollback journal")
        expect(try reader.scalar("PRAGMA user_version") == "2", "schema v2")
        expect(try reader.scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'") == "5",
               "schema v2 keeps the five-table contract")
        expect(try reader.scalar("SELECT ranking_fingerprint IS NOT NULL AND settings_fingerprint IS NOT NULL AND measurement_fingerprint IS NOT NULL AND build_identity IS NOT NULL FROM config_revisions") == "1",
               "new revisions persist every layered identity")
        let expectedFingerprints = try QualityFingerprints.make(configuration: record.revisions[0].configuration,
            build: metadata, engineVersion: "test-engine", databaseSchemaVersion: 2,
            metricRuleVersion: QualityLimits.metricRuleVersion,
            collectionRuleVersion: QualityLimits.collectionRuleVersion)
        expect(try reader.rows("SELECT ranking_fingerprint, settings_fingerprint, measurement_fingerprint, build_identity FROM config_revisions").first ==
               [expectedFingerprints.ranking, expectedFingerprints.settings, expectedFingerprints.measurement, expectedFingerprints.buildIdentity],
               "stored identities use schema, metric, collection, settings, ranking and build inputs")
        expect(try reader.rows("PRAGMA foreign_key_check").isEmpty, "all foreign keys hold")
        let savedOperations = try reader.scalar("SELECT operations_json FROM candidate_decisions")
        expect(try QualityJSON.decoder().decode(QualityOperations.self, from: Data(savedOperations.utf8)) == record.decisions[0].operations,
               "operation counters persist exactly")
        expect(try reader.scalar("SELECT operations_json FROM compositions") == savedOperations, "composition counters persist")
        expect(try reader.scalar("SELECT regular_ranked_selection || matches_custom_phrase FROM candidate_decisions") == "11",
               "selection scope and phrase matching are separate stored flags")
        let saved = try reader.scalar("SELECT snapshot_json FROM candidate_decisions")
        let decoded = try QualityJSON.decoder(configurations: record.configurationsByID).decode(QualityPageSnapshot.self, from: Data(saved.utf8))
        var expected = record.decisions[0].snapshot
        expected.capturedAt = decoded.capturedAt
        expect(decoded == expected, "rank mapping and Unicode JSON round trip")
        await store.close()
        expect(try reader.scalar("SELECT status FROM recording_runs") == "closed", "orderly close persisted")
        let reopened = QualityStore(url: url, engineVersion: "test-engine", buildMetadata: metadata)
        await reopened.flush()
        expect(try reader.scalar("SELECT count(*) FROM compositions") == "1", "reopen retains data")
        expect(try reader.scalar("SELECT count(*) FROM recording_runs") == "2", "each launch creates a run")
        await reopened.close()
        print("PASS quality store: reopen, Unicode snapshots, native/display ranks, foreign keys, run close")
        try await atomicityAndReaders()
        try await busyLocks()
        try await pressureAndTimer()
        try await budgets()
        try await configurationBudgetsAndReferences()
        try await fatalFaults()
        try await v1Migration()
        try await identityFailures()
        try await nonDestructiveSchemaAndOpen()
        try await metadataAndRevisions()
        print("PASS quality store: 10 persistence/failure groups")
    }
}

private final class Gate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var used = false
    func blockOnce() {
        let shouldBlock = lock.withLock { if used { return false }; used = true; return true }
        guard shouldBlock else { return }
        expect(!Thread.isMainThread, "worker hooks never execute on the main thread")
        entered.signal()
        expect(release.wait(timeout: .now() + 10) == .success, "test worker gate released")
    }
    func wait() { expect(entered.wait(timeout: .now() + 5) == .success, "worker reached gate") }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
    func read() -> Int { lock.withLock { value } }
}

private extension QualityStoreTests {
    static func v1Migration() async throws {
        let url = try makeURL("v1-migration")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try createV1Database(at: url)
        let store = QualityStore(url: url, engineVersion: "test", buildMetadata: metadata)
        expect(store.submit(fixture("after-migration")) == .accepted, "migration stays off producer path")
        await store.close()
        let reader = try Reader(url)
        expect(try reader.scalar("PRAGMA user_version") == "2", "strict v1 migrates to v2")
        expect(try reader.scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'") == "5",
               "migration keeps exactly five owned tables")
        expect(try reader.scalar("SELECT fingerprint FROM config_revisions WHERE id='legacy-revision'") == "legacy-fingerprint",
               "legacy fingerprint remains exact")
        expect(try reader.scalar("SELECT ranking_fingerprint IS NULL AND settings_fingerprint IS NULL AND measurement_fingerprint IS NULL AND build_identity IS NULL FROM config_revisions WHERE id='legacy-revision'") == "1",
               "legacy layered identities remain unknown")
        expect(try reader.scalar("SELECT count(*) FROM recording_runs WHERE id='legacy-run'") == "1" &&
               reader.scalar("SELECT count(*) FROM compositions WHERE id='legacy-composition'") == "1" &&
               reader.scalar("SELECT count(*) FROM commits WHERE id='legacy-commit'") == "1" &&
               reader.scalar("SELECT count(*) FROM candidate_decisions WHERE id='legacy-decision'") == "1",
               "all five legacy table rows survive migration")
        expect(try reader.scalar("SELECT count(*) FROM sqlite_master WHERE name IN ('analysis_time','analysis_runs')") == "2",
               "allowed analysis index and view survive migration")
        expect(try reader.scalar("SELECT count(*) FROM config_revisions WHERE id='revision-after-migration' AND ranking_fingerprint IS NOT NULL AND settings_fingerprint IS NOT NULL AND measurement_fingerprint IS NOT NULL AND build_identity IS NOT NULL") == "1",
               "post-migration revision gets complete layered identities")

        let rollbackURL = try makeURL("v1-migration-rollback")
        defer { try? FileManager.default.removeItem(at: rollbackURL.deletingLastPathComponent()) }
        try createV1Database(at: rollbackURL)
        let before = try Data(contentsOf: rollbackURL)
        let failed = QualityStore(url: rollbackURL, engineVersion: "test", buildMetadata: metadata,
            hooks: QualityStoreHooks(fault: { point in
                if case .beforeMigrationCommit = point { return SQLITE_IOERR }
                return nil
            }))
        await failed.close()
        expect(failed.statistics().disabled, "migration failure disables recording")
        expect(try Data(contentsOf: rollbackURL) == before, "failed migration leaves v1 bytes unchanged")

        let collisionURL = try makeURL("v1-index-collision")
        defer { try? FileManager.default.removeItem(at: collisionURL.deletingLastPathComponent()) }
        try createV1Database(at: collisionURL)
        do {
            let writer = try Reader(collisionURL, writable: true)
            try writer.execute("CREATE INDEX revisions_ranking_fingerprint ON config_revisions(created_at)")
        }
        let collisionStore = QualityStore(url: collisionURL, engineVersion: "test", buildMetadata: metadata)
        await collisionStore.close()
        expect(!collisionStore.statistics().disabled, "analysis index name collision does not block migration")
        let collisionReader = try Reader(collisionURL)
        expect(try collisionReader.scalar("SELECT sql FROM sqlite_master WHERE name='revisions_ranking_fingerprint'").contains("created_at"),
               "colliding analysis index is preserved unchanged")
        expect(try collisionReader.scalar("SELECT count(*) FROM pragma_index_list('config_revisions') AS l JOIN pragma_index_info(l.name) AS i WHERE i.name='ranking_fingerprint'") == "1",
               "migration creates a safe alternate ranking index")
        let collisionReopen = QualityStore(url: collisionURL, engineVersion: "test", buildMetadata: metadata)
        await collisionReopen.close()
        expect(!collisionReopen.statistics().disabled, "migrated alternate layered index validates on reopen")
        print("PASS quality store: strict atomic v1 migration, exact rows, NULL legacy layers, analysis objects, rollback")
    }

    static func identityFailures() async throws {
        let url = try makeURL("identity-failure")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var incomplete = metadata
        incomplete.rankingSourceSHA256 = "unknown"
        let store = QualityStore(url: url, engineVersion: "test", buildMetadata: incomplete)
        expect(store.submit(fixture("identity-a")) == .accepted && store.submit(fixture("identity-b")) == .accepted,
               "identity generation remains deferred from producer")
        await store.close()
        let reader = try Reader(url)
        expect(try reader.scalar("SELECT count(*) FROM compositions") == "0" &&
               reader.scalar("SELECT count(*) FROM config_revisions") == "0",
               "identity failure drops the entire batch without partial rows")
        let stats = store.statistics()
        expect(stats.droppedInvalid == 2 && stats.droppedIdentity == 2 && stats.lastIdentityError == "missing ranking source",
               "identity drop count and bounded reason are diagnosable")
        expect(!stats.disabled, "identity failure does not disable input or future recording attempts")
        let savedStats = try QualityJSON.decoder().decode(QualityStoreStatistics.self,
            from: Data(try reader.scalar("SELECT stats_json FROM recording_runs").utf8))
        expect(savedStats.droppedIdentity == 2 && savedStats.lastIdentityError == "missing ranking source",
               "identity diagnostics persist with the recording run")
        print("PASS quality store: incomplete identity drops whole deferred batch with bounded diagnostics")
    }

    static func configurationBudgetsAndReferences() async throws {
        let url = try makeURL("configuration-budgets")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = QualityStore(url: url, engineVersion: "test", buildMetadata: metadata)
        func configured(_ id: String, count: Int, text: String = "短语") -> QualityEnvelope {
            var value = fixture(id)
            let config = QualityAppliedConfiguration(candidateCount: 5, customPhrases: (0..<count).map {
                QualityPhrase(id: "phrase-\($0)", code: "code\($0)", text: text + "\($0)")
            }, inputOptions: ["tabCandidatePaging": true])
            value.revisions[0].configuration = config
            value.decisions[0].snapshot.configuration = config
            value.decisions[0].snapshot.candidates = (0..<5).map {
                QualityCandidate(text: "候选\($0)", displayIndex: $0, displayRank: $0 + 1, nativeIndex: $0, nativeRank: $0 + 1)
            }
            value.decisions[0].firstPage = value.decisions[0].snapshot
            value.decisions[0].visitedPages = Array(repeating: value.decisions[0].snapshot, count: 8)
            return value
        }
        for count in [0, 1, 20, 50, 200] {
            expect(store.submit(configured("matrix-\(count)", count: count)) == .accepted, "moderate configuration accepted")
        }
        let unicode = configured("unicode-config", count: 200, text: String(repeating: "😀中文\n", count: 12))
        expect(store.submit(unicode) == .accepted, "long Unicode configuration accepted")
        await store.flush()
        let reader = try Reader(url, writable: true)
        expect(store.statistics().written == 6 && store.statistics().truncatedEnvelopes == 0, "logical and compact encoded matrix preserves history")
        expect(try reader.scalar("SELECT count(*) FROM candidate_decisions WHERE json_array_length(visited_pages_json)=8") == "6", "eight persisted pages each")
        let compact = try reader.scalar("SELECT snapshot_json FROM candidate_decisions WHERE composition_id='matrix-200'")
        expect(!compact.contains("\"configuration\":"), "persisted pages omit full applied configuration")
        do {
            _ = try QualityJSON.decoder().decode(QualityPageSnapshot.self, from: Data(compact.utf8))
            expect(false, "compact page must not decode without resolver")
        } catch is DecodingError { }
        let original = configured("matrix-200", count: 200)
        let decoded = try QualityJSON.decoder(configurations: original.configurationsByID).decode(QualityPageSnapshot.self, from: Data(compact.utf8))
        expect(decoded.configuration == original.decisions[0].snapshot.configuration, "explicit resolver restores complete configuration")
        let legacy = try QualityJSON.encoder().encode(decoded)
        expect(try QualityJSON.decoder().decode(QualityPageSnapshot.self, from: legacy) == decoded, "legacy full pages remain decodable")
        var wrongResolver = original.configurationsByID!
        wrongResolver[decoded.configurationRevisionID]!.candidateCount = 9
        do {
            _ = try QualityJSON.decoder(configurations: wrongResolver).decode(QualityPageSnapshot.self, from: legacy)
            expect(false, "legacy configuration must agree with supplied resolver")
        } catch is DecodingError { }
        let legacySQL = String(decoding: legacy, as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        try reader.execute("UPDATE candidate_decisions SET snapshot_json='\(legacySQL)' WHERE composition_id='matrix-200'")
        var reference = configured("reference-only", count: 200)
        reference.decisions[0].snapshot.configurationRevisionID = original.revisions[0].id
        reference.decisions[0].firstPage = reference.decisions[0].snapshot
        reference.decisions[0].visitedPages = Array(repeating: reference.decisions[0].snapshot, count: 8)
        reference.revisions = []
        expect(reference.retainedBytes > 60_000, "reference-only page configuration is charged")
        expect(store.submit(reference) == .accepted, "existing revision may be referenced without resending")
        await store.close()
        let reopened = QualityStore(url: url, engineVersion: "test", buildMetadata: metadata)
        expect(reopened.submit(configured("after-reopen", count: 50)) == .accepted, "mixed legacy and compact database reopens")
        await reopened.flush()
        expect(try reader.scalar("SELECT count(*) FROM compositions") == "8", "legacy and compact records preserved on reopen")
        var missing = reference
        missing.composition.id = "missing-revision"
        missing.decisions[0].snapshot.configurationRevisionID = "missing"
        missing.decisions[0].firstPage = nil
        missing.decisions[0].visitedPages = []
        missing.decisions[0].id = "missing-decision"
        missing.commits = []
        missing.decisions[0].commitID = nil
        missing.decisions[0].outcome = .unknown
        expect(reopened.submit(missing) == .accepted, "missing persisted reference checked on worker")
        await reopened.flush()
        expect(reopened.statistics().droppedInvalid == 1, "missing revision rolls back")
        missing.composition.id = "stored-content-mismatch"
        missing.decisions[0].id = "stored-content-mismatch-decision"
        missing.decisions[0].snapshot.configurationRevisionID = original.revisions[0].id
        missing.decisions[0].snapshot.configuration.candidateCount = 9
        expect(reopened.submit(missing) == .accepted, "reference content validated against existing SQLite revision")
        await reopened.flush()
        expect(reopened.statistics().droppedInvalid == 2, "saved revision content cannot be replaced by reference-only envelope")
        var mismatch = original
        mismatch.decisions[0].visitedPages[0].configuration.candidateCount = 9
        expect(reopened.submit(mismatch) == .invalid, "same ID with conflicting configuration rejected before canonicalization")
        let oversized = configured("large-config", count: 1, text: String(repeating: "x", count: 140_000))
        expect(reopened.submit(oversized) == .oversized, "unique configuration cap applies before removing history")
        var options = fixture("oversized-options")
        options.decisions[0].snapshot.configuration.inputOptions = [String(repeating: "x", count: 140_000): true]
        options.revisions = []
        expect(reopened.submit(options) == .oversized, "reference-only input options count toward unique configuration budget")
        let escaped = configured("escaped-config", count: 1, text: String(repeating: "\u{0}", count: 50_000))
        expect(reopened.submit(escaped) == .accepted, "configuration logical budget permits control fixture")
        await reopened.flush()
        expect(reopened.statistics().droppedOversized == 3 && reopened.statistics().truncatedEnvelopes == 0, "encoded configuration cap drops without misleading history truncation")
        await reopened.close()

        let pressureURL = try makeURL("byte-pressure")
        defer { try? FileManager.default.removeItem(at: pressureURL.deletingLastPathComponent()) }
        let gate = Gate()
        let pressure = QualityStore(url: pressureURL, engineVersion: "test", buildMetadata: metadata,
            hooks: QualityStoreHooks(beforeBatch: { gate.blockOnce() }))
        await pressure.flush()
        for index in 0..<16 { expect(pressure.submit(configured("byte-\(index)", count: 1, text: String(repeating: "x", count: 100_000))) == .accepted, "initial batch accepted") }
        gate.wait()
        let inFlightBytes = pressure.statistics().bufferedBytes
        expect(inFlightBytes > 3_000_000, "in-flight batch retains its byte charge")
        var accepted = 16
        for index in 16..<100 {
            if pressure.submit(configured("byte-\(index)", count: 1, text: String(repeating: "x", count: 100_000))) == .accepted { accepted += 1 }
        }
        expect(accepted < 128 && pressure.statistics().buffered == accepted, "byte cap binds before count cap")
        expect(pressure.statistics().bufferedBytes <= QualityLimits.bufferedBytes, "pending plus in-flight byte cap")
        gate.release.signal()
        await pressure.close()
        expect(pressure.statistics().written == accepted && pressure.statistics().bufferedBytes == 0, "entire accepted charge released after drain")
        print("PASS quality configuration: matrix, Unicode, compact/legacy/mixed reopen, reference integrity, logical/encoded config limits, 8 MiB in-flight queue bound")
    }

    static func atomicityAndReaders() async throws {
        let url = try makeURL("atomicity")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = Gate()
        let store = QualityStore(url: url, engineVersion: "test", buildMetadata: metadata,
            hooks: QualityStoreHooks(fault: { point in
                if case .beforeCommit = point { gate.blockOnce() }
                return nil
            }))
        await store.flush()
        let reader = try Reader(url)
        for index in 0..<16 { expect(store.submit(fixture("atomic-\(index)")) == .accepted, "batch accepts") }
        gate.wait()
        expect(try reader.scalar("SELECT count(*) FROM compositions") == "0", "reader sees no partial compositions")
        expect(try reader.scalar("SELECT count(*) FROM commits") == "0", "reader sees no partial commits")
        gate.release.signal()
        await store.flush()
        expect(try reader.scalar("SELECT count(*) FROM candidate_decisions") == "16", "batch appears atomically")
        var invalid = fixture("invalid-link")
        invalid.decisions[0].commitID = "commit-atomic-0"
        expect(store.submit(invalid) == .accepted, "foreign key validated on worker")
        expect(store.submit(fixture("rolled-back-with-invalid")) == .accepted, "valid peer enters same batch")
        await store.flush()
        expect(store.statistics().droppedInvalid == 2 && !store.statistics().disabled, "invalid batch drops without disabling")
        expect(try reader.scalar("SELECT count(*) FROM compositions") == "16", "cross-composition FK rolls back whole envelope and batch")
        expect(try reader.scalar("SELECT count(*) FROM config_revisions") == "16", "revision insertion rolls back too")
        expect(try reader.rows("PRAGMA foreign_key_check").isEmpty, "no dangling links")
        await store.close()
        print("PASS quality store: atomic batches, concurrent reader visibility, cross-composition FK rollback")
    }

    static func busyLocks() async throws {
        let url = try makeURL("busy")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = QualityStore(url: url, engineVersion: "test", buildMetadata: metadata)
        await store.flush()
        let locker = try Reader(url, writable: true)
        try locker.execute("BEGIN IMMEDIATE")
        expect(store.submit(fixture("write-locked")) == .accepted, "locked DB does not block submit")
        await store.flush()
        expect(store.statistics().droppedBusy == 1 && !store.statistics().disabled, "writer busy drops batch")
        expect(store.statistics().bufferedBytes == 0, "busy failure releases in-flight byte charge")
        try locker.execute("ROLLBACK")
        expect(try locker.scalar("SELECT count(*) FROM compositions") == "0", "busy writes leave no partial data")
        try locker.execute("BEGIN")
        _ = try locker.scalar("SELECT count(*) FROM compositions")
        store.submit(fixture("read-locked"))
        await store.flush()
        expect(store.statistics().droppedBusy == 2 && !store.statistics().disabled, "long reader causes bounded commit busy")
        try locker.execute("COMMIT")
        expect(try locker.scalar("SELECT count(*) FROM config_revisions") == "0", "commit busy rolls back inserted parent rows")
        store.submit(fixture("after-lock"))
        await store.close()
        expect(try locker.scalar("SELECT count(*) FROM compositions") == "1", "next batch recovers after lock release")
        let saved = try QualityJSON.decoder().decode(QualityStoreStatistics.self,
            from: Data(try locker.scalar("SELECT stats_json FROM recording_runs").utf8))
        expect(saved.droppedBusy == 2 && saved.written == 1 && saved.buffered == 0, "run persists drop counters")
        print("PASS quality store: writer lock and reader-held COMMIT busy, rollback, next-batch recovery")
    }

    static func pressureAndTimer() async throws {
        let url = try makeURL("pressure")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = Gate()
        let store = QualityStore(url: url, engineVersion: "test", buildMetadata: metadata,
                                 hooks: QualityStoreHooks(beforeBatch: { gate.blockOnce() }))
        await store.flush()
        for index in 0..<16 { store.submit(fixture("pressure-\(index)")) }
        gate.wait()
        let start = Date()
        for index in 16..<140 { store.submit(fixture("pressure-\(index)")) }
        let elapsed = Date().timeIntervalSince(start)
        let stats = store.statistics()
        expect(stats.buffered == 128 && stats.peakBuffered == 128, "in-flight plus pending is capped at 128")
        expect(stats.droppedQueue == 12, "overflow drops counted")
        expect(elapsed < 0.5, "blocked background work does not block producer")
        gate.release.signal()
        await store.flush()
        expect(store.statistics().written == 128 && store.statistics().buffered == 0, "accepted FIFO prefix drains")
        let reader = try Reader(url)
        expect(try reader.scalar("SELECT count(*) FROM compositions WHERE id = 'pressure-127'") == "1", "last accepted item preserved")
        expect(try reader.scalar("SELECT count(*) FROM compositions WHERE id = 'pressure-128'") == "0", "overflow never written")
        let beforeIdle = try reader.scalar("PRAGMA data_version")
        try await Task.sleep(for: .milliseconds(1300))
        expect(try reader.scalar("PRAGMA data_version") == beforeIdle, "idle timer does not write unchanged bookkeeping")
        store.submit(fixture("timer"))
        try await Task.sleep(for: .milliseconds(1300))
        expect(store.statistics().written == 129, "sub-batch flushes on one-second timer")
        await store.close()
        expect(store.submit(fixture("after-close")) == .disabled, "close rejects future submissions")
        print("PASS quality store: 128 cap includes in-flight, FIFO overflow, 16 batch, 1s timer; producer \(Int(elapsed * 1000)) ms")
    }

    static func budgets() async throws {
        let url = try makeURL("budgets")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = QualityStore(url: url, engineVersion: "test", buildMetadata: metadata)
        var history = fixture("history")
        var first = history.decisions[0].snapshot
        first.page = 0
        first.candidates[0].displayRank = 1
        first.candidates[0].nativeRank = 3
        history.decisions[0].firstPage = first
        history.decisions[0].visitedPages = Array(repeating: history.decisions[0].snapshot, count: 100)
        expect(store.submit(history) == .accepted, "page history trimmed before dropping core")
        var oversized = fixture("oversized")
        oversized.decisions[0].snapshot.rawInput = String(repeating: "x", count: 100_000)
        expect(oversized.bounded() == nil, "active recorder can apply same bounded cap")
        expect(store.submit(oversized) == .oversized, "oversized core dropped")
        var escaped = fixture("escaped")
        escaped.decisions[0].snapshot.rawInput = String(repeating: "\u{0}", count: 15_000)
        expect(store.submit(escaped) == .accepted, "logical budget accepted before JSON encoding")
        store.noteOversizedActiveRecord()
        await store.close()
        let reader = try Reader(url)
        expect(try reader.scalar("SELECT count(*) FROM compositions") == "1", "worker drops encoded oversized core")
        expect(try reader.scalar("SELECT page_history_truncated FROM compositions") == "1", "composition truncation explicit")
        expect(try reader.scalar("SELECT dropped_page_count FROM candidate_decisions") == "100", "removed page count explicit")
        expect(try reader.scalar("SELECT visited_pages_json FROM candidate_decisions") == "[]", "history removed")
        expect(try reader.scalar("SELECT first_page_json IS NOT NULL FROM candidate_decisions") == "1", "first page remains core evidence")
        expect(store.statistics().droppedOversized == 3 && store.statistics().truncatedEnvelopes == 1, "memory, encoded and active drops counted")
        print("PASS quality store: 64 KiB active/queued/encoded caps, history-first truncation, preserved first page")
    }

    static func fatalFaults() async throws {
        for code in [SQLITE_FULL, SQLITE_IOERR, SQLITE_CORRUPT] {
            let url = try makeURL("fatal")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let logged = Counter()
            let store = QualityStore(url: url, engineVersion: "test", buildMetadata: metadata,
                hooks: QualityStoreHooks(fault: { point in
                    if case .afterComposition = point { return code }
                    return nil
                }, loggedFailure: { _ in _ = logged.increment() }))
            store.submit(fixture("fatal-\(code)"))
            await store.flush()
            expect(store.statistics().disabled && store.statistics().lastErrorCode == code, "fatal code disables run")
            expect(store.submit(fixture("disabled-\(code)")) == .disabled, "disabled store rejects later record")
            await store.flush()
            await store.close()
            expect(logged.read() == 1, "fatal logs once")
            let reader = try Reader(url)
            expect(try reader.scalar("SELECT count(*) FROM compositions") == "0", "fatal fault rolls back composition")
            expect(try reader.scalar("SELECT count(*) FROM config_revisions") == "0", "fatal fault rolls back revision")
            expect(try reader.scalar("SELECT status FROM recording_runs") == "disabled", "fatal run status best-effort saved")
        }
        print("PASS quality store: injected FULL, IOERR, CORRUPT rollback and disable/log-once")
    }

    static func nonDestructiveSchemaAndOpen() async throws {
        for setup in ["CREATE TABLE unrelated (value TEXT); INSERT INTO unrelated VALUES ('sentinel')",
                      "PRAGMA user_version = 99", "PRAGMA user_version = 1; PRAGMA application_id = 123"] {
            let url = try makeURL("foreign")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            do { let writer = try Reader(url, writable: true); try writer.execute(setup) }
            let before = try Data(contentsOf: url)
            let store = QualityStore(url: url, engineVersion: "test", buildMetadata: metadata)
            store.submit(fixture())
            await store.close()
            expect(store.statistics().disabled, "foreign or unknown schema disabled")
            expect(try Data(contentsOf: url) == before, "foreign DB bytes unchanged")
        }
        let incompatibleV1 = try makeURL("incompatible-v1")
        defer { try? FileManager.default.removeItem(at: incompatibleV1.deletingLastPathComponent()) }
        try createV1Database(at: incompatibleV1)
        do {
            let writer = try Reader(incompatibleV1, writable: true)
            try writer.execute("CREATE TRIGGER changed_contract AFTER INSERT ON compositions BEGIN DELETE FROM compositions WHERE id = NEW.id; END")
        }
        let incompatibleBefore = try Data(contentsOf: incompatibleV1)
        let incompatible = QualityStore(url: incompatibleV1, engineVersion: "test", buildMetadata: metadata)
        await incompatible.close()
        expect(incompatible.statistics().disabled, "contract-changing v1 database is rejected")
        expect(try Data(contentsOf: incompatibleV1) == incompatibleBefore, "incompatible v1 database bytes remain unchanged")

        for version in [1, 2] {
            let literalURL = try makeURL("incompatible-literal-v\(version)")
            defer { try? FileManager.default.removeItem(at: literalURL.deletingLastPathComponent()) }
            try createV1Database(at: literalURL, schemaVersion: version, committedLiteral: "com mitted")
            let literalBefore = try Data(contentsOf: literalURL)
            let literalStore = QualityStore(url: literalURL, engineVersion: "test", buildMetadata: metadata)
            await literalStore.close()
            expect(literalStore.statistics().disabled, "v\(version) CHECK string literal mutation is rejected")
            expect(try Data(contentsOf: literalURL) == literalBefore, "rejected v\(version) literal mutation remains byte-identical")
        }

        let corrupt = try makeURL("corrupt")
        defer { try? FileManager.default.removeItem(at: corrupt.deletingLastPathComponent()) }
        let original = Data("not a sqlite database".utf8)
        try original.write(to: corrupt)
        let bad = QualityStore(url: corrupt, engineVersion: "test", buildMetadata: metadata)
        await bad.close()
        expect(try bad.statistics().disabled && Data(contentsOf: corrupt) == original, "corrupt database preserved")

        let directoryURL = try makeURL("directory")
        defer { try? FileManager.default.removeItem(at: directoryURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let readonlyURL = try makeURL("unwritable")
        let readonlyParent = readonlyURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readonlyParent.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readonlyParent.path)
            try? FileManager.default.removeItem(at: readonlyParent)
        }
        for url in [URL(fileURLWithPath: "/dev/null/quality.sqlite3"), directoryURL, readonlyURL] {
            let logged = Counter()
            let store = QualityStore(url: url, engineVersion: "test", buildMetadata: metadata,
                hooks: QualityStoreHooks(loggedFailure: { _ in _ = logged.increment() }))
            store.submit(fixture())
            await store.flush()
            await store.close()
            expect(store.statistics().disabled && logged.read() == 1, "pre-open filesystem and sqlite open failures disable once")
        }
        print("PASS quality store: unknown/foreign/corrupt DB preserved, pre-open filesystem and SQLite open failures")
    }

    static func metadataAndRevisions() async throws {
        let url = try makeURL("revisions")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manifest = url.deletingLastPathComponent().appendingPathComponent("QualityBuild.json")
        try QualityJSON.encoder().encode(metadata).write(to: manifest)
        let gate = Gate()
        let store = QualityStore(url: url, engineVersion: "test", metadataURL: manifest,
                                 hooks: QualityStoreHooks(beforeOpen: { gate.blockOnce() }))
        gate.wait()
        expect(!FileManager.default.fileExists(atPath: url.path), "initialization and manifest reading are deferred to worker")
        store.submit(fixture("revision-a"))
        store.submit(fixture("revision-b"))
        gate.release.signal()
        await store.close()
        let reader = try Reader(url)
        expect(try reader.scalar("SELECT count(DISTINCT fingerprint) FROM config_revisions") == "1", "same applied config/build groups across capture IDs")
        let saved = try QualityJSON.decoder().decode(QualityBuildMetadata.self,
            from: Data(try reader.scalar("SELECT build_metadata_json FROM recording_runs").utf8))
        expect(saved == metadata, "background reads exact bundled metadata")
        do {
            let analysis = try Reader(url, writable: true)
            try analysis.execute("CREATE INDEX analysis_time ON compositions(ended_at); CREATE VIEW analysis_runs AS SELECT id FROM recording_runs")
        }
        var changed = metadata
        changed.sourceTreeSHA256 = String(repeating: "f", count: 64)
        let next = QualityStore(url: url, engineVersion: "test", buildMetadata: changed)
        next.submit(fixture("revision-c"))
        await next.close()
        expect(try reader.scalar("SELECT count(DISTINCT fingerprint) FROM config_revisions") == "2", "dirty source differences split revision comparisons")
        expect(try reader.scalar("SELECT count(DISTINCT ranking_fingerprint) FROM config_revisions") == "1",
               "build-only changes retain one ranking identity")
        expect(try reader.scalar("SELECT count(DISTINCT build_identity) FROM config_revisions") == "2",
               "build-only changes retain both traceable build identities")
        let mismatch = QualityStore(url: url, engineVersion: "test", buildMetadata: changed)
        var invalid = fixture("revision-mismatch")
        invalid.revisions[0].configuration.candidateCount = 9
        mismatch.submit(invalid)
        await mismatch.close()
        expect(mismatch.statistics().droppedInvalid == 1, "actual snapshot settings must match saved revision")
        do {
            let writer = try Reader(url, writable: true)
            try writer.execute("CREATE TRIGGER changed_contract AFTER INSERT ON compositions BEGIN DELETE FROM compositions WHERE id = NEW.id; END")
        }
        let before = try Data(contentsOf: url)
        let unsupported = QualityStore(url: url, engineVersion: "test", buildMetadata: changed)
        await unsupported.close()
        expect(unsupported.statistics().disabled, "schema-changing trigger is unsupported")
        expect(try Data(contentsOf: url) == before, "unsupported v1 changes stay untouched")
        print("PASS quality store: background initialization, bundled metadata, stable fingerprints, mismatch rollback, analysis schema compatibility")
    }
}
