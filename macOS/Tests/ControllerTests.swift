import InputMethodKit

@MainActor
final class RecordingClient: NSObject, @preconcurrency IMKTextInput {
    var mutations: [String] = []
    var document: String?
    var selection = NSRange(location: NSNotFound, length: 0)
    var mark = NSRange(location: NSNotFound, length: 0)
    var contextAvailable = true
    var updatesActualRange = true
    var requests: [NSRange] = []
    var substringResponse: ((NSRange) -> (String?, NSRange))?

    init(document: String? = nil) {
        self.document = document
        if let document { selection = NSRange(location: document.utf16.count, length: 0) }
    }

    private func replace(_ text: String, marked: Bool, cursor: NSRange? = nil) {
        guard let document else { return }
        let range = mark.location != NSNotFound ? mark : selection
        check(range.location != NSNotFound && NSMaxRange(range) <= document.utf16.count)
        self.document = (document as NSString).replacingCharacters(in: range, with: text)
        selection = NSRange(location: range.location + (cursor?.location ?? text.utf16.count), length: cursor?.length ?? 0)
        mark = marked && !text.isEmpty ? NSRange(location: range.location, length: text.utf16.count) : NSRange(location: NSNotFound, length: 0)
    }
    func insertText(_ string: Any!, replacementRange: NSRange) {
        check(replacementRange == NSRange(location: NSNotFound, length: 0))
        mutations.append("insert:\(string as! String)")
        replace(string as! String, marked: false)
    }
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        check(replacementRange == NSRange(location: NSNotFound, length: 0))
        let text = string as! String
        check(selectionRange.location <= text.utf16.count)
        mutations.append("mark:\(text)")
        replace(text, marked: true, cursor: selectionRange)
    }
    func selectedRange() -> NSRange { selection }
    func markedRange() -> NSRange { mark }
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
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! {
        requests.append(range)
        guard contextAvailable else { return nil }
        if let substringResponse {
            let (text, actual) = substringResponse(range)
            actualRange?.pointee = actual
            return text
        }
        guard let document, NSMaxRange(range) <= document.utf16.count else { return nil }
        if updatesActualRange { actualRange?.pointee = range }
        return (document as NSString).substring(with: range)
    }
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
        contextReading()
        runCases(settings: isolated.settings)
        try customPhrases(settings: isolated.settings)
        try customPhraseFailure(settings: isolated.settings, user: CommandLine.arguments[2])
        contextReranking(settings: isolated.settings)
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

    @MainActor static func contextReading() {
        func read(_ client: RecordingClient, owned: Bool = false) -> String {
            IFPrecedingText.read(from: client, ownsMarkedText: owned, secureInput: false)
        }
        let client = RecordingClient(document: "😀准备午被选中后文")
        client.selection = NSRange(location: 5, length: 3)
        check(read(client) == "😀准备午")
        check(client.requests.last == NSRange(location: 0, length: 5))
        client.updatesActualRange = false
        check(read(client) == "😀准备午", "Exact requests need no adjusted actualRange")
        client.mark = NSRange(location: 5, length: 3)
        client.selection = NSRange(location: 7, length: 0)
        check(read(client, owned: true) == "😀准备午")
        check(read(client).isEmpty, "A foreign mark is not preceding committed text")
        client.selection = NSRange(location: 9, length: 0)
        check(read(client, owned: true).isEmpty)
        client.mark = NSRange(location: NSNotFound, length: 0)
        for invalid in [NSRange(location: NSNotFound, length: 0), NSRange(location: 0, length: NSNotFound),
                        NSRange(location: -1, length: 0), NSRange(location: Int.max - 1, length: 4)] {
            client.selection = invalid; check(read(client).isEmpty)
        }
        let bounded = RecordingClient(document: "😀" + String(repeating: "前", count: 12) + "准备午")
        bounded.substringResponse = { request in
            check(request == NSRange(location: 1, length: 16))
            return (bounded.document, NSRange(location: 0, length: 17))
        }
        check(read(bounded) == bounded.document, "Expanded surrogate pair at the prefix start")
        bounded.substringResponse = { _ in ("准备午", NSRange(location: 14, length: 3)) }
        check(read(bounded) == "准备午", "Shorter available prefix ending exactly at the caret")
        for response in [("准备午", NSRange(location: 14, length: 2)),
                         ("准备午", NSRange(location: 13, length: 3)),
                         ("准备午", NSRange(location: NSNotFound, length: 3)),
                         ("准备午", NSRange(location: Int.max - 1, length: 3))] {
            bounded.substringResponse = { _ in response }; check(read(bounded).isEmpty)
        }
        let split = RecordingClient(document: "前😀")
        split.selection = NSRange(location: 2, length: 0)
        split.substringResponse = { _ in ("前😀", NSRange(location: 0, length: 3)) }
        check(read(split).isEmpty, "Never cut a surrogate pair at the caret")
        let requests = client.requests.count
        check(IFPrecedingText.read(from: client, ownsMarkedText: false, secureInput: true).isEmpty)
        check(client.requests.count == requests, "Secure event input must not request document text")
        check(IFPrecedingText.read(from: nil, ownsMarkedText: false, secureInput: false).isEmpty)
        client.contextAvailable = false; client.selection = NSRange(location: 5, length: 0)
        check(read(client).isEmpty)
        print("PASS context reading: bounded UTF-16, emoji, selection, owned/foreign marks, adjusted/unmodified/malformed ranges, nil/unavailable/secure clients")
    }

    @MainActor static func contextReranking(settings: IFSettings) {
        func prepared(_ prefix: String = "准备午") -> (InkFlowInputController, RecordingClient) {
            let client = RecordingClient(document: prefix)
            let controller = InkFlowInputController(server: nil, delegate: nil, client: client,
                                                    settings: settings, settingsWindow: IFSettingsWindowController(settings: settings))!
            for character in "can" { check(controller.handle(keyEvent(0, String(character)), client: client)) }
            return (controller, client)
        }
        for action in ["space", "digit", "click", "arrow", "panel-highlight", "comma", "return", "shortcut", "toggle", "commit", "deactivate"] {
            let (controller, client) = prepared()
            let candidates = controller.candidates(nil) as! [String]
            check(candidates.first == "餐")
            check(client.mark.location == 3 && client.document == "准备午can")
            client.mutations.removeAll()
            var expected = "餐"
            switch action {
            case "space": check(controller.handle(keyEvent(49, " "), client: client))
            case "digit": check(controller.handle(keyEvent(18, "1"), client: client))
            case "click": controller.candidateSelected(NSAttributedString(string: candidates[1])); expected = candidates[1]
            case "arrow":
                check(controller.handle(keyEvent(125, ""), client: client))
                check(controller.engine?.snapshot().highlight == 1)
                check(controller.handle(keyEvent(49, " "), client: client)); expected = candidates[1]
            case "panel-highlight":
                controller.candidateSelectionChanged(NSAttributedString(string: candidates[1]))
                check(controller.engine?.snapshot().highlight == 1)
                check(controller.handle(keyEvent(49, " "), client: client)); expected = candidates[1]
            case "comma": check(controller.handle(keyEvent(43, ","), client: client)); expected = "餐，"
            case "return": check(controller.handle(keyEvent(36, "\r"), client: client)); expected = "can"
            case "shortcut": check(!controller.handle(keyEvent(0, "a", .command), client: client))
            case "toggle": check(controller.handle(keyEvent(49, " ", [.control, .shift]), client: client))
            case "commit": controller.commitComposition(client)
            default: controller.deactivateServer(client)
            }
            check(client.document == "准备午" + expected, action)
            check(client.mutations.filter { $0.hasPrefix("insert:") } == ["insert:" + expected], action)
            check(!client.mutations.contains("mark:"), "No empty replacement after committing")
            controller.commitComposition(client); controller.deactivateServer(client)
            check(client.document == "准备午" + expected)
        }
        for action in ["space", "digit", "commit"] {
            for moveSelection in [false, true] {
                let (controller, client) = prepared()
                if moveSelection { client.selection = NSRange(location: 0, length: 0) }
                else { client.contextAvailable = false }
                switch action {
                case "space": check(controller.handle(keyEvent(49, " "), client: client))
                case "digit": check(controller.handle(keyEvent(18, "1"), client: client))
                default: controller.commitComposition(client)
                }
                check(client.document == "准备午餐", "A changed/unreadable client must not silently change the displayed selection")
            }
        }
        let (controller, client) = prepared()
        check(controller.handle(keyEvent(125, ""), client: client))
        let before = controller.engine!.snapshot()
        settings.fontSize = 18; settings.vertical = true; settings.candidateCount = 9
        check(controller.engine!.snapshot() == before)
        controller.commitComposition(client)
        check(client.document == "准备午" + before.candidates[before.highlight])
        settings.fontSize = 14; settings.vertical = false; settings.candidateCount = 5
        let (unrelated, _) = prepared("完全无关")
        let baseline = IFEngine()!; type(baseline, "can")
        check(unrelated.engine?.snapshot().candidates == baseline.snapshot().candidates, "Controllers must not share document context")
        print("PASS context controller: actual marked-document edits, digits/click/arrows/panel highlight/default/flush, raw Return, unreadable/moved selection, settings and client isolation")
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

        for (input, expected) in [("hzidao", "知道"), ("nnihao", "你好")] {
            client.mutations.removeAll()
            for letter in input { check(controller.handle(keyEvent(0, String(letter)), client: client)) }
            check(client.mutations.allSatisfy { $0.hasPrefix("mark:") }, "Typing must only update marked text")
            check((controller.candidates(nil) as? [String])?.first == expected)
            client.mutations.removeAll()
            check(controller.handle(keyEvent(18, "1"), client: client))
            check(client.mutations == ["insert:\(expected)"])
            controller.commitComposition(client)
            check(client.mutations == ["insert:\(expected)"])
        }
        print("PASS controller spelling correction: preedit-only updates, corrected candidates, single digit-key commit")
    }
}
