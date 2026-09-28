import Foundation
import InkFlowRime

/// A single rollback-first transaction for exactly three native dictionaries and allowlisted preferences.
/// Atomic writes + file synchronization cover process interruption, not hardware power-loss durability.
struct PersonalDataTransaction: Sendable {
    struct Journal: Codable, Sendable {
        var phase: String
        var originals: [String: Bool]
        var steps: [String: String]
        var rollbackPreferences: [String: Data]
        var incomingPreferences: [String: Data]
    }
    let user: URL
    var root: URL { user.appendingPathComponent("PersonalData/transaction") }
    var journalURL: URL { root.appendingPathComponent("journal.json") }
    func database(_ name: String, in directory: URL) -> URL { directory.appendingPathComponent(name + ".userdb") }
    func save(_ journal: Journal) throws { try PersonalDataFiles.write(JSONEncoder().encode(journal), journalURL) }
    func load() throws -> Journal? {
        guard try PersonalDataFiles.exists(root) else { return nil }
        guard try PersonalDataFiles.exists(journalURL) else {
            if try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty {
                try FileManager.default.removeItem(at: root); return nil
            }
            throw PersonalDataError("journal-missing")
        }
        let journal = try JSONDecoder().decode(Journal.self, from: PersonalDataFiles.read(journalURL, limit: 8 * 1024 * 1024))
        guard ["prepared", "applying", "rollback", "committed"].contains(journal.phase),
              Set(journal.originals.keys) == Set(PersonalBackupDocument.names),
              Set(journal.steps.keys) == Set(PersonalBackupDocument.names),
              journal.steps.values.allSatisfy({ ["pending", "moving", "installing", "installed", "restoring", "restored"].contains($0) }),
              Set(journal.rollbackPreferences.keys).isSubset(of: PersonalBackupSettings.keys),
              Set(journal.incomingPreferences.keys) == PersonalBackupSettings.keys else { throw PersonalDataError("journal-invalid") }
        return journal
    }
    func prepare(staging: URL, rollback: [String: Data], incoming: [String: Data]) throws {
        guard try !PersonalDataFiles.exists(root) else { throw PersonalDataError("recovery-required") }
        var originals: [String: Bool] = [:]
        for name in PersonalBackupDocument.names { originals[name] = try PersonalDataFiles.exists(database(name, in: user)) }
        try PersonalDataFiles.directory(root)
        // Save the original-presence record before moving even staged data into the transaction.
        let journal = Journal(phase: "prepared", originals: originals,
            steps: Dictionary(uniqueKeysWithValues: PersonalBackupDocument.names.map { ($0, "pending") }),
            rollbackPreferences: rollback, incomingPreferences: incoming)
        try save(journal)
        try PersonalDataFiles.directory(root.appendingPathComponent("old"))
        try FileManager.default.moveItem(at: staging.appendingPathComponent("databases"), to: root.appendingPathComponent("new"))
    }
    func install(fault: (String) throws -> Void = { _ in }) throws {
        guard var journal = try load(), journal.phase == "prepared" else { throw PersonalDataError("journal-phase") }
        journal.phase = "applying"; try save(journal)
        for name in PersonalBackupDocument.names {
            let live = database(name, in: user), old = database(name, in: root.appendingPathComponent("old")), new = database(name, in: root.appendingPathComponent("new"))
            try PersonalDataFiles.safe(live); try PersonalDataFiles.safe(old); try PersonalDataFiles.safe(new)
            journal.steps[name] = "moving"; try save(journal)
            if journal.originals[name] == true { try FileManager.default.moveItem(at: live, to: old) }
            try fault(name + ".old")
            journal.steps[name] = "installing"; try save(journal)
            if try PersonalDataFiles.exists(new) { try FileManager.default.moveItem(at: new, to: live) }
            try fault(name + ".new")
            journal.steps[name] = "installed"; try save(journal)
        }
    }
    func rollback() throws -> [String: Data] {
        guard var journal = try load(), journal.phase != "committed" else { throw PersonalDataError("journal-phase") }
        journal.phase = "rollback"; try save(journal)
        for name in PersonalBackupDocument.names {
            let live = database(name, in: user), old = database(name, in: root.appendingPathComponent("old"))
            let step = journal.steps[name]!
            if step == "restored" || step == "pending" { continue }
            let hasOld = try PersonalDataFiles.exists(old), hasLive = try PersonalDataFiles.exists(live)
            if journal.originals[name] == true {
                if hasOld {
                    journal.steps[name] = "restoring"; try save(journal)
                    if hasLive { try FileManager.default.removeItem(at: live) }
                    try FileManager.default.moveItem(at: old, to: live)
                } else {
                    // moving can be interrupted before rename; restoring can be interrupted after rename.
                    guard hasLive, step == "moving" || step == "restoring" else { throw PersonalDataError("original-missing") }
                }
            } else if hasLive {
                guard ["installing", "installed", "restoring"].contains(step) else { throw PersonalDataError("unexpected-live") }
                journal.steps[name] = "restoring"; try save(journal)
                try FileManager.default.removeItem(at: live)
            }
            journal.steps[name] = "restored"; try save(journal)
        }
        return journal.rollbackPreferences
    }
    func commit() throws {
        guard var journal = try load() else { throw PersonalDataError("journal-missing") }
        journal.phase = "committed"; try save(journal)
    }
    func cleanup() throws {
        for name in ["old", "new", "journal.json"] {
            let file = root.appendingPathComponent(name)
            if try PersonalDataFiles.exists(file) { try FileManager.default.removeItem(at: file) }
        }
        try FileManager.default.removeItem(at: root)
    }

