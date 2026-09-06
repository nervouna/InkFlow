import InputMethodKit

@MainActor
final class RecordingClient: NSObject, @preconcurrency IMKTextInput {
    var mutations: [String] = []
    func insertText(_ string: Any!, replacementRange: NSRange) {
        check(replacementRange == NSRange(location: NSNotFound, length: 0))
        mutations.append("insert:\(string as! String)")
    }
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        check(replacementRange == NSRange(location: NSNotFound, length: 0))
        let text = string as! String
        check(selectionRange.location <= text.utf16.count)
        mutations.append("mark:\(text)")
    }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! { nil }
    func length() -> Int { 0 }
    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode,
                        inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { NSNotFound }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! { [:] }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed name: String!) {}
    func selectMode(_ identifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String! { "inkflow.recording-client" }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { "inkflow.recording-client" }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { nil }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
}

@main
struct ControllerTests {
    @MainActor static func main() throws {
        check(CommandLine.arguments.count == 3)
        let isolated = IsolatedSettings()
        defer { isolated.cleanup() }
        try IFEngine.start(shared: CommandLine.arguments[1], user: CommandLine.arguments[2])
        IFStubHeadlessControllerFramework()
        runCases(settings: isolated.settings)
        try customPhrases(settings: isolated.settings)
        try customPhraseFailure(settings: isolated.settings, user: CommandLine.arguments[2])
        IFEngine.stop()
        print("PASS controller: idle client unchanged, Escape clears owned mark once, commit inserts once without empty replacement, consecutive quotes and shifted punctuation")
    }

    @MainActor static func customPhraseFailure(settings: IFSettings, user: String) throws {
        let client = RecordingClient()
        let controller = InkFlowInputController(server: nil, delegate: nil, client: client,
                                                settings: settings, settingsWindow: IFSettingsWindowController(settings: settings))!
        let engine = controller.engine!
        let files = FileManager.default
        let permissions = try files.attributesOfItem(atPath: user)[.posixPermissions]!
        let phrase: CustomPhrase, warning: String?, handled: Bool, retained: Bool
        do {
            try files.setAttributes([.posixPermissions: 0o500], ofItemAtPath: user)
            defer {
                do { try files.setAttributes([.posixPermissions: permissions], ofItemAtPath: user) }
                catch { check(false, "Cannot restore temporary directory permissions: \(error)") }
            }
            phrase = try settings.saveCustomPhrase(code: "dz", text: "警告恢复后的地址")
            warning = settings.inputSettingsError
            handled = controller.handle(keyEvent(0, "d"), client: client)
            retained = settings.inputSettingsError == warning && engine.configurationError == warning
        }
        // Check after the defer restored permissions, including on the expected RED run.
        check(warning != nil, "An unwritable phrase directory must produce a settings warning")
        check(handled && !engine.snapshot().preedit.isEmpty)
        check(retained, "CP-001: typing must retain the warning while failed settings remain deferred")
        check(controller.handle(keyEvent(0, "z"), client: client))
        check(settings.inputSettingsError == warning, "Restored permissions alone must not clear a deferred warning")
        check(controller.handle(keyEvent(53, ""), client: client))
        check(settings.inputSettingsError == nil && engine.configurationError == nil)
        for letter in "dz" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
        check(engine.snapshot().candidates.first == phrase.text)
        check(controller.handle(keyEvent(53, ""), client: client))

        let failedAgain: Bool, reverted: Bool
        do {
            try files.setAttributes([.posixPermissions: 0o500], ofItemAtPath: user)
            defer {
                do { try files.setAttributes([.posixPermissions: permissions], ofItemAtPath: user) }
                catch { check(false, "Cannot restore temporary directory permissions: \(error)") }
            }
            try settings.saveCustomPhrase(id: phrase.id, code: phrase.code, text: "尚未载入的修改")
            failedAgain = settings.inputSettingsError != nil
            try settings.saveCustomPhrase(id: phrase.id, code: phrase.code, text: phrase.text)
            reverted = settings.inputSettingsError == nil && engine.configurationError == nil
        }
        check(failedAgain && reverted, "Returning to the already-applied configuration must clear the warning")
        try settings.deleteCustomPhrase(id: phrase.id)
        print("PASS CP-001: write failure warning survives typing/deferred reload, clears after successful idle retry or return to applied settings")
    }

