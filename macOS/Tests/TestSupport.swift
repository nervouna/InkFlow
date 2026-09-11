import AppKit
import InputMethodKit

@MainActor
func check(_ condition: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard condition() else {
        print("FAIL \(file):\(line) \(message)")
        exit(1)
    }
}

@MainActor
func keyEvent(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                    isARepeat: false, keyCode: code)!
}

@MainActor
func modifierEvent(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: code)!
}

@MainActor
func type(_ engine: IFEngine, _ text: String) {
    for code in text.utf16 { engine.key(Int32(code)) }
}

@MainActor
final class IsolatedSettings {
    let suite = "inkflow.test.\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: IFSettings
    init() {
        defaults = UserDefaults(suiteName: suite)!
        settings = IFSettings(defaults: defaults)
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite) }
}

@MainActor
func drainEvents(seconds: TimeInterval = 0.15) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while deadline.timeIntervalSinceNow > 0 {
        if let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }
}


@MainActor
final class RecordingClient: NSObject, @preconcurrency IMKTextInput {
    var mutations: [String] = []
    var insertions: [(replacementRange: NSRange, markedRange: NSRange)] = []
    var insertionCallback: (() -> Void)?
    var onMutation: (() -> Void)?
    var testBundleID: String? = "inkflow.recording-client"
    var testClientID: String? = "inkflow.recording-client"
    var document: String?
    var selection = NSRange(location: NSNotFound, length: 0)
    var mark = NSRange(location: NSNotFound, length: 0)
    var contextAvailable = true
    var updatesActualRange = true
    var requests: [NSRange] = []
    var substringResponse: ((NSRange) -> (String?, NSRange))?
    var lengthReads = 0
    var reportedLength: Int?

    init(document: String? = nil) {
        self.document = document
        if let document { selection = NSRange(location: document.utf16.count, length: 0) }
    }

    private func replace(_ text: String, marked: Bool, cursor: NSRange? = nil, requested: NSRange? = nil) {
        guard let document else { return }
        let range = requested.flatMap { $0.location != NSNotFound ? $0 : nil } ?? (mark.location != NSNotFound ? mark : selection)
        check(range.location != NSNotFound && NSMaxRange(range) <= document.utf16.count)
        self.document = (document as NSString).replacingCharacters(in: range, with: text)
        selection = NSRange(location: range.location + (cursor?.location ?? text.utf16.count), length: cursor?.length ?? 0)
        mark = marked && !text.isEmpty ? NSRange(location: range.location, length: text.utf16.count) : NSRange(location: NSNotFound, length: 0)
    }
    func insertText(_ string: Any!, replacementRange: NSRange) {
        insertions.append((replacementRange, mark))
        mutations.append("insert:\(string as! String)")
        onMutation?()
        replace(string as! String, marked: false, requested: replacementRange)
        insertionCallback?()
    }
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        check(replacementRange == NSRange(location: NSNotFound, length: 0))
        let text = string as! String
        check(selectionRange.location <= text.utf16.count)
        mutations.append("mark:\(text)")
        onMutation?()
        replace(text, marked: true, cursor: selectionRange)
    }
    func selectedRange() -> NSRange { selection }
    func markedRange() -> NSRange { mark }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! { nil }
    func length() -> Int { lengthReads += 1; return reportedLength ?? document?.utf16.count ?? NSNotFound }
    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode,
                        inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { NSNotFound }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! { [:] }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed name: String!) {}
    func selectMode(_ identifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String! { testBundleID }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { testClientID }
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
