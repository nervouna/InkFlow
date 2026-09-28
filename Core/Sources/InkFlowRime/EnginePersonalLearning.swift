import Foundation

@MainActor
extension IFEngine {
    package struct PersonalLearningEntry: Equatable, Identifiable, Sendable {
        package enum Source: String, CaseIterable, Sendable { case english, voice }
        package let source: Source
        package let code: String
        package let text: String
        package let commits: Int
        package let revision: UInt64
        package var id: String { source.rawValue + "\t" + code + "\t" + text }
        fileprivate var payload: String { id + "\t" + String(commits) }
    }

    package struct PersonalLearningUndo: Sendable {
        package let entry: PersonalLearningEntry
        fileprivate let revision: UInt64
    }

    package enum PersonalLearningError: Error, Equatable {
        case busy, unavailable, conflict, tooLarge
    }

    /// No filesystem enumeration and no secondary store: the active Rime memories
    /// own both namespaces. This lifecycle API must never run in a key callback.
    package static func personalLearningEntries() throws -> [PersonalLearningEntry] {
        let result = try personalLearningRequest("list")
        guard result.hasPrefix("ok\n"), result.hasSuffix("\n") else { throw PersonalLearningError.unavailable }
        let lines = result.dropFirst(3).split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        guard lines.count <= 8192 else { throw PersonalLearningError.tooLarge }
        var ids = Set<String>()
        return try lines.map { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 4, let source = PersonalLearningEntry.Source(rawValue: String(parts[0])),
                  (1...64).contains(parts[1].utf8.count), parts[1].utf8.allSatisfy({ (97...122).contains($0) }),
                  (1...256).contains(parts[2].utf8.count), !parts[2].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let count = Int(parts[3]), count > 0 else { throw PersonalLearningError.unavailable }
            let entry = PersonalLearningEntry(source: source, code: String(parts[1]), text: String(parts[2]),
                                              commits: count, revision: voiceLexicon.learningRevision)
            guard ids.insert(entry.id).inserted else { throw PersonalLearningError.unavailable }
            return entry
        }.sorted { $0.id < $1.id }
    }

    package static func deletePersonalLearning(_ entry: PersonalLearningEntry) throws -> PersonalLearningUndo {
        guard entry.revision == voiceLexicon.learningRevision else { throw PersonalLearningError.conflict }
        guard (1..<Int(Int32.max)).contains(entry.commits) else { throw PersonalLearningError.tooLarge }
        try personalLearningMutation("delete\t" + entry.payload)
        return PersonalLearningUndo(entry: entry, revision: voiceLexicon.learningRevision)
    }

    package static func undoPersonalLearning(_ undo: PersonalLearningUndo) throws {
        guard undo.revision == voiceLexicon.learningRevision else { throw PersonalLearningError.conflict }
        try personalLearningMutation("restore\t" + undo.entry.payload)
    }

    private static func personalLearningMutation(_ payload: String) throws {
        let result = try personalLearningRequest(payload)
        guard result == "ok" else {
            // A failed native write may have applied part of the operation. Do not
            // retain a stale UI snapshot or allow an older undo after any attempt.
            invalidatePersonalLearning()
            throw result == "conflict" ? PersonalLearningError.conflict : .unavailable
        }
        invalidatePersonalLearning()
    }

    package static func invalidatePersonalLearning() {
        for engine in liveSessions where engine.available {
            api.pointee.set_property(engine.session, "inkflow_learning_invalidate", "1")
            api.pointee.set_property(engine.session, "inkflow_learning_invalidate", "")
        }
        voiceLexicon.invalidateLearningSnapshot()
        signalIdle()
    }

    private static func personalLearningRequest(_ payload: String) throws -> String {
        guard ready else { throw PersonalLearningError.unavailable }
        guard allSessionsIdle, voiceLexicon.canRead else { throw PersonalLearningError.busy }
        let temporary = liveSessions.isEmpty ? IFEngine() : nil
        defer { withExtendedLifetime(temporary) {} }
        guard let engine = liveSessions.first(where: \.available), allSessionsIdle, voiceLexicon.canRead else {
            throw PersonalLearningError.busy
        }
        let api = Self.api.pointee
        api.set_property(engine.session, "inkflow_learning_manage_result", "")
        payload.withCString { api.set_property(engine.session, "inkflow_learning_manage", $0) }
        defer {
            api.set_property(engine.session, "inkflow_learning_manage", "")
            api.set_property(engine.session, "inkflow_learning_manage_result", "")
        }
        var buffer = [CChar](repeating: 0, count: 3 * 1024 * 1024)
        guard api.get_property(engine.session, "inkflow_learning_manage_result", &buffer, buffer.count) != 0,
              let end = buffer.firstIndex(of: 0), end < buffer.count - 1 else { throw PersonalLearningError.unavailable }
        return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
