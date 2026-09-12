import Foundation

/// A disposable view of the existing Rime user dictionary, never a learning authority.
struct VoiceLexiconSnapshot: Sendable, Equatable {
    enum Availability: Sendable { case available, unknown }
    struct Entry: Sendable, Equatable {
        let text: String
        let code: String
        let commits: Int
        var explicit = false
    }
    static let entryLimit = 512
    static let byteLimit = 64 * 1024
    let generation: UInt64
    let revision: UInt64
    let availability: Availability
    let entries: [Entry]

    static func unknown(generation: UInt64 = 0, revision: UInt64 = 0) -> Self {
        Self(generation: generation, revision: revision, availability: .unknown, entries: [])
    }

    init(generation: UInt64, revision: UInt64, availability: Availability, entries: [Entry]) {
        self.generation = generation; self.revision = revision; self.availability = availability
        var accepted: [Entry] = [], seen = Set<String>(), bytes = 0
        for entry in entries.prefix(Self.entryLimit * 2) {
            let size = entry.text.utf8.count + entry.code.utf8.count + 32
            guard (2...64).contains(entry.text.count), entry.commits >= 0,
                  entry.text.rangeOfCharacter(from: .controlCharacters) == nil,
                  entry.code.utf8.allSatisfy({ $0 == 32 || (97...122).contains($0) }),
                  bytes + size <= Self.byteLimit, seen.insert(entry.text).inserted else { continue }
            accepted.append(entry); bytes += size
            if accepted.count == Self.entryLimit { break }
        }
        self.entries = accepted
    }

    init(payload: String, generation: UInt64, revision: UInt64) {
        guard payload.utf8.count <= Self.byteLimit, payload.hasPrefix("ok\n") else {
            self = .unknown(generation: generation, revision: revision); return
        }
        let entries = payload.dropFirst(3).split(separator: "\n").prefix(Self.entryLimit).compactMap { line -> Entry? in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 3, let commits = Int(columns[2]) else { return nil }
            return Entry(text: String(columns[0]), code: String(columns[1]), commits: commits)
        }
        self.init(generation: generation, revision: revision, availability: .available, entries: entries)
    }

    /// Settings remains the authority for explicitly maintained phrases, ahead of automatic learning.
    func includingCustomPhrases(_ phrases: [CustomPhrase]) -> Self {
        let explicit = phrases.prefix(Self.entryLimit).map {
            Entry(text: $0.text, code: $0.code, commits: 1, explicit: true)
        }
        return Self(generation: generation, revision: revision, availability: availability, entries: explicit + entries)
    }
}

@MainActor
final class VoiceLexiconStore {
    private(set) var snapshot = VoiceLexiconSnapshot.unknown()
    private var task: Task<Void, Never>?
    private var dirty = true
    private var epoch: UInt64 = 0
    private var committedAt: Date?
    private var committedInstant: ContinuousClock.Instant?

    /// Native Rime allows undo while time(NULL) - transaction_time <= 3 seconds.
    /// Check wall time as well as monotonic elapsed time, including backward clock changes.
    var canRead: Bool {
        guard let committedAt, let committedInstant else { return true }
        return Date().timeIntervalSince(committedAt) >= 4 && committedInstant.duration(to: .now) >= .seconds(4)
    }

    func nativeCommit() {
        committedAt = Date(); committedInstant = .now; dirty = true
    }

    func reset() {
        task?.cancel(); task = nil; dirty = true; epoch &+= 1
        snapshot = .unknown(generation: epoch)
        committedAt = nil; committedInstant = nil
    }

    func markDirty() { dirty = true }

