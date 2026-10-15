import InkFlowPortable
import Foundation

/// A listing the core captured at one learning revision. Entries refer to it by index.
final class LearningListing: @unchecked Sendable {
    fileprivate let handle: OpaquePointer
    fileprivate init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { ifr_learning_free(handle) }
}

/// What the core needs to restore a deleted entry.
final class LearningUndoToken: @unchecked Sendable {
    fileprivate let handle: OpaquePointer
    fileprivate init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { ifr_learning_undo_free(handle) }
}

@MainActor
extension IFEngine {
    package struct PersonalLearningEntry: Equatable, Identifiable, Sendable {
        package enum Source: String, CaseIterable, Sendable { case english, voice }
        package let source: Source
        package let code: String
        package let text: String
        package let commits: Int
        package let revision: UInt64
        fileprivate let listing: LearningListing
        fileprivate let index: Int
        package var id: String { source.rawValue + "\t" + code + "\t" + text }
        package static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.source == rhs.source && lhs.code == rhs.code && lhs.text == rhs.text
                && lhs.commits == rhs.commits && lhs.revision == rhs.revision
        }
    }

    package struct PersonalLearningUndo: Sendable {
        package let entry: PersonalLearningEntry
        fileprivate let revision: UInt64
        fileprivate let token: LearningUndoToken
    }

    package enum PersonalLearningError: Error, Equatable {
        case busy, unavailable, conflict, tooLarge
    }

    /// No filesystem enumeration and no secondary store: the active Rime memories own both
    /// namespaces. This lifecycle API must never run in a key callback.
    package static func personalLearningEntries() throws -> [PersonalLearningEntry] {
        guard ready, let native else { throw PersonalLearningError.unavailable }
        guard allSessionsIdle, voiceLexicon.canRead else { throw PersonalLearningError.busy }
        var created: OpaquePointer?
        let status = ifr_personal_learning_entries(native, &created)
        guard status == ifrOK, let created else { throw learningError(status) }
        let listing = LearningListing(created)
        let revision = voiceLexicon.learningRevision
        return (0..<ifr_learning_count(created)).map { index in
            PersonalLearningEntry(source: ifr_learning_source(created, index) == Int32(IFR_LEARNING_VOICE) ? .voice : .english,
                code: ifrString(ifr_learning_code(created, index)), text: ifrString(ifr_learning_text(created, index)),
                commits: Int(ifr_learning_commits(created, index)), revision: revision, listing: listing, index: index)
        }.sorted { $0.id < $1.id }
    }

    package static func deletePersonalLearning(_ entry: PersonalLearningEntry) throws -> PersonalLearningUndo {
        guard entry.revision == voiceLexicon.learningRevision else { throw PersonalLearningError.conflict }
        guard (1..<Int(Int32.max)).contains(entry.commits) else { throw PersonalLearningError.tooLarge }
        var token: OpaquePointer?
        try personalLearningMutation { ifr_personal_learning_delete($0, entry.listing.handle, entry.index, &token) }
        guard let token else { throw PersonalLearningError.unavailable }
        return PersonalLearningUndo(entry: entry, revision: voiceLexicon.learningRevision, token: LearningUndoToken(token))
    }

    package static func undoPersonalLearning(_ undo: PersonalLearningUndo) throws {
        guard undo.revision == voiceLexicon.learningRevision else { throw PersonalLearningError.conflict }
        try personalLearningMutation { ifr_personal_learning_undo($0, undo.token.handle) }
    }

    private static func personalLearningMutation(_ operation: (OpaquePointer) -> IFRStatus) throws {
        guard ready, let native else { throw PersonalLearningError.unavailable }
        guard allSessionsIdle, voiceLexicon.canRead else { throw PersonalLearningError.busy }
        let status = operation(native)
        if Int(status) == IFR_BUSY { throw PersonalLearningError.busy }
        // The core already dropped every session's cached view. A failed native write may have applied
        // part of the operation: do not retain a stale UI snapshot or allow an older undo after any attempt.
        voiceLexicon.invalidateLearningSnapshot()
        signalIdle()
        guard status == ifrOK else { throw learningError(status) }
    }

    /// The dictionaries changed outside the engine: drop every session's cached learning view.
    package static func invalidatePersonalLearning() {
        if let native { _ = ifr_personal_learning_invalidate(native) }
        voiceLexicon.invalidateLearningSnapshot()
        signalIdle()
    }

    private static func learningError(_ status: IFRStatus) -> PersonalLearningError {
        switch Int(status) {
        case IFR_BUSY: .busy
        case IFR_CONFLICT: .conflict
        case IFR_TOO_LARGE: .tooLarge
        default: .unavailable
        }
    }
}