    @MainActor static func customPhrases(settings: IFSettings) throws {
        let client = RecordingClient()
        let controller = InkFlowInputController(server: nil, delegate: nil, client: client,
                                                settings: settings, settingsWindow: IFSettingsWindowController(settings: settings))!
        let engine = controller.engine!
        let phrase = try settings.saveCustomPhrase(code: "dz", text: "原地址")
        for letter in "dz" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
        check(controller.candidates(nil) as? [String] == engine.snapshot().candidates)
        check(engine.snapshot().candidates.first == "原地址")
        let old = engine.snapshot()
        client.mutations.removeAll()
        try settings.saveCustomPhrase(id: phrase.id, code: "dz", text: "新地址")
        settings.candidateCount = 3
        check(engine.snapshot() == old && engine.candidateCount == 5)
        check(!client.mutations.contains { $0.hasPrefix("insert:") }, "Settings must not commit composition")
        client.mutations.removeAll()
        check(controller.handle(keyEvent(18, "1"), client: client))
        check(client.mutations == ["insert:原地址"])
        check(engine.candidateCount == 3 && settings.inputSettingsError == nil)
        for letter in "dz" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
        check(engine.snapshot().candidates.first == "新地址")
        client.mutations.removeAll()
        controller.candidateSelected(NSAttributedString(string: "新地址"))
        check(client.mutations == ["insert:新地址"], "Native candidate callback inserts custom phrase exactly once")
        controller.commitComposition(client)
        check(client.mutations == ["insert:新地址"])
        try settings.deleteCustomPhrase(id: phrase.id)
        for letter in "dz" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
        check(!engine.snapshot().candidates.contains("新地址"))
        check(controller.handle(keyEvent(53, ""), client: client))
        settings.candidateCount = 5
        print("PASS custom phrase controller: settings notifications, deferred phrase/count reload, old composition commits once, updated next input, native click callback, deletion")
    }

    @MainActor static func runCases(settings: IFSettings) {
        let controller = InkFlowInputController(server: nil, delegate: nil, client: nil,
                                                settings: settings, settingsWindow: IFSettingsWindowController(settings: settings))!
        check(controller.engine != nil)
        let client = RecordingClient()
        check(!controller.handle(keyEvent(123, ""), client: client)); check(client.mutations.isEmpty)
        check(!controller.handle(keyEvent(0, "a", .command), client: client)); check(client.mutations.isEmpty)
        check(controller.handle(keyEvent(49, " ", [.control, .shift]), client: client)); check(client.mutations.isEmpty)
        check(!controller.handle(keyEvent(0, "a"), client: client))
        controller.commitComposition(client); controller.deactivateServer(client); check(client.mutations.isEmpty)
        check(controller.handle(keyEvent(49, " ", [.control, .shift]), client: client))
        check(controller.handle(keyEvent(45, "n"), client: client)); check(client.mutations == ["mark:n"])
        check(controller.handle(keyEvent(53, ""), client: client)); check(client.mutations == ["mark:n", "mark:"])
        controller.commitComposition(client); controller.deactivateServer(client); check(client.mutations.count == 2)
        client.mutations.removeAll()
        for letter in "nihao" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
        client.mutations.removeAll()
        check(controller.handle(keyEvent(49, " "), client: client)); check(client.mutations == ["insert:你好"])
        controller.commitComposition(client); controller.deactivateServer(client); check(client.mutations == ["insert:你好"])
        client.mutations.removeAll()
        for _ in 0..<4 { check(controller.handle(keyEvent(39, "\"", .shift), client: client)) }
        let quotes = ["insert:“", "insert:”", "insert:“", "insert:”"]
        check(client.mutations == quotes)
        controller.commitComposition(client); controller.deactivateServer(client); check(client.mutations == quotes)
        let punctuation: [(UInt16, String, String)] = [(39, "\"", "“"), (33, "{", "「"), (30, "}", "」"), (22, "^", "……"), (27, "_", "——")]
        for (code, input, output) in punctuation {
            for letter in "nihao" { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
            client.mutations.removeAll()
            check(controller.handle(keyEvent(code, input, .shift), client: client))
            let expected = ["insert:你好\(output)"]
            check(client.mutations == expected)
            controller.commitComposition(client); controller.deactivateServer(client); check(client.mutations == expected)
        }
    }
}
