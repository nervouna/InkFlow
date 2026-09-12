import Foundation

@MainActor
extension IFEngine {
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
