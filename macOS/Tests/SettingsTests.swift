import Foundation
import AppKit
#if SWIFT_PACKAGE
@testable import InkFlowCore
import InkFlowTestSupport
#endif

@main
struct SettingsTests {
    @MainActor static func main() async throws {
        let isolated = IsolatedSettings()
        defer { isolated.cleanup() }
        let defaults = isolated.defaults
        let settings = isolated.settings
        check(settings.candidateCount == 5 && !settings.vertical && settings.fontSize == 14 && !settings.thunderMode)
        check(settings.inputPreferences[.bracketPaging] && !settings.inputPreferences[.minusEqualPaging],
              "Only square brackets page by default")
        groupedInputPreferences()
        configurableShortcuts()
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
        settings.candidateCount = 9; settings.fontSize = 36; settings.vertical = true; settings.thunderMode = true
        let reload = IFSettings(defaults: defaults)
        check(reload.candidateCount == 9 && reload.fontSize == 36 && reload.vertical && reload.thunderMode)
        for count in 3...9 { settings.candidateCount = count; check(settings.candidateCount == count) }
        for size in [14, 16, 18, 24, 36] { settings.fontSize = size; check(settings.fontSize == size) }
        settings.candidateCount = 1; settings.fontSize = 15
        check(settings.candidateCount == 5 && settings.fontSize == 14)
        try customPhrases(defaults: defaults, settings: settings)
        UpdateTests.run()
        try await feedbackReports()
        await DiagnosticFeedbackModelTests.run()
        defaults.set("yes", forKey: "thunderMode")
        check(!settings.thunderMode, "Malformed Thunder preference must use the safe default")
        print("PASS settings: defaults, malformed values, bounds, and persistence")
    }

    @MainActor static func configurableShortcuts() {
        let isolated = IsolatedSettings(); defer { isolated.cleanup() }
        let shortcuts = isolated.settings.shortcuts
        check(ShortcutAction.allCases.map(\.rawValue) == ["inputMode", "punctuation", "script", "voiceHold", "voiceToggle"],
              "Only five customizable commands are exposed; AI acceptance remains fixed")
        check(shortcuts.binding(for: .inputMode) == .leftShift && shortcuts.binding(for: .voiceHold) == .rightShift
              && shortcuts.binding(for: .voiceToggle) == .rightShift)
        check(shortcuts.binding(for: .punctuation) == .none && shortcuts.binding(for: .script) == .none)
        let chord = ShortcutBinding.recorded(from: keyEvent(40, "k", [.control, .option, .shift]))!
        check(shortcuts.set(chord, for: .punctuation), "A recorded combination outside the old preset list is supported")
        check(chord.matches(keyEvent(40, "K", [.control, .option, .shift, .capsLock])), "Matching uses physical key and ignores Caps Lock")
        check(!chord.matches(keyEvent(40, "k", [.control, .option])) && !chord.matches(keyEvent(37, "k", [.control, .option, .shift])),
              "Both modifier set and physical key must match")
        check(!shortcuts.set(chord, for: .script) && shortcuts.error != nil && shortcuts.binding(for: .script) == .none,
              "A conflicting assignment leaves the previous binding intact")
        check(shortcuts.set(chord, for: .punctuation))
        let reload = KeyboardShortcuts(defaults: isolated.defaults)
        check(reload.binding(for: .punctuation) == chord && reload.binding(for: .punctuation).title == chord.title,
              "Recorded identity and display label survive persistence")
        check(shortcuts.set(.none, for: .inputMode))
        check(KeyboardShortcuts(defaults: isolated.defaults).binding(for: .inputMode) == .none,
              "Explicitly clearing a default binding survives reload")
        check(shortcuts.set(chord, for: .inputMode) == false)
        check(shortcuts.set(.none, for: .punctuation))
        check(shortcuts.set(chord, for: .voiceHold) && shortcuts.set(chord, for: .voiceToggle),
              "Hold and double-tap may share the same recorded combination")
        for event in [keyEvent(0, "a"), keyEvent(48, "\t"), keyEvent(7, "x", .command), keyEvent(49, " ", .command)] {
            let invalid = ShortcutBinding.recorded(from: event)!
            check(!shortcuts.set(invalid, for: .script) && shortcuts.error != nil,
                  "Typing keys, fixed Tab, and reserved system/application commands must be rejected")
        }
        check(!shortcuts.set(.leftShift, for: .script), "Punctuation/script commands require combinations")
        let modifiedTab = ShortcutBinding.recorded(from: keyEvent(48, "\t", [.control, .option]))!
        check(shortcuts.set(modifiedTab, for: .script), "Reserving plain Tab does not reserve every modified Tab chord")
        let functionKey = ShortcutBinding.recorded(from: keyEvent(122, "", .function))!
        check(shortcuts.set(functionKey, for: .script), "An unmodified function key is recordable")
        let revision = shortcuts.revision
        shortcuts.restoreDefaults()
        check(shortcuts.revision > revision && shortcuts.error == nil,
              "Restoring defaults publishes a runtime cancellation revision")
        let restored = KeyboardShortcuts(defaults: isolated.defaults)
        check(restored.binding(for: .inputMode) == .leftShift && restored.binding(for: .voiceHold) == .rightShift
              && restored.binding(for: .voiceToggle) == .rightShift && restored.binding(for: .script) == .none)
        isolated.defaults.set(Data("{broken".utf8), forKey: "shortcut.inputMode")
        check(KeyboardShortcuts(defaults: isolated.defaults).binding(for: .inputMode) == .leftShift,
              "Malformed persisted data safely falls back to the default")
        print("PASS configurable shortcuts: recording, exact matches, defaults, clear, conflicts, persistence, validation, reset revision")
    }

