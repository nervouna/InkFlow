import Foundation
import InkFlowRimeNative
@testable import InkFlowCore
import InkFlowDomain
import InkFlowRime

@main struct PersonalDataTests {
    static func expect(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label) }
    static func rejects(_ label: String, _ body: () throws -> Void) {
        do { try body(); preconditionFailure(label) } catch { }
    }
    static func snapshot(_ name: String, rows: Bool = true) -> String {
        let row = name == "pinyin_simp" ? "ni hao \t你好" : name == "inkflow_shared_english" ? "backupword \tBackupWord" : "beifen \t备份别名"
        return "# Rime user dictionary\n#@/db_name\t\(name)\n#@/db_type\tuserdb\n#@/rime_version\t1.17.0\n#@/user_id\t\(rows ? "synthetic-source" : "")\n" +
        (rows ? "#@/tick\t99\n\(row)\tc=7 d=0.123456789 t=42\nce shi \t测试\tc=-3 d=0.0000123 t=17\n" : "")
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "--personal-data" { exit(IFPersonalDataWorkerBootstrap.run(arguments: CommandLine.arguments)) }
        if CommandLine.arguments.dropFirst().first == "--crash-step" {
            let transaction = PersonalDataTransaction(user: URL(fileURLWithPath: CommandLine.arguments[2]))
            try transaction.install { if $0 == CommandLine.arguments[3] { exit(73) } }
            preconditionFailure("crash boundary not reached")
        }
        if CommandLine.arguments.dropFirst().first == "--preferences" {
            let defaults = UserDefaults(suiteName: CommandLine.arguments[2])!
            expect(defaults.integer(forKey: "candidateCount") == 9, "cross-process persistence")
            return
        }
        let suite = "InkFlowPersonalTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IFSettings(defaults: defaults)
        defaults.set("synthetic-secret", forKey: "aiBaseURL")
        defaults.set(1, forKey: "aiEnabled"); defaults.set(1, forKey: "voicePolishEnabled"); defaults.set(1, forKey: "qualityRecordingPaused")
        var preferences = try settings.personalBackupSettings()
        preferences.integers["candidateCount"] = 9
        preferences.shortcuts["inputMode"] = .rightShift
        preferences.shortcuts["voiceHold"] = .leftShift
        preferences.shortcuts["voiceToggle"] = .leftShift
        try settings.applyPersonalPreferences(preferences.encodedPreferences())
        expect(settings.shortcuts.binding(for: .inputMode) == .rightShift, "atomic shortcut swap")
        expect(settings.shortcuts.binding(for: .voiceHold) == .leftShift, "atomic shortcut swap")
        expect(settings.voicePolishEnabled && settings.qualityRecordingPaused, "destination switches")
        expect(defaults.string(forKey: "aiBaseURL") == "synthetic-secret", "service preserved")
        let synchronized = await settings.synchronizePersonalPreferences()
        expect(synchronized, "synchronize")
        let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); process.arguments = ["--preferences", suite]
        try process.run(); process.waitUntilExit(); expect(process.terminationStatus == 0, "independent preferences reader")
        var document = PersonalBackupDocument(rime: "1.17.0", settings: preferences,
            dictionaries: Dictionary(uniqueKeysWithValues: PersonalBackupDocument.names.map { ($0, Optional(snapshot($0))) }))
        let fixture = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("personal-data-" + UUID().uuidString)
        try PersonalDataFiles.directory(fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("backup.json")
        let bytes = try JSONEncoder().encode(document)
        expect(!String(decoding: bytes, as: UTF8.self).contains("synthetic-secret"), "allowlist")
        try PersonalDataFiles.write(bytes, file)
        _ = try PersonalBackupDocument.read(file)
        var unknown = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        unknown["credentials"] = "never-accepted"
        try PersonalDataFiles.write(JSONSerialization.data(withJSONObject: unknown), file)
        rejects("unknown fields") { _ = try PersonalBackupDocument.read(file) }
        document.format = 2; rejects("version") { try document.validate() }; document.format = 1
        document.dictionaries.removeValue(forKey: "pinyin_simp"); rejects("missing dictionary") { try document.validate() }
        document.dictionaries["pinyin_simp"] = .some(nil); try document.validate()
        let oversized = fixture.appendingPathComponent("oversized.json")
        _ = FileManager.default.createFile(atPath: oversized.path, contents: Data())
        let oversizedHandle = try FileHandle(forWritingTo: oversized)
        try oversizedHandle.truncate(atOffset: UInt64(PersonalBackupDocument.maximumBytes + 1)); try oversizedHandle.close()
        rejects("preallocation size bound") { _ = try PersonalBackupDocument.read(oversized) }
        let link = fixture.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        rejects("symlink") { _ = try PersonalBackupDocument.read(link) }
        do {
            // Each native row and snapshot fits its own limits. Quoted phrase text
            // doubles during JSON escaping, making the final three-library file too large.
            let phrase = String(repeating: "\"", count: 60_000)
            let rows = (0..<512).map { "ni hao \t\($0)\(phrase)\tc=7 d=0.123456789 t=42\n" }.joined()
            let snapshots = Dictionary(uniqueKeysWithValues: PersonalBackupDocument.names.map {
                ($0, Optional(snapshot($0, rows: false) + rows))
            })
            let escaped = PersonalBackupDocument(rime: "1.17.0", settings: preferences, dictionaries: snapshots)
            for text in snapshots.values.compactMap({ $0 }) {
                expect(text.utf8.count <= 32 * 1024 * 1024, "escape fixture fits snapshot budget")
                let lines = text.split(separator: "\n")
                expect(lines.count <= 250_000 && lines.allSatisfy { $0.utf8.count <= 65_536 }, "escape fixture fits native row budgets")
            }
            let destination = fixture.appendingPathComponent("existing-backup.json")
            let original = Data("preserve-existing-backup".utf8)
            try PersonalDataFiles.write(original, destination)
            do {
                try escaped.write(to: destination)
                preconditionFailure("JSON escaping must exceed the final file budget")
            } catch let error as PersonalDataError {
                expect(error.code == "export-size", "reject actual encoded size, not a snapshot limit")
            }
            expect(try! Data(contentsOf: destination) == original, "oversized export preserves existing target")
        }
        let worker = PersonalDataWorker(user: fixture, helper: URL(fileURLWithPath: CommandLine.arguments[0]))
        for empty in [false, true] {
            let stage = fixture.appendingPathComponent("PersonalData/staging/" + UUID().uuidString)
            try PersonalDataFiles.directory(stage.appendingPathComponent("databases"))
            for name in PersonalBackupDocument.names { try PersonalDataFiles.write(Data(snapshot(name, rows: !empty).utf8), stage.appendingPathComponent(name + ".userdb.txt")) }
            do { try worker.run(root: stage, restore: true) } catch { throw PersonalDataError("restore-empty-\(empty)-\(error)") }
            do { try worker.run(root: stage, restore: false) } catch { throw PersonalDataError("export-empty-\(empty)-\(error)") }
            for name in PersonalBackupDocument.names {
                let actual = try String(contentsOf: stage.appendingPathComponent(name + ".userdb.txt"), encoding: .utf8)
                let expected = snapshot(name, rows: !empty)
                expect(Set(actual.split(separator: "\n")) == Set(expected.split(separator: "\n")), "native complete map roundtrip")
            }
        }
        for suffix in ["malformed\n", "x \tx\tc=NaN d=1 t=1\n", "x \tx\tc=1 d=inf t=1\n", "x \tx\tc=1 d=1 t=-1\n", "ni hao \t你好\tc=1 d=1 t=1\n", "#unknown\n"] {
            let stage = fixture.appendingPathComponent("PersonalData/staging/" + UUID().uuidString)
            try PersonalDataFiles.directory(stage.appendingPathComponent("databases"))
            try PersonalDataFiles.write(Data((snapshot("pinyin_simp") + suffix).utf8), stage.appendingPathComponent("pinyin_simp.userdb.txt"))
            rejects("native malformed") { try worker.run(root: stage, restore: true) }
        }
        let largeStage = fixture.appendingPathComponent("PersonalData/staging/" + UUID().uuidString)
        try PersonalDataFiles.directory(largeStage.appendingPathComponent("databases"))
        let large = snapshot("pinyin_simp", rows: false) + (0..<249990).map { "ni hao \t合成\($0)\tc=7 d=0.123456789 t=42\n" }.joined()
        try PersonalDataFiles.write(Data(large.utf8), largeStage.appendingPathComponent("pinyin_simp.userdb.txt"))
        let began = ContinuousClock.now
        try worker.run(root: largeStage, restore: true); try worker.run(root: largeStage, restore: false)
        print("PASS bounded synthetic scale: 249990 rows, \(large.utf8.count) bytes, \(began.duration(to: .now))")
        for absent in [false, true] {
            for stop in PersonalBackupDocument.names.flatMap({ [$0 + ".old", $0 + ".new"] }) {
                let user = fixture.appendingPathComponent(UUID().uuidString)
                let stage = user.appendingPathComponent("PersonalData/staging/" + UUID().uuidString)
                try PersonalDataFiles.directory(stage.appendingPathComponent("databases"))
                for name in PersonalBackupDocument.names {
                    if !absent {
                        let old = user.appendingPathComponent(name + ".userdb"); try PersonalDataFiles.directory(old)
                        try PersonalDataFiles.write(Data("old".utf8), old.appendingPathComponent("fixture"))
                    }
                    let new = stage.appendingPathComponent("databases/" + name + ".userdb"); try PersonalDataFiles.directory(new)
                    try PersonalDataFiles.write(Data("new".utf8), new.appendingPathComponent("fixture"))
                }
                let transaction = PersonalDataTransaction(user: user)
                try transaction.prepare(staging: stage, rollback: [:], incoming: preferences.encodedPreferences())
                let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                child.arguments = ["--crash-step", user.path, stop]
                try child.run(); child.waitUntilExit(); expect(child.terminationStatus == 73, "process exited at rename boundary")
                if absent {
                    try PersonalDataTransaction.recover(user: user, defaults: defaults)
                    try PersonalDataTransaction.recover(user: user, defaults: defaults)
                } else { _ = try transaction.rollback(); _ = try transaction.rollback() }
                for name in PersonalBackupDocument.names {
                    let live = user.appendingPathComponent(name + ".userdb")
                    if absent { expect(!FileManager.default.fileExists(atPath: live.path), "absence restored") }
                    else { expect(try! Data(contentsOf: live.appendingPathComponent("fixture")) == Data("old".utf8), "original restored") }
                }
                if !absent { try transaction.cleanup() }
            }
        }
        let committedUser = fixture.appendingPathComponent("committed")
        let committedStage = committedUser.appendingPathComponent("PersonalData/staging/" + UUID().uuidString)
        try PersonalDataFiles.directory(committedStage.appendingPathComponent("databases"))
        let committed = PersonalDataTransaction(user: committedUser)
        try committed.prepare(staging: committedStage, rollback: [:], incoming: preferences.encodedPreferences())
        try committed.install(); try committed.commit()
        defaults.set(3, forKey: "candidateCount")
        try PersonalDataTransaction.recover(user: committedUser, defaults: defaults)
        expect(defaults.integer(forKey: "candidateCount") == 9, "committed recovery reapplies incoming settings")
        defaults.set(3, forKey: "candidateCount")
        try PersonalDataTransaction.recover(user: committedUser, defaults: defaults)
        expect(defaults.integer(forKey: "candidateCount") == 3, "completed journal cannot overwrite later settings")
        try settings.applyPersonalPreferences(preferences.encodedPreferences())
        let engineUser = fixture.appendingPathComponent("engine-user")
        try PersonalDataFiles.directory(engineUser)
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let runtime = IFDictionaryRuntime.bundled(helper: repository.appendingPathComponent("build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker"))
        let coordinator = IFDictionaryCoordinator()
        coordinator.bootstrapForServing(runtime: runtime, user: engineUser)
        defer { IFEngine.stop() }
        for _ in 0..<100 {
            if coordinator.personalDataLifecycleReady { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        expect(coordinator.personalDataLifecycleReady, "synthetic engine lifecycle settled")
        let retainedEngine = IFEngine()!
        let controller = PersonalDataController(user: engineUser, helper: URL(fileURLWithPath: CommandLine.arguments[0]), settings: settings, coordinator: coordinator)
        let complete = PersonalBackupDocument(rime: IFEngine.version, settings: preferences,
            dictionaries: Dictionary(uniqueKeysWithValues: PersonalBackupDocument.names.map { ($0, Optional(snapshot($0))) }))
        try FileHandle.standardError.write(contentsOf: Data("TEST first production restore\n".utf8))
        try await controller.restore(complete)
        expect(retainedEngine.available && !coordinator.isBusy, "retained session restored")
        for key in "nihao".utf8 { retainedEngine.key(Int32(key)) }
        expect(retainedEngine.snapshot().candidates.contains("你好"), "restored Chinese usable")
        rejects("busy composition") { _ = try coordinator.beginPersonalData() }
        retainedEngine.clear(recordQuality: false)
        let learned = try IFEngine.personalLearningEntries()
        expect(learned.contains { $0.source == .english && $0.text == "BackupWord" && $0.commits == 7 }, "English learning survives destination identity")
        expect(learned.contains { $0.source == .voice && $0.text == "备份别名" && $0.commits == 7 }, "voice learning survives destination identity")
        let oldUndo = try IFEngine.deletePersonalLearning(learned.first { $0.source == .english }!)
        for _ in 0..<60 {
            if IFEngine.voiceLexicon.canRead { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try FileHandle.standardError.write(contentsOf: Data("TEST second production restore\n".utf8))
        try await controller.restore(complete)
        rejects("old learning undo invalidated") { try IFEngine.undoPersonalLearning(oldUndo) }
        var replacement = complete
        replacement.settings.integers["candidateCount"] = 3
        coordinator.activationFault = { step, restoring in
            if !restoring, step == .start { throw PersonalDataError("injected-start") }
        }
        do { try await controller.restore(replacement); preconditionFailure("restart failure") } catch { }
        coordinator.activationFault = { _, _ in }
        expect(settings.candidateCount == 9 && retainedEngine.available && !coordinator.isBusy, "engine failure rolls back settings and serving")
        var persistenceCalls = 0
        controller.persistPreferences = {
            persistenceCalls += 1
            return persistenceCalls == 1 ? false : await settings.synchronizePersonalPreferences()
        }
        do { try await controller.restore(replacement); preconditionFailure("persistence failure") } catch { }
        controller.persistPreferences = { await settings.synchronizePersonalPreferences() }
        expect(settings.candidateCount == 9 && retainedEngine.available && !coordinator.isBusy, "settings persistence failure rolls back")
        let reserved = try coordinator.beginPersonalData()
        expect(!retainedEngine.available && IFEngine() == nil, "reservation blocks old and new sessions")
        rejects("dictionary exclusion") { _ = try coordinator.beginPersonalData() }
        try coordinator.restartPersonalData(reserved)
        expect(!retainedEngine.available && !retainedEngine.key(97), "restart remains suspended until transaction finishes")
        coordinator.finishPersonalData()
        expect(retainedEngine.available, "final journal boundary resumes input")
        let exported = fixture.appendingPathComponent("engine-export.json")
        try await controller.export(to: exported)
        let afterEngine = try PersonalBackupDocument.read(exported)
        for name in PersonalBackupDocument.names {
            let rows = afterEngine.dictionaries[name]!!.split(separator: "\n").filter { !$0.hasPrefix("#") }
            let original = snapshot(name).split(separator: "\n").filter { !$0.hasPrefix("#") }
            expect(Set(rows) == Set(original), "full weights and tombstones survive real engine open")
        }
        try await coordinator.shutdown()
        IFEngine.stop()
        settings.personalDataRecoveryRequired = true; settings.shortcuts.personalDataRecoveryRequired = true
        settings.candidateCount = 3; settings.setInputOption(.traditional, enabled: true)
        expect(settings.candidateCount == 9 && !settings.inputPreferences[.traditional], "frozen settings")
        expect(!settings.shortcuts.set(.leftShift, for: .inputMode), "frozen shortcuts")
        print("PASS personal backup format, settings, native maps, malformed input, rename fault rollback and reentry")
    }
}
