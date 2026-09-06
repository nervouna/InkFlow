import Foundation

@main
struct SettingsTests {
    @MainActor static func main() throws {
        let isolated = IsolatedSettings()
        defer { isolated.cleanup() }
        let defaults = isolated.defaults
        let settings = isolated.settings
        check(settings.candidateCount == 5 && !settings.vertical && settings.fontSize == 14)
        for bad: Any in [2, 10, 3.5, "9", [Int](), true] {
            defaults.set(bad, forKey: "candidateCount")
            check(settings.candidateCount == 5)
        }
        for bad: Any in [15, 0, "18", [Int]()] {
            defaults.set(bad, forKey: "fontSize")
            check(settings.fontSize == 14)
        }
        defaults.set("yes", forKey: "vertical")
        check(!settings.vertical)
        settings.candidateCount = 9; settings.fontSize = 36; settings.vertical = true
        let reload = IFSettings(defaults: defaults)
        check(reload.candidateCount == 9 && reload.fontSize == 36 && reload.vertical)
        for count in 3...9 { settings.candidateCount = count; check(settings.candidateCount == count) }
        for size in [14, 16, 18, 24, 36] { settings.fontSize = size; check(settings.fontSize == size) }
        settings.candidateCount = 1; settings.fontSize = 15
        check(settings.candidateCount == 5 && settings.fontSize == 14)
        try customPhrases(defaults: defaults, settings: settings)
        print("PASS settings: defaults, malformed values, bounds, persistence")
    }

    @MainActor static func customPhrases(defaults: UserDefaults, settings: IFSettings) throws {
        check(settings.customPhrases.isEmpty && settings.customPhrasesLoadError == nil)
        let first = try settings.saveCustomPhrase(code: " DZ ", text: " 台北市信义区 ")
        let second = try settings.saveCustomPhrase(code: "dz", text: "另一个地址😀")
        check(first.code == "dz" && first.text == "台北市信义区")
        check(first.id != second.id && settings.customPhrases.count == 2)
        let reopened = IFSettings(defaults: defaults)
        check(reopened.customPhrases == settings.customPhrases, "IDs, normalized codes and Unicode text must persist")
        let saved = defaults.data(forKey: "customPhrases")!
        for code in ["", "  ", "d1", "d z", "中文", "é", "a\tb", "a\nb", "a'"] {
            rejects { _ = try settings.saveCustomPhrase(code: code, text: "短语") }
        }
        for phrase in ["", "  ", "a\tb", "a\nb", "a\rb", "a\0b", "a\u{2028}b", "a\u{7f}b"] {
            rejects { _ = try settings.saveCustomPhrase(code: "test", text: phrase) }
        }
        rejects { _ = try settings.saveCustomPhrase(code: "DZ", text: first.text) }
        rejects { _ = try settings.saveCustomPhrase(id: first.id, code: second.code, text: second.text) }
        rejects { try settings.deleteCustomPhrase(id: UUID()) }
        rejects { _ = try settings.saveCustomPhrase(id: UUID(), code: "a", text: "未知条目") }
        check(defaults.data(forKey: "customPhrases") == saved, "Rejected edits must not change persistence")
        let edited = try settings.saveCustomPhrase(id: first.id, code: "addr", text: "新地址")
        check(edited.id == first.id && settings.customPhrases.first == edited)
        try settings.deleteCustomPhrase(id: second.id)
        check(IFSettings(defaults: defaults).customPhrases == [edited])
        try settings.deleteCustomPhrase(id: first.id)
        check(IFSettings(defaults: defaults).customPhrases.isEmpty)

        let invalid = CustomPhrase(id: UUID(), code: "bad\tcode", text: "文本")
        let badValues: [Any] = ["not data", Data("broken json".utf8),
            try JSONEncoder().encode([invalid]), try JSONEncoder().encode([first, first])]
        for bad in badValues {
            defaults.set(bad, forKey: "customPhrases")
            let corrupt = IFSettings(defaults: defaults)
            check(corrupt.customPhrases.isEmpty && corrupt.customPhrasesLoadError != nil)
            rejects { _ = try corrupt.saveCustomPhrase(code: "a", text: "不能覆盖损坏数据") }
            check((defaults.object(forKey: "customPhrases") as! NSObject).isEqual(bad))
        }
        defaults.removeObject(forKey: "customPhrases")
        print("PASS custom phrase settings: CRUD, normalized codes, shared codes, Unicode, duplicates, control characters, round-trip IDs, malformed data preserved")
    }

    @MainActor static func rejects(_ operation: () throws -> Void) {
        do { try operation(); check(false, "Invalid custom phrase operation must fail") }
        catch { check(!error.localizedDescription.isEmpty) }
    }
}
