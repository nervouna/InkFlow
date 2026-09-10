import Foundation
import SQLite3

private let qualityTimingBuildMetadata = QualityBuildMetadata(sourceRevision: "test",
    sourceTreeSHA256: String(repeating: "a", count: 64), sourceDirty: false,
    bundledResourcesSHA256: String(repeating: "b", count: 64), bundleSHA256: String(repeating: "c", count: 64),
    rankingSourceSHA256: String(repeating: "d", count: 64), rankingResourcesSHA256: String(repeating: "e", count: 64),
    appVersion: "test", appBuild: "1")

private func expect(_ value: Bool, _ message: String, line: UInt = #line) {
    precondition(value, "FAIL line \(line): \(message)")
}
private func near(_ value: Double?, _ expected: Double) -> Bool {
    value.map { abs($0 - expected) < 0.00001 } ?? false
}
@MainActor private final class Time {
    var now: Double = 100
    var clock: QualityClock { QualityClock(monotonic: { self.now }, utc: { Date(timeIntervalSince1970: 1_000) }) }
}
@main struct QualityTimingTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quality-timing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("quality.sqlite3")
        let store = QualityStore(url: url, engineVersion: "synthetic", buildMetadata: qualityTimingBuildMetadata)
        let time = Time()
        let recorder = QualityRecorder(store: store, clock: time.clock)
        let revision = QualityConfigRevision(configuration: QualityAppliedConfiguration(candidateCount: 5))
        func page(_ raw: String, caret: Int? = nil, prefix: String = "", page: Int = 0) -> QualityPageSnapshot {
            QualityPageSnapshot(generation: 0, rawInput: raw, caret: caret ?? raw.count, selectedPrefix: prefix,
                precedingContext: "", configurationRevisionID: revision.id, configuration: revision.configuration,
                page: page, pageSize: 5, candidates: raw.isEmpty ? [] : [QualityCandidate(text: "你", displayIndex: 0, displayRank: 1, nativeIndex: 0, nativeRank: 1)], highlightedDisplayIndex: 0)
        }
        func action(_ key: Int32, _ before: QualityPageSnapshot, _ after: QualityPageSnapshot, repeatKey: Bool = false) {
            recorder.willMutate(before, revision: revision, action: .key(key, 0, repeatKey))
            recorder.didMutate(after, handled: true)
        }
        action(110, page(""), page("n"))
        let firstID = recorder.activeCompositionID
        expect(firstID != nil && recorder.timingSnapshot?.keySamples.first?.interval == nil, "first key has no cross-composition interval")
        time.now = 100.2; action(105, page("n"), page("ni"))
        time.now = 100.3; recorder.observeCandidateVisibility(true)
        time.now = 100.5; action(0xff56, page("ni"), page("ni", page: 1))
        time.now = 100.6; recorder.observeCandidateVisibility(false)
        time.now = 100.8; recorder.observeCandidateVisibility(true)
        time.now = 101.0
        recorder.willMutate(page("ni"), revision: revision, action: .key(32, 0))
        time.now = 103.0 // Engine / client processing must not count as the user's wait.
        recorder.didMutate(page(""), handled: true)
        recorder.commitDrained("你", insertionIssued: true, clientID: nil)
        expect(recorder.activeCompositionID == nil, "completed composition detaches correlation")
        await store.flush()
        var rows = try operations(url)
        let timing = rows[0].timing!
        expect(timing.keySamples.count == 4, "all first and terminal keys retained")
        expect(timing.keySamples.map(\.kind) == [.typing, .typing, .page, .space], "key categories distinguish navigation")
        expect(near(timing.keySamples.last?.interval, 0.5), "terminal interval uses entry time")
        expect(near(timing.postEditWait, 0.8), "navigation does not reset last edit")
        expect(near(timing.observedVisibleDuration, 0.5), "hidden period excluded")
        expect(near(timing.endedOffset, 1), "selection entry freezes endpoint")
        expect(timing.visibilityObservationInterval == 0.1, "visibility precision is explicit")

        time.now = 110; action(110, page(""), page("n"))
        expect(recorder.activeCompositionID != firstID && recorder.timingSnapshot?.keySamples.first?.interval == nil, "next composition has a fresh identity and interval")
        recorder.observeCandidateVisibility(true)
        time.now = 110.2; action(105, page("n"), page("ni"))
        time.now = 110.5; action(0xff08, page("ni"), page("n"), repeatKey: true)
        time.now = 110.7; action(0xff1b, page("n"), page(""))
        await store.flush(); rows = try operations(url)
        expect(near(rows[1].timing?.postEditWait, 0.2), "backspace resets wait")
        expect(near(rows[1].timing?.observedVisibleDuration, 0.2), "edit restarts visible dwell")
        expect(rows[1].timing?.keySamples[2].isRepeat == true && rows[1].timing?.keySamples.last?.kind == .escape, "repeat and cancellation key preserved")

        time.now = 120; action(110, page(""), page("nihao"))
        recorder.observeCandidateVisibility(true)
        time.now = 120.4
        recorder.willMutate(page("nihao"), revision: revision, action: .select(0, .panel, false))
        recorder.didMutate(page("nihao", prefix: "你"), handled: true)
        time.now = 120.7
        recorder.recordExternalKey(.aiTab, isRepeat: false)
        recorder.finishExternalSelection(reason: "ai_adopted")
        await store.flush(); rows = try operations(url)
        expect(near(rows[2].timing?.postEditWait, 0.7) && near(rows[2].timing?.observedVisibleDuration, 0.7), "whole final wait remains anchored to last actual edit")
        expect(near(rows[2].timing?.phaseWait, 0.3) && near(rows[2].timing?.phaseObservedVisibleDuration, 0.3), "partial selection begins separate remaining-input phase")
        expect(rows[2].timing?.keySamples.last?.kind == .aiTab && rows[2].keypresses == 2, "AI Tab is a physical terminal key")

        time.now = 130; action(110, page(""), page("n"))
        for _ in 0..<(QualityLimits.keySamples + 20) {
            time.now += 0.01; recorder.recordExternalKey(.tab, isRepeat: true)
        }
        time.now += 0.01; action(0xff1b, page("n"), page(""))
        await store.flush(); rows = try operations(url)
        expect(rows[3].timing?.keySamples.count == QualityLimits.keySamples, "bounded sample capture")
        expect(rows[3].timing?.droppedKeyCount == 22, "all omitted keys explicitly counted")
        expect(rows[3].timing?.keySamples.last?.kind == .escape, "bounded capture still retains final key")

        time.now = 140; action(110, page(""), page("n"))
        recorder.setTimingCaptureEnabled(false)
        action(105, page("n"), page("ni")); action(0xff1b, page("ni"), page(""))
        recorder.setTimingCaptureEnabled(true)
        await store.flush(); rows = try operations(url)
        expect(rows[4].timing == nil, "secure-input suppression removes active timing and captures no further samples")
        time.now = 150; action(110, page(""), page("ni"))
        recorder.observeCandidateVisibility(true)
        time.now = 150.2; action(0xff51, page("ni"), page("ni", caret: 1))
        time.now = 150.3; action(0xff51, page("ni", caret: 1), page("ni", caret: 1))
        time.now = 150.7; action(0xff1b, page("ni", caret: 1), page(""))
        await store.flush(); rows = try operations(url)
        expect(near(rows[5].timing?.postEditWait, 0.5), "actual caret movement resets last edit; ineffective movement does not")
        expect(rows[5].timing?.keySamples[1].kind == .caret, "caret editing category recorded")
        time.now = 160; action(110, page(""), page("n"))
        time.now = 160.2
        recorder.willMutate(page("n"), revision: revision, action: .toggle(true))
        recorder.didMutate(page("n"), handled: true)
        time.now = 160.4; action(0xff1b, page("n"), page(""))
        await store.flush(); rows = try operations(url)
        expect(rows[6].timing?.keySamples[1].kind == .modeToggle && rows[6].timing?.keySamples[1].isRepeat == true,
               "mode toggle preserves its physical key repeat flag")
        let legacy = Data(#"{"keypresses":2,"pageRequests":0,"pageTurns":0,"candidateMoves":0,"preeditEdits":0}"#.utf8)
        expect(try QualityJSON.decoder().decode(QualityOperations.self, from: legacy).timing == nil, "legacy missing timing remains unknown")
        await store.close()
        expect(store.statistics().written == 7 && store.statistics().droppedInvalid == 0 && store.statistics().droppedOversized == 0, "timing records survive actual SQLite writer budgets")
        print("PASS quality timing: keys, terminal boundary, edit/navigation, observed visibility, partial/AI selection, secure suppression, bounds, legacy JSON and SQLite roundtrip")
    }

    static func operations(_ url: URL) throws -> [QualityOperations] {
        var db: OpaquePointer?
        expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, "open synthetic DB")
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        expect(sqlite3_prepare_v2(db, "SELECT operations_json FROM compositions ORDER BY rowid", -1, &statement, nil) == SQLITE_OK, "read operations")
        defer { sqlite3_finalize(statement) }
        var result: [QualityOperations] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try QualityJSON.decoder().decode(QualityOperations.self,
                from: Data(String(cString: sqlite3_column_text(statement, 0)).utf8)))
        }
        return result
    }
}
