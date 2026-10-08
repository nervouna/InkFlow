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
        fileprivate var fields: [String] { [source.rawValue, code, text, String(commits)] }
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
        let reply = try personalLearningRequest(["list"])
        guard reply.status == "ok", reply.body.isEmpty || reply.body.hasSuffix("\n") else { throw PersonalLearningError.unavailable }
        let lines = reply.body.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
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
        try personalLearningMutation(["delete"] + entry.fields)
        return PersonalLearningUndo(entry: entry, revision: voiceLexicon.learningRevision)
    }

    package static func undoPersonalLearning(_ undo: PersonalLearningUndo) throws {
        guard undo.revision == voiceLexicon.learningRevision else { throw PersonalLearningError.conflict }
        try personalLearningMutation(["restore"] + undo.entry.fields)
    }

    private static func personalLearningMutation(_ fields: [String]) throws {
        let status = try personalLearningRequest(fields).status
        guard status == "ok" else {
            // A failed native write may have applied part of the operation. Do not
            // retain a stale UI snapshot or allow an older undo after any attempt.
            invalidatePersonalLearning()
            throw status == "conflict" ? PersonalLearningError.conflict : .unavailable
        }
        invalidatePersonalLearning()
    }

    package static func invalidatePersonalLearning() {
        for engine in liveSessions where engine.available { _ = engine.call("learning_invalidate") }
        voiceLexicon.invalidateLearningSnapshot()
        signalIdle()
    }

    private static func personalLearningRequest(_ fields: [String]) throws -> IFRimeChannel.Reply {
        guard ready else { throw PersonalLearningError.unavailable }
        guard allSessionsIdle, voiceLexicon.canRead else { throw PersonalLearningError.busy }
        let temporary = liveSessions.isEmpty ? IFEngine() : nil
        defer { withExtendedLifetime(temporary) {} }
        guard let engine = liveSessions.first(where: \.available), allSessionsIdle, voiceLexicon.canRead else {
            throw PersonalLearningError.busy
        }
        guard let reply = engine.call("learning_manage", fields, capacity: 3 * 1024 * 1024) else {
            throw PersonalLearningError.unavailable
        }
        return reply
    }
}
