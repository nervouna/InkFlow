import Foundation

@main
struct SettingsTests {
    @MainActor static func main() throws {
        let isolated = IsolatedSettings()
        defer { isolated.cleanup() }
        let defaults = isolated.defaults
        let settings = isolated.settings
        check(settings.candidateCount == 5 && !settings.vertical && settings.fontSize == 14)
        check(settings.inputPreferences[.bracketPaging] && !settings.inputPreferences[.minusEqualPaging],
              "Only square brackets page by default")
        groupedInputPreferences()
        for option in InputOption.allCases where ![.fuzzyZ, .fuzzyC, .fuzzyS, .bracketPaging, .minusEqualPaging].contains(option) {
            check(settings.inputPreferences[option] == option.defaultValue)
            settings.setInputOption(option, enabled: !option.defaultValue)
            check(IFSettings(defaults: defaults).inputPreferences[option] == !option.defaultValue)
            for bad: Any in [2, "true", 0.5, [Int]()] {
                defaults.set(bad, forKey: "input.\(option.rawValue)")
                check(settings.inputPreferences[option] == option.defaultValue)
            }
            defaults.removeObject(forKey: "input.\(option.rawValue)")
        }
        settings.setInputOption(.cornerQuotes, enabled: false)
        settings.setInputOption(.englishPunctuation, enabled: true)
        settings.setInputOption(.englishPunctuation, enabled: false)
        check(!settings.inputPreferences[.cornerQuotes], "English punctuation preserves every mapping choice")
        settings.setInputOption(.cornerQuotes, enabled: true)
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

    @MainActor static func groupedInputPreferences() {
        let isolated = IsolatedSettings()
        defer { isolated.cleanup() }
        let defaults = isolated.defaults, settings = isolated.settings
        let fuzzy: [InputOption] = [.fuzzyZ, .fuzzyC, .fuzzyS]
        for mask in 0..<8 {
            for (index, option) in fuzzy.enumerated() {
                defaults.set(mask & (1 << index) != 0, forKey: "input.\(option.rawValue)")
            }
            let snapshot = IFSettings(defaults: defaults).inputPreferences
            check(fuzzy.allSatisfy { snapshot[$0] == (mask != 0) }, "Any legacy fuzzy pair enables all three: \(mask)")
        }
        for mask in 0..<4 {
            defaults.set(mask & 1 != 0, forKey: "input.bracketPaging")
            defaults.set(mask & 2 != 0, forKey: "input.minusEqualPaging")
            let snapshot = IFSettings(defaults: defaults).inputPreferences
            check(snapshot[.minusEqualPaging] == (mask == 2) && snapshot[.bracketPaging] == (mask != 2),
                  "Only legacy exclusive minus/equal is preserved: \(mask)")
        }
        for option in InputOption.allCases { defaults.removeObject(forKey: "input.\(option.rawValue)") }
        for bad: Any in [2, "true", 0.5, [Int]()] {
            for option in fuzzy + [.bracketPaging, .minusEqualPaging] {
                defaults.set(bad, forKey: "input.\(option.rawValue)")
            }
            check(!settings.fuzzyEnabled && settings.pagingKeys == .brackets, "Malformed grouped values use product defaults")
        }
        for option in InputOption.allCases { defaults.removeObject(forKey: "input.\(option.rawValue)") }
        var notifications: [InputPreferences] = []
        let observer = NotificationCenter.default.addObserver(forName: .settingsDidChange, object: nil, queue: nil) { note in
            guard note.object as? IFSettings === settings else { return }
            MainActor.assumeIsolated {
                let defaults = isolated.defaults
                let snapshot = settings.inputPreferences
                for option in fuzzy + [.bracketPaging, .minusEqualPaging] {
                    if defaults.object(forKey: "input.\(option.rawValue)") != nil {
                        check(defaults.bool(forKey: "input.\(option.rawValue)") == snapshot[option],
                              "Notification exposes only fully persisted grouped choices")
                    }
                }
                notifications.append(snapshot)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        settings.fuzzyEnabled = true
        check(notifications.count == 1 && fuzzy.allSatisfy { notifications[0][$0] })
        settings.fuzzyEnabled = true
        check(notifications.count == 1, "An unchanged canonical group does not notify")
        settings.pagingKeys = .minusEqual
        check(notifications.count == 2 && !notifications[1][.bracketPaging] && notifications[1][.minusEqualPaging])
        settings.pagingKeys = .brackets
        check(notifications.count == 3 && notifications[2][.bracketPaging] && !notifications[2][.minusEqualPaging])
        for option in fuzzy { settings.setInputOption(option, enabled: false) }
        check(notifications.count == 4 && fuzzy.allSatisfy { !notifications[3][$0] })
        settings.setInputOption(.fuzzyC, enabled: true)
        check(fuzzy.allSatisfy { settings.inputPreferences[$0] }, "Individual setter cannot split the fuzzy group")
        check(notifications.count == 5)
        settings.setInputOption(.bracketPaging, enabled: false)
        check(settings.pagingKeys == .minusEqual && notifications.count == 6)
        settings.setInputOption(.minusEqualPaging, enabled: false)
        check(settings.pagingKeys == .brackets && notifications.count == 7)
        let restored = IFSettings(defaults: defaults)
        check(restored.fuzzyEnabled && restored.pagingKeys == .brackets)
        check(restored.inputPreferences.recordedValues == notifications.last?.recordedValues)
        defaults.set(false, forKey: "input.fuzzyZ")
        settings.fuzzyEnabled = true
        check(notifications.count == 8 && fuzzy.allSatisfy { defaults.bool(forKey: "input.\($0.rawValue)") },
              "Writing an already-effective legacy fuzzy value still completes all stored bits")
        print("PASS grouped input preferences: 8 fuzzy/4 paging legacy states, malformed defaults, atomic notifications, canonical setters and recorded values")
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