    /// Called by the engine's deferred idle notification, independently of dictionary activation.
    func prepareIfNeeded() {
        guard dirty, task == nil, IFEngine.ready else { return }
        let expectedEpoch = epoch
        let delay: Duration = canRead ? .milliseconds(250) : .seconds(4)
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.epoch == expectedEpoch else { return }
            self.task = nil
            guard IFEngine.ready, IFEngine.allSessionsIdle,
                  let engine = IFEngine.liveSessions.first(where: \.available) else { return }
            // allSessionsIdle may drain a new commit. Check its undo window afterwards.
            guard self.canRead else { self.prepareIfNeeded(); return }
            // Temporary UserDictionary destruction commits the shared native transaction.
            // Delay reads until its ordinary undo window has already expired. No handles
            // survive the call; Memory.disconnect makes its remaining callbacks inert.
            self.snapshot = engine.readVoiceLexicon(generation: expectedEpoch, revision: self.snapshot.revision &+ 1)
            self.dirty = false
        }
    }
}

@MainActor
extension IFEngine {
    func readVoiceLexicon(generation: UInt64, revision: UInt64) -> VoiceLexiconSnapshot {
        guard available, Self.allSessionsIdle, Self.voiceLexicon.canRead else {
            return .unknown(generation: generation, revision: revision)
        }
        let api = Self.api.pointee
        api.set_property(session, "inkflow_voice_lexicon_result", "")
        api.set_property(session, "inkflow_voice_lexicon", "read")
        defer {
            api.set_property(session, "inkflow_voice_lexicon", "")
            api.set_property(session, "inkflow_voice_lexicon_result", "")
        }
        var buffer = [CChar](repeating: 0, count: VoiceLexiconSnapshot.byteLimit + 1)
        guard api.get_property(session, "inkflow_voice_lexicon_result", &buffer, buffer.count) != 0 else {
            return .unknown(generation: generation, revision: revision)
        }
        let payload = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return VoiceLexiconSnapshot(payload: payload, generation: generation, revision: revision)
    }
}

enum VoiceAlternativeReranker {
    /// Ranges must preserve the ASR text exactly, with its primary spelling first.
    /// Only alternatives already offered by ASR are eligible; never invent a homophone replacement.
    static func select(_ ranges: [[String]], snapshot: VoiceLexiconSnapshot, fixedPrefix: String = "") -> String {
        let primary = ranges.compactMap(\.first).joined()
        guard ranges.count <= 64, primary.utf16.count <= 16_000, !snapshot.entries.isEmpty else { return primary }
        // Explicit character spelling is stronger evidence than a learned homophone.
        guard primary.range(of: #"([\p{Han}])[\p{Han}]{0,4}的\1"#, options: .regularExpression) == nil else { return primary }
        let prefix = String(fixedPrefix.suffix(8))
        var paths = [""]
        for range in ranges {
            guard let first = range.first else { continue }
            let normalized = latin(first)
            var seen = Set<String>()
            let alternatives = range.prefix(8).filter {
                $0.utf16.count <= 16_000 && latin($0) == normalized && seen.insert($0).inserted
            }
            var next: [String] = []
            expansion: for path in paths {
                for alternative in alternatives {
                    let combined = path + alternative
                    if combined.utf16.count <= 16_000 { next.append(combined) }
                    if next.count == 128 { break expansion }
                }
            }
            // Stable beam ordering retains Apple order on ties. Score each path only once.
            var scored: [(text: String, index: Int, value: Int)] = []
            for (index, text) in next.enumerated() {
                scored.append((text, index, score(prefix + text, entries: snapshot.entries)))
            }
            scored.sort { $0.value == $1.value ? $0.index < $1.index : $0.value > $1.value }
            paths = scored.map(\.text)
        }
        var best = primary, bestScore = score(prefix + primary, entries: snapshot.entries)
        for path in paths {
            let candidateScore = score(prefix + path, entries: snapshot.entries)
            if candidateScore > bestScore { best = path; bestScore = candidateScore }
        }
        return best
    }

    private static func latin(_ text: String) -> String {
        (text.applyingTransform(.toLatin, reverse: false) ?? text)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined()
    }

    private static func score(_ text: String, entries: [VoiceLexiconSnapshot.Entry]) -> Int {
        entries.reduce(0) { score, entry in
            guard text.contains(entry.text) else { return score }
            return score + (entry.explicit ? 8192 : min(entry.commits, 8))
        }
    }
}
