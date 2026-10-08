import InkFlowDomain
import Foundation

@MainActor
extension IFEngine {
    /// Explicit lifecycle action. It touches only the two named English memories;
    /// public dictionaries and the ordinary pinyin_simp user dictionary stay open.
    @discardableResult
    package static func clearPersonalEnglishLearning() -> Bool {
        guard ready, allSessionsIdle else { return false }
        let temporary = liveSessions.isEmpty ? IFEngine() : nil
        guard let engine = liveSessions.first(where: \.available), allSessionsIdle else { return false }
        let cleared = engine.call("clear_english_learning")?.status == "ok"
        if cleared { invalidatePersonalLearning() }
        withExtendedLifetime(temporary) {}
        return cleared
    }

    @discardableResult
    package func learnVoiceCorrection(_ correction: VoiceLearnedCorrection) -> Bool {
        let canonical = correction.canonicalText.lowercased()
        guard available, (2...64).contains(correction.sourceCode.utf8.count),
              correction.sourceCode.utf8.allSatisfy({ (97...122).contains($0) }),
              (2...64).contains(correction.canonicalText.utf8.count),
              correction.canonicalText.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
              canonical.utf8.allSatisfy({ (97...122).contains($0) }) else { return false }
        let learned = call("voice_learning", [correction.sourceCode, canonical, correction.canonicalText])?.status == "ok"
        if learned { Self.voiceLexicon.markDirty(); Self.signalIdle() }
        return learned
    }

    package func readVoiceAliases(generation: UInt64 = 0, revision: UInt64 = 0) -> VoiceAliasSnapshot {
        guard available, Self.allSessionsIdle else {
            return .unknown(generation: generation, revision: revision)
        }
        guard let reply = call("voice_aliases", capacity: VoiceAliasSnapshot.byteLimit + 64) else {
            return .unknown(generation: generation, revision: revision)
        }
        return VoiceAliasSnapshot(status: reply.status, rows: reply.body, generation: generation, revision: revision)
    }

    /// Small read-only input observation; candidate presentation and quality telemetry are unrelated.
    package func aiInputIdentity() -> AIInputIdentity? {
        guard available, !asciiMode else { return nil }
        let input = Self.string(Self.api.pointee.get_input(session))
        guard !input.isEmpty else { return nil }
        var context = Self.makeContext()
        guard Self.api.pointee.get_context(session, &context) != 0 else { return nil }
        defer { _ = Self.api.pointee.free_context(&context) }
        let preedit = Self.string(context.composition.preedit)
        let offset = Int(context.composition.sel_start)
        guard offset >= 0, offset <= preedit.utf8.count,
              let prefix = String(bytes: preedit.utf8.prefix(offset), encoding: .utf8) else { return nil }
        return AIInputIdentity(rawInput: input, caret: Int(Self.api.pointee.get_caret_pos(session)), selectedPrefix: prefix)
    }

    /// Called only for a consumed AI adoption, inside the controller's delivery scope.
    /// Learning failure must never prevent insertion or register the original typo.
    @discardableResult
    package func prepareConsumedAIAdoption(input: AIInputIdentity, text: String) -> Bool {
        let preferences = inputPreferences
        let pronunciation = aiPronunciation(input: input, text: text)
        clear(recordQuality: false)
        return learnAIAdoption(input: input, text: text, preferences: preferences, pronunciation: pronunciation)
    }

    /// Low-level Rime update, also used by native learning contract regressions.
    @discardableResult
    package func learnAIAdoption(input: AIInputIdentity, text: String, preferences: InputPreferences? = nil,
                         pronunciation: AIPronunciation? = nil) -> Bool {
        guard available, text.hasPrefix(input.selectedPrefix),
              let code = (pronunciation ?? aiPronunciation(input: input, text: text)).resolve(input: input.rawInput, text: text,
                  preferences: preferences ?? inputPreferences ?? requestedInput) else { return false }
        let learned = call("ai_learning", [code, text])?.status == "ok"
        if learned { Self.voiceLexicon.markDirty(); Self.signalIdle() }
        return learned
    }

    package func allowsAIRecommendation(input: AIInputIdentity, text: String) -> Bool {
        text.hasPrefix(input.selectedPrefix) &&
            !aiPronunciation(input: input, text: text).isClearExpansion(input: input.rawInput, text: text,
                preferences: inputPreferences ?? requestedInput)
    }

    /// Read only the current recommendation's native phrase/character codes. The
    /// absolute reverse-table path follows active dictionary activation and rollback.
    package func aiPronunciation(input: AIInputIdentity, text: String) -> AIPronunciation {
        guard available else { return AIPronunciation(phrases: [:], characters: [:]) }
        let reverse = Self.compiledDirectory.appendingPathComponent("pinyin_simp.reverse.bin").path
        let reply = call("ai_readings", [reverse, input.rawInput, text], capacity: 128 * 1024)
        return AIPronunciation(text: text, nativeReadings: reply.flatMap { $0.status == "ok" ? $0.body : nil } ?? "")
    }
}
