import Foundation

@MainActor
extension IFEngine {
    /// Explicit lifecycle action. It touches only the two named English memories;
    /// public dictionaries and the ordinary pinyin_simp user dictionary stay open.
    @discardableResult
    static func clearPersonalEnglishLearning() -> Bool {
        guard ready, allSessionsIdle else { return false }
        let temporary = liveSessions.isEmpty ? IFEngine() : nil
        guard let engine = liveSessions.first(where: \.available), allSessionsIdle else { return false }
        let api = Self.api.pointee
        api.set_property(engine.session, "inkflow_clear_english_learning_result", "")
        api.set_property(engine.session, "inkflow_clear_english_learning", "clear")
        api.set_property(engine.session, "inkflow_clear_english_learning", "")
        var result = [CChar](repeating: 0, count: 16)
        let read = api.get_property(engine.session, "inkflow_clear_english_learning_result", &result, result.count)
        api.set_property(engine.session, "inkflow_clear_english_learning_result", "")
        let cleared = read != 0 && Self.string(result) == "ok"
        if cleared { voiceLexicon.markDirty(); signalIdle() }
        withExtendedLifetime(temporary) {}
        return cleared
    }

    @discardableResult
    func learnVoiceCorrection(_ correction: VoiceLearnedCorrection) -> Bool {
        let canonical = correction.canonicalText.lowercased()
        guard available, (2...64).contains(correction.sourceCode.utf8.count),
              correction.sourceCode.utf8.allSatisfy({ (97...122).contains($0) }),
              (2...64).contains(correction.canonicalText.utf8.count),
              correction.canonicalText.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
              canonical.utf8.allSatisfy({ (97...122).contains($0) }) else { return false }
        let api = Self.api.pointee
        let payload = correction.sourceCode + "\t" + canonical + "\t" + correction.canonicalText
        api.set_property(session, "inkflow_voice_learning_result", "")
        payload.withCString { api.set_property(session, "inkflow_voice_learning", $0) }
        api.set_property(session, "inkflow_voice_learning", "")
        var result = [CChar](repeating: 0, count: 16)
        let read = api.get_property(session, "inkflow_voice_learning_result", &result, result.count)
        api.set_property(session, "inkflow_voice_learning_result", "")
        let learned = read != 0 && Self.string(result) == "ok"
        if learned { Self.voiceLexicon.markDirty(); Self.signalIdle() }
        return learned
    }

    func readVoiceAliases(generation: UInt64 = 0, revision: UInt64 = 0) -> VoiceAliasSnapshot {
        guard available, Self.allSessionsIdle else {
            return .unknown(generation: generation, revision: revision)
        }
        let api = Self.api.pointee
        api.set_property(session, "inkflow_voice_aliases_result", "")
        api.set_property(session, "inkflow_voice_aliases", "read")
        defer {
            api.set_property(session, "inkflow_voice_aliases", "")
            api.set_property(session, "inkflow_voice_aliases_result", "")
        }
        var buffer = [CChar](repeating: 0, count: VoiceAliasSnapshot.byteLimit + 1)
        guard api.get_property(session, "inkflow_voice_aliases_result", &buffer, buffer.count) != 0 else {
            return .unknown(generation: generation, revision: revision)
        }
        let payload = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return VoiceAliasSnapshot(payload: payload, generation: generation, revision: revision)
    }

    /// Small read-only input observation; candidate presentation and quality telemetry are unrelated.
    func aiInputIdentity() -> AIInputIdentity? {
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
    func learnAIAdoption(input: AIInputIdentity, text: String, preferences: InputPreferences? = nil,
                         pronunciation: AIPronunciation? = nil) -> Bool {
        guard available, text.hasPrefix(input.selectedPrefix),
              let code = (pronunciation ?? aiPronunciation(input: input, text: text)).resolve(input: input.rawInput, text: text,
                  preferences: preferences ?? inputPreferences ?? requestedInput) else { return false }
        let api = Self.api.pointee
        let payload = code + "\t" + text
        api.set_property(session, "inkflow_ai_learning_result", "")
        payload.withCString { api.set_property(session, "inkflow_ai_learning", $0) }
        // Properties are transport only: retain no adopted text in the live context.
        api.set_property(session, "inkflow_ai_learning", "")
        var result = [CChar](repeating: 0, count: 16)
        let read = api.get_property(session, "inkflow_ai_learning_result", &result, result.count)
        api.set_property(session, "inkflow_ai_learning_result", "")
        let learned = read != 0 && String(decoding: result.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == "ok"
        if learned { Self.voiceLexicon.markDirty(); Self.signalIdle() }
        return learned
    }

    func allowsAIRecommendation(input: AIInputIdentity, text: String) -> Bool {
        text.hasPrefix(input.selectedPrefix) &&
            !aiPronunciation(input: input, text: text).isClearExpansion(input: input.rawInput, text: text,
                preferences: inputPreferences ?? requestedInput)
    }

    /// Read only the current recommendation's native phrase/character codes. The
    /// absolute reverse-table path follows active dictionary activation and rollback.
    func aiPronunciation(input: AIInputIdentity, text: String) -> AIPronunciation {
        guard available else { return AIPronunciation(phrases: [:], characters: [:]) }
        let api = Self.api.pointee
        Self.compiledDirectory.appendingPathComponent("pinyin_simp.reverse.bin").path.withCString {
            api.set_property(session, "inkflow_ai_reverse_path", $0)
        }
        api.set_property(session, "inkflow_ai_readings_result", "")
        (input.rawInput + "\t" + text).withCString { api.set_property(session, "inkflow_ai_readings", $0) }
        var result = [CChar](repeating: 0, count: 128 * 1024)
        let read = api.get_property(session, "inkflow_ai_readings_result", &result, result.count)
        for name in ["inkflow_ai_readings", "inkflow_ai_readings_result", "inkflow_ai_reverse_path"] {
            api.set_property(session, name, "")
        }
        let readings = read != 0 ? String(decoding: result.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        return AIPronunciation(text: text, nativeReadings: readings)
    }
}
