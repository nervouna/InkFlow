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
        IFEngine.stop()
        print("PASS controller: idle client unchanged, Escape clears owned mark once, commit inserts once without empty replacement, consecutive quotes and shifted punctuation")
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
        for (input, emoji) in [("aixin", "❤️"), ("zhongguo", "🇨🇳"), ("yisheng", "👨‍⚕️")] {
            for letter in input { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
            var selected = false
            for _ in 0..<10 {
                let candidates = controller.candidates(nil) as! [String]
                if let index = candidates.firstIndex(of: emoji) {
                    client.mutations.removeAll()
                    let keys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
                    check(controller.handle(keyEvent(keys[index], String(index + 1)), client: client))
                    check(client.mutations == ["insert:\(emoji)"], "Insert whole emoji once: \(input)")
                    check(controller.candidates(nil).isEmpty)
                    controller.commitComposition(client); controller.deactivateServer(client)
                    check(client.mutations == ["insert:\(emoji)"])
                    selected = true
                    break
                }
                let page = controller.engine!.snapshot().page
                check(controller.handle(keyEvent(121, ""), client: client))
                if controller.engine!.snapshot().page == page { break }
            }
            check(selected, "Controller must expose \(emoji)")
        }
        print("PASS controller emoji: candidate bridge, paging, variation selector / flag / ZWJ sequences inserted once, composition cleared")
    }
}