    static func feedbackBody(_ url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "body" })?.value ?? ""
    }

    @MainActor static func feedbackReports() async throws {
        let metadata = FeedbackMetadata(version: "0.4.1", build: "41", operatingSystem: "macOS 26.0 (25A1)")
        let calls = FeedbackTestRecorder()
        let opened = FeedbackOpenRecorder()
        let reporter = FeedbackReporter(metadata: metadata, maximumURLLength: 2_000, collectLogs: {
            await calls.recordLogCollection()
            return "2026-09-14 newest private-safe diagnostic"
        }, openURL: { url in
            opened.url = url
            return true
        })

        let withoutLogs = await reporter.prepare(includeLogs: false)
        let bodyWithoutLogs = feedbackBody(withoutLogs.url)
        let initialLogCollections = await calls.logCollections
        check(initialLogCollections == 0, "Default-off feedback must never run the log collector")
        check(withoutLogs.url.host == "github.com" && withoutLogs.url.path == "/nervouna/InkFlow/issues/new")
        check(bodyWithoutLogs.contains("墨流版本：0.4.1 (41)") && bodyWithoutLogs.contains("macOS：macOS 26.0 (25A1)"))
        check(!bodyWithoutLogs.contains("运行日志") && !bodyWithoutLogs.contains("private-safe diagnostic"),
              "Opted-out feedback must contain metadata only")

        let withLogs = await reporter.prepare(includeLogs: true)
        let includedLogCollections = await calls.logCollections
        check(includedLogCollections == 1)
        check(feedbackBody(withLogs.url).contains("newest private-safe diagnostic"))
        check(withLogs.notice == nil)

        let longLogs = (1...80).map { "record-\($0)-" + String(repeating: "诊断", count: 12) }.joined(separator: "\n")
        let bounded = FeedbackReporter(metadata: metadata, maximumURLLength: 1_200,
            collectLogs: { longLogs }, openURL: { _ in true })
        let truncated = await bounded.prepare(includeLogs: true)
        let truncatedBody = feedbackBody(truncated.url)
        check(truncated.url.absoluteString.utf8.count <= 1_200, "Final percent-encoded issue URL must respect its bound")
        check(truncatedBody.contains("日志已截断") && truncatedBody.contains("record-80-"),
              "Truncation must be explicit and retain newest records")
        check(!truncatedBody.contains("record-1-"), "Truncation must discard oldest records first")

        let failed = FeedbackReporter(metadata: metadata, maximumURLLength: 2_000, collectLogs: {
            throw NSError(domain: "FeedbackTests", code: 7)
        }, openURL: { _ in true })
        let fallback = await failed.prepare(includeLogs: true)
        let fallbackBody = feedbackBody(fallback.url)
        check(fallbackBody.contains("日志采集失败") && !fallbackBody.contains("NSError"))
        check(fallback.notice != nil, "Collection failure must be visible to the user while preserving the issue handoff")

        let commandRecorder = FeedbackCommandRecorder()
        let collector = FeedbackLogCollector(run: { executable, arguments in
            await commandRecorder.record(executable: executable, arguments: arguments)
            return "synthetic unified log"
        })
        let collected = try await collector.collect()
        check(collected == "synthetic unified log")
        let command = await commandRecorder.command
        check(command?.0.path == "/usr/bin/log")
        check(command?.1 == ["show", "--last", "10m", "--style", "compact", "--predicate",
                             "subsystem == \"io.damao.inputmethod.inkflow\""],
              "Feedback may collect only the bounded InkFlow unified-log predicate")

        _ = reporter.open(withoutLogs)
        check(opened.url == withoutLogs.url, "Injected browser handoff must receive the prepared URL")
        print("PASS feedback reports: opt-in collection, metadata-only default, exact log predicate, failure fallback and newest-first URL bound")
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

actor FeedbackTestRecorder {
    private(set) var logCollections = 0

    func recordLogCollection() { logCollections += 1 }
}

@MainActor
final class FeedbackOpenRecorder {
    var url: URL?
}

actor FeedbackCommandRecorder {
    private(set) var command: (URL, [String])?

    func record(executable: URL, arguments: [String]) { command = (executable, arguments) }
}
