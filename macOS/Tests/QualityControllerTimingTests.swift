import InputMethodKit
#if SWIFT_PACKAGE
@testable import InkFlowCore
import InkFlowTestSupport
#endif

@MainActor private final class ControllerTime {
    var now: TimeInterval = 100
    var clock: QualityClock { QualityClock(monotonic: { self.now }, utc: { Date(timeIntervalSince1970: 10_000 + self.now) }) }
}

@MainActor private final class TimingPresentation: AIInputPresentation {
    var candidatesVisible = false
    var suggestionVisible = false
    var automaticallyShow = true
    func refreshCandidates(_ candidates: [String], highlight: Int) {
        if candidates.isEmpty { candidatesVisible = false; suggestionVisible = false }
        else if automaticallyShow { candidatesVisible = true }
    }
    func hideCandidates() { candidatesVisible = false; suggestionVisible = false }
    func presentSuggestion(_ text: String) -> Bool { suggestionVisible = candidatesVisible; return suggestionVisible }
    func hideSuggestion() { suggestionVisible = false }
}

private actor TimingService: AISuggestionServing {
    func suggest(input: AISuggestionInput, configuration: AISuggestionConfiguration) async throws -> String { "你好" }
}

extension QualityCaptureTests {
    @MainActor static func controllerTiming(_ output: URL) async throws {
        let db = CaptureDatabase(url: output.appendingPathComponent("controller-timing-" + UUID().uuidString + ".sqlite3"))
        defer { try? FileManager.default.removeItem(at: db.url) }
        let store = QualityStore(url: db.url, engineVersion: IFEngine.version, buildMetadata: qualityCaptureBuildMetadata)
        let aiDB = CaptureDatabase(url: output.appendingPathComponent("controller-ai-" + UUID().uuidString + ".sqlite3"))
        defer { try? FileManager.default.removeItem(at: aiDB.url) }
        let aiStore = AIStatisticsStore(url: aiDB.url, now: { Date(timeIntervalSince1970: 10_000) })
        let isolated = IsolatedSettings(); defer { isolated.cleanup() }
        let settings = isolated.settings
        let time = ControllerTime()
        func fixture(_ endpoint: TimingPresentation = TimingPresentation(), secure: @escaping () -> Bool = { false }) -> (InkFlowInputController, RecordingClient, TimingPresentation) {
            let client = RecordingClient(document: "")
            let control = InkFlowInputController(server: nil, delegate: nil, client: client, settings: settings,
                settingsWindow: IFSettingsWindowController(settings: settings), qualityStore: store, qualityClock: time.clock,
                aiStatisticsStore: aiStore,
                smartService: TimingService(), secureInput: secure, presentation: endpoint)!
            return (control, client, endpoint)
        }
        func near(_ value: Double?, _ expected: Double) -> Bool { value.map { abs($0 - expected) < 0.00001 } ?? false }
        func typeInput(_ control: InkFlowInputController, _ client: RecordingClient) {
            for char in "nihao" {
                time.now += 0.1
                check(control.handle(keyEvent(0, String(char)), client: client))
            }
        }
        for (code, text, kind) in [(UInt16(49), " ", QualityKeyKind.space), (18, "1", .digit), (36, "\r", .returnRaw), (53, "", .escape)] {
            let (control, client, _) = fixture()
            typeInput(control, client)
            let before = control.engine!.qualityRecorder!.timingSnapshot!
            check(before.keySamples.count == 5 && before.keySamples[0].interval == nil)
            check(before.keySamples.dropFirst().allSatisfy { near($0.interval, 0.1) }, "timestamp-zero event fixtures retain injectable clock spacing")
            time.now += 0.4
            client.onMutation = { time.now += 5 }
            check(control.handle(keyEvent(code, text), client: client))
            client.onMutation = nil
            await store.flush()
            let row = db.rows("SELECT * FROM compositions ORDER BY rowid DESC LIMIT 1")[0]
            let ops = db.ops(row)
            check(ops.keypresses == 6 && ops.timing?.keySamples.last?.kind == kind, "actual terminal controller key captured once")
            check(near(ops.timing?.postEditWait, 0.4) && near(ops.timing?.observedVisibleDuration, 0.4), "client insertion/clear processing excluded from dwell")
            check(control.engine?.qualityRecorder?.activeCompositionID == nil)
        }
        do {
            var delay = false
            let (control, client, _) = fixture(secure: { if delay { time.now += 1 }; return false })
            typeInput(control, client); time.now += 0.3
            delay = true
            client.onMutation = { time.now += 5 }
            control.candidateSelected(NSAttributedString(string: control.engine!.snapshot().candidates[0]))
            delay = false; client.onMutation = nil
            await store.flush()
            let ops = db.ops(db.rows("SELECT * FROM compositions ORDER BY rowid DESC LIMIT 1")[0])
            check(ops.keypresses == 5 && near(ops.timing?.postEditWait, 0.3) && near(ops.timing?.observedVisibleDuration, 0.3),
                  "mouse selection freezes at callback entry before validation/insertion, without inventing a key")
        }
        do {
            var delay = false
            let (control, client, _) = fixture(secure: { if delay { time.now += 1 }; return false })
            typeInput(control, client); time.now += 0.3
            delay = true
            check(!control.handle(keyEvent(0, "k", .command), client: client))
            delay = false
            await store.flush()
            let ops = db.ops(db.rows("SELECT * FROM compositions ORDER BY rowid DESC LIMIT 1")[0])
            check(ops.keypresses == 6 && ops.timing?.keySamples.last?.kind == .shortcut && near(ops.timing?.postEditWait, 0.3),
                  "unhandled shortcut's fallback flush retains original key callback entry")
        }
        do {
            let endpoint = TimingPresentation(); endpoint.automaticallyShow = false
            let (control, client, _) = fixture(endpoint)
            typeInput(control, client)
            check(!settings.smart.isEnabled, "ordinary visibility timer is tested with AI disabled")
            let reads = client.requests.count
            time.now += 0.2; endpoint.candidatesVisible = true
            pumpVisibilityTimer()
            time.now += 0.3; endpoint.candidatesVisible = false
            pumpVisibilityTimer()
            check(client.requests.count == reads, "ordinary visibility polling reads no document content")
            time.now += 0.4
            check(control.handle(keyEvent(49, " "), client: client))
            await store.flush()
            let ops = db.ops(db.rows("SELECT * FROM compositions ORDER BY rowid DESC LIMIT 1")[0])
            check(near(ops.timing?.postEditWait, 0.9) && near(ops.timing?.observedVisibleDuration, 0.3), "delayed show and external hide observed without AI timer")
        }
        do {
            try settings.smart.save(baseURL: "https://example.invalid", apiKey: "synthetic", model: "fixture")
            settings.smart.isEnabled = true
            var delayValidation = false
            let (control, client, endpoint) = fixture(secure: {
                if delayValidation { time.now += 1 }
                return false
            })
            typeInput(control, client)
            for _ in 0..<100 where !endpoint.suggestionVisible { try await Task.sleep(for: .milliseconds(20)) }
            check(endpoint.suggestionVisible, "fake AI suggestion reached production controller adoption")
            let originalCompositionID = control.engine!.qualityRecorder!.activeCompositionID!
            time.now += 0.4
            let repeated = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: true, keyCode: 48)!
            check(control.handle(repeated, client: client))
            check(!control.engine!.snapshot().preedit.isEmpty, "held Tab records a key without adoption")
            time.now += 0.2
            delayValidation = true
            client.onMutation = { time.now += 5 }
            check(control.handle(keyEvent(48, "\t"), client: client))
            client.onMutation = nil; delayValidation = false
            await store.flush()
            await aiStore.flush()
            let row = db.rows("SELECT * FROM compositions ORDER BY rowid DESC LIMIT 1")[0]
            let ops = db.ops(row)
            check(row["outcome"] == "committed" && row["outcome_reason"] == "ai_adopted", "AI adoption is explicit ordinary timing ending")
            check(ops.keypresses == 7 && ops.timing?.keySamples.suffix(2).map(\.kind) == [.tab, .aiTab], "repeat Tab and accepted Tab both recorded once")
            check(ops.timing?.keySamples.dropLast().last?.isRepeat == true)
            check(near(ops.timing?.postEditWait, 0.6) && near(ops.timing?.observedVisibleDuration, 0.6), "AI validation and insert callbacks excluded from terminal wait")
            check(db.rows("SELECT * FROM commits WHERE composition_id='" + row["id"]! + "'").isEmpty, "ordinary store does not duplicate AI recommendation text")
            let attempt = aiDB.rows("SELECT * FROM attempts WHERE composition_id='" + originalCompositionID + "'").last!
            check(attempt["dispatch_composition_id"] == originalCompositionID && row["id"] == originalCompositionID, "AI and ordinary DB share immutable composition identity")
            let events = aiDB.rows("SELECT * FROM attempt_events WHERE attempt_id='" + attempt["id"]! + "'")
            for kind in ["shown", "adoptionRequested", "insertionIssued", "insertionReturned"] {
                check(events.filter { $0["kind"] == kind }.count == 1, "actual controller AI lifecycle recorded once")
            }
            let adoptionAt = Double(events.first { $0["kind"] == "adoptionRequested" }!["occurred_at"]!)!
            let lastEditAt = Double(attempt["last_edit_at"]!)!
            check(near(adoptionAt - lastEditAt, 0.6), "AI Tab uses callback-entry UTC before synchronous validation and insertion")
            check(aiDB.rows("SELECT * FROM samples WHERE attempt_id='" + attempt["id"]! + "'")[0]["response_text"] == "你好", "Fake service result still records its real returned recommendation")
            settings.smart.isEnabled = false
        }
        do {
            let (control, client, _) = fixture(secure: { true })
            typeInput(control, client)
            check(control.handle(keyEvent(53, ""), client: client))
            await store.flush()
            check(db.ops(db.rows("SELECT * FROM compositions ORDER BY rowid DESC LIMIT 1")[0]).timing == nil,
                  "secure input does not accrue per-key timing")
        }
        await store.close()
        await aiStore.close()
        check(store.statistics().written == 9 && store.statistics().droppedOversized == 0 && store.statistics().droppedInvalid == 0)
        print("PASS controller timing: real Rime first/final keys, digit/space/return/escape/click/AI Tab, callback time exclusion, delayed visibility without AI and secure input")
    }

    @MainActor private static func pumpVisibilityTimer() {
        let until = Date(timeIntervalSinceNow: 0.15)
        while Date() < until { _ = RunLoop.main.run(mode: .default, before: until) }
    }
}
