import Foundation
import SQLite3
#if SWIFT_PACKAGE
@testable import InkFlowCore
import InkFlowAITestSupport
#endif

@main
struct AIStatisticsTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--crash-fixture" {
            let store = AIStatisticsStore(url: URL(fileURLWithPath: CommandLine.arguments[2]))
            let handle = store.begin(configuration: config)
            handle.record(.transportStarted); handle.record(.uiEnded, reason: "inputChanged")
            await store.flush()
            // Exercise real OS lock release without the recorder's graceful close/deinit.
            exit(0)
        }
        let metadata = AIResponseMetadata.parse(Data(#"{"model":"fixture-model","choices":[{"message":{"content":"retained-result"}}],"usage":{"prompt_tokens":250,"completion_tokens":50,"total_tokens":300,"prompt_tokens_details":{"cached_tokens":100},"completion_tokens_details":{"reasoning_tokens":10}}}"#.utf8))
        let rule = AIPriceRule(id: "synthetic-v1", provider: "https://fixture.example", model: "fixture-model", currency: "USD", inputPerMillion: 2, cachedInputPerMillion: Decimal(string: "0.2"), outputPerMillion: 4)
        require(metadata.usage.state == .valid, "Independently decode valid usage")
        require(rule.estimate(metadata.usage) == Decimal(string: "0.00052"), "Cached input and reasoning are subsets")
        require(AIResponseMetadata.parse(Data(#"{"usage":{"prompt_tokens":1,"completion_tokens":2,"prompt_tokens_details":{"cached_tokens":3}}}"#.utf8)).usage.state == .invalid, "Reject cache greater than input")
        require(AIResponseMetadata.parse(Data(#"{"choices":{}}"#.utf8)).usage.state == .missing, "Missing metadata remains unknown")
        for usage in [#"{"prompt_tokens":true,"completion_tokens":2}"#, #"{"prompt_tokens":-1,"completion_tokens":2}"#,
                      #"{"prompt_tokens":1.5,"completion_tokens":2}"#, #"{"prompt_tokens":1,"completion_tokens":2,"total_tokens":4}"#,
                      #"{"prompt_tokens":10,"completion_tokens":2,"prompt_cache_miss_tokens":99}"#,
                      #"{"prompt_tokens":10,"completion_tokens":2,"prompt_tokens_details":{"cached_tokens":6},"prompt_cache_miss_tokens":5}"#,
                      #"{"prompt_tokens":1,"completion_tokens":2,"completion_tokens_details":{"reasoning_tokens":3}}"#] {
            require(AIResponseMetadata.parse(Data("{\"usage\":\(usage)}".utf8)).usage.state == .invalid, "Reject inconsistent or malformed usage")
        }
        require(rule.estimate(.init(state: .valid, prompt: 10, completion: 20)) == nil, "Missing cache usage must not guess discounted cost")
        let huge = String(repeating: "👨‍👩‍👧‍👦", count: 1000)
        let hugeData = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": huge]]], "usage": ["prompt_tokens": 10, "completion_tokens": 20]])
        let bounded = AIResponseMetadata.parse(hugeData)
        require(bounded.usage.state == .valid && bounded.textTruncated && bounded.text!.utf8.count <= 16_384 && huge.hasPrefix(bounded.text!), "Long Unicode samples stay bounded without losing usage or inventing text")
        try await persistence(metadata: metadata, rule: rule)
        try await writerFailures()
        print("PASS AI statistics usage and pricing")
    }

    static let config = AIConfigurationSnapshot(strategyVersion: "fixture-strategy", promptVersion: "fixture-v1", promptTemplate: "Synthetic static prompt only.",
        provider: "https://fixture.example", requestedModel: "fixture-model", maxTokens: 256, stream: false, thinkingDisabled: false)

    static func persistence(metadata: AIResponseMetadata, rule: AIPriceRule) async throws {
        let root = URL(fileURLWithPath: "build/ai-statistics-evidence").appendingPathComponent("writer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = AIStatisticsTestDatabase(url: root.appendingPathComponent("ai-statistics.sqlite3"))
        let time = AIStatisticsTestTime()
        let store = AIStatisticsStore(url: db.url, pricing: .init(version: 1, rules: [rule]), buildIdentity: "synthetic-build", now: { time.now })
        let association = AIStatisticsAssociation(compositionID: "ordinary-fixture", appBundleID: "test.fixture", lastEditAt: time.now - 0.5,
            lastEditMonotonic: time.stamp.monotonic - 0.5, observedVisibleAfterEdit: 0.3, candidates: ["retained-result", "candidate-only-secret"], candidatePage: 0)
        let attempt = store.begin(at: time.stamp, configuration: config, association: association)
        attempt.dispatch(.init(preceding: "preceding-only-secret", following: "following-only-secret", pinyin: "fixturepinyin", selectedPrefix: ""), association: association, at: time.stamp)
        attempt.record(.transportStarted, at: time.stamp)
        attempt.record(.uiEnded, at: time.stamp, reason: "inputChanged")
        attempt.response(metadata, status: 200, at: time.stamp)
        attempt.record(.transportEnded, at: time.stamp, reason: "succeeded")
        attempt.returned("retained-result", at: time.stamp)
        attempt.record(.shown, at: time.stamp); attempt.record(.shown, at: time.stamp)
        attempt.record(.adoptionRequested, at: time.stamp); attempt.record(.adoptionRequested, at: time.stamp)
        attempt.record(.insertionIssued, at: time.stamp); attempt.record(.insertionIssued, at: time.stamp)
        attempt.record(.insertionReturned, at: time.stamp)
        await store.flush()
        let row = db.rows("SELECT * FROM attempts")[0]
        require(row["estimated_cost"] == "0.00052" && row["currency"] == "USD", "Actual SQLite decimal cost readback")
        require(row["composition_id"] == "ordinary-fixture" && row["dispatch_composition_id"] == "ordinary-fixture", "Original association survives UI ending")
        require(row["matches_first_candidate"] == "1" && row["matches_candidate_page"] == "1" && row["candidate_coverage"] == "current_page", "Retain text-free comparison with captured page")
        require(db.rows("SELECT * FROM attempt_events WHERE kind='shown'").count == 1 && db.rows("SELECT * FROM attempt_events WHERE kind='insertionIssued'").count == 1, "First show and insertion are idempotent")
        require(db.rows("SELECT * FROM samples")[0]["response_text"] == "retained-result", "Bounded response sample retained")
        let textFree = String(describing: db.rows("SELECT * FROM attempts")) + String(describing: db.rows("SELECT * FROM configurations")) + String(describing: db.rows("SELECT * FROM attempt_events"))
        for text in ["retained-result", "preceding-only-secret", "following-only-secret", "candidate-only-secret", "fixturepinyin"] {
            require(!textFree.contains(text), "User text belongs exclusively to samples")
        }
        let second = AIStatisticsStore(url: db.url, now: { time.now })
        await second.flush()
        require(db.scalar("SELECT status FROM recording_runs WHERE id='\(store.runID)'") == "running", "A concurrent live recorder must not be recovered as dead")
        await second.close()

        let unknown = store.begin(at: time.stamp, configuration: config)
        unknown.response(.init(), status: 200, at: time.stamp)
        unknown.record(.uiEnded, at: time.stamp, reason: "invalidResponse")
        await store.flush()
        require(db.scalar("SELECT usage_state FROM attempts WHERE id='\(unknown.id)'") == "missing", "Missing usage is explicit")
        let prefixed = store.begin(at: time.stamp, configuration: config)
        prefixed.dispatch(.init(preceding: "", following: "", pinyin: "nihao", selectedPrefix: "already-selected-"),
                          association: .init(candidates: ["suffix"], candidatePage: 0), at: time.stamp)
        prefixed.returned("already-selected-suffix", at: time.stamp)
        let oversized = store.begin(at: time.stamp, configuration: config)
        let bigData = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": String(repeating: "👨‍👩‍👧‍👦", count: 1000)]]], "usage": ["prompt_tokens": 10, "completion_tokens": 20]])
        oversized.response(.parse(bigData), status: 200, at: time.stamp)
        await store.flush()
        require(db.scalar("SELECT matches_first_candidate FROM attempts WHERE id='\(prefixed.id)'") == "1", "Compare selected prefix plus ordinary candidate with full AI replacement")
        require(db.scalar("SELECT usage_state FROM attempts WHERE id='\(oversized.id)'") == "valid" && db.scalar("SELECT response_truncated FROM attempts WHERE id='\(oversized.id)'") == "1", "Truncating invalid oversized text preserves HTTP and usage rows")
        let canonical = store.begin(at: time.stamp, configuration: config)
        canonical.dispatch(.init(preceding: "", following: "", pinyin: "nihao", selectedPrefix: ""),
                           association: .init(candidates: ["你好"], candidatePage: 0), at: time.stamp)
        canonical.record(.uiEnded, at: time.stamp, reason: "inputChanged")
        let padded = String(repeating: " ", count: 4096) + "你好"
        let paddedData = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": padded]]], "usage": ["prompt_tokens": 10, "completion_tokens": 20]])
        canonical.response(.parse(paddedData), status: 200, at: time.stamp)
        canonical.returned(padded.trimmingCharacters(in: .whitespacesAndNewlines), at: time.stamp)
        canonical.returned("duplicate-must-not-replace", at: time.stamp)
        await store.flush()
        require(db.scalar("SELECT response_text FROM samples WHERE attempt_id='\(canonical.id)'") == "你好", "Actual returned recommendation replaces a whitespace-only truncated raw capture, even after UI end")
        let canonicalRow = db.rows("SELECT * FROM attempts WHERE id='\(canonical.id)'")[0]
        require(canonicalRow["suggestion_length"] == "2" && canonicalRow["matches_first_candidate"] == "1" && canonicalRow["matches_candidate_page"] == "1", "Returned text corrects length and comparison facts")
        require(canonicalRow["response_truncated"] == "1" && canonicalRow["usage_state"] == "valid", "Raw capture truncation and usage remain independent facts")
        require(db.rows("SELECT * FROM configurations").count == 1, "Identical prompt/pricing snapshots are deduplicated")
        let interruptedID = store.begin(at: time.stamp, configuration: config).id
        let endedPending = store.begin(at: time.stamp, configuration: config)
        endedPending.record(.transportStarted, at: time.stamp)
        endedPending.record(.uiEnded, at: time.stamp, reason: "inputChanged")
        await store.close()
        require(db.scalar("SELECT recovery_state FROM attempts WHERE id='\(interruptedID)'") == "closed_incomplete", "Shutdown tail does not pretend rejection")
        require(db.scalar("SELECT recovery_state FROM attempts WHERE id='\(endedPending.id)'") == "closed_incomplete", "Ended UI does not imply completed transport accounting")

        // Synthetic crash run has no OS lock; reopening may recover it, never the live writer above.
        _ = db.rows("INSERT INTO recording_runs(id,started_at,status,counters_json) VALUES ('crashed-fixture',0,'running','{}')", writable: true)
        time.advance(30 * 86400 + 1)
        let reopened = AIStatisticsStore(url: db.url, now: { time.now })
        await reopened.flush()
        require(db.scalar("SELECT status FROM recording_runs WHERE id='crashed-fixture'") == "interrupted", "Unowned prior run is recovered")
        require(db.rows("SELECT * FROM samples").isEmpty, "30-day cleanup deletes all sample fields")
        require(db.scalar("SELECT estimated_cost FROM attempts WHERE id='\(attempt.id)'") == "0.00052", "Numeric cost survives text expiry")
        let old = reopened.begin(at: .init(utc: time.now - 31 * 86400, monotonic: 0), configuration: config)
        old.returned("late-expired-private", at: time.stamp)
        await reopened.close()
        require(db.rows("SELECT * FROM samples").isEmpty, "Late observations cannot recreate expired samples")
        let bytes = try Data(contentsOf: db.url)
        for text in ["retained-result", "preceding-only-secret", "following-only-secret", "candidate-only-secret", "fixturepinyin", "late-expired-private"] {
            require(bytes.range(of: Data(text.utf8)) == nil, "secure_delete scrubs expiring text from SQLite pages")
        }
        // Leave a second fully synthetic, retained writer fixture for the readonly query task.
        let fixture = AIStatisticsStore(url: root.appendingPathComponent("retained-fixture.sqlite3"), pricing: .init(version: 1, rules: [rule]), now: { time.now })
        let retained = fixture.begin(at: time.stamp, configuration: config, association: association)
        retained.dispatch(.init(preceding: "Synthetic prefix", following: "Synthetic suffix", pinyin: "nihao", selectedPrefix: ""), association: association, at: time.stamp)
        retained.response(metadata, status: 200, at: time.stamp); retained.returned("retained-result", at: time.stamp)
        retained.record(.shown, at: time.stamp); retained.record(.uiEnded, at: time.stamp, reason: "commit")
        await fixture.close()
        print("PASS AI statistics SQLite, idempotence, late cost, live writer recovery, expiry; fixtures=\(root.path)")
    }

    static func writerFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inkflow-ai-stats-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = DispatchSemaphore(value: 0)
        let bounded = AIStatisticsStore(url: root.appendingPathComponent("bounded.sqlite3"), capacity: 2, hooks: .init(beforeOpen: { blocker.wait() }))
        var dropped: AIStatisticsHandle?
        for _ in 0..<10 { dropped = bounded.begin(configuration: config) }
        require(bounded.statistics().buffered == 2 && bounded.statistics().droppedQueue == 8, "Queue memory is strictly bounded")
        blocker.signal(); await bounded.flush()
        dropped?.record(.transportStarted); await bounded.close()
        require(bounded.statistics().droppedMissingAttempt == 1, "Events after a queue-dropped begin remain explicit loss, never orphan records")
        let busyURL = root.appendingPathComponent("busy.sqlite3")
        let busy = AIStatisticsStore(url: busyURL)
        await busy.flush()
        var writer: OpaquePointer?
        require(sqlite3_open(busyURL.path, &writer) == SQLITE_OK, "Open isolated competing writer")
        require(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK, "Hold actual SQLite writer lock")
        _ = busy.begin(configuration: config); await busy.flush()
        require(sqlite3_exec(writer, "COMMIT", nil, nil, nil) == SQLITE_OK, "Release isolated writer")
        sqlite3_close(writer); await busy.close()
        require(busy.statistics().droppedBusy == 1 && !busy.statistics().disabled, "Busy writer loss remains observable")
        let invalid = AIStatisticsStore(url: root.appendingPathComponent("oversized.sqlite3"))
        let handle = invalid.begin(configuration: config)
        handle.dispatch(.init(preceding: String(repeating: "x", count: 40_000), following: "", pinyin: "", selectedPrefix: ""), association: .init(), at: .now)
        await invalid.close()
        require(invalid.statistics().droppedOversized == 1, "Oversized sample cannot bypass memory cap")
        let foreign = AIStatisticsTestDatabase(url: root.appendingPathComponent("foreign.sqlite3"))
        _ = foreign.rows("CREATE TABLE unrelated(value TEXT)", writable: true)
        let original = try Data(contentsOf: foreign.url)
        let rejected = AIStatisticsStore(url: foreign.url)
        _ = rejected.begin(configuration: config); await rejected.close()
        require(rejected.statistics().disabled, "Foreign schema fails closed")
        let preserved = try Data(contentsOf: foreign.url)
        require(preserved == original, "Foreign database bytes are preserved")
        let crashDB = AIStatisticsTestDatabase(url: root.appendingPathComponent("crash.sqlite3"))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--crash-fixture", crashDB.url.path]
        try child.run(); child.waitUntilExit()
        require(child.terminationStatus == 0 && crashDB.scalar("SELECT status FROM recording_runs") == "running", "Unclosed child fixture remains a real crash tail")
        let recovering = AIStatisticsStore(url: crashDB.url)
        await recovering.close()
        require(crashDB.scalar("SELECT recovery_state FROM attempts") == "interrupted", "Reopening detects released OS lock and marks pending accounting interrupted")
        require(crashDB.scalar("SELECT reason FROM attempt_events WHERE kind='uiEnded'") == "inputChanged", "Recovery never rewrites the original UI reason")
        print("PASS AI statistics bounded queue, oversized payload, busy and foreign database preservation")
    }
}
