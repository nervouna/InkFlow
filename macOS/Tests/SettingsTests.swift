import Foundation

@main
struct SettingsTests {
    @MainActor static func main() {
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
        print("PASS settings: defaults, malformed values, bounds, persistence")
    }
}