    @MainActor static func recover(user: URL, defaults: UserDefaults) throws {
        let transaction = Self(user: user)
        guard let journal = try transaction.load() else { return }
        let preferences = journal.phase == "committed" ? journal.incomingPreferences : try transaction.rollback()
        try IFSettings.writePersonalPreferences(preferences, defaults: defaults)
        guard defaults.synchronize() else { throw PersonalDataError("preferences-persistence") }
        try transaction.cleanup()
    }
}

@MainActor
final class PersonalDataController {
    let user: URL
    let helper: URL
    let settings: IFSettings
    let coordinator: IFDictionaryCoordinator
    var persistPreferences: @MainActor () async -> Bool
    init(user: URL, helper: URL, settings: IFSettings, coordinator: IFDictionaryCoordinator) {
        self.user = user; self.helper = helper; self.settings = settings; self.coordinator = coordinator
        persistPreferences = { await settings.synchronizePersonalPreferences() }
    }
    private func staging() async throws -> URL {
        let root = user.appendingPathComponent("PersonalData/staging/\(UUID().uuidString)")
        try await Task.detached { try PersonalDataFiles.directory(root.appendingPathComponent("databases")) }.value
        return root
    }
    func export(to destination: URL) async throws {
        let preferences = try settings.personalBackupSettings(), version = IFEngine.version
        let root = try await staging(), user = self.user, helper = self.helper
        defer { Task.detached { try? FileManager.default.removeItem(at: root) } }
        guard IFInputControllerVoice.personalDataIdle else { throw PersonalDataError("voice-busy") }
        let configuration = try coordinator.beginPersonalData()
        defer { coordinator.finishPersonalData() }
        do {
            try await Task.detached {
                var bytes = 0
                for name in PersonalBackupDocument.names {
                    let source = user.appendingPathComponent(name + ".userdb")
                    if try PersonalDataFiles.exists(source) {
                        bytes += try PersonalDataFiles.validateTree(source)
                        guard bytes <= 128 * 1024 * 1024 else { throw PersonalDataError("database-size") }
                        try FileManager.default.copyItem(at: source, to: root.appendingPathComponent("databases/" + name + ".userdb"))
                    }
                }
            }.value
            try coordinator.restartPersonalData(configuration, resumeInput: true)
        } catch {
            if !IFEngine.ready { try? coordinator.restartPersonalData(configuration, resumeInput: true, restoring: true) }
            throw error
        }
        try await Task.detached {
            try PersonalDataWorker(user: user, helper: helper).run(root: root, restore: false)
            var dictionaries: [String: String?] = [:]
            for name in PersonalBackupDocument.names {
                let file = root.appendingPathComponent(name + ".userdb.txt")
                if try PersonalDataFiles.exists(file) {
                    guard let text = String(data: try PersonalDataFiles.read(file, limit: 32 * 1024 * 1024), encoding: .utf8) else { throw PersonalDataError("utf8") }
                    dictionaries[name] = .some(text)
                } else { dictionaries[name] = .some(nil) }
            }
            let document = PersonalBackupDocument(rime: version, settings: preferences, dictionaries: dictionaries)
            try document.validate()
            try PersonalDataFiles.write(JSONEncoder().encode(document), destination)
        }.value
    }
    func restore(_ document: PersonalBackupDocument) async throws {
        let root = try await staging(), user = self.user, helper = self.helper
        defer { Task.detached { try? FileManager.default.removeItem(at: root) } }
        let incoming = try await Task.detached {
            try document.validate()
            return try document.settings.encodedPreferences()
        }.value
        try await Task.detached {
            for (name, snapshot) in document.dictionaries {
                if let snapshot { try PersonalDataFiles.write(Data(snapshot.utf8), root.appendingPathComponent(name + ".userdb.txt")) }
            }
            try PersonalDataWorker(user: user, helper: helper).run(root: root, restore: true)
            try PersonalDataFiles.validateTree(root.appendingPathComponent("databases"))
        }.value
        guard IFInputControllerVoice.personalDataIdle else { throw PersonalDataError("voice-busy") }
        let configuration = try coordinator.beginPersonalData()
        let transaction = PersonalDataTransaction(user: user)
        settings.personalDataApplying = true
        settings.shortcuts.personalDataRecoveryRequired = true
        defer {
            settings.personalDataApplying = false
            settings.shortcuts.personalDataRecoveryRequired = settings.personalDataRecoveryRequired
        }
        do {
            let rollback = try await settings.personalRollbackPreferences()
            try await Task.detached { try transaction.prepare(staging: root, rollback: rollback, incoming: incoming); try transaction.install() }.value
            try settings.applyPersonalPreferences(incoming)
            try coordinator.restartPersonalData(configuration)
            guard await persistPreferences() else { throw PersonalDataError("preferences-persistence") }
            try await Task.detached { try transaction.commit(); try transaction.cleanup() }.value
            coordinator.finishPersonalData()
        } catch {
            IFEngine.stop()
            do {
                if try await Task.detached(operation: { try transaction.load() }).value != nil {
                    let original = try await Task.detached { try transaction.rollback() }.value
                    try settings.applyPersonalPreferences(original)
                    guard await persistPreferences() else { throw PersonalDataError("rollback-persistence") }
                    try await Task.detached { try transaction.cleanup() }.value
                }
                try coordinator.restartPersonalData(configuration, restoring: true)
            } catch {
                // Keep reservation and input unavailable. Application restart resolves the retained journal
                // before constructing Settings; no additional personal-data transaction can proceed.
                settings.personalDataRecoveryRequired = true
                settings.shortcuts.personalDataRecoveryRequired = true
                coordinator.finishPersonalData()
                throw PersonalDataError("recovery-required")
            }
            coordinator.finishPersonalData(); throw error
        }
    }
}
