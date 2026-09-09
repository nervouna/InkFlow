import InputMethodKit
import SQLite3

@MainActor
struct CaptureDatabase {
    let url: URL
    func rows(_ sql: String) -> [[String: String]] {
        var db: OpaquePointer?
        check(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        check(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        defer { sqlite3_finalize(statement) }
        var result: [[String: String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                if let text = sqlite3_column_text(statement, index) {
                    row[String(cString: sqlite3_column_name(statement, index))] = String(cString: text)
                }
            }
            result.append(row)
        }
        return result
    }
    func decisions() -> [[String: String]] { rows("SELECT rowid, * FROM candidate_decisions ORDER BY rowid") }
    func page(_ row: [String: String], _ column: String = "snapshot_json") -> QualityPageSnapshot {
        try! QualityJSON.decoder().decode(QualityPageSnapshot.self, from: Data(row[column]!.utf8))
    }
    func ops(_ row: [String: String]) -> QualityOperations {
        try! QualityJSON.decoder().decode(QualityOperations.self, from: Data(row["operations_json"]!.utf8))
    }
}

@main
struct QualityCaptureTests {
    @MainActor static func main() async throws {
        check(CommandLine.arguments.count == 3)
        let shared = CommandLine.arguments[1]
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let files = FileManager.default
        let scratch = output.appendingPathComponent("capture-" + UUID().uuidString)
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        let db = CaptureDatabase(url: output.appendingPathComponent("engine-controller.sqlite3"))
        if files.fileExists(atPath: db.url.path) { try files.removeItem(at: db.url) }
        let store = QualityStore(url: db.url, engineVersion: IFEngine.version, buildMetadata: .unknown)
        try IFEngine.start(shared: shared, user: scratch.appendingPathComponent("rime").path)
        IFStubHeadlessControllerFramework()
        let isolated = IsolatedSettings()
        defer { isolated.cleanup() }
        classification()
        pureSnapshots()
        try await engineAndController(store, db, isolated.settings)
        try await controllerTiming(output)
        let pagingDB = CaptureDatabase(url: output.appendingPathComponent("paging-settings.sqlite3"))
        if files.fileExists(atPath: pagingDB.url.path) { try files.removeItem(at: pagingDB.url) }
        let pagingStore = QualityStore(url: pagingDB.url, engineVersion: IFEngine.version, buildMetadata: .unknown)
        await pagingSettings(pagingStore, pagingDB)
        await pagingStore.close()
        let syntheticDB = CaptureDatabase(url: output.appendingPathComponent("recorder-synthetic.sqlite3"))
        if files.fileExists(atPath: syntheticDB.url.path) { try files.removeItem(at: syntheticDB.url) }
        let syntheticStore = QualityStore(url: syntheticDB.url, engineVersion: "synthetic", buildMetadata: .unknown)
        await synthetic(syntheticStore, syntheticDB)
        await syntheticStore.close()
        await store.close()
        check(store.statistics().droppedInvalid == 0 && store.statistics().errors == 0,
              "All real envelopes must satisfy the store contract: \(store.statistics())")
        IFEngine.stop()
        try await equivalence(shared: shared, scratch: scratch)
        try await stalledWriter(shared: shared, scratch: scratch)
        print("PASS quality capture: actual engine/controller SQLite evidence at \(db.url.path)")
    }

    @MainActor static func controller(_ settings: IFSettings, _ client: RecordingClient?, _ store: QualityStore?) -> InkFlowInputController {
        InkFlowInputController(server: nil, delegate: nil, client: client, settings: settings,
            settingsWindow: IFSettingsWindowController(settings: settings), qualityStore: store)!
    }
    @MainActor static func input(_ text: String, _ controller: InkFlowInputController, _ client: RecordingClient?) {
        for character in text { check(controller.handle(keyEvent(0, String(character)), client: client)) }
    }
    @MainActor static func digit(_ index: Int, _ controller: InkFlowInputController, _ client: RecordingClient?) {
        check(controller.handle(keyEvent(18, String(index + 1)), client: client))
    }
    @MainActor static func classification() {
        for (text, kind) in [("中文", QualityTextKind.chinese), ("hello", .english), ("这份offer", .mixed),
                             ("❤️", .emoji), ("🇨🇳", .emoji), ("👨‍⚕️", .emoji), ("1️⃣", .emoji),
                             ("123", .number), ("，！？", .symbol), ("é", .other)] {
            check(QualityTextKind.classify(text) == kind, text)
        }
        print("PASS text kinds: Chinese/English/mixed/emoji/symbol/number/other; bare digits are not emoji")
    }
    @MainActor static func pureSnapshots() {
        let engine = IFEngine()!
        check(engine.qualityRecorder == nil, "Tests/direct starts must not enable a production recorder")
        type(engine, "nihao")
        let before = engine.snapshot()
        for _ in 0..<10 {
            let quality = engine.qualitySnapshot()
            check(quality.rawInput == "nihao" && quality.caret == 5 && quality.selectedPrefix.isEmpty)
            check(quality.pageSize == 5 && quality.candidates.map(\.text) == before.candidates)
            check(quality.candidates.allSatisfy { $0.source == nil && $0.consumedInputStart == nil && $0.consumedInputEnd == nil })
        }
        check(engine.snapshot() == before)
        engine.key(32)
        for _ in 0..<10 { _ = engine.qualitySnapshot() }
        check(engine.takeCommit() == "你好" && engine.takeCommit().isEmpty, "Observation must not drain commits")
        print("PASS pure snapshots: no order/highlight/preedit mutation and no commit drain")
    }

    @MainActor static func engineAndController(_ store: QualityStore, _ db: CaptureDatabase, _ settings: IFSettings) async throws {
        for size in [3, 5, 9] {
            settings.candidateCount = size
            let client = RecordingClient(document: "")
            let control = controller(settings, client, store)
            input("shi", control, client)
            let first = control.engine!.qualitySnapshot()
            check(control.handle(keyEvent(121, ""), client: client))
            let second = control.engine!.qualitySnapshot()
            check(second.page == 1 && second.pageSize == size)
            let expected = second.candidates[0].text
            digit(0, control, client)
            check(client.document == expected)
            control.commitComposition(client); control.deactivateServer(client)
            await store.flush()
            let row = db.decisions().last!
            let captured = db.page(row)
            check(captured.pageSize == size && captured.candidates[0].displayRank == size + 1)
            check(captured.candidates[0].nativeRank == size + second.candidates[0].nativeIndex + 1)
            check(db.page(row, "first_page_json").candidates == first.candidates)
            check(db.page(row, "first_page_json").generation == captured.generation)
            check(row["outcome"] == "committed" && row["selected_display_index"] == "0")
            check(captured.presentation == .candidatesRequested)
            check(db.ops(row).pageRequests == 1 && db.ops(row).pageTurns == 1)
        }
        settings.candidateCount = 3
        do {
            let client = RecordingClient(document: "")
            let control = controller(settings, client, store)
            input("shi", control, client)
            for _ in 0..<3 { check(control.handle(keyEvent(125, ""), client: client)) }
            check(control.engine!.snapshot().page == 1)
            check(control.handle(keyEvent(49, " "), client: client))
            await store.flush()
            let row = db.decisions().last!
            check(db.ops(row).candidateMoves == 3 && db.ops(row).pageTurns == 1)
            check(db.ops(row).pageRequests == 0 && db.ops(row).preeditEdits == 0)
        }
        settings.candidateCount = 5
        do {
            let client = RecordingClient(document: "")
            let control = controller(settings, client, store)
            input("shi", control, client)
            let original = control.engine!.qualitySnapshot()
            check(control.handle(keyEvent(125, ""), client: client))
            let highlighted = control.engine!.snapshot()
            check(control.handle(keyEvent(49, " "), client: client))
            check(client.document == highlighted.candidates[highlighted.highlight])
            await store.flush()
            let row = db.decisions().last!
            check(row["selected_display_index"] == "1" && db.ops(row).candidateMoves == 1)
            check(db.page(row, "first_page_json").candidates == original.candidates)
        }
        print("PASS page sizes 3/5/9, page 2 slot 1, native rank mapping and arrow+space first-page retention")

        var observedNativeReorder = false
        for panel in [false, true] {
            for move in [false, true] {
                let client = RecordingClient(document: "准备午")
                let control = controller(settings, client, store)
                input("can", control, client)
                check(control.engine!.snapshot().candidates[0] == "餐")
                if move { client.selection = NSRange(location: 0, length: 0) }
                else { client.contextAvailable = false }
                if panel { control.candidateSelected(NSAttributedString(string: "餐")) }
                else { digit(0, control, client) }
                await store.flush()
                let row = db.decisions().last!
                let snapshot = db.page(row)
                check(snapshot.precedingContext == "准备午" && snapshot.candidates[0].text == "餐")
                observedNativeReorder = observedNativeReorder || snapshot.candidates[0].nativeIndex != 0
                check(snapshot.candidates[0].displayIndex == 0)
                check(row["trigger"] == (panel ? "panel" : "digit"))
                check(row["regular_ranked_selection"] == "1" && client.document == "准备午餐")
            }
        }
        check(observedNativeReorder, "At least the cold first context selection must expose a different native rank")
        print("PASS context rerank digit/panel selection preserves shown order after unavailable/moved client context")

        for undo in [false, true] {
            let client = RecordingClient(document: "")
            let control = controller(settings, client, store)
            input("nihao", control, client)
            let before = control.engine!.qualitySnapshot()
            let count = db.decisions().count
            if undo { digit(before.candidates.firstIndex { $0.text == "你" }!, control, client) }
            else {
                control.candidateSelectionChanged(NSAttributedString(string: "你"))
                check(control.handle(keyEvent(49, " "), client: client))
            }
            check(control.engine!.qualitySnapshot().selectedPrefix == "你")
            check(control.engine!.qualitySnapshot().rawInput == "nihao")
            if undo {
                check(control.handle(keyEvent(51, ""), client: client))
                check(control.engine!.qualitySnapshot().selectedPrefix.isEmpty)
                check(control.engine!.qualitySnapshot().rawInput == "nihao")
                let full = control.engine!.snapshot().candidates.firstIndex(of: "你好")!
                digit(full, control, client)
            } else { check(control.handle(keyEvent(49, " "), client: client)) }
            check(client.document == "你好")
            await store.flush()
            let rows = Array(db.decisions().dropFirst(count))
            check(rows.count == 2)
            check(rows[0]["selected_text"] == "你")
            check(db.page(rows[0], "first_page_json").generation == db.page(rows[0]).generation,
                  "Highlight-only unconverted preedit changes preserve generation")
            check(rows[0]["outcome"] == (undo ? "reverted" : "committed"))
            check(rows[1]["outcome"] == "committed")
            if !undo { check(rows[0]["commit_id"] == rows[1]["commit_id"]) }
            else { check(rows[0]["commit_id"] == nil && rows[0]["path_reason"] == "selected_prefix_undone") }
        }
        print("PASS selected-prefix segments link two decisions to one insert; Backspace undo with unchanged raw input is reverted")

        for action in ["return", "punctuation", "forced", "toggle"] {
            let client = RecordingClient(document: "")
            let control = controller(settings, client, store)
            input("nihao", control, client)
            let count = db.decisions().count
            switch action {
            case "return": check(control.handle(keyEvent(36, "\r"), client: client))
            case "punctuation": check(control.handle(keyEvent(43, ","), client: client))
            case "forced": check(!control.handle(keyEvent(0, "a", .command), client: client))
            default:
                let before = control.engine!.snapshot()
                check(control.handle(keyEvent(49, " ", [.control, .shift]), client: client))
                check(control.engine!.snapshot() == before && !control.engine!.asciiMode && control.engine!.requestedASCIIMode)
                check(!client.mutations.contains { $0.hasPrefix("insert:") }, "Deferred toggle must not insert text")
                await store.flush()
                check(db.decisions().count == count, "Deferred toggle must not publish a selection decision")
            }
            control.commitComposition(client); control.deactivateServer(client)
            await store.flush()
            let rows = Array(db.decisions().dropFirst(count))
            check(rows.count == 1, "Nested \(action) must record exactly one decision")
            check(rows[0]["regular_ranked_selection"] == "0")
            check(client.mutations.filter { $0.hasPrefix("insert:") }.count == 1)
            let composition = db.rows("SELECT * FROM compositions WHERE id='\(rows[0]["composition_id"]!)'")[0]
            check(db.ops(composition).keypresses == 6, "Count outer keys exactly once")
            if action == "return" {
                check(rows[0]["selected_display_index"] == nil && rows[0]["unknown_rank_reason"] == "not_a_candidate_selection")
                check(client.document == "nihao")
            } else if action == "toggle" {
                check(rows[0]["trigger"] == "force_flush" && rows[0]["outcome"] == "committed")
                check(db.rows("SELECT * FROM commits WHERE id='\(rows[0]["commit_id"]!)'")[0]["kind"] == "forced_flush",
                      "Actual flush owns the commit origin after a deferred toggle")
            }
        }
        do {
            let client = RecordingClient(document: "")
            let control = controller(settings, client, store)
            input("nihao", control, client)
            let before = control.engine!.snapshot(), count = db.decisions().count
            check(control.handle(keyEvent(49, " ", [.control, .shift]), client: client))
            check(control.engine!.snapshot() == before && !client.mutations.contains { $0.hasPrefix("insert:") })
            await store.flush()
            check(db.decisions().count == count)
            let selected = before.candidates[before.highlight]
            control.candidateSelected(NSAttributedString(string: selected))
            control.commitComposition(client); control.deactivateServer(client)
            await store.flush()
            let rows = Array(db.decisions().dropFirst(count))
            check(rows.count == 1 && rows[0]["trigger"] == "panel" && rows[0]["outcome"] == "committed")
            check(rows[0]["regular_ranked_selection"] == "1")
            check(client.mutations.filter { $0.hasPrefix("insert:") } == ["insert:" + selected])
            let composition = db.rows("SELECT * FROM compositions WHERE id='\(rows[0]["composition_id"]!)'")[0]
            check(db.ops(composition).keypresses == 6, "Five letters plus deferred toggle; panel selection adds no key")
            check(db.rows("SELECT * FROM commits WHERE id='\(rows[0]["commit_id"]!)'")[0]["kind"] == "candidate")
        }
        print("PASS deferred mode recording: no premature decision/insert, one actual flush or panel decision, correct origin and six keys")
        do {
            let client = RecordingClient(document: "")
            let control = controller(settings, client, store)
            input("nihao", control, client)
            check(control.handle(keyEvent(53, ""), client: client))
            control.commitComposition(client); control.deactivateServer(client)
            check(control.handle(keyEvent(43, ","), client: client))
            await store.flush()
            let last = db.rows("SELECT * FROM commits ORDER BY rowid DESC LIMIT 1")[0]
            check(last["text"] == "，" && last["kind"] == "direct_symbol")
            check(db.rows("SELECT * FROM candidate_decisions WHERE composition_id='\(last["composition_id"]!)'").isEmpty)
        }
        do {
            let client = RecordingClient(document: "")
            let control = controller(settings, client, store)
            input("nihao", control, client)
            let count = db.decisions().count
            client.insertionCallback = { [weak control] in control?.commitComposition(nil) }
            digit(0, control, client)
            await store.flush()
            let rows = Array(db.decisions().dropFirst(count))
            check(rows.count == 1 && rows[0]["outcome"] == "committed" && rows[0]["commit_id"] != nil,
                  "A finish callback inside insertText must preserve the original decision")
            check(client.mutations.filter { $0.hasPrefix("insert:") } == ["insert:你好"])
        }
        var reentrantOriginsPassed = true
        for (raw, force) in [("nihao", false), ("vv", false), ("vv", true)] {
            let client = RecordingClient(document: "")
            let control = controller(settings, client, store)
            let compositionCount = db.rows("SELECT * FROM compositions").count
            let commitCount = db.rows("SELECT * FROM commits").count
            let decisionCount = db.decisions().count
            input(raw, control, client)
            if raw == "vv" { check(control.engine!.snapshot().candidates.isEmpty) }
            client.insertionCallback = { [weak control] in control?.commitComposition(nil) }
            if force { check(!control.handle(keyEvent(0, "a", .command), client: client)) }
            else { check(control.handle(keyEvent(36, "\r"), client: client)) }
            await store.flush()
            let compositions = Array(db.rows("SELECT * FROM compositions ORDER BY rowid").dropFirst(compositionCount))
            let commits = Array(db.rows("SELECT * FROM commits ORDER BY rowid").dropFirst(commitCount))
            let kind = force ? "forced_flush" : "raw_return"
            let passed = compositions.count == 1 && commits.count == 1 &&
                compositions[0]["id"] == commits[0]["composition_id"] &&
                db.ops(compositions[0]).keypresses == raw.count + 1 &&
                commits[0]["kind"] == kind && commits[0]["insertion_issued"] == "1"
            reentrantOriginsPassed = reentrantOriginsPassed && passed
            check(client.mutations.filter { $0.hasPrefix("insert:") } == ["insert:" + raw])
            if raw == "vv" { check(db.decisions().count == decisionCount, "No candidate means no selection decision") }
            print("\(passed ? "PASS" : "FAIL") CAP-001 raw=\(raw) origin=\(kind) compositions=\(compositions.count) commits=\(commits.count)")
        }
        do {
            let client = RecordingClient(document: "")
            let control = controller(settings, client, store)
            input("x", control, client)
            check(control.handle(keyEvent(51, ""), client: client))
            await store.flush()
            let composition = db.rows("SELECT * FROM compositions ORDER BY rowid DESC LIMIT 1")[0]
            check(composition["outcome"] == "cancelled" && db.ops(composition).keypresses == 2 && db.ops(composition).preeditEdits == 1)
            check(!client.mutations.contains { $0.hasPrefix("insert:") })
        }
        check(reentrantOriginsPassed, "CAP-001: empty nested drains preserve the outer composition, original kind and key counts")
        print("PASS raw Return, punctuation, modified-key flush, mode toggle, Escape, direct symbols and duplicate/nested finish callbacks; last-character deletion still cancels")

        do {
            let client = RecordingClient(document: "")
            let control = controller(settings, client, store)
            let count = db.decisions().count
            input("ni", control, client)
            check(control.handle(keyEvent(39, "'"), client: client))
            input("hao", control, client)
            check(control.handle(keyEvent(30, "]"), client: client))
            check(control.handle(keyEvent(33, "["), client: client))
            check(control.handle(keyEvent(30, "]"), client: client))
            check(control.handle(keyEvent(33, "["), client: client))
            check(control.handle(keyEvent(51, ""), client: client))
            check(control.handle(keyEvent(0, "o"), client: client))
            check(control.handle(keyEvent(49, " "), client: client))
            control.commitComposition(client)
            await store.flush()
            let rows = Array(db.decisions().dropFirst(count))
            check(rows.count == 1 && rows[0]["trigger"] == "space", "Pinyin separator and page aliases are not decisions")
            let composition = db.rows("SELECT * FROM compositions WHERE id='\(rows[0]["composition_id"]!)'")[0]
            let operations = db.ops(composition)
            check(operations.preeditEdits == 1 && operations.pageRequests == 4 && operations.pageTurns == 4,
                  "Only edits/navigation count: \(operations)")
            let countBeforeIdle = db.rows("SELECT * FROM compositions").count
            check(!control.handle(keyEvent(0, "a", .command), client: client))
            check(!control.handle(keyEvent(123, ""), client: client))
            check(control.handle(keyEvent(49, " ", [.control, .shift]), client: client))
            check(!control.handle(keyEvent(0, "a"), client: client))
            await store.flush()
            check(db.rows("SELECT * FROM compositions").count == countBeforeIdle, "Idle passthrough keys do not become per-key records")
        }
        print("PASS apostrophe/page aliases, actual edit/navigation counters and no idle/ASCII-passthrough per-key records")

        do {
            let client = RecordingClient(document: "")
            let control = controller(settings, client, store)
            input("yisheng", control, client)
            var found = false
            for _ in 0..<10 {
                if let index = control.engine!.snapshot().candidates.firstIndex(of: "👨‍⚕️") {
                    digit(index, control, client); found = true; break
                }
                check(control.handle(keyEvent(121, ""), client: client))
            }
            check(found && client.document == "👨‍⚕️")
            await store.flush()
            check(db.decisions().last!["text_kind"] == "emoji")
        }

        let kinds: [(String, QualityTextKind)] = [("中文", .chinese), ("hello", .english), ("这份offer", .mixed),
            ("😀", .emoji), ("1️⃣", .emoji), ("123", .number), ("！？", .symbol), ("é", .other)]
        for (text, kind) in kinds {
            let phrase = try settings.saveCustomPhrase(code: "zq", text: text)
            let client = RecordingClient(document: "")
            let control = controller(settings, client, store)
            input("zq", control, client)
            digit(0, control, client)
            await store.flush()
            let row = db.decisions().last!
            check(row["selected_text"] == text && row["text_kind"] == kind.rawValue && row["matches_custom_phrase"] == "1")
            check(db.page(row).candidates[0].source == nil, "Custom phrase equality is not translator provenance")
            try settings.deleteCustomPhrase(id: phrase.id)
        }
        print("PASS real engine commits for all text kinds and separate custom phrase matching flag")

        do {
            settings.candidateCount = 3
            let phrase = try settings.saveCustomPhrase(code: "zq", text: "旧短语")
            let client = RecordingClient(document: "")
            let control = controller(settings, client, store)
            input("zq", control, client)
            let old = control.engine!.qualitySnapshot()
            settings.candidateCount = 9
            try settings.saveCustomPhrase(id: phrase.id, code: "zq", text: "新短语")
            check(control.engine!.qualitySnapshot().configuration == old.configuration)
            digit(0, control, client)
            await store.flush()
            check(db.page(db.decisions().last!).configuration == old.configuration)
            input("zq", control, client)
            digit(0, control, client)
            await store.flush()
            let new = db.page(db.decisions().last!)
            check(new.pageSize == 9 && new.configuration.customPhrases[0].text == "新短语")
            check(new.configurationRevisionID != old.configurationRevisionID)
            try settings.deleteCustomPhrase(id: phrase.id)
            settings.candidateCount = 5
        }
        do {
            let first = RecordingClient(document: "准备午")
            let second = RecordingClient(document: "完全无关")
            let a = controller(settings, first, store), b = controller(settings, second, store)
            input("can", a, first); input("can", b, second)
            digit(0, a, first); digit(0, b, second)
            await store.flush()
            let last = Array(db.decisions().suffix(2)).map { db.page($0).precedingContext }
            check(last == ["准备午", "完全无关"])
            let previousClient = RecordingClient()
            let changed = controller(settings, previousClient, store)
            input("nihao", changed, previousClient)
            let otherClient = RecordingClient()
            otherClient.testBundleID = nil; otherClient.testClientID = nil
            digit(0, changed, otherClient)
            await store.flush()
            let unknownClient = db.rows("SELECT * FROM compositions ORDER BY rowid DESC LIMIT 1")[0]
            check(unknownClient["app_bundle_id"] == nil && unknownClient["client_id"] == nil)
            let noClient = controller(settings, nil, store)
            input("nihao", noClient, nil); digit(0, noClient, nil)
            await store.flush()
            check(db.rows("SELECT * FROM compositions WHERE outcome_reason='client_changed'").count > 0)
            check(db.rows("SELECT * FROM commits ORDER BY rowid DESC LIMIT 1")[0]["insertion_issued"] == "0")
        }
        print("PASS deferred applied settings, configuration revisions, controller/client isolation and no-client insertion evidence")
    }

    @MainActor static func pagingSettings(_ store: QualityStore, _ db: CaptureDatabase) async {
        let isolated = IsolatedSettings()
        defer { isolated.cleanup() }
        let settings = isolated.settings
        for keys in IFSettings.PagingKeys.allCases {
            settings.pagingKeys = keys
            let client = RecordingClient(document: "")
            let control = controller(settings, client, store)
            input("shi", control, client)
            let before = control.engine!.qualitySnapshot()
            settings.pagingKeys = keys == .brackets ? .minusEqual : .brackets
            for event in keys == .brackets ? [keyEvent(30, "]"), keyEvent(33, "[")] : [keyEvent(24, "="), keyEvent(27, "-")] {
                check(control.handle(event, client: client))
            }
            _ = control.handle(keys == .brackets ? keyEvent(24, "=") : keyEvent(30, "]"), client: client)
            control.commitComposition(client)
            await store.flush()
            let original = db.rows("SELECT * FROM compositions ORDER BY rowid DESC LIMIT 1")[0]
            check(db.ops(original).pageRequests == 2 && db.ops(original).pageTurns == 2,
                  "Unselected symbols are not page requests; a pending choice does not change applied paging")
            check(db.page(db.decisions().last!).configuration.inputOptions == before.configuration.inputOptions)

            input("shi", control, client)
            let updated = control.engine!.qualitySnapshot()
            check(updated.configuration.inputOptions == settings.inputPreferences.recordedValues)
            for event in [keyEvent(121, ""), keyEvent(116, "")] +
                (keys == .brackets ? [keyEvent(24, "="), keyEvent(27, "-")] : [keyEvent(30, "]"), keyEvent(33, "[")]) {
                check(control.handle(event, client: client))
            }
            _ = control.handle(keys == .brackets ? keyEvent(30, "]") : keyEvent(24, "="), client: client)
            control.commitComposition(client)
            await store.flush()
            let next = db.rows("SELECT * FROM compositions ORDER BY rowid DESC LIMIT 1")[0]
            check(db.ops(next).pageRequests == 4 && db.ops(next).pageTurns == 4,
                  "Next composition counts the new selected pair and native Page Up/Down only")
            check(db.page(db.decisions().last!).configuration.inputOptions == updated.configuration.inputOptions)
        }
        check(db.rows("SELECT * FROM compositions").count == 4 && store.statistics().errors == 0)
        print("PASS paging recording: unselected symbols excluded, deferred and next-composition applied options, native Page Up/Down retained")
    }

    @MainActor static func synthetic(_ store: QualityStore, _ db: CaptureDatabase) async {
        let revision = QualityConfigRevision(configuration: QualityAppliedConfiguration(candidateCount: 3))
        func page(_ raw: String = "tong", _ prefix: String = "", _ number: Int = 0) -> QualityPageSnapshot {
            QualityPageSnapshot(generation: 0, rawInput: raw, caret: raw.utf8.count, selectedPrefix: prefix,
                precedingContext: "", configurationRevisionID: revision.id, configuration: revision.configuration,
                page: number, pageSize: 3, candidates: (0..<3).map {
                    QualityCandidate(text: "同", displayIndex: $0, displayRank: number * 3 + $0 + 1,
                                     nativeIndex: $0, nativeRank: number * 3 + $0 + 1)
                }, highlightedDisplayIndex: 0)
        }
        let recorder = QualityRecorder(store: store)
        let before = page("tong", "", 1)
        recorder.willMutate(before, revision: revision, action: .select(0, .panel, true))
        recorder.didMutate(page(""), handled: true)
        recorder.commitDrained("同", insertionIssued: false, clientID: nil)
        await store.flush()
        let ambiguous = db.decisions().last!
        check(ambiguous["outcome"] == "committed" && ambiguous["selected_display_index"] == nil)
        check(ambiguous["unknown_rank_reason"] == "ambiguous_candidate_text" && ambiguous["first_page_json"] == nil)
        check(db.page(ambiguous).presentation == .notShown)
        let countBeforeEdit = db.decisions().count
        recorder.willMutate(page("tonghao"), revision: revision, action: .select(0, .panel, false))
        recorder.didMutate(page("tonghao", "同"), handled: true)
        recorder.willMutate(page("tonghao", "同"), revision: revision, action: .key(120, 0))
        recorder.didMutate(page("tonghaox", "同"), handled: true)
        recorder.willMutate(page("tonghaox", "同"), revision: revision, action: .select(0, .panel, false))
        recorder.didMutate(page(""), handled: true)
        recorder.commitDrained("同同", insertionIssued: false, clientID: nil)
        await store.flush()
        let edited = Array(db.decisions().dropFirst(countBeforeEdit))
        check(edited.count == 2 && edited[0]["outcome"] == "unknown" && edited[1]["outcome"] == "committed")
        check(edited[0]["path_reason"] == "composition_edited_after_selection" && edited[0]["commit_id"] == nil)
        var invalid = page()
        invalid.selectedPrefixValid = false
        recorder.willMutate(invalid, revision: revision, action: .select(0, .panel, false))
        recorder.didMutate(page(""), handled: true)
        recorder.commitDrained("同", insertionIssued: false, clientID: nil)
        await store.flush()
        check(db.decisions().last!["path_reason"] == "invalid_selected_prefix")
        var noCandidates = page("unmatched")
        noCandidates.candidates = []
        let candidateCount = db.decisions().count
        recorder.willMutate(noCandidates, revision: revision, action: .key(0xff0d, 0))
        recorder.didMutate(page(""), handled: true)
        recorder.commitDrained("unmatched", insertionIssued: false, clientID: nil)
        await store.flush()
        check(db.decisions().count == candidateCount, "No candidate means no synthetic raw-return selection")
        check(db.rows("SELECT * FROM commits ORDER BY rowid DESC LIMIT 1")[0]["kind"] == "raw_return")
        let oversizedBefore = store.statistics().droppedOversized
        for _ in 0..<3 {
            let huge = page(String(repeating: "x", count: 100_000))
            recorder.willMutate(huge, revision: revision, action: .key(120, 0))
            recorder.didMutate(huge, handled: true)
        }
        check(store.statistics().droppedOversized == oversizedBefore + 1)
        recorder.willMutate(page("x"), revision: revision, action: .clear)
        recorder.didMutate(page(""), handled: true)
        recorder.commitDrained("", insertionIssued: false, clientID: nil)
        recorder.willMutate(page(), revision: revision, action: .select(0, .panel, false))
        recorder.didMutate(page(""), handled: true)
        recorder.commitDrained("同", insertionIssued: true, clientID: "synthetic")
        await store.flush()
        check(db.decisions().last!["selected_display_index"] == "0")
        for index in 0..<70 {
            var snapshot = page("tong", "", index)
            snapshot.candidates[0].text = String(repeating: "字", count: 80)
            recorder.presented(snapshot, revision: revision, panelShowIssued: false)
        }
        var final = page("tong", "", 69)
        final.candidates[0].text = String(repeating: "字", count: 80)
        recorder.willMutate(final, revision: revision, action: .select(0, .panel, false))
        recorder.didMutate(page(""), handled: true)
        recorder.commitDrained(final.candidates[0].text, insertionIssued: false, clientID: nil)
        await store.flush()
        let truncated = db.decisions().last!
        check(truncated["page_history_truncated"] == "1")
        check(db.page(truncated).page == 69 && db.page(truncated, "first_page_json").page == 0)
        print("PASS synthetic unknown-rank/first-page/not-shown evidence, bounded active overflow/resumption and preserved core after history truncation")
    }

    @MainActor static func equivalence(shared: String, scratch: URL) async throws {
        let initial = scratch.appendingPathComponent("identical-initial")
        try IFEngine.start(shared: shared, user: initial.path)
        IFEngine.stop()
        let files = FileManager.default
        var transcripts: [[String]] = []
        for enabled in [false, true] {
            let user = scratch.appendingPathComponent(enabled ? "recording-on" : "recording-off")
            try files.copyItem(at: initial, to: user)
            try IFEngine.start(shared: shared, user: user.path)
            let settings = IsolatedSettings()
            let store = enabled ? QualityStore(url: scratch.appendingPathComponent("equivalence.sqlite3"),
                engineVersion: IFEngine.version, buildMetadata: .unknown) : nil
            var transcript: [String] = []
            do {
                let client = RecordingClient(document: "准备午")
                let control = controller(settings.settings, client, store)
                let events = "can".map { keyEvent(0, String($0)) } + [keyEvent(125, ""), keyEvent(49, " ")] +
                    "nihao".map { keyEvent(0, String($0)) } + [keyEvent(121, ""), keyEvent(18, "1"), keyEvent(36, "\r")] +
                    "nihao".map { keyEvent(0, String($0)) } + [keyEvent(43, ","), keyEvent(49, " ", [.control, .shift]), keyEvent(0, "a")]
                for event in events {
                    let handled = control.handle(event, client: client)
                    transcript.append("\(handled)|\(control.engine!.snapshot())|\(client.document ?? "nil")|\(client.mutations)|\(client.requests)")
                }
                control.commitComposition(client); control.deactivateServer(client)
                transcript.append("\(client.document ?? "nil")|\(client.mutations)")
            }
            await store?.close()
            settings.cleanup()
            IFEngine.stop()
            transcripts.append(transcript)
        }
        check(transcripts[0] == transcripts[1], "Recording on/off must preserve handled/candidates/commits/document reads/client transcript from identical initial Rime bytes")
        print("PASS recording on/off equivalence from two copies of identical initial isolated Rime state (including document read transcript)")
    }

    @MainActor static func stalledWriter(shared: String, scratch: URL) async throws {
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let store = QualityStore(url: scratch.appendingPathComponent("stalled.sqlite3"), engineVersion: IFEngine.version,
            buildMetadata: .unknown, hooks: QualityStoreHooks(beforeOpen: { entered.signal(); gate.wait() }))
        check(entered.wait(timeout: .now() + 5) == .success)
        try IFEngine.start(shared: shared, user: scratch.appendingPathComponent("stalled-rime").path)
        let settings = IsolatedSettings()
        let client = RecordingClient()
        let control = controller(settings.settings, client, store)
        let started = ContinuousClock.now
        for _ in 0..<140 { input("nihao", control, client); digit(0, control, client) }
        let elapsed = started.duration(to: .now)
        check(store.statistics().peakBuffered == 128 && store.statistics().droppedQueue > 0)
        check(elapsed < .seconds(10), "A stalled writer must not stall controller calls: \(elapsed)")
        gate.signal()
        await store.close()
        IFEngine.stop()
        settings.cleanup()
        print("PASS stalled worker: 140 controller compositions completed in \(elapsed), bounded queue/drop counters verified")
    }
}
